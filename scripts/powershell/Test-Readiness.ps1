#requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Infrastructure', 'Workloads')][string] $Stage = 'Workloads',
    [switch] $StartResources,
    [switch] $Json,
    [ValidateRange(30, 7200)][int] $WaitSeconds = 1800
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
$watch = [Diagnostics.Stopwatch]::StartNew()
if ($Json) {
    $python = Get-Command python, python3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) { throw 'JSON readiness requires Python 3.9 or newer.' }
    $arguments = @((Join-Path $PSScriptRoot '..\lab_readiness.py'), '--stage', $Stage,
        '--format', 'json', '--private-check-shell', 'powershell', '--wait-seconds', "$WaitSeconds")
    if ($StartResources) { $arguments += '--start-resources' }
    & $python.Source @arguments
    exit $LASTEXITCODE
}
$values = Get-LabEnvironment
Invoke-LabReadiness $values -Stage $Stage -StartResources:$StartResources -WaitSeconds $WaitSeconds
Write-Host "Readiness prerequisites passed ($([int]$watch.Elapsed.TotalSeconds)s total). Run Test-Lab and Test-Origins separately to prove runtime API/TLS and fresh regional health."
