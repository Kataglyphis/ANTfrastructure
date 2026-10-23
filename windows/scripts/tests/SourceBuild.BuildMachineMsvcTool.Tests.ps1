#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The build machine's x64-targeting cl/ml64 by name, never PATH's ARM64 cl; a fixture VC tree, no Visual Studio needed.

Describe 'Resolve-BuildMachineMsvcTool' {

    BeforeAll {

        $script:tmp = New-TestDir -Prefix 'wbt-vctools-'
        $script:vc = Join-Path $script:tmp 'VC\Tools\MSVC\14.51.36231'
        Write-TestFileTree -Root $script:vc -Files @{
            'bin/HostX64/x64/cl.exe' = 'x64 cl'; 'bin/HostX64/ARM64/cl.exe' = 'arm64 cl'
            'bin/HostX64/ARM64/ml64.exe' = 'arm64-dir ml64'
        }
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns the x64-targeting tool as a forward-slash path' {
        $r = Resolve-BuildMachineMsvcTool -VcToolsDir $script:vc -Name 'cl.exe'
        Assert-True ($r -like '*/bin/HostX64/x64/cl.exe') "path shape ($r)"
        Assert-False ($r -match '\\') 'no backslashes (meson [binaries] value)'
    }

    It 'throws when only the ARM64-targeting copy exists (never falls back to PATH or HostX64\ARM64)' {
        Assert-Throws { Resolve-BuildMachineMsvcTool -VcToolsDir $script:vc -Name 'ml64.exe' | Out-Null } 'ml64.exe present only under HostX64\ARM64 must throw'
    }

    It 'throws on an empty VC tools root' {
        Assert-Throws { Resolve-BuildMachineMsvcTool -VcToolsDir ' ' -Name 'cl.exe' | Out-Null } 'blank root must throw'
    }
}
