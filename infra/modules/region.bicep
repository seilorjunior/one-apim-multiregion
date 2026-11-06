param name string
param location string
param tags object
param addressPrefix string
param backendRecord string
param nodeCount int
param vmSize string
param workspaceId string
param adminPrincipalId string = ''
param adminRoleAssignmentName string = ''
param privateIngress bool = false
param retainGatewayNetwork bool = false

var gatewayNetwork = privateIngress || retainGatewayNetwork

var clusterAdminRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')

var apimSubnetPrefix = '${addressPrefix}.0.0/26'
var nodeSubnetPrefix = '${addressPrefix}.1.0/24'
var backendSubnetPrefix = '${addressPrefix}.2.0/27'
var backendIp = '${addressPrefix}.2.10'
var privateZoneName = 'api.lab.internal'

resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-apim-${name}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: privateIngress ? 'AllowApplicationGatewayHttps' : 'AllowFrontDoorHttps'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: privateIngress ? '${addressPrefix}.3.0/24' : 'AzureFrontDoor.Backend'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowApimManagement'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3443'
          sourceAddressPrefix: 'ApiManagement'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowPlatformHealth'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '6390'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowNativeMultiRegionHealth'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'AzureTrafficManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherGatewayAccess'
        properties: {
          priority: 140
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherManagementAccess'
        properties: {
          priority: 150
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nodeNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-aks-${name}'
  location: location
  tags: tags
  properties: {}
}

resource gatewayNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (gatewayNetwork) {
  name: 'nsg-agw-${name}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowPrivateLinkHttps'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '${addressPrefix}.4.0/27'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowGatewayManager'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowPlatformHealth'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherHttps'
        properties: {
          priority: 130
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: ['80', '443']
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${name}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '${addressPrefix}.0.0/16'
      ]
    }
    subnets: concat([
      {
        name: 'apim'
        properties: {
          addressPrefix: apimSubnetPrefix
          networkSecurityGroup: {
            id: apimNsg.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
            {
              service: 'Microsoft.Sql'
            }
            {
              service: 'Microsoft.KeyVault'
            }
          ]
        }
      }
      {
        name: 'aks'
        properties: {
          addressPrefix: nodeSubnetPrefix
          networkSecurityGroup: {
            id: nodeNsg.id
          }
        }
      }
      {
        name: 'backend'
        properties: {
          addressPrefix: backendSubnetPrefix
        }
      }
    ], gatewayNetwork ? [
      {
        name: 'application-gateway'
        properties: {
          addressPrefix: '${addressPrefix}.3.0/24'
          networkSecurityGroup: { id: gatewayNsg!.id }
          serviceEndpoints: [{ service: 'Microsoft.KeyVault' }]
        }
      }
      {
        name: 'gateway-private-link'
        properties: {
          addressPrefix: '${addressPrefix}.4.0/27'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'vault-private-endpoints'
        properties: {
          addressPrefix: '${addressPrefix}.5.0/27'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ] : [])
  }
}

resource apimPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-apim-${name}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    dnsSettings: {
      domainNameLabel: 'apim-${name}'
    }
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-aks-${name}'
  location: location
  tags: tags
}

resource networkRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vnet.id, identity.id, 'network-contributor')
  scope: vnet
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2025-01-01' = {
  name: 'aks-${name}'
  location: location
  tags: union(tags, {
    'azd-service-name': 'lab-api'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  properties: {
    dnsPrefix: 'aks-${name}'
    nodeResourceGroup: 'rg-nodes-${name}'
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: tenant().tenantId
    }
    apiServerAccessProfile: {
      enablePrivateCluster: true
      enablePrivateClusterPublicFQDN: false
      privateDNSZone: 'System'
      disableRunCommand: false
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: nodeCount
        vmSize: vmSize
        mode: 'System'
        type: 'VirtualMachineScaleSets'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        osDiskType: 'Managed'
        osDiskSizeGB: 64
        maxPods: 30
        vnetSubnetID: '${vnet.id}/subnets/aks'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkPolicy: 'calico'
      podCidr: '${addressPrefix == '10.10' ? '10.240' : '10.241'}.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'NodeImage'
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
  dependsOn: [
    networkRole
  ]
}

resource userClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminPrincipalId)) {
  name: empty(adminRoleAssignmentName) ? guid(aks.id, adminPrincipalId, clusterAdminRoleId) : adminRoleAssignmentName
  scope: aks
  properties: {
    principalId: adminPrincipalId
    principalType: 'User'
    roleDefinitionId: clusterAdminRoleId
    description: 'Persistent Kubernetes administration for the lab deployment user, requested by the user.'
  }
}

resource privateZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: '${backendRecord}.${privateZoneName}'
  location: 'global'
  tags: tags
}

resource zoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateZone
  name: 'regional-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource backendRecordSet 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateZone
  name: '@'
  properties: {
    ttl: 30
    aRecords: [
      {
        ipv4Address: backendIp
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'lab-monitoring'
  scope: aks
  properties: {
    workspaceId: workspaceId
    logs: [
      {
        category: 'kube-apiserver'
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

output apimSubnetId string = '${vnet.id}/subnets/apim'
output apimSubnetPrefix string = apimSubnetPrefix
output apimPublicIpId string = apimPublicIp.id
output aksName string = aks.name
output backendIp string = backendIp
output gatewaySubnetId string = '${vnet.id}/subnets/application-gateway'
output gatewayPrivateLinkSubnetId string = '${vnet.id}/subnets/gateway-private-link'
output vaultEndpointSubnetId string = '${vnet.id}/subnets/vault-private-endpoints'
output vnetId string = vnet.id
