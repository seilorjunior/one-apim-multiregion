#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateRange(1, 50)][int] $Vus = 2,
    [ValidateRange(1, 600)][int] $DurationSeconds = 60,
    [ValidateRange(1, 60000)][int] $P95Milliseconds = 1500,
    [ValidateRange(1, 60000)][int] $P99Milliseconds = 3000,
    [string] $SummaryPath = 'load-results/summary.json'
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
if ($P99Milliseconds -lt $P95Milliseconds) { throw 'P99Milliseconds must be at least P95Milliseconds.' }
$values = Get-LabEnvironment
Assert-LabValues $values @('API_URL', 'AZURE_PRIMARY_LOCATION', 'AZURE_SECONDARY_LOCATION')
if (-not $PSCmdlet.ShouldProcess($values.API_URL, "Generate up to $Vus concurrent requests for $DurationSeconds seconds, plus request drain time")) {
    return
}
if (-not (Get-Command k6 -ErrorAction SilentlyContinue)) { throw 'k6 must be installed and on PATH.' }
Invoke-LabReadiness $values -Stage Workloads
$summary = [IO.Path]::GetFullPath($SummaryPath)
New-Item -ItemType Directory -Force (Split-Path -Parent $summary) | Out-Null
& k6 run --no-usage-report --summary-export $summary `
    --env "API_URL=$($values.API_URL)" --env "PRIMARY_REGION=$($values.AZURE_PRIMARY_LOCATION)" `
    --env "SECONDARY_REGION=$($values.AZURE_SECONDARY_LOCATION)" --env CONFIRM_LOAD=yes `
    --env "LOAD_VUS=$Vus" --env "LOAD_SECONDS=$DurationSeconds" `
    --env "LOAD_P95_MS=$P95Milliseconds" --env "LOAD_P99_MS=$P99Milliseconds" `
    (Join-Path $PSScriptRoot '../../tests/load/lab.js')
if ($LASTEXITCODE -ne 0) { throw "k6 failed or thresholds were exceeded (exit $LASTEXITCODE). Summary: $summary" }
Write-Host "PASS: k6 thresholds passed. Summary: $summary. This is not strict regional origin-health or failover evidence."
