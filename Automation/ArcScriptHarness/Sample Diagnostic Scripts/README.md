# Sample Diagnostic Scripts

Ready-to-use diagnostic scripts for [`ArcScriptHarness.ps1`](../README.md). Each script is designed to run on Arc-enabled Windows servers via the Run Command API and produces structured plain-text output that the harness captures in its Markdown report.

---

## Contents

| Script | Description |
|---|---|
| [`ArcPatchLevel.ps1`](#arcpatchlevelps1) | Collects machine FQDN and the 5 most recent OS patches |
| [`ArcPatchState.ps1`](#arcpatchstateps1) | Lists all installed Security Updates, Servicing Stack Updates, and OS Updates via DISM |
| [`ArcMachineHealth.ps1`](#arcmachinehealthps1) | Comprehensive health snapshot: system info, .NET, CPU, memory, disk, network, and recent events |

---

## ArcPatchLevel.ps1

### Purpose

A ready-to-use diagnostic script for `ArcScriptHarness.ps1` that collects the following information from each Arc-enabled Windows machine:

> **Version 1.1.0** — Simplified to report the machine FQDN only. Machine name, domain, and IP address fields have been removed.

| Data | Source |
|---|---|
| Machine FQDN | `[System.Net.Dns]::GetHostEntry('').HostName` |
| 5 most recent OS update titles | Windows Update Agent COM API (`Microsoft.Update.Session`) |
| OS update KB numbers | Parsed from WUA title |
| OS update install dates | WUA `QueryHistory` |
| OS update result codes | WUA `QueryHistory` (2=Success, 3=Partial, 4=Failed, 5=Aborted) |

Only updates that match an OS update phrase are considered. Microsoft uses two naming conventions:

- **Old:** `... for Windows Server 2016/2019/2022/2025` or `... for Windows 10/11`
- **New (Windows Server 2022+):** `... for Microsoft server operating system version 21H2`

Both are matched by the pattern `for (?:Windows (?:Server|\d)|Microsoft server operating system)`. The `YYYY-MM` date prefix is intentionally **not** used as a match criterion — Microsoft now applies it to non-OS updates (e.g. Defender platform updates) as well, making it an unreliable indicator.

| Pattern | Matches | Excluded by |
|---|---|---|
| `for Windows (?:Server\|\d)` | `for Windows Server 2016/2019/2022/2025`, `for Windows 10`, `for Windows 11` | Anything else |
| `for Microsoft server operating system` | `for Microsoft server operating system version 21H2` (new naming for Windows Server 2022+) | Anything else |

Combined, these exclude `for Windows Defender` and `for Microsoft Defender` — neither `Defender` token matches either branch of the alternation.

### WUA Fallback

The Windows Update Agent COM query runs inside a background job with a **90-second timeout** to prevent the script from stalling on machines with a locked or oversized update datastore. If the WUA COM interface is unavailable or the job times out, the script automatically falls back to `Get-HotFix`, which returns up to 5 of the most recently installed hotfixes. Result codes are shown as `Installed` in the fallback case since `Get-HotFix` only surfaces patches that were successfully applied.

### Requirements

- PowerShell 5.1 or later (executes on the Arc agent, not the machine running the harness)
- No external modules required

### Sample Output

```
=== Arc Patch Level Diagnostic ===
Script Version    : 1.1.0
FQDN              : server01.contoso.com

--- 5 Most Recent OS Updates (WUA) ---
KB            Date         Result     Title
------------  ----------   ---------  ------------------------------------------------------------
KB5063060     2026-06-11   Success    2026-06 Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5063060)
KB5058385     2026-05-14   Success    2026-05 Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5058385)
KB5055526     2026-04-08   Success    2026-04 Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5055526)
KB5053603     2026-03-11   Success    2026-03 Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5053603)
KB5052000     2026-02-11   Success    2026-02 Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5052000)
```

### Usage

**Via the harness (recommended):**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\Sample Diagnostic Scripts\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Locally for testing (runs against the current machine):**
```powershell
.\ArcPatchLevel.ps1
```

---

## ArcPatchState.ps1

### Purpose

A ready-to-use diagnostic script for `ArcScriptHarness.ps1` that queries the local DISM package store (`dism /online /get-packages`) and reports all installed patches that fall into one of three categories:

| Category | Filter logic |
|---|---|
| **Security Update** | DISM `Release Type` = `Security Update` |
| **Servicing Stack Update** | DISM `Release Type` = `Update` AND Package Identity contains `ServicingStack` |
| **OS Update** | DISM `Release Type` = `Update` AND Package Identity does **not** contain `ServicingStack` (covers Cumulative/LCU patches) |

Results are sorted by install date descending in a single flat table. No record-count limit is applied — all matching installed packages are returned.

### DISM Background Job

The DISM command is run inside a background job with a **120-second timeout** to prevent the script from stalling on machines with a large package store or a locked CBS database. If the job does not complete within the timeout, the machine is reported with a timeout message and no package data.

### Requirements

- PowerShell 5.1 or later (executes on the Arc agent)
- DISM requires elevation — satisfied automatically when run via Arc Run Command (agent runs as SYSTEM)
- No external modules required

### Sample Output

```
=== Arc Patch State Diagnostic ===
Script Version    : 1.0.0
FQDN              : server01.contoso.com
Data Source       : DISM

KB            Install Date Package Identity
------------  ------------ ------------------------------------------------------------
KB5063060     2026-06-11   Package_for_RU_KB5063060~31bf3856ad364e35~amd64~~10.0.20348.1
KB5058385     2026-05-14   Package_for_RU_KB5058385~31bf3856ad364e35~amd64~~10.0.20348.1
KB5034439     2026-02-11   Microsoft-Windows-ServicingStack-Package~31bf3856ad364e35~amd64~~10.0.20348.1
KB5028948     2024-07-09   Package_for_KB5028948~31bf3856ad364e35~amd64~~10.0.20348.1

Total matching packages: 4
```

### Usage

**Via the harness (recommended):**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\Sample Diagnostic Scripts\ArcPatchState.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Locally for testing (requires an elevated session):**
```powershell
.\ArcPatchState.ps1
```

---

## ArcMachineHealth.ps1

### Purpose

A comprehensive health snapshot diagnostic for `ArcScriptHarness.ps1`. Collects the following from each Arc-enabled Windows machine:

| Data | Source |
|---|---|
| Machine name, logon domain, OS version and build | `$env:COMPUTERNAME`, WMI `Win32_ComputerSystem`, WMI `Win32_OperatingSystem` |
| .NET Framework versions installed (1.x – 4.8.1) | Registry `HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP` |
| CPU model, architecture, physical/logical cores, clock speed, total usage | WMI `Win32_Processor` |
| Total, free, used RAM and % free | WMI `Win32_OperatingSystem` |
| Top 20 processes by working set (name, PID, MB) | `Get-Process` |
| Automatic-start services not currently running | `Get-Service` |
| Fixed disk volumes: label, % used, free space, total size | WMI `Win32_LogicalDisk` (DriveType=3) |
| IP-enabled network adapters (Physical/Virtual): IPv4, MAC, network name | WMI `Win32_NetworkAdapterConfiguration`, `Win32_NetworkAdapter`, `Get-NetConnectionProfile` |
| Last 20 Critical (Level 1) and Warning (Level 3) events — System log | `Get-WinEvent` with XPath filter |
| Last 20 Critical (Level 1) and Warning (Level 3) events — Application log | `Get-WinEvent` with XPath filter |
| Total script run time | `Get-Date` delta |

> **Output size:** This script routinely produces 6–10 KB of output per machine, which exceeds the 4 KB inline Run Command limit on complex machines. `ArcScriptHarness.ps1` flags truncation automatically in the report.

### Requirements

- PowerShell 5.1 or later (executes on the Arc agent)
- No external modules required

### Sample Output

```
=== Arc Machine Health Diagnostic ===
Script Version    : 1.0.0
Run Started       : 2026-06-26 09:15:00

--- System Information ---
Machine Name      : SERVER01
Logon Domain      : contoso.com
OS Version        : Windows Server 2022 Datacenter (Build 20348)

--- .NET Framework Versions ---
  .NET Framework 3.5
  .NET Framework 4.8.1

--- CPU ---
Processor         : Intel(R) Xeon(R) Gold 6154 CPU @ 3.00GHz
Architecture      : x64
Cores             : 8
Logical Processors: 16
Max Clock Speed   : 3000 MHz
Total CPU Usage   : 12%

--- Memory ---
Total RAM         : 32768 MB (32.0 GB)
Free RAM          : 24576 MB (24.0 GB)
Used RAM          : 8192 MB (8.0 GB)
% Free RAM        : 75.0%

Top 20 Processes by Working Set:
Name                           PID    WS (MB)
------------------------------  ------  ----------
svchost                         1234       512.3
w3wp                            5678       384.1
...

Auto-Start Services Currently Not Running:
Service Name                        Status           Display Name
-----------------------------------  ---------------  --------------------------------------------------
wuauserv                            Stopped          Windows Update

--- Disk Volumes (Fixed) ---
Drive  Label                Used%       Free          Total
-----  --------------------  -------  ------------  ------------
C:     Windows               45.2%      54.3 GB        99.0 GB
D:     Data                  28.1%     143.9 GB       200.0 GB

--- Network Adapters (IP-Enabled) ---
[Physical] Microsoft Hyper-V Network Adapter
  IP Address(es) : 10.0.1.42
  MAC Address    : 00-15-5D-AB-CD-EF
  Network        : Contoso Corp Network

--- Last 20 Critical/Warning Events (System Log) ---
TimeCreated          Level     EventId  Source                        Message
--------------------  --------  -------  ----------------------------  --------------------------------------------------
2026-06-25 03:12:44  Warning      4226  Tcpip                         TCP/IP has reached the security limit...
...

=== Total Script Run Time: 4.2s ===
```

### Usage

**Via the harness (recommended):**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\Sample Diagnostic Scripts\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Target a specific machine:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\Sample Diagnostic Scripts\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -MachineName          'SERVER01'
```

**Locally for testing (runs against the current machine):**
```powershell
.\ArcMachineHealth.ps1
```
