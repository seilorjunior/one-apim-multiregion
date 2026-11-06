#requires -Version 7.4
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '..\scripts\powershell\Lab.Common.ps1')
$root = Split-Path $PSScriptRoot -Parent
$checks = 0
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

function Invoke-StartupCase {
    param(
        [hashtable] $Sequences = @{},
        [switch] $CheckOnly,
        [string] $FailOperation = '',
        [string] $ExpectedGroup = 'rg-test',
        [switch] $DeadlineBoundary
    )
    $startupMock = [pscustomobject]@{
        Sequences = $Sequences
        Positions = @{}
        Events = [Collections.Generic.List[string]]::new()
        Clock = [DateTimeOffset] '2026-11-04T12:00:00Z'
        Error = ''
    }
    function Get-Date {
        param([switch] $AsUTC)
        $startupMock.Clock.UtcDateTime
    }
    function Start-Sleep {
        param([int] $Seconds)
        $startupMock.Events.Add("sleep:$Seconds")
        $startupMock.Clock = $startupMock.Clock.AddSeconds($Seconds)
    }
    function Invoke-LabNative {
        param($Program, $Arguments)
        $operation = $Arguments[0..1] -join ' '
        if ($operation -eq $FailOperation) { throw "Simulated $operation failure" }
        $startupMock.Events.Add($operation)
        if ($operation -eq 'resource list') {
            $targets = @(foreach ($name in $startupMock.Sequences.Keys) {
                @{
                    name = $name
                    resourceGroup = 'rg-test'
                    id = "/subscriptions/sub/resourceGroups/rg-test/providers/Microsoft.ContainerService/managedClusters/$name"
                }
            })
            Assert-True ($Arguments -contains 'azd-env-name=lab-test') 'Discovery must be restricted to the environment tag.'
            Assert-True ($Arguments -notcontains '--resource-type' -and
                $Arguments[$Arguments.IndexOf('--query') + 1] -like "*type=='Microsoft.ContainerService/managedClusters'*") 'Tag discovery must filter AKS in the query, not with the incompatible resource-type option.'
            return ConvertTo-Json -InputObject $targets -Compress
        }
        $cluster = $Arguments[$Arguments.IndexOf('--name') + 1]
        Assert-True ($Arguments -contains 'sub' -and $Arguments -contains 'rg-test') 'Every AKS operation must pin subscription and resource group.'
        if ($operation -eq 'aks show') {
            if (-not $startupMock.Positions.ContainsKey($cluster)) { $startupMock.Positions[$cluster] = 0 }
            $position = [Math]::Min($startupMock.Positions[$cluster], $startupMock.Sequences[$cluster].Count - 1)
            $stage = $startupMock.Sequences[$cluster][$position] -split '/'
            $startupMock.Positions[$cluster]++
            if ($DeadlineBoundary) { $startupMock.Clock = $startupMock.Clock.AddSeconds(30) }
            return @{ provisioningState = $stage[0]; powerState = $stage[1] } | ConvertTo-Json -Compress
        }
        if ($operation -eq 'aks start') {
            Assert-True ($Arguments -contains '--no-wait') 'Start requests must not serialize cluster startup.'
            $startupMock.Events.Add("start:$cluster")
            return ''
        }
        throw "Unexpected test operation: $operation"
    }
    try {
        Wait-LabClustersRunning @{
            AZURE_ENV_NAME = 'lab-test'
            AZURE_SUBSCRIPTION_ID = 'sub'
            AZURE_RESOURCE_GROUP = $ExpectedGroup
        } -StartClusters:(-not $CheckOnly) -WaitSeconds 30
    }
    catch {
        $startupMock.Error = $_.Exception.Message
    }
    return $startupMock
}

foreach ($sequences in @(@{}, @{ primary = @('Succeeded/Running'); secondary = @('Succeeded/Running') })) {
    $result = Invoke-StartupCase $sequences
    Assert-True ($result.Error -eq '') "Running/new environment failed: $($result.Error)"
    Assert-True (-not ($result.Events -like 'start:*')) 'Running and absent clusters must never be started.'
}
$result = Invoke-StartupCase @{
    primary = @('Succeeded/Stopped', 'Succeeded/Running')
    secondary = @('Succeeded/Stopped', 'Succeeded/Running')
}
Assert-True ($result.Error -eq '') "Startup failed: $($result.Error)"
Assert-True (@($result.Events -like 'start:*').Count -eq 2) 'Both stopped clusters must start.'
Assert-True ($result.Events.IndexOf('start:primary') -lt $result.Events.IndexOf('sleep:15') -and
    $result.Events.IndexOf('start:secondary') -lt $result.Events.IndexOf('sleep:15')) 'Both start requests must precede the first wait.'

$result = Invoke-StartupCase @{ primary = @('Stopping/Running', 'Succeeded/Stopped', 'Succeeded/Running') }
Assert-True ($result.Error -like '*within 30 seconds*') 'Success at the exact deadline must be rejected.'
Assert-True ($result.Events.IndexOf('start:primary') -gt $result.Events.IndexOf('sleep:15')) 'Stopping must finish before start.'
$result = Invoke-StartupCase @{ primary = @('Starting/Running', 'Succeeded/Running') }
Assert-True ($result.Error -eq '' -and -not ($result.Events -like 'start:*')) 'Existing start operations must be awaited without duplicate requests.'
$result = Invoke-StartupCase @{ primary = @('Succeeded/Stopped') }
Assert-True ($result.Error -like '*within 30 seconds*') 'A stale stopped state must time out.'
Assert-True (@($result.Events -like 'start:*').Count -eq 1) 'A delayed state transition must not submit duplicate starts.'
foreach ($stage in @('Failed/Running', 'Canceled/Running', 'Mystery/Running', 'Succeeded/Unknown')) {
    $result = Invoke-StartupCase @{ primary = @($stage) }
    Assert-True ($result.Error -like '*unsupported state*') "Unexpected state must fail: $stage"
    Assert-True (-not ($result.Events -like 'start:*')) 'Invalid states must not trigger starts.'
}
$result = Invoke-StartupCase @{ primary = @('Succeeded/Stopped') } -CheckOnly
Assert-True ($result.Error -like '*not Running/Succeeded*' -and -not ($result.Events -like 'start:*')) 'Read-only hooks must refuse stopped clusters without starting them.'
foreach ($operation in @('resource list', 'aks show', 'aks start')) {
    $result = Invoke-StartupCase @{ primary = @('Succeeded/Stopped') } -FailOperation $operation
    Assert-True ($result.Error -like "*Simulated $operation failure*") 'CLI failures must propagate.'
}
$result = Invoke-StartupCase @{ primary = @('Succeeded/Stopped') } -ExpectedGroup 'different-group'
Assert-True ($result.Error -like '*scope does not match*' -and -not ($result.Events -like 'start:*')) 'Scope mismatch must fail before startup.'
$result = Invoke-StartupCase @{ one = @('Succeeded/Stopped'); two = @('Succeeded/Stopped'); three = @('Succeeded/Stopped') }
Assert-True ($result.Error -like '*More than two*' -and -not ($result.Events -like 'start:*')) 'Ambiguous discovery must fail before startup.'
$result = Invoke-StartupCase @{ primary = @('Succeeded/Running') } -DeadlineBoundary
Assert-True ($result.Error -like '*within 30 seconds*') 'A slow query cannot pass at the deadline.'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('lab-provision-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
try {
    foreach ($name in @('Provision-Lab.ps1', 'Lab.Common.ps1')) {
        Copy-Item (Join-Path $root "scripts\powershell\$name") (Join-Path $temporary $name)
    }
    [IO.File]::WriteAllText((Join-Path $temporary 'Prepare-Lab.ps1'), @'
param([switch] $StartResources, [int] $WaitSeconds)
$state.StartResources = [bool] $StartResources
$state.Prepared = $true
$state.WaitSeconds = $WaitSeconds
if ($state.FailPrepare) { throw 'Preparation failed.' }
'@)
    [IO.File]::WriteAllText((Join-Path $temporary 'Sync-DomainBootstrap.ps1'), @'
param([switch] $Provision, [int] $WaitSeconds)
if (-not $Provision) { throw 'Bootstrap mutation flag was not supplied.' }
$state.Bootstrap = $true
if ($state.FailBootstrap) { throw 'Bootstrap failed.' }
'@)
    $state = [pscustomobject]@{ Bootstrap = $false; FailBootstrap = $false; Prepared = $false; StartResources = $false; WaitSeconds = 0; FailPrepare = $false; ExitCode = 0; Calls = @() }
    function azd {
        $state.Calls += ,@($args)
        $global:LASTEXITCODE = $state.ExitCode
    }
    & (Join-Path $temporary 'Provision-Lab.ps1') -Preview -StartResources
    Assert-True (-not $state.Prepared -and -not $state.Bootstrap -and ($state.Calls[0] -join ' ') -eq 'provision --preview') 'Preview must never run bootstrap purchases or startup preparation.'
    $state.Calls = @()
    & (Join-Path $temporary 'Provision-Lab.ps1') -WaitSeconds 60
    Assert-True ($state.Bootstrap -and $state.Prepared -and $state.WaitSeconds -eq 60 -and ($state.Calls[0] -join ' ') -eq 'provision') "Provision must bootstrap before startup and forward its timeout: $($state | ConvertTo-Json -Compress)."
    Assert-True (-not $state.StartResources) 'Provisioning must not implicitly start billable resources.'
    & (Join-Path $temporary 'Provision-Lab.ps1') -StartResources -WaitSeconds 60
    Assert-True ($state.StartResources) 'Explicit startup must be forwarded to preparation.'
    $state.Prepared = $false
    $state.FailBootstrap = $true
    $state.Calls = @()
    $failure = ''
    try { & (Join-Path $temporary 'Provision-Lab.ps1') } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*Bootstrap failed*' -and -not $state.Prepared -and $state.Calls.Count -eq 0) 'Bootstrap failure must prevent startup and provisioning.'
    $state.FailBootstrap = $false
    $state.FailPrepare = $true
    $state.Calls = @()
    $failure = ''
    try { & (Join-Path $temporary 'Provision-Lab.ps1') } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*Preparation failed*' -and $state.Calls.Count -eq 0) 'Preparation failure must prevent provisioning.'
    $state.ExitCode = 7
    $failure = ''
    try { & (Join-Path $temporary 'Provision-Lab.ps1') -Preview } catch { $failure = $_.Exception.Message }
    Assert-True ($failure -like '*exit code 7*') 'Provision failures must propagate.'
}
finally {
    foreach ($name in @('Provision-Lab.ps1', 'Lab.Common.ps1', 'Prepare-Lab.ps1', 'Sync-DomainBootstrap.ps1')) {
        $path = Join-Path $temporary $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $temporary
}
Write-Host "PASS: $checks offline cluster startup checks. No Azure operations were executed."
