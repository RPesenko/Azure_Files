# Logic App Templates
### Missing Update Mail
This logic app runs a query on every Wednesday morning to query a Log Analytics workspace for missing security updates.  The results are rendered as an HTML table and inserted into the body of an e-mail.

Things to note:
* The connection to a Log Analytics workspace has to be configured once (but can be used for other Logic Apps)
* The O365 connection has to be configured once (but can be used for other Logic Apps)
* The Logs query can be modified in the template, or after the Logic App has been deployed
* The Update Management solution should be enabled in the Log Analytic workspace in advance, so there is data to query
* The mail recipient defaults to "User@contoso.com" and should be changed to a real user or test mailbox/DL

### ODA Mail
Similar to the Missing Update logic app, this logic app runs a weekly query against a Log Analytics workspace for recommendations against an On Demand assessment.  The results are rendered as an HTML table and inserted into the body of an e-mail after additional formatting is performed by means of an optional CSS.

Things to note:
* The connection to a Log Analytics workspace has to be configured once (but can be used for other Logic Apps)
* The O365 connection has to be configured once (but can be used for other Logic Apps)
* The Logs query can be modified in the template, or after the Logic App has been deployed
* The On Demand Assessment should be enabled in the Log Analytic workspace in advance, so there is data to query
* The mail recipient defaults to "User@contoso.com" and should be changed to a real user or test mailbox/DL


