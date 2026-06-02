**DCR Templates for Change Tracking and Inventory**

The following Data Collection Rule (DCR) templates can be deployed to Azure to enable Change Tracking and Inventory (CTI) for Azure VMs and Azure Arc Connected Machines. 

*Prerequisites*
- Each Azure VM or Arc-enabled VM can only be associated to ONE DCR for CTI. Associating the VM to more than one DCR for CTI is unsupported and can have unexpected results. 
- The CTI must upload change data to an Azure Monitor Log Analytics workspace in an Azure region that supports CTI. The VM can still be associated with non-CTI DCRs that upload performance metrics, events and other log data to Logs workspaces or storage accounts in other regions.
- DCRs are limited to 250 registry collection definitions. The CTI extension will only adhere to the first 250 registry definitions in the DCR and ignore the rest, though wildcards and recursion can be used for subkeys and values. 

*Additional Notes*
- Additional registry entries or file collection definitions can be added to the DCR via the Azure Portal. The template can also be edited and redeployed with the same name to overwrite the existing DCR if many changes need to be made.
- Registry keys or values that do not show in the *ConfigurationData* table of the logs workspace, or in the Change Tracking and Inventory node of the Azure Portal, may be empty or missing on the Azure VM. 

*Deployment via Azure Portal*
1) Download one of the DCR ARM templates to your local drive.
2) Open the Azure Portal and select the _Deploy a Custom Template_ service from the Azure search bar.
3) On the Custom Deployment page, select _Build your own template in the editor_
4) Browse to the JSON file you downloaded on your local drive.
5) Make any required changes, such as adding or removing registry key definitions, enabling recursion, group tag naming, etc.
6) Click the _save_ button.
7) On the _Basics_ page, select the Resource Group to host this DCR. This DCR needs to be deployed to the same Azure Region that the Log Analytics workspace is deployed to, and that Azure Region needs to support _Change Tracking and Inventory_. The Azure Region will populate automatically under _Instance details_ based on the Resource Group location.
8) The defailt DCR name is specified in the template, but can be changed here. If no DCR with the selected name exists in that Resource Group, a new DCR will be deployed. If an existing DCR with that name already exists in the Resource Group, the deployment will overwrite the existing DCR. This is useful for reverting unwanted changes or updating the existing deployment.
9) Specify the Resource ID of the Log Analytics Workspace. This Resource ID can be found in the _Properties_ node under the _Settings_ node in the navigation tree of the Workspace. 
10) Select _Review and Create_ to let Azure Resource Manager validate the template before deployment. If no errors are found, select _Create_ to deploy the configured template. 
