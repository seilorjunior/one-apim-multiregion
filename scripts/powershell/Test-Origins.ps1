#requires -Version 7.4
[CmdletBinding()]
param(
    [DateTimeOffset] $Since = (Get-Date -AsUTC).AddMinutes(-5),
    [ValidateRange(0, 1800)][int] $WaitSeconds = 900
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
$values = Get-LabEnvironment
Assert-LabValues $values @(
    'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'AZURE_FRONT_DOOR_PROFILE',
    'APIM_PRIMARY_HOST', 'APIM_SECONDARY_HOST'
)
$now = [DateTimeOffset] (Get-Date -AsUTC)
if ($values.ContainsKey('APP_INGRESS_MODE') -and $values.APP_INGRESS_MODE -notin @('public', 'private')) { throw 'APP_INGRESS_MODE must be public or private.' }
$private = $values.ContainsKey('APP_INGRESS_MODE') -and $values.APP_INGRESS_MODE -eq 'private'
if ($private) {
    Assert-LabValues $values @('FRONT_DOOR_PRIMARY_ORIGIN_HOST', 'FRONT_DOOR_SECONDARY_ORIGIN_HOST', 'FRONT_DOOR_ORIGIN_GROUP')
}
$hosts = if ($values.ContainsKey('FRONT_DOOR_PRIMARY_ORIGIN_HOST') -and $values.ContainsKey('FRONT_DOOR_SECONDARY_ORIGIN_HOST')) {
    @($values.FRONT_DOOR_PRIMARY_ORIGIN_HOST, $values.FRONT_DOOR_SECONDARY_ORIGIN_HOST)
} else { @($values.APIM_PRIMARY_HOST, $values.APIM_SECONDARY_HOST) }
$originGroup = if ($values.ContainsKey('FRONT_DOOR_ORIGIN_GROUP')) { $values.FRONT_DOOR_ORIGIN_GROUP } else { 'regional-apis' }
$expectedGroup = if ($private) { 'regional-apis-private' } else { 'regional-apis' }
if ($originGroup -ne $expectedGroup) { throw 'Ingress outputs are stale. Provision the selected topology before testing it.' }
if ($private) {
    if ($hosts[0] -ne $values.APP_GATEWAY_PRIMARY_HOST -or $hosts[1] -ne $values.APP_GATEWAY_SECONDARY_HOST) {
        throw 'Origin host outputs do not match the configured private gateways.'
    }
} elseif ($hosts[0] -ne $values.APIM_PRIMARY_HOST -or $hosts[1] -ne $values.APIM_SECONDARY_HOST) {
    throw 'Origin host outputs do not match the configured public APIM gateways.'
}
if ($Since -gt $now) { throw 'Since must not be in the future.' }
if ($hosts[0] -eq $hosts[1]) { throw 'Expected two distinct regional origin hosts.' }
Invoke-LabReadiness $values -Stage Infrastructure
$resource = "/subscriptions/$($values.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($values.AZURE_RESOURCE_GROUP)/providers/Microsoft.Cdn/profiles/$($values.AZURE_FRONT_DOOR_PROFILE)"
$deadline = $now.AddSeconds($WaitSeconds)
do {
    $now = [DateTimeOffset] (Get-Date -AsUTC)
    $queryStart = if ($Since -gt $now.AddMinutes(-5)) { $now.AddMinutes(-5) } else { $Since }
    $metrics = (Invoke-LabNative az @(
        'monitor', 'metrics', 'list',
        '--subscription', $values.AZURE_SUBSCRIPTION_ID, '--resource', $resource,
        '--metric', 'OriginHealthPercentage', '--interval', 'PT1M', '--aggregation', 'Minimum',
        '--filter', "Origin eq '*' and OriginGroup eq '*'",
        '--start-time', $queryStart.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'),
        '--end-time', $now.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'),
        '--output', 'json', '--only-show-errors'
    )) | ConvertFrom-Json
    $result = Test-LabOriginMetrics $metrics $hosts $Since $now $originGroup
    if ($result.Healthy) {
        $result.Origins | Format-Table -AutoSize
        Write-Host 'PASS: both protected regional origins have fresh Front Door health-probe evidence.'
        return
    }
    $message = $result.Reasons -join '; '
    if ([DateTimeOffset] (Get-Date -AsUTC) -ge $deadline) {
        throw "Regional origin health was not proven: $message"
    }
    Write-Warning "Waiting for Azure Monitor origin health: $message"
    Start-Sleep -Seconds 30
} while ($true)
