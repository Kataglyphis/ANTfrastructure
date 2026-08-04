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
    $newFakeNinja = {
        param($dir)
        $lines = @(
            '@echo off',
            'echo NINJA %* >> "%WBT_NINJA_LOG%"',
            'if "%WBT_NINJA_MODE%"=="fail" exit /b 1',
            'if exist "%WBT_NINJA_FAILONCE%" ( del "%WBT_NINJA_FAILONCE%" & exit /b 1 )',
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
