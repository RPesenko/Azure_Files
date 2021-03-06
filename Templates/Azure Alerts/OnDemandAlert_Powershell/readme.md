# ODAAlertOnly_PS.ps1
Powershell script to create an Azure Alert when an On Demand Assessment (ODA) has not generated any recommendations in the last seven days.  Does not rely on Azure JSON templates.

### Use case
On Demand Assessments run every seven days by default.  If the assessment does not run after seven days, this alert will fire.  An action group can later be added to sent an e-mail notification or trigger an automated response to the alert.  A seperate alert rule must be created for each type of On Demand Assessment 

### Parameters
* $RGName = Resource Group of the workspace being used for ODA.  This is where the alert will be created.
* $WKSPName = Name of the workspace to query for ODA results.
* $ODAType = Technology type of the ODA.  This string Will be prepended to rest of query.
_Allowed Values_: 'AD', 'ADS', 'Azure', 'Exchange', 'ExchangeOnline', 'SQL', 'SCOM', 'SCCM', 'SP', 'SPO', 'SfB', 'WindowsClient', 'WindowsServer'

### Example 
> .\ODAAlertOnly_PS.ps1 -RGName _TestRG_ -WKSPName _MyLogsWorkspace_ -ODAType _SQL_

##### Version 1.1 Release Notes
- Added mandatory script parameters.  Validaton set.

##### Version 1.0 Release Notes
- This version of the script does not create to link to an existing Action Group.  Another version that includes action groups will be forthcoming in this same folder.
- Version 1.0 has static parameters for Resource Group, Workgroup name and technology type.  The next version should include default values and dynamic parameters
- There is no error handling at this time.  Next version will include that.
