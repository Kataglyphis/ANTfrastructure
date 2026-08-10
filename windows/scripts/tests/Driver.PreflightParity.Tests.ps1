# Backlog 0c: lane parity is now OWNED by this suite. The RDNA4 gate landed
# in the BK driver a day before the classic lane got it via review - this
# test makes that class of drift a red gate instead of a lucky catch. When a
# new preflight is added to one driver, either add it to the other or extend
# the lane-specific allowlist below WITH a reason.

#requires -Version 7.0

Describe 'driver preflight parity (build.ps1 vs build-buildkit.ps1)' {

    $windowsDir = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
    $classic = Get-Content (Join-Path $windowsDir 'build.ps1') -Raw
    $bk = Get-Content (Join-Path $windowsDir 'build-buildkit.ps1') -Raw

    # The shared preflight contract: every entry must appear in BOTH drivers.
    $sharedPreflights = @(
        'Assert-SccacheEndpoint',
        'Assert-DiskHeadroom',
        'Assert-NoActiveRdna4Gpu',
        'Assert-StageDiskHeadroom'
    )
    # Lane-specific preflights, with the reason they do not need a twin:
    #   Assert-ShimPatch / Assert-BuildkitdStepLogEnv - containerd/buildkitd
    #     infrastructure only exists on the BK lane.
    #   Assert-DockerDaemon - the classic lane's daemon; BK talks to buildkitd
    #     via npipe and would refuse in buildctl resolution instead.
    $bkOnly = @('Assert-ShimPatch', 'Assert-BuildkitdStepLogEnv')
    #   Assert-ImageExists - classic-lane mid-chain input check (docker image
    #     inspect between stages); the BK lane resolves committed stage tags
    #     via --opt image-resolve-mode=local inside the solve instead.
    $classicOnly = @('Assert-DockerDaemon', 'Assert-ImageExists')

    It 'wires every shared preflight in BOTH drivers' {
        foreach ($gate in $sharedPreflights) {
            Assert-True ($classic -match [regex]::Escape($gate)) "build.ps1 must call $gate"
            Assert-True ($bk -match [regex]::Escape($gate)) "build-buildkit.ps1 must call $gate"
        }
    }

    It 'keeps the lane-specific gates where they belong' {
        foreach ($gate in $bkOnly) {
            Assert-True ($bk -match [regex]::Escape($gate)) "build-buildkit.ps1 must call $gate"
        }
        foreach ($gate in $classicOnly) {
            Assert-True ($classic -match [regex]::Escape($gate)) "build.ps1 must call $gate"
        }
    }

    It 'offers the gate-specific RDNA4 override in BOTH drivers (backlog #18)' {
        foreach ($content in @($classic, $bk)) {
            Assert-True ($content -match '\$SkipRdna4Gate') 'both drivers must accept -SkipRdna4Gate'
            Assert-True ($content -match 'SkipHostChecks -or \$SkipRdna4Gate') 'the RDNA4 gate must honor either override'
        }
    }

    It 'catches a NEW Assert-* preflight added to only one driver' {
        # Any Assert-* invocation in a driver must be shared, allowlisted, or
        # this test fails - that is the ownership 0c asked for.
        $known = $sharedPreflights + $bkOnly + $classicOnly
        foreach ($pair in @(@{ Name = 'build.ps1'; Text = $classic }, @{ Name = 'build-buildkit.ps1'; Text = $bk })) {
            $called = @([regex]::Matches($pair.Text, '(?m)^\s*(Assert-[A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $unknown = @($called | Where-Object { $_ -notin $known })
            Assert-Equal 0 $unknown.Count "$($pair.Name) calls unlisted preflight(s): $($unknown -join ', ') - add to the parity contract or the lane allowlist"
        }
    }
}
