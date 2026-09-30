#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Without the ASM target the x86 assembler gets aarch64 .S kernels; host-tool configures expect no cross flags at all.

Describe 'Get-CMakeCrossArgs' {
    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsTargetArch.Common.psm1') -Force -DisableNameChecking
    }

    It 'arm64 carries C, CXX AND ASM compiler targets plus the matching _FLAGS_INIT' {
        $a = @(Get-CMakeCrossArgs -Arch 'arm64')
        foreach ($k in 'CMAKE_C_COMPILER_TARGET', 'CMAKE_CXX_COMPILER_TARGET', 'CMAKE_ASM_COMPILER_TARGET') {
            Assert-True (@($a | Where-Object { $_ -eq "-D$k=aarch64-pc-windows-msvc" }).Count -eq 1) "$k present exactly once"
        }
        foreach ($k in 'CMAKE_C_FLAGS_INIT', 'CMAKE_CXX_FLAGS_INIT', 'CMAKE_ASM_FLAGS_INIT') {
            Assert-True (@($a | Where-Object { $_ -eq "-D$k=--target=aarch64-pc-windows-msvc" }).Count -eq 1) "$k present exactly once"
        }
        Assert-True ($a -contains '-DCMAKE_SYSTEM_PROCESSOR=ARM64') 'system processor'
    }

    It 'the host arch yields no cross args at all' {
        Assert-Equal 0 @(Get-CMakeCrossArgs -Arch 'amd64').Count 'host-tool configures must see an empty list'
    }
}
