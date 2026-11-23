#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest

function New-DelegationFixtureImage {
    param([string]$Tag, [string]$Digit)
    [pscustomobject]@{ Tag = $Tag; Manifest = 'sha256:' + ($Digit * 64); Config = 'sha256:' + ($Digit * 64) }
}

function New-DelegationFixtureSnapshot {
    $images = @(
        New-DelegationFixtureImage 'local/kataglyphis:bk-windows-media-core-onnx-nvidia' 'a'
        New-DelegationFixtureImage 'local/kataglyphis:bk-windows-media-core-ffmpeg-nvidia' 'b'
        New-DelegationFixtureImage 'local/kataglyphis:bk-windows-media-nvidia' 'c'
        New-DelegationFixtureImage 'local/kataglyphis:bk-winamd64-nvidia' 'd'
        New-DelegationFixtureImage 'local/kataglyphis:bk-windows-sdk-nvidia' 'e'
        New-DelegationFixtureImage 'example/other:bk-windows-media-core-onnx-nvidia' 'f'
        New-DelegationFixtureImage 'local/kataglyphis:bk-windows-media-core-onnx-arm64' '1'
    )
    $containers = @(
        [pscustomobject]@{ Id = '2' * 64; Image = $images[0].Config; Status = 'exited'; Running = $false; Disposable = $false }
        [pscustomobject]@{ Id = '3' * 64; Image = $images[1].Config; Status = 'exited'; Running = $false; Disposable = $true }
        [pscustomobject]@{ Id = '4' * 64; Image = $images[2].Config; Status = 'exited'; Running = $true; Disposable = $true }
    )
    [pscustomobject]@{ Images = $images; Containers = $containers; CacheMounts = @('cache-one', 'cache-two'); FreeBytes = 50GB; UnusedPrivateRegularBytes = 1GB }
}

function New-DelegationFixtureContainer {
    param([switch]$TaskAbsent)
    $state = if ($TaskAbsent) {
        [pscustomobject]@{ Status = ''; Running = $false; Paused = $false; Restarting = $false; Pid = 0; ExitCode = 0; Error = ''; StartedAt = ''; FinishedAt = '' }
    } else { [pscustomobject]@{ Running = $false; Status = 'exited' } }
    [pscustomobject]@{
        Id = 'a' * 64; Image = 'sha256:' + ('b' * 64)
        State = $state
        Config = [pscustomobject]@{ Labels = [pscustomobject]@{ 'org.kataglyphis.antfrastructure.disposable' = 'true' } }
    }
}

function New-DelegationFixtureImageListing {
    param([string]$Name = 'example/store:current', [string]$Digest = ('sha256:' + ('a' * 64)), [switch]$Untagged)
    [pscustomobject]@{ Name = $(if ($Untagged) { '<none>' } else { $Name }); ID = $Digest;
        Repository = $(if ($Untagged) { '<none>' } else { 'example/store' }); Tag = $(if ($Untagged) { '<none>' } else { 'current' }) }
}

function Assert-DelegationPendingCompletion {
    param($State, [string]$Find = '', [string]$Replace = '')
    Invoke-DelegationModuleFixture -Kind Completion -State $State -Find $Find -Replace $Replace -Body {
        param($State)
        Assert-Equal $null (Read-MutDelegatedMaintenanceCompletion $State.Task fixture $State.Started $State.Instance) 'uncompleted receipts must remain pending'
    }
}

Export-ModuleMember -Function New-DelegationFixtureImageListing, Assert-DelegationPendingCompletion

function Assert-DelegationPropertyRefusals {
    param($Prototype, [hashtable[]]$Fault, [scriptblock]$Body, [string]$MessagePattern)
    foreach ($change in $Fault) {
        $changed = $Prototype.PSObject.Copy()
        foreach ($key in $change.Keys) { $changed.$key = $change[$key] }
        Assert-Throws { & $Body $changed } -MessagePattern $MessagePattern
    }
}

function Get-DelegationFixtureIdentityCases {
    param($Valid, $Foreign)
    @([pscustomobject]@{ Entries = @() }, [pscustomobject]@{ Entries = @($Valid, $Valid) }, [pscustomobject]@{ Entries = @($Foreign) })
}

Export-ModuleMember -Function Assert-DelegationPropertyRefusals, Get-DelegationFixtureIdentityCases

function New-DelegationFixtureCollection {
    $collection = [pscustomobject]@{ Entries = [Collections.Generic.List[object]]::new() }
    $collection | Add-Member -MemberType ScriptProperty -Name Count -Value { $this.Entries.Count }
    $collection | Add-Member -MemberType ScriptMethod -Name Item -Value { param($Index) $this.Entries[$Index - 1] }
    $collection | Add-Member -MemberType ScriptMethod -Name Create -Value {
        param($Type)
        if ($Type -ne 0) { throw 'Only a fixed execution action is expected.' }
        $action = [pscustomobject]@{ Path = ''; Arguments = ''; WorkingDirectory = '' }
        $this.Entries.Add($action)
        return $action
    }
    return $collection
}

function New-DelegationFixtureService {
    $definition = [pscustomobject]@{
        Principal = [pscustomobject]@{ UserId = ''; LogonType = 0; RunLevel = 0 }
        Settings = [pscustomobject]@{ Enabled = $true; Hidden = $false; MultipleInstances = 0; ExecutionTimeLimit = ''; AllowHardTerminate = $true; DisallowStartIfOnBatteries = $true; StopIfGoingOnBatteries = $true }
        Actions = New-DelegationFixtureCollection
        Triggers = New-DelegationFixtureCollection
    }
    $service = [pscustomobject]@{ Definition = $definition; RunningTasks = @() }
    $service | Add-Member -MemberType ScriptMethod -Name NewTask -Value { param($Flags) $this.Definition }
    $service | Add-Member -MemberType ScriptMethod -Name GetRunningTasks -Value {
        param($Flags)
        @($this.RunningTasks | Where-Object { $Flags -eq 1 -or -not $_.Hidden })
    }
    return $service
}

function New-DelegationFixtureTask {
    param($Definition, [string]$Sddl)
    $task = [pscustomobject]@{ Definition = $Definition; Sddl = $Sddl }
    $task | Add-Member -MemberType ScriptMethod -Name GetSecurityDescriptor -Value { param($Flags) $this.Sddl }
    return $task
}


function Get-DelegationFixtureFunctions {
    param([ValidateSet('Policy', 'Containers', 'Flow', 'Manifest', 'Task', 'Inventory')][string]$Kind)
    $entries = switch ($Kind) {
        Inventory { @('modules/WindowsStevedoreDelegation.Inventory.psm1', @('Assert-DelegatedStoreIdle', 'ConvertTo-DelegatedImageTags', 'ConvertTo-DelegatedImageInventory')) }
        Policy { @('modules/WindowsStevedoreDelegation.Policy.psm1', @('Get-DelegatedRetirementPlan', 'Assert-DelegatedPreservation')) }
        Containers { @('modules/WindowsHostMaintenance.Common.psm1', @('Assert-HostIdentityPairs', 'Get-HostDisposableContainerLabel', 'Assert-HostTaskAbsentState', 'Get-HostContainerStatus', 'ConvertTo-HostContainerRecord')); @('host/Clear-DiskSpace.ps1', @('Get-StevedoreTargets', 'Get-StevedoreInspection', 'Assert-StevedoreContainerTarget', 'Invoke-StevedoreRemoval')) }
        Flow { @('tests/Stevedore.Delegation.Flow.Tests.ps1', @('New-DelegationFlowState', 'Invoke-DelegationCacheDrift', 'Assert-DelegationFlowApply', 'Invoke-DelegationFlowResult')); @('modules/WindowsStevedoreDelegation.Policy.psm1', @('Get-DelegatedRetirementPlan')) }
        Manifest { @('tests/Stevedore.Delegation.Manifest.Tests.ps1', @('New-DelegationManifestState', 'Get-DelegationManifestCases', 'Assert-DelegationManifestRefusal')); @('modules/WindowsStevedoreDelegation.Security.psm1', @('Get-DelegatedMaintenancePayload')) }
        Task { @('modules/WindowsStevedoreDelegation.Security.psm1', @('Get-DelegatedMaintenanceSddl')); @('modules/WindowsStevedoreDelegation.Task.psm1', @('New-DelegatedMaintenanceTask', 'Assert-DelegatedMaintenanceTaskDefinition', 'Assert-DelegatedMaintenanceTask')) }
    }
    $parts = for ($i = 0; $i -lt $entries.Count; $i += 2) {
        Get-ScriptFunctionDefinition -ScriptPath ('windows/scripts/' + $entries[$i]) -FunctionName $entries[$i + 1]
    }
    return [scriptblock]::Create(($parts -join "`n"))
}

function New-DelegationFixtureRetainedSnapshot {
    param($Plan)
    [pscustomobject]@{ Images = @($Plan.PreservedImages); Containers = @($Plan.PreservedContainers); CacheMounts = @($Plan.CacheMounts); FreeBytes = 110GB }
}

function Assert-DelegationFixtureSelection {
    param($Plan, $Snapshot)
    Assert-Equal 1 $Plan.Images.Count 'only the unreferenced branch with a merge may retire'
    Assert-Equal $Snapshot.Images[1].Tag $Plan.Images[0].Tag
    Assert-Equal 1 $Plan.Containers.Count 'only marked stopped containers may retire'
    Assert-Equal ('3' * 64) $Plan.Containers[0].Id
    Assert-Equal 6 $Plan.PreservedImages.Count
    Assert-Equal 2 $Plan.PreservedContainers.Count
    Assert-Equal 'cache-one|cache-two' ($Plan.CacheMounts -join '|')
}

function New-DelegationFixtureMutation {
    param([string]$Find, [string]$Replace, [string]$Expected)
    return @{ Find = $Find; Replace = $Replace; Expected = $Expected }
}

function New-DelegationFixtureResult {
    param($State)
    return @{ before = $State.Before; plan = $State.Plan; after = $null; preservation_verified = $false; target_met = $false; state = 'failed'; raw_exit = 1 }
}

function New-DelegationCompletionState {
    param([ValidateSet('none', 'missing', 'active', 'stale', 'foreign', 'scheduler-running')][string]$Fault = 'none')
    $task = [pscustomobject]@{ ActiveInstances = 0; LastTaskResult = 0; State = 3 }
    $task | Add-Member -MemberType ScriptMethod -Name GetInstances -Value { param($Flags) [pscustomobject]@{ Count = $this.ActiveInstances } }
    $state = [pscustomobject]@{ Task = $task; Exists = $true; ProbeMode = ''; Started = [datetimeoffset]::Parse('2026-11-20T00:00:00Z').UtcDateTime; Instance = 'instance-one';
        Result = [pscustomobject]@{ started_utc = '2026-11-20T00:00:01Z'; task_instance = 'instance-one'; raw_exit = 0 } }
    switch ($Fault) {
        missing { $state.Exists = $false }
        active { $state.Task.ActiveInstances = 1 }
        stale { $state.Result.started_utc = '2026-11-19T00:00:00Z' }
        foreign { $state.Result.task_instance = 'another-instance' }
        scheduler-running { $state.Task.LastTaskResult = 267009 }
    }
    return $state
}

function Get-DelegationModuleArguments {
    param([ValidateSet('Flow', 'Manifest', 'Completion', 'ImageInventory')][string]$Kind, $State)
    switch ($Kind) {
        Flow {
            $module = 'WindowsStevedoreDelegation.Task.psm1'
            $names = @('Complete-DelegatedMaintenanceRun')
            $prelude = @'
Import-Module $State.Policy -ErrorAction Stop
function Invoke-DelegatedCanonicalReclaim { param($Root,$Plan,[switch]$Apply) $State.Calls.Add($(if($Apply){'apply'}else{'preview'})) }
function Assert-DelegatedMaintenanceOverlap { $State.Calls.Add('idle') }
function Get-DelegatedStoreSnapshot { param($Manifest,$LogRoot,$Name) if($Name -ceq 'pre-apply'){return $State.Fresh};return $State.After }
'@
        }
        Manifest {
            $module = 'WindowsStevedoreDelegation.Security.psm1'
            $names = @('Read-DelegatedMaintenanceManifest', 'Assert-DelegatedMaintenancePolicy', 'Get-DelegatedMaintenancePayload', 'Get-DelegatedMaintenanceSddl')
            $prelude = @'
function Get-DelegatedMaintenanceLayout { [pscustomobject]@{Root=$State.Root;Tools=$State.ToolsRoot} }
function Assert-DelegatedMaintenancePath { param($Path,[switch]$Trusted) }
function Get-Content { param($LiteralPath,[switch]$Raw) $State.Manifest | ConvertTo-Json -Depth 12 }
function Get-FileHash { param($LiteralPath,$Algorithm) [pscustomobject]@{Hash=('a'*64)} }
'@
        }
        Completion {
            $module = 'WindowsStevedoreDelegation.Task.psm1'
            $names = @('Read-DelegatedMaintenanceCompletion')
            $prelude = @'
function Test-Path { param($LiteralPath) $State.Exists }
function Get-Content { param($LiteralPath,[switch]$Raw) $State.Result | ConvertTo-Json }
'@
        }
        ImageInventory {
            $module = 'WindowsStevedoreDelegation.Inventory.psm1'
            $names = @('Get-DelegatedContainerdInventory', 'ConvertTo-DelegatedImageTags', 'ConvertTo-DelegatedImageInventory', 'Get-DelegatedImageIdentities')
            $prelude = @'
function Invoke-DelegatedContainerdCommand {
    param($Manifest,$Arguments,$LogRoot,$Name)
    if ($Arguments -contains '--format') {
        foreach ($ref in $State.Names) { New-DelegationFixtureImageListing $ref $State.Manifest | ConvertTo-Json -Compress }
    } else {
        'example/store current ' + $State.Manifest + ' 1 GB'
        'local/kataglyphis arm64-acceptance-fixture ' + $State.Manifest + ' 1 GB'
    }
}
function Read-DelegatedContainerdJson {
    param($Manifest,$Arguments,$LogRoot,$Name)
    if (($Arguments -join '|') -cne ('image|inspect|' + $State.Manifest)) { throw 'no such image: reconstructed display tag' }
    return $State.Details
}
'@
        }
    }
    return @{ ScriptPath = 'windows/scripts/modules/' + $module; FunctionName = $names; FixtureState = $State; Prelude = $prelude }
}

function Invoke-DelegationModuleFixture {
    param([ValidateSet('Flow', 'Manifest', 'Completion', 'ImageInventory')][string]$Kind, $State, [scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $options = Get-DelegationModuleArguments -Kind $Kind -State $State
    Invoke-WithFunctionModule @options -Body $Body -Find $Find -Replace $Replace
}

Export-ModuleMember -Function Get-DelegationModuleArguments

function Assert-DelegationFixtureRemovalCommand {
    $ast = Get-TestScriptAst -ScriptPath (Join-Path (Get-RepoRoot) 'windows/scripts/host/Clear-DiskSpace.ps1')
    $function = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-StevedoreRemoval' }, $true))[0]
    $bodyAst = ConvertTo-TestScriptAst -Text $function.Body.Extent.Text -ErrorLabel 'selected removal body'
    $calls = @($bodyAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.Extent.Text -match '\$Store.Tool' }, $true))
    Assert-Equal 1 $calls.Count
    Assert-TestAstCommand -Command $calls -Text '& $Store.Tool --address $Store.Address --namespace $Store.Namespace $command $Tag' -Unconditional
    Assert-Match ([regex]::Escape("$" + "command = if (`$Container) { 'rm' } else { 'rmi' }")) $function.Body.Extent.Text
}

Export-ModuleMember -Function New-DelegationCompletionState, Invoke-DelegationModuleFixture, Assert-DelegationFixtureRemovalCommand, Get-DelegationFixtureFunctions, New-DelegationFixtureRetainedSnapshot, Assert-DelegationFixtureSelection, New-DelegationFixtureMutation, New-DelegationFixtureResult, New-DelegationFixtureImage, New-DelegationFixtureSnapshot, New-DelegationFixtureContainer, New-DelegationFixtureService, New-DelegationFixtureTask
