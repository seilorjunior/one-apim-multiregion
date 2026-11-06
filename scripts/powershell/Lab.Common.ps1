Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-LabNative {
    param(
        [Parameter(Mandatory)][string] $Program,
        [string[]] $Arguments = @()
    )
    $result = & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
    return ($result -join [Environment]::NewLine)
}

function Get-LabEnvironment {
    $values = @{}
    $raw = Invoke-LabNative azd @('env', 'get-values')
    foreach ($line in ($raw -split '\r?\n')) {
        if ($line -match '^([A-Z][A-Z0-9_]*)="(.*)"$') {
            $values[$Matches[1]] = $Matches[2]
        }
    }
    return $values
}

function Assert-LabValues {
    param([hashtable] $Values, [string[]] $Names)
    foreach ($name in $Names) {
        if (-not $Values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($Values[$name])) {
            throw "Missing azd value $name. Set it with: azd env set $name <value>"
        }
    }
}

function Invoke-LabReadiness {
    param(
        [hashtable] $Values,
        [ValidateSet('Prepare', 'Infrastructure', 'Workloads')][string] $Stage = 'Infrastructure',
        [switch] $StartResources,
        [ValidateRange(30, 7200)][int] $WaitSeconds = 1800
    )
    $python = $null
    foreach ($name in @('python', 'python3')) {
        $candidate = Get-Command $name -ErrorAction SilentlyContinue
        if ($candidate) {
            & $candidate.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
            if ($LASTEXITCODE -eq 0) { $python = $candidate.Source; break }
        }
    }
    if (-not $python) { throw 'Readiness checks require Python 3.9 or newer in both shells.' }
    Assert-LabValues $Values @('AZURE_ENV_NAME')
    $arguments = @((Join-Path $PSScriptRoot '..\lab_readiness.py'), '--stage', $Stage, '--wait-seconds', "$WaitSeconds", '--environment-name', $Values.AZURE_ENV_NAME)
    if ($StartResources) { $arguments += '--start-resources' }
    & $python @arguments
    if ($LASTEXITCODE -ne 0) { throw "Lab $Stage readiness failed. Resolve the reported prerequisite before continuing." }
    if ($Stage -ne 'Prepare') { Invoke-LabPrivateReadiness $Values }
}

function Invoke-LabPrivateReadiness {
    param([hashtable] $Values)
    if ($Values.ContainsKey('APP_INGRESS_MODE') -and $Values.APP_INGRESS_MODE -eq 'private') {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Write-Host 'START: Certificate metadata validation.'
        Set-LabIngressConfiguration $Values
        $tls = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".azure\$($Values.AZURE_ENV_NAME)\tls"
        Assert-LabGatewayCertificate $Values $tls
        Write-Host "PASS: Certificate metadata ($([int]$watch.Elapsed.TotalSeconds)s elapsed). START: Private vault endpoints and isolated DNS."
        Assert-LabGatewayVaultNetwork $Values
        Write-Host "PASS: Vault topology ($([int]$watch.Elapsed.TotalSeconds)s elapsed). START: Scoped Private Link approvals."
        & (Join-Path $PSScriptRoot 'Connect-PrivateOrigins.ps1')
        Write-Host "PASS: Private access gates ($([int]$watch.Elapsed.TotalSeconds)s total)."
    }
}

function Set-LabIngressConfiguration {
    param([hashtable] $Values)
    if (-not $Values.ContainsKey('APP_GATEWAY_KEY_VAULT_NETWORK_MODE')) { $Values.APP_GATEWAY_KEY_VAULT_NETWORK_MODE = 'trusted-services' }
    if ($Values.APP_GATEWAY_KEY_VAULT_NETWORK_MODE -notin @('trusted-services', 'private-endpoints')) {
        throw 'APP_GATEWAY_KEY_VAULT_NETWORK_MODE must be trusted-services or private-endpoints.'
    }
    if (-not $Values.ContainsKey('APP_INGRESS_MODE')) { $Values.APP_INGRESS_MODE = 'public' }
    if ($Values.APP_INGRESS_MODE -notin @('public', 'private')) { throw 'APP_INGRESS_MODE must be public or private.' }
    if ($Values.ContainsKey('APP_GATEWAY_NETWORK_MODE') -and $Values.APP_GATEWAY_NETWORK_MODE -notin @('auto', 'retain')) {
        throw 'APP_GATEWAY_NETWORK_MODE must be auto or retain.'
    }
    if ($Values.APP_INGRESS_MODE -eq 'public' -and
        $Values.ContainsKey('APP_GATEWAY_PRIMARY_ID') -and $Values.APP_GATEWAY_PRIMARY_ID -and
        (-not $Values.ContainsKey('APP_GATEWAY_NETWORK_MODE') -or $Values.APP_GATEWAY_NETWORK_MODE -ne 'retain')) {
        throw 'Set APP_GATEWAY_NETWORK_MODE to retain before rollback. In-use Application Gateway subnets cannot be removed.'
    }
    if ($Values.APP_INGRESS_MODE -eq 'public') { return }
    $Values.APP_GATEWAY_NETWORK_MODE = 'retain'
    foreach ($key in @('PRIMARY', 'SECONDARY')) {
        $name = "APP_GATEWAY_${key}_HOST"
        if (-not $Values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($Values[$name])) {
            Assert-LabValues $Values @('APP_GATEWAY_DNS_SUFFIX', 'AZURE_LOCATION', 'AZURE_SECONDARY_LOCATION')
            $region = if ($key -eq 'PRIMARY') { $Values.AZURE_LOCATION } else { $Values.AZURE_SECONDARY_LOCATION }
            $Values[$name] = "gw-$region.$($Values.APP_GATEWAY_DNS_SUFFIX)"
        }
        $Values[$name] = $Values[$name].ToLowerInvariant()
        if ($Values[$name] -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' -or
            $Values[$name] -match '(^|\.)((example\.(com|net|org))|invalid|test|localhost|internal|azure-api\.net|azurefd\.net)$') {
            throw "$name must be a hostname under a domain you control, covered by a publicly trusted certificate."
        }
    }
    if ($Values.APP_GATEWAY_PRIMARY_HOST -eq $Values.APP_GATEWAY_SECONDARY_HOST) { throw 'Application Gateway regional hostnames must be distinct.' }
    Assert-LabValues $Values @('APP_GATEWAY_KEY_VAULT_NAME', 'APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP', 'APP_GATEWAY_CERTIFICATE_SECRET_ID')
    if ($Values.APP_GATEWAY_CERTIFICATE_SECRET_ID -notmatch '^https://([a-z0-9-]+)\.vault\.azure\.net/secrets/([a-zA-Z0-9-]+)/?$' -or
        $Matches[1] -ne $Values.APP_GATEWAY_KEY_VAULT_NAME) {
        throw 'APP_GATEWAY_CERTIFICATE_SECRET_ID must be a versionless secret URI in the configured Key Vault.'
    }
    $Values.APP_GATEWAY_CERTIFICATE_SECRET_ID = $Values.APP_GATEWAY_CERTIFICATE_SECRET_ID.TrimEnd('/')
}

function Assert-LabGatewayCertificate {
    param([hashtable] $Values, [string] $TlsDirectory)
    if ($Values.APP_INGRESS_MODE -ne 'private') { return }
    $vault = (Invoke-LabNative az @(
        'keyvault', 'show', '--subscription', $Values.AZURE_SUBSCRIPTION_ID,
        '--resource-group', $Values.APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP,
        '--name', $Values.APP_GATEWAY_KEY_VAULT_NAME,
        '--query', '{rbac:properties.enableRbacAuthorization,publicNetwork:properties.publicNetworkAccess,defaultAction:properties.networkAcls.defaultAction,bypass:properties.networkAcls.bypass}',
        '--output', 'json', '--only-show-errors'
    )) | ConvertFrom-Json
    $privateEndpoints = $Values.ContainsKey('APP_GATEWAY_KEY_VAULT_NETWORK_MODE') -and $Values.APP_GATEWAY_KEY_VAULT_NETWORK_MODE -eq 'private-endpoints'
    if ($vault.rbac -ne $true) { throw 'The certificate Key Vault must use Azure RBAC.' }
    if ($privateEndpoints) {
        Assert-LabValues $Values @('AZURE_ENV_NAME', 'APP_GATEWAY_CERTIFICATE_ORDER_ID')
        if ($vault.publicNetwork -ne 'Disabled') { throw 'Private-endpoints mode requires the certificate vault public network access to remain Disabled.' }
        Write-Warning 'Certificate metadata alone does not prove vault access. Both regional endpoint/DNS paths require deployed-topology verification.'
    }
    elseif ($vault.publicNetwork -eq 'Disabled' -or
        ($vault.defaultAction -eq 'Deny' -and $vault.bypass -notmatch 'AzureServices')) {
        throw 'The certificate Key Vault must use Azure RBAC and allow Application Gateway certificate retrieval through its public/trusted-service network path.'
    }
    $certificateName = ($Values.APP_GATEWAY_CERTIFICATE_SECRET_ID -split '/')[-1]
    if ($Values.ContainsKey('APP_GATEWAY_CERTIFICATE_ORDER_ID') -and $Values.APP_GATEWAY_CERTIFICATE_ORDER_ID) {
        $orderId = $Values.APP_GATEWAY_CERTIFICATE_ORDER_ID
        $subscriptionPrefix = "/subscriptions/$($Values.AZURE_SUBSCRIPTION_ID)/resourceGroups/"
        if (-not $orderId.StartsWith($subscriptionPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $orderId.Substring($subscriptionPrefix.Length) -notmatch '^[^/]+/providers/Microsoft\.CertificateRegistration/certificateOrders/[a-zA-Z0-9._-]+$') {
            throw 'Certificate order must be a Microsoft.CertificateRegistration order in the configured subscription.'
        }
        $order = (Invoke-LabNative az @(
            'rest', '--method', 'get', '--url', "${orderId}?api-version=2024-11-01",
            '--query', 'properties.{status:status,state:provisioningState,product:productType,externalKey:isPrivateKeyExternal,signed:signedCertificate,certificates:certificates}',
            '--output', 'json', '--only-show-errors'
        )) | ConvertFrom-Json
        if ($order.status -ne 'Issued' -or $order.state -ne 'Succeeded' -or
            $order.product -ne 'StandardDomainValidatedWildCardSsl' -or $order.externalKey -ne $false) {
            throw 'Purchased wildcard certificate must be Issued/Succeeded with an Azure-managed private key before private ingress is enabled.'
        }
        $vaultId = "/subscriptions/$($Values.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($Values.APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP)/providers/Microsoft.KeyVault/vaults/$($Values.APP_GATEWAY_KEY_VAULT_NAME)"
        $bindings = @($order.certificates.PSObject.Properties.Value | Where-Object {
            $_.keyVaultId -eq $vaultId -and $_.keyVaultSecretName -ceq $certificateName -and $_.provisioningState -eq 'Succeeded'
        })
        if ($bindings.Count -ne 1) { throw 'Purchased certificate is not successfully synchronized to the configured Key Vault secret.' }
        if ($order.signed.subject -notmatch '^CN=\*\.([a-zA-Z0-9.-]+)$') { throw 'Purchased certificate must have the expected wildcard subject.' }
        $suffix = $Matches[1].ToLowerInvariant()
        foreach ($hostName in @($Values.APP_GATEWAY_PRIMARY_HOST, $Values.APP_GATEWAY_SECONDARY_HOST)) {
            if ($hostName -notmatch "^[a-zA-Z0-9-]+\.$([regex]::Escape($suffix))$") { throw "Purchased wildcard does not cover $hostName." }
        }
        if ([DateTimeOffset]::Parse($order.signed.notBefore) -gt [DateTimeOffset]::UtcNow -or
            [DateTimeOffset]::Parse($order.signed.notAfter) -le [DateTimeOffset]::UtcNow.AddDays(1)) {
            throw 'Purchased certificate is not currently valid with more than one day remaining.'
        }
        Write-Host 'Purchased certificate issuance, wildcard coverage, validity, and Key Vault synchronization verified through Azure management metadata. Front Door TLS validation remains mandatory.'
        return
    }
    $metadata = (Invoke-LabNative az @(
        'keyvault', 'certificate', 'show', '--subscription', $Values.AZURE_SUBSCRIPTION_ID,
        '--vault-name', $Values.APP_GATEWAY_KEY_VAULT_NAME, '--name', $certificateName,
        '--query', '{cer:cer,sid:sid,enabled:attributes.enabled,contentType:policy.secretProperties.contentType,exportable:policy.keyProperties.exportable}', '--output', 'json', '--only-show-errors'
    )) | ConvertFrom-Json
    if ($metadata.enabled -ne $true -or $metadata.contentType -ne 'application/x-pkcs12' -or $metadata.exportable -ne $true -or
        -not $metadata.sid.StartsWith("$($Values.APP_GATEWAY_CERTIFICATE_SECRET_ID)/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Key Vault certificate must be enabled, exportable PFX, and correspond to the configured certificate secret.'
    }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($metadata.cer))
    $root = [Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes((Join-Path $TlsDirectory 'root.cer')))
    try {
        if ($certificate.Subject -eq $certificate.Issuer -or $certificate.Issuer -eq $root.Subject -or
            $certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddDays(1) -or
            $certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow) {
            throw 'Gateway TLS requires a currently valid CA-issued certificate, not the lab CA or a self-signed certificate, with more than one day remaining.'
        }
        foreach ($hostName in @($Values.APP_GATEWAY_PRIMARY_HOST, $Values.APP_GATEWAY_SECONDARY_HOST)) {
            if (-not $certificate.MatchesHostname($hostName, $true, $false)) { throw "Gateway certificate SAN does not cover $hostName." }
        }
        $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
        try {
            $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $chain.ChainPolicy.DisableCertificateDownloads = $true
            $null = $chain.ChainPolicy.ApplicationPolicy.Add([Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
            if ($Values.ContainsKey('APP_GATEWAY_CERTIFICATE_CHAIN_FILE') -and $Values.APP_GATEWAY_CERTIFICATE_CHAIN_FILE) {
                $pem = [IO.File]::ReadAllText($Values.APP_GATEWAY_CERTIFICATE_CHAIN_FILE)
                if ($pem -match '-----BEGIN .*PRIVATE KEY-----') { throw 'The optional chain file must contain only public CA certificates, never private keys.' }
                $chain.ChainPolicy.ExtraStore.ImportFromPemFile($Values.APP_GATEWAY_CERTIFICATE_CHAIN_FILE)
            }
            if (-not $chain.Build($certificate)) {
                throw 'Gateway certificate chain is not trusted by this machine. Supply public intermediate certificates through APP_GATEWAY_CERTIFICATE_CHAIN_FILE if needed; never add the lab CA to the trust store.'
            }
        }
        finally { $chain.Dispose() }
    }
    finally {
        $certificate.Dispose()
        $root.Dispose()
    }
    Write-Host 'Gateway certificate metadata, SANs, validity, and local trust chain checked using public certificate data only. Front Door public-chain validation remains mandatory after deployment.'
}

function Assert-LabGatewayVaultNetwork {
    param([hashtable] $Values)
    if (-not $Values.ContainsKey('APP_INGRESS_MODE') -or $Values.APP_INGRESS_MODE -ne 'private' -or
        -not $Values.ContainsKey('APP_GATEWAY_KEY_VAULT_NETWORK_MODE') -or $Values.APP_GATEWAY_KEY_VAULT_NETWORK_MODE -ne 'private-endpoints') { return }
    Assert-LabValues $Values @('AZURE_SUBSCRIPTION_ID', 'APP_GATEWAY_KEY_VAULT_NAME', 'APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP')
    $vaultId = "/subscriptions/$($Values.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($Values.APP_GATEWAY_KEY_VAULT_RESOURCE_GROUP)/providers/Microsoft.KeyVault/vaults/$($Values.APP_GATEWAY_KEY_VAULT_NAME)"
    $seenZones = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seenVnets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Read-VaultNetworkResource {
        param([string] $Id, [string] $Version = '2024-05-01')
        return (Invoke-LabNative az @('rest', '--method', 'get', '--url', "${Id}?api-version=$Version", '--output', 'json', '--only-show-errors')) | ConvertFrom-Json
    }
    foreach ($region in @('PRIMARY', 'SECONDARY')) {
        Assert-LabValues $Values @("APP_GATEWAY_${region}_ID", "APP_GATEWAY_${region}_VAULT_ENDPOINT_ID", "APP_GATEWAY_${region}_VAULT_DNS_ZONE_ID")
        $gatewayId = $Values["APP_GATEWAY_${region}_ID"]
        $endpointId = $Values["APP_GATEWAY_${region}_VAULT_ENDPOINT_ID"]
        $zoneId = $Values["APP_GATEWAY_${region}_VAULT_DNS_ZONE_ID"]
        $prefix = "/subscriptions/$($Values.AZURE_SUBSCRIPTION_ID)/resourceGroups/"
        if ($gatewayId -notmatch "^$([regex]::Escape($prefix))[^/]+/providers/Microsoft.Network/applicationGateways/[^/]+$" -or
            $endpointId -notmatch "^$([regex]::Escape($prefix))[^/]+/providers/Microsoft.Network/privateEndpoints/[^/]+$" -or
            $zoneId -notmatch "^$([regex]::Escape($prefix))[^/]+/providers/Microsoft.Network/privateDnsZones/privatelink\.vaultcore\.azure\.net$" -or
            -not $seenZones.Add($zoneId)) {
            throw 'Private vault resource IDs must belong to this subscription and use separate regional DNS zones.'
        }
        $gateway = Read-VaultNetworkResource $gatewayId
        $endpoint = Read-VaultNetworkResource $endpointId
        $p = $endpoint.properties
        $gatewaySubnets = @($gateway.properties.gatewayIPConfigurations | ForEach-Object { $_.properties.subnet.id })
        if ($gateway.properties.provisioningState -ne 'Succeeded' -or $gatewaySubnets.Count -ne 1 -or $gatewaySubnets[0] -notmatch '/subnets/application-gateway$') {
            throw "$region Application Gateway is not successfully provisioned in the expected subnet."
        }
        $vnetId = $gatewaySubnets[0] -replace '/subnets/application-gateway$', ''
        $connections = @($p.privateLinkServiceConnections)
        if ($p.provisioningState -ne 'Succeeded' -or $p.subnet.id -ne "$vnetId/subnets/vault-private-endpoints" -or
            -not $seenVnets.Add($vnetId) -or $connections.Count -ne 1 -or $p.networkInterfaces.Count -ne 1) {
            throw "$region vault endpoint must be successful and local to its isolated gateway VNet."
        }
        $connection = $connections[0].properties
        if ($connection.privateLinkServiceId -ne $vaultId -or ($connection.groupIds -join ',') -ne 'vault' -or
            $connection.privateLinkServiceConnectionState.status -ne 'Approved') {
            throw "$region vault endpoint must target the exact configured vault, group vault, and be Approved."
        }
        $vnet = Read-VaultNetworkResource $vnetId
        $dhcp = $vnet.properties.PSObject.Properties['dhcpOptions']
        if ($dhcp -and @($dhcp.Value.dnsServers | Where-Object { $_ }).Count -gt 0) { throw 'Managed private vault DNS requires the Azure-provided VNet resolver.' }
        $nic = Read-VaultNetworkResource $p.networkInterfaces[0].id
        $ips = @($nic.properties.ipConfigurations)
        if ($nic.properties.privateEndpoint.id -ne $endpointId -or $ips.Count -ne 1 -or $ips[0].properties.subnet.id -ne $p.subnet.id -or
            [string]::IsNullOrWhiteSpace($ips[0].properties.privateIPAddress)) { throw "$region endpoint NIC does not identify a single local private address." }
        $groups = Read-VaultNetworkResource "$endpointId/privateDnsZoneGroups"
        if ($groups.value.Count -ne 1 -or $groups.value[0].properties.provisioningState -ne 'Succeeded' -or
            $groups.value[0].properties.privateDnsZoneConfigs.Count -ne 1 -or
            $groups.value[0].properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId -ne $zoneId) { throw "$region vault DNS zone group is missing or points to another zone." }
        $links = Read-VaultNetworkResource "$zoneId/virtualNetworkLinks" '2024-06-01'
        if ($links.value.Count -ne 1 -or $links.value[0].properties.provisioningState -ne 'Succeeded' -or
            $links.value[0].properties.virtualNetwork.id -ne $vnetId -or $links.value[0].properties.registrationEnabled -ne $false) {
            throw "$region vault DNS zone must link only to its local gateway VNet without auto-registration."
        }
        $record = Read-VaultNetworkResource "$zoneId/A/$($Values.APP_GATEWAY_KEY_VAULT_NAME)" '2024-06-01'
        if ($record.properties.aRecords.Count -ne 1 -or $record.properties.aRecords[0].ipv4Address -ne $ips[0].properties.privateIPAddress) {
            throw "$region vault DNS must resolve only to its own endpoint address."
        }
    }
    Write-Host 'PASS: Both private vault endpoint approvals, local gateway VNets, NIC addresses, DNS zone groups and isolated records verified. Runtime TLS still requires end-to-end testing.'
}

function Get-LabPrivateLinkMarker {
    param([string] $ProfileId)
    # ARM guid() uses UUIDv5 with this fixed namespace and the resource ID as its name.
    $namespace = [Convert]::FromHexString('11fb06fb712d4ddd98c7e71bbd588830')
    $name = [Text.Encoding]::UTF8.GetBytes($ProfileId.ToLowerInvariant())
    $hash = [Security.Cryptography.SHA1]::HashData([byte[]]($namespace + $name))
    $hash[6] = ($hash[6] -band 0x0f) -bor 0x50
    $hash[8] = ($hash[8] -band 0x3f) -bor 0x80
    $hex = [Convert]::ToHexString($hash[0..15]).ToLowerInvariant()
    return "apim-lab:$($hex.Substring(0, 8))-$($hex.Substring(8, 4))-$($hex.Substring(12, 4))-$($hex.Substring(16, 4))-$($hex.Substring(20, 12))"
}

function Get-LabPrivateOrigins {
    param([hashtable] $Values)
    Assert-LabValues $Values @(
        'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_FRONT_DOOR_PROFILE',
        'APP_GATEWAY_PRIMARY_ID', 'APP_GATEWAY_SECONDARY_ID',
        'APP_GATEWAY_PRIMARY_HOST', 'APP_GATEWAY_SECONDARY_HOST',
        'AZURE_LOCATION', 'AZURE_SECONDARY_LOCATION'
    )
    if ($Values.APP_GATEWAY_PRIMARY_ID -eq $Values.APP_GATEWAY_SECONDARY_ID) { throw 'Private ingress requires two distinct regional Application Gateways.' }
    $scope = "/subscriptions/$($Values.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($Values.AZURE_RESOURCE_GROUP)"
    $profile = "$scope/providers/Microsoft.Cdn/profiles/$($Values.AZURE_FRONT_DOOR_PROFILE)"
    $markers = @((Get-LabPrivateLinkMarker $profile), "apim-lab:$profile")
    foreach ($pair in @(@('PRIMARY', 'br'), @('SECONDARY', 'us'))) {
        $gatewayId = $Values["APP_GATEWAY_$($pair[0])_ID"]
        $prefix = "$scope/providers/Microsoft.Network/applicationGateways/"
        if (-not $gatewayId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $gatewayId.Substring($prefix.Length) -notmatch '^[a-zA-Z0-9._-]+$') {
            throw 'Application Gateway ID is outside the configured lab scope.'
        }
        $originId = "$profile/originGroups/regional-apis-private/origins/$($pair[1])"
        $origin = (Invoke-LabNative az @('rest', '--method', 'get', '--url', "${originId}?api-version=2024-09-01", '--output', 'json', '--only-show-errors')) | ConvertFrom-Json
        $link = $origin.properties.sharedPrivateLinkResource
        if ($link.privateLink.id -ne $gatewayId -or $link.groupId -ne 'private' -or
            $origin.properties.hostName -ne $Values["APP_GATEWAY_$($pair[0])_HOST"] -or -not $origin.properties.enforceCertificateNameCheck) {
            throw "Private origin $($pair[1]) does not match the configured gateway, private frontend, hostname, and TLS validation."
        }
        $statusProperty = $link.PSObject.Properties['status']
        $status = if ($null -eq $statusProperty) { '' } else { [string] $statusProperty.Value }
        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = 'Initializing'
        }
        elseif ($status -notin @('Approved', 'Pending')) { throw "Private origin $($pair[1]) is $status. Investigate it before requesting a new connection." }
        $connectionId = ''
        if ($status -ne 'Approved') {
            $connections = (Invoke-LabNative az @(
                'rest', '--method', 'get', '--url', "${gatewayId}?api-version=2024-05-01",
                '--query', 'properties.privateEndpointConnections', '--output', 'json', '--only-show-errors'
            )) | ConvertFrom-Json
            $matchingConnections = @($connections | Where-Object {
                $_.properties.privateLinkServiceConnectionState.description -cin $markers
            })
            if ($matchingConnections.Count -gt 1) { throw "Multiple requests match $gatewayId. Inspect and approve the intended connection manually." }
            if ($matchingConnections.Count -eq 0 -and $status -ne 'Initializing') {
                throw "No matching pending or approved request was found on $gatewayId. Inspect its Private Link requests; unrelated connections will not be approved."
            }
            if ($matchingConnections.Count -eq 1) {
                $candidateId = [string] $matchingConnections[0].id
                if (-not $candidateId.StartsWith("$gatewayId/privateEndpointConnections/", [StringComparison]::OrdinalIgnoreCase) -or
                    $candidateId.Substring("$gatewayId/privateEndpointConnections/".Length) -notmatch '^[a-zA-Z0-9._-]+$') {
                    throw 'Private endpoint connection ID is outside the configured gateway scope.'
                }
                $gatewayStatus = [string] $matchingConnections[0].properties.privateLinkServiceConnectionState.status
                if ($gatewayStatus -notin @('Approved', 'Pending')) {
                    throw "Matching gateway request on $gatewayId is '$gatewayStatus'. Investigate it before requesting a new connection."
                }
                if ($gatewayStatus -eq 'Pending') { $connectionId = $candidateId }
                elseif ($status -eq 'Initializing') {
                    $location = if ($pair[0] -eq 'PRIMARY') { $Values.AZURE_LOCATION } else { $Values.AZURE_SECONDARY_LOCATION }
                    if ($origin.properties.provisioningState -ne 'Succeeded' -or $origin.properties.enabledState -ne 'Enabled' -or
                        $origin.properties.originHostHeader -ne $Values["APP_GATEWAY_$($pair[0])_HOST"] -or
                        $link.privateLinkLocation -ne $location -or $link.requestMessage -cnotin $markers -or
                        $matchingConnections[0].properties.provisioningState -ne 'Succeeded') {
                        throw 'Unreported Front Door status requires a successful enabled origin, exact Host/region/request marker, and a Succeeded/Approved gateway connection.'
                    }
                    $status = 'ApprovedAtGateway'
                    Write-Warning "Origin $($pair[1]): Front Door has not reported status; exact scoped gateway connection is Succeeded/Approved. Using gateway-side approval evidence only; runtime TLS/API health remains unverified."
                }
            }
        }
        if ($status -eq 'Initializing') {
            Write-Warning "Front Door origin $($pair[1]) has not reported its Private Link status yet and no verified gateway approval is available."
        }
        [pscustomobject]@{ Origin = $pair[1]; Status = $status; ConnectionId = $connectionId; ProfileId = $profile }
    }
}

function Wait-LabClustersRunning {
    param(
        [hashtable] $Values,
        [switch] $StartClusters,
        [ValidateRange(30, 7200)][int] $WaitSeconds = 1800
    )
    Assert-LabValues $Values @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID')
    $targets = @((Invoke-LabNative az @(
        'resource', 'list', '--subscription', $Values.AZURE_SUBSCRIPTION_ID,
        '--tag', "azd-env-name=$($Values.AZURE_ENV_NAME)",
        '--query', "[?type=='Microsoft.ContainerService/managedClusters'].{name:name,resourceGroup:resourceGroup,id:id}",
        '--output', 'json', '--only-show-errors'
    )) | ConvertFrom-Json)
    if ($targets.Count -gt 2) { throw 'More than two AKS clusters match this azd environment; refusing ambiguous startup.' }
    if ($targets.Count -eq 0) {
        Write-Host 'No existing AKS clusters match this environment; Bicep can create them.'
        return
    }
    $groups = @($targets.resourceGroup | Select-Object -Unique)
    if ($groups.Count -ne 1) { throw 'Environment AKS clusters span multiple resource groups; refusing startup.' }
    foreach ($target in $targets) {
        if ($target.name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$' -or
            $target.resourceGroup -notmatch '^[a-zA-Z0-9_.()-]+$') {
            throw 'Invalid cluster discovery response.'
        }
        $expectedId = "/subscriptions/$($Values.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($target.resourceGroup)/providers/Microsoft.ContainerService/managedClusters/$($target.name)"
        if ($target.id -ne $expectedId -or
            ($Values.ContainsKey('AZURE_RESOURCE_GROUP') -and $Values.AZURE_RESOURCE_GROUP -ne $target.resourceGroup)) {
            throw 'Discovered AKS scope does not match the selected environment.'
        }
    }
    if (@($targets.id | Select-Object -Unique).Count -ne $targets.Count) { throw 'Duplicate AKS discovery results.' }
    $deadline = ([DateTimeOffset] (Get-Date -AsUTC)).AddSeconds($WaitSeconds)
    $requested = @{}
    do {
        if ([DateTimeOffset] (Get-Date -AsUTC) -ge $deadline) {
            throw "AKS startup did not reach Running/Succeeded within $WaitSeconds seconds. Azure operations may still be running; inspect the clusters before retrying."
        }
        $pending = @()
        foreach ($target in $targets) {
            $state = (Invoke-LabNative az @(
                'aks', 'show', '--subscription', $Values.AZURE_SUBSCRIPTION_ID,
                '--resource-group', $target.resourceGroup, '--name', $target.name,
                '--query', '{provisioningState:provisioningState,powerState:powerState.code}',
                '--output', 'json', '--only-show-errors'
            )) | ConvertFrom-Json
            if ($state.provisioningState -notin @('Succeeded', 'Starting', 'Stopping', 'Updating', 'Creating') -or
                $state.powerState -notin @('Running', 'Stopped')) {
                throw "AKS $($target.name) has an unsupported state: $($state.provisioningState)/$($state.powerState)."
            }
            Write-Host "AKS $($target.name): $($state.powerState)/$($state.provisioningState)."
            if ($state.provisioningState -eq 'Succeeded' -and $state.powerState -eq 'Running') { continue }
            if (-not $StartClusters) {
                throw "AKS $($target.name) is not Running/Succeeded. Use scripts/powershell/Provision-Lab.ps1 -StartResources or scripts/bash/Provision-Lab.sh --start-resources to explicitly start stopped compute before provisioning. Preview and direct azd hooks never start clusters."
            }
            $pending += [pscustomobject]@{ Target = $target; State = $state }
        }
        if ([DateTimeOffset] (Get-Date -AsUTC) -ge $deadline) {
            throw "AKS startup did not reach Running/Succeeded within $WaitSeconds seconds. Azure operations may still be running; inspect the clusters before retrying."
        }
        if ($pending.Count -eq 0) { return }
        foreach ($item in $pending) {
            $target = $item.Target
            if ($item.State.provisioningState -eq 'Succeeded' -and $item.State.powerState -eq 'Stopped' -and -not $requested.ContainsKey($target.id)) {
                Write-Warning "Starting AKS $($target.name); compute charges resume. Other lab clusters will start without waiting for this operation."
                $null = Invoke-LabNative az @(
                    'aks', 'start', '--subscription', $Values.AZURE_SUBSCRIPTION_ID,
                    '--resource-group', $target.resourceGroup, '--name', $target.name,
                    '--no-wait', '--output', 'none', '--only-show-errors'
                )
                $requested[$target.id] = $true
            }
        }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Get-LabRegions {
    param([hashtable] $Values)
    Assert-LabValues $Values @(
        'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP',
        'AZURE_PRIMARY_LOCATION', 'AZURE_SECONDARY_LOCATION',
        'AKS_PRIMARY_NAME', 'AKS_SECONDARY_NAME',
        'BACKEND_PRIMARY_IP', 'BACKEND_SECONDARY_IP',
        'APIM_PRIMARY_SUBNET', 'APIM_SECONDARY_SUBNET'
    )
    return @(
        [pscustomobject]@{
            Key = 'Primary'
            Location = $Values.AZURE_PRIMARY_LOCATION
            Cluster = $Values.AKS_PRIMARY_NAME
            BackendIp = $Values.BACKEND_PRIMARY_IP
            ApimSubnet = $Values.APIM_PRIMARY_SUBNET
        },
        [pscustomobject]@{
            Key = 'Secondary'
            Location = $Values.AZURE_SECONDARY_LOCATION
            Cluster = $Values.AKS_SECONDARY_NAME
            BackendIp = $Values.BACKEND_SECONDARY_IP
            ApimSubnet = $Values.APIM_SECONDARY_SUBNET
        }
    )
}

function Invoke-LabAksCommand {
    param(
        [hashtable] $Values,
        [string] $Cluster,
        [string] $Command,
        [string] $File
    )
    $arguments = @(
        'aks', 'command', 'invoke',
        '--subscription', $Values.AZURE_SUBSCRIPTION_ID,
        '--resource-group', $Values.AZURE_RESOURCE_GROUP,
        '--name', $Cluster,
        '--command', $Command,
        '--output', 'json',
        '--only-show-errors'
    )
    if ($File) {
        $arguments += @('--file', $File)
    }
    $scriptFile = $null
    try {
        if ($Command -match '[\r\n]') {
            $scriptFile = Join-Path ([IO.Path]::GetTempPath()) ("apim-lab-command-$([Guid]::NewGuid().ToString('N')).sh")
            [IO.File]::WriteAllText($scriptFile, $Command.Replace("`r`n", "`n").Replace("`r", "`n"))
            $arguments[$arguments.IndexOf('--command') + 1] = "sh $(Split-Path $scriptFile -Leaf)"
            $arguments += @('--file', $scriptFile)
        }
        $raw = Invoke-LabNative az $arguments
    }
    finally {
        if ($scriptFile -and (Test-Path -LiteralPath $scriptFile)) {
            Remove-Item -LiteralPath $scriptFile -Force
        }
    }
    $deadline = [DateTime]::UtcNow.AddMinutes(10)
    do {
        if ($raw.TrimStart().StartsWith('{')) {
            $result = $raw | ConvertFrom-Json
            break
        }
        if ($raw -notmatch '(?m)^command id: ([0-9a-fA-F]{32}), started at:') {
            throw "AKS Run Command returned an unexpected response format for $Cluster."
        }
        $commandId = $Matches[1]
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "AKS command $commandId in $Cluster is still running after ten minutes. Retrieve it with az aks command result."
        }
        Write-Warning "AKS command $commandId in $Cluster is still running; waiting for its result."
        Start-Sleep -Seconds 5
        $raw = Invoke-LabNative az @(
            'aks', 'command', 'result',
            '--subscription', $Values.AZURE_SUBSCRIPTION_ID,
            '--resource-group', $Values.AZURE_RESOURCE_GROUP,
            '--name', $Cluster,
            '--command-id', $commandId,
            '--output', 'json',
            '--only-show-errors'
        )
    } while ($true)
    if (-not $result.PSObject.Properties['exitCode'] -or $null -eq $result.exitCode) {
        throw "AKS Run Command did not return an exit code for $Cluster."
    }
    if ($result.exitCode -ne 0) {
        throw "AKS command failed in $Cluster (exit $($result.exitCode)): $($result.logs)"
    }
    return [string] $result.logs
}

function New-LabTlsFiles {
    param([Parameter(Mandatory)][string] $Directory)
    if (Test-Path -LiteralPath $Directory) {
        throw "TLS directory already exists: $Directory. Refusing to overwrite certificates."
    }
    $null = New-Item -ItemType Directory -Path $Directory
    if ($IsWindows) {
        $acl = Get-Acl -LiteralPath $Directory
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'
        )
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Directory -AclObject $acl
    }
    else {
        [IO.File]::SetUnixFileMode($Directory, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    $rootKey = [System.Security.Cryptography.RSA]::Create(3072)
    $leafKey = [System.Security.Cryptography.RSA]::Create(2048)
    $root = $null
    $leaf = $null
    try {
        $rootRequest = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=APIM Multi Region Lab Root',
            $rootKey,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $rootRequest.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true)
        )
        $rootRequest.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign, $true
            )
        )
        $now = [DateTimeOffset]::UtcNow
        $root = $rootRequest.CreateSelfSigned($now.AddMinutes(-5), $now.AddDays(90))
        $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=br.api.lab.internal',
            $leafKey,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true)
        )
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
                [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true
            )
        )
        $usages = [System.Security.Cryptography.OidCollection]::new()
        $null = $usages.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $request.CertificateExtensions.Add(
            [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($usages, $true)
        )
        $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        $san.AddDnsName('br.api.lab.internal')
        $san.AddDnsName('us.api.lab.internal')
        $request.CertificateExtensions.Add($san.Build())
        $serial = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
        $leaf = $request.Create($root, $now.AddMinutes(-1), $now.AddDays(60), $serial)
        [IO.File]::WriteAllBytes((Join-Path $Directory 'root.cer'), $root.Export(
            [System.Security.Cryptography.X509Certificates.X509ContentType]::Cert
        ))
        [IO.File]::WriteAllText(
            (Join-Path $Directory 'tls.crt'), $leaf.ExportCertificatePem() + "`n" + $root.ExportCertificatePem()
        )
        [IO.File]::WriteAllText((Join-Path $Directory 'tls.key'), $leafKey.ExportPkcs8PrivateKeyPem())
    }
    finally {
        if ($leaf) { $leaf.Dispose() }
        if ($root) { $root.Dispose() }
        $leafKey.Dispose()
        $rootKey.Dispose()
    }
}

function Assert-LabTlsFiles {
    param([string] $Directory)
    foreach ($file in @('root.cer', 'tls.crt', 'tls.key')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $file))) {
            throw "Incomplete TLS material: missing $file in $Directory. Do not mix certificates from different runs."
        }
    }
    $leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile(
        (Join-Path $Directory 'tls.crt'), (Join-Path $Directory 'tls.key')
    )
    $root = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [IO.File]::ReadAllBytes((Join-Path $Directory 'root.cer'))
    )
    $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
    try {
        if ($leaf.NotAfter.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(7)) {
            throw 'Laboratory TLS certificate expires in less than seven days. Rotate TLS material and reprovision before testing.'
        }
        $chain.ChainPolicy.TrustMode = [System.Security.Cryptography.X509Certificates.X509ChainTrustMode]::CustomRootTrust
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
        $null = $chain.ChainPolicy.CustomTrustStore.Add($root)
        if (-not $chain.Build($leaf)) {
            throw "Laboratory certificate does not chain to root.cer: $($chain.ChainStatus.StatusInformation -join '; ')"
        }
    }
    finally {
        $chain.Dispose()
        $root.Dispose()
        $leaf.Dispose()
    }
}

function New-LabManifest {
    param(
        [string] $Template,
        [string] $TlsDirectory,
        [psobject] $Region
    )
    $manifest = [IO.File]::ReadAllText($Template).Replace("`r`n", "`n").Replace("`r", "`n")
    $replacements = @{
        '__REGION__' = $Region.Location
        '__CLUSTER__' = $Region.Cluster
        '__BACKEND_IP__' = $Region.BackendIp
        '__APIM_SUBNET__' = $Region.ApimSubnet
        '__TLS_CERTIFICATE__' = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $TlsDirectory 'tls.crt')))
        '__TLS_KEY__' = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $TlsDirectory 'tls.key')))
    }
    foreach ($entry in $replacements.GetEnumerator()) {
        $manifest = $manifest.Replace($entry.Key, $entry.Value)
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifest))).ToLowerInvariant()
    $manifest = $manifest.Replace('__WORKLOAD_HASH__', $hash)
    if ($manifest -match '__[A-Z_]+__') {
        throw "Unresolved workload placeholder: $($Matches[0])"
    }
    return $manifest
}

function Test-LabResponse {
    param(
        [Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject] $Response,
        [string[]] $ExpectedRegions
    )
    if ([int] $Response.StatusCode -ne 200) {
        throw "Unexpected API HTTP status: $($Response.StatusCode)"
    }
    $body = $Response.Content | ConvertFrom-Json -AsHashtable
    foreach ($field in @('region', 'cluster', 'pod')) {
        if (-not $body.ContainsKey($field) -or [string]::IsNullOrWhiteSpace($body[$field])) {
            throw 'API response must identify region, cluster and pod.'
        }
    }
    if ($body.region -notin $ExpectedRegions) {
        throw "Unexpected backend region: $($body.region)"
    }
    $gateway = ($Response.Headers['X-Lab-Gateway-Region'] -join '').Replace(' ', '').ToLowerInvariant()
    if ($gateway -ne $body.region) {
        throw "Gateway/backend locality mismatch: gateway=$gateway backend=$($body.region)"
    }
    return [pscustomobject] $body
}

function Test-LabOriginMetrics {
    param(
        [psobject] $Metrics,
        [string[]] $Hosts,
        [DateTimeOffset] $Since,
        [DateTimeOffset] $Now,
        [string] $OriginGroup = 'regional-apis'
    )
    $metric = @($Metrics.value | Where-Object { $_.name.value -eq 'OriginHealthPercentage' })
    if ($metric.Count -ne 1) { throw 'Expected exactly one OriginHealthPercentage metric.' }
    if ($metric[0].PSObject.Properties['errorCode'] -and $metric[0].errorCode -ne 'Success') {
        throw "Origin health metric error: $($metric[0].errorCode)"
    }
    $minimumTimestamp = $Since.ToUnixTimeSeconds()
    if ($Since.UtcTicks % [TimeSpan]::TicksPerMinute -ne 0) {
        $minimumTimestamp += 60 - ($minimumTimestamp % 60)
    }
    $reasons = [Collections.Generic.List[string]]::new()
    $evidence = foreach ($hostName in $Hosts) {
        $series = @($metric[0].timeseries | Where-Object {
            $dimensions = @{}
            foreach ($dimension in $_.metadatavalues) { $dimensions[$dimension.name.value] = $dimension.value }
            $dimensions['Origin'] -eq "${hostName}:443" -and $dimensions['OriginGroup'] -eq $OriginGroup
        })
        if ($series.Count -gt 1) { throw "Duplicate metric series for ${hostName}:443." }
        if ($series.Count -eq 0) {
            $reasons.Add("${hostName}: missing origin metric series")
            continue
        }
        $points = @($series[0].data | Where-Object {
            $timestamp = ([DateTimeOffset] $_.timeStamp).ToUnixTimeSeconds()
            $timestamp -ge $minimumTimestamp -and $timestamp + 60 -le $Now.ToUnixTimeSeconds()
        } | Sort-Object { ([DateTimeOffset] $_.timeStamp).ToUnixTimeSeconds() })
        if ($points.Count -lt 2) {
            $reasons.Add("${hostName}: need two completed one-minute buckets after $($Since.ToString('o'))")
            continue
        }
        $last = $points[-1]
        $previous = $points[-2]
        $lastTime = ([DateTimeOffset] $last.timeStamp).ToUnixTimeSeconds()
        $previousTime = ([DateTimeOffset] $previous.timeStamp).ToUnixTimeSeconds()
        if ($lastTime - $previousTime -ne 60 -or ($Now - [DateTimeOffset] $last.timeStamp).TotalSeconds -gt 300) {
            $reasons.Add("${hostName}: origin evidence is stale or not consecutive")
            continue
        }
        $healthy = $true
        foreach ($point in @($previous, $last)) {
            if (-not $point.PSObject.Properties['minimum'] -or $null -eq $point.minimum) {
                $healthy = $false
                continue
            }
            if ($point.minimum -isnot [ValueType] -or $point.minimum -is [bool]) {
                throw "Invalid origin health percentage for $hostName."
            }
            $percentage = [double] $point.minimum
            if (-not [double]::IsFinite($percentage) -or $percentage -lt 0 -or $percentage -gt 100) {
                throw "Invalid origin health percentage for $hostName."
            }
            if ($percentage -ne 100) { $healthy = $false }
        }
        if (-not $healthy) {
            $reasons.Add("${hostName}: both completed buckets must report minimum=100; missing data is not healthy")
            continue
        }
        [pscustomobject]@{ Origin = "${hostName}:443"; LatestBucketUtc = [DateTimeOffset] $last.timeStamp; MinimumPercent = 100 }
    }
    return [pscustomobject]@{ Healthy = $reasons.Count -eq 0; Reasons = $reasons.ToArray(); Origins = @($evidence) }
}
