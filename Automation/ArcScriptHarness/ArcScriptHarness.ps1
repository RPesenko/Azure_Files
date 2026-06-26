#Requires -Version 5.1
<#
.SYNOPSIS
    Sends a diagnostic PowerShell script to Azure Arc-enabled Windows servers and logs results to Markdown.

.DESCRIPTION
    Reads a local diagnostic script, submits it to each target Arc agent via the Azure Connected Machine
    Run Command API, polls for completion, collects output, and writes a formatted Markdown report.

    The harness wraps your diagnostic script in a try/catch block automatically — no changes to your
    script are required. Use Write-Output in your diagnostic script for results that should appear
    in the report. Write-Error and thrown exceptions are captured in the stderr section.

    PREREQUISITES
    - Az.ConnectedMachine module 0.4.0+:  Install-Module Az.ConnectedMachine -MinimumVersion 0.4.0
    - Az.Accounts module (for authentication)
    - Arc Connected Machine agent version 1.33+ on each target machine
    - RBAC: Azure Connected Machine Resource Administrator role (or a role that grants
      Microsoft.HybridCompute/machines/runCommands/write) on target machines

    OUTPUT CAPTURE
    Run Command inline output is limited to approximately 4 KB per machine. Output at or above
    this limit will be flagged in the report. For larger output, extend this script to use
    -OutputBlobUri with an Azure Storage append blob SAS URI.

.PARAMETER DiagnosticScriptPath
    Path to the local .ps1 diagnostic script to run on each Arc agent.

.PARAMETER SubscriptionId
    The Azure subscription ID containing the Arc agents.

.PARAMETER OutputMarkdownPath
    Path to write the Markdown results report.
    Defaults to .\ArcDiagResults_<timestamp>.md in the current directory.

.PARAMETER ResourceGroupNames
    Optional. One or more resource group names to restrict the target machines.
    If omitted, all connected Windows Arc machines in the subscription are targeted.

.PARAMETER FilterTags
    Optional. A hashtable of tag key/value pairs. Machines must have ALL specified tags
    (AND logic) to be targeted.
    Example: @{ Environment = 'Prod'; Team = 'Ops' }

.PARAMETER BatchSize
    Number of machines to submit per batch. Default: 10.
    Keeps ARM write operations within the rate-limit refill rate (~10/sec).

.PARAMETER BatchDelaySeconds
    Seconds to wait between submission batches. Default: 2.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for a single machine's script to complete before marking
    it as timed out. Default: 600 (10 minutes).

.PARAMETER PollIntervalSeconds
    Seconds to wait between polling rounds. Default: 15.

.PARAMETER SkipCleanup
    When specified, Run Command ARM resources created on each machine are not deleted
    after results are collected. Useful for auditing or troubleshooting in the portal.

.EXAMPLE
    .\ArcScriptHarness.ps1 `
        -DiagnosticScriptPath .\Get-DiskHealth.ps1 `
        -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    .\ArcScriptHarness.ps1 `
        -DiagnosticScriptPath  .\Get-DiskHealth.ps1 `
        -SubscriptionId        'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ResourceGroupNames    'RG-Prod-East','RG-Prod-West' `
        -FilterTags            @{ Environment = 'Production' } `
        -OutputMarkdownPath    'C:\Reports\DiskHealth.md' `
        -TimeoutSeconds        300

.EXAMPLE
    .\ArcScriptHarness.ps1 `
        -DiagnosticScriptPath .\Collect-EventLogs.ps1 `
        -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -SkipCleanup

.NOTES
    Run command name format: ArcDiag-yyyyMMddHHmmss (22 chars, within the 36-char API limit).
    Re-running the harness within the same second against the same machines will cause a name
    collision. In normal use this cannot occur.
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) { throw "File not found: $_" }
        if ([System.IO.Path]::GetExtension($_) -ne '.ps1') { throw "File must be a .ps1 script: $_" }
        $true
    })]
    [string] $DiagnosticScriptPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $SubscriptionId,

    [Parameter()]
    [string] $OutputMarkdownPath,

    [Parameter()]
    [string[]] $ResourceGroupNames,

    [Parameter()]
    [hashtable] $FilterTags,

    [Parameter()]
    [ValidateRange(1, 50)]
    [int] $BatchSize = 10,

    [Parameter()]
    [ValidateRange(0, 60)]
    [int] $BatchDelaySeconds = 2,

    [Parameter()]
    [ValidateRange(30, 3600)]
    [int] $TimeoutSeconds = 600,

    [Parameter()]
    [ValidateRange(5, 300)]
    [int] $PollIntervalSeconds = 15,

    [switch] $SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
function Write-Status {
    param([string] $Message, [string] $Color = 'Cyan')
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -ForegroundColor $Color
}

function Get-MachineTags {
    # Az.ConnectedMachine returns tags in a .Tag property (singular); some SDK
    # versions surface it as .Tags. This helper normalises both.
    param($Machine)
    if ($Machine.PSObject.Properties['Tags'] -and $null -ne $Machine.Tags) { return $Machine.Tags }
    if ($Machine.PSObject.Properties['Tag']  -and $null -ne $Machine.Tag)  { return $Machine.Tag  }
    return @{}
}

# Unique key for a machine that is stable even when two RGs share a machine name
function Get-MachineKey { param($Machine) "$($Machine.ResourceGroupName)/$($Machine.Name)" }

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Validation & Setup
# ──────────────────────────────────────────────────────────────────────────────
Write-Status '─── Phase 1: Validation & Setup ──────────────────────────────' 'White'

$script:HarnessStart   = Get-Date
$script:RunTimestamp   = Get-Date -Format 'yyyyMMddHHmmss'
$script:RunCommandName = "ArcDiag-$($script:RunTimestamp)"   # 22 chars — within the 36-char API limit

# 1a. Resolve and read diagnostic script
$DiagnosticScriptPath = (Resolve-Path -Path $DiagnosticScriptPath).Path
$rawScript            = Get-Content -Path $DiagnosticScriptPath -Raw -Encoding UTF8

# Wrap in try/catch so any diagnostic script surfaces errors cleanly without modification
$wrappedScript = @"
try {
$rawScript
} catch {
    Write-Error "UNHANDLED EXCEPTION: `$(`$_.Exception.Message)"
    exit 1
}
"@

$scriptBytes = [System.Text.Encoding]::UTF8.GetByteCount($wrappedScript)
Write-Status "Diagnostic script  : $DiagnosticScriptPath ($scriptBytes bytes)"

# 1b. Default output path
if (-not $OutputMarkdownPath) {
    $OutputMarkdownPath = Join-Path (Get-Location).Path "ArcDiagResults_$($script:RunTimestamp).md"
}
Write-Status "Report path        : $OutputMarkdownPath"

# 1c. Check Az.ConnectedMachine module
$minModuleVersion = [version]'0.4.0'
$connModule = Get-Module -ListAvailable -Name 'Az.ConnectedMachine' |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $connModule) {
    throw (
        "Az.ConnectedMachine module not found.`n" +
        "Install it with:  Install-Module Az.ConnectedMachine -MinimumVersion 0.4.0"
    )
}
if ($connModule.Version -lt $minModuleVersion) {
    throw (
        "Az.ConnectedMachine $($connModule.Version) is below minimum required $minModuleVersion.`n" +
        "Update with:  Update-Module Az.ConnectedMachine"
    )
}
Write-Status "Az.ConnectedMachine: v$($connModule.Version)"

# 1d. Azure authentication — ensure context targets the correct subscription
$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext -or $azContext.Subscription.Id -ne $SubscriptionId) {
    Write-Status 'No matching Azure context found — initiating sign-in...' 'Yellow'
    Connect-AzAccount -SubscriptionId $SubscriptionId | Out-Null
    $azContext = Get-AzContext
}
Write-Status "Azure account      : $($azContext.Account.Id)"
Write-Status "Subscription       : $($azContext.Subscription.Name) ($SubscriptionId)"
Write-Status "Run command name   : $($script:RunCommandName)"

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Machine Discovery
# ──────────────────────────────────────────────────────────────────────────────
Write-Status '─── Phase 2: Machine Discovery ───────────────────────────────' 'White'
Write-Status 'Querying Arc machines in subscription...'

$allMachines = @(Get-AzConnectedMachine -SubscriptionId $SubscriptionId)
Write-Status "$($allMachines.Count) total Arc machine(s) found in subscription."

# Start with Connected Windows machines
$candidates = $allMachines | Where-Object { $_.Status -eq 'Connected' -and $_.OSName -eq 'windows' }

# Collect skipped machines (offline or non-Windows) before additional filters
$skippedMachines = @($allMachines | Where-Object { $_.Status -ne 'Connected' -or $_.OSName -ne 'windows' })

# Resource group filter
if ($ResourceGroupNames -and $ResourceGroupNames.Count -gt 0) {
    # Normalise to lowercase for case-insensitive match
    $rgNamesLower = $ResourceGroupNames | ForEach-Object { $_.ToLower() }
    $candidates   = $candidates | Where-Object { $_.ResourceGroupName.ToLower() -in $rgNamesLower }
    Write-Status "RG filter          : $($ResourceGroupNames -join ', ')"
}

# Tag filter — machine must carry ALL specified tag key/value pairs
if ($FilterTags -and $FilterTags.Count -gt 0) {
    $candidates = $candidates | Where-Object {
        $machineTags = Get-MachineTags -Machine $_
        $allMatch    = $true
        foreach ($key in $FilterTags.Keys) {
            if ($machineTags[$key] -ne $FilterTags[$key]) {
                $allMatch = $false
                break
            }
        }
        $allMatch
    }
    $tagDesc = ($FilterTags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
    Write-Status "Tag filter         : $tagDesc"
}

$targetMachines = @($candidates)

Write-Status ("Target: {0} | Skipped (offline/non-Win): {1} | Filtered out: {2}" -f
    $targetMachines.Count,
    $skippedMachines.Count,
    ($allMachines.Count - $targetMachines.Count - $skippedMachines.Count)
) 'Cyan'

if ($targetMachines.Count -eq 0) {
    Write-Status 'No machines match the specified criteria. Nothing to do.' 'Yellow'
    exit 0
}

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Batch Submission
# ──────────────────────────────────────────────────────────────────────────────
Write-Status '─── Phase 3: Batch Submission ────────────────────────────────' 'White'
Write-Status "BatchSize: $BatchSize | Delay: ${BatchDelaySeconds}s | Machine timeout: ${TimeoutSeconds}s"

# $machineState — keyed by "RG/MachineName" to handle duplicate names across RGs
# Each entry: @{ Machine; SubmittedAt; CompletedAt; Status; Result }
$machineState     = [ordered] @{}
$submissionErrors = [System.Collections.Generic.List[pscustomobject]]::new()

# Build batches
$batches = [System.Collections.Generic.List[object[]]]::new()
for ($i = 0; $i -lt $targetMachines.Count; $i += $BatchSize) {
    $end = [Math]::Min($i + $BatchSize - 1, $targetMachines.Count - 1)
    $batches.Add(@($targetMachines[$i..$end]))
}

$batchNum = 0
foreach ($batch in $batches) {
    $batchNum++
    Write-Status "Submitting batch $batchNum / $($batches.Count) ($($batch.Count) machine(s))..."

    foreach ($machine in $batch) {
        $mKey = Get-MachineKey -Machine $machine
        $machineState[$mKey] = @{
            Machine     = $machine
            SubmittedAt = $null
            CompletedAt = $null
            Status      = 'Pending'
            Result      = $null
        }

        $maxRetries = 3
        $attempt    = 0
        $submitted  = $false

        while ($attempt -lt $maxRetries -and -not $submitted) {
            $attempt++
            try {
                $null = New-AzConnectedMachineRunCommand `
                    -SubscriptionId    $SubscriptionId `
                    -ResourceGroupName $machine.ResourceGroupName `
                    -MachineName       $machine.Name `
                    -Location          $machine.Location `
                    -RunCommandName    $script:RunCommandName `
                    -SourceScript      $wrappedScript `
                    -AsyncExecution `
                    -TimeoutInSecond   $TimeoutSeconds

                $machineState[$mKey].SubmittedAt = Get-Date
                $machineState[$mKey].Status      = 'Submitted'
                $submitted = $true
                Write-Status ("  [OK]  {0} ({1})" -f $machine.Name, $machine.ResourceGroupName) 'Green'

            } catch {
                $errMsg     = $_.Exception.Message
                $isThrottle = $errMsg -match '429|TooManyRequests|too many requests'

                if ($isThrottle -and $attempt -lt $maxRetries) {
                    # Exponential backoff: 10s, 20s, 30s
                    $waitSec = 10 * $attempt
                    Write-Status ("  [429] {0} — rate limited, waiting {1}s (attempt {2}/{3})..." -f
                        $machine.Name, $waitSec, $attempt, $maxRetries) 'Yellow'
                    Start-Sleep -Seconds $waitSec
                } else {
                    Write-Status ("  [ERR] {0} — {1}" -f $machine.Name, $errMsg) 'Red'
                    $machineState[$mKey].Status = 'SubmissionError'
                    $submissionErrors.Add([pscustomobject]@{
                        MachineKey    = $mKey
                        MachineName   = $machine.Name
                        ResourceGroup = $machine.ResourceGroupName
                        Error         = $errMsg
                    })
                    break
                }
            }
        }
    }

    # Brief pause between batches (skip after the last one)
    if ($batchNum -lt $batches.Count -and $BatchDelaySeconds -gt 0) {
        Start-Sleep -Seconds $BatchDelaySeconds
    }
}

$submittedKeys = @($machineState.Keys | Where-Object { $machineState[$_].Status -eq 'Submitted' })
Write-Status ("Submitted {0}/{1} machines successfully. {2} submission error(s)." -f
    $submittedKeys.Count, $targetMachines.Count, $submissionErrors.Count)

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Poll for Completion
# ──────────────────────────────────────────────────────────────────────────────
Write-Status '─── Phase 4: Polling for Completion ─────────────────────────' 'White'

$terminalProvStates = @('Succeeded', 'Failed', 'Canceled')
$completedKeys      = [System.Collections.Generic.HashSet[string]]::new()

# Pre-mark submission errors as done so polling skips them
foreach ($key in $machineState.Keys) {
    if ($machineState[$key].Status -eq 'SubmissionError') {
        [void]$completedKeys.Add($key)
    }
}

$pendingCount = $submittedKeys.Count

while ($pendingCount -gt 0) {
    $stillPending = 0

    foreach ($mKey in $submittedKeys) {
        if ($completedKeys.Contains($mKey)) { continue }

        $entry   = $machineState[$mKey]
        $machine = $entry.Machine

        # Per-machine timeout
        $elapsed = (Get-Date) - $entry.SubmittedAt
        if ($elapsed.TotalSeconds -gt $TimeoutSeconds) {
            Write-Status ("  [TIMEOUT] {0}" -f $machine.Name) 'Yellow'
            $entry.Status      = 'TimedOut'
            $entry.CompletedAt = Get-Date
            [void]$completedKeys.Add($mKey)
            continue
        }

        try {
            $runResult = Get-AzConnectedMachineRunCommand `
                -SubscriptionId    $SubscriptionId `
                -ResourceGroupName $machine.ResourceGroupName `
                -MachineName       $machine.Name `
                -RunCommandName    $script:RunCommandName

            $provState  = $runResult.ProvisioningState
            $execState  = $runResult.InstanceViewExecutionState

            # A machine is done when ARM provisioning reached a terminal state AND
            # the script is no longer actively running on the agent
            $isTerminal = ($provState -in $terminalProvStates) -and ($execState -ne 'Running')

            if ($isTerminal) {
                $entry.Result      = $runResult
                $entry.CompletedAt = Get-Date
                $exitCode          = $runResult.InstanceViewExitCode

                if ($exitCode -eq 0) {
                    $entry.Status = 'Success'
                    Write-Status ("  [OK]   {0} | ExitCode: {1} | ExecState: {2}" -f
                        $machine.Name, $exitCode, $execState) 'Green'
                } else {
                    $entry.Status = 'ScriptError'
                    Write-Status ("  [FAIL] {0} | ExitCode: {1} | ExecState: {2}" -f
                        $machine.Name, $exitCode, $execState) 'Red'
                }
                [void]$completedKeys.Add($mKey)
            } else {
                $stillPending++
            }

        } catch {
            # Transient poll error — log and retry next round
            Write-Status ("  [POLL] {0} — poll error (will retry): {1}" -f
                $machine.Name, $_.Exception.Message) 'Yellow'
            $stillPending++
        }
    }

    $pendingCount = $stillPending

    if ($pendingCount -gt 0) {
        Write-Status ("  Waiting: {0,3} | Completed: {1,3} | Total submitted: {2,3}" -f
            $pendingCount, $completedKeys.Count, $submittedKeys.Count) 'DarkCyan'
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

Write-Status 'All machines have reached a terminal state.'

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 5 — Cleanup
# ──────────────────────────────────────────────────────────────────────────────
if (-not $SkipCleanup) {
    Write-Status '─── Phase 5: Cleanup ─────────────────────────────────────────' 'White'
    $cleanedCount   = 0
    $cleanErrCount  = 0

    foreach ($mKey in $machineState.Keys) {
        $entry = $machineState[$mKey]
        # Only remove if we actually created the ARM resource
        if ($entry.Status -eq 'SubmissionError') { continue }

        $machine = $entry.Machine
        try {
            Remove-AzConnectedMachineRunCommand `
                -SubscriptionId    $SubscriptionId `
                -ResourceGroupName $machine.ResourceGroupName `
                -MachineName       $machine.Name `
                -RunCommandName    $script:RunCommandName `
                -ErrorAction       Stop
            $cleanedCount++
        } catch {
            $cleanErrCount++
            Write-Status ("  [WARN] Could not remove run command for {0}: {1}" -f
                $machine.Name, $_.Exception.Message) 'Yellow'
        }
    }
    Write-Status "Removed $cleanedCount run command resource(s). $cleanErrCount removal error(s)."
} else {
    Write-Status '─── Phase 5: Cleanup skipped (-SkipCleanup) ─────────────────' 'DarkGray'
    Write-Status "Run command resources are retained under name: $($script:RunCommandName)" 'DarkGray'
    Write-Status 'To remove manually: Remove-AzConnectedMachineRunCommand -RunCommandName <name>' 'DarkGray'
}

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 6 — Markdown Report
# ──────────────────────────────────────────────────────────────────────────────
Write-Status '─── Phase 6: Generating Markdown Report ──────────────────────' 'White'

$totalDuration = (Get-Date) - $script:HarnessStart
$scriptName    = [System.IO.Path]::GetFileName($DiagnosticScriptPath)
$reportLines   = [System.Collections.Generic.List[string]]::new()

# Tally stats from final state
$statSuccess = 0; $statFail = 0; $statTimeout = 0
foreach ($mKey in $machineState.Keys) {
    switch ($machineState[$mKey].Status) {
        'Success'     { $statSuccess++ }
        'ScriptError' { $statFail++ }
        'TimedOut'    { $statTimeout++ }
    }
}
$statSubErr  = $submissionErrors.Count
$statSkipped = $skippedMachines.Count
$mdFence     = [string][char]96 * 3   # triple-backtick; avoids `' parser ambiguity in PS language server

# ── Header ────────────────────────────────────────────────────────────────────
$reportLines.Add('# Arc Diagnostic Report')
$reportLines.Add('')
$reportLines.Add('| Field | Value |')
$reportLines.Add('|---|---|')
$reportLines.Add("| **Diagnostic Script** | ``$scriptName`` |")
$reportLines.Add("| **Run Timestamp** | $($script:HarnessStart.ToString('yyyy-MM-dd HH:mm:ss')) |")
$reportLines.Add("| **Run Command Name** | ``$($script:RunCommandName)`` |")
$reportLines.Add("| **Subscription ID** | ``$SubscriptionId`` |")
$reportLines.Add("| **Total Duration** | $([Math]::Round($totalDuration.TotalMinutes, 1)) min |")

if ($ResourceGroupNames -and $ResourceGroupNames.Count -gt 0) {
    $reportLines.Add("| **RG Filter** | $($ResourceGroupNames -join ', ') |")
}
if ($FilterTags -and $FilterTags.Count -gt 0) {
    $tagStr = ($FilterTags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
    $reportLines.Add("| **Tag Filter** | $tagStr |")
}
$reportLines.Add("| **Cleanup** | $(if ($SkipCleanup) { 'Skipped — ARM resources retained' } else { 'Completed' }) |")
$reportLines.Add('')

# ── Statistics ────────────────────────────────────────────────────────────────
$reportLines.Add('## Summary')
$reportLines.Add('')
$reportLines.Add('| Result | Count |')
$reportLines.Add('|---|---|')
$reportLines.Add("| ✅ Success | $statSuccess |")
$reportLines.Add("| ❌ Script Error (non-zero exit) | $statFail |")
$reportLines.Add("| ⏱ Timed Out | $statTimeout |")
$reportLines.Add("| 🚫 Submission Error | $statSubErr |")
$reportLines.Add("| ⏭ Skipped (offline / non-Windows) | $statSkipped |")
$reportLines.Add("| **Total Targeted** | **$($targetMachines.Count)** |")
$reportLines.Add('')

# ── Summary Table ─────────────────────────────────────────────────────────────
$reportLines.Add('## Machine Results')
$reportLines.Add('')
$reportLines.Add('| Machine | Resource Group | Location | Status | Exit Code | Stdout (bytes) | Duration (s) |')
$reportLines.Add('|---|---|---|---|---|---|---|')

foreach ($mKey in $machineState.Keys) {
    $entry   = $machineState[$mKey]
    $machine = $entry.Machine
    $result  = $entry.Result

    if ($null -ne $result -and $null -ne $result.InstanceViewExitCode) {
        $exitCode = $result.InstanceViewExitCode
    } else {
        $exitCode = '-'
    }
    if ($null -ne $result -and $result.InstanceViewOutput) {
        $outBytes = [System.Text.Encoding]::UTF8.GetByteCount($result.InstanceViewOutput)
    } else {
        $outBytes = 0
    }

    $durSec = '-'
    if ($entry.SubmittedAt -and $entry.CompletedAt) {
        $durSec = [Math]::Round(($entry.CompletedAt - $entry.SubmittedAt).TotalSeconds)
    }

    $reportLines.Add("| $($machine.Name) | $($machine.ResourceGroupName) | $($machine.Location) | $($entry.Status) | $exitCode | $outBytes | $durSec |")
}
$reportLines.Add('')

# ── Submission Errors ─────────────────────────────────────────────────────────
if ($submissionErrors.Count -gt 0) {
    $reportLines.Add('## Submission Errors')
    $reportLines.Add('')
    foreach ($err in $submissionErrors) {
        $reportLines.Add("### $($err.MachineName)")
        $reportLines.Add('')
        $reportLines.Add("- **Resource Group**: $($err.ResourceGroup)")
        $reportLines.Add("- **Error**: $($err.Error)")
        $reportLines.Add('')
    }
}

# ── Per-Machine Detail ────────────────────────────────────────────────────────
$reportLines.Add('## Per-Machine Output')
$reportLines.Add('')

foreach ($mKey in $machineState.Keys) {
    $entry  = $machineState[$mKey]
    $result = $entry.Result
    if (-not $result) { continue }   # Skipped submission errors — no result to show

    $machine   = $entry.Machine
    $stdout    = $result.InstanceViewOutput
    $stderr    = $result.InstanceViewError
    $execState = $result.InstanceViewExecutionState
    $exitCode  = $result.InstanceViewExitCode

    $reportLines.Add("### $($machine.Name)")
    $reportLines.Add('')
    $reportLines.Add('| Field | Value |')
    $reportLines.Add('|---|---|')
    $reportLines.Add("| Resource Group | $($machine.ResourceGroupName) |")
    $reportLines.Add("| Location | $($machine.Location) |")
    $reportLines.Add("| Status | $($entry.Status) |")
    $reportLines.Add("| Exit Code | $exitCode |")
    $reportLines.Add("| Execution State | $execState |")
    if ($entry.SubmittedAt -and $entry.CompletedAt) {
        $dur = [Math]::Round(($entry.CompletedAt - $entry.SubmittedAt).TotalSeconds)
        $reportLines.Add("| Duration | ${dur}s |")
    }
    $reportLines.Add('')

    # Truncation warning — inline output is capped at ~4 KB by the API
    if ($stdout) { $stdoutBytes = [System.Text.Encoding]::UTF8.GetByteCount($stdout) } else { $stdoutBytes = 0 }
    if ($stdoutBytes -ge 4096) {
        $reportLines.Add("> **Warning:** stdout is $stdoutBytes bytes and may be truncated at the 4,096-byte API limit. Consider using -OutputBlobUri for larger output.")
        $reportLines.Add('')
    }

    if ($stdout) { $stdoutText = $stdout.TrimEnd() } else { $stdoutText = '(no output)' }
    $reportLines.Add('**stdout**')
    $reportLines.Add('')
    $reportLines.Add($mdFence)
    $reportLines.Add($stdoutText)
    $reportLines.Add($mdFence)
    $reportLines.Add('')

    if ($stderr) {
        $reportLines.Add('**stderr**')
        $reportLines.Add('')
        $reportLines.Add($mdFence)
        $reportLines.Add($stderr.TrimEnd())
        $reportLines.Add($mdFence)
        $reportLines.Add('')
    }
}

# ── Skipped Machines ──────────────────────────────────────────────────────────
if ($skippedMachines.Count -gt 0) {
    $reportLines.Add('## Skipped Machines')
    $reportLines.Add('')
    $reportLines.Add('| Machine | Resource Group | OS | Agent Status | Reason |')
    $reportLines.Add('|---|---|---|---|---|')
    foreach ($m in $skippedMachines) {
        if ($m.Status -ne 'Connected') { $reason = 'Agent not connected' } else { $reason = 'Non-Windows OS' }
        if ($m.OSName) { $osName = $m.OSName } else { $osName = 'Unknown' }
        $reportLines.Add("| $($m.Name) | $($m.ResourceGroupName) | $osName | $($m.Status) | $reason |")
    }
    $reportLines.Add('')
}

# ── Write report file ─────────────────────────────────────────────────────────
$reportContent = $reportLines -join [System.Environment]::NewLine
$reportDir     = [System.IO.Path]::GetDirectoryName($OutputMarkdownPath)

if ($reportDir -and -not (Test-Path -Path $reportDir -PathType Container)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

Set-Content -Path $OutputMarkdownPath -Value $reportContent -Encoding UTF8

Write-Status "Report written     : $OutputMarkdownPath" 'Green'
Write-Status ("Total run time     : {0:mm\:ss} (mm:ss)" -f $totalDuration) 'Green'
