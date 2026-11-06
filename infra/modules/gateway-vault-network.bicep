param name string
param location string
param tags object
param vaultId string
param subnetId string
param vnetId string
param dnsResourceGroup string

module dns 'gateway-vault-dns.bicep' = {
  name: 'vault-private-dns'
  scope: resourceGroup(dnsResourceGroup)
  params: {
    vnetId: vnetId
    tags: tags
  }
}

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-vault-${name}'
  location: location
  tags: tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: 'gateway-certificate'
        properties: {
          privateLinkServiceId: vaultId
          groupIds: ['vault']
          requestMessage: 'Regional Application Gateway certificate access'
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: endpoint
  name: 'vault'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: { privateDnsZoneId: dns.outputs.id }
      }
    ]
  }
}

output endpointId string = endpoint.id
output dnsZoneId string = dns.outputs.id
