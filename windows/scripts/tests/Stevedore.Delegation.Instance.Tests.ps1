#requires -Version 7.0
# NOT covered: real SYSTEM execution, scheduler visibility, UAC, installed ACLs or reclaimed bytes.

Describe 'Portable hidden maintenance instance controls' {
    Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop

    It 'discovers exactly one hidden original task and refuses foreign or ambiguous instances' {
        $service = New-DelegationFixtureService
        $path = '\ANTfrastructureMaintenanceV2\InspectBuildStorage'
        $id = '{11111111-2222-3333-4444-555555555555}'
        $entry = [pscustomobject]@{ Path = $path; InstanceGuid = $id; Hidden = $true }
        $service.RunningTasks = @($entry)
        $state = [pscustomobject]@{ Service = $service; Path = $path; Identity = $id }
        $exercise = {
            param($State)
            $value = try { Get-MutDelegatedMaintenanceCurrentInstance $State.Service $State.Path } catch { 'refused: ' + $_.Exception.Message }
            Assert-Equal $State.Identity $value 'hidden task must be resolved'
        }
        $invoke = @{ ScriptPath = 'windows/scripts/modules/WindowsStevedoreDelegation.Task.psm1'; FunctionName = 'Get-DelegatedMaintenanceCurrentInstance'; FixtureState = $state; Body = $exercise }
        Invoke-WithFunctionModule @invoke
        Assert-Throws { Invoke-WithFunctionModule @invoke -Find 'GetRunningTasks(1)' -Replace 'GetRunningTasks(0)' } -MessagePattern 'hidden task must be resolved'
        foreach ($case in (Get-DelegationFixtureIdentityCases $entry ([pscustomobject]@{ Path = '\other\InspectBuildStorage'; InstanceGuid = $id; Hidden = $true }))) {
            $service.RunningTasks = $case.Entries
            Invoke-WithFunctionModule @invoke -Body {
                param($State)
                Assert-Throws { Get-MutDelegatedMaintenanceCurrentInstance $State.Service $State.Path } -MessagePattern 'original scheduled-task instance'
            }
        }
        $refusal = @{} + $invoke
        $refusal.Body = {
            param($State)
            Assert-Throws { Get-MutDelegatedMaintenanceCurrentInstance $State.Service $State.Path } -MessagePattern 'instance.*unknown'
        }
        foreach ($recipe in @(
            @{ Entries = @($entry, $entry); Find = '$instances.Count -ne 1'; Replace = '$false' }
            @{ Entries = @([pscustomobject]@{ Path = '\other\InspectBuildStorage'; InstanceGuid = $id; Hidden = $true }); Find = ' | Where-Object Path -CEQ $TaskPath'; Replace = '' }
        )) {
            $service.RunningTasks = $recipe.Entries
            Invoke-WithFunctionModule @refusal
            Assert-Throws { Invoke-WithFunctionModule @refusal -Find $recipe.Find -Replace $recipe.Replace } -MessagePattern 'expected an exception'
        }
        foreach ($invalid in @('not-a-guid', [guid]::Empty.ToString('B'))) {
            $service.RunningTasks = @([pscustomobject]@{ Path = $path; InstanceGuid = $invalid; Hidden = $true })
            Invoke-WithFunctionModule @refusal
        }
    }

    It 'refuses queued running and unknown tasks even when instance enumeration is filtered' {
        $exercise = {
            $task = (New-DelegationCompletionState).Task
            foreach ($schedulerState in @(0, 1, 2, 3, 4)) {
                $task.State = $schedulerState
                Assert-Equal ($schedulerState -notin @(1, 3)) (Test-MutDelegatedMaintenanceTaskActive $task) 'filtered scheduler state must remain authoritative'
            }
            $task.State = 3; $task.ActiveInstances = 1
            Assert-True (Test-MutDelegatedMaintenanceTaskActive $task)
        }
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsStevedoreDelegation.Security.psm1' -FunctionName 'Test-DelegatedMaintenanceTaskActive' `
            -Find '$Task.State -notin @(1, 3) -or ' -Replace '' -IncludeControl -Expected 'filtered scheduler state' -Body $exercise
    }

    It 'shares the active-task check at overlap and both revocation boundaries' {
        foreach ($entry in @(
            @{ Path = 'modules/WindowsStevedoreDelegation.Task.psm1'; Count = 1 }
            @{ Path = 'host/Remove-StevedoreMaintenance.ps1'; Count = 2 }
        )) {
            $ast = Get-TestScriptAst -ScriptPath (Join-Path (Get-RepoRoot) ('windows/scripts/' + $entry.Path))
            $calls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Test-DelegatedMaintenanceTaskActive' }, $true))
            Assert-Equal $entry.Count $calls.Count 'all refusal boundaries must retain the shared check'
            foreach ($call in $calls) { Assert-TestAstCommand -Command $call -Text 'Test-DelegatedMaintenanceTaskActive $task' }
        }
    }

    It 'keeps queued or hidden running tasks pending when instance enumeration is filtered' {
        foreach ($schedulerState in @(2, 4)) {
            $state = New-DelegationCompletionState
            $state.Task.State = $schedulerState
            Assert-DelegationPendingCompletion $state
        }
    }

    It 'mutation-tests that a filtered running instance cannot look completed' {
        $state = New-DelegationCompletionState
        $state.Task.State = 4
        Assert-DelegationPendingCompletion $state
        Assert-Throws {
            Assert-DelegationPendingCompletion $state -Find '$task.State -eq 3 -and ' -Replace ''
        } -MessagePattern 'uncompleted receipts must remain pending'
    }
}
