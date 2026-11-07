#requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$checks = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Get-TestArgument {
    param([object[]] $Arguments, [string] $Name)
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -lt 0) { return $null }
    return [string] $Arguments[$index + 1]
}

function Invoke-TestCase {
    param(
        [switch] $TemporaryAccess,
        [switch] $ExistingAccess,
        [switch] $FailRequest,
        [switch] $FailRestore,
        [switch] $FailDelete,
        [switch] $DenyAccess,
        [switch] $FailSecondGrant,
        [switch] $FailOriginRead,
        [switch] $FailRecoveryHealth,
        [switch] $RecentOriginBoundary,
        [switch] $FailReadiness,
        [switch] $DirectFailover,
        [switch] $ContinuedService,
        [switch] $PrivateIngress,
        [switch] $WhatIf
    )
    $state = [pscustomobject]@{
        Replicas = @{ primary = 3; secondary = 2 }
        Assignments = @{}
        Events = [Collections.Generic.List[string]]::new()
        FailRequest = [bool] $FailRequest
        RequestFailed = $false
        FailRestore = [bool] $FailRestore
        FailDelete = [bool] $FailDelete
        DenyAccess = [bool] $DenyAccess
        FailSecondGrant = [bool] $FailSecondGrant
        FailOriginRead = [bool] $FailOriginRead
        FailRecoveryHealth = [bool] $FailRecoveryHealth
        Clock = [DateTimeOffset]::UtcNow.AddHours(-2)
        FreezeClock = [bool] $RecentOriginBoundary
        MetricWindowSeconds = 0
        FailReadiness = [bool] $FailReadiness
        ReadinessCalls = [Collections.Generic.List[string]]::new()
        ContinuedService = [bool] $ContinuedService
        PrivateIngress = [bool] $PrivateIngress
    }
    if ($ExistingAccess) {
        $state.Assignments['existing'] = [pscustomobject]@{
            name = 'existing'
            id = '/pre-existing-assignment'
            scope = '/subscriptions/subscription'
            roleDefinitionId = '/roles/b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'
        }
    }
    function azd {
        $global:LASTEXITCODE = 0
        @(
            'AZURE_ENV_NAME="offline-test"'
            'AZURE_SUBSCRIPTION_ID="subscription"'
            'AZURE_RESOURCE_GROUP="rg-test"'
            'AZURE_PRIMARY_LOCATION="westus3"'
            'AZURE_SECONDARY_LOCATION="centralus"'
            'AKS_PRIMARY_NAME="primary"'
            'AKS_SECONDARY_NAME="secondary"'
            'BACKEND_PRIMARY_IP="10.10.2.10"'
            'BACKEND_SECONDARY_IP="10.20.2.10"'
            'APIM_PRIMARY_SUBNET="10.10.0.0/26"'
            'APIM_SECONDARY_SUBNET="10.20.0.0/26"'
            'AZURE_FRONT_DOOR_PROFILE="afd-test"'
            'APIM_PRIMARY_HOST="primary.regional.azure-api.net"'
            'APIM_SECONDARY_HOST="secondary.regional.azure-api.net"'
            'API_URL="https://lab.invalid/lab"'
            if ($state.PrivateIngress) {
                'APP_INGRESS_MODE="private"'
                'FRONT_DOOR_PRIMARY_ORIGIN_HOST="primary.regional.azure-api.net"'
                'FRONT_DOOR_SECONDARY_ORIGIN_HOST="secondary.regional.azure-api.net"'
                'APP_GATEWAY_PRIMARY_HOST="primary.regional.azure-api.net"'
                'APP_GATEWAY_SECONDARY_HOST="secondary.regional.azure-api.net"'
                'FRONT_DOOR_ORIGIN_GROUP="regional-apis-private"'
            }
        )
    }
    function az {
        $arguments = $args
        $global:LASTEXITCODE = 0
        $operation = $arguments[0..2] -join ' '
        switch ($operation) {
            'monitor metrics list' {
                if ($state.FailOriginRead) { $global:LASTEXITCODE = 1; return 'Metric access denied' }
                $end = [DateTimeOffset] (Get-TestArgument $arguments '--end-time')
                $start = [DateTimeOffset] (Get-TestArgument $arguments '--start-time')
                $state.MetricWindowSeconds = ($end - $start).TotalSeconds
                if ($state.MetricWindowSeconds -lt 60) { throw 'Metric query requires at least one minute.' }
                $minute = [DateTimeOffset]::FromUnixTimeSeconds([long] ([Math]::Floor($end.ToUnixTimeSeconds() / 60.0) * 60))
                $series = foreach ($hostName in @('primary.regional.azure-api.net', 'secondary.regional.azure-api.net')) {
                    @{
                        metadatavalues = @(
                            @{ name = @{ value = 'Origin' }; value = "${hostName}:443" }
                            @{ name = @{ value = 'OriginGroup' }; value = $(if ($state.PrivateIngress) { 'regional-apis-private' } else { 'regional-apis' }) }
                        )
                        data = @(
                            @{ timeStamp = $minute.AddMinutes(-2).ToString('o'); minimum = 100 }
                            @{ timeStamp = $minute.AddMinutes(-1).ToString('o'); minimum = $(if ($state.FailRecoveryHealth -and @($state.Events | Where-Object { $_ -like 'scale:*:0' }).Count -gt 0) { 0 } else { 100 }) }
                        )
                    }
                }
                $state.Events.Add('origins:healthy')
                return @{ value = @(@{ name = @{ value = 'OriginHealthPercentage' }; timeseries = @($series) }) } | ConvertTo-Json -Depth 10
            }
            'ad signed-in-user show' {
                return '{"id":"user-id","userPrincipalName":"tester@example.invalid"}'
            }
            'role assignment list' {
                $query = Get-TestArgument $arguments '--query'
                $scope = Get-TestArgument $arguments '--scope'
                $items = @($state.Assignments.Values | Where-Object { $_.scope -eq $scope -or $scope.StartsWith("$($_.scope)/") })
                if ($query) {
                    if ($query -notmatch "^\[\?name=='([^']+)'\]$") { throw "Unexpected test query: $query" }
                    $items = @($items | Where-Object name -EQ $Matches[1])
                }
                return ConvertTo-Json -InputObject $items -Depth 5
            }
            'role assignment create' {
                $name = Get-TestArgument $arguments '--name'
                $scope = Get-TestArgument $arguments '--scope'
                if ($state.FailSecondGrant -and $scope.EndsWith('/secondary')) {
                    $global:LASTEXITCODE = 1
                    return 'Role assignment denied'
                }
                $state.Assignments[$name] = [pscustomobject]@{
                    name = $name
                    id = "$scope/providers/Microsoft.Authorization/roleAssignments/$name"
                    scope = $scope
                    roleDefinitionId = '/roles/b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'
                }
                $state.Events.Add("grant:$name")
                return '{}'
            }
            'role assignment delete' {
                $id = Get-TestArgument $arguments '--ids'
                $name = ($id -split '/')[-1]
                $state.Events.Add("delete:$name")
                if ($state.FailDelete) {
                    $global:LASTEXITCODE = 1
                    return 'Role deletion denied'
                }
                $state.Assignments.Remove($name)
                return
            }
            'aks command invoke' {
                $cluster = Get-TestArgument $arguments '--name'
                $command = Get-TestArgument $arguments '--command'
                $exitCode = 0
                $logs = 'ok'
                if ($command.StartsWith('kubectl auth can-i')) {
                    if ($state.DenyAccess) { $exitCode = 1; $logs = 'forbidden' }
                }
                elseif ($command.StartsWith('kubectl get deployment')) {
                    $logs = [string] $state.Replicas[$cluster]
                }
                elseif ($command -match '--replicas=(\d+)') {
                    $count = [int] $Matches[1]
                    $state.Events.Add("scale:${cluster}:$count")
                    if ($state.FailRestore -and $cluster -eq 'primary' -and $count -gt 0) {
                        $exitCode = 7
                        $logs = 'Restore failed'
                    }
                    else { $state.Replicas[$cluster] = $count }
                }
                elseif (-not $command.StartsWith('kubectl rollout status')) {
                    throw "Unexpected test command: $command"
                }
                return @{ exitCode = $exitCode; logs = $logs } | ConvertTo-Json
            }
            default { throw "Unexpected native invocation: $($arguments -join ' ')" }
        }
    }
    function Start-Sleep { param($Seconds) }
    function Get-Date {
        param([switch] $AsUTC)
        $result = $state.Clock.UtcDateTime
        if (-not $state.FreezeClock) { $state.Clock = $state.Clock.AddMinutes(3) }
        return $result
    }
    function Invoke-WebRequest {
        param($Uri, $Method, [switch] $SkipHttpErrorCheck, $TimeoutSec)
        if ($state.FailRequest -and -not $state.RequestFailed -and $state.Replicas.primary -eq 0) {
            $state.RequestFailed = $true
            throw [InvalidOperationException]::new('Injected request failure')
        }
        $cluster = if ($state.Replicas.primary -eq 0 -or $state.ContinuedService) { 'secondary' } else { 'primary' }
        $location = if ($cluster -eq 'primary') { 'westus3' } else { 'centralus' }
        $state.Events.Add("http:$location")
        $http = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
        $http.RequestMessage = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
        $http.Content = [Net.Http.StringContent]::new("{`"region`":`"$location`",`"cluster`":`"$cluster`",`"pod`":`"pod-1`"}")
        $null = $http.Headers.TryAddWithoutValidation('X-Lab-Gateway-Region', $location)
        return [Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]::new(
            $http, [TimeSpan]::FromSeconds(1), [Threading.CancellationToken]::None
        )
    }

    $testWork = Join-Path $root ".artifacts\failover-tests\$([Guid]::NewGuid().ToString('N'))"
    $testScripts = Join-Path $testWork 'scripts\powershell'
    $null = New-Item -ItemType Directory -Path $testScripts -Force
    Copy-Item (Join-Path $root 'scripts\failover_report.py') (Join-Path $testWork 'scripts\failover_report.py')
    Copy-Item (Join-Path $root 'scripts\lab_contracts.py') (Join-Path $testWork 'scripts\lab_contracts.py')
    Get-ChildItem (Join-Path $root 'scripts\powershell') -Filter '*.ps1' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $testScripts
    }
    Add-Content -LiteralPath (Join-Path $testScripts 'Lab.Common.ps1') -Value @'

function Invoke-LabReadiness {
    param($Values, $Stage, [switch] $StartResources, $WaitSeconds)
    if ($StartResources) { throw 'Tests must never opt into resource startup.' }
    $state.ReadinessCalls.Add($Stage)
    if ($state.FailReadiness -and $Stage -eq 'Workloads') { throw 'Injected workload readiness failure' }
}
'@
    $log = Join-Path $testWork 'run.log'
    $failure = $null
    $failureLog = ''
    $reports = @()
    Push-Location $testWork
    try {
        if ($RecentOriginBoundary) {
            & (Join-Path $testScripts 'Test-Origins.ps1') -Since $state.Clock -WaitSeconds 0 *> $log
        }
        elseif ($DirectFailover) {
            & (Join-Path $testScripts 'Test-Failover.ps1') -StopRegion Primary -OriginWaitSeconds 0 -ReportPath (Join-Path $testWork 'evidence\explicit.json') -Confirm:$false -WhatIf:$WhatIf *> $log
        }
        else {
            & (Join-Path $testScripts 'Test-EndToEnd.ps1') -TemporaryClusterAdmin:$TemporaryAccess -Samples 1 -OriginWaitSeconds 0 -Confirm:$false -WhatIf:$WhatIf *> $log
        }
    }
    catch { $failure = $_ }
    finally {
        if ($failure -and (Test-Path $log)) { $failureLog = Get-Content -Raw $log }
        $reports = @(Get-ChildItem -LiteralPath $testWork -Filter '*.json' -Recurse | ForEach-Object { Get-Content -Raw $_.FullName | ConvertFrom-Json })
        Pop-Location
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            try { Remove-Item -LiteralPath $testWork -Recurse -Force; break }
            catch {
                if ($attempt -eq 5) { throw }
                [Threading.Thread]::Sleep(200)
            }
        }
    }
    return [pscustomobject]@{ State = $state; Failure = $failure; Reports = $reports; Log = $failureLog }
}

$result = Invoke-TestCase -DirectFailover -PrivateIngress
Assert-True ($null -eq $result.Failure) "Direct failover failed: $($result.Failure)`n$($result.Log)"
$report = $result.Reports[0]
Assert-True ($report.status -eq 'passed' -and $report.ingressMode -eq 'private') 'Successful private failover must persist a report.'
Assert-True ($report.evidence -eq 'ObservedTransition' -and $report.samples.Count -eq 10) 'The report must include baseline and failover samples and honest transition evidence.'
Assert-True ($report.replicas.original -eq 3 -and $report.replicas.stopped -eq 0 -and $report.replicas.restored -eq 3) 'Report must prove the original, stopped and restored counts.'
Assert-True ($report.stages.recoveryOrigins.status -eq 'passed' -and $report.stages.recoverySmoke.status -eq 'passed') 'Report must prove strict origin and smoke recovery.'
Assert-True ($report.samples[0].observerLatencyMs -ge 0 -and ([DateTimeOffset] $report.completedAtUtc).Offset -eq [TimeSpan]::Zero) 'Report must include observer latency and UTC timestamps.'
Assert-True (($report | ConvertTo-Json -Depth 10) -notmatch 'lab.invalid|pod-1|Injected request failure') 'Report must not retain URLs, bodies or raw exceptions.'

$result = Invoke-TestCase -DirectFailover -ContinuedService
Assert-True ($null -eq $result.Failure -and $result.Reports[0].evidence -eq 'ContinuedService') 'An already-surviving client must not claim an observed transition.'

$result = Invoke-TestCase -DirectFailover -FailRequest
$report = $result.Reports[0]
Assert-True ($null -ne $result.Failure -and $report.status -eq 'failed') 'A failed request must persist a failed report.'
Assert-True ($report.evidence -eq 'NotProven' -and $report.stages.availability.status -eq 'failed') 'Failed availability must never claim a transition.'
Assert-True ($report.samples[-1].error -eq 'unexpected') 'Unexpected failures must be recorded using safe categories.'
Assert-True ($result.State.Replicas.primary -eq 3 -and $report.stages.restoration.status -eq 'passed') 'Request failure must unconditionally restore replicas.'
Assert-True ($report.stages.recoveryOrigins.status -eq 'passed') 'Failure cleanup must still attempt strict fresh origin recovery.'

$result = Invoke-TestCase -DirectFailover -FailRequest -FailRestore
$report = $result.Reports[0]
Assert-True ($null -ne $result.Failure -and $report.status -eq 'failed') 'Failed cleanup must still persist a final failure report.'
Assert-True ($report.stages.restoration.status -eq 'failed' -and $report.stages.replicaVerification.status -eq 'failed') 'Failed cleanup must not claim restored replicas.'
Assert-True ($report.replicas.restored -eq 0 -and $report.stages.recoveryOrigins.status -eq 'notRun') 'Unrestored workloads must not claim strict recovery.'
Assert-True ($result.State.Events.Contains('scale:primary:3')) 'Restoration must be attempted after request failure.'

$result = Invoke-TestCase -DirectFailover -FailRecoveryHealth
Assert-True ($null -ne $result.Failure -and $result.Reports[0].stages.recoveryOrigins.status -eq 'failed') 'Missing fresh origin health must fail the persisted report.'
Assert-True ($result.State.Replicas.primary -eq 3) 'Strict recovery failure must not undo replica restoration.'

$result = Invoke-TestCase -DirectFailover -FailReadiness
Assert-True ($null -ne $result.Failure -and $result.Reports[0].stages.readiness.status -eq 'failed') 'Readiness failure must produce an explicit report before disruption.'
Assert-True (-not $result.State.Events.Contains('scale:primary:0')) 'Readiness failure must not disrupt workloads.'

$result = Invoke-TestCase -DirectFailover -WhatIf
Assert-True ($null -eq $result.Failure -and $result.Reports.Count -eq 0) 'WhatIf must not write evidence or disrupt workloads.'

$result = Invoke-TestCase -TemporaryAccess
Assert-True ($null -eq $result.Failure) "Happy path failed: $($result.Failure)"
Assert-True (@($result.State.Events | Where-Object { $_ -like 'grant:*' }).Count -eq 2) 'Temporary access must be scoped independently to both clusters.'
Assert-True ($result.State.Assignments.Count -eq 0) 'All newly created permissions must be removed.'
Assert-True ($result.State.Replicas.primary -eq 3 -and $result.State.Replicas.secondary -eq 2) 'Original replica counts must be preserved.'
$stops = @($result.State.Events | Where-Object { $_ -like 'scale:*:0' })
Assert-True ($stops.Count -eq 2 -and $stops[0] -eq 'scale:primary:0' -and $stops[1] -eq 'scale:secondary:0') 'Both failover directions must run sequentially.'
$lastDelete = ($result.State.Events | Where-Object { $_ -like 'delete:*' } | Select-Object -Last 1)
Assert-True ($result.State.Events.IndexOf($lastDelete) -lt $result.State.Events.Count - 1) 'The final smoke test must run after temporary access is removed.'

$result = Invoke-TestCase -TemporaryAccess -ExistingAccess
Assert-True ($null -eq $result.Failure) 'Existing administrator access must be usable.'
Assert-True ($result.State.Assignments.ContainsKey('existing')) 'Pre-existing access must never be deleted.'
Assert-True (@($result.State.Events | Where-Object { $_ -like 'grant:*' -or $_ -like 'delete:*' }).Count -eq 0) 'Existing access must not be modified.'

$result = Invoke-TestCase
Assert-True ($null -eq $result.Failure) 'Tests must support pre-authorized users without creating role assignments.'
Assert-True (@($result.State.Events | Where-Object { $_ -like 'grant:*' }).Count -eq 0) 'Role assignment must be opt-in.'

$result = Invoke-TestCase -TemporaryAccess -WhatIf
Assert-True ($null -eq $result.Failure) 'WhatIf must complete without errors.'
Assert-True ($result.State.Events.Count -eq 0) 'WhatIf must not grant roles, call the API, or change replicas.'
Assert-True ($result.State.ReadinessCalls.Count -eq 0) 'WhatIf must not run readiness or startup.'

$result = Invoke-TestCase -TemporaryAccess -FailReadiness
Assert-True ($null -ne $result.Failure) 'Failed workload readiness must abort disruptive testing.'
Assert-True ($result.State.Assignments.Count -eq 0) 'Failed readiness must still remove temporary access.'
Assert-True (@($result.State.Events | Where-Object { $_ -like 'scale:*:0' }).Count -eq 0) 'Workload readiness must precede every disruption.'

$result = Invoke-TestCase -DenyAccess
Assert-True ($null -ne $result.Failure) 'Missing workload access must fail explicitly.'
Assert-True (@($result.State.Events | Where-Object { $_ -like 'scale:*' -or $_ -like 'http:*' }).Count -eq 0) 'Access checks must precede workload disruption.'

$result = Invoke-TestCase -TemporaryAccess -FailRequest
Assert-True ($null -ne $result.Failure) 'A failed failover test must not report success.'
Assert-True ($result.State.Replicas.primary -eq 3 -and $result.State.Replicas.secondary -eq 2) 'A failed request must still restore both original replica counts.'
Assert-True ($result.State.Assignments.Count -eq 0) 'A failed request must still remove temporary access.'
Assert-True (-not $result.State.Events.Contains('scale:secondary:0')) 'The second failure simulation must not run after the first fails.'

$result = Invoke-TestCase -TemporaryAccess -FailRestore
Assert-True ($null -ne $result.Failure) 'Failed restoration must be reported.'
Assert-True ($result.State.Assignments.Count -eq 0) 'Failed restoration must not prevent role cleanup.'
Assert-True ($result.State.Events.Contains('scale:secondary:2')) 'Restoration must still be attempted on the other cluster.'

$result = Invoke-TestCase -TemporaryAccess -FailDelete
Assert-True ($null -ne $result.Failure) 'Failed permission cleanup must be reported.'
Assert-True (@($result.State.Events | Where-Object { $_ -like 'delete:*' }).Count -eq 2) "Cleanup failure on one cluster must not skip the other assignment. Events: $($result.State.Events -join ', '); failure: $($result.Failure)"

$result = Invoke-TestCase -TemporaryAccess -FailSecondGrant
Assert-True ($null -ne $result.Failure) 'Failed role creation must abort tests.'
Assert-True ($result.State.Assignments.Count -eq 0) 'Partially created temporary access must be cleaned up.'
Assert-True (@($result.State.Events | Where-Object { $_ -like 'scale:*' }).Count -eq 0) 'Failed role creation must not disrupt workloads.'

$result = Invoke-TestCase -TemporaryAccess -FailOriginRead
Assert-True ($null -ne $result.Failure) 'Missing metric access must fail explicitly before role grants.'
Assert-True ($result.State.Events.Count -eq 0) 'Metric preflight failure must not grant roles or disrupt workloads.'

$result = Invoke-TestCase -TemporaryAccess -FailRecoveryHealth
Assert-True ($null -ne $result.Failure) 'Unproven regional recovery must fail the workflow.'
Assert-True (-not $result.State.Events.Contains('scale:secondary:0')) 'The next region must not be stopped before both origins recover.'
Assert-True ($result.State.Assignments.Count -eq 0) 'Recovery-health failure must still remove temporary access.'
Assert-True ($result.State.Replicas.primary -eq 3 -and $result.State.Replicas.secondary -eq 2) 'Recovery-health failure must preserve original replicas.'

$result = Invoke-TestCase -RecentOriginBoundary
Assert-True ($null -ne $result.Failure -and $result.Failure.Exception.Message -like '*Regional origin health was not proven*') 'Old metric buckets must not satisfy a recent recovery boundary.'
Assert-True ($result.State.MetricWindowSeconds -ge 60) 'Recent recovery checks must still use an Azure Monitor query window of at least one minute.'

Write-Host "PASS: $checks offline end-to-end checks. Azure, HTTP and delays were simulated."
