#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateRange(0, 3600)][int] $WaitSeconds = 0,
    [ValidateRange(1, 100)][int] $Samples = 10
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
$values = Get-LabEnvironment
Assert-LabValues $values @('API_URL', 'AZURE_PRIMARY_LOCATION', 'AZURE_SECONDARY_LOCATION')
Invoke-LabReadiness $values -Stage Infrastructure
$expected = @($values.AZURE_PRIMARY_LOCATION, $values.AZURE_SECONDARY_LOCATION)
$deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
do {
    $ready = $false
    try {
        $response = Invoke-WebRequest "$($values.API_URL)/whoami" -SkipHttpErrorCheck -TimeoutSec 30
        if ([int] $response.StatusCode -eq 200) {
            $null = Test-LabResponse $response $expected
            $ready = $true
        }
        else {
            Write-Warning "API is not ready: HTTP $($response.StatusCode). Infrastructure preflight passed, but runtime DNS/TLS/backend health may still fail; this is not necessarily propagation."
        }
    }
    catch [System.Net.Http.HttpRequestException] {
        Write-Warning "API transport not ready: $($_.Exception.Message)"
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        Write-Warning "API request timed out: $($_.Exception.Message)"
    }
    catch [System.TimeoutException] {
        Write-Warning "API request timed out: $($_.Exception.Message)"
    }
    if (-not $ready) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw 'API is not ready. Inspect Front Door probes, APIM GatewayLogs, private DNS and AKS pods.'
        }
        Start-Sleep -Seconds 15
    }
} until ($ready)

foreach ($method in @('GET', 'HEAD')) {
    $health = Invoke-WebRequest "$($values.API_URL)/health/ready" -Method $method -SkipHttpErrorCheck -TimeoutSec 30
    if ([int] $health.StatusCode -ne 200) {
        throw "$method readiness failed with HTTP $($health.StatusCode)."
    }
}
$results = foreach ($index in 1..$Samples) {
    $response = Invoke-WebRequest "$($values.API_URL)/whoami?sample=$index" -SkipHttpErrorCheck -TimeoutSec 30
    $body = Test-LabResponse $response $expected
    [pscustomobject]@{
        Sample = $index
        Region = $body.region
        Cluster = $body.cluster
        Pod = $body.pod
        Gateway = $response.Headers['X-Lab-Gateway-Region'] -join ''
    }
}
$results | Format-Table -AutoSize
Write-Host 'Smoke test passed. A single client may hit only the lower-latency region; this does not prove both origins are healthy.'
