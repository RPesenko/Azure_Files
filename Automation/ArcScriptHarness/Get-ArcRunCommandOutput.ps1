#Requires -Version 5.1
<#
.SYNOPSIS
    Collects InstanceViewOutput from a named Run Command across all Connected Arc
    machines in a resource group and writes the results to a Markdown file.

.PARAMETER ResourceGroupName
    The resource group containing the Arc machines.

.PARAMETER RunCommandName
    The name of the Run Command ARM resource to query on each machine.

.PARAMETER OutputPath
    Path to write the Markdown report.
    Defaults to ArcRunCommandOutput_<timestamp>.md in the script's directory.

.NOTES
    Version: 1.1.0
    Assumes an active Az context (Connect-AzAccount already run).

.EXAMPLE
    .\Get-ArcRunCommandOutput.ps1 -ResourceGroupName 'MyRG' -RunCommandName 'ArcDiag-ArcPatchLevel'

.EXAMPLE
    .\Get-ArcRunCommandOutput.ps1 -ResourceGroupName 'MyRG' -RunCommandName 'ArcDiag-ArcPatchLevel' -OutputPath 'C:\Reports\output.md'
#>
param (
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $RunCommandName,

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot ("ArcRunCommandOutput_{0}.md" -f (Get-Date -Format 'yyyyMMddHHmmss')))
)

# If OutputPath is a directory, append the default timestamped filename
if (Test-Path $OutputPath -PathType Container) {
    $OutputPath = Join-Path $OutputPath ("ArcRunCommandOutput_{0}.md" -f (Get-Date -Format 'yyyyMMddHHmmss'))
}

$mdFence = '```'

# Discover Connected machines
Write-Host "Querying Connected Arc machines in '$ResourceGroupName'..."
$machines = @(
    Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName -ErrorAction Stop |
        Where-Object { $_.Status -eq 'Connected' }
)
Write-Host "$($machines.Count) Connected machine(s) found."

# Collect results
$results = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($machine in $machines) {
    Write-Host "  Fetching: $($machine.Name)..."
    try {
        $cmd = Get-AzConnectedMachineRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -MachineName       $machine.Name `
            -RunCommandName    $RunCommandName `
            -ErrorAction       Stop

        $output      = if ($cmd.InstanceViewOutput) { $cmd.InstanceViewOutput.TrimEnd() } else { '(no output)' }
        $endTime     = if ($cmd.InstanceViewEndTime)   { $cmd.InstanceViewEndTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
        $exitCode    = if ($null -ne $cmd.InstanceViewExitCode) { $cmd.InstanceViewExitCode } else { '-' }
        $durationSec = if ($cmd.InstanceViewStartTime -and $cmd.InstanceViewEndTime) {
                           [Math]::Round(($cmd.InstanceViewEndTime - $cmd.InstanceViewStartTime).TotalSeconds)
                       } else { '-' }
        $results.Add([pscustomobject]@{
            MachineName  = $machine.Name
            Output       = $output
            EndTime      = $endTime
            DurationSec  = $durationSec
            ExitCode     = $exitCode
            Error        = $null
        })
    }
    catch {
        $results.Add([pscustomobject]@{
            MachineName  = $machine.Name
            Output       = $null
            EndTime      = '-'
            DurationSec  = '-'
            ExitCode     = '-'
            Error        = $_.Exception.Message
        })
    }
}

# Build Markdown
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Arc Run Command Output')
$lines.Add('')
$lines.Add("| Field | Value |")
$lines.Add("|---|---|")
$lines.Add("| **Resource Group** | $ResourceGroupName |")
$lines.Add("| **Run Command Name** | ``$RunCommandName`` |")
$lines.Add("| **Generated** | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
$lines.Add("| **Machines** | $($results.Count) |")
$lines.Add('')

foreach ($r in $results) {
    $lines.Add("## $($r.MachineName)")
    $lines.Add('')
    $lines.Add("End Time: $($r.EndTime)   ")
    $lines.Add("Execution Time: $($r.DurationSec)s   ")
    $lines.Add("Exit Code: $($r.ExitCode)")
    $lines.Add('')
    if ($r.Error) {
        $lines.Add("*Error: $($r.Error)*")
    } else {
        $lines.Add($mdFence)
        $lines.Add($r.Output)
        $lines.Add($mdFence)
    }
    $lines.Add('')
}

$lines | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Report written to: $OutputPath"
