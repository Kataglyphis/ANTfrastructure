#requires -Version 7.0
# NOT covered: live SYSTEM registration, UAC, daemon access, installed file ACLs or real non-admin execution.

Describe 'Bounded delegated maintenance tasks' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Task)
        $script:readerSid = 'S-1-5-21-1-2-3-1001'
        $script:installedRoot = 'C:\Program Files\fixture-maintenance'
    }

    It 'constructs one protected fixed action without triggers or stop-existing behavior' {
        $service = New-DelegationFixtureService
        $definition = New-DelegatedMaintenanceTask $service $script:installedRoot
        Assert-Equal 'SYSTEM' $definition.Principal.UserId
        Assert-Equal 5 $definition.Principal.LogonType
        Assert-Equal 1 $definition.Principal.RunLevel
        Assert-Equal 2 $definition.Settings.MultipleInstances
        Assert-Equal 0 $definition.Triggers.Count
        Assert-Equal 1 $definition.Actions.Count
        Assert-Equal (Join-Path $script:installedRoot 'runtime\pwsh.exe') $definition.Actions.Item(1).Path
        Assert-Equal ('-NoLogo -NoProfile -NonInteractive -File "' + (Join-Path $script:installedRoot 'Invoke-StevedoreMaintenanceWorker.ps1') + '"') $definition.Actions.Item(1).Arguments
        Assert-False $definition.Settings.Enabled
    }

    It 'gives the specific user read/execute and refuses group-like or malformed SIDs' {
        $sddl = Get-DelegatedMaintenanceSddl $script:readerSid -Task
        Assert-Match '\(A;;GRGX;;;S-1-5-21-1-2-3-1001\)' $sddl
        foreach ($invalid in @('S-1-1-0', 'S-1-5-32-545', 'SYSTEM', 'S-1-5-21-1-2-3-1001)(A;;GA;;;WD)')) {
            Assert-Throws { Get-DelegatedMaintenanceSddl $invalid -Task } -MessagePattern 'specific'
        }
        $definition = New-DelegatedMaintenanceTask (New-DelegationFixtureService) $script:installedRoot
        $task = New-DelegationFixtureTask $definition $sddl
        Assert-DelegatedMaintenanceTask $task $definition $script:readerSid
        $task.Sddl = $sddl.Replace('GRGX', 'GA')
        Assert-Throws { Assert-DelegatedMaintenanceTask $task $definition $script:readerSid } -MessagePattern 'delegation'
    }

    It 'refuses a changed principal command or extra trigger' {
        foreach ($fault in @('principal', 'command', 'trigger', 'termination', 'timeout', 'battery')) {
            $expected = New-DelegatedMaintenanceTask (New-DelegationFixtureService) $script:installedRoot
            $actual = New-DelegatedMaintenanceTask (New-DelegationFixtureService) $script:installedRoot
            switch ($fault) {
                principal { $actual.Principal.UserId = 'user' }
                command { $actual.Actions.Item(1).Arguments += ' -ArbitraryInput' }
                trigger { $actual.Triggers.Entries.Add([pscustomobject]@{}) }
                termination { $actual.Settings.AllowHardTerminate = $true }
                timeout { $actual.Settings.ExecutionTimeLimit = 'PT1H' }
                battery { $actual.Settings.StopIfGoingOnBatteries = $true }
            }
            $task = New-DelegationFixtureTask $actual (Get-DelegatedMaintenanceSddl $script:readerSid -Task)
            Assert-Throws { Assert-DelegatedMaintenanceTask $task $expected $script:readerSid } -MessagePattern 'differs'
        }
    }

    It 'mutation-tests the fixed principal action and concurrency policy' {
        $cases = @(
            New-DelegationFixtureMutation '$definition.Principal.UserId = ''SYSTEM''' '$definition.Principal.UserId = ''Users''' 'fixed SYSTEM'
            New-DelegationFixtureMutation '$definition.Settings.MultipleInstances = 2' '$definition.Settings.MultipleInstances = 3' 'never stop'
            New-DelegationFixtureMutation '$action.Arguments = ''-NoLogo -NoProfile -NonInteractive -File ' '$action.Arguments = ''-NoLogo -NonInteractive -File ' 'NoProfile'
        )
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsStevedoreDelegation.Task.psm1' -FunctionName 'New-DelegatedMaintenanceTask' -IncludeControl -Case $cases -Body {
            $definition = New-MutDelegatedMaintenanceTask (New-DelegationFixtureService) $script:installedRoot
            Assert-Equal 'SYSTEM' $definition.Principal.UserId 'fixed SYSTEM principal'
            Assert-Equal 2 $definition.Settings.MultipleInstances 'never stop an existing instance'
            Assert-Match '-NoLogo -NoProfile -NonInteractive' $definition.Actions.Item(1).Arguments 'NoProfile must remain fixed'
        }
    }

    It 'accepts only a fresh completed receipt from the submitted instance' {
        Invoke-DelegationModuleFixture -Kind Completion -State (New-DelegationCompletionState) -Body {
            param($State)
            $result = Read-MutDelegatedMaintenanceCompletion $State.Task fixture $State.Started $State.Instance
            Assert-Equal 0 $result.raw_exit
        }
        foreach ($fault in @('missing', 'active', 'stale', 'foreign', 'scheduler-running')) {
            $state = New-DelegationCompletionState -Fault $fault
            Assert-DelegationPendingCompletion $state
        }
    }

    It 'retains a completed worker failure without converting it to success' {
        $state = New-DelegationCompletionState
        $state.Task.LastTaskResult = 1
        $state.Result.raw_exit = 1
        Invoke-DelegationModuleFixture -Kind Completion -State $state -Body {
            param($State)
            Assert-Equal 1 (Read-MutDelegatedMaintenanceCompletion $State.Task fixture $State.Started $State.Instance).raw_exit
        }
    }

    It 'mutation-tests foreign receipts and scheduler disagreement with healthy controls' {
        $recipes = @(
            @{ Mode = 'raw'; Find = 'if ($task.LastTaskResult -ne $result.raw_exit)'; Replace = 'if ($false)'; Expected = 'expected an exception' }
            @{ Mode = 'foreign'; Find = 'if (([datetimeoffset]$result.started_utc).UtcDateTime -ge $started -and $result.task_instance -ieq $InstanceGuid)'; Replace = 'if ($true)'; Expected = 'foreign receipt must remain pending' }
        )
        foreach ($recipe in $recipes) {
            $state = New-DelegationCompletionState
            $state.ProbeMode = $recipe.Mode
            if ($recipe.Mode -ceq 'raw') { $state.Task.LastTaskResult = 1 } else { $state.Result.task_instance = 'another-instance' }
            $exercise = { param($State)
                if ($State.ProbeMode -ceq 'raw') {
                    Assert-Throws { Read-MutDelegatedMaintenanceCompletion $State.Task fixture $State.Started $State.Instance } -MessagePattern 'raw results differ'
                } else {
                    Assert-Equal $null (Read-MutDelegatedMaintenanceCompletion $State.Task fixture $State.Started $State.Instance) 'foreign receipt must remain pending'
                }
            }
            Invoke-DelegationModuleFixture -Kind Completion -State $state -Body $exercise
            Assert-Throws {
                Invoke-DelegationModuleFixture -Kind Completion -State $state -Body $exercise -Find $recipe.Find -Replace $recipe.Replace
            } -MessagePattern $recipe.Expected
        }
    }
}
