#requires -Version 7.0
# NOT covered: containerd behavior, real writable-layer contents, volume preservation or operating-system privileges.

Describe 'Canonical stopped container retirement' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Containers)
    }

    It 'requires full unique container and expected image identities' {
        $id = 'a' * 64
        $image = 'sha256:' + ('b' * 64)
        Assert-Equal 1 @(Get-StevedoreTargets -Container @($id) @($image)).Count
        Assert-Throws { Get-StevedoreTargets -Container @($id) @() } -MessagePattern 'expected image'
        Assert-Throws { Get-StevedoreTargets -Container @('short') @($image) } -MessagePattern 'Full container'
        Assert-Throws { Get-StevedoreTargets -Container @($id, $id) @($image, $image) } -MessagePattern 'Duplicate'
    }

    It 'recognizes the explicit disposable label without treating missing labels as permission' {
        $item = New-DelegationFixtureContainer
        Assert-True (ConvertTo-HostContainerRecord $item).Disposable
        $item.Config.Labels = $null
        Assert-False (ConvertTo-HostContainerRecord $item).Disposable
        $item.State.Running = 'false'
        Assert-Throws { ConvertTo-HostContainerRecord $item } -MessagePattern 'running state'
    }

    It 'refuses active unmarked changed and unknown container state' {
        $script:container = New-DelegationFixtureContainer
        function Invoke-StevedoreRead { param($Store, $Arguments, $FailureMessage) ConvertTo-Json -InputObject @($script:container) -Depth 6 }
        function ConvertFrom-StevedoreJson { param($Raw, $Context) $Raw | ConvertFrom-Json }
        $target = @(Get-StevedoreTargets -Container @($script:container.Id) @($script:container.Image))[0]
        Assert-StevedoreContainerTarget -Store @{} -Target $target
        foreach ($case in @('running', 'unmarked', 'changed', 'unknown')) {
            $script:container = New-DelegationFixtureContainer
            switch ($case) {
                running { $script:container.State.Running = $true }
                unmarked { $script:container.Config.Labels = $null }
                changed { $script:container.Image = 'sha256:' + ('c' * 64) }
                unknown { $script:container.State.Status = 'unknown' }
            }
            Assert-Throws { Assert-StevedoreContainerTarget -Store @{} -Target $target } -MessagePattern 'Container'
        }
    }

    It 'does not force removal or remove volumes' {
        Assert-DelegationFixtureRemovalCommand
    }
}
