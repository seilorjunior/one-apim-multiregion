param name string
param location string
param tags object
param subnetId string
param privateLinkSubnetId string
param frontendIp string
@minLength(1)
param listenerHost string
@secure()
@minLength(1)
param certificateSecretId string
param identityId string
param apimHost string
param apimPrivateIp string
param workspaceId string

var gatewayName = 'agw-${name}'
var gatewayId = resourceId('Microsoft.Network/applicationGateways', gatewayName)
var privateLinkName = 'frontdoor'

// The public IP supports the v2 infrastructure; no listener uses its frontend.
resource infrastructureIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-agw-${name}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource gateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: gatewayName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 2
      maxCapacity: 4
    }
    enableHttp2: true
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101S'
    }
    gatewayIPConfigurations: [
      {
        name: 'gateway'
        properties: {
          subnet: { id: subnetId }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'infrastructure'
        properties: {
          publicIPAddress: { id: infrastructureIp.id }
        }
      }
      {
        name: 'private'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: frontendIp
          subnet: { id: subnetId }
          privateLinkConfiguration: {
            id: '${gatewayId}/privateLinkConfigurations/${privateLinkName}'
          }
        }
      }
    ]
    privateLinkConfigurations: [
      {
        name: privateLinkName
        properties: {
          ipConfigurations: [
            {
              name: 'primary'
              properties: {
                primary: true
                privateIPAllocationMethod: 'Dynamic'
                subnet: { id: privateLinkSubnetId }
              }
            }
          ]
        }
      }
    ]
    frontendPorts: [
      { name: 'https', properties: { port: 443 } }
    ]
    sslCertificates: [
      { name: 'listener', properties: { keyVaultSecretId: certificateSecretId } }
    ]
    httpListeners: [
      {
        name: 'private-https'
        properties: {
          frontendIPConfiguration: { id: '${gatewayId}/frontendIPConfigurations/private' }
          frontendPort: { id: '${gatewayId}/frontendPorts/https' }
          sslCertificate: { id: '${gatewayId}/sslCertificates/listener' }
          protocol: 'Https'
          hostName: listenerHost
          requireServerNameIndication: true
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'regional-apim'
        properties: {
          backendAddresses: [
            { ipAddress: apimPrivateIp }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'apim-gateway'
        properties: {
          protocol: 'Https'
          path: '/status-0123456789abcdef'
          pickHostNameFromBackendHttpSettings: true
          interval: 30
          timeout: 20
          unhealthyThreshold: 3
          match: { statusCodes: ['200'] }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'apim-https'
        properties: {
          port: 443
          protocol: 'Https'
          hostName: apimHost
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 25
          probe: { id: '${gatewayId}/probes/apim-gateway' }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'api'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: { id: '${gatewayId}/httpListeners/private-https' }
          backendAddressPool: { id: '${gatewayId}/backendAddressPools/regional-apim' }
          backendHttpSettings: { id: '${gatewayId}/backendHttpSettingsCollection/apim-https' }
        }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'lab-monitoring'
  scope: gateway
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'ApplicationGatewayAccessLog', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output id string = gateway.id
