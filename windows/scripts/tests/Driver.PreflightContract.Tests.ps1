#requires -Version 7.0
# Backlog 0c, single-driver since 2026-08-31: this suite owned PARITY between build.ps1
# and build-buildkit.ps1 until the classic driver was deleted. What survives is the half
# that still bites — a preflight gate silently added or dropped in the one driver left.


Describe 'driver preflight contract (build-buildkit.ps1)' {

    $windowsDir = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
    $bk = Get-Content (Join-Path $windowsDir 'build-buildkit.ps1') -Raw

    # Every gate the surviving driver must wire. Dropping one is the regression.
    $requiredPreflights = @(
        'Assert-SccacheEndpoint',
        'Assert-DiskHeadroom',
        'Assert-NoActiveRdna4Gpu',
        'Assert-StageDiskHeadroom',
        # containerd/buildkitd infrastructure — BK lane only, and now the only lane.
        'Assert-ShimPatch',
        'Assert-BuildkitdStepLogEnv'
    )

    It 'wires every required preflight' {
        foreach ($gate in $requiredPreflights) {
            Assert-True ($bk -match [regex]::Escape($gate)) "build-buildkit.ps1 must call $gate"
        }
    }

    It 'offers the gate-specific RDNA4 override (backlog #18)' {
        Assert-True ($bk -match '\$SkipRdna4Gate') 'the driver must accept -SkipRdna4Gate'
        Assert-True ($bk -match 'SkipHostChecks -or \$SkipRdna4Gate') 'the RDNA4 gate must honor either override'
    }

    It 'catches a NEW Assert-* preflight that was never added to the contract' {
        $called = @([regex]::Matches($bk, '(?m)^\s*(Assert-[A-Za-z0-9]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $unknown = @($called | Where-Object { $_ -notin $requiredPreflights })
        Assert-Equal 0 $unknown.Count "build-buildkit.ps1 calls unlisted preflight(s): $($unknown -join ', ') - add it to the contract above"
    }
}
