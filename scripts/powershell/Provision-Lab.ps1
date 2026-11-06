#requires -Version 7.4
[CmdletBinding()]
param(
    [switch] $Preview,
    [switch] $StartResources,
    [ValidateRange(30, 7200)][int] $WaitSeconds = 1800
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
if (-not $Preview) {
    & (Join-Path $PSScriptRoot 'Sync-DomainBootstrap.ps1') -Provision -WaitSeconds $WaitSeconds
    & (Join-Path $PSScriptRoot 'Prepare-Lab.ps1') -StartResources:$StartResources -WaitSeconds $WaitSeconds
}
[string[]] $arguments = if ($Preview) { @('provision', '--preview') } else { @('provision') }
& azd @arguments
if ($LASTEXITCODE -ne 0) { throw "azd provision failed with exit code $LASTEXITCODE." }
