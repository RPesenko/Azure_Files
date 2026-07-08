#Requires -Version 5.1
<#
.SYNOPSIS
    Collects InstanceViewOutput from a named Run Command across all Connected Arc
    machines in one or more resource groups and writes the combined results to a
    Markdown file.

.PARAMETER ResourceGroupNames
    One or more resource group names to query. Results from all groups are combined
    into a single report.

.PARAMETER RunCommandName
    The name of the Run Command ARM resource to query on each machine.

.PARAMETER OutputPath
    Path to write the Markdown report.
    Defaults to ArcRunCommandOutput_<timestamp>.md in the script's directory.

.PARAMETER ExcludeDomains
    One or more domain suffixes to exclude. Any machine whose FQDN ends with one
    of the supplied values (case-insensitive) is skipped entirely.
    Example values: 'contoso.com', 'us.contoso.com'

.NOTES
    Version: 1.3.0
    Assumes an active Az context (Connect-AzAccount already run).

.EXAMPLE
    .\Get-ArcRunCommandOutput.ps1 -ResourceGroupNames 'MyRG' -RunCommandName 'ArcDiag-ArcPatchLevel'

.EXAMPLE
    .\Get-ArcRunCommandOutput.ps1 -ResourceGroupNames 'RG1','RG2' -RunCommandName 'ArcDiag-ArcPatchLevel'

.EXAMPLE
    .\Get-ArcRunCommandOutput.ps1 -ResourceGroupNames 'RG1','RG2' -RunCommandName 'ArcDiag-ArcPatchLevel' -OutputPath 'C:\Reports\output.md'

.EXAMPLE
    .\Get-ArcRunCommandOutput.ps1 -ResourceGroupNames 'RG1','RG2' -RunCommandName 'ArcDiag-ArcPatchLevel' -ExcludeDomains 'contoso.com','extranet.contoso.com'
#>
param (
    [Parameter(Mandatory)]
    [string[]] $ResourceGroupNames,

    [Parameter(Mandatory)]
    [string] $RunCommandName,

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot ("ArcRunCommandOutput_{0}.md" -f (Get-Date -Format 'yyyyMMddHHmmss'))),

    [Parameter()]
    [string[]] $ExcludeDomains = @()
)

# If OutputPath is a directory, append the default timestamped filename
if (Test-Path $OutputPath -PathType Container) {
    $OutputPath = Join-Path $OutputPath ("ArcRunCommandOutput_{0}.md" -f (Get-Date -Format 'yyyyMMddHHmmss'))
}

$mdFence = '```'

# Discover Connected machines across all resource groups
$machines = [System.Collections.Generic.List[object]]::new()
foreach ($rg in $ResourceGroupNames) {
    Write-Host "Querying Connected Arc machines in '$rg'..."
    $rgMachines = @(
        Get-AzConnectedMachine -ResourceGroupName $rg -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Connected' }
    )
    Write-Host "  $($rgMachines.Count) Connected machine(s) found."
    foreach ($m in $rgMachines) { $machines.Add($m) }
}
Write-Host "$($machines.Count) total Connected machine(s) across $($ResourceGroupNames.Count) resource group(s)."

# Filter machines by domain suffix if requested
if ($ExcludeDomains.Count -gt 0) {
    $before = $machines.Count
    $machines = [System.Collections.Generic.List[object]]($machines | Where-Object {
        $fqdn = $_.DnsFqdn
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            return $true   # no FQDN available – cannot determine domain, keep machine
        }
        $excluded = $false
        foreach ($domain in $ExcludeDomains) {
            if ($fqdn -ilike "*.$domain" -or $fqdn -ieq $domain) {
                $excluded = $true
                break
            }
        }
        -not $excluded
    })
    $skipped = $before - $machines.Count
    Write-Host "Domain filter applied (excluded: $($ExcludeDomains -join ', ')): $skipped machine(s) skipped, $($machines.Count) remaining."
}

# Collect results
$results = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($machine in $machines) {
    Write-Host "  Fetching: $($machine.Name) ($($machine.ResourceGroupName))..."
    try {
        $cmd = Get-AzConnectedMachineRunCommand `
            -ResourceGroupName $machine.ResourceGroupName `
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
            MachineName   = $machine.Name
            ResourceGroup = $machine.ResourceGroupName
            Output        = $output
            EndTime       = $endTime
            DurationSec   = $durationSec
            ExitCode      = $exitCode
            Error         = $null
        })
    }
    catch {
        $results.Add([pscustomobject]@{
            MachineName   = $machine.Name
            ResourceGroup = $machine.ResourceGroupName
            Output        = $null
            EndTime       = '-'
            DurationSec   = '-'
            ExitCode      = '-'
            Error         = $_.Exception.Message
        })
    }
}

# Build Markdown
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Arc Run Command Output')
$lines.Add('')
$lines.Add("| Field | Value |")
$lines.Add("|---|---|")
$lines.Add("| **Resource Group(s)** | $($ResourceGroupNames -join ', ') |")
$lines.Add("| **Run Command Name** | ``$RunCommandName`` |")
$lines.Add("| **Generated** | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
$lines.Add("| **Machines** | $($results.Count) |")
if ($ExcludeDomains.Count -gt 0) {
    $lines.Add("| **Excluded Domains** | $($ExcludeDomains -join ', ') |")
}
$lines.Add('')

foreach ($r in $results) {
    $lines.Add("## $($r.MachineName)")
    $lines.Add('')
    $lines.Add("Resource Group: $($r.ResourceGroup)   ")
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
