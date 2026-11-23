#requires -Version 7.0
# NOT covered: live native commands, privileged scheduler state, filesystem ACLs or real free bytes.

function New-DelegationFlowState {
    $before = New-DelegationFixtureSnapshot
    $plan = Get-DelegatedRetirementPlan $before
    $after = New-DelegationFixtureRetainedSnapshot $plan
    [pscustomobject]@{ Before = $before; Fresh = $before; After = $after; Plan = $plan;
        Calls = [Collections.Generic.List[string]]::new(); Policy = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsStevedoreDelegation.Policy.psm1' }
}

function Invoke-DelegationCacheDrift {
    param([string]$Stage, [string]$Find = '', [string]$Replace = '')
    $state = New-DelegationFlowState
    $original = $state.$Stage
    $state.$Stage = [pscustomobject]@{ Images = $original.Images; Containers = $original.Containers; CacheMounts = @(); FreeBytes = 110GB }
    Invoke-DelegationModuleFixture -Kind Flow -State $state -Find $Find -Replace $Replace -Body {
        param($State)
        $result = New-DelegationFixtureResult $State
        Assert-Throws { Complete-MutDelegatedMaintenanceRun -Root fixture -Manifest @{} -Result $result -LogRoot fixture } -MessagePattern 'cache identities differ'
        Assert-Equal 1 $result.raw_exit
    }
}

function Invoke-DelegationFlowResult {
    param($State)
    $result = New-DelegationFixtureResult $State
    Complete-MutDelegatedMaintenanceRun -Root fixture -Manifest @{} -Result $result -LogRoot fixture
    Assert-Equal 0 $result.raw_exit
    return $result
}

function Assert-DelegationFlowApply {
    param($State)
    $result = Invoke-DelegationFlowResult $State
    Assert-Equal 'preview|idle|apply' ($State.Calls -join '|') 'apply must stay selected'
    Assert-Equal 0 $result.raw_exit
    Assert-True $result.preservation_verified
    Assert-True $result.target_met
}

Describe 'Delegated maintenance execution flow' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Flow)
    }

    It 'previews rechecks applies and verifies before reporting capacity' {
        Invoke-DelegationModuleFixture -Kind Flow -State (New-DelegationFlowState) -Body {
            param($State)
            Assert-DelegationFlowApply $State
        }
    }

    It 'does not repeat exhausted pruning and does not promise the free-space target' {
        $state = New-DelegationFlowState
        $state.Before.Images = @(); $state.Before.Containers = @(); $state.Before.UnusedPrivateRegularBytes = 0
        $state.Fresh = $state.Before; $state.After = $state.Before; $state.Plan = Get-DelegatedRetirementPlan $state.Before
        Invoke-DelegationModuleFixture -Kind Flow -State $state -Body {
            param($State)
            $result = Invoke-DelegationFlowResult $State
            Assert-Equal 0 $State.Calls.Count 'exhausted storage must not be pruned again'
            Assert-False $result.target_met
            Assert-Equal 0 $result.raw_exit
            Assert-Match 'No eligible' $result.plan.reason
        }
    }

    It 'refuses changed cache identities before apply and after a partial operation' {
        foreach ($stage in @('Fresh', 'After')) {
            Invoke-DelegationCacheDrift $stage
        }
    }

    It 'mutation-tests that apply and both preservation boundaries stay wired' {
        $state = New-DelegationFlowState
        $exercise = {
            param($State)
            Assert-DelegationFlowApply $State
        }
        Assert-Throws {
            Invoke-DelegationModuleFixture -Kind Flow -State $state -Body $exercise -Find 'Invoke-DelegatedCanonicalReclaim -Root $Root -Plan $Result.plan -Apply' -Replace 'Invoke-DelegatedCanonicalReclaim -Root $Root -Plan $Result.plan'
        } -MessagePattern 'apply must stay selected'
        foreach ($stage in @('Fresh', 'After')) {
            $anchor = if ($stage -ceq 'Fresh') { 'Assert-DelegatedPreservation -Plan $unchanged -Snapshot $fresh' } else { 'Assert-DelegatedPreservation -Plan $Result.plan -Snapshot $Result.after' }
            Assert-Throws { Invoke-DelegationCacheDrift $stage -Find $anchor -Replace '0' } -MessagePattern 'expected an exception'
        }
    }
}
