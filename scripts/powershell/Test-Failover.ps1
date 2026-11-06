#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Primary', 'Secondary')][string] $StopRegion,
    [ValidateRange(60, 1800)][int] $TimeoutSeconds = 600,
    [ValidateRange(0, 1800)][int] $OriginWaitSeconds = 900,
    [string] $ReportPath
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
$values = Get-LabEnvironment
Assert-LabValues $values @('API_URL')
$regions = Get-LabRegions $values
$target = $regions | Where-Object Key -EQ $StopRegion
$survivor = $regions | Where-Object Key -NE $StopRegion

if (-not $PSCmdlet.ShouldProcess($target.Cluster, "Verify both origins, interrupt lab-api, test availability in $($survivor.Location), restore replicas and prove origin recovery")) {
    return
}
$reportHelper = Join-Path $PSScriptRoot '..\failover_report.py'
$reportPython = $null
foreach ($name in @('python', 'python3')) {
    $candidate = Get-Command $name -ErrorAction SilentlyContinue
    if ($candidate) {
        & $candidate.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
        if ($LASTEXITCODE -eq 0) { $reportPython = $candidate.Source; break }
    }
}
if (-not $reportPython) { throw 'Failover reporting requires Python 3.9 or newer.' }
$mode = if ($values.ContainsKey('APP_INGRESS_MODE')) { $values.APP_INGRESS_MODE } else { 'public' }
$reportArguments = @('init', $mode, $target.Key, $target.Location, $survivor.Key, $survivor.Location, "$TimeoutSeconds")
if ($ReportPath) { $reportArguments += @('--path', $ReportPath) }
$reportPathResolved = & $reportPython $reportHelper @reportArguments
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize failover report. No disruption was attempted.' }
Write-Host "Failover report: $reportPathResolved"
function Write-FailoverEvidence {
    param([string[]] $ReportArguments)
    & $reportPython $reportHelper @ReportArguments --path $reportPathResolved
    if ($LASTEXITCODE -ne 0) { throw 'Could not persist failover evidence.' }
}
function Write-FailoverCleanupEvidence {
    param([string[]] $ReportArguments)
    try { Write-FailoverEvidence $ReportArguments }
    catch {
        $script:reportWriteFailed = $true
        Write-Warning 'Could not persist cleanup evidence; restoration will still be attempted.'
    }
}
function Get-FailoverSample {
    param([string] $Phase)
    $clock = (& $reportPython $reportHelper clock) -split ' '
    if ($LASTEXITCODE -ne 0) { throw 'Could not start sample timing.' }
    $status = '000'; $observedRegion = ''; $errorCategory = 'unexpected'
    try {
        $response = Invoke-WebRequest "$($values.API_URL)/whoami?${Phase}=$([Guid]::NewGuid())" -SkipHttpErrorCheck -TimeoutSec 15
        $status = [string] [int] $response.StatusCode
        if ([int] $response.StatusCode -ne 200) {
            $errorCategory = 'http'
            if ($Phase -eq 'baseline') { throw 'Baseline HTTP failure.' }
            return $null
        }
        $errorCategory = 'invalidResponse'
        $body = Test-LabResponse $response @($target.Location, $survivor.Location)
        $observedRegion = $body.region
        $errorCategory = 'none'
        return $observedRegion
    }
    catch [System.Net.Http.HttpRequestException] {
        $errorCategory = 'transport'
        if ($Phase -eq 'baseline') { throw }
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        $errorCategory = 'timeout'
        if ($Phase -eq 'baseline') { throw }
    }
    catch [System.TimeoutException] {
        $errorCategory = 'timeout'
        if ($Phase -eq 'baseline') { throw }
    }
    finally {
        Write-FailoverEvidence @('sample', $Phase, $clock[0], $clock[1], $status, $observedRegion, $errorCategory)
    }
}
$restoreRequired = $false
$reportWriteFailed = $false
$testFailed = $true
$cleanupFailed = $false
$replicas = 0
try {
    Write-FailoverEvidence @('stage', 'readiness', 'running')
    Invoke-LabReadiness $values -Stage Workloads
    Write-FailoverEvidence @('stage', 'readiness', 'passed')
    Write-FailoverEvidence @('stage', 'preflightOrigins', 'running')
    & (Join-Path $PSScriptRoot 'Test-Origins.ps1') -WaitSeconds $OriginWaitSeconds
    Write-FailoverEvidence @('stage', 'preflightOrigins', 'passed')
    Write-FailoverEvidence @('stage', 'rollouts', 'running')
    foreach ($region in $regions) {
        Write-Host (Invoke-LabAksCommand $values $region.Cluster 'kubectl rollout status deployment/lab-api -n apim-lab --timeout=120s')
    }
    $rawReplicas = Invoke-LabAksCommand $values $target.Cluster "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'"
    if (-not [int]::TryParse($rawReplicas.Trim(), [ref] $replicas) -or $replicas -lt 1) {
        throw 'Target must have a positive replica count before the failure test.'
    }
    Write-FailoverEvidence @('replicas', 'original', "$replicas")
    Write-FailoverEvidence @('stage', 'rollouts', 'passed')
    Write-FailoverEvidence @('stage', 'baseline', 'running')
    foreach ($sample in 1..5) {
        $baselineRegion = Get-FailoverSample baseline
        Write-Host "Baseline sample ${sample}: region=$baselineRegion"
    }
    Write-FailoverEvidence @('stage', 'baseline', 'passed')
    $transitionEvidence = if ($baselineRegion -eq $target.Location) { 'ObservedTransition' } else { 'ContinuedService' }
    Write-Host "Last baseline region=$baselineRegion; stopping=$($target.Location)."
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $consecutive = 0
    $failedRequests = 0
    Write-FailoverEvidence @('stage', 'disruption', 'running')
    $restoreRequired = $true
    Write-Host (Invoke-LabAksCommand $values $target.Cluster 'kubectl scale deployment lab-api -n apim-lab --replicas=0 && kubectl rollout status deployment/lab-api -n apim-lab --timeout=120s')
    $stoppedReplicas = Invoke-LabAksCommand $values $target.Cluster "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'"
    if ($stoppedReplicas.Trim() -ne '0') { throw 'Target workload did not scale to zero.' }
    Write-FailoverEvidence @('replicas', 'stopped', '0')
    Write-FailoverEvidence @('stage', 'disruption', 'passed')
    Write-FailoverEvidence @('stage', 'availability', 'running')
    do {
        $observedRegion = Get-FailoverSample failover
        if ($observedRegion) {
            Write-Host "t=$([int] $watch.Elapsed.TotalSeconds)s region=$observedRegion"
            if ($observedRegion -eq $survivor.Location) { $consecutive++ } else { $consecutive = 0 }
        }
        else {
            $failedRequests++
            $consecutive = 0
            Write-Warning 'Expected disruption during failover: HTTP/transport failure or timeout.'
        }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Failover did not stabilize within $TimeoutSeconds seconds."
        }
        if ($consecutive -ge 5) { break }
        Start-Sleep -Seconds 5
    } while ($true)
    Write-FailoverEvidence @('stage', 'availability', 'passed')
    Write-Host "PASS availability: five consecutive responses from $($survivor.Location); evidence=$transitionEvidence; elapsed=$([int] $watch.Elapsed.TotalSeconds)s; failed samples=$failedRequests."
    if ($transitionEvidence -eq 'ContinuedService') {
        Write-Warning 'The client was already using the surviving region. Availability passed; a client traffic transition was not observed.'
    }
    Write-Host 'Elapsed time includes Azure Run Command overhead; it is not an exact outage-duration measurement.'
    $testFailed = $false
}
finally {
    try {
        if ($restoreRequired) {
            Write-FailoverCleanupEvidence @('stage', 'restoration', 'running')
            try {
                Write-Host "Restoring $($target.Cluster) to $replicas replicas..."
                Write-Host (Invoke-LabAksCommand $values $target.Cluster "kubectl scale deployment lab-api -n apim-lab --replicas=$replicas && kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s")
                $recoverySince = [DateTimeOffset] (Get-Date -AsUTC)
                Write-FailoverCleanupEvidence @('stage', 'restoration', 'passed')
            }
            catch {
                $cleanupFailed = $true
                Write-FailoverCleanupEvidence @('stage', 'restoration', 'failed')
                Write-Warning "Could not restore $($target.Cluster). Restore lab-api to $replicas replicas manually."
            }
            Write-FailoverCleanupEvidence @('stage', 'replicaVerification', 'running')
            try {
                $restoredReplicas = Invoke-LabAksCommand $values $target.Cluster "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'"
                if ($restoredReplicas.Trim() -match '^\d+$') { Write-FailoverCleanupEvidence @('replicas', 'restored', $restoredReplicas.Trim()) }
                if ($restoredReplicas.Trim() -ne [string] $replicas) { throw 'Target replica count was not restored.' }
                Write-FailoverCleanupEvidence @('stage', 'replicaVerification', 'passed')
            }
            catch {
                $cleanupFailed = $true
                Write-FailoverCleanupEvidence @('stage', 'replicaVerification', 'failed')
                Write-Warning 'Target replica count could not be verified after restoration.'
            }
            if (-not $cleanupFailed) {
                Write-FailoverCleanupEvidence @('stage', 'recoveryOrigins', 'running')
                try {
                    & (Join-Path $PSScriptRoot 'Test-Origins.ps1') -Since $recoverySince -WaitSeconds $OriginWaitSeconds
                    Write-FailoverCleanupEvidence @('stage', 'recoveryOrigins', 'passed')
                }
                catch {
                    $cleanupFailed = $true
                    Write-FailoverCleanupEvidence @('stage', 'recoveryOrigins', 'failed')
                    Write-Warning 'Fresh strict origin recovery was not proven.'
                }
                Write-FailoverCleanupEvidence @('stage', 'recoverySmoke', 'running')
                try {
                    & (Join-Path $PSScriptRoot 'Test-Lab.ps1') -WaitSeconds 600
                    Write-FailoverCleanupEvidence @('stage', 'recoverySmoke', 'passed')
                }
                catch {
                    $cleanupFailed = $true
                    Write-FailoverCleanupEvidence @('stage', 'recoverySmoke', 'failed')
                    Write-Warning 'Post-restoration smoke checks failed.'
                }
            }
        }
    }
    finally {
        $reportCode = if ($testFailed -or $cleanupFailed -or $reportWriteFailed) { '1' } else { '0' }
        Write-FailoverCleanupEvidence @('finish', $reportCode)
    }
}
if ($cleanupFailed -or $reportWriteFailed) { throw "Failover recovery or evidence persistence failed. Inspect $reportPathResolved." }
Write-Host 'PASS recovery: original replicas restored and both Front Door origins healthy after restoration. This does not require this client to move back.'
