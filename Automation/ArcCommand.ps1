#Requires -Version 7.0
$ErrorActionPreference = "Stop"

$scriptPath = "C:\Temp\test.ps1" ## Update with your diagnostic script path
$resourceGroupName = "MyRG" ## Update with your resource group name containing Arc machines
$outputPath = "C:\Temp\Arc_RunCommand_Results.csv" ## Update with your desired output path for Success/Failed results
$throttleLimit = 20 ## Throttle limit based on performance requirements (default: 20)

try {
    # Validate prerequisites
    Write-Verbose "Validating prerequisites..."

    # Check if source script exists
    if (-not (Test-Path $scriptPath)) {
        throw "Source script not found: $scriptPath"
    }
    Write-Verbose "Source script found: $scriptPath"

    # Check if output directory exists
    $outputDir = Split-Path -Parent $outputPath
    if (-not (Test-Path $outputDir)) {
        throw "Output directory not found: $outputDir"
    }
    Write-Verbose "Output directory exists: $outputDir"

    # Check if Az.ConnectedMachine module is available
    if (-not (Get-Module -Name "Az.ConnectedMachine" -ListAvailable)) {
        throw "Azure PowerShell module 'Az.ConnectedMachine' is not installed. Install it using: Install-Module -Name Az.ConnectedMachine -Force"
    }
    Write-Verbose "Az.ConnectedMachine module is available"

    # Verify Azure authentication
    try {
        $context = Get-AzContext
        if (-not $context) {
            throw "Not authenticated to Azure"
        }
        Write-Verbose "Azure authentication verified for subscription: $($context.Subscription.Name)"
    }
    catch {
        throw "Azure authentication failed. Please run Connect-AzAccount first."
    }

    # Load script content
    Write-Verbose "Loading source script..."
    $script = Get-Content $scriptPath -Raw
    if (-not $script) {
        throw "Source script is empty: $scriptPath"
    }

    # Get Arc machines
    Write-Verbose "Retrieving Arc machines from resource group: $resourceGroupName"
    $machines = Get-AzConnectedMachine -ResourceGroupName $resourceGroupName -ErrorAction Stop

    if (-not $machines) {
        throw "No Arc machines found in resource group: $resourceGroupName"
    }
    Write-Verbose "Found $(($machines | Measure-Object).Count) machine(s)"

    Write-Verbose "Starting parallel execution with throttle limit: $throttleLimit"
    $results = $machines | ForEach-Object -Parallel {
        $machineName = $_.Name
        Write-Verbose "Processing machine: $machineName"

        try {
            $startTime = Get-Date

            # Build the command parameters
            $commandParams = @{
                ResourceGroupName = $_.ResourceGroupName
                MachineName       = $_.Name
                RunCommandName    = "CollectData_" + [guid]::NewGuid().ToString()
                Location          = $_.Location
                SourceScript      = $using:script
                AsyncExecution    = $true
                TimeoutInSecond   = 300
                ErrorAction       = "Stop"
            }

            Write-Verbose "Executing RunCommand on $machineName with parameters: $($commandParams.Keys -join ', ')"
            
            $response = New-AzConnectedMachineRunCommand @commandParams

            $endTime = Get-Date
            $duration = $endTime - $startTime

            Write-Verbose "Machine $machineName succeeded (Duration: $($duration.TotalSeconds)s)"

            [pscustomobject]@{
                MachineName = $_.Name
                Status      = "Success"
                StartTime   = $startTime
                EndTime     = $endTime
                Duration    = $duration.TotalSeconds
                Error       = $null
            }
        }
        catch {
            Write-Verbose "Machine $machineName failed: $($_.Exception.Message)"

            [pscustomobject]@{
                MachineName = $_.Name
                Status      = "Failed"
                StartTime   = $null
                EndTime     = $null
                Duration    = $null
                Error       = $_.Exception.Message
            }
        }

    } -ThrottleLimit $throttleLimit

    # Verify results
    if (-not $results) {
        throw "No results were collected from any machines"
    }

    # Analyze results (use @() array wrapper to handle single objects correctly)
    $successCount = @($results | Where-Object { $_.Status -eq "Success" }).Count
    $failureCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count

    Write-Verbose "Execution completed - Success: $successCount, Failed: $failureCount"

    # Export results
    Write-Verbose "Exporting results to: $outputPath"
    $results | Sort-Object MachineName |
        Export-Csv $outputPath -NoTypeInformation

    # Display summary
    Write-Host "Script execution completed successfully"
    Write-Host "  Success: $successCount machine(s)"
    Write-Host "  Failed: $failureCount machine(s)"
    Write-Host "  Results exported to: $outputPath"
}
catch {
    Write-Error "Script failed with error: $($_.Exception.Message)"
    Write-Error "Full Exception: $($_ | Out-String)"
    Write-Error "Line: $($_.InvocationInfo.ScriptLineNumber) | Column: $($_.InvocationInfo.OffsetInLine)"
    Write-Error "Command: $($_.InvocationInfo.Line)"
    exit 1
}