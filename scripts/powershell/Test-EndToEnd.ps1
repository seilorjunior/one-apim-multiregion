#requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $TemporaryClusterAdmin,
    [ValidateRange(1, 100)][int] $Samples = 20,
    [ValidateRange(60, 1800)][int] $TimeoutSeconds = 600,
    [ValidateRange(30, 1800)][int] $RbacWaitSeconds = 600,
    [ValidateRange(0, 1800)][int] $OriginWaitSeconds = 900
)

. (Join-Path $PSScriptRoot 'Lab.Common.ps1')
$values = Get-LabEnvironment
Assert-LabValues $values @('AZURE_ENV_NAME', 'API_URL')
$regions = Get-LabRegions $values
$target = "$($values.AZURE_ENV_NAME): $($regions.Cluster -join ', ')"
$action = 'Run smoke tests, stop each regional workload in turn, and restore its original replicas'
if ($TemporaryClusterAdmin) {
    $action += '; grant temporary AKS RBAC Cluster Admin to the signed-in CLI user and remove only newly created assignments'
}
if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    return
}

$assignments = [Collections.Generic.List[object]]::new()
$replicas = @{}
$cleanupErrors = [Collections.Generic.List[string]]::new()
$runError = $null
$failoverStarted = $false
$roleId = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'

try {
    & (Join-Path $PSScriptRoot 'Test-Origins.ps1') -WaitSeconds $OriginWaitSeconds
    if ($TemporaryClusterAdmin) {
        $user = (Invoke-LabNative az @('ad', 'signed-in-user', 'show', '--output', 'json', '--only-show-errors')) | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($user.id) -or [string]::IsNullOrWhiteSpace($user.userPrincipalName)) {
            throw 'TemporaryClusterAdmin requires an interactive Azure CLI user login.'
        }
        Write-Host "Temporary access identity: $($user.userPrincipalName)"
        foreach ($region in $regions) {
            $scope = "/subscriptions/$($values.AZURE_SUBSCRIPTION_ID)/resourceGroups/$($values.AZURE_RESOURCE_GROUP)/providers/Microsoft.ContainerService/managedClusters/$($region.Cluster)"
            $existing = @((Invoke-LabNative az @(
                'role', 'assignment', 'list',
                '--subscription', $values.AZURE_SUBSCRIPTION_ID,
                '--assignee', $user.id, '--scope', $scope,
                '--include-inherited', '--include-groups',
                '--output', 'json', '--only-show-errors'
            )) | ConvertFrom-Json)
            if (@($existing | Where-Object { ($_.roleDefinitionId -split '/')[-1] -eq $roleId }).Count -gt 0) {
                Write-Host "Preserving existing AKS RBAC Cluster Admin access on $($region.Cluster)."
                continue
            }
            $name = [Guid]::NewGuid().ToString()
            $assignment = [pscustomobject]@{
                Id = "$scope/providers/Microsoft.Authorization/roleAssignments/$name"
                Name = $name
                Scope = $scope
            }
            $assignments.Add($assignment)
            $null = Invoke-LabNative az @(
                'role', 'assignment', 'create',
                '--subscription', $values.AZURE_SUBSCRIPTION_ID,
                '--name', $name, '--assignee-object-id', $user.id,
                '--assignee-principal-type', 'User', '--role', $roleId, '--scope', $scope,
                '--output', 'json', '--only-show-errors'
            )
            Write-Host "Temporary access granted on $($region.Cluster): $($assignment.Id)"
        }
    }

    foreach ($region in $regions) {
        $deadline = [DateTime]::UtcNow.AddSeconds($RbacWaitSeconds)
        do {
            $probe = (Invoke-LabNative az @(
                'aks', 'command', 'invoke',
                '--subscription', $values.AZURE_SUBSCRIPTION_ID,
                '--resource-group', $values.AZURE_RESOURCE_GROUP,
                '--name', $region.Cluster,
                '--command', 'kubectl auth can-i get deployments.apps -n apim-lab --quiet && kubectl auth can-i watch deployments.apps -n apim-lab --quiet && kubectl auth can-i get deployments.apps --subresource=scale -n apim-lab --quiet && kubectl auth can-i update deployments.apps --subresource=scale -n apim-lab --quiet',
                '--output', 'json', '--only-show-errors'
            )) | ConvertFrom-Json
            if (-not $probe.PSObject.Properties['exitCode'] -or $null -eq $probe.exitCode) {
                throw "Authorization probe returned no exit code for $($region.Cluster)."
            }
            if ($probe.exitCode -eq 0) { break }
            if ($probe.exitCode -ne 1 -or -not $TemporaryClusterAdmin -or [DateTime]::UtcNow -ge $deadline) {
                throw "Kubernetes access is not ready on $($region.Cluster): $($probe.logs). Grant workload access or use -TemporaryClusterAdmin with role-assignment permissions."
            }
            Write-Warning "Waiting for Azure RBAC propagation on $($region.Cluster)."
            Start-Sleep -Seconds 15
        } while ($true)
        Write-Host (Invoke-LabAksCommand $values $region.Cluster 'kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s')
        $raw = Invoke-LabAksCommand $values $region.Cluster "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'"
        $count = 0
        if (-not [int]::TryParse($raw.Trim(), [ref] $count) -or $count -lt 1) {
            throw "Expected a positive replica count on $($region.Cluster)."
        }
        $replicas[$region.Cluster] = $count
    }

    Invoke-LabReadiness $values -Stage Workloads
    Write-Host 'Running initial smoke test...'
    & (Join-Path $PSScriptRoot 'Test-Lab.ps1') -WaitSeconds 120 -Samples $Samples
    foreach ($region in $regions) {
        Write-Host "Testing failure of $($region.Location) ($($region.Key))..."
        $failoverStarted = $true
        & (Join-Path $PSScriptRoot 'Test-Failover.ps1') -StopRegion $region.Key -TimeoutSeconds $TimeoutSeconds -OriginWaitSeconds $OriginWaitSeconds -Confirm:$false
        Write-Host (Invoke-LabAksCommand $values $region.Cluster 'kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s')
        $raw = Invoke-LabAksCommand $values $region.Cluster "kubectl get deployment lab-api -n apim-lab -o jsonpath='{.spec.replicas}'"
        if ($raw.Trim() -ne [string] $replicas[$region.Cluster]) {
            throw "Replica count was not restored on $($region.Cluster)."
        }
    }
}
catch {
    $runError = $_
    Write-Error -Message "End-to-end test failed: $($_.Exception.Message)" -ErrorAction Continue
}
finally {
    if ($failoverStarted) {
        foreach ($region in $regions) {
            try {
                $count = $replicas[$region.Cluster]
                Write-Host "Ensuring original replica count on $($region.Cluster): $count"
                Write-Host (Invoke-LabAksCommand $values $region.Cluster "kubectl scale deployment lab-api -n apim-lab --replicas=$count && kubectl rollout status deployment/lab-api -n apim-lab --timeout=180s")
            }
            catch {
                $message = "Could not restore $($region.Cluster): $($_.Exception.Message). Restore lab-api to $count replicas manually."
                $cleanupErrors.Add($message)
                Write-Error -Message $message -ErrorAction Continue
            }
        }
    }
    foreach ($assignment in $assignments) {
        try {
            $null = Invoke-LabNative az @(
                'role', 'assignment', 'delete',
                '--subscription', $values.AZURE_SUBSCRIPTION_ID,
                '--ids', $assignment.Id, '--only-show-errors'
            )
            $remaining = @((Invoke-LabNative az @(
                'role', 'assignment', 'list',
                '--subscription', $values.AZURE_SUBSCRIPTION_ID,
                '--scope', $assignment.Scope,
                '--query', "[?name=='$($assignment.Name)']",
                '--output', 'json', '--only-show-errors'
            )) | ConvertFrom-Json)
            if ($remaining.Count -gt 0) {
                throw 'Assignment is still present after deletion.'
            }
            Write-Host "Temporary access removed and verified: $($assignment.Id)"
        }
        catch {
            $message = "Could not remove temporary assignment $($assignment.Id): $($_.Exception.Message)"
            $cleanupErrors.Add($message)
            Write-Error -Message $message -ErrorAction Continue
        }
    }
}
if ($runError) {
    throw $runError
}
if ($cleanupErrors.Count -gt 0) {
    throw ($cleanupErrors -join [Environment]::NewLine)
}

Write-Host 'Running final smoke test after restoring replicas and removing temporary access...'
& (Join-Path $PSScriptRoot 'Test-Origins.ps1') -WaitSeconds $OriginWaitSeconds
& (Join-Path $PSScriptRoot 'Test-Lab.ps1') -WaitSeconds 600 -Samples $Samples
$regions | Select-Object Location, Cluster, @{ Name = 'RestoredReplicas'; Expression = { $replicas[$_.Cluster] } } | Format-Table -AutoSize
Write-Host "PASS: both failover directions completed, workloads restored, and global API healthy: $($values.API_URL)"
Write-Warning 'This is a sampled workload-failure test, not a regional outage or exact RTO measurement. Both origins were verified using fresh probe metrics; recovery does not require this client to return to its original region.'
