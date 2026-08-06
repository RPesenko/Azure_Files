@description('The name of the Azure Workbook to create or update.')
param workbookName string

@description('The location of the Azure Workbook.')
param location string = resourceGroup().location

@description('The Azure Resource ID of the target resource the workbook is scoped to. Use empty string for resource group or subscription scope.')
param targetResourceId string = ''

@description('The JSON string content of the workbook definition.')
param workbookDefinition string

@description('The kind of the workbook, e.g. "shared" or "user".')
param kind string = 'shared'

@description('The tags to associate with the workbook.')
param tags object = {}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  location: location
  tags: tags
  kind: kind
  properties: {
    displayName: workbookName
    serializedData: workbookDefinition
    sourceId: empty(targetResourceId) ? null : targetResourceId
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
