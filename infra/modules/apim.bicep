param name string
param location string
param secondaryLocation string
param tags object
param publisherName string
param publisherEmail string
param primarySubnetId string
param secondarySubnetId string
param primaryPublicIpId string
param secondaryPublicIpId string
param backendRootCertificate string
param frontDoorId string
param workspaceId string
param privateIngress bool = false

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Premium'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
    virtualNetworkType: privateIngress ? 'Internal' : 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: primarySubnetId
    }
    publicIpAddressId: primaryPublicIpId
    publicNetworkAccess: 'Enabled'
    additionalLocations: [
      {
        location: secondaryLocation
        sku: {
          name: 'Premium'
          capacity: 1
        }
        virtualNetworkConfiguration: {
          subnetResourceId: secondarySubnetId
        }
        publicIpAddressId: secondaryPublicIpId
        disableGateway: false
      }
    ]
    certificates: [
      {
        encodedCertificate: backendRootCertificate
        storeName: 'Root'
      }
    ]
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'False'
    }
  }
}

resource primaryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'aks-br'
  properties: {
    protocol: 'http'
    url: 'https://br.api.lab.internal'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource secondaryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'aks-us'
  properties: {
    protocol: 'http'
    url: 'https://us.api.lab.internal'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'lab'
  properties: {
    displayName: 'Regional laboratory API'
    path: 'lab'
    subscriptionRequired: false
    protocols: [
      'https'
    ]
    format: 'openapi+json'
    value: loadTextContent('../../src/lab-api/openapi.json')
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(loadTextContent('../policies/regional.xml'), '__PRIMARY_REGION__', location)
  }
  dependsOn: [
    observability
    primaryBackend
    secondaryBackend
  ]
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'lab-monitoring'
  scope: apim
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource azureMonitorLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
  }
}

module observability 'apim-observability.bicep' = {
  name: 'apim-observability'
  params: {
    apimName: apim.name
    apiName: api.name
    frontDoorId: frontDoorId
    loggerName: azureMonitorLogger.name
  }
  dependsOn: [
    diagnostics
  ]
}

output apimName string = apim.name
output primaryHost string = first(split(replace(apim.properties.gatewayRegionalUrl, 'https://', ''), '/'))
output secondaryHost string = first(split(replace(apim.properties.additionalLocations[0].gatewayRegionalUrl, 'https://', ''), '/'))
output primaryPrivateIp string = privateIngress ? apim.properties.privateIPAddresses[0] : ''
output secondaryPrivateIp string = privateIngress ? apim.properties.additionalLocations[0].privateIPAddresses[0] : ''
