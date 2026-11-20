#requires -Version 7.0
# NOT covered: live daemons, SYSTEM tasks, ACL enforcement, concurrent changes or physical storage reclamation.
Set-StrictMode -Version Latest

Describe 'Portable delegated maintenance controls' {
    It 'holds an exclusive file lock and rejects a sharing mutation' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsHostMaintenance.Common.psm1' -FunctionName 'Open-ExclusiveFile' `
            -Find '[IO.FileShare]::None' -Replace '[IO.FileShare]::ReadWrite' -IncludeControl -Expected 'expected an exception' -Body {
                Invoke-InTestDir {
                    param($dir)
                    $path = Join-Path $dir 'maintenance.lock'
                    $lock = Open-MutExclusiveFile -LiteralPath $path -Mode OpenOrCreate
                    try { Assert-Throws { $probe = Open-MutExclusiveFile -LiteralPath $path -Mode Open; $probe.Dispose() } }
                    finally { $lock.Dispose() }
                }
            }
    }

    It 'accepts empty image and container inventories under strict mode' {
        $prelude = 'function Invoke-DelegatedContainerdCommand { param($Manifest,$Arguments,$LogRoot,$Name) return @() }'
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsStevedoreDelegation.Inventory.psm1' `
            -FunctionName 'Get-DelegatedContainerdInventory', 'ConvertTo-DelegatedImageTags' -Prelude $prelude -Body {
                Set-StrictMode -Version Latest
                foreach ($kind in @('image', 'container')) {
                    Assert-Equal 0 @(Get-MutDelegatedContainerdInventory @{} fixture empty -Kind $kind).Count
                }
            }
    }

    It 'keeps final images retained container references and compiler caches' {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Policy)
        $snapshot = New-DelegationFixtureSnapshot
        $plan = Get-DelegatedRetirementPlan $snapshot
        Assert-DelegationFixtureSelection $plan $snapshot
        $after = New-DelegationFixtureRetainedSnapshot $plan
        Assert-DelegatedPreservation $plan $after
        $after.CacheMounts = @('missing')
        Assert-Throws { Assert-DelegatedPreservation $plan $after } -MessagePattern 'Compiler cache'
        $snapshot.Containers[0].Image = $snapshot.Images[0].Manifest
        Assert-Equal 1 (Get-DelegatedRetirementPlan $snapshot).Images.Count 'manifest references remain protected'
        $snapshot.Images[2].Tag = 'local/kataglyphis:bk-windows-media-rocm'
        Assert-Equal 0 (Get-DelegatedRetirementPlan $snapshot).Images.Count 'a different lane does not prove a merge'
    }

    It 'requires an exact disposable marker and known full container identities' {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Containers)
        $item = New-DelegationFixtureContainer
        Assert-True (ConvertTo-HostContainerRecord $item).Disposable
        foreach ($value in @('TRUE', 'false', '')) {
            $item.Config.Labels = [pscustomobject]@{ 'org.kataglyphis.antfrastructure.disposable' = $value }
            Assert-False (ConvertTo-HostContainerRecord $item).Disposable 'marker value must be exact'
        }
        $item.Config.Labels = [pscustomobject]@{ 'ORG.KATAGLYPHIS.ANTFRASTRUCTURE.DISPOSABLE' = 'true' }
        Assert-False (ConvertTo-HostContainerRecord $item).Disposable 'marker name must be exact'
        $item.State.Running = 'false'
        Assert-Throws { ConvertTo-HostContainerRecord $item } -MessagePattern 'running state'
        Assert-Throws { Get-StevedoreTargets -Container @('short') @($item.Image) } -MessagePattern 'Full container'
        Assert-Throws { Get-StevedoreTargets -Container @($item.Id) @() } -MessagePattern 'expected image'
        Assert-Throws { Get-StevedoreTargets -Container @($item.Id, $item.Id) @($item.Image, $item.Image) } -MessagePattern 'Duplicate'
    }

    It 'retains plain removal without force or volumes' {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        Assert-DelegationFixtureRemovalCommand
    }

    It 'refuses active or unknown accounting and incomplete image identities' {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Inventory)
        $usage = [pscustomobject]@{ id = 'regular-one'; inUse = $false; recordType = 'regular'; shared = $false; size = 0 }
        $history = '{"record":{"CreatedAt":{"seconds":1},"CompletedAt":{"seconds":2}}}'
        Assert-DelegatedStoreIdle @($usage) @($history)
        foreach ($fault in @(@{inUse=$true}, @{inUse='false'}, @{shared='false'}, @{size=-1}, @{recordType=''})) {
            $changed = $usage.PSObject.Copy()
            foreach ($key in $fault.Keys) { $changed.$key = $fault[$key] }
            Assert-Throws { Assert-DelegatedStoreIdle @($changed) @($history) } -MessagePattern 'active|unknown'
        }
        Assert-Throws { Assert-DelegatedStoreIdle @($usage) @('{"record":{"CreatedAt":{"seconds":1},"CompletedAt":null}}') } -MessagePattern 'unfinished'
        $digest = 'sha256:' + ('a' * 64)
        $tags = @(ConvertTo-DelegatedImageTags @("local/kataglyphis current $digest 1 GB"))
        $details = @([pscustomobject]@{ RepoTags = @('docker.io/local/kataglyphis:current'); Id = $digest })
        Assert-Equal $digest @(ConvertTo-DelegatedImageInventory $tags $details)[0].Config
        Assert-Throws { ConvertTo-DelegatedImageTags @("<none> <none> $digest 1 GB") } -MessagePattern 'Untagged'
        Assert-Throws { ConvertTo-DelegatedImageInventory $tags @() } -MessagePattern 'identity is unknown'
    }
}
