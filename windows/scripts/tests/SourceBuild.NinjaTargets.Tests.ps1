#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Invoke-NinjaBuildWithRetry -Targets (added 2026-08-24 for the runtime-only
# TVM cross build): the explicit target list must reach EVERY ninja invocation
# of the retry ladder, or a retry silently rebuilds the whole graph (and, for
# TVM, the compiler the lane must not ship). Same fake ninja.bat as the retry
# suite, driven through the same env knobs.

Describe 'Invoke-NinjaBuildWithRetry -Targets' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-ninjat-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
        @(
            '@echo off',
            'echo NINJA %* >> "%WBT_NINJA_LOG%"',
            'if exist "%WBT_NINJA_FAILONCE%" ( del "%WBT_NINJA_FAILONCE%" & exit /b 1 )',
            'exit /b 0'
        ) -join "`r`n" | Set-Content -LiteralPath (Join-Path $script:tmp 'ninja.bat') -Encoding ASCII
        $script:savedPath = $env:PATH
        $env:PATH = "$($script:tmp);$env:PATH"
        $env:WBT_NINJA_LOG = Join-Path $script:tmp 'ninja.log'
        $env:WBT_NINJA_MODE = ''
        $env:WBT_NINJA_STALLMARK = ''
    }
    AfterAll {
        $env:PATH = $script:savedPath
        foreach ($n in 'WBT_NINJA_LOG', 'WBT_NINJA_MODE', 'WBT_NINJA_FAILONCE', 'WBT_NINJA_STALLMARK') { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
        Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'passes the target list on the first invocation and on the incremental retry' {
        $failOnce = Join-Path $script:tmp 'failonce'
        Set-Content -LiteralPath $failOnce -Value 'x' -Encoding ASCII
        $env:WBT_NINJA_FAILONCE = $failOnce
        Remove-Item $env:WBT_NINJA_LOG -Force -ErrorAction SilentlyContinue
        Invoke-NinjaBuildWithRetry -BuildDir $script:tmp -RetryJobs 1 -MemGBPerJob 1 -Targets @('tvm_runtime', 'tvm_ffi_shared') -StallRetries 0
        $calls = @(Get-Content $env:WBT_NINJA_LOG)
        Assert-Equal 2 $calls.Count 'first attempt failed, incremental retry succeeded'
        # cmd's `echo %* >>` leaves a trailing space before the redirect -- tolerate it.
        foreach ($c in $calls) { Assert-True ($c -match ' tvm_runtime tvm_ffi_shared\s*$') "every invocation carries the targets last: $c" }
    }

    It 'omits targets entirely when none are given (whole-graph build, unchanged behaviour)' {
        $env:WBT_NINJA_FAILONCE = ''
        Remove-Item $env:WBT_NINJA_LOG -Force -ErrorAction SilentlyContinue
        Invoke-NinjaBuildWithRetry -BuildDir $script:tmp -RetryJobs 1 -MemGBPerJob 1 -StallRetries 0
        $calls = @(Get-Content $env:WBT_NINJA_LOG)
        Assert-Equal 1 $calls.Count
        Assert-True ($calls[0] -match "-C $([regex]::Escape($script:tmp))\s*$") "no trailing targets: $($calls[0])"
    }
}
