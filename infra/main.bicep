targetScope = 'subscription'

@minLength(3)
@maxLength(24)
@description('azd environment name: lowercase letters, digits and hyphens; start with a letter.')
param environmentName string

@description('Primary region, using its Azure location name without spaces.')
param location string = 'brazilsouth'
param secondaryLocation string = 'eastus'
param publisherName string
param publisherEmail string

@description('Public DER-encoded laboratory CA certificate in base64. This is not a private key.')
param backendRootCertificate string

@minValue(1)
@maxValue(5)
param aksNodeCount int = 2
param aksVmSize string = 'Standard_D2s_v5'

@description('Entra user object ID receiving persistent Kubernetes Cluster Admin on both AKS clusters. Empty disables creation.')
param aksAdminPrincipalId string = ''

@description('Existing primary cluster role assignment GUID to adopt. Empty generates a deterministic GUID.')
param aksPrimaryAdminRoleAssignmentName string = ''

@description('Existing secondary cluster role assignment GUID to adopt. Empty generates a deterministic GUID.')
param aksSecondaryAdminRoleAssignmentName string = ''

@allowed(['public', 'private'])
@description('Opt-in private ingress uses regional Application Gateways with Front Door Private Link and APIM Internal.')
param ingressMode string = 'public'
@allowed(['auto', 'retain'])
@description('Retain gateway subnets during public-mode rollback while retired Application Gateways still exist.')
param gatewayNetworkMode string = 'auto'
param gatewayPrimaryHost string = ''
param gatewaySecondaryHost string = ''
param gatewayKeyVaultName string = ''
param gatewayKeyVaultResourceGroup string = ''
@allowed(['trusted-services', 'private-endpoints'])
@description('Private endpoints creates isolated regional vault DNS views without enabling public vault access.')
param gatewayKeyVaultNetworkMode string = 'trusted-services'
@description('Versionless HTTPS Key Vault secret URI of a publicly trusted PFX certificate covering both gateway hostnames.')
@secure()
param gatewayCertificateSecretId string = ''

@description('Opt-in operational alerts. Disabled creates no alerting resources or role assignments and requires no notification email.')
param enableOperationalAlerts bool = false
@description('Operational mailbox for enabled alerts. Supply through environment configuration; do not commit personal addresses.')
param alertNotificationEmail string = ''
@description('Optional full ARM ID of the purchased Microsoft.CertificateRegistration/certificateOrders resource, not a Key Vault certificate or secret. Empty omits expiry monitoring.')
param alertCertificateOrderResourceId string = ''
@minValue(1)
@maxValue(365)
param alertCertificateExpiryWarningDays int = 30

var privateIngress = ingressMode == 'private'
var privateVaultNetwork = gatewayKeyVaultNetworkMode == 'private-endpoints' && (privateIngress || gatewayNetworkMode == 'retain')
var suffix = take(uniqueString(subscription().id, environmentName), 8)
var name = '${environmentName}-${suffix}'
// Keep disabled-module scope expressions valid even when no certificate order is configured.
var alertCertificateOrderParts = split(empty(alertCertificateOrderResourceId)
  ? '/subscriptions/${subscription().subscriptionId}/resourceGroups/${rg.name}/providers/Microsoft.CertificateRegistration/certificateOrders/not-configured'
  : alertCertificateOrderResourceId, '/')
var tags = {
  'azd-env-name': environmentName
  purpose: 'multi-region-lab'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${name}'
  location: location
  tags: tags
}

resource primaryVaultDnsRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (privateVaultNetwork) {
  name: 'rg-${name}-vault-dns-br'
  location: location
  tags: tags
}

resource secondaryVaultDnsRg 'Microsoft.Resources/resourceGroups@2024-03-01' = if (privateVaultNetwork) {
  name: 'rg-${name}-vault-dns-us'
  location: secondaryLocation
  tags: tags
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    name: name
    location: location
    tags: tags
  }
}

module primary 'modules/region.bicep' = {
  name: 'primary-region'
  scope: rg
  params: {
    name: '${name}-br'
    location: location
    tags: tags
    addressPrefix: '10.10'
    backendRecord: 'br'
    nodeCount: aksNodeCount
    vmSize: aksVmSize
    workspaceId: monitoring.outputs.workspaceId
    adminPrincipalId: aksAdminPrincipalId
    adminRoleAssignmentName: aksPrimaryAdminRoleAssignmentName
    privateIngress: privateIngress
    retainGatewayNetwork: gatewayNetworkMode == 'retain'
  }
}

module secondary 'modules/region.bicep' = {
  name: 'secondary-region'
  scope: rg
  params: {
    name: '${name}-us'
    location: secondaryLocation
    tags: tags
    addressPrefix: '10.20'
    backendRecord: 'us'
    nodeCount: aksNodeCount
    vmSize: aksVmSize
    workspaceId: monitoring.outputs.workspaceId
    adminPrincipalId: aksAdminPrincipalId
    adminRoleAssignmentName: aksSecondaryAdminRoleAssignmentName
    privateIngress: privateIngress
    retainGatewayNetwork: gatewayNetworkMode == 'retain'
  }
}

module edge 'modules/edge.bicep' = {
  name: 'edge'
  scope: rg
  params: {
    name: name
    location: 'global'
    tags: tags
    workspaceId: monitoring.outputs.workspaceId
  }
}

module gatewayIdentity 'modules/gateway-identity.bicep' = if (privateIngress) {
  name: 'gateway-identity'
  scope: rg
  params: {
    name: name
    location: location
    tags: tags
  }
}

module gatewayVaultAccess 'modules/gateway-vault-access.bicep' = if (privateIngress) {
  name: 'gateway-vault-access'
  scope: resourceGroup(empty(gatewayKeyVaultResourceGroup) ? rg.name : gatewayKeyVaultResourceGroup)
  params: {
    vaultName: gatewayKeyVaultName
    principalId: gatewayIdentity!.outputs.principalId
  }
}

module primaryGateway 'modules/application-gateway.bicep' = if (privateIngress) {
  name: 'primary-application-gateway'
  scope: rg
  params: {
    name: '${name}-br'
    location: location
    tags: tags
    subnetId: primary.outputs.gatewaySubnetId
    privateLinkSubnetId: primary.outputs.gatewayPrivateLinkSubnetId
    frontendIp: '10.10.3.10'
    listenerHost: gatewayPrimaryHost
    certificateSecretId: gatewayCertificateSecretId
    identityId: gatewayIdentity!.outputs.id
    apimHost: apim.outputs.primaryHost
    apimPrivateIp: apim.outputs.primaryPrivateIp
    workspaceId: monitoring.outputs.workspaceId
  }
  dependsOn: [gatewayVaultAccess, primaryVaultNetwork]
}

module secondaryGateway 'modules/application-gateway.bicep' = if (privateIngress) {
  name: 'secondary-application-gateway'
  scope: rg
  params: {
    name: '${name}-us'
    location: secondaryLocation
    tags: tags
    subnetId: secondary.outputs.gatewaySubnetId
    privateLinkSubnetId: secondary.outputs.gatewayPrivateLinkSubnetId
    frontendIp: '10.20.3.10'
    listenerHost: gatewaySecondaryHost
    certificateSecretId: gatewayCertificateSecretId
    identityId: gatewayIdentity!.outputs.id
    apimHost: apim.outputs.secondaryHost
    apimPrivateIp: apim.outputs.secondaryPrivateIp
    workspaceId: monitoring.outputs.workspaceId
  }
  dependsOn: [gatewayVaultAccess, secondaryVaultNetwork]
}

module primaryVaultNetwork 'modules/gateway-vault-network.bicep' = if (privateVaultNetwork) {
  name: 'primary-vault-network'
  scope: rg
  params: {
    name: '${name}-br'
    location: location
    tags: tags
    vaultId: resourceId(subscription().subscriptionId, gatewayKeyVaultResourceGroup, 'Microsoft.KeyVault/vaults', gatewayKeyVaultName)
    subnetId: primary.outputs.vaultEndpointSubnetId
    vnetId: primary.outputs.vnetId
    dnsResourceGroup: primaryVaultDnsRg!.name
  }
}

module secondaryVaultNetwork 'modules/gateway-vault-network.bicep' = if (privateVaultNetwork) {
  name: 'secondary-vault-network'
  scope: rg
  params: {
    name: '${name}-us'
    location: secondaryLocation
    tags: tags
    vaultId: resourceId(subscription().subscriptionId, gatewayKeyVaultResourceGroup, 'Microsoft.KeyVault/vaults', gatewayKeyVaultName)
    subnetId: secondary.outputs.vaultEndpointSubnetId
    vnetId: secondary.outputs.vnetId
    dnsResourceGroup: secondaryVaultDnsRg!.name
  }
}

module apim 'modules/apim.bicep' = {
  name: 'api-management'
  scope: rg
  params: {
    name: 'apim-${name}'
    location: location
    secondaryLocation: secondaryLocation
    tags: tags
    publisherName: publisherName
    publisherEmail: publisherEmail
    primarySubnetId: primary.outputs.apimSubnetId
    secondarySubnetId: secondary.outputs.apimSubnetId
    primaryPublicIpId: primary.outputs.apimPublicIpId
    secondaryPublicIpId: secondary.outputs.apimPublicIpId
    backendRootCertificate: backendRootCertificate
    frontDoorId: edge.outputs.frontDoorId
    workspaceId: monitoring.outputs.workspaceId
    privateIngress: privateIngress
  }
}

module routing 'modules/routing.bicep' = {
  name: 'edge-routing'
  scope: rg
  params: {
    profileName: edge.outputs.profileName
    endpointName: edge.outputs.endpointName
    primaryHost: privateIngress ? gatewayPrimaryHost : apim.outputs.primaryHost
    secondaryHost: privateIngress ? gatewaySecondaryHost : apim.outputs.secondaryHost
    privateIngress: privateIngress
    primaryPrivateLinkId: privateIngress ? primaryGateway!.outputs.id : ''
    secondaryPrivateLinkId: privateIngress ? secondaryGateway!.outputs.id : ''
    primaryLocation: location
    secondaryLocation: secondaryLocation
  }
}

module operationalAlerts 'modules/alerts.bicep' = if (enableOperationalAlerts) {
  name: 'operational-alerts'
  scope: rg
  params: {
    name: name
    location: location
    tags: tags
    notificationEmail: alertNotificationEmail
    workspaceId: monitoring.outputs.workspaceId
    profileId: resourceId(rg.name, 'Microsoft.Cdn/profiles', edge.outputs.profileName)
    originGroup: privateIngress ? 'regional-apis-private' : 'regional-apis'
    originHosts: [
      privateIngress ? gatewayPrimaryHost : apim.outputs.primaryHost
      privateIngress ? gatewaySecondaryHost : apim.outputs.secondaryHost
    ]
    gatewayIds: privateIngress ? [primaryGateway!.outputs.id, secondaryGateway!.outputs.id] : []
    certificateOrderResourceId: alertCertificateOrderResourceId
    certificateExpiryWarningDays: alertCertificateExpiryWarningDays
  }
  dependsOn: [routing]
}

// Reuse the access-only mode at the order's own resource group, including orders outside the lab RG.
module certificateAlertAccess 'modules/alerts.bicep' = if (enableOperationalAlerts && !empty(alertCertificateOrderResourceId)) {
  name: 'certificate-alert-reader'
  scope: resourceGroup(alertCertificateOrderParts[2], alertCertificateOrderParts[4])
  params: {
    name: name
    location: location
    tags: tags
    notificationEmail: alertNotificationEmail
    certificateAccessOnly: true
    certificateOrderResourceId: alertCertificateOrderResourceId
    certificateReaderPrincipalId: operationalAlerts!.outputs.queryPrincipalId
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_PRIMARY_LOCATION string = location
output AZURE_SECONDARY_LOCATION string = secondaryLocation
output APIM_NAME string = apim.outputs.apimName
output APIM_PRIMARY_HOST string = apim.outputs.primaryHost
output APIM_SECONDARY_HOST string = apim.outputs.secondaryHost
output AKS_PRIMARY_NAME string = primary.outputs.aksName
output AKS_SECONDARY_NAME string = secondary.outputs.aksName
output BACKEND_PRIMARY_IP string = primary.outputs.backendIp
output BACKEND_SECONDARY_IP string = secondary.outputs.backendIp
output APIM_PRIMARY_SUBNET string = primary.outputs.apimSubnetPrefix
output APIM_SECONDARY_SUBNET string = secondary.outputs.apimSubnetPrefix
output AZURE_FRONT_DOOR_PROFILE string = edge.outputs.profileName
output AZURE_FRONT_DOOR_ENDPOINT string = edge.outputs.endpointName
output AZURE_FRONT_DOOR_ID string = edge.outputs.frontDoorId
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.workspaceId
output API_URL string = 'https://${edge.outputs.hostName}/lab'
output APP_INGRESS_MODE string = ingressMode
output APP_GATEWAY_NETWORK_MODE string = privateIngress ? 'retain' : gatewayNetworkMode
output APP_GATEWAY_KEY_VAULT_NETWORK_MODE string = gatewayKeyVaultNetworkMode
output APP_GATEWAY_PRIMARY_VAULT_ENDPOINT_ID string = privateVaultNetwork ? primaryVaultNetwork!.outputs.endpointId : ''
output APP_GATEWAY_SECONDARY_VAULT_ENDPOINT_ID string = privateVaultNetwork ? secondaryVaultNetwork!.outputs.endpointId : ''
output APP_GATEWAY_PRIMARY_VAULT_DNS_ZONE_ID string = privateVaultNetwork ? primaryVaultNetwork!.outputs.dnsZoneId : ''
output APP_GATEWAY_SECONDARY_VAULT_DNS_ZONE_ID string = privateVaultNetwork ? secondaryVaultNetwork!.outputs.dnsZoneId : ''
output APP_GATEWAY_PRIMARY_ID string = privateIngress ? primaryGateway!.outputs.id : ''
output APP_GATEWAY_SECONDARY_ID string = privateIngress ? secondaryGateway!.outputs.id : ''
output FRONT_DOOR_PRIMARY_ORIGIN_HOST string = privateIngress ? gatewayPrimaryHost : apim.outputs.primaryHost
output FRONT_DOOR_SECONDARY_ORIGIN_HOST string = privateIngress ? gatewaySecondaryHost : apim.outputs.secondaryHost
output FRONT_DOOR_ORIGIN_GROUP string = privateIngress ? 'regional-apis-private' : 'regional-apis'
output OPERATIONAL_ALERTS_ENABLED bool = enableOperationalAlerts
output CERTIFICATE_EXPIRY_MONITOR_STATUS string = !enableOperationalAlerts
  ? 'disabled'
  : empty(alertCertificateOrderResourceId)
    ? 'not-configured: certificate expiry is NOT monitored; set APP_GATEWAY_CERTIFICATE_ORDER_ID'
    : 'configured: hourly ARG order metadata; missing order or expiry raises an alert'
