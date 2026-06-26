# ArcCommand.ps1

A lightweight, self-contained PowerShell script for executing a script across all Azure Arc-enabled Windows servers in a single resource group via the [Azure Connected Machine Run Command API](https://learn.microsoft.com/azure/azure-arc/servers/run-command).

For a full-featured harness with output capture, polling, retry logic, and a Markdown report, see [`ArcScriptHarness/README.md`](ArcScriptHarness/README.md).

---

## Prerequisites

| Requirement | Detail |
|---|---|
| **PowerShell** | 7.0 or later |
| **Az.ConnectedMachine** | Version **0.4.0** or later: `Install-Module Az.ConnectedMachine -MinimumVersion 0.4.0` |
| **Az.Accounts** | Included with the Az module; required for authentication |
| **Arc agent** | Version **1.33+** on each target machine (Run Command support) |
| **Azure RBAC** | **Azure Connected Machine Resource Administrator** (or a custom role granting `Microsoft.HybridCompute/machines/runCommands/write`) on the target machines |

---

## Purpose

Submits a local PowerShell script to every connected Arc machine in a resource group in parallel and exports a submission-result summary to CSV. 

This script uses `AsyncExecution` (fire-and-forget) — it submits the run command to each machine concurrently but does **not** poll for results or collect script output. Use `ArcScriptHarness.ps1` when you need to capture output or verify that the script completed successfully on each machine.

---

## Configuration

Edit the variables at the top of the script before running:

```powershell
$scriptPath        = "C:\Temp\test.ps1"                   # Path to the script to run on each Arc machine
$resourceGroupName = "MyRG"                                # Resource group containing the target Arc machines
$outputPath        = "C:\Temp\Arc_RunCommand_Results.csv"  # Where to write the CSV results summary
$throttleLimit     = 20                                    # Max concurrent submissions (default: 20)
```

---

## Usage

```powershell
# 1. Authenticate to Azure (if not already signed in)
Connect-AzAccount

# 2. Set the target subscription
Set-AzContext -SubscriptionId '<your-subscription-id>'

# 3. Run the script
.\ArcCommand.ps1

# 4. Add -Verbose for detailed per-machine progress
.\ArcCommand.ps1 -Verbose
```

---

## Output

A CSV file at `$outputPath` with one row per machine:

| Column | Description |
|---|---|
| `MachineName` | Arc machine name |
| `Status` | `Success` or `Failed` |
| `StartTime` | Submission timestamp |
| `EndTime` | Completion timestamp |
| `Duration` | Elapsed seconds |
| `Error` | Error message (on failure) |

> **Note:** Because `AsyncExecution` is used, `Status = Success` means the run command was **submitted** successfully, not that the script running on the machine completed successfully.
