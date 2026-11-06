param name string
param location string
param tags object
param workspaceName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

var querySources = [
  { title: 'Front Door: access, probes and WAF (provider-native IDs)', query: loadTextContent('../queries/front-door.kql') }
  { title: 'Application Gateway: private-ingress access (optional tier)', query: loadTextContent('../queries/application-gateway.kql') }
  { title: 'APIM: response/backend correlation and regional gateway status', query: loadTextContent('../queries/apim-correlation.kql') }
  { title: 'AKS: control-plane activity only', query: loadTextContent('../queries/aks-control-plane.kql') }
  { title: 'AKS: optional existing ContainerLogV2 backend correlation', query: loadTextContent('../queries/aks-correlation.kql') }
]

var queryItems = [for (source, index) in querySources: {
  type: 3
  name: 'query-${index}'
  content: {
    version: 'KqlItem/1.0'
    title: source.title
    query: source.query
    queryType: 0
    resourceType: 'microsoft.operationalinsights/workspaces'
    crossComponentResources: [
      workspace.id
    ]
    visualization: 'table'
    timeContext: {
      durationMs: 3600000
    }
  }
}]

// Workbook metadata reuses existing diagnostics; no new ingestion pipeline or paid service.
resource operationsWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, name, 'regional-operations')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Regional API operations - ${name}'
    category: 'workbook'
    sourceId: workspace.id
    serializedData: string({
      version: 'Notebook/1.0'
      isLocked: false
      fallbackResourceIds: [
        workspace.id
      ]
      items: concat([
        {
          type: 1
          name: 'evidence-boundaries'
          content: {
            json: '''
## Regional API evidence (last hour)
Each section is a separate tier, not a universal distributed trace. Front Door tracking references, Application Gateway transaction IDs and APIM provider request/correlation IDs differ; do not join them as if they were the same ID. Time/resource/region comparisons are contextual evidence only.

The validated `X-Correlation-ID` GUID is propagated from APIM to nginx and returned on responses, including policy-handled errors. It is an untrusted diagnostic label, not authentication or a unique request guarantee. Failures before APIM (Front Door/WAF/Application Gateway/TLS) cannot receive this APIM-generated header.

APIM request detail shows only allowlisted diagnostic headers; nginx JSON logs exclude raw targets, query strings, bodies and credentials. Existing provider diagnostics can still contain URLs; protect workspace access and never send secrets in URLs.

AKS control-plane activity is not pod traffic. ContainerLogV2 is optional and is NOT enabled here. Inspect nginx JSON through `kubectl logs` when no container log collection exists. Empty/missing/stale data is NOT healthy evidence. Existing strict metric, readiness and failover gates remain authoritative.

This workbook adds metadata/query sources only. Existing workspace ingestion, retention and query charges still apply; separately authorize Container Insights or any other ingestion expansion. Queries target the existing AzureDiagnostics settings; externally migrated resource-specific tables require adapting queries.
'''
          }
        }
      ], queryItems)
    })
  }
}

output operationsWorkbookId string = operationsWorkbook.id
