#Requires -Version 5.1
<#
.SYNOPSIS
    Collects machine name, logon domain, IP address, and latest cumulative update.
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

# ── Latest cumulative update via Windows Update Agent COM API ─────────────────
$cuTitle   = 'Not found'
$cuKB      = 'N/A'
$cuDate    = 'N/A'

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
            # Fetch the 50 most-recent entries (newest-first); the latest CU
            # will appear near the top on any normally-patched machine.
            $history  = $searcher.QueryHistory(0, [Math]::Min($totalCount, 50))
            $latestCU = $history |
                Where-Object { $_.ResultCode -eq 2 -and $_.Title -match 'Cumulative Update' } |
                Sort-Object Date -Descending |
                Select-Object -First 1

            if ($latestCU) {
                $result.Title = $latestCU.Title
                $result.Date  = $latestCU.Date.ToString('yyyy-MM-dd')
                $result.KB    = if ($latestCU.Title -match '(KB\d+)') { $Matches[1] } else { 'KB not parseable from title' }
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
                $cuTitle = "$($hotfix.Description) - $($hotfix.HotFixID)"
                $cuKB    = $hotfix.HotFixID
                if ($hotfix.InstalledOn) { $cuDate = $hotfix.InstalledOn.ToString('yyyy-MM-dd') } else { $cuDate = 'Unknown' }
            } else {
                $cuTitle = 'No hotfixes found via fallback'
            }
        } catch {
            $cuTitle = "ERROR retrieving update info: $($_.Exception.Message)"
        }
    } else {
        $cuTitle = $wuaData.Title
        $cuKB    = $wuaData.KB
        $cuDate  = $wuaData.Date
    }
} else {
    # Job did not finish within 90 seconds — kill it and report the timeout
    Stop-Job    -Job $wuaJob
    $cuTitle = 'WUA query timed out (>90s) — datastore may be locked or oversized'
}
Remove-Job -Job $wuaJob -Force

# ── Output ────────────────────────────────────────────────────────────────────
Write-Output "=== Arc Patch Level Diagnostic ==="
Write-Output "Machine Name      : $machineName"
Write-Output "Domain            : $domain"
Write-Output "IP Address(es)    : $ipDisplay"
Write-Output ""
Write-Output "--- Latest Cumulative Update ---"
Write-Output "Display Name      : $cuTitle"
Write-Output "KB Version        : $cuKB"
Write-Output "Install Date      : $cuDate"
