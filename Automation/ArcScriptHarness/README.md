# ArcScriptHarness

A production-grade PowerShell harness for executing a diagnostic (or any operational) script across Azure Arc-enabled Windows servers at scale via the [Azure Connected Machine Run Command API](https://learn.microsoft.com/azure/azure-arc/servers/run-command).

For a lighter-weight, fire-and-forget alternative, see [`ArcCommand.ps1`](../README.md).

---

## Contents

| Script | Description |
|---|---|
| [`ArcScriptHarness.ps1`](#arcscriptharnessps1) | The harness — handles targeting, parallel submission, polling, retry, and reporting |
| [`Get-ArcRunCommandOutput.ps1`](#get-arcruncommandoutputps1) | Retrieves existing Run Command output from all connected Arc machines in a resource group and writes a Markdown report |
| [`SampleDiagnosticScripts/`](SampleDiagnosticScripts/README.md) | Three sample diagnostic scripts: `ArcPatchLevel.ps1`, `ArcPatchState.ps1`, `ArcMachineHealth.ps1` — see subfolder README |

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
    -DiagnosticScriptPath .\SampleDiagnosticScripts\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Filter to specific resource groups and save report with a specific name:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath  .\SampleDiagnosticScripts\ArcPatchLevel.ps1 `
    -SubscriptionId        'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ResourceGroupNames    'RG-Prod-East', 'RG-Prod-West' `
    -OutputPath            'C:\Reports\PatchLevel_Tues_pm.md'
```

**Write report to a directory (default filename auto-generated):**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\SampleDiagnosticScripts\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -OutputPath           'C:\Temp\Diags\'
```

**Filter by tags:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\SampleDiagnosticScripts\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -FilterTags           @{ Environment = 'Production'; Team = 'Ops' }
```

**Large estate — increase batch size, adjust timeout:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath  .\SampleDiagnosticScripts\ArcPatchLevel.ps1 `
    -SubscriptionId        'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -BatchSize             25 `
    -BatchDelaySeconds     5 `
    -TimeoutSeconds        900 `
    -OutputPath            'C:\Reports\Results.md'
```

**Target specific machines by FQDN (e.g. re-run against machines that failed or timed out):**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\SampleDiagnosticScripts\ArcPatchLevel.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -FilterFQDNs          'server01.contoso.com', 'server02.contoso.com'
```

**Target a single machine by name:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\SampleDiagnosticScripts\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -MachineName          'SERVER01'
```

**Target multiple machines — short names and FQDNs can be mixed:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\SampleDiagnosticScripts\ArcMachineHealth.ps1 `
    -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -MachineName          'SERVER01', 'server02.contoso.com', 'SERVER03'
```

**Force cleanup of Run Command ARM resources after collection:**
```powershell
.\ArcScriptHarness.ps1 `
    -DiagnosticScriptPath .\SampleDiagnosticScripts\ArcPatchLevel.ps1 `
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

<InstanceViewOutput content>
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
