#Requires -Version 5.1
<#
.SYNOPSIS
    Comprehensive machine health diagnostic. Collects system info, .NET Framework versions,
    CPU (WMI), memory with top processes and stopped auto-start services, disk volumes,
    IP-enabled network adapters, and the last 20 Critical/Warning events in the System
    and Application event logs. Reports total script run time.

    Designed to run via ArcScriptHarness.ps1. No modification required - the harness
    wraps this script in a try/catch automatically.

.NOTES
    Version: 1.0.0
    Total output commonly exceeds the 4 KB inline Run Command limit on complex machines.
    ArcScriptHarness.ps1 will flag truncation automatically.
#>
$script:Version = '1.0.0'
$scriptStart    = Get-Date

Write-Output "=== Arc Machine Health Diagnostic ==="
Write-Output "Script Version    : $($script:Version)"
Write-Output "Run Started       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output ""

# -- System Information --------------------------------------------------------
Write-Output "--- System Information ---"
$cs     = Get-CimInstance -ClassName Win32_ComputerSystem  -ErrorAction Stop
$os     = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$domain = if ($cs.PartOfDomain) {
              $cs.Domain
          } else {
              'Not domain-joined (workgroup: ' + $cs.Workgroup + ')'
          }

# VM or physical detection via Manufacturer / Model
$mfr   = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { '' }
$model = if ($cs.Model)        { $cs.Model.Trim()        } else { '' }
$vmPlatform = $null
$vmHostName = $null
if ($model -eq 'Virtual Machine' -and $mfr -like 'Microsoft*') {
    $vmPlatform = 'Hyper-V'
    $hvKey = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
    if (Test-Path $hvKey) {
        $hvProps = Get-ItemProperty -Path $hvKey -ErrorAction SilentlyContinue
        if ($hvProps -and $hvProps.PhysicalHostName) { $vmHostName = $hvProps.PhysicalHostName }
    }
} elseif ($mfr -like 'VMware*') {
    $vmPlatform = 'VMware'
} elseif ($mfr -eq 'innotek GmbH' -or $model -like '*VirtualBox*') {
    $vmPlatform = 'VirtualBox'
} elseif ($mfr -like '*Amazon*' -or $model -like '*Amazon*') {
    $vmPlatform = 'AWS'
} elseif ($mfr -like '*Google*' -or $model -like '*Google*') {
    $vmPlatform = 'Google Cloud'
} elseif ($model -like '*Virtual*' -or $mfr -like '*QEMU*' -or $mfr -like '*Xen*') {
    $vmPlatform = 'Virtual Machine'
}
$machineTypeStr = if ($vmPlatform) {
    if ($vmHostName) { "VM ($vmPlatform) - Host: $vmHostName" }
    else             { "VM ($vmPlatform)" }
} else { 'Physical' }

Write-Output "Machine Name      : $($env:COMPUTERNAME)"
Write-Output "Logon Domain      : $domain"
Write-Output "OS Version        : $($os.Caption) (Build $($os.BuildNumber))"
Write-Output "Machine Type      : $machineTypeStr"
Write-Output ""

# -- .NET Framework Versions ---------------------------------------------------
Write-Output "--- .NET Framework Versions ---"
$dotNetVersions = [System.Collections.Generic.List[string]]::new()
$ndpPath = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP'
if (Test-Path $ndpPath) {
    # 1.x / 2.x / 3.x - presence via Install=1 in each version subkey
    foreach ($ver in @('v1.0.3705', 'v1.1.4322', 'v2.0.50727', 'v3.0', 'v3.5')) {
        $keyPath = Join-Path $ndpPath $ver
        if (Test-Path $keyPath) {
            $props = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
            if ($props -and $props.Install -eq 1) {
                $dotNetVersions.Add('.NET Framework ' + $ver.TrimStart('v'))
            }
        }
    }
    # 4.5+ - Release DWORD in v4\Full maps to a specific version string
    $v4Path = Join-Path $ndpPath 'v4\Full'
    if (Test-Path $v4Path) {
        $release = (Get-ItemProperty -Path $v4Path -ErrorAction SilentlyContinue).Release
        if ($release) {
            $v4ver = if     ($release -ge 533320) { '4.8.1' }
                     elseif ($release -ge 528040) { '4.8'   }
                     elseif ($release -ge 461808) { '4.7.2' }
                     elseif ($release -ge 461308) { '4.7.1' }
                     elseif ($release -ge 460798) { '4.7'   }
                     elseif ($release -ge 394802) { '4.6.2' }
                     elseif ($release -ge 394254) { '4.6.1' }
                     elseif ($release -ge 393295) { '4.6'   }
                     elseif ($release -ge 379893) { '4.5.2' }
                     elseif ($release -ge 378675) { '4.5.1' }
                     elseif ($release -ge 378389) { '4.5'   }
                     else                          { "4.x (Release DWORD: $release)" }
            $dotNetVersions.Add(".NET Framework $v4ver")
        }
    }
}
if ($dotNetVersions.Count -gt 0) {
    foreach ($v in $dotNetVersions) { Write-Output "  $v" }
} else {
    Write-Output "  (No .NET Framework versions found in registry)"
}
Write-Output ""

# -- CPU (all values via WMI Win32_Processor) ----------------------------------
Write-Output "--- CPU ---"
$cpuList = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
$cpuInfo = $cpuList[0]
$archMap  = @{ 0 = 'x86'; 5 = 'ARM'; 6 = 'Itanium'; 9 = 'x64'; 12 = 'ARM64' }
$archName = if ($archMap.ContainsKey([int]$cpuInfo.Architecture)) {
                $archMap[[int]$cpuInfo.Architecture]
            } else {
                "Unknown ($($cpuInfo.Architecture))"
            }
$totalCores   = ($cpuList | Measure-Object -Property NumberOfCores            -Sum).Sum
$totalLogical = ($cpuList | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$loadPercs    = @($cpuList | Where-Object { $_.LoadPercentage -ne $null } |
                    Select-Object -ExpandProperty LoadPercentage)
$avgLoad      = if ($loadPercs.Count -gt 0) {
                    "$([Math]::Round(($loadPercs | Measure-Object -Average).Average))%"
                } else {
                    'N/A'
                }
Write-Output "Processor         : $($cpuInfo.Name.Trim())"
Write-Output "Architecture      : $archName"
if ($cpuList.Count -gt 1) { Write-Output "Physical CPUs     : $($cpuList.Count)" }
Write-Output "Cores             : $totalCores"
Write-Output "Logical Processors: $totalLogical"
Write-Output "Max Clock Speed   : $($cpuInfo.MaxClockSpeed) MHz"
Write-Output "Total CPU Usage   : $avgLoad"
Write-Output ""

# -- Memory --------------------------------------------------------------------
Write-Output "--- Memory ---"
$totalMB = [Math]::Round($os.TotalVisibleMemorySize / 1024)
$freeMB  = [Math]::Round($os.FreePhysicalMemory     / 1024)
$usedMB  = $totalMB - $freeMB
$pctFree = if ($totalMB -gt 0) { [Math]::Round(($freeMB / $totalMB) * 100, 1) } else { 0 }
$totalGB = [Math]::Round($totalMB / 1024, 1)
$freeGB  = [Math]::Round($freeMB  / 1024, 1)
$usedGB  = [Math]::Round($usedMB  / 1024, 1)
Write-Output "Total RAM         : ${totalMB} MB (${totalGB} GB)"
Write-Output "Free RAM          : ${freeMB} MB (${freeGB} GB)"
Write-Output "Used RAM          : ${usedMB} MB (${usedGB} GB)"
Write-Output "% Free RAM        : ${pctFree}%"
Write-Output ""

Write-Output "Top 3 Processes by Working Set:"
$procFmt = "{0,-30} {1,7} {2,10}"
Write-Output ($procFmt -f 'Name', 'PID', 'WS (MB)')
Write-Output ($procFmt -f ('-' * 30), ('-' * 7), ('-' * 10))
$topProcs = @(
    Get-Process -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 3
)
foreach ($p in $topProcs) {
    $wsMB    = [Math]::Round($p.WorkingSet64 / 1MB, 1)
    $nameStr = $p.Name.Substring(0, [Math]::Min($p.Name.Length, 30))
    Write-Output ($procFmt -f $nameStr, $p.Id, $wsMB)
}
Write-Output ""

Write-Output "Auto-Start Services Currently Not Running:"
$stoppedAuto = @(
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } |
        Sort-Object DisplayName
)
if ($stoppedAuto.Count -gt 0) {
    $svcFmt = "{0,-35} {1,-15} {2}"
    Write-Output ($svcFmt -f 'Service Name', 'Status', 'Display Name')
    Write-Output ($svcFmt -f ('-' * 35), ('-' * 15), ('-' * 50))
    foreach ($svc in $stoppedAuto) {
        $svcName  = $svc.ServiceName.Substring(0, [Math]::Min($svc.ServiceName.Length, 35))
        $dispName = $svc.DisplayName.Substring(0, [Math]::Min($svc.DisplayName.Length, 60))
        Write-Output ($svcFmt -f $svcName, $svc.Status, $dispName)
    }
} else {
    Write-Output "  (None - all automatic services are running)"
}
Write-Output ""

# -- Disk Volumes (Fixed) ------------------------------------------------------
Write-Output "--- Disk Volumes (Fixed) ---"
$disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
if ($disks.Count -gt 0) {
    $dskFmt = "{0,-6} {1,-20} {2,7}  {3,12}  {4,12}"
    Write-Output ($dskFmt -f 'Drive', 'Label', 'Used%', 'Free', 'Total')
    Write-Output ($dskFmt -f ('-' * 5), ('-' * 20), ('-' * 7), ('-' * 12), ('-' * 12))
    foreach ($d in $disks) {
        $tGB     = [Math]::Round($d.Size      / 1GB, 1)
        $fGB     = [Math]::Round($d.FreeSpace / 1GB, 1)
        $usedPct = if ($d.Size -gt 0) {
                       [Math]::Round((($d.Size - $d.FreeSpace) / $d.Size) * 100, 1)
                   } else { 0 }
        $label   = if ($d.VolumeName -and $d.VolumeName -ne '') { $d.VolumeName } else { '(unlabeled)' }
        Write-Output ($dskFmt -f $d.DeviceID, $label, "${usedPct}%", "${fGB} GB", "${tGB} GB")
    }
} else {
    Write-Output "  (No fixed disk volumes found)"
}
Write-Output ""

# -- Network Adapters (IP-Enabled) ---------------------------------------------
Write-Output "--- Network Adapters (IP-Enabled) ---"

# Build a network profile name lookup keyed by interface index (Win8 / Server 2012+)
$netProfiles = @{}
try {
    foreach ($p in @(Get-NetConnectionProfile -ErrorAction Stop)) {
        $netProfiles[[int]$p.InterfaceIndex] = $p.Name
    }
} catch { }

# Win32_NetworkAdapter keyed by WMI Index (same value as Win32_NetworkAdapterConfiguration.Index)
$adapterMap = @{}
foreach ($a in @(Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue)) {
    $adapterMap[[int]$a.Index] = $a
}

$adapterConfigs = @(
    Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop
)
if ($adapterConfigs.Count -eq 0) {
    Write-Output "  (No IP-enabled adapters found)"
} else {
    foreach ($cfg in $adapterConfigs) {
        $adapter = $adapterMap[[int]$cfg.Index]
        $adType  = if ($adapter -and $adapter.PhysicalAdapter) { 'Physical' } else { 'Virtual' }

        # IPv4 only - IPv6 addresses contain colons
        $ipv4List = if ($cfg.IPAddress) {
                        @($cfg.IPAddress | Where-Object { $_ -notlike '*:*' })
                    } else { @() }
        $ips = if ($ipv4List.Count -gt 0) { $ipv4List -join ', ' } else { 'None (IPv4)' }

        # Network profile name: prefer Get-NetConnectionProfile; fall back to
        # the adapter's NetConnectionID (name shown in Network Connections)
        $netName = 'Unknown'
        if ($adapter -and
                $adapter.PSObject.Properties['InterfaceIndex'] -and
                $netProfiles.ContainsKey([int]$adapter.InterfaceIndex)) {
            $netName = $netProfiles[[int]$adapter.InterfaceIndex]
        } elseif ($adapter -and $adapter.NetConnectionID -and $adapter.NetConnectionID -ne '') {
            $netName = $adapter.NetConnectionID
        }

        Write-Output "[$adType] $($cfg.Description)"
        Write-Output "  IP Address(es) : $ips"
        Write-Output "  MAC Address    : $($cfg.MACAddress)"
        Write-Output "  Network        : $netName"
        Write-Output ""
    }
}

# -- Event Logs ----------------------------------------------------------------
# WinEvent Level: 1 = Critical, 3 = Warning  (Level 2 = Error is excluded per request)
$evtFmt = "{0,-20} {1,-8} {2,7}  {3,-40}  {4,-25}"
foreach ($logName in @('System', 'Application')) {
    Write-Output "--- Last 5 Critical/Warning Events ($logName Log) ---"
    try {
        $events = @(
            Get-WinEvent -LogName $logName `
                -FilterXPath '*[System[Level=1 or Level=3]]' `
                -MaxEvents 5 `
                -ErrorAction Stop
        )
        if ($events.Count -gt 0) {
            Write-Output ($evtFmt -f 'TimeCreated', 'Level', 'EventId', 'Source', 'Message (25 chars)')
            Write-Output ($evtFmt -f ('-' * 20), ('-' * 8), ('-' * 7), ('-' * 40), ('-' * 25))
            foreach ($e in $events) {
                $levelLabel = switch ($e.Level) {
                    1       { 'Critical' }
                    3       { 'Warning'  }
                    default { "Lvl$($e.Level)" }
                }
                $timeStr  = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                $srcShort = $e.ProviderName.Substring(0, [Math]::Min($e.ProviderName.Length, 40))
                $rawMsg   = if ($e.Message) { ($e.Message -split "`n")[0].Trim() } else { '' }
                $msgShort = $rawMsg.Substring(0, [Math]::Min($rawMsg.Length, 25))
                Write-Output ($evtFmt -f $timeStr, $levelLabel, $e.Id, $srcShort, $msgShort)
            }
        } else {
            Write-Output "  (No Critical or Warning events found in $logName log)"
        }
    } catch {
        Write-Output "  (Error reading ${logName} log: $($_.Exception.Message))"
    }
    Write-Output ""
}

# -- Total Script Run Time -----------------------------------------------------
$elapsed = (Get-Date) - $scriptStart
Write-Output ("=== Total Script Run Time: {0:F1}s ===" -f $elapsed.TotalSeconds)
