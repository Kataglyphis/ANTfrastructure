#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Every ORT CUDA target keeps sccache because the hub's sccache carries the PTX-only fix (mozilla/sccache#2862, #2809).

Describe 'Build-OnnxFromSource: every CUDA target keeps the sccache launcher' {

    It 'names no per-target launcher exemption' {
        $src = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-OnnxFromSource.ps1')
        foreach ($pattern in 'CMAKE_PROJECT_onnxruntime_INCLUDE', 'sccache-ptx-exempt', 'CUDA_COMPILER_LAUNCHER\s*""') {
            Assert-False ($src -match $pattern) "Build-OnnxFromSource.ps1 must not take nvcc off sccache ($pattern)"
        }
        Assert-False (Test-Path -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\patches\onnxruntime\sccache-ptx-exempt.cmake')) 'the exempting include is gone'
    }

    It 'relies on an sccache build whose patch runs a PTX-only ptxas pass instead of aborting it' {
        $patch = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'shared\upstream\sccache\patches\0001-ptxas-ptx-verify-noncacheable.patch')
        Assert-Match '\+\s+Cacheable::No' $patch
        $pins = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        Assert-Match '(?m)^SCCACHE_WINDOWS_VERSION=\S+-pr2809$' $pins
    }
}
