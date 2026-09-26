#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Build-OnnxFromSource.ps1's Disable-OrtCudaLauncherForPtx: with Blackwell (120/121) in the arch
# list, ORT compiles its LLM kernels as PTX only on MSVC, and sccache 0.18 aborts every such nvcc
# compile (mozilla/sccache#2862), so the CUDA launcher must go for that build and only for it.
# NOT covered: nvcc, sccache or ORT's own cmake.

Describe 'Build-OnnxFromSource: the CUDA launcher and a Blackwell arch list' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-OnnxFromSource.ps1' -FunctionName 'Disable-OrtCudaLauncherForPtx')

    It 'takes the launcher back for 120 or 121, and leaves any other arch list alone (mutation)' {
        foreach ($c in @(
                @{ Archs = '86;87;89;120'; Off = $true }, @{ Archs = '121'; Off = $true },
                @{ Archs = '80;86;87;89;90'; Off = $false }, @{ Archs = '86;89'; Off = $false })) {
            Invoke-WithEnv @{ SCCACHE_CUDA_LAUNCHER = '1' } {
                $r = Disable-OrtCudaLauncherForPtx -Architectures $c.Archs 6>$null
                Assert-Equal $c.Off $r "result for $($c.Archs)"
                Assert-Equal $(if ($c.Off) { '' } else { '1' }) "$env:SCCACHE_CUDA_LAUNCHER" "launcher for $($c.Archs)"
            }
        }
    }

    It 'does nothing when the launcher was not on' {
        Invoke-WithEnv @{ SCCACHE_CUDA_LAUNCHER = $null } {
            Assert-False (Disable-OrtCudaLauncherForPtx -Architectures '86;120' 6>$null) 'nothing to take back'
            Assert-Null $env:SCCACHE_CUDA_LAUNCHER 'still unset'
        }
    }

    It 'is called on the CUDA path of the script, before the configure' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-OnnxFromSource.ps1')
        $call = $src.IndexOf('$null = Disable-OrtCudaLauncherForPtx')
        Assert-True ($call -gt $src.IndexOf('if ($cudaUsable) {')) 'inside the CUDA branch'
        Assert-True ($call -lt $src.IndexOf("Switch-BuildPhase '3. cmake configure'")) 'before cmake reads the launcher'
    }
}
