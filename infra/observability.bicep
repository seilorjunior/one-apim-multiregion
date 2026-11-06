targetScope = 'resourceGroup'

@description('Original lab name used to preserve the existing workbook resource ID and display name.')
@minLength(1)
param name string

param apimName string = 'apim-${name}'
param workspaceName string = 'log-${name}'
param location string = resourceGroup().location
param tags object = {}

@description('The existing Front Door profile GUID, NOT its ARM resource ID. Preserves the current global policy access-control boundary.')
@minLength(36)
@maxLength(36)
param frontDoorId string

@description('Existing API and Azure Monitor logger must already be provisioned; this entrypoint never recreates them.')
param apiName string = 'lab'
param loggerName string = 'azuremonitor'

// Incremental deployment only: no APIM service, workspace, compute or networking PUTs.
module apimObservability 'modules/apim-observability.bicep' = {
  name: 'apim-observability'
  params: {
    apimName: apimName
    apiName: apiName
    frontDoorId: frontDoorId
    loggerName: loggerName
  }
}

module workbook 'modules/operations-workbook.bicep' = {
  name: 'operations-workbook'
  params: {
    name: name
    location: location
    tags: tags
    workspaceName: workspaceName
  }
}

output operationsWorkbookId string = workbook.outputs.operationsWorkbookId
