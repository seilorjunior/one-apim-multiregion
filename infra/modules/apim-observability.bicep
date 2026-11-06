param apimName string
param apiName string = 'lab'
param frontDoorId string
param loggerName string = 'azuremonitor'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' existing = {
  parent: apim
  name: apiName
}

resource azureMonitorLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' existing = {
  parent: apim
  name: loggerName
}

resource globalPolicy 'Microsoft.ApiManagement/service/policies@2024-05-01' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('../policies/global.xml'), '__FRONT_DOOR_ID__', frontDoorId)
  }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: api
  name: 'azuremonitor'
  properties: {
    loggerId: azureMonitorLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
    logClientIp: false
    frontend: {
      request: {
        headers: []
        body: { bytes: 0 }
      }
      response: {
        headers: [
          'X-Correlation-ID'
          'X-Lab-Gateway-Region'
        ]
        body: { bytes: 0 }
      }
    }
    backend: {
      request: {
        headers: [
          'X-Correlation-ID'
        ]
        body: { bytes: 0 }
      }
      response: {
        headers: [
          'X-Correlation-ID'
          'X-Lab-Backend-Region'
        ]
        body: { bytes: 0 }
      }
    }
  }
}
