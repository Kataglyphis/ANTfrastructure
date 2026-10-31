# NOT covered: a live daemon or the contents of its reported inventory.

. (Join-Path (Get-RepoRoot) 'windows/scripts/host/Get-StevedoreInventory.ps1')

Describe 'Stevedore inventory' {
    It 'plans only read-only probes in the requested namespace' {
        $plan = @(Get-StevedoreInventoryPlan -StevedoreNamespace 'sample-space' -BuildkitAddress 'npipe:////./pipe/test' -ContainerdAddress 'test-pipe' -NerdctlPath 'custom-nerdctl' -BuildctlPath 'custom-buildctl')
        Assert-Equal 3 $plan.Count
        Assert-Equal 'custom-buildctl' $plan[0].Executable
        Assert-Equal '--addr|npipe:////./pipe/test|du|-v' ($plan[0].Arguments -join '|')
        Assert-Equal 'custom-nerdctl' $plan[1].Executable
        Assert-Equal '--address|test-pipe|--namespace|sample-space|images|--no-trunc' ($plan[1].Arguments -join '|')
        Assert-Equal '--address|test-pipe|--namespace|sample-space|ps|-a|--no-trunc' ($plan[2].Arguments -join '|')
    }

    It 'rejects namespace option injection' {
        Assert-Throws { Get-StevedoreInventoryPlan -StevedoreNamespace '--help' -BuildkitAddress 'addr' -ContainerdAddress 'pipe' -NerdctlPath 'n' -BuildctlPath 'b' } -MessagePattern 'StevedoreNamespace'
    }

    It 'fails when a probe exits nonzero' {
        $exe = (Get-Process -Id $PID).Path
        Invoke-StevedoreInventoryProbe -Executable $exe -Arguments @('-NoProfile', '-Command', 'exit 0')
        Assert-Throws { Invoke-StevedoreInventoryProbe -Executable $exe -Arguments @('-NoProfile', '-Command', 'exit 7') } -MessagePattern 'exit code 7'
    }
}
