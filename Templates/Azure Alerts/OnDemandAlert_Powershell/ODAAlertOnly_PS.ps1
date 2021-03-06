<# Script: ODAAlertOnly_PS
   Purpose: Create Azure Alert if ODA assessment has not run in over a week
   Version: 1.1 
   Author: RPesenko@microsoft.com
#>

Param (
    [Parameter(Mandatory)]
    [string] $RGName,    # Resource Group of workspace and where alert will be created
    [Parameter(Mandatory)]
    [string] $WKSPName,  # Name of workspace to query for ODA results
    [Parameter(Mandatory)]
    [ValidateSet('AD','ADS','Azure','Exchange','ExchangeOnline','SQL','SCOM','SCCM','SP','SPO','SfB','WindowsClient','WindowsServer')]
    [string] $ODAType    # Technology type of ODA.  Will be prepended to rest of query.
)

$la_workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $RGName -Name $WKSPName

$query = $ODAType + "AssessmentRecommendation | where TimeGenerated >= ago(7d) | summarize count(RecommendationId) "

$alert = New-object PSObject -Property @{
    Name = "Missing $ODAType ODA Alert";
    FrequencyInMinutes= 1440;
    TimeWindowInMinutes = 1440;
    ThresholdOperator = 'LessThan';
    Threshold = 2;
    query = $query
    Severity = 1;
    Description = "Alert if no $ODAType ODA assessment was run in the last week"
}

Write-Output "Configuring $AlertName ($($alert.Name))..."

$source = New-AzScheduledQueryRuleSource -Query $alert.query -DataSourceId $la_workspace.ResourceId -WarningAction Ignore
$schedule = New-AzScheduledQueryRuleSchedule -FrequencyInMinutes $alert.FrequencyInMinutes -TimeWindowInMinutes $alert.TimeWindowInMinutes -WarningAction Ignore
$trigger_condition = New-AzScheduledQueryRuleTriggerCondition -ThresholdOperator $alert.ThresholdOperator -Threshold $alert.Threshold -WarningAction Ignore
$action = New-AzScheduledQueryRuleAlertingAction -Severity $alert.Severity -Trigger $trigger_condition -WarningAction Ignore

New-AzScheduledQueryRule `
    -ResourceGroupName $la_workspace.ResourceGroupName `
    -Location $la_workspace.Location `
    -Action $action `
    -Enabled $true `
    -Description $alert.Description `
    -Schedule $schedule `
    -Source $source `
    -Name $alert.Name `
    -WarningAction Ignore 
