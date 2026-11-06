#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $Approve,
    [ValidateRange(0, 1800)][int] $WaitSeconds = 600
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
$values = Get-LabEnvironment
if (-not $values.ContainsKey('APP_INGRESS_MODE') -or $values.APP_INGRESS_MODE -eq 'public') {
    Write-Host 'Public ingress: no Private Link approval is required.'
    return
}
if ($values.APP_INGRESS_MODE -ne 'private') { throw 'APP_INGRESS_MODE must be public or private.' }
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($WaitSeconds)
$approved = @{}
do {
    $origins = @(Get-LabPrivateOrigins $values)
    if (@($origins | Where-Object { $_.Status -notin @('Approved', 'ApprovedAtGateway') }).Count -eq 0) {
        Write-Host 'PASS: both expected origin connections are approved (Front Door or verified gateway-side evidence). Runtime TLS/API health still requires publication and fresh origin checks.'
        return
    }
    if (-not $Approve) {
        throw 'Private Link is pending or initializing; both origin approvals are not yet verified. Inspect the requests in each Application Gateway, then run Connect-PrivateOrigins.ps1 -Approve (interactive confirmation). After approval, rerun Deploy-LabApi.ps1.'
    }
    foreach ($origin in $origins | Where-Object { $_.Status -in @('Pending', 'Initializing') -and $_.ConnectionId }) {
        if (-not $approved.ContainsKey($origin.ConnectionId)) {
            Write-Warning 'The request-message marker is not authentication. Confirm the connection belongs to this Front Door profile before approving.'
            if (-not $PSCmdlet.ShouldProcess($origin.ConnectionId, "Approve the expected connection for $($origin.ProfileId)")) {
                throw 'Private Link approval was not performed. Private ingress is not ready.'
            }
            $null = Invoke-LabNative az @(
                'network', 'private-endpoint-connection', 'approve', '--id', $origin.ConnectionId,
                '--description', (Get-LabPrivateLinkMarker $origin.ProfileId), '--only-show-errors'
            )
            $approved[$origin.ConnectionId] = $true
        }
    }
    if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Private Link is still pending or initializing; both origin approvals are not yet verified. Inspect gateway connections and allow propagation, then rerun the check. No unrelated requests were approved.' }
    Start-Sleep -Seconds 20
} while ($true)
