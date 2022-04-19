# ODA Monitoring App
This template allows you to create a new logic app to verify that an On Demand Assessment has run recently and, if so, to mail a summary of results to one or more recipients.  

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FRPesenko%2FAzure_Files%2Fmaster%2FTemplates%2FLogic%20Apps%2FODA%20Monitoring%20App%2FODA_Monitoring_template.json)

## Deploy the template with Powershell
### Connect to Azure
From PowerShell, type the following to establish a connection to your subscription.
> Connect-AzAccount

### (Optional) Create a new Resource Group for your Logic App
If you will be adding this logic app to an existing resource group, skip to the next step. If you need to create a new resource group for your logic app, type the following command. 
##### Syntax
> New-AzResourceGroup -Name `<AppName>` -Location `<Azure Region>`
##### Example
> New-AzResourceGroup -Name `RG_LogicAppTest` -Location `"Central US"`

### Create a deployment of the template (Optionally using the parameter file) 
Type the following in your PowerShell session
##### Syntax
> New-AzResourceGroupDeployment 
  -Name `<Name of Deployment>` 
  -ResourceGroupName `<Name of target Resource Group>` 
  -TemplateFile `<Path to template file>` 
  -TemplateParameterFile `<Path to parameter file>`
##### Example
> New-AzResourceGroupDeployment 
  -Name `Test_App_Deployment` 
  -ResourceGroupName `RG_AppTest` 
  -TemplateFile `C:\templates\ODA_Template.json` 
  -TemplateParameterFile `C:\templates\ODA_Parameters.json`

The template provides a default value for the name of the logic app but that can be changed at deployment. The Name, Resource Group and Subscription of the Log Analytic Workspace to be assesed, plus the e-mail addresses of the recipients must be provided either in the optional parameter file, or when prompted by PowerShell if the `TemplateParameterFile` parameter is omitted from the deployment.

### Authorize the API connections
After the deployment completes, two managed API connection objects will be created, but not initialized, in the resource group. One connection "`AzureRegion`-AzureMonitorLogs", is used to connect to the Log Analytic Workspace. From the "_Edit API Connection_" node of the connection, click the "**Authorize**" button and enter credentials for an account with permission to query the workspace.

The second connection is "`AzureRegion`-Office365". This connection is required to send e-mail via an O365 mail account. From the "_Edit API Connection_" node of the connection, click the "**Authorize**" button and enter credentials for a mail enabled O3365 account.

Once these two connections have been initialized, additional logic apps deployed to the same resource group with the same template can use the existing connections without having to initialize them again.