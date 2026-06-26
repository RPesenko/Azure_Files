#Requires -Version 7.2
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

.PARAMETER FilterFQDNs
    Optional. An array of fully qualified domain names (FQDNs). When specified, only
    machines whose FQDN matches an entry in this list (case-insensitive) are targeted.
    Useful for re-running the harness against a specific subset of machines — for example,
    machines that were unresponsive or returned errors in a previous pass — without
    reprocessing all machines that already succeeded.
    Example: 'server01.contoso.com','server02.contoso.com'

.PARAMETER BatchSize
    Number of machines to submit per batch. Default: 10. Also controls the ThrottleLimit
    for concurrent ARM write operations within each batch (all machines in a batch are
    submitted in parallel). Keeps ARM write operations within the rate-limit refill rate (~10/sec).

.PARAMETER BatchDelaySeconds
    Seconds to wait between submission batches. Default: 2.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for a single machine's script to complete before marking
    it as timed out. Default: 600 (10 minutes).

.PARAMETER PollIntervalSeconds
    Seconds to wait between polling rounds. Default: 15.

.PARAMETER Cleanup
    When specified, Run Command ARM resources are deleted from each machine after results
    are collected. By default, resources are retained and reused on subsequent runs,
    which avoids the create/delete overhead and enables version-aware re-execution.

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
    # Force removal of Run Command ARM resources after collection
    .\ArcScriptHarness.ps1 `
        -DiagnosticScriptPath .\Collect-EventLogs.ps1 `
        -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -Cleanup

.EXAMPLE
    # Re-run against only the machines that failed or timed out in a previous pass
    .\ArcScriptHarness.ps1 `
        -DiagnosticScriptPath .\Get-DiskHealth.ps1 `
        -SubscriptionId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -FilterFQDNs          'server01.contoso.com','server02.contoso.com'

.NOTES
    Version: 1.0.0

    Run command name format: ArcDiag-<ScriptBaseName> - stable across runs (max 36 chars).
    The Run Command ARM resource is created on first use and reused on subsequent runs:
      Create - no existing resource found; created fresh.
      ReRun  - resource exists and script hash matches; re-executed unchanged.
      Update - resource exists but script content has changed; updated before execution.
    Run Command resources are retained by default; pass -Cleanup to remove after collection.

    PARALLEL EXECUTION (PowerShell 7.2+ required)
    Within each batch all Run Command submissions are dispatched concurrently using
    ForEach-Object -Parallel. Each polling round and the cleanup phase are also parallelised.
    Each parallel runspace re-establishes the Az context via Set-AzContext so no interactive
    sign-in is required in child runspaces. BatchSize doubles as the submission ThrottleLimit;
    polling is capped at 20 concurrent GETs and cleanup at 10 concurrent DELETEs.
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
    [string[]] $FilterFQDNs,

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

    [switch] $Cleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Version        = '1.0.0'

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

function Get-MachineFQDN {
    # The FQDN property name varies across Az.ConnectedMachine SDK versions.
    # Falls back to the short machine name if no FQDN property is present.
    param($Machine)
    if ($Machine.PSObject.Properties['FQDN']     -and $null -ne $Machine.FQDN)     { return $Machine.FQDN     }
    if ($Machine.PSObject.Properties['DNSFqdn']  -and $null -ne $Machine.DNSFqdn)  { return $Machine.DNSFqdn  }
    if ($Machine.PSObject.Properties['DnsFqdn']  -and $null -ne $Machine.DnsFqdn)  { return $Machine.DnsFqdn  }
    return $Machine.Name
}

# Unique key for a machine that is stable even when two RGs share a machine name
function Get-MachineKey { param($Machine) "$($Machine.ResourceGroupName)/$($Machine.Name)" }

# ──────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Validation & Setup
# ──────────────────────────────────────────────────────────────────────────────
Write-Status '─── Phase 1: Validation & Setup ──────────────────────────────' 'White'
Write-Status "Harness version    : v$($script:Version)"

$script:HarnessStart   = Get-Date
$script:RunTimestamp   = Get-Date -Format 'yyyyMMddHHmmss'

# 1a. Resolve and read diagnostic script
$DiagnosticScriptPath = (Resolve-Path -Path $DiagnosticScriptPath).Path
$rawScript            = Get-Content -Path $DiagnosticScriptPath -Raw -Encoding UTF8

# Stable run command name derived from the script file name so the same ARM resource
# is reused across runs.  Non-alphanumeric characters are replaced with hyphens;
# name is truncated to fit within the 36-char API limit (9-char 'ArcDiag-' prefix leaves 27).
$scriptBase            = [System.IO.Path]::GetFileNameWithoutExtension($DiagnosticScriptPath)
$scriptBase            = ($scriptBase -replace '[^a-zA-Z0-9]', '-' -replace '-{2,}', '-').TrimEnd('-')
$scriptBase            = $scriptBase.Substring(0, [Math]::Min($scriptBase.Length, 27))
$script:RunCommandName = "ArcDiag-$scriptBase"

# Compute a short SHA-256 hash of the raw script for change detection.
# Compared against the hash embedded in any existing Run Command resource to decide
# whether to Create, ReRun (same hash), or Update (different hash) the resource.
$sha256            = [System.Security.Cryptography.SHA256]::Create()
$hashBytes         = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($rawScript))
$script:ScriptHash = (($hashBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
$sha256.Dispose()

# Wrap in try/catch so any diagnostic script surfaces errors cleanly without modification.
# ArcHarness-ScriptHash  - stable per script content; used for version detection on reuse.
# ArcHarness-RunTimestamp - changes every run, ensuring the agent always re-executes even
#                           when the script content itself has not changed.
$wrappedScript = @"
# ArcHarness-ScriptHash: $($script:ScriptHash)
# ArcHarness-RunTimestamp: $($script:RunTimestamp)
try {
$rawScript
} catch {
    Write-Error "UNHANDLED EXCEPTION: `$(`$_.Exception.Message)"
    exit 1
}
"@

$scriptBytes = [System.Text.Encoding]::UTF8.GetByteCount($wrappedScript)
Write-Status "Diagnostic script  : $DiagnosticScriptPath ($scriptBytes bytes)"
Write-Status "Script hash        : $($script:ScriptHash)"

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

# FQDN filter — only include machines whose FQDN is in the supplied list
if ($FilterFQDNs -and $FilterFQDNs.Count -gt 0) {
    $fqdnLower  = $FilterFQDNs | ForEach-Object { $_.ToLower() }
    $candidates = $candidates | Where-Object {
        (Get-MachineFQDN -Machine $_).ToLower() -in $fqdnLower
    }
    Write-Status "FQDN filter        : $($FilterFQDNs -join ', ')"
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

# Capture script-scoped variables into plain variables for use in $using: scope
$runCommandName = $script:RunCommandName
$scriptHash     = $script:ScriptHash

$batchNum = 0
foreach ($batch in $batches) {
    $batchNum++
    Write-Status "Submitting batch $batchNum / $($batches.Count) ($($batch.Count) machine(s))..."

    # Pre-initialise state entries sequentially so downstream phases can reference every machine
    foreach ($machine in $batch) {
        $mKey = Get-MachineKey -Machine $machine
        $machineState[$mKey] = @{
            Machine     = $machine
            SubmittedAt = $null
            CompletedAt = $null
            Status      = 'Pending'
            Result      = $null
        }
    }

    # Submit all machines in the batch concurrently; ThrottleLimit caps in-flight ARM writes
    $batchResults = $batch | ForEach-Object -Parallel {
        $machine     = $_
        $mKey        = "$($machine.ResourceGroupName)/$($machine.Name)"
        $maxRetries  = 3
        $attempt     = 0
        $submitted   = $false
        $submittedAt = $null
        $errorMsg    = $null
        $action      = 'Create'
        $warnings    = [System.Collections.Generic.List[string]]::new()

        # ForEach-Object -Parallel runs in a fresh runspace — re-establish the Az context
        $null = Set-AzContext -Context $using:azContext -ErrorAction SilentlyContinue

        # Check for an existing Run Command resource and determine the action.
        # ArcHarness-ScriptHash in the resource's SourceScript is compared to the current hash:
        #   Create - no resource found.
        #   ReRun  - resource found; hash matches; script unchanged.
        #   Update - resource found; hash differs; script has changed.
        try {
            $existingCmd = Get-AzConnectedMachineRunCommand `
                -SubscriptionId    $using:SubscriptionId `
                -ResourceGroupName $machine.ResourceGroupName `
                -MachineName       $machine.Name `
                -RunCommandName    $using:runCommandName `
                -ErrorAction       Stop

            $existingHash = $null
            if ($existingCmd.SourceScript) {
                $firstLine = ($existingCmd.SourceScript -split '[\r\n]+')[0].Trim()
                if ($firstLine -match '#\s*ArcHarness-ScriptHash:\s*([0-9a-f]+)') {
                    $existingHash = $Matches[1]
                }
            }
            $action = if ($existingHash -eq $using:scriptHash) { 'ReRun' } else { 'Update' }
        } catch {
            # Resource not found (404) or unavailable - will be created
            $action = 'Create'
        }

        while ($attempt -lt $maxRetries -and -not $submitted) {
            $attempt++
            try {
                $null = New-AzConnectedMachineRunCommand `
                    -SubscriptionId    $using:SubscriptionId `
                    -ResourceGroupName $machine.ResourceGroupName `
                    -MachineName       $machine.Name `
                    -Location          $machine.Location `
                    -RunCommandName    $using:runCommandName `
                    -SourceScript      $using:wrappedScript `
                    -AsyncExecution `
                    -TimeoutInSecond   $using:TimeoutSeconds

                $submittedAt = Get-Date
                $submitted   = $true

            } catch {
                $errMsg     = $_.Exception.Message
                $isThrottle = $errMsg -match '429|TooManyRequests|too many requests'

                if ($isThrottle -and $attempt -lt $maxRetries) {
                    $waitSec = 10 * $attempt
                    $warnings.Add(("  [429] {0} — rate limited, waiting {1}s (attempt {2}/{3})..." -f
                        $machine.Name, $waitSec, $attempt, $maxRetries))
                    Start-Sleep -Seconds $waitSec
                } else {
                    $errorMsg = $errMsg
                    break
                }
            }
        }

        [pscustomobject]@{
            MachineKey    = $mKey
            MachineName   = $machine.Name
            ResourceGroup = $machine.ResourceGroupName
            Submitted     = $submitted
            SubmittedAt   = $submittedAt
            Action        = $action
            Error         = $errorMsg
            Warnings      = $warnings.ToArray()
        }
    } -ThrottleLimit $BatchSize

    # Merge parallel results back into $machineState (sequential — no concurrency concerns)
    foreach ($sub in $batchResults) {
        foreach ($warn in $sub.Warnings) { Write-Status $warn 'Yellow' }

        if ($sub.Submitted) {
            $machineState[$sub.MachineKey].SubmittedAt = $sub.SubmittedAt
            $machineState[$sub.MachineKey].Status      = 'Submitted'
            $actionLabel = switch ($sub.Action) {
                'ReRun'  { 'Re-run'  }
                'Update' { 'Updated' }
                default  { 'Created' }
            }
            Write-Status ("  [OK]  {0} ({1}) [{2}]" -f $sub.MachineName, $sub.ResourceGroup, $actionLabel) 'Green'
        } else {
            $machineState[$sub.MachineKey].Status = 'SubmissionError'
            Write-Status ("  [ERR] {0} — {1}" -f $sub.MachineName, $sub.Error) 'Red'
            $submissionErrors.Add([pscustomobject]@{
                MachineKey    = $sub.MachineKey
                MachineName   = $sub.MachineName
                ResourceGroup = $sub.ResourceGroup
                Error         = $sub.Error
            })
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
    # Build lightweight per-machine input objects — avoids serialising the full $machineState
    # hashtable into every parallel runspace
    $pollInputs = @(
        $submittedKeys |
        Where-Object { -not $completedKeys.Contains($_) } |
        ForEach-Object {
            [pscustomobject]@{
                MachineKey    = $_
                MachineName   = $machineState[$_].Machine.Name
                ResourceGroup = $machineState[$_].Machine.ResourceGroupName
                SubmittedAt   = $machineState[$_].SubmittedAt
            }
        }
    )

    # Poll all pending machines concurrently; ThrottleLimit caps in-flight ARM GETs
    $pollResults = $pollInputs | ForEach-Object -Parallel {
        $item = $_

        $elapsed = (Get-Date) - $item.SubmittedAt
        if ($elapsed.TotalSeconds -gt $using:TimeoutSeconds) {
            return [pscustomobject]@{
                MachineKey  = $item.MachineKey
                MachineName = $item.MachineName
                Outcome     = 'TimedOut'
                Result      = $null
                ExitCode    = $null
                ExecState   = $null
                PollError   = $null
                CompletedAt = Get-Date
            }
        }

        $null = Set-AzContext -Context $using:azContext -ErrorAction SilentlyContinue

        try {
            $runResult = Get-AzConnectedMachineRunCommand `
                -SubscriptionId    $using:SubscriptionId `
                -ResourceGroupName $item.ResourceGroup `
                -MachineName       $item.MachineName `
                -RunCommandName    $using:runCommandName

            $provState  = $runResult.ProvisioningState
            $execState  = $runResult.InstanceViewExecutionState

            # A machine is done when ARM provisioning reached a terminal state AND
            # the script is no longer actively running on the agent AND
            # the execution end time is after our submission (guards against briefly
            # seeing the terminal state of a previous run immediately after a re-submit).
            $execEndTime  = if ($runResult.PSObject.Properties['InstanceViewEndTime']) { $runResult.InstanceViewEndTime } else { $null }
            $isCurrentRun = (-not $execEndTime) -or ($execEndTime -gt $item.SubmittedAt)
            $isTerminal   = $isCurrentRun -and ($provState -in $using:terminalProvStates) -and ($execState -ne 'Running')

            if ($isTerminal) {
                $exitCode = $runResult.InstanceViewExitCode
                $outcome  = if ($exitCode -eq 0) { 'Success' } else { 'ScriptError' }
                return [pscustomobject]@{
                    MachineKey  = $item.MachineKey
                    MachineName = $item.MachineName
                    Outcome     = $outcome
                    Result      = $runResult
                    ExitCode    = $exitCode
                    ExecState   = $execState
                    PollError   = $null
                    CompletedAt = Get-Date
                }
            }

            return [pscustomobject]@{
                MachineKey  = $item.MachineKey
                MachineName = $item.MachineName
                Outcome     = 'Pending'
                Result      = $null
                ExitCode    = $null
                ExecState   = $null
                PollError   = $null
                CompletedAt = $null
            }
        } catch {
            return [pscustomobject]@{
                MachineKey  = $item.MachineKey
                MachineName = $item.MachineName
                Outcome     = 'Pending'
                Result      = $null
                ExitCode    = $null
                ExecState   = $null
                PollError   = $_.Exception.Message
                CompletedAt = $null
            }
        }
    } -ThrottleLimit 20

    # Merge poll results back into $machineState (sequential)
    $stillPending = 0
    foreach ($pr in $pollResults) {
        switch ($pr.Outcome) {
            'TimedOut' {
                $machineState[$pr.MachineKey].Status      = 'TimedOut'
                $machineState[$pr.MachineKey].CompletedAt = $pr.CompletedAt
                [void]$completedKeys.Add($pr.MachineKey)
                Write-Status ("  [TIMEOUT] {0}" -f $pr.MachineName) 'Yellow'
            }
            'Success' {
                $machineState[$pr.MachineKey].Result      = $pr.Result
                $machineState[$pr.MachineKey].CompletedAt = $pr.CompletedAt
                $machineState[$pr.MachineKey].Status      = 'Success'
                [void]$completedKeys.Add($pr.MachineKey)
                Write-Status ("  [OK]   {0} | ExitCode: {1} | ExecState: {2}" -f
                    $pr.MachineName, $pr.ExitCode, $pr.ExecState) 'Green'
            }
            'ScriptError' {
                $machineState[$pr.MachineKey].Result      = $pr.Result
                $machineState[$pr.MachineKey].CompletedAt = $pr.CompletedAt
                $machineState[$pr.MachineKey].Status      = 'ScriptError'
                [void]$completedKeys.Add($pr.MachineKey)
                Write-Status ("  [FAIL] {0} | ExitCode: {1} | ExecState: {2}" -f
                    $pr.MachineName, $pr.ExitCode, $pr.ExecState) 'Red'
            }
            default {
                # 'Pending' — still running
                $stillPending++
                if ($pr.PollError) {
                    Write-Status ("  [POLL] {0} — poll error (will retry): {1}" -f
                        $pr.MachineName, $pr.PollError) 'Yellow'
                }
            }
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
if ($Cleanup) {
    Write-Status '─── Phase 5: Cleanup ─────────────────────────────────────────' 'White'

    # Collect machines for which a run command ARM resource was actually created
    $cleanableMachines = @(
        $machineState.Keys |
        Where-Object { $machineState[$_].Status -ne 'SubmissionError' } |
        ForEach-Object { $machineState[$_].Machine }
    )

    # @() forces an array even when only one machine is cleaned — required by Set-StrictMode
    $cleanResults = @(
        $cleanableMachines | ForEach-Object -Parallel {
            $machine = $_
            $null = Set-AzContext -Context $using:azContext -ErrorAction SilentlyContinue
            try {
                Remove-AzConnectedMachineRunCommand `
                    -SubscriptionId    $using:SubscriptionId `
                    -ResourceGroupName $machine.ResourceGroupName `
                    -MachineName       $machine.Name `
                    -RunCommandName    $using:runCommandName `
                    -ErrorAction       Stop
                [pscustomobject]@{ MachineName = $machine.Name; Success = $true; Error = $null }
            } catch {
                [pscustomobject]@{ MachineName = $machine.Name; Success = $false; Error = $_.Exception.Message }
            }
        } -ThrottleLimit 10
    )

    # @() on Where-Object guards against a single match returning a bare object (not an array)
    $cleanedCount  = @($cleanResults | Where-Object {  $_.Success }).Count
    $cleanErrCount = @($cleanResults | Where-Object { -not $_.Success }).Count
    foreach ($cr in @($cleanResults | Where-Object { -not $_.Success })) {
        Write-Status ("  [WARN] Could not remove run command for {0}: {1}" -f $cr.MachineName, $cr.Error) 'Yellow'
    }
    Write-Status "Removed $cleanedCount run command resource(s). $cleanErrCount removal error(s)."
} else {
    Write-Status '─── Phase 5: Resources retained (pass -Cleanup to remove) ───' 'DarkGray'
    Write-Status "Run command name  : $($script:RunCommandName) (retained on each machine)" 'DarkGray'
    Write-Status "To remove: Remove-AzConnectedMachineRunCommand -RunCommandName '$($script:RunCommandName)'" 'DarkGray'
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
$reportLines.Add("| **Harness Version** | ``$($script:Version)`` |")
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
if ($FilterFQDNs -and $FilterFQDNs.Count -gt 0) {
    $reportLines.Add("| **FQDN Filter** | $($FilterFQDNs -join ', ') |")
}
$reportLines.Add("| **Cleanup** | $(if ($Cleanup) { 'Completed' } else { 'Skipped - ARM resources retained for reuse' }) |")
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
