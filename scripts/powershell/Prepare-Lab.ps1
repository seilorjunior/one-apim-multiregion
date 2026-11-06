#requires -Version 7.4
[CmdletBinding()]
param(
    [switch] $StartClusters,
    [switch] $StartResources,
    [ValidateRange(30, 7200)][int] $WaitSeconds = 1800
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')

foreach ($tool in @('azd', 'az')) {
    $null = Get-Command $tool -ErrorAction Stop
}
$values = Get-LabEnvironment
Assert-LabValues $values @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_LOCATION', 'APIM_PUBLISHER_EMAIL')
if ($values.AZURE_ENV_NAME -notmatch '^[a-z][a-z0-9-]{2,23}$') {
    throw 'Environment name must have 3-24 lowercase letters/digits/hyphens and start with a letter.'
}
if ($values.APIM_PUBLISHER_EMAIL -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw 'APIM_PUBLISHER_EMAIL must contain a valid publisher email address.'
}
if (-not $values.ContainsKey('AZURE_SECONDARY_LOCATION')) {
    $values.AZURE_SECONDARY_LOCATION = 'eastus'
    $null = Invoke-LabNative azd @('env', 'set', 'AZURE_SECONDARY_LOCATION', $values.AZURE_SECONDARY_LOCATION)
}
if (-not $values.ContainsKey('APIM_PUBLISHER_NAME')) {
    $null = Invoke-LabNative azd @('env', 'set', 'APIM_PUBLISHER_NAME', 'Multi-region laboratory')
}
if ($values.AZURE_LOCATION -eq $values.AZURE_SECONDARY_LOCATION) {
    throw 'Primary and secondary regions must be different.'
}
foreach ($region in @($values.AZURE_LOCATION, $values.AZURE_SECONDARY_LOCATION)) {
    if ($region -notmatch '^[a-z][a-z0-9]+$') {
        throw "Use the Azure location identifier without spaces: $region"
    }
}
$account = (Invoke-LabNative az @(
    'account', 'show', '--subscription', $values.AZURE_SUBSCRIPTION_ID, '--output', 'json', '--only-show-errors'
)) | ConvertFrom-Json
if ($account.state -ne 'Enabled') {
    throw "Azure subscription is not enabled: $($account.id)"
}
if ($values.ContainsKey('APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE') -and $values.APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE) {
    & (Join-Path $PSScriptRoot 'Sync-DomainBootstrap.ps1')
    $values = Get-LabEnvironment
}
Set-LabIngressConfiguration $values
$directory = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".azure\$($values.AZURE_ENV_NAME)\tls"
if (-not (Test-Path -LiteralPath $directory)) {
    New-LabTlsFiles $directory
}
Assert-LabTlsFiles $directory
Assert-LabGatewayCertificate $values $directory
if ($values.APP_INGRESS_MODE -eq 'private') {
    foreach ($name in @('APP_GATEWAY_PRIMARY_HOST', 'APP_GATEWAY_SECONDARY_HOST', 'APP_GATEWAY_CERTIFICATE_SECRET_ID', 'APP_GATEWAY_NETWORK_MODE')) {
        $null = Invoke-LabNative azd @('env', 'set', $name, $values[$name])
    }
    Write-Warning 'Private ingress changes APIM to Internal and adds two billable Application Gateways. Plan the cutover and approve the expected Front Door Private Link requests before publishing workloads.'
}
$publicRoot = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $directory 'root.cer')))
$null = Invoke-LabNative azd @('env', 'set', 'LAB_ROOT_CERTIFICATE', $publicRoot)
if ($StartClusters -and -not $StartResources) {
    Wait-LabClustersRunning $values -StartClusters -WaitSeconds $WaitSeconds
}
Invoke-LabReadiness $values -Stage Prepare -StartResources:$StartResources -WaitSeconds $WaitSeconds
Write-Host "Prepared lab for subscription $($account.id): $($values.AZURE_LOCATION) + $($values.AZURE_SECONDARY_LOCATION)."
Write-Warning 'Provisioning creates two Premium classic APIM units, two AKS clusters and Front Door Premium. Charges accrue while resources exist.'
