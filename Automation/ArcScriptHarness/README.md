# ArcScriptHarness

A production-grade PowerShell harness for executing a diagnostic (or any operational) script across Azure Arc-enabled Windows servers at scale via the [Azure Connected Machine Run Command API](https://learn.microsoft.com/azure/azure-arc/servers/run-command).

For a lighter-weight, fire-and-forget alternative, see [`ArcCommand.ps1`](../README.md).

---

## Contents

| Script | Description |
|---|---|
| [`ArcScriptHarness.ps1`](#arcscriptharnessps1) | The harness — handles targeting, parallel submission, polling, retry, and reporting |
| [`ArcPatchLevel.ps1`](#arcpatchlevelps1) | Sample diagnostic script — collects machine FQDN and the 5 most recent OS patches |
| [`ArcPatchState.ps1`](#arcpatchstateps1) | Sample diagnostic script — lists all installed Security Updates, Servicing Stack Updates, and OS Updates via DISM |
| [`ArcMachineHealth.ps1`](#arcmachinehealthps1) | Sample diagnostic script — comprehensive health snapshot: system info, .NET, CPU, memory, disk, network, and recent events |
| [`Get-ArcRunCommandOutput.ps1`](#get-arcruncommandoutputps1) | Retrieves existing Run Command output from all connected Arc machines in a resource group and writes a Markdown report |

---

## Prerequisites

| Requirement | Detail |
|---|---|
| **PowerShell** | 7.2 or later (required for `ForEach-Object -Parallel`) |
| **Az.ConnectedMachine** | Version **0.4.0** or later: `Install-Module Az.ConnectedMachine -MinimumVersion 0.4.0` |
| **Az.Accounts** | Included with the Az module; required for authentication |
| **Arc agent** | Version **1.33+** on each target machine (Run Command support) |
| **Azure RBAC** | **Azure Connected Machine Resource Administrator** (or a custom role granting `Microsoft.HybridCompute/machines/runCommands/write`) on the target machines |

---

## ArcScriptHarness.ps1

### Purpose

Executes a local PowerShell script against Azure Arc-enabled Windows servers with full lifecycle management. Key features:

- **Flexible targeting** — scope runs by resource group, tag key/value pairs, an explicit machine name/FQDN list, or any combination of the three
- **Parallel batch submission** — all machines within each batch are submitted concurrently (`ForEach-Object -Parallel`); `BatchSize` controls the ARM write throttle limit
- **Automatic retry** with exponential back-off on HTTP 429 (rate-limit) responses
- **Polling loop** — waits for every machine to reach a terminal state before continuing; polling calls are also parallelised
- **Markdown report** — full per-machine stdout/stderr, exit codes, durations, and a summary table written to a single `.md` file
- **Smart reuse** — Run Command ARM resources are retained by default and reused on subsequent runs. A SHA-256 script hash is compared on each run: `Create` for new resources, `ReRun` when the script is unchanged, `Update` when the script has changed
- **Optional cleanup** — Pass `-Cleanup` to delete Run Command resources after collection
- **Script wrapping** — the diagnostic script is automatically wrapped in a `try/catch`; no modifications to your script are required

### Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `DiagnosticScriptPath` | `string` | ✅ | — | Path to the local `.ps1` script to run on each Arc agent |
| `SubscriptionId` | `string` | ✅ | — | Azure subscription ID containing the target Arc machines |
| `OutputPath` | `string` | | `.\ArcDiagResults_<timestamp>.md` in the current directory | Path to write the Markdown results report. If a directory path is supplied, the default timestamped filename is generated inside that directory |
| `ResourceGroupNames` | `string[]` | | *(all RGs)* | One or more resource group names to restrict targets. If omitted, all connected Windows Arc machines in the subscription are targeted |
| `FilterTags` | `hashtable` | | *(none)* | Tag key/value pairs that machines must **all** carry to be targeted (AND logic). Example: `@{ Environment = 'Prod'; Team = 'Ops' }` |
| `FilterFQDNs` | `string[]` | | *(none)* | Explicit list of FQDNs to target (case-insensitive). Machines not in the list are excluded. Useful for re-running against machines that failed or timed out in a previous pass without re-processing machines that already succeeded. Example: `'server01.contoso.com','server02.contoso.com'` |
| `MachineName` | `string[]` | | *(none)* | One or more machine names to target. Each entry is matched against the machine's short name (e.g. `SERVER01`) **and** its FQDN — either form works in the same list. Applied in addition to any other active filters. Example: `'SERVER01','server02.contoso.com'` |
| `BatchSize` | `int` | | `10` | Machines per batch. Also controls the `ThrottleLimit` for concurrent ARM writes within each batch. Range: 1–50 |
| `BatchDelaySeconds` | `int` | | `2` | Seconds to pause between batches to stay within ARM write rate limits. Range: 0–60 |
| `TimeoutSeconds` | `int` | | `600` | Per-machine timeout in seconds before marking a machine as timed out. Range: 30–3600 |
| `PollIntervalSeconds` | `int` | | `15` | Seconds between polling rounds. Range: 5–300 |
| `Cleanup` | `switch` | | `$false` | When set, Run Command ARM resources are deleted after collection. By default resources are retained and reused on subsequent runs |

### Execution Phases

| Phase | Description |
|---|---|
| **1 — Validation & Setup** | Validates the script path, checks Az.ConnectedMachine version, authenticates to Azure |
| **2 — Machine Discovery** | Queries all Arc machines in the subscription; applies Connected/Windows, RG, tag, FQDN, and machine name filters |
| **3 — Batch Submission** | Splits targets into batches; submits all machines in each batch in parallel |
| **4 — Poll for Completion** | Polls all pending machines concurrently each round until every machine reaches a terminal state. Transient `management.azure.com` connectivity errors are caught and retried silently without failing the run |
| **5 — Cleanup** | Deletes Run Command ARM resources from targeted machines in parallel. Only runs when `-Cleanup` is specified; by default resources are retained for reuse |
| **6 — Markdown Report** | Writes a formatted report with summary statistics, per-machine output, and skipped machines |

### Usage Examples

**Basic — all connected Windows machines in a subscription:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Filter to specific resource groups and save report:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath  .\ArcPatchLevel.ps1 `
    -SubscriptionId        'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ResourceGroupNames    'RG-Prod-East', 'RG-Prod-West' `
    -OutputPath            'C:\Reports\PatchLevel.md'
```

**Write report to a directory (filename auto-generated):**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -OutputPath           'C:\Temp\Diags\'
```

**Filter by tags:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -FilterTags           @{ Environment = 'Production'; Team = 'Ops' }
```

**Large estate — increase batch size, adjust timeout:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath  .\ArcPatchLevel.ps1 `
    -SubscriptionId        'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -BatchSize             25 `
    -BatchDelaySeconds     5 `
    -TimeoutSeconds        900 `
    -OutputPath            'C:\Reports\Results.md'
```

**Target specific machines by FQDN (e.g. re-run against machines that failed or timed out):**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -FilterFQDNs          'server01.contoso.com', 'server02.contoso.com'
```

**Target a single machine by name:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -MachineName          'SERVER01'
```

**Target multiple machines — short names and FQDNs can be mixed:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -MachineName          'SERVER01', 'server02.contoso.com', 'SERVER03'
```

**Force cleanup of Run Command ARM resources after collection:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -Cleanup
```

### Output — Markdown Report

The generated report contains:

- **Header table** — script name, run timestamp, run command name, subscription, total duration, active filters, cleanup status
- **Summary** — count of successes, script errors, timeouts, submission errors, and skipped machines
- **Machine Results table** — one row per machine with status, exit code, stdout byte count, and duration
- **Submission Errors** — details for any machines that failed to submit
- **Per-Machine Output** — full stdout and stderr for each completed machine, with a warning if output approached the 4 KB API limit
- **Skipped Machines** — machines excluded due to offline status or non-Windows OS

### Writing a Compatible Diagnostic Script

The harness wraps your script in a `try/catch` automatically. Follow these conventions:

```powershell
#Requires -Version 5.1   # Minimum version supported by Arc agents; 7.x also works

# Use Write-Output for any data that should appear in the report
Write-Output "Result: $someValue"

# Write-Error and thrown exceptions are captured in the stderr section of the report.
# No changes are needed — the harness handles error capture automatically.
```

> **Output size limit:** Run Command inline output is capped at approximately **4 KB** per machine by the Azure API. The report flags any machine whose output meets or exceeds this threshold. For larger output, extend the harness to use `-OutputBlobUri` with an Azure Storage append blob SAS URI.

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
    -DiagnosticScriptPath .\ArcPatchLevel.ps1 `
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
    -DiagnosticScriptPath .\ArcPatchState.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Locally for testing (requires an elevated session):**
```powershell
.\ArcPatchState.ps1
```

---

## Get-ArcRunCommandOutput.ps1

### Purpose

A standalone read-only script that queries the current output of an existing named Run Command resource from every **Connected** Arc machine in a resource group and compiles the results into a single Markdown file.

This is intended as a lightweight companion to `ArcScriptHarness.ps1` — use it to pull results from a previous harness run without resubmitting the diagnostic script.

### Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `ResourceGroupName` | `string` | ✅ | — | Resource group containing the Arc machines |
| `RunCommandName` | `string` | ✅ | — | Name of the Run Command ARM resource to query on each machine (e.g. `ArcDiag-ArcPatchLevel`) |
| `OutputPath` | `string` | | `ArcRunCommandOutput_<timestamp>.md` next to the script | Path for the output Markdown file. If a directory is supplied, the default timestamped filename is generated inside that directory |

### Prerequisites

- PowerShell 5.1 or later
- `Az.ConnectedMachine` module installed
- Active Azure context (`Connect-AzAccount` already run)

### Behaviour

- Only targets machines with `Status -eq 'Connected'`; offline machines are silently skipped
- If a machine does not have the named Run Command resource, the report shows `*Error: ...*` for that machine instead of halting
- Output is sequential (no parallel calls) — safe for small to medium resource groups

### Per-Machine Report Format

Each machine section in the generated Markdown report contains:

```
## MACHINENAME

End Time: 2026-07-01 12:28:47
Execution Time: 42s
Exit Code: 0

```
<InstanceViewOutput content>
```
```

### Usage Examples

**Query all connected machines in a resource group:**
```powershell
.\Get-ArcRunCommandOutput.ps1 `
    -ResourceGroupName 'MyRG' `
    -RunCommandName    'ArcDiag-ArcPatchLevel'
```

**Write output to a specific directory:**
```powershell
.\Get-ArcRunCommandOutput.ps1 `
    -ResourceGroupName 'MyRG' `
    -RunCommandName    'ArcDiag-ArcPatchLevel' `
    -OutputPath        'C:\Temp\Diags\'
```

**Write output to a specific file:**
```powershell
.\Get-ArcRunCommandOutput.ps1 `
    -ResourceGroupName 'MyRG' `
    -RunCommandName    'ArcDiag-ArcPatchLevel' `
    -OutputPath        'C:\Reports\output.md'
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
    -DiagnosticScriptPath .\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Target a specific machine:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -MachineName          'SERVER01'
```

**Locally for testing (runs against the current machine):**
```powershell
.\ArcMachineHealth.ps1
```
