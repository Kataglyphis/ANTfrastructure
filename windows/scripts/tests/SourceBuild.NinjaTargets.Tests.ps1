#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# -Targets must reach every ninja call of the retry ladder, or a retry silently rebuilds the whole graph.

Import-Module (Join-Path $PSScriptRoot 'WindowsSourceBuild.RetryFixtures.psm1') -Force -DisableNameChecking

$script:NewTargetNinja = New-TestBatchToolSetup -Name ninja.bat -Line @(
    'echo NINJA %* >> "%WBT_NINJA_LOG%"',
    'if exist "%WBT_NINJA_FAILONCE%" ( del "%WBT_NINJA_FAILONCE%" & exit /b 1 )'
)

Describe 'Invoke-NinjaBuildWithRetry -Targets' {

    # $Retry carries what a case adds to the shared single-job ladder.
    $runLadder = {
        param([int]$Failures, [hashtable]$Retry = @{})
        Invoke-RecordedRetryFixture -Tool ninja -ToolSetup $script:NewTargetNinja -Failures $Failures -Body {
            param($context)
            Invoke-NinjaBuildWithRetry -BuildDir $context.Dir -RetryJobs 1 -MemGBPerJob 1 -StallRetries 0 @Retry
        }
    }

    It 'passes the target list on the first invocation and on the incremental retry' {
        $fixture = & $runLadder 1 @{ Targets = @('tvm_runtime', 'tvm_ffi_shared') }
        $calls = $fixture.Calls
        Assert-Equal 2 $calls.Count 'first attempt failed, incremental retry succeeded'
        # cmd's `echo %* >>` leaves a trailing space before the redirect -- tolerate it.
        foreach ($c in $calls) { Assert-True ($c -match ' tvm_runtime tvm_ffi_shared\s*$') "every invocation carries the targets last: $c" }
    }

    It 'omits targets entirely when none are given (whole-graph build, unchanged behaviour)' {
        $fixture = & $runLadder 0
        $calls = $fixture.Calls
        Assert-Equal 1 $calls.Count
        Assert-True ($calls[0] -match "-C $([regex]::Escape($fixture.Dir))\s*$") "no trailing targets: $($calls[0])"
    }

    # A chatty fake ninja: without `| Out-Host` its lines would leak into the helper's return ahead of the path.
    It 'Invoke-HostToolCmakeBuild returns exactly the directory path, not the build output' {
        Invoke-InTestDir { param($dir)
            $chatty = Join-Path $dir 'chatty'
            $null = New-TestBatchTool -Directory $chatty -Name ninja.bat -Line @('echo ninja: Entering directory %2', 'echo [1/1] Linking fake')
            $null = New-TestBatchTool -Directory $chatty -Name cmake.bat -Line 'echo -- Configuring done (fake cmake)'
            Invoke-WithEnv @{ PATH = "$chatty;$env:PATH"; WINDOWS_TARGET_ARCH = 'amd64'; WBT_NINJA_FAILONCE = '' } {
                $src = Join-Path $dir 'src'; $bld = Join-Path $dir 'bld'; $pfx = Join-Path $dir 'pfx'
                New-Item -Path $src -ItemType Directory -Force | Out-Null
                $result = @(Invoke-HostToolCmakeBuild -SourceDir $src -BuildDir $bld -InstallPrefix $pfx -Targets @('flatc') -Label 'fake host tools' -LogName 'fake-host.log')
                Assert-Equal 1 $result.Count "one return value, no build-log lines on the pipeline: $($result -join ' | ')"
                Assert-Equal $bld $result[0] 'returns the build dir when not installing'
                $withInstall = @(Invoke-HostToolCmakeBuild -SourceDir $src -BuildDir $bld -InstallPrefix $pfx -Install -Label 'fake host tools' -LogName 'fake-host.log')
                Assert-Equal (Join-Path $pfx 'bin') $withInstall[-1] 'returns <prefix>\bin when installing'
                Assert-Equal 1 $withInstall.Count 'still exactly one value with -Install'
            }
        }
    }
}
