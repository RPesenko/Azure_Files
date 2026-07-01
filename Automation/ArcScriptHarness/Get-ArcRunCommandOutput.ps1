#Requires -Version 5.1
<#
.SYNOPSIS
    Collects InstanceViewOutput from a named Run Command across all Connected Arc
    machines in a resource group and writes the results to a Markdown file.

.NOTES
    Version: 1.0.0
    Assumes an active Az context (Connect-AzAccount already run).
#>

# ── Configuration ─────────────────────────────────────────────────────────────
$ResourceGroupName = 'MyRG'  # <-- Change this to your resource group name
$RunCommandName    = 'ArcDiag-ArcParchLevel'
$OutputPath        = Join-Path $PSScriptRoot ("ArcRunCommandOutput_{0}.md" -f (Get-Date -Format 'yyyyMMddHHmmss'))
# ──────────────────────────────────────────────────────────────────────────────

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

        $output = if ($cmd.InstanceViewOutput) { $cmd.InstanceViewOutput.TrimEnd() } else { '(no output)' }
        $results.Add([pscustomobject]@{ MachineName = $machine.Name; Output = $output; Error = $null })
    }
    catch {
        $results.Add([pscustomobject]@{ MachineName = $machine.Name; Output = $null; Error = $_.Exception.Message })
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
