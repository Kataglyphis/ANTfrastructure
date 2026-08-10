# Tests for Invoke-NinjaBuildWithRetry (WindowsSourceBuild.Common.psm1) — the
# OOM-shaped compile retry: a failed `ninja -j<N>` is re-run incrementally with
# -j<RetryJobs> before giving up. A regression here either retries a doomed
# build at full parallelism (re-OOMing for hours) or throws away a build that a
# -j1 pass would have finished. A fake ninja.bat on PATH (same pattern as the
# Pip tests) drives every path; BUILD_JOBS pins the first-attempt job count so
# the case matrix is host-independent. Each invocation is appended to a log
# file, so attempt COUNT and the exact -j values are both asserted.

Describe 'Invoke-NinjaBuildWithRetry' {

    # Writes the fake ninja.bat into $dir. Behavior is steered per-case via env:
    #   WBT_NINJA_LOG      — file every invocation appends its arguments to
    #   WBT_NINJA_MODE     — 'fail' = always exit 1
    #   WBT_NINJA_FAILONCE — marker file: if present, delete it and exit 1 (so
    #                        the FIRST call fails and the retry succeeds)
    #   WBT_NINJA_STALLMARK — when set, every FAILING invocation also appends a
    #                         line to this file (simulates a stall-guard kill
    #                         recorded during the attempt)
    $newFakeNinja = {
        param($dir)
        $lines = @(
            '@echo off',
            'echo NINJA %* >> "%WBT_NINJA_LOG%"',
            'if "%WBT_NINJA_MODE%"=="fail" ( if not "%WBT_NINJA_STALLMARK%"=="" echo kill >> "%WBT_NINJA_STALLMARK%" ) & if "%WBT_NINJA_MODE%"=="fail" exit /b 1',
            'if exist "%WBT_NINJA_FAILONCE%" ( del "%WBT_NINJA_FAILONCE%" & ( if not "%WBT_NINJA_STALLMARK%"=="" echo kill >> "%WBT_NINJA_STALLMARK%" ) & exit /b 1 )',
            'exit /b 0'
        )
        Set-Content -LiteralPath (Join-Path $dir 'ninja.bat') -Value ($lines -join "`r`n") -Encoding ASCII
    }

    It 'succeeds first try at the full job count and never retries' {
        Invoke-InTestDir { param($dir)
            & $newFakeNinja $dir
            $log = Join-Path $dir 'ninja.log'
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_NINJA_LOG = $log; WBT_NINJA_MODE = ''
                WBT_NINJA_FAILONCE = ''; BUILD_JOBS = '4'; NINJA_KEEP_GOING = ''; NINJA_STATUS = ''
            } {
                Invoke-NinjaBuildWithRetry -BuildDir $dir -RetryJobs 1
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 1 $calls.Count 'exactly one ninja invocation on a green build'
            Assert-Match '^NINJA -j 4 ' $calls[0] 'first attempt uses the full BUILD_JOBS count'
        }
    }

    It 'retries a failed build once with -j<RetryJobs> and succeeds' {
        Invoke-InTestDir { param($dir)
            & $newFakeNinja $dir
            $log = Join-Path $dir 'ninja.log'
            $failOnce = Join-Path $dir 'fail-once.marker'
            Set-Content -LiteralPath $failOnce -Value 'x' -Encoding ASCII
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_NINJA_LOG = $log; WBT_NINJA_MODE = ''
                WBT_NINJA_FAILONCE = $failOnce; BUILD_JOBS = '4'; NINJA_KEEP_GOING = ''; NINJA_STATUS = ''
            } {
                Invoke-NinjaBuildWithRetry -BuildDir $dir -RetryJobs 2
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $calls.Count 'failed attempt + one incremental retry'
            Assert-Match '^NINJA -j 4 ' $calls[0] 'first attempt at full parallelism'
            Assert-Match '^NINJA -j 2 ' $calls[1] 'the retry used exactly -j<RetryJobs>'
        }
    }

    It 'throws after the reduced-job retry also fails (exit code in the message)' {
        Invoke-InTestDir { param($dir)
            & $newFakeNinja $dir
            $log = Join-Path $dir 'ninja.log'
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_NINJA_LOG = $log; WBT_NINJA_MODE = 'fail'
                WBT_NINJA_FAILONCE = ''; BUILD_JOBS = '4'; NINJA_KEEP_GOING = ''; NINJA_STATUS = ''
            } {
                Assert-Throws { Invoke-NinjaBuildWithRetry -BuildDir $dir -RetryJobs 1 } `
                    -MessagePattern 'Build failed \(exit 1\)' `
                    'a fail-fail sequence must throw with the native exit code'
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $calls.Count 'full attempt + reduced retry, then give up'
            Assert-Match '^NINJA -j 1 ' $calls[1] 'the final attempt was the reduced one'
        }
    }

    It 'retries a guard-kill failure at FULL -j, not -j<RetryJobs> (run-6 lesson)' {
        Invoke-InTestDir { param($dir)
            & $newFakeNinja $dir
            $log = Join-Path $dir 'ninja.log'
            $failOnce = Join-Path $dir 'fail-once.marker'
            $stallMark = Join-Path $dir 'stall.marker'
            Set-Content -LiteralPath $failOnce -Value 'x' -Encoding ASCII
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_NINJA_LOG = $log; WBT_NINJA_MODE = ''
                WBT_NINJA_FAILONCE = $failOnce; WBT_NINJA_STALLMARK = $stallMark
                BUILD_JOBS = '4'; NINJA_KEEP_GOING = ''; NINJA_STATUS = ''
            } {
                Invoke-NinjaBuildWithRetry -BuildDir $dir -RetryJobs 2 -StallMarkerPath $stallMark
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $calls.Count 'guard-kill attempt + ONE full-speed retry'
            Assert-Match '^NINJA -j 4 ' $calls[1] 'the stall retry must stay at full parallelism (L0 hits), never drop to -j<RetryJobs>'
        }
    }

    It 'bounds stall retries, then falls through to the incremental attempt, then throws' {
        Invoke-InTestDir { param($dir)
            & $newFakeNinja $dir
            $log = Join-Path $dir 'ninja.log'
            $stallMark = Join-Path $dir 'stall.marker'
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_NINJA_LOG = $log; WBT_NINJA_MODE = 'fail'
                WBT_NINJA_FAILONCE = ''; WBT_NINJA_STALLMARK = $stallMark
                BUILD_JOBS = '4'; NINJA_KEEP_GOING = ''; NINJA_STATUS = ''
            } {
                Assert-Throws { Invoke-NinjaBuildWithRetry -BuildDir $dir -RetryJobs 1 -StallRetries 3 -StallMarkerPath $stallMark } `
                    -MessagePattern 'Build failed \(exit 1\)'
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 5 $calls.Count 'first attempt + 3 bounded stall retries + 1 incremental attempt'
            Assert-Match '^NINJA -j 4 ' $calls[3] 'stall retries stay at full -j'
            Assert-Match '^NINJA -j 1 ' $calls[4] 'the last resort is the incremental -j<RetryJobs> attempt'
        }
    }

    It 'does NOT retry when the job count is already <= RetryJobs' {
        Invoke-InTestDir { param($dir)
            & $newFakeNinja $dir
            $log = Join-Path $dir 'ninja.log'
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_NINJA_LOG = $log; WBT_NINJA_MODE = 'fail'
                WBT_NINJA_FAILONCE = ''; BUILD_JOBS = '2'; NINJA_KEEP_GOING = ''; NINJA_STATUS = ''
            } {
                Assert-Throws { Invoke-NinjaBuildWithRetry -BuildDir $dir -RetryJobs 2 } `
                    -MessagePattern 'Build failed \(exit 1\)' `
                    'jobs == RetryJobs must fail without a pointless identical retry'
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 1 $calls.Count 'no retry: rerunning at the same -j cannot help an OOM'
        }
    }
}
