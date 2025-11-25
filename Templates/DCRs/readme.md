**DCR Template for Change Tracking and Inventory**

The following Data Collection Rule (DCR) templates can be deployed to Azure to enable Change Tracking and Inventory (CTI) for Azure VMs and Azure Arc Connected Machines. 

*Prerequisites*
- Each Azure VM or Arc-enabled VM can only be associated to ONE DCR for CTI. Associating the VM to more than one DCR for CTI is unsupported and can have unexpected results. 
- The CTI must upload change data to an Azure Monitor Log Analytics workspace in an Azure region that supports CTI. The VM can still be associated with non-CTI DCRs that upload performance metrics, events and other log data to Logs workspaces or storage accounts in other regions.
- DCRs are limited to 250 registry collection definitions. The CTI extension will only collect the first 250 registry keys defined in the DCR and ignore the rest.

*Additional Notes*
- Additional registry entries or file collection definitions can be added to the DCR via the Azure Portal. The template can also be edited and redeployed with the same name to overwrite the existing DCR if many changes need to be made.
- Registry keys or values that do not show in the *ConfigurationData* table of the logs workspace, or in the Change Tracking and Inventory node of the Azure Portal, may be empty or missing on the Azure VM. 
