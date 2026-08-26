#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Resolve-BuildMachineMsvcTool (build-gstreamer-from-source.ps1): the x64-
# targeting cl.exe / ml64.exe the meson native file names for the BUILD machine
# after arm64 run 26 (the build-machine libffi found HostX64\ARM64\cl.exe on
# PATH and ml64 died on FFI_TYPE_SMALL_STRUCT_4B). Lifted out of the script's
# AST; fixture VC tools tree, no Visual Studio needed. Pins: forward-slash
# path under bin/HostX64/x64, throws (never falls back) when the tool or the
# root is missing.

Describe 'Resolve-BuildMachineMsvcTool' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\build-gstreamer-from-source.ps1' `
                                       -FunctionName 'Resolve-BuildMachineMsvcTool')

        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-vctools-' + [guid]::NewGuid().ToString('N'))
        $script:vc = Join-Path $script:tmp 'VC\Tools\MSVC\14.51.36231'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:vc 'bin\HostX64\x64') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $script:vc 'bin\HostX64\ARM64') | Out-Null
        Set-Content (Join-Path $script:vc 'bin\HostX64\x64\cl.exe') 'x64 cl'
        Set-Content (Join-Path $script:vc 'bin\HostX64\ARM64\cl.exe') 'arm64 cl'
        Set-Content (Join-Path $script:vc 'bin\HostX64\ARM64\ml64.exe') 'arm64-dir ml64'
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns the x64-targeting tool as a forward-slash path' {
        $r = Resolve-BuildMachineMsvcTool -VcToolsDir $script:vc -Name 'cl.exe'
        Assert-True ($r -like '*/bin/HostX64/x64/cl.exe') "path shape ($r)"
        Assert-False ($r -match '\\') 'no backslashes (meson [binaries] value)'
    }

    It 'throws when only the ARM64-targeting copy exists (never falls back to PATH or HostX64\ARM64)' {
        $threw = $false
        try { Resolve-BuildMachineMsvcTool -VcToolsDir $script:vc -Name 'ml64.exe' | Out-Null } catch { $threw = $true }
        Assert-True $threw 'ml64.exe present only under HostX64\ARM64 must throw'
    }

    It 'throws on an empty VC tools root' {
        $threw = $false
        try { Resolve-BuildMachineMsvcTool -VcToolsDir ' ' -Name 'cl.exe' | Out-Null } catch { $threw = $true }
        Assert-True $threw 'blank root must throw'
    }
}
