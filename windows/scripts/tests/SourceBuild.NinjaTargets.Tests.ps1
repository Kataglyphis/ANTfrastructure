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

    # Invoke-HostToolCmakeBuild (arm64 run 18, 2026-08-25): the helper's block
    # tees every ninja line onto the pipeline, so without `| Out-Host` its
    # return value was [ninja lines..., path] and IREE's `Join-Path $dir $tool`
    # died with "A drive with the name 'ninja' does not exist". A CHATTY fake
    # ninja + a fake cmake reproduce it: the return must be exactly one string.
    It 'Invoke-HostToolCmakeBuild returns exactly the directory path, not the build output' {
        $env:WBT_NINJA_FAILONCE = ''
        $chatty = Join-Path $script:tmp 'chatty'
        New-Item -Path $chatty -ItemType Directory -Force | Out-Null
        @('@echo off', 'echo ninja: Entering directory %2', 'echo [1/1] Linking fake', 'exit /b 0') -join "`r`n" |
            Set-Content -LiteralPath (Join-Path $chatty 'ninja.bat') -Encoding ASCII
        @('@echo off', 'echo -- Configuring done (fake cmake)', 'exit /b 0') -join "`r`n" |
            Set-Content -LiteralPath (Join-Path $chatty 'cmake.bat') -Encoding ASCII
        $savedPath = $env:PATH; $savedArch = $env:WINDOWS_TARGET_ARCH
        $env:PATH = "$chatty;$env:PATH"; $env:WINDOWS_TARGET_ARCH = 'amd64'
        try {
            $src = Join-Path $script:tmp 'src'; $bld = Join-Path $script:tmp 'bld'; $pfx = Join-Path $script:tmp 'pfx'
            New-Item -Path $src -ItemType Directory -Force | Out-Null
            $result = @(Invoke-HostToolCmakeBuild -SourceDir $src -BuildDir $bld -InstallPrefix $pfx -Targets @('flatc') -Label 'fake host tools' -LogName 'fake-host.log')
            Assert-Equal 1 $result.Count "one return value, no build-log lines on the pipeline: $($result -join ' | ')"
            Assert-Equal $bld $result[0] 'returns the build dir when not installing'
            $withInstall = @(Invoke-HostToolCmakeBuild -SourceDir $src -BuildDir $bld -InstallPrefix $pfx -Install -Label 'fake host tools' -LogName 'fake-host.log')
            Assert-Equal (Join-Path $pfx 'bin') $withInstall[-1] 'returns <prefix>\bin when installing'
            Assert-Equal 1 $withInstall.Count 'still exactly one value with -Install'
        } finally {
            $env:PATH = $savedPath
            if ($null -eq $savedArch) { Remove-Item Env:WINDOWS_TARGET_ARCH -ErrorAction SilentlyContinue } else { $env:WINDOWS_TARGET_ARCH = $savedArch }
        }
    }
}
