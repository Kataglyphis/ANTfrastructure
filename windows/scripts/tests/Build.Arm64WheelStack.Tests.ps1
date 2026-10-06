#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# A wheel key without its pin throws hours into the arm64 merge stage, so the table and versions.env are checked here.

Describe 'Copy-Arm64TorchWheels: every staged wheel is pinned' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Copy-Arm64TorchWheels.ps1' -FunctionName 'Get-Arm64WheelStack')
        $script:stacks = Get-Arm64WheelStack
        $script:pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        # torch has no cp314 win_arm64 wheel upstream; the pytest stack runs on the bundle's own cp314.
        $script:abi = @{ TORCH_WINDOWS_ARM64 = 'cp313'; PYTEST_WINDOWS_ARM64 = 'cp314' }
    }

    It 'has a URL and a 64-hex SHA256 for every key in both stacks' {
        Assert-Equal 'TORCH_WINDOWS_ARM64,PYTEST_WINDOWS_ARM64' (@($script:stacks.Keys) -join ',') 'the two stacks, torch first'
        foreach ($prefix in $script:stacks.Keys) {
            foreach ($name in $script:stacks[$prefix].Keys) {
                Assert-Match '^https://\S+\.whl$' $script:pins["${prefix}_${name}_URL"] "${prefix}_${name}_URL"
                Assert-Match '^[0-9a-f]{64}$' $script:pins["${prefix}_${name}_SHA256"] "${prefix}_${name}_SHA256"
            }
        }
    }

    It 'flags a wheel native exactly when it is a win_arm64 wheel of the stack''s ABI' {
        foreach ($prefix in $script:stacks.Keys) {
            foreach ($name in $script:stacks[$prefix].Keys) {
                $file = [uri]::UnescapeDataString(([uri]$script:pins["${prefix}_${name}_URL"]).Segments[-1])
                if ($script:stacks[$prefix][$name]) {
                    Assert-Match "-$($script:abi[$prefix])-$($script:abi[$prefix])-win_arm64\.whl$" $file "$prefix $name is native"
                } else {
                    Assert-Match '-(py2\.)?py3-none-any\.whl$' $file "$prefix $name is universal"
                }
            }
        }
    }

    It 'pins no wheel that no stack stages' {
        foreach ($prefix in $script:stacks.Keys) {
            $pinned = @($script:pins.Keys | Where-Object { $_ -match "^${prefix}_(.+)_URL$" } | ForEach-Object { $_ -replace "^${prefix}_|_URL$", '' })
            $orphans = @($pinned | Where-Object { -not $script:stacks[$prefix].Contains($_) })
            Assert-Equal '' ($orphans -join ',') "$prefix pins without a table row"
        }
    }
}
