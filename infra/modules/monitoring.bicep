param name string
param location string
param tags object

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${name}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: 1
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

module workbook 'operations-workbook.bicep' = {
  name: 'operations-workbook'
  params: {
    name: name
    location: location
    tags: tags
    workspaceName: workspace.name
  }
}

output workspaceId string = workspace.id
output operationsWorkbookId string = workbook.outputs.operationsWorkbookId
