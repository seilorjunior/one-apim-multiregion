#requires -Version 7.4
[CmdletBinding()]
param(
    [switch] $Provision,
    [ValidateRange(1, 7200)][int] $WaitSeconds = 1800
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
$values = Get-LabEnvironment
if (-not $values.ContainsKey('APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE') -or -not $values.APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE) {
    Write-Host 'Domain bootstrap not configured; using the existing/manual certificate workflow.'
    return
}
$python = $null
foreach ($name in @('python', 'python3')) {
    $candidate = Get-Command $name -ErrorAction SilentlyContinue
    if ($candidate) {
        & $candidate.Source -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'
        if ($LASTEXITCODE -eq 0) { $python = $candidate.Source; break }
    }
}
if (-not $python) { throw 'The optional domain bootstrap requires Python 3.9 or newer. Install Python or leave APP_DOMAIN_BOOTSTRAP_PARAMETERS_FILE unset to use a manually configured certificate.' }
$arguments = @((Join-Path $PSScriptRoot '..\domain_bootstrap.py'), '--wait-seconds', "$WaitSeconds")
if ($Provision) { $arguments += '--provision' }
& $python @arguments
if ($LASTEXITCODE -ne 0) { throw "Domain bootstrap failed with exit code $LASTEXITCODE. No lab deployment will continue." }
