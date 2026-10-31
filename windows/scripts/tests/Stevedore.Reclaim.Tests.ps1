#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT

Describe 'Stevedore selected reclaim' {
    BeforeAll {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Clear-DiskSpace.ps1' -FunctionName `
        'Get-StevedoreTargets', 'Assert-StevedoreTarget', 'Invoke-StevedoreReclaim', 'Assert-StevedoreSelectors')

    function Get-StevedoreImageId { param($Store, $Tag) $script:inspectionCount++; if ($script:changeAfter -and $script:inspectionCount -gt $script:changeAfter) { return ('sha256:' + ('b' * 64)) }; return $script:currentImageId }
    function Assert-StevedoreAdmin { $script:events.Add('admin') }
    function Assert-StevedoreIdle { param($Buildctl, $Address) $script:events.Add("idle:$Address") }
    function Invoke-StevedoreRemoval { param($Store, $Tag) $script:events.Add("remove:$($Store.Address):$($Store.Namespace):$Tag") }
    function Invoke-StevedoreRegularPrune { param($Buildctl, $Address, $TargetGB) $script:events.Add("prune:${Address}:$TargetGB") }
    function Write-HostMaintenanceMessage { param($Message) }
    }

    BeforeEach {
        $script:currentImageId = 'sha256:' + ('a' * 64)
        $script:events = [Collections.Generic.List[string]]::new()
        $script:inspectionCount = 0
        $script:changeAfter = 0
        $script:target = @(Get-StevedoreTargets -Tags @('local/example:stage') -Ids @($script:currentImageId))
    }

    It 'rejects unmatched, wildcard, duplicate, and non-full image selectors' {
        Assert-Throws { Get-StevedoreTargets -Tags @('local/example:stage') -Ids @() } -MessagePattern 'one expected'
        Assert-Throws { Get-StevedoreTargets -Tags @('local/example:*') -Ids @($script:currentImageId) } -MessagePattern 'Invalid explicit'
        Assert-Throws { Get-StevedoreTargets -Tags @('local/example:stage', 'local/example:stage') -Ids @($script:currentImageId, $script:currentImageId) } -MessagePattern 'Duplicate'
        Assert-Throws { Get-StevedoreTargets -Tags @('local/example:stage') -Ids @('sha256:abcd') } -MessagePattern 'full lowercase'
    }

    It 'rejects daemon-only parameters instead of falling into general cleanup' {
        foreach ($name in @('ImageTag', 'ExpectedImageId', 'RegularCache', 'StevedoreNamespace', 'BuildkitAddress', 'ContainerdAddress')) {
            Assert-Throws { Assert-StevedoreSelectors -Selected $false -BoundParameters @($name) } -MessagePattern 'requires -StevedoreOnly'
        }
        Assert-StevedoreSelectors -Selected $false -BoundParameters @('Apply')
        Assert-StevedoreSelectors -Selected $true -BoundParameters @('ContainerdAddress')
    }

    It 'previews, applies only selected operations, and stops on ID drift' {
        Invoke-StevedoreReclaim -Targets $script:target -PruneRegular $true -TargetGB 100 -DoApply $false `
            -Nerdctl 'nerdctl' -Buildctl 'buildctl' -Namespace 'buildkit' -Address 'npipe:////./pipe/buildkitd' -ContainerdAddress 'npipe://containerd'
        Assert-Equal 0 $script:events.Count
        Invoke-StevedoreReclaim -Targets $script:target -PruneRegular $false -TargetGB 100 -DoApply $true `
            -Nerdctl 'nerdctl' -Buildctl 'buildctl' -Namespace 'custom' -Address 'npipe:////./pipe/test' -ContainerdAddress 'npipe://containerd'
        Assert-Equal 'admin|idle:npipe:////./pipe/test|remove:npipe://containerd:custom:local/example:stage' ($script:events -join '|')
        $script:events.Clear()
        Invoke-StevedoreReclaim -Targets @() -PruneRegular $true -TargetGB 120 -DoApply $true `
            -Nerdctl 'nerdctl' -Buildctl 'buildctl' -Namespace 'custom' -Address 'npipe:////./pipe/test' -ContainerdAddress 'npipe://containerd'
        Assert-Equal 'admin|idle:npipe:////./pipe/test|idle:npipe:////./pipe/test|prune:npipe:////./pipe/test:120' ($script:events -join '|')
        $script:events.Clear()
        $script:currentImageId = 'sha256:' + ('b' * 64)
        Assert-Throws {
            Invoke-StevedoreReclaim -Targets $script:target -PruneRegular $true -TargetGB 100 -DoApply $true `
                -Nerdctl 'nerdctl' -Buildctl 'buildctl' -Namespace 'buildkit' -Address 'npipe://bk' -ContainerdAddress 'npipe://ctr'
        } -MessagePattern 'changed since review'
        Assert-Equal 0 $script:events.Count
        $script:currentImageId = 'sha256:' + ('a' * 64)
        $script:inspectionCount = 0
        $script:changeAfter = 1
        Assert-Throws {
            Invoke-StevedoreReclaim -Targets $script:target -PruneRegular $true -TargetGB 100 -DoApply $true `
                -Nerdctl 'nerdctl' -Buildctl 'buildctl' -Namespace 'buildkit' -Address 'npipe://bk' -ContainerdAddress 'npipe://ctr'
        } -MessagePattern 'changed since review'
        Assert-Equal 'admin|idle:npipe://bk' ($script:events -join '|')
        $script:inspectionCount = 0
        $script:events.Clear()
        $other = @(Get-StevedoreTargets -Tags @('local/example:other') -Ids @($script:currentImageId))
        $script:changeAfter = 3
        Assert-Throws {
            Invoke-StevedoreReclaim -Targets @($script:target[0], $other[0]) -PruneRegular $true -TargetGB 100 -DoApply $true `
                -Nerdctl 'nerdctl' -Buildctl 'buildctl' -Namespace 'buildkit' -Address 'npipe://bk' -ContainerdAddress 'npipe://ctr'
        } -MessagePattern 'changed since review'
        Assert-Equal 'admin|idle:npipe://bk|remove:npipe://ctr:buildkit:local/example:stage' ($script:events -join '|')
    }

    It 'rejects empty selections and option-shaped namespace or address' {
        Assert-Throws { Invoke-StevedoreReclaim -Targets @() -PruneRegular $false -TargetGB 100 -DoApply $false -Namespace buildkit -Address 'npipe://x' } -MessagePattern 'Select image'
        Assert-Throws { Invoke-StevedoreReclaim -Targets $script:target -PruneRegular $false -TargetGB 100 -DoApply $false -Namespace '-bad' -Address 'npipe://x' } -MessagePattern 'namespace'
        Assert-Throws { Invoke-StevedoreReclaim -Targets $script:target -PruneRegular $false -TargetGB 100 -DoApply $false -Namespace buildkit -Address '-bad' } -MessagePattern 'address'
        Assert-Throws { Invoke-StevedoreReclaim -Targets $script:target -PruneRegular $false -TargetGB 100 -DoApply $false -Namespace buildkit -Address 'npipe://x' -ContainerdAddress '-bad' } -MessagePattern 'containerd address'
    }
}

Describe 'Stevedore daemon calls' {
    BeforeAll {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Clear-DiskSpace.ps1' -FunctionName `
        'Invoke-StevedoreRead', 'ConvertFrom-StevedoreJson', 'Assert-BuildkitIdle', 'Assert-StevedoreIdle', 'Get-StevedoreImageId', 'Invoke-StevedoreRemoval', 'Invoke-StevedoreRegularPrune')

    function Invoke-FakeDaemon {
        $script:calls.Add(($args -join '|'))
        $global:LASTEXITCODE = if ($args -contains '--namespace') { $script:nerdctlExit } else { $script:buildctlExit }
        if ($args -contains 'ps') { if ($script:running) { 'container1' }; return }
        if ($args -contains 'inspect') {
            '['
            '  {'
            '    "Id": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
            '  }'
            ']'
        }
        if ($args -contains 'du') { $script:usage }
    }
    }

    BeforeEach {
        $script:calls = [Collections.Generic.List[string]]::new()
        $script:nerdctlExit = 0
        $script:buildctlExit = 0
        $script:running = $false
        $script:usage = '[{"inUse":false}]'
        $script:store = [pscustomobject]@{ Tool = 'Invoke-FakeDaemon'; Namespace = 'custom'; Address = 'npipe://ctr' }
    }

    It 'routes inspections, removals, and regular-only pruning to explicit endpoints' {
        $id = Get-StevedoreImageId -Store $script:store -Tag 'local/example:tag'
        Assert-Equal ('sha256:' + ('a' * 64)) $id
        Invoke-StevedoreRemoval -Store $script:store -Tag 'local/example:tag'
        Invoke-StevedoreRegularPrune -Buildctl Invoke-FakeDaemon -Address 'npipe://bk' -TargetGB 100
        Assert-Equal '--address|npipe://ctr|--namespace|custom|image|inspect|local/example:tag' $script:calls[0]
        Assert-Equal '--address|npipe://ctr|--namespace|custom|rmi|local/example:tag' $script:calls[1]
        Assert-Equal '--addr|npipe://bk|prune|--filter|type==regular|--free-storage|102400' $script:calls[2]
    }

    It 'refuses active containers, in-use records, invalid usage, and native errors' {
        Mock Get-Process { }
        Assert-StevedoreIdle -Store $script:store -Buildctl Invoke-FakeDaemon -Address 'npipe://bk'
        Assert-Equal '--address|npipe://ctr|--namespace|custom|ps|--quiet|--no-trunc' $script:calls[0]
        $script:running = $true
        Assert-Throws { Assert-StevedoreIdle -Store $script:store -Buildctl Invoke-FakeDaemon -Address 'npipe://bk' } -MessagePattern 'containers are running'
        $script:running = $false
        $script:usage = '[{"inUse":true}]'
        Assert-Throws { Assert-StevedoreIdle -Store $script:store -Buildctl Invoke-FakeDaemon -Address 'npipe://bk' } -MessagePattern 'in-use'
        $script:usage = '[{}]'
        Assert-Throws { Assert-StevedoreIdle -Store $script:store -Buildctl Invoke-FakeDaemon -Address 'npipe://bk' } -MessagePattern 'no valid inUse'
        $script:nerdctlExit = 1
        Assert-Throws { Assert-StevedoreIdle -Store $script:store -Buildctl Invoke-FakeDaemon -Address 'npipe://bk' } -MessagePattern 'Cannot inspect Stevedore containers'
        Assert-Throws { Invoke-StevedoreRemoval -Store $script:store -Tag 'local/example:tag' } -MessagePattern 'removal failed'
        $script:buildctlExit = 1
        Assert-Throws { Invoke-StevedoreRegularPrune -Buildctl Invoke-FakeDaemon -Address 'npipe://bk' -TargetGB 100 } -MessagePattern 'prune failed'
    }
}
