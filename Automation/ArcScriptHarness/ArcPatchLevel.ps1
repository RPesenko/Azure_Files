#Requires -Version 5.1
<#
.SYNOPSIS
    Collects machine name, logon domain, IP address, and latest OS update.
    Defender definition updates, security intelligence updates, and other
    non-OS component updates are excluded from the result.
    Designed to run via ArcScriptHarness.ps1. No modification needed — the harness
    wraps this script in a try/catch automatically.
#>

# ── Machine name ──────────────────────────────────────────────────────────────
$machineName = $env:COMPUTERNAME

# ── Domain ────────────────────────────────────────────────────────────────────
$cs           = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$domain       = if ($cs.PartOfDomain) { $cs.Domain } else { 'Not domain-joined (workgroup: ' + $cs.Workgroup + ')' }

# ── IP address(es) — IPv4 only, exclude loopback and APIPA ───────────────────
$ipList = $null
try {
    $ipList = @(
        Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -ExpandProperty IPAddress
    )
} catch {
    # Fallback: DNS resolution (works on PS 5.1 without NetAdapter module)
    $ipList = @(
        [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).AddressList |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            ForEach-Object { $_.IPAddressToString }
    )
}
$ipDisplay = if ($ipList -and $ipList.Count -gt 0) { $ipList -join ', ' } else { 'None found' }

# ── Latest OS update via Windows Update Agent COM API ───────────────────────
$updateTitle = 'Not found'
$updateKB    = 'N/A'
$updateDate  = 'N/A'

# Run the WUA COM query in a background job so it cannot stall the script
# indefinitely (GetTotalHistoryCount or QueryHistory can block on a locked
# datastore or a slow WU service).  90 seconds is generous for 50 entries.
$wuaJob = Start-Job -ScriptBlock {
    $result = [PSCustomObject]@{ Title = 'Not found'; KB = 'N/A'; Date = 'N/A'; Error = $null }
    try {
        $session    = New-Object -ComObject Microsoft.Update.Session
        $searcher   = $session.CreateUpdateSearcher()
        $totalCount = $searcher.GetTotalHistoryCount()

        if ($totalCount -gt 0) {
            # Fetch the 100 most-recent entries (newest-first).
            # Match only updates whose title contains 'for Windows <OS>' — the phrase
            # present in every genuine OS quality update per Microsoft's naming convention
            # (cumulative, security, servicing stack, .NET framework updates, etc.).
            #
            # The YYYY-MM date prefix is intentionally NOT used as a match criterion:
            # Microsoft now applies that prefix to non-OS component updates as well
            # (e.g. 'Windows ML OpenVINO Update'), so it is no longer a reliable
            # indicator of an OS-level patch.
            #
            # Pattern:  for Windows (?:Server|\d)
            #   'Server' — covers Windows Server 2016/2019/2022/2025
            #   '\d'     — covers Windows 10/11 (version number starts with a digit)
            # Intentionally excludes 'for Windows Defender' because 'Defender' starts
            # with neither 'Server' nor a digit.
            $history        = $searcher.QueryHistory(0, [Math]::Min($totalCount, 100))
            $includePattern = 'for Windows (?:Server|\d)'
            $latestUpdate   = $history |
                Where-Object { $_.ResultCode -eq 2 -and $_.Title -match $includePattern } |
                Sort-Object Date -Descending |
                Select-Object -First 1

            if ($latestUpdate) {
                $result.Title = $latestUpdate.Title
                $result.Date  = $latestUpdate.Date.ToString('yyyy-MM-dd')
                $result.KB    = if ($latestUpdate.Title -match '(KB\d+)') { $Matches[1] } else { 'KB not parseable from title' }
            }
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

$wuaCompleted = Wait-Job -Job $wuaJob -Timeout 90

if ($wuaCompleted) {
    $wuaData = Receive-Job -Job $wuaJob
    if ($wuaData.Error) {
        # WUA COM unavailable — try Get-HotFix fallback
        try {
            $hotfix = Get-HotFix -ErrorAction Stop |
                Where-Object { $_.HotFixID -match '^KB' } |
                Sort-Object InstalledOn -Descending |
                Select-Object -First 1

            if ($hotfix) {
                $updateTitle = "$($hotfix.Description) - $($hotfix.HotFixID)"
                $updateKB    = $hotfix.HotFixID
                if ($hotfix.InstalledOn) { $updateDate = $hotfix.InstalledOn.ToString('yyyy-MM-dd') } else { $updateDate = 'Unknown' }
            } else {
                $updateTitle = 'No hotfixes found via fallback'
            }
        } catch {
            $updateTitle = "ERROR retrieving update info: $($_.Exception.Message)"
        }
    } else {
        $updateTitle = $wuaData.Title
        $updateKB    = $wuaData.KB
        $updateDate  = $wuaData.Date
    }
} else {
    # Job did not finish within 90 seconds — kill it and report the timeout
    Stop-Job    -Job $wuaJob
    $updateTitle = 'WUA query timed out (>90s) — datastore may be locked or oversized'
}
Remove-Job -Job $wuaJob -Force

# ── Output ────────────────────────────────────────────────────────────────────
Write-Output "=== Arc Patch Level Diagnostic ==="
Write-Output "Machine Name      : $machineName"
Write-Output "Domain            : $domain"
Write-Output "IP Address(es)    : $ipDisplay"
Write-Output ""
Write-Output "--- Latest OS Update ---"
Write-Output "Display Name      : $updateTitle"
Write-Output "KB Version        : $updateKB"
Write-Output "Install Date      : $updateDate"
