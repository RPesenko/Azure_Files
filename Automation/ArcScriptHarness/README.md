# ArcScriptHarness

A production-grade PowerShell harness for executing a diagnostic (or any operational) script across Azure Arc-enabled Windows servers at scale via the [Azure Connected Machine Run Command API](https://learn.microsoft.com/azure/azure-arc/servers/run-command).

For a lighter-weight, fire-and-forget alternative, see [`ArcCommand.ps1`](../README.md).

---

## Contents

| Script | Description |
|---|---|
| [`ArcScriptHarness.ps1`](#arcscriptharnessps1) | The harness — handles targeting, parallel submission, polling, retry, and reporting |
| [`ArcPatchLevel.ps1`](#arcpatchlevelps1) | Sample diagnostic script — collects patch level, domain, and IP info from each machine |

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

- **Multi-RG and tag-based targeting** — scope runs by resource group, tag key/value pairs, or both
- **Parallel batch submission** — all machines within each batch are submitted concurrently (`ForEach-Object -Parallel`); `BatchSize` controls the ARM write throttle limit
- **Automatic retry** with exponential back-off on HTTP 429 (rate-limit) responses
- **Polling loop** — waits for every machine to reach a terminal state before continuing; polling calls are also parallelised
- **Markdown report** — full per-machine stdout/stderr, exit codes, durations, and a summary table written to a single `.md` file
- **Automatic cleanup** — Run Command ARM resources are deleted in parallel after results are collected (suppressible with `-SkipCleanup`)
- **Script wrapping** — the diagnostic script is automatically wrapped in a `try/catch`; no modifications to your script are required

### Parameters

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `DiagnosticScriptPath` | `string` | ✅ | — | Path to the local `.ps1` script to run on each Arc agent |
| `SubscriptionId` | `string` | ✅ | — | Azure subscription ID containing the target Arc machines |
| `OutputMarkdownPath` | `string` | | `.\ArcDiagResults_<timestamp>.md` | Path to write the Markdown results report |
| `ResourceGroupNames` | `string[]` | | *(all RGs)* | One or more resource group names to restrict targets. If omitted, all connected Windows Arc machines in the subscription are targeted |
| `FilterTags` | `hashtable` | | *(none)* | Tag key/value pairs that machines must **all** carry to be targeted (AND logic). Example: `@{ Environment = 'Prod'; Team = 'Ops' }` |
| `BatchSize` | `int` | | `10` | Machines per batch. Also controls the `ThrottleLimit` for concurrent ARM writes within each batch. Range: 1–50 |
| `BatchDelaySeconds` | `int` | | `2` | Seconds to pause between batches to stay within ARM write rate limits. Range: 0–60 |
| `TimeoutSeconds` | `int` | | `600` | Per-machine timeout in seconds before marking a machine as timed out. Range: 30–3600 |
| `PollIntervalSeconds` | `int` | | `15` | Seconds between polling rounds. Range: 5–300 |
| `SkipCleanup` | `switch` | | `$false` | When set, Run Command ARM resources are **not** deleted after collection. Useful for portal inspection or troubleshooting |

### Execution Phases

| Phase | Description |
|---|---|
| **1 — Validation & Setup** | Validates the script path, checks Az.ConnectedMachine version, authenticates to Azure |
| **2 — Machine Discovery** | Queries all Arc machines in the subscription; applies Connected/Windows, RG, and tag filters |
| **3 — Batch Submission** | Splits targets into batches; submits all machines in each batch in parallel |
| **4 — Poll for Completion** | Polls all pending machines concurrently each round until every machine reaches a terminal state |
| **5 — Cleanup** | Deletes Run Command ARM resources from all targeted machines in parallel (unless `-SkipCleanup`) |
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
    -OutputMarkdownPath    'C:\Reports\PatchLevel.md'
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
    -OutputMarkdownPath    'C:\Reports\Results.md'
```

**Skip cleanup to inspect Run Command resources in the Azure portal:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -SkipCleanup
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

| Data | Source |
|---|---|
| Machine name | `$env:COMPUTERNAME` |
| Domain / workgroup | WMI `Win32_ComputerSystem` |
| IPv4 address(es) | `Get-NetIPAddress` (falls back to DNS resolution on PS 5.1) |
| Latest cumulative update title | Windows Update Agent COM API (`Microsoft.Update.Session`) |
| Latest cumulative update KB number | Parsed from WUA title |
| Latest cumulative update install date | WUA `QueryHistory` |

### WUA Fallback

The Windows Update Agent COM query runs inside a background job with a **90-second timeout** to prevent the script from stalling on machines with a locked or oversized update datastore. If the WUA COM interface is unavailable or the job times out, the script automatically falls back to `Get-HotFix`.

### Requirements

- PowerShell 5.1 or later (executes on the Arc agent, not the machine running the harness)
- No external modules required

### Sample Output

```
=== Arc Patch Level Diagnostic ===
Machine Name      : SERVER01
Domain            : contoso.com
IP Address(es)    : 10.0.1.42, 10.0.1.43

--- Latest Cumulative Update ---
Display Name      : 2025-11 Cumulative Update for Windows Server 2022 (KB5046613)
KB Version        : KB5046613
Install Date      : 2025-11-12
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
