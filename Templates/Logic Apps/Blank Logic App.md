# Creating a blank Logic App with recurrance trigger
This template allows you to create a new logic app with a trigger to run on a recurring schedule.  

## Deploy template with Powershell
#### Connect to Azure
From PowerShell, type the following to establish a connection to your subscription.
> Connect-AzAccount

##### Create a Resource Group for your Logic App
From PowerShell, type the following to create a new Resource Group (if required) in one of the Azure Regions
> New-AzResourceGroup -Name RG_LogicAppTest -Location "Central US"

#### Create a deployment of the template
Type the following in your PowerShell session
>   New-AzResourceGroupDeployment 
  -Name FirstDeployment 
  -ResourceGroupName RG_LogicAppTest 
  -TemplateFile $templateFile 
  -Appname "Blank_Logic_App" 
  -AppInterval 1 
  -AppFrequency "Day"

  The _New-AzResourcGroupDeployment_ cmdlet uses the following parameters
  - Name: This is the name of the deployment task.  
  - TemplateFile: Populate the _$templateFile_ variable with the path to your template.
  - Appname: This is the name of the Logic App to be deployed.
  - AppInterval: Integer value for recurrance
  - AppFrequency:  String value for recurrance (EX: Month, Day, Minute,etc)

If the _AppInterval_ and _AppFreguency_ parameters are not provided, the template defaults to 15 minutes.

Alternatively, you can deploy the template using the parameter file
> New-AzResourceGroupDeployment 
  -Name FirstDeployment 
  -ResourceGroupName RG_LogicAppTest 
  -TemplateFile $templateFile 
  -TemplateParameterFile $parameterFile

The template also allows for use of the _location_ parameter.  It uses a function to default the Logic App to the same Azure region as the Resource Group, but if you include the parameter with a different Azure region, you can create the Logic app in a new region.