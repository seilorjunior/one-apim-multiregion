#requires -Version 7.4
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\powershell\Lab.Common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('apim-lab-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
$checks = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $ExpectedMessage)
    $caught = $false
    try { & $Action }
    catch {
        $caught = $true
        Assert-True ($_.Exception.Message -like "*$ExpectedMessage*") "Unexpected exception: $($_.Exception.Message)"
    }
    Assert-True $caught "Expected failure containing: $ExpectedMessage"
}

function Get-ArmResources {
    param([psobject] $Template)
    foreach ($resource in $Template.resources) {
        $resource
        if ($resource.type -eq 'Microsoft.Resources/deployments') {
            Get-ArmResources $resource.properties.template
        }
    }
}

function New-TestResponse {
    param([string] $Body, [string] $Gateway = 'Brazil South')
    $http = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
    $http.RequestMessage = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'https://lab.invalid/whoami')
    $http.Content = [System.Net.Http.StringContent]::new($Body)
    $null = $http.Headers.TryAddWithoutValidation('X-Lab-Gateway-Region', $Gateway)
    return [Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]::new(
        $http, [TimeSpan]::FromSeconds(5), [Threading.CancellationToken]::None
    )
}

try {
    foreach ($script in Get-ChildItem (Join-Path $root 'scripts\powershell') -Filter '*.ps1') {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref] $tokens, [ref] $parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "Invalid PowerShell: $($script.Name): $parseErrors"
    }
    $build = Join-Path $temporary 'main.json'
    $null = Invoke-LabNative bicep @('build', (Join-Path $root 'infra\main.bicep'), '--outfile', $build)
    $template = Get-Content -LiteralPath $build -Raw | ConvertFrom-Json
    $bootstrapBuild = Join-Path $temporary 'domain-bootstrap.json'
    $null = Invoke-LabNative bicep @('build', (Join-Path $root 'infra\domain-bootstrap.bicep'), '--outfile', $bootstrapBuild)
    $bootstrap = Get-Content -LiteralPath $bootstrapBuild -Raw | ConvertFrom-Json
    Assert-True (-not $bootstrap.parameters.authorizePurchases.defaultValue) 'Domain and certificate purchases must be disabled by default.'
    Assert-True ($bootstrap.parameters.registrationContact.type -eq 'secureObject') 'Registrant personal data must be a secure parameter.'
    Assert-True ($bootstrap.parameters.domainPurchaseConsent.type -eq 'secureObject') 'Registrar consent must be supplied securely, not fabricated.'
    Assert-True (-not $bootstrap.parameters.autoRenewDomain.defaultValue -and -not $bootstrap.parameters.autoRenewCertificate.defaultValue) 'Renewals require separate opt-in.'
    foreach ($resource in $bootstrap.resources) {
        Assert-True ($resource.condition -eq "[parameters('authorizePurchases')]") 'Every bootstrap resource must require explicit purchase authorization.'
    }
    $purchase = @($bootstrap.resources | Where-Object type -EQ 'Microsoft.DomainRegistration/domains')[0]
    Assert-True ($purchase.properties.consent -eq "[parameters('domainPurchaseConsent')]") 'Purchase must use the actual supplied registrar consent.'
    Assert-True ($purchase.properties.dnsType -eq 'AzureDns') 'Purchased domain must delegate to the provisioned Azure DNS zone.'
    $order = @($bootstrap.resources | Where-Object type -EQ 'Microsoft.CertificateRegistration/certificateOrders')[0]
    Assert-True ($order.properties.productType -eq 'StandardDomainValidatedWildCardSsl') 'Both regional hostnames require the paid wildcard product.'
    Assert-True ($order.properties.distinguishedName -eq "[format('CN=*.{0}', parameters('domainName'))]") 'Certificate wildcard must match the purchased domain.'
    Assert-True (-not $order.properties.PSObject.Properties['certificates']) 'Order creation must omit the read-only certificates collection.'
    $bindings = @($bootstrap.resources | Where-Object type -EQ 'Microsoft.CertificateRegistration/certificateOrders/certificates')
    Assert-True ($bindings.Count -eq 1) 'The certificate order must have exactly one separately deployed vault binding.'
    $binding = $bindings[0]
    Assert-True ($binding.properties.keyVaultSecretName -eq "[variables('certificateSecretName')]") 'Azure must store the issued certificate in the configured vault secret.'
    Assert-True ($binding.properties.keyVaultId -like '*Microsoft.KeyVault/vaults*') 'The certificate binding must reference the dedicated vault.'
    Assert-True (@($binding.dependsOn | Where-Object { $_ -like '*Microsoft.CertificateRegistration/certificateOrders*' }).Count -eq 1) 'The vault binding must be deployed after its certificate order.'
    $bootstrapVault = @($bootstrap.resources | Where-Object type -EQ 'Microsoft.KeyVault/vaults')[0]
    Assert-True $bootstrapVault.properties.enableRbacAuthorization 'Bootstrap vault must use Azure RBAC.'
    Assert-True $bootstrapVault.properties.enablePurgeProtection 'Bootstrap vault must retain purge protection.'
    Assert-True ($bootstrapVault.properties.networkAcls.defaultAction -eq 'Deny') 'Bootstrap vault must reject untrusted network access.'
    Assert-True ($bootstrapVault.properties.publicNetworkAccess -eq 'Disabled') 'Paid bootstrap must preserve private-only vault access explicitly, without relying on policy mutation.'
    $issuerRole = @($bootstrap.resources | Where-Object type -EQ 'Microsoft.Authorization/roleAssignments')[0]
    Assert-True ($issuerRole.properties.principalId -eq "[parameters('certificateIssuerPrincipalId')]") 'Certificate issuer must use the tenant service principal object ID.'
    Assert-True ($bootstrap.outputs.APP_GATEWAY_CERTIFICATE_ORDER_ID.type -eq 'string') 'Bootstrap must expose the order reference for private ingress preflight.'
    $txt = @($bootstrap.resources | Where-Object type -EQ 'Microsoft.Network/dnsZones/TXT')[0]
    $caa = @($bootstrap.resources | Where-Object type -EQ 'Microsoft.Network/dnsZones/CAA')[0]
    Assert-True ($txt.properties.TXTRecords -like "*parameters('existingVerificationTxtRecords')*") 'Partial bootstrap must preserve existing public TXT values.'
    Assert-True ($caa.properties.caaRecords -like "*parameters('existingIssuerCaaRecords')*") 'Partial bootstrap must preserve existing public CAA values.'
    Assert-True ($txt.properties.TTL -eq "[parameters('verificationTtl')]") 'Partial bootstrap must preserve the root TXT TTL.'
    Assert-True ($caa.properties.TTL -eq "[parameters('issuerCaaTtl')]") 'Partial bootstrap must preserve the root CAA TTL.'
    $resources = @(Get-ArmResources $template)
    Assert-True ($template.parameters.gatewayKeyVaultNetworkMode.defaultValue -eq 'trusted-services') 'Existing public/trusted-service behavior must remain the default.'
    $vaultEndpoints = @($resources | Where-Object type -EQ 'Microsoft.Network/privateEndpoints')
    Assert-True ($vaultEndpoints.Count -eq 2) 'Private vault mode must declare one endpoint for each isolated region.'
    foreach ($endpoint in $vaultEndpoints) {
        Assert-True (($endpoint.properties.privateLinkServiceConnections[0].properties.groupIds -join ',') -eq 'vault') 'Endpoints must target Key Vault, not another Private Link group.'
        Assert-True ($endpoint.properties.subnet.id -eq "[parameters('subnetId')]") 'Vault endpoints must use dedicated regional subnets.'
    }
    $vaultDnsZones = @($resources | Where-Object { $_.type -eq 'Microsoft.Network/privateDnsZones' -and $_.name -eq 'privatelink.vaultcore.azure.net' })
    Assert-True ($vaultDnsZones.Count -eq 2) 'Each isolated VNet requires its own vault DNS view.'
    $dnsGroups = @($template.resources | Where-Object type -EQ 'Microsoft.Resources/resourceGroups' | Where-Object name -LIKE '*vault-dns*')
    Assert-True ($dnsGroups.Count -eq 2) 'Same-named regional vault DNS zones must use distinct resource groups.'
    foreach ($group in $dnsGroups) {
        Assert-True ($group.condition -eq "[variables('privateVaultNetwork')]") 'Auxiliary DNS groups must be opt-in and retainable during rollback.'
    }
    foreach ($regionName in @('primary', 'secondary')) {
        $gatewayDeployment = @($template.resources | Where-Object name -EQ "$regionName-application-gateway")[0]
        Assert-True (@($gatewayDeployment.dependsOn | Where-Object { $_ -like "*$regionName-vault-network*" }).Count -eq 1) 'Gateways must wait for regional vault networking, including DNS zone group deployment.'
        $networkDeployment = @($template.resources | Where-Object name -EQ "$regionName-vault-network")[0]
        Assert-True ($networkDeployment.condition -eq "[variables('privateVaultNetwork')]") 'Private vault networking must remain opt-in.'
    }
    foreach ($shell in @('powershell', 'bash')) {
        $extension = if ($shell -eq 'powershell') { 'ps1' } else { 'sh' }
        $publisher = [IO.File]::ReadAllText((Join-Path $root "scripts\$shell\Deploy-LabApi.$extension"))
        $common = [IO.File]::ReadAllText((Join-Path $root "scripts\$shell\Lab.Common.$extension"))
        Assert-True ($publisher -match '(Invoke-LabReadiness \$values -Stage|lab_readiness) Infrastructure' -and
            $publisher -match '(Invoke-LabReadiness \$values -Stage|lab_readiness) Workloads' -and
            $common -match 'Assert-LabGatewayVaultNetwork|lab_gateway_vault_network') 'Both workload publishers must use shared infrastructure/private-network checks before publication and workload checks after rollout.'
    }
    $apims = @($resources | Where-Object type -EQ 'Microsoft.ApiManagement/service')
    Assert-True ($apims.Count -eq 1) 'The lab must deploy exactly one APIM instance.'
    $apim = $apims[0]
    Assert-True ($apim.sku.name -eq 'Premium') 'Native multi-region requires Premium classic.'
    Assert-True ($apim.properties.additionalLocations.Count -eq 1) 'Expected exactly one additional APIM region.'
    Assert-True ($template.parameters.ingressMode.defaultValue -eq 'public') 'Private ingress must be opt-in.'
    Assert-True (($template.parameters.ingressMode.allowedValues -join ',') -eq 'public,private') 'Only the documented ingress modes are supported.'
    Assert-True ($apim.properties.virtualNetworkType -eq "[if(parameters('privateIngress'), 'Internal', 'External')]") 'APIM must switch to Internal only in private ingress mode.'
    Assert-True ($apim.properties.certificates[0].storeName -eq 'Root') 'APIM must trust the lab root CA.'
    $apiDiagnostics = @($resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/apis/diagnostics')
    Assert-True ($apiDiagnostics.Count -eq 1) 'Expected one API diagnostic configuration.'
    $loggers = @($resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/loggers')
    Assert-True ($loggers.Count -eq 1) 'Expected one explicitly provisioned APIM logger.'
    Assert-True ($loggers[0].properties.loggerType -eq 'azureMonitor') 'APIM logger must use Azure Monitor.'
    Assert-True ($apiDiagnostics[0].properties.loggerId -eq "[resourceId('Microsoft.ApiManagement/service/loggers', parameters('apimName'), parameters('loggerName'))]") 'API diagnostics must reference the exact parameterized child logger resource ID.'
    $observabilityModules = @($resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'apim-observability' })
    Assert-True ($observabilityModules.Count -eq 1) 'Expected one APIM observability module.'
    Assert-True ($observabilityModules[0].properties.parameters.loggerName.value -eq 'azuremonitor' -and
        $observabilityModules[0].properties.parameters.apimName.value -eq "[parameters('name')]") 'The parent module must bind the child to the provisioned APIM Azure Monitor logger.'
    Assert-True ($loggers[0].name -eq "[format('{0}/{1}', parameters('name'), 'azuremonitor')]" -and
        $observabilityModules[0].dependsOn -contains "[resourceId('Microsoft.ApiManagement/service/loggers', parameters('name'), 'azuremonitor')]") 'The observability module must depend on creation of the exact provisioned Azure Monitor logger.'
    Assert-True ($null -eq $apiDiagnostics[0].properties.PSObject.Properties['httpCorrelationProtocol']) 'Azure Monitor diagnostics must omit the Application Insights-only httpCorrelationProtocol property.'
    $clusters = @($resources | Where-Object type -EQ 'Microsoft.ContainerService/managedClusters')
    Assert-True ($clusters.Count -eq 2) 'Expected two AKS clusters.'
    $userRoles = @($resources | Where-Object {
        $_.type -eq 'Microsoft.Authorization/roleAssignments' -and $_.properties.principalType -eq 'User'
    })
    Assert-True ($userRoles.Count -eq 2) 'Expected a persistent user role assignment in each regional template.'
    foreach ($role in $userRoles) {
        Assert-True ($role.scope -like '*Microsoft.ContainerService/managedClusters*') 'User Cluster Admin must be scoped only to AKS.'
        Assert-True ($role.properties.roleDefinitionId -eq "[variables('clusterAdminRoleId')]") 'Bootstrap access must use the cluster admin role definition.'
        Assert-True ($role.properties.principalId -eq "[parameters('adminPrincipalId')]") 'User identity must remain parameterized.'
        Assert-True ($role.condition -eq "[not(empty(parameters('adminPrincipalId')))]") 'An empty principal must create no assignment.'
        Assert-True ($role.name -like "*parameters('adminRoleAssignmentName')*guid(*") 'Role names must support adoption and deterministic defaults.'
    }
    foreach ($regionName in @('primary-region', 'secondary-region')) {
        $deployment = @($template.resources | Where-Object name -EQ $regionName)[0]
        Assert-True ($deployment.properties.template.variables.clusterAdminRoleId -eq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')]") 'Bootstrap access must use AKS RBAC Cluster Admin.'
        Assert-True ($deployment.properties.parameters.adminPrincipalId.value -eq "[parameters('aksAdminPrincipalId')]") 'Both regions must receive the configured user.'
        Assert-True ($deployment.properties.parameters.retainGatewayNetwork.value -eq "[equals(parameters('gatewayNetworkMode'), 'retain')]") 'Both regions must preserve gateway subnets during rollback when requested.'
        Assert-True ($deployment.properties.template.variables.gatewayNetwork -eq "[or(parameters('privateIngress'), parameters('retainGatewayNetwork'))]") 'Gateway network lifetime must be independent of APIM ingress mode.'
        $assignmentParameter = if ($regionName -eq 'primary-region') { 'aksPrimaryAdminRoleAssignmentName' } else { 'aksSecondaryAdminRoleAssignmentName' }
        Assert-True ($deployment.properties.parameters.adminRoleAssignmentName.value -eq "[parameters('$assignmentParameter')]") 'Each region must receive its own adoption GUID.'
    }
    foreach ($cluster in $clusters) {
        Assert-True $cluster.properties.apiServerAccessProfile.enablePrivateCluster 'AKS API server must be private.'
        Assert-True (-not $cluster.properties.apiServerAccessProfile.enablePrivateClusterPublicFQDN) 'Public private-cluster FQDN must be disabled.'
        Assert-True $cluster.properties.disableLocalAccounts 'AKS local credentials must be disabled.'
    }
    $originLoops = @($resources | Where-Object type -EQ 'Microsoft.Cdn/profiles/originGroups/origins')
    Assert-True ($originLoops.Count -eq 1) 'Expected one two-origin resource loop.'
    Assert-True ($originLoops[0].properties -like "*'enforceCertificateNameCheck', true()*") 'Front Door origin TLS validation must remain unconditionally enabled.'
    Assert-True ($originLoops[0].properties -like "*if(parameters('privateIngress'), createObject('sharedPrivateLinkResource'*'groupId', 'private'*") 'Private Link must target the private Application Gateway frontend only in private mode.'
    Assert-True ($originLoops[0].properties -like "*'requestMessage', format('apim-lab:{0}', guid(toLower(resourceId('Microsoft.Cdn/profiles', parameters('profileName')))))*") 'Private Link request markers must hash the normalized profile ID to stay within the 140-character limit.'
    $gateways = @($resources | Where-Object type -EQ 'Microsoft.Network/applicationGateways')
    Assert-True ($gateways.Count -eq 2) 'Expected two regional Application Gateway templates.'
    foreach ($deploymentName in @('primary-application-gateway', 'secondary-application-gateway', 'gateway-identity', 'gateway-vault-access')) {
        $deployment = @($template.resources | Where-Object name -EQ $deploymentName)[0]
        Assert-True ($deployment.condition -eq "[variables('privateIngress')]") 'Private ingress resources must not deploy in public mode.'
    }
    foreach ($gateway in $gateways) {
        Assert-True ($gateway.properties.sku.name -eq 'Standard_v2') 'Front Door provides WAF; regional gateways use Standard_v2.'
        Assert-True ($gateway.properties.autoscaleConfiguration.minCapacity -eq 2) 'Each regional gateway must retain two minimum instances.'
        Assert-True ($gateway.properties.httpListeners.Count -eq 1) 'Gateway must expose only one HTTPS listener.'
        $listener = $gateway.properties.httpListeners[0].properties
        Assert-True ($listener.protocol -eq 'Https' -and $listener.requireServerNameIndication) 'Gateway listener must use HTTPS and SNI.'
        Assert-True ($listener.frontendIPConfiguration.id -like '*frontendIPConfigurations/private*') 'No public Application Gateway listener may be created.'
        Assert-True ($gateway.properties.backendHttpSettingsCollection[0].properties.protocol -eq 'Https') 'Application Gateway to APIM must use HTTPS.'
        Assert-True ($gateway.properties.probes[0].properties.path -eq '/status-0123456789abcdef') 'Regional gateway probes must check APIM availability.'
        Assert-True ($gateway.properties.privateLinkConfigurations.Count -eq 1) 'Gateway must expose a dedicated Private Link configuration.'
    }
    $route = @($resources | Where-Object type -EQ 'Microsoft.Cdn/profiles/afdEndpoints/routes')[0]
    Assert-True ($route.properties.patternsToMatch -contains '/*') 'New APIM API prefixes must not require a separate Front Door update.'
    $backendResources = @($resources | Where-Object type -EQ 'Microsoft.ApiManagement/service/backends')
    Assert-True ($backendResources.Count -eq 2) 'Expected a private backend for each gateway region.'
    foreach ($backend in $backendResources) {
        Assert-True $backend.properties.tls.validateCertificateChain 'Backend CA validation must stay enabled.'
        Assert-True $backend.properties.tls.validateCertificateName 'Backend hostname validation must stay enabled.'
        Assert-True ($backend.properties.url -like 'https://*.api.lab.internal') 'Backend must use private DNS and HTTPS.'
    }
    $policy = [xml](Get-Content (Join-Path $root 'infra\policies\global.xml') -Raw)
    Assert-True ($policy.policies.inbound.choose.when.condition -like '*X-Azure-FDID*') 'Global policy must validate the Front Door profile.'
    $regional = [xml](Get-Content (Join-Path $root 'infra\policies\regional.xml') -Raw)
    Assert-True ($null -ne $regional.policies.inbound.base) 'API policy must inherit the global origin restriction.'
    $healthGuard = $regional.policies.outbound.choose.when
    Assert-True ($healthGuard.condition -like '*readiness-get*readiness-head*X-Lab-Backend-Region*context.Deployment.Region*') 'Readiness must verify backend/gateway locality, including HEAD without a body.'
    Assert-True ($healthGuard.'set-status'.code -eq '503') 'Missing or mismatched regional readiness must fail the Front Door probe.'
    $openapi = Get-Content (Join-Path $root 'src\lab-api\openapi.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-True ($openapi.paths['/health/ready'].ContainsKey('head')) 'Readiness must accept HEAD probes.'
    $null = Get-Content (Join-Path $root 'infra\main.parameters.json') -Raw | ConvertFrom-Json

    $tls = Join-Path $temporary 'tls'
    New-LabTlsFiles $tls
    Assert-LabTlsFiles $tls
    $script:checks++
    Assert-Throws { New-LabTlsFiles $tls } 'Refusing to overwrite'
    $region = [pscustomobject]@{
        Key = 'Primary'
        Location = 'brazilsouth'
        Cluster = 'aks-lab-br'
        BackendIp = '10.10.2.10'
        ApimSubnet = '10.10.0.0/26'
    }
    $manifest = New-LabManifest (Join-Path $root 'src\lab-api\workload.yaml') $tls $region
    Assert-True ($manifest -notmatch '__[A-Z_]+__') 'All workload placeholders must be replaced.'
    Assert-True ($manifest -match 'loadBalancerSourceRanges:\s+- 10.10.0.0/26') 'Only the regional APIM subnet should reach the internal API service.'
    Assert-True ($manifest -match 'region":"brazilsouth"') 'Sample response must identify its actual region.'
    Assert-True ($manifest -match 'readOnlyRootFilesystem: true') 'Workload root filesystem must be read-only.'
    $hash = [regex]::Match($manifest, 'checksum/lab-workload: "([a-f0-9]{64})"').Groups[1].Value
    Assert-True ($hash.Length -eq 64) 'Pod template must include a rendered workload checksum.'
    Assert-True ((New-LabManifest (Join-Path $root 'src\lab-api\workload.yaml') $tls $region) -eq $manifest) 'Identical inputs must not trigger another rollout.'
    $originalCertificate = [IO.File]::ReadAllText((Join-Path $tls 'tls.crt'))
    try {
        [IO.File]::AppendAllText((Join-Path $tls 'tls.crt'), "`n")
        $rotated = New-LabManifest (Join-Path $root 'src\lab-api\workload.yaml') $tls $region
        Assert-True ($rotated -notmatch [regex]::Escape("checksum/lab-workload: `"$hash`"")) 'Certificate content changes must trigger a rollout.'
    }
    finally { [IO.File]::WriteAllText((Join-Path $tls 'tls.crt'), $originalCertificate) }
    $leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
        (Join-Path $tls 'tls.crt'), (Join-Path $tls 'tls.key')
    )
    try {
        $san = @($leaf.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' })[0].Format($false)
        Assert-True ($san.Contains('br.api.lab.internal') -and $san.Contains('us.api.lab.internal')) 'Certificate must cover both private backend names.'
    }
    finally { $leaf.Dispose() }
    Assert-Throws { Assert-LabValues @{} @('API_URL') } 'Missing azd value API_URL'
    $response = New-TestResponse '{"region":"brazilsouth","cluster":"aks-br","pod":"lab-1"}'
    try {
        $body = Test-LabResponse $response @('brazilsouth', 'eastus')
        Assert-True ($body.region -eq 'brazilsouth') 'Response validation must normalize gateway display names.'
    }
    finally { $response.BaseResponse.Dispose() }
    $response = New-TestResponse '{"region":"eastus","cluster":"aks-us","pod":"lab-1"}'
    try {
        Assert-Throws { Test-LabResponse $response @('brazilsouth', 'eastus') } 'locality mismatch'
    }
    finally { $response.BaseResponse.Dispose() }
    $response = New-TestResponse '{"region":"brazilsouth"}'
    try {
        Assert-Throws { Test-LabResponse $response @('brazilsouth', 'eastus') } 'must identify region, cluster and pod'
    }
    finally { $response.BaseResponse.Dispose() }

    & {
        function Invoke-LabNative { param($Program, $Arguments) return '{"exitCode":0,"logs":"ok"}' }
        $logs = Invoke-LabAksCommand @{ AZURE_SUBSCRIPTION_ID = 's'; AZURE_RESOURCE_GROUP = 'r' } 'aks' 'true'
        Assert-True ($logs -eq 'ok') 'AKS helper must return successful command logs.'
    }
    & {
        function Invoke-LabNative { param($Program, $Arguments) return '{"exitCode":7,"logs":"failure"}' }
        Assert-Throws { Invoke-LabAksCommand @{ AZURE_SUBSCRIPTION_ID = 's'; AZURE_RESOURCE_GROUP = 'r' } 'aks' 'false' } 'exit 7'
    }
    & {
        function Invoke-LabNative { param($Program, $Arguments) return '{"logs":"incomplete"}' }
        Assert-Throws { Invoke-LabAksCommand @{ AZURE_SUBSCRIPTION_ID = 's'; AZURE_RESOURCE_GROUP = 'r' } 'aks' 'true' } 'did not return an exit code'
    }
    & {
        function Start-Sleep { param($Seconds) }
        function Invoke-LabNative {
            param($Program, $Arguments)
            if ($Arguments[2] -eq 'invoke') {
                return 'command id: 0123456789abcdef0123456789abcdef, started at: 2026-11-03, status: Running'
            }
            Assert-True ($Arguments[2] -eq 'result') 'Pending commands must be queried, not invoked again.'
            Assert-True ($Arguments -contains '0123456789abcdef0123456789abcdef') 'Result lookup must use the pending command ID.'
            return '{"exitCode":0,"logs":"completed"}'
        }
        $logs = Invoke-LabAksCommand @{ AZURE_SUBSCRIPTION_ID = 's'; AZURE_RESOURCE_GROUP = 'r' } 'aks' 'true'
        Assert-True ($logs -eq 'completed') 'AKS helper must wait for pending command results.'
    }
    & {
        function Invoke-LabNative { param($Program, $Arguments) return 'unexpected output' }
        Assert-Throws { Invoke-LabAksCommand @{ AZURE_SUBSCRIPTION_ID = 's'; AZURE_RESOURCE_GROUP = 'r' } 'aks' 'true' } 'unexpected response format'
    }
    & {
        $capture = [pscustomobject]@{ Path = $null }
        function Invoke-LabNative {
            param($Program, $Arguments)
            $capture.Path = $Arguments[-1]
            Assert-True ($Arguments[-2] -eq '--file') 'Multiline commands must be attached as shell scripts.'
            Assert-True ($Arguments -contains 'workload.yaml') 'Command scripts must preserve other attachments.'
            $remoteCommand = $Arguments[$Arguments.IndexOf('--command') + 1]
            Assert-True ($remoteCommand -eq "sh $(Split-Path $capture.Path -Leaf)") 'Remote command must invoke the attached script without multiline arguments.'
            $content = [IO.File]::ReadAllText($capture.Path)
            Assert-True ($content -eq "for i in 1; do`n  echo ready`ndone") 'Attached scripts must preserve shell syntax and use Unix line endings.'
            return '{"exitCode":0,"logs":"ready"}'
        }
        $logs = Invoke-LabAksCommand @{ AZURE_SUBSCRIPTION_ID = 's'; AZURE_RESOURCE_GROUP = 'r' } 'aks' "for i in 1; do`r`n  echo ready`r`ndone" 'workload.yaml'
        Assert-True ($logs -eq 'ready') 'Multiline command results must be returned.'
        Assert-True (-not (Test-Path -LiteralPath $capture.Path)) 'Temporary command scripts must be removed after invocation.'
    }
    & {
        $capture = [pscustomobject]@{ Path = $null }
        function Invoke-LabNative {
            param($Program, $Arguments)
            $capture.Path = $Arguments[-1]
            throw 'Test invocation failed'
        }
        Assert-Throws { Invoke-LabAksCommand @{ AZURE_SUBSCRIPTION_ID = 's'; AZURE_RESOURCE_GROUP = 'r' } 'aks' "echo one`necho two" } 'Test invocation failed'
        Assert-True (-not (Test-Path -LiteralPath $capture.Path)) 'Temporary command scripts must also be removed when invocation fails.'
    }
    & (Join-Path $PSScriptRoot 'Test-ClusterStartup.Local.ps1')
    $script:checks++
    & (Join-Path $PSScriptRoot 'Test-EndToEnd.Local.ps1')
    $script:checks++
    Write-Host "PASS: $checks local checks. No Azure resource was provisioned or queried."
}
finally {
    foreach ($file in @('main.json', 'domain-bootstrap.json', 'tls\root.cer', 'tls\tls.crt', 'tls\tls.key')) {
        $path = Join-Path $temporary $file
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    $tlsPath = Join-Path $temporary 'tls'
    if (Test-Path -LiteralPath $tlsPath) { Remove-Item -LiteralPath $tlsPath }
    Remove-Item -LiteralPath $temporary
}
