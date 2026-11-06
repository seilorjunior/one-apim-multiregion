param name string
param location string
param tags object
@minLength(3)
@description('Required only when this opt-in module is deployed. Use an operational mailbox.')
param notificationEmail string
param workspaceId string = ''
param profileId string = ''
param originGroup string = ''
param originHosts array = []
param gatewayIds array = []
param certificateOrderResourceId string = ''
@minValue(1)
@maxValue(365)
param certificateExpiryWarningDays int = 30

// A second instance grants only order-scoped management-plane access in the order's resource group.
param certificateAccessOnly bool = false
param certificateReaderPrincipalId string = ''

var createRules = !certificateAccessOnly
var workspaceName = createRules ? last(split(workspaceId, '/')) : 'not-configured'
var certificateOrderName = certificateAccessOnly ? last(split(certificateOrderResourceId, '/')) : 'not-configured'
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
var logReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (createRules) {
  name: 'ag-${name}-operations'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'lab-ops'
    enabled: true
    emailReceivers: [
      {
        name: 'operations'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// Supported metrics: https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-cdn-profiles-metrics
resource originUnavailable 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (host, index) in originHosts: if (createRules) {
  name: '${name}-origin-${index}-unavailable'
  location: 'global'
  tags: tags
  properties: {
    description: 'Origin ${host}: successful Front Door health probes average below 1% for five minutes. Missing metrics do not trigger this alert.'
    severity: 1
    enabled: true
    scopes: [profileId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'origin-health'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Cdn/profiles'
          metricName: 'OriginHealthPercentage'
          timeAggregation: 'Average'
          operator: 'LessThan'
          threshold: 1
          dimensions: [
            { name: 'Origin', operator: 'Include', values: ['${host}:443'] }
            { name: 'OriginGroup', operator: 'Include', values: [originGroup] }
          ]
        }
      ]
    }
    actions: [{ actionGroupId: actionGroup!.id }]
  }
}]

resource http5xx 'Microsoft.Insights/metricAlerts@2018-03-01' = if (createRules) {
  name: '${name}-frontdoor-http5xx'
  location: 'global'
  tags: tags
  properties: {
    description: 'Front Door client HTTP 5xx percentage averages above 1% for five minutes; not a request-count or synthetic availability check.'
    severity: 2
    enabled: true
    scopes: [profileId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'http5xx'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Cdn/profiles'
          metricName: 'Percentage5XX'
          timeAggregation: 'Average'
          operator: 'GreaterThan'
          threshold: 1
        }
      ]
    }
    actions: [{ actionGroupId: actionGroup!.id }]
  }
}

// Supported metric: https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-applicationgateways-metrics
resource unhealthyBackend 'Microsoft.Insights/metricAlerts@2018-03-01' = [for (gatewayId, index) in gatewayIds: if (createRules) {
  name: '${name}-gateway-${index}-unhealthy-backend'
  location: 'global'
  tags: tags
  properties: {
    description: 'Application Gateway reports an unhealthy backend in any backend settings pool over five minutes.'
    severity: 1
    enabled: true
    scopes: [gatewayId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'unhealthy-backend'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Network/applicationGateways'
          metricName: 'UnhealthyHostCount'
          timeAggregation: 'Average'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            { name: 'BackendSettingsPool', operator: 'Include', values: ['*'] }
          ]
        }
      ]
    }
    actions: [{ actionGroupId: actionGroup!.id }]
  }
}]

resource queryIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (createRules) {
  name: 'id-${name}-alert-query'
  location: location
  tags: tags
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (createRules) {
  name: workspaceName
}

resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (createRules) {
  name: guid(workspace.id, name, 'alert-log-reader')
  scope: workspace
  properties: {
    roleDefinitionId: logReaderRoleId
    principalId: queryIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource certificateOrder 'Microsoft.CertificateRegistration/certificateOrders@2024-11-01' existing = if (certificateAccessOnly) {
  name: certificateOrderName
}

resource certificateReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (certificateAccessOnly) {
  name: guid(certificateOrder.id, certificateReaderPrincipalId, readerRoleId)
  scope: certificateOrder
  properties: {
    roleDefinitionId: readerRoleId
    principalId: certificateReaderPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Microsoft's documented cap signal, not a fabricated workspace metric:
// https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap#alert-when-daily-cap-is-reached
resource ingestionCap 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (createRules) {
  name: '${name}-ingestion-daily-cap'
  location: location
  tags: tags
  kind: 'LogAlert'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${queryIdentity!.id}': {} }
  }
  properties: {
    displayName: 'Log Analytics daily cap reached'
    description: 'Post-cap _LogOperation OverQuota event, not an approaching-cap warning or guaranteed ingestion/billing limit.'
    enabled: true
    severity: 2
    scopes: [workspaceId]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    autoMitigate: true
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: '''
            _LogOperation
            | where TimeGenerated >= ago(5m)
            | where Category =~ "Ingestion"
            | where Detail contains "OverQuota"
            '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [actionGroup!.id] }
  }
  dependsOn: [workspaceReader]
}

// ARG cross-service log alerts are public preview and require managed identity and public-cloud support:
// https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule
// Order metadata: https://learn.microsoft.com/dotnet/api/microsoft.azure.powershell.cmdlets.functions.models.iappservicecertificateorder.signedcertificatenotafter
// ARG can lag ARM and omit properties. Missing order/expiry is an alert, never interpreted as a healthy certificate.
// This observes the purchased ORDER, not the certificate served by a listener, and never reads the private vault.
resource certificateExpiry 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (createRules && !empty(certificateOrderResourceId)) {
  name: '${name}-certificate-order-expiry'
  location: location
  tags: tags
  kind: 'LogAlert'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${queryIdentity!.id}': {} }
  }
  properties: {
    displayName: 'Certificate order expiring or metadata unavailable'
    description: 'Order signedCertificate.notAfter within ${certificateExpiryWarningDays} days, already expired, or absent in ARG. Does not verify listener certificate deployment or renewal.'
    enabled: true
    severity: 2
    scopes: [workspaceId]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    autoMitigate: true
    // Order-scoped RBAC is granted by a second module after this identity exists; allow propagation before evaluation.
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: format('''
            arg("").Resources
            | where type =~ 'microsoft.certificateregistration/certificateorders'
            | where id =~ '{0}'
            | project Expiry = todatetime(properties.signedCertificate.notAfter)
            | summarize Expiry = max(Expiry), Orders = count()
            | where Orders != 1 or isnull(Expiry) or Expiry <= now() + {1}d
            | project TimeGenerated = now(), CertificateOrderId = '{0}', Expiry,
                Reason = iff(Orders != 1 or isnull(Expiry), 'Order or expiry metadata unavailable in ARG', 'Certificate order expiring or expired')
            ''', certificateOrderResourceId, certificateExpiryWarningDays)
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            { name: 'Reason', operator: 'Include', values: ['*'] }
          ]
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [actionGroup!.id] }
  }
  dependsOn: [workspaceReader]
}

output queryPrincipalId string = createRules ? queryIdentity!.properties.principalId : ''
