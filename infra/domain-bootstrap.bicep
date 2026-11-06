targetScope = 'resourceGroup'

@description('Explicit purchase authorization after reviewing domain availability, current prices, registrar terms, and subscription eligibility. False deploys no resources.')
param authorizePurchases bool = false
param domainName string = ''
param location string = resourceGroup().location
param primaryLocation string = 'westus3'
param secondaryLocation string = 'centralus'

@description('Real ICANN registrant contact, supplied through secure, non-versioned parameters. Also used for administrative, billing, and technical contacts.')
@secure()
param registrationContact object = {}

@description('Actual registrar consent: agreementKeys, agreedAt, and agreedBy. Never fabricate acceptance or an IP address.')
@secure()
param domainPurchaseConsent object = {}

@description('Tenant service principal OBJECT ID for Microsoft.Azure.CertificateRegistration; its application ID is f3c21649-0979-4721-ac85-b0216b2cf413.')
param certificateIssuerPrincipalId string = ''
param domainPrivacy bool = true
param autoRenewDomain bool = false
param autoRenewCertificate bool = false
@description('Existing public root TXT values retained by the orchestrator when resuming a partial bootstrap.')
param existingVerificationTxtRecords array = []
param verificationTtl int = 300
param existingVerificationMetadata object = {}
@description('Existing issuer CAA entries retained alongside the explicitly approved GoDaddy issuer.')
param existingIssuerCaaRecords array = []
param issuerCaaTtl int = 300
param existingIssuerMetadata object = {}

var suffix = take(uniqueString(subscription().id, resourceGroup().id), 12)
var vaultName = 'kv-origin-${suffix}'
var certificateSecretName = 'gateway-origin'
var tags = {
  purpose: 'multi-region-lab-domain'
}

resource zone 'Microsoft.Network/dnsZones@2018-05-01' = if (authorizePurchases) {
  name: domainName
  location: 'global'
  tags: tags
}

resource domain 'Microsoft.DomainRegistration/domains@2024-11-01' = if (authorizePurchases) {
  name: domainName
  location: 'global'
  tags: tags
  properties: {
    autoRenew: autoRenewDomain
    privacy: domainPrivacy
    contactRegistrant: registrationContact
    contactAdmin: registrationContact
    contactBilling: registrationContact
    contactTech: registrationContact
    consent: domainPurchaseConsent
    dnsType: 'AzureDns'
    targetDnsType: 'AzureDns'
    dnsZoneId: zone!.id
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = if (authorizePurchases) {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

resource issuerAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (authorizePurchases) {
  name: guid(vault!.id, certificateIssuerPrincipalId, 'certificate-registration-secrets-officer')
  scope: vault
  properties: {
    principalId: certificateIssuerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  }
}

resource order 'Microsoft.CertificateRegistration/certificateOrders@2024-11-01' = if (authorizePurchases) {
  name: 'origin-wildcard-${suffix}'
  location: 'global'
  tags: tags
  properties: {
    distinguishedName: 'CN=*.${domainName}'
    productType: 'StandardDomainValidatedWildCardSsl'
    keySize: 2048
    validityInYears: 1
    autoRenew: autoRenewCertificate
  }
  dependsOn: [domain, issuerAccess, issuerAuthorization]
}

resource certificateBinding 'Microsoft.CertificateRegistration/certificateOrders/certificates@2024-11-01' = if (authorizePurchases) {
  parent: order
  name: 'gateway'
  location: 'global'
  tags: tags
  properties: {
    keyVaultId: vault!.id
    keyVaultSecretName: certificateSecretName
  }
}

resource issuerAuthorization 'Microsoft.Network/dnsZones/CAA@2018-05-01' = if (authorizePurchases) {
  parent: zone
  name: '@'
  properties: {
    TTL: issuerCaaTtl
    metadata: existingIssuerMetadata
    caaRecords: union(existingIssuerCaaRecords, [
      { flags: 0, tag: 'issue', value: 'godaddy.com' }
      { flags: 0, tag: 'issuewild', value: 'godaddy.com' }
    ])
  }
}

resource verification 'Microsoft.Network/dnsZones/TXT@2018-05-01' = if (authorizePurchases) {
  parent: zone
  name: '@'
  properties: {
    TTL: verificationTtl
    metadata: existingVerificationMetadata
    TXTRecords: union(existingVerificationTxtRecords, [
      { value: [order!.properties.domainVerificationToken] }
    ])
  }
}

output purchasesAuthorized bool = authorizePurchases
output APP_GATEWAY_DNS_SUFFIX string = authorizePurchases ? domainName : ''
output APP_GATEWAY_PRIMARY_HOST string = authorizePurchases ? 'gw-${primaryLocation}.${domainName}' : ''
output APP_GATEWAY_SECONDARY_HOST string = authorizePurchases ? 'gw-${secondaryLocation}.${domainName}' : ''
output APP_GATEWAY_KEY_VAULT_NAME string = authorizePurchases ? vault!.name : ''
output APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP string = authorizePurchases ? resourceGroup().name : ''
output gatewayCertificateUri string = authorizePurchases ? '${vault!.properties.vaultUri}secrets/${certificateSecretName}' : ''
output APP_GATEWAY_CERTIFICATE_ORDER_ID string = authorizePurchases ? order!.id : ''
output certificateStatus string = authorizePurchases ? order!.properties.status : 'NotPurchased'
