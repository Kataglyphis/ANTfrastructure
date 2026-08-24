#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Invoke-WithHostArchLibraryEnvironment (#116, 2026-08-24): a host-tool pass on
# a cross lane needs the HOST's library directories on LIB/LIBPATH, not the
# target's. VsDevCmd -arch=arm64 leaves both pointing at ...\arm64, and lld-link
# reads ONLY LIB, so IREE's native host-tools configure died in its first
# try-compile ("msvcrtd.lib(exe_main.obj): machine type arm64 conflicts with
# x64"). The helper rewrites the arch SEGMENT of every entry for the duration
# of the block and restores both variables afterwards -- including on throw.

Describe 'Invoke-WithHostArchLibraryEnvironment' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
        $script:savedArch = $env:WINDOWS_TARGET_ARCH
        $script:savedLib = $env:LIB
        $script:savedLibPath = $env:LIBPATH
    }

    AfterAll {
        $env:WINDOWS_TARGET_ARCH = $script:savedArch
        $env:LIB = $script:savedLib
        $env:LIBPATH = $script:savedLibPath
    }

    It 'rewrites every arm64 segment of LIB and LIBPATH to x64 inside the block, and restores both after it' {
        $env:WINDOWS_TARGET_ARCH = 'arm64'
        $env:LIB = 'C:\VS\VC\Tools\MSVC\14.51\lib\arm64;C:\Kits\10\Lib\10.0.26100.0\ucrt\arm64;C:\Kits\10\Lib\10.0.26100.0\um\arm64;C:\VS\VC\Tools\MSVC\14.51\atlmfc\lib\arm64;C:\other\lib'
        $env:LIBPATH = 'C:\VS\VC\Tools\MSVC\14.51\lib\arm64\store\references;C:\VS\VC\Tools\MSVC\14.51\lib\arm64'
        $inside = Invoke-WithHostArchLibraryEnvironment { @{ LIB = $env:LIB; LIBPATH = $env:LIBPATH } }
        Assert-Equal 'C:\VS\VC\Tools\MSVC\14.51\lib\x64;C:\Kits\10\Lib\10.0.26100.0\ucrt\x64;C:\Kits\10\Lib\10.0.26100.0\um\x64;C:\VS\VC\Tools\MSVC\14.51\atlmfc\lib\x64;C:\other\lib' $inside.LIB 'LIB inside the block: every \arm64 segment -> \x64, unrelated entries untouched'
        Assert-Equal 'C:\VS\VC\Tools\MSVC\14.51\lib\x64\store\references;C:\VS\VC\Tools\MSVC\14.51\lib\x64' $inside.LIBPATH 'LIBPATH inside the block: mid-path segments rewritten too'
        Assert-Equal 'C:\VS\VC\Tools\MSVC\14.51\lib\arm64;C:\Kits\10\Lib\10.0.26100.0\ucrt\arm64;C:\Kits\10\Lib\10.0.26100.0\um\arm64;C:\VS\VC\Tools\MSVC\14.51\atlmfc\lib\arm64;C:\other\lib' $env:LIB 'LIB restored after the block'
    }

    It 'restores the environment when the block throws' {
        $env:WINDOWS_TARGET_ARCH = 'arm64'
        $env:LIB = 'C:\VS\lib\arm64'
        $threw = $false
        try { Invoke-WithHostArchLibraryEnvironment { throw 'boom' } } catch { $threw = $true }
        Assert-True $threw 'the block''s exception propagates'
        Assert-Equal 'C:\VS\lib\arm64' $env:LIB 'LIB restored even on throw'
    }

    It 'is a no-op on the native lane (host == target)' {
        $env:WINDOWS_TARGET_ARCH = 'amd64'
        $env:LIB = 'C:\VS\lib\x64;C:\weird\arm64'
        $inside = Invoke-WithHostArchLibraryEnvironment { $env:LIB }
        Assert-Equal 'C:\VS\lib\x64;C:\weird\arm64' $inside 'nothing rewritten when the host is the target'
    }
}
