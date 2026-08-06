#Requires -Version 5.1
<#
.SYNOPSIS
    Collects the machine FQDN and the most recent OS updates.
    Results are output as a table showing KB number, install date, result code, and title.
    Defender definition updates, security intelligence updates, and other
    non-OS component updates are excluded from the result.
    Designed to run via ArcScriptHarness.ps1. Pass -DiagnosticScriptParameters to override
    the default count. The harness lifts the param() block automatically.

.PARAMETER MostRecentCount
    Number of most recent OS updates to return. Must be between 1 and 100. Defaults to 10.

.EXAMPLE
    # Run directly on the local machine
    .\ArcPatchLevel.ps1 -MostRecentCount 20

.EXAMPLE
    # Run via ArcScriptHarness.ps1 with a custom count
    .\ArcScriptHarness.ps1 `
        -DiagnosticScriptPath       .\ArcPatchLevel.ps1 `
        -SubscriptionId             'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -DiagnosticScriptParameters @{ MostRecentCount = 20 }

.NOTES
    Version: 1.3.0
#>
param(
    [ValidateRange(1, 100)]
    [int]$MostRecentCount = 10
)
$script:Version = '1.3.0'

# ── FQDN ──────────────────────────────────────────────────────────────────────
$fqdn = [System.Net.Dns]::GetHostEntry('').HostName

# ── Parameter validation ──────────────────────────────────────────────────────
if ($MostRecentCount -lt 1 -or $MostRecentCount -gt 100) {
    throw "MostRecentCount must be between 1 and 100 (received: $MostRecentCount)."
}

# ── Most recent OS updates via Windows Update Agent COM API ──────────────────
# Run the WUA COM query in a background job so it cannot stall the script
# indefinitely (GetTotalHistoryCount or QueryHistory can block on a locked
# datastore or a slow WU service).  90 seconds is generous for 200 entries.
$wuaJob = Start-Job -ScriptBlock {
    $result = [PSCustomObject]@{
        Updates = [System.Collections.Generic.List[PSCustomObject]]::new()
        Error   = $null
    }
    try {
        $session    = New-Object -ComObject Microsoft.Update.Session
        $searcher   = $session.CreateUpdateSearcher()
        $totalCount = $searcher.GetTotalHistoryCount()

        if ($totalCount -gt 0) {
            # Fetch the 200 most-recent entries (newest-first).
            # Match only updates whose title contains an OS update phrase.
            #
            # Two naming conventions are in use:
            #   Old: 'for Windows Server 2016/2019/2022/2025' or 'for Windows 10/11'
            #   New: 'for Microsoft server operating system version 21H2' (Windows Server 2022+)
            #
            # Both are matched by:
            #   for (?:Windows (?:Server|\d)|Microsoft server operating system)
            #
            # The YYYY-MM date prefix is intentionally NOT used as a match criterion:
            # Microsoft applies that prefix to non-OS updates as well (e.g. Defender
            # platform updates), so it is no longer a reliable indicator of an OS patch.
            #
            # Intentionally excludes 'for Microsoft Defender' and
            # 'for Windows Defender' — neither 'Defender' token matches the alternation.
            $history        = $searcher.QueryHistory(0, [Math]::Min($totalCount, 200))
            $includePattern = 'for (?:Windows (?:Server|\d)|Microsoft server operating system)'
            $osUpdates      = $history |
                Where-Object { $_.Title -match $includePattern } |
                Sort-Object Date -Descending |
                Select-Object -First $using:MostRecentCount

            foreach ($u in $osUpdates) {
                $kb = if ($u.Title -match '(KB\d+)') { $Matches[1] } else { 'N/A' }
                $result.Updates.Add([PSCustomObject]@{
                    KB         = $kb
                    Title      = $u.Title
                    Date       = $u.Date.ToString('yyyy-MM-dd')
                    ResultCode = [int]$u.ResultCode
                })
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

$wuaCompleted = Wait-Job -Job $wuaJob -Timeout 90

# $osUpdates   — unified list regardless of source (WUA primary or Get-HotFix fallback)
# $updateSource — describes the data source or any error/timeout condition
# WUA ResultCode values: 2=Success  3=SucceededWithErrors  4=Failed  5=Aborted
# ResultCode -1 means the Get-HotFix fallback was used; result is implicitly installed.
$osUpdates    = @()
$updateSource = 'WUA'

if ($wuaCompleted) {
    $wuaData = Receive-Job -Job $wuaJob
    if ($wuaData.Error) {
        # WUA COM unavailable — fall back to Get-HotFix
        $updateSource = 'Fallback (Get-HotFix)'
        try {
            $hotfixes = @(
                Get-HotFix -ErrorAction Stop |
                    Where-Object { $_.HotFixID -match '^KB' } |
                    Sort-Object InstalledOn -Descending |
                    Select-Object -First $MostRecentCount
            )
            $osUpdates = @(
                $hotfixes | ForEach-Object {
                    $dateStr = if ($_.InstalledOn) { $_.InstalledOn.ToString('yyyy-MM-dd') } else { 'Unknown' }
                    [PSCustomObject]@{
                        KB         = $_.HotFixID
                        Title      = "$($_.Description) - $($_.HotFixID)"
                        Date       = $dateStr
                        ResultCode = -1
                    }
                }
            )
        } catch {
            $updateSource = "ERROR: $($_.Exception.Message)"
        }
    } else {
        $osUpdates = @($wuaData.Updates)
    }
} else {
    # Job did not finish within 90 seconds — kill it and report the timeout
    Stop-Job  -Job $wuaJob
    $updateSource = 'WUA query timed out (>90s) - datastore may be locked or oversized'
}
Remove-Job -Job $wuaJob -Force

# ── Output ────────────────────────────────────────────────────────────────────
Write-Output "=== Arc Patch Level Diagnostic ==="
Write-Output "Script Version    : $($script:Version)"
Write-Output "FQDN              : $fqdn"
Write-Output ""
Write-Output "--- $MostRecentCount Most Recent OS Updates ($updateSource) ---"

if ($osUpdates.Count -gt 0) {
    $rowFmt = "{0,-13} {1,-12} {2,-10} {3}"
    Write-Output ($rowFmt -f 'KB', 'Date', 'Result', 'Title')
    Write-Output ($rowFmt -f ('-' * 12), ('-' * 10), ('-' * 9), ('-' * 60))
    foreach ($u in $osUpdates) {
        $label = switch ($u.ResultCode) {
            2       { 'Success'   }
            3       { 'Partial'   }
            4       { 'Failed'    }
            5       { 'Aborted'   }
            -1      { 'Installed' }
            default { "Code:$($u.ResultCode)" }
        }
        Write-Output ($rowFmt -f $u.KB, $u.Date, $label, $u.Title)
    }
} else {
    Write-Output "(No OS updates found - $updateSource)"
}
