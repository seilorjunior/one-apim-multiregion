#requires -Version 7.4
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$values = Get-LabEnvironment
Assert-LabValues $values @('AZURE_ENV_NAME', 'LAB_ROOT_CERTIFICATE')
Invoke-LabReadiness $values -Stage Infrastructure
$regions = Get-LabRegions $values
$tlsDirectory = Join-Path $root ".azure\$($values.AZURE_ENV_NAME)\tls"
Assert-LabTlsFiles $tlsDirectory
$localRoot = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $tlsDirectory 'root.cer')))
if ($localRoot -ne $values.LAB_ROOT_CERTIFICATE) {
    throw 'Local TLS CA differs from the azd CA value. Re-run azd provision before deploying workloads.'
}
foreach ($region in $regions) {
    $manifest = New-LabManifest (Join-Path $root 'src\lab-api\workload.yaml') $tlsDirectory $region
    $path = Join-Path $tlsDirectory "workload-$($region.Key.ToLowerInvariant()).yaml"
    try {
        [IO.File]::WriteAllText($path, $manifest)
        Write-Host "Deploying sample API in $($region.Cluster) via AKS Run Command..."
        $command = "kubectl apply -f $(Split-Path $path -Leaf) && kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s"
        Write-Host (Invoke-LabAksCommand $values $region.Cluster $command $path)
        $waitForIp = @'
for i in $(seq 1 60); do
  ip=$(kubectl get service lab-api -n apim-lab -o jsonpath='{.status.loadBalancer.ingress[0].ip}') || exit 1
  if [ "$ip" = "__BACKEND_IP__" ]; then echo "Internal service ready: $ip"; exit 0; fi
  sleep 5
done
echo "Internal Load Balancer did not receive its expected private IP" >&2
exit 1
'@
        Write-Host (Invoke-LabAksCommand $values $region.Cluster ($waitForIp.Replace('__BACKEND_IP__', $region.BackendIp)))
    }
    finally {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}
$deployedSince = [DateTimeOffset] (Get-Date -AsUTC)
Invoke-LabReadiness $values -Stage Workloads
& (Join-Path $PSScriptRoot 'Test-Lab.ps1') -WaitSeconds 1200
& (Join-Path $PSScriptRoot 'Test-Origins.ps1') -Since $deployedSince
