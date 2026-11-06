param profileName string
param endpointName string
param primaryHost string
param secondaryHost string
param privateIngress bool = false
param primaryPrivateLinkId string = ''
param secondaryPrivateLinkId string = ''
param primaryLocation string = ''
param secondaryLocation string = ''

resource profile 'Microsoft.Cdn/profiles@2024-09-01' existing = {
  name: profileName
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-09-01' existing = {
  parent: profile
  name: endpointName
}

resource group 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = {
  parent: profile
  name: privateIngress ? 'regional-apis-private' : 'regional-apis'
  properties: {
    sessionAffinityState: 'Disabled'
    healthProbeSettings: {
      probePath: '/lab/health/ready'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 30
    }
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
  }
}

resource origins 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = [for origin in [
  { name: 'br', host: primaryHost, privateLinkId: primaryPrivateLinkId, location: primaryLocation }
  { name: 'us', host: secondaryHost, privateLinkId: secondaryPrivateLinkId, location: secondaryLocation }
]: {
  parent: group
  name: origin.name
  properties: union({
    hostName: origin.host
    originHostHeader: origin.host
    httpsPort: 443
    httpPort: 80
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
    priority: 1
    weight: 1000
  }, privateIngress ? {
    sharedPrivateLinkResource: {
      privateLink: { id: origin.privateLinkId }
      groupId: 'private'
      privateLinkLocation: origin.location
      requestMessage: 'apim-lab:${guid(toLower(profile.id))}'
    }
  } : {})
}]

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = {
  parent: endpoint
  name: 'lab-api'
  properties: {
    originGroup: {
      id: group.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    origins
  ]
}
