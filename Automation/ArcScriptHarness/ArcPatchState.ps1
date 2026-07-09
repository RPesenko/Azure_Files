#Requires -Version 5.1
<#
.SYNOPSIS
    Collects installed patch state using DISM /online /get-packages.
    Results are grouped into three categories: Security Updates, Servicing Stack Updates,
    and OS Updates, sorted by install date descending within each group.
    Designed to run via ArcScriptHarness.ps1.

.EXAMPLE
    # Run directly on the local machine (requires elevation)
    .\ArcPatchState.ps1

.EXAMPLE
    # Run via ArcScriptHarness.ps1
    .\ArcScriptHarness.ps1 `
        -DiagnosticScriptPath .\ArcPatchState.ps1 `
        -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.NOTES
    Version: 1.0.0
    DISM requires elevation. When run via Arc Run Command the agent executes as SYSTEM,
    so elevation is satisfied automatically.
    Release-type filter:
        Security Update  — DISM Release Type = 'Security Update'
        Servicing Stack  — DISM Release Type = 'Update' AND Identity contains 'ServicingStack'
        OS Update        — DISM Release Type = 'Update' AND Identity does NOT contain 'ServicingStack'
#>

$script:Version = '1.0.0'

# ── FQDN ──────────────────────────────────────────────────────────────────────
$fqdn = [System.Net.Dns]::GetHostEntry('').HostName

# ── DISM package query ────────────────────────────────────────────────────────
# Run DISM in a background job to prevent the script from stalling if DISM hangs
# (e.g. on a system with a very large package store or a locked CBS database).
$dismJob = Start-Job -ScriptBlock {
    $result = [PSCustomObject]@{
        Packages = [System.Collections.Generic.List[PSCustomObject]]::new()
        Error    = $null
    }
    try {
        $raw = & dism /online /get-packages 2>&1

        if ($LASTEXITCODE -ne 0) {
            $result.Error = "DISM exited with code $LASTEXITCODE. Output: $(($raw | Select-Object -First 5) -join ' ')"
            return $result
        }

        # Parse the block-structured DISM output.
        # Each package block contains: Package Identity, State, Release Type, Install Time,
        # terminated by a blank line or end-of-stream.
        $current = @{}
        foreach ($line in $raw) {
            $line = $line.Trim()
            if ($line -match '^Package Identity\s*:\s*(.+)$') {
                $current = @{ Identity = $Matches[1].Trim() }
            } elseif ($current.ContainsKey('Identity') -and $line -match '^State\s*:\s*(.+)$') {
                $current['State'] = $Matches[1].Trim()
            } elseif ($current.ContainsKey('Identity') -and $line -match '^Release Type\s*:\s*(.+)$') {
                $current['ReleaseType'] = $Matches[1].Trim()
            } elseif ($current.ContainsKey('Identity') -and $line -match '^Install Time\s*:\s*(.+)$') {
                $current['InstallTime'] = $Matches[1].Trim()
                # A completed Installed entry — flush it
                if ($current['State'] -eq 'Installed' -and $current.ContainsKey('ReleaseType')) {
                    $result.Packages.Add([PSCustomObject]@{
                        Identity    = $current['Identity']
                        ReleaseType = $current['ReleaseType']
                        InstallTime = $current['InstallTime']
                    })
                }
                $current = @{}
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

$dismCompleted = Wait-Job -Job $dismJob -Timeout 120

$packages   = @()
$dataSource = 'DISM'

if ($dismCompleted) {
    $dismData = Receive-Job -Job $dismJob
    if ($dismData.Error) {
        $dataSource = "ERROR: $($dismData.Error)"
    } else {
        $packages = @(
            $dismData.Packages |
                Where-Object {
                    $_.ReleaseType -eq 'Security Update' -or
                    $_.ReleaseType -eq 'Update'
                } |
                ForEach-Object {
                    # Extract KB number from the package identity when present
                    $kb = if ($_.Identity -match '(KB\d+)') { $Matches[1] } else { 'N/A' }

                    # Normalise install date to yyyy-MM-dd
                    $installDate = 'Unknown'
                    if ($_.InstallTime) {
                        try {
                            $installDate = [datetime]::Parse($_.InstallTime).ToString('yyyy-MM-dd')
                        } catch {
                            $installDate = $_.InstallTime
                        }
                    }

                    [PSCustomObject]@{
                        KB          = $kb
                        InstallDate = $installDate
                        Identity    = $_.Identity
                    }
                }
        )
    }
} else {
    Stop-Job -Job $dismJob
    $dataSource = 'DISM query timed out (>120s) - CBS database may be locked or oversized'
}
Remove-Job -Job $dismJob -Force

# ── Output ────────────────────────────────────────────────────────────────────
Write-Output "=== Arc Patch State Diagnostic ==="
Write-Output "Script Version    : $($script:Version)"
Write-Output "FQDN              : $fqdn"
Write-Output "Data Source       : $dataSource"
Write-Output ""

if ($packages.Count -gt 0) {
    $sorted = @($packages | Sort-Object InstallDate -Descending)
    $rowFmt = "{0,-13} {1,-12} {2}"
    Write-Output ($rowFmt -f 'KB', 'Install Date', 'Package Identity')
    Write-Output ($rowFmt -f ('-' * 12), ('-' * 11), ('-' * 60))
    foreach ($p in $sorted) {
        Write-Output ($rowFmt -f $p.KB, $p.InstallDate, $p.Identity)
    }
    Write-Output ""
    Write-Output "Total matching packages: $($packages.Count)"
} else {
    Write-Output "(No matching packages found - $dataSource)"
}
