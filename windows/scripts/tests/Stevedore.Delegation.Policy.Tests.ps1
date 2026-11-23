#requires -Version 7.0
# NOT covered: actual daemons, task registration, ACL enforcement, physical reclamation or concurrent engine mutations.

Describe 'Delegated Stevedore retention' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Policy)
    }

    It 'selects only completed branch tags and marked stopped containers' {
        $snapshot = New-DelegationFixtureSnapshot
        $plan = Get-DelegatedRetirementPlan $snapshot
        Assert-DelegationFixtureSelection $plan $snapshot
    }

    It 'handles a fresh empty store and normalized registry spelling' {
        $empty = [pscustomobject]@{ Images = @(); Containers = @(); CacheMounts = @(); FreeBytes = 100GB }
        $plan = Get-DelegatedRetirementPlan $empty
        Assert-Equal 0 $plan.Images.Count
        Assert-Equal 0 $plan.Containers.Count
        $snapshot = New-DelegationFixtureSnapshot
        $snapshot.Images[2].Tag = 'docker.io/' + $snapshot.Images[2].Tag
        Assert-Equal 1 (Get-DelegatedRetirementPlan $snapshot).Images.Count
    }

    It 'detects unrelated image container and compiler cache drift' {
        $snapshot = New-DelegationFixtureSnapshot
        $plan = Get-DelegatedRetirementPlan $snapshot
        $after = New-DelegationFixtureRetainedSnapshot $plan
        Assert-DelegatedPreservation $plan $after
        $cases = @(
            @{ Find = 'if (($before -join "`n") -cne ($after -join "`n"))'; Replace = 'if ($false)'; Expected = 'expected an exception' ; Field = 'image' }
            @{ Find = 'if (($beforeContainers -join "`n") -cne ($afterContainers -join "`n"))'; Replace = 'if ($false)'; Expected = 'expected an exception'; Field = 'container' }
            @{ Find = 'if ((@($Plan.CacheMounts | Sort-Object) -join "`n") -cne (@($Snapshot.CacheMounts | Sort-Object) -join "`n"))'; Replace = 'if ($false)'; Expected = 'expected an exception'; Field = 'cache' }
        )
        foreach ($case in $cases) {
            $exercise = {
                param($field)
                $source = New-DelegationFixtureSnapshot
                $keep = Get-DelegatedRetirementPlan $source
                $changed = New-DelegationFixtureRetainedSnapshot $keep
                if ($field -eq 'image') { $changed.Images = @($changed.Images | Select-Object -Skip 1) }
                if ($field -eq 'container') { $changed.Containers = @() }
                if ($field -eq 'cache') { $changed.CacheMounts = @('cache-one') }
                Assert-Throws { Assert-MutDelegatedPreservation $keep $changed } -MessagePattern 'differ'
            }
            Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsStevedoreDelegation.Policy.psm1' -FunctionName 'Assert-DelegatedPreservation' `
                -BodyArgumentList @($case.Field) -IncludeControl -Find $case.Find -Replace $case.Replace -Expected $case.Expected -Body $exercise
        }
    }
}
