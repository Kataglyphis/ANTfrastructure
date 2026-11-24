#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real clone, network access, or whether GitHub serves the pinned hub commit shallowly.

Describe 'Build-TorchApp.ps1: the app checkout carries its hub submodule' {
    . (Get-ScriptFunctionDefinition -ScriptPath (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TorchApp.ps1') -FunctionName 'New-TorchAppCheckout')

    It 'initializes only third_party/ANTfrastructure, shallowly, after either checkout path (mutation)' {
        foreach ($ref in @('0123456789abcdef0123456789abcdef01234567', 'develop')) {
            Invoke-InTestDir { param($dir)
                $script:calls = [System.Collections.Generic.List[string]]::new()
                function Invoke-ShieldedNative { param([string]$Label, [string]$CommandLine) $script:calls.Add("$Label|$CommandLine") }
                $app = Join-Path $dir 'opt\OrchestrANT'
                New-TorchAppCheckout -AppDir $app -AppRef $ref 3>$null
                $last = $script:calls[$script:calls.Count - 1]
                Assert-Match '^git submodule \(app hub\)\|' $last "the hub submodule comes last for $ref"
                Assert-Match ([regex]::Escape("git -C ""$app"" submodule update --init --depth 1 third_party/ANTfrastructure")) $last "shallow and path-scoped for $ref"
                Assert-False ($last -match '--recursive') "no nested submodules for $ref"
            }
        }
    }
}
