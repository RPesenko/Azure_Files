# ODA Monitoring App
This template allows you to create a new logic app to verify that an On Demand Assessment has run recently and, if so, to mail a summary of results to one or more recipients. The time interval, connection credentials and e-mail recipients can all be updated in the Azure portal after deployment.

**Permissions Required**
- The user deploying the template must have permission to create a resource group or add resources to an existing resource group.
- Credentials for a user account with read permission on the Log Analytics Workspace where the ODA results reside must be added to the resource group after deployment.
- Credentials for an account with an O365 mailbox must be added to the resource group after deployment to allow results to be sent by e-mail.

## Deploy the template directly
The link below allows you to quickly deploy the template to Azure. This method doesn't require access to the Azure PowerShell module and is recommended if you don't need to heavily customize the deployment. 

[![Deploy To Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FRPesenko%2FAzure_Files%2Fmaster%2FTemplates%2FLogic%20Apps%2FODA%20Monitoring%20App%2FODA_Monitoring_template.json)

 
## Deploy the template with Powershell
Use this option if you need to customize the deployment template or parameter file. This requires you to have the Azure PowerShell module installed on your workstation and have a locally saved copy of the template and parameter file.

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

## Authorize the API connections
Regardless of the deployment method used, two uninitialized managed API connection objects will be created in the resource group. You will need to provide valid credentials for both managed API connection before the logic app can run successfully.

One connection "`AzureRegion`-AzureMonitorLogs", is used to connect to the Log Analytic Workspace. From the "_Edit API Connection_" node of the connection object's properties, click the "**Authorize**" button and enter credentials for an account with read permission to the workspace.

The second connection is "`AzureRegion`-Office365". This connection is required to send e-mail via an O365 mail account. From the "_Edit API Connection_" node of the connection object's properties, click the "**Authorize**" button and enter credentials for a mail enabled O365 account.

Once these two connections have been initialized, additional logic apps deployed to the same resource group with the same template can use the existing connections without having to initialize them again. If the credentials need to be changed at a later time, repeat the above steps as needed to update or change the API connection.