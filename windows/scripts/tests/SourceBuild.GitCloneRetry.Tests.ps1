#requires -Version 7.0
# Tests for Invoke-GitClone's retry (WindowsSourceBuild.Common.psm1, #116) —
# one TCP drop (curl 18 at 610 s of the LiteRT clone) killed a 4-hour ride
# because the driver correctly does not infra-retry script failures. A fake
# git.bat on PATH (same pattern as the NinjaRetry tests) drives every path;
# each invocation is appended to a log file so the attempt COUNT is asserted,
# and the partial-tree case proves Reset-SourceBuildDirectory wipes leftovers
# between attempts. InitialDelaySeconds 0 keeps the suite sleep-free.

Describe 'Invoke-GitClone retry' {

    # Behavior is steered per-case via env:
    #   WBT_GIT_LOG      — file every invocation appends its arguments to
    #   WBT_GIT_MODE     — 'fail' = always exit 128
    #   WBT_GIT_FAILONCE — marker file: if present, delete it, leave a PARTIAL
    #                      tree in the target and exit 128 (transient drop)
    #   WBT_GIT_TARGET   — the clone target dir the fake writes into
    $newFakeGit = {
        param($dir)
        $lines = @(
            '@echo off',
            'echo GIT %* >> "%WBT_GIT_LOG%"',
            'if "%WBT_GIT_MODE%"=="fail" exit /b 128',
            'if exist "%WBT_GIT_FAILONCE%" ( del "%WBT_GIT_FAILONCE%" & mkdir "%WBT_GIT_TARGET%" 2>nul & echo partial > "%WBT_GIT_TARGET%\partial.txt" & exit /b 128 )',
            'mkdir "%WBT_GIT_TARGET%" 2>nul',
            'echo ok > "%WBT_GIT_TARGET%\cloned.txt"',
            'exit /b 0'
        )
        Set-Content -LiteralPath (Join-Path $dir 'git.bat') -Value ($lines -join "`r`n") -Encoding ASCII
    }

    It 'succeeds first try with exactly one git invocation' {
        Invoke-InTestDir { param($dir)
            & $newFakeGit $dir
            $log = Join-Path $dir 'git.log'
            $target = Join-Path $dir 'src'
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_GIT_LOG = $log; WBT_GIT_MODE = ''
                WBT_GIT_FAILONCE = ''; WBT_GIT_TARGET = $target
            } {
                $r = Invoke-GitClone -RepoUrl 'https://example.invalid/repo.git' -SourceDir $target -Branch 'main' -InitialDelaySeconds 0
                Assert-Equal $true $r 'green clone returns $true'
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 1 $calls.Count 'exactly one git invocation on a green clone'
            Assert-Match '^GIT clone --branch main ' $calls[0] 'ref and shape forwarded'
        }
    }

    It 'retries a transient failure once and wipes the partial tree between attempts' {
        Invoke-InTestDir { param($dir)
            & $newFakeGit $dir
            $log = Join-Path $dir 'git.log'
            $target = Join-Path $dir 'src'
            $failOnce = Join-Path $dir 'fail-once.marker'
            Set-Content -LiteralPath $failOnce -Value 'x' -Encoding ASCII
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_GIT_LOG = $log; WBT_GIT_MODE = ''
                WBT_GIT_FAILONCE = $failOnce; WBT_GIT_TARGET = $target
            } {
                $r = Invoke-GitClone -RepoUrl 'https://example.invalid/repo.git' -SourceDir $target -Branch 'main' -InitialDelaySeconds 0 3>$null
                Assert-Equal $true $r 'recovers on the second attempt'
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $calls.Count 'failed attempt + one retry'
            Assert-Equal $false (Test-Path (Join-Path $target 'partial.txt')) 'partial tree from the failed attempt was wiped before the retry'
            Assert-Equal $true (Test-Path (Join-Path $target 'cloned.txt')) 'the retry produced the clone'
        }
    }

    It 'throws after MaxAttempts with the attempt count in the message' {
        Invoke-InTestDir { param($dir)
            & $newFakeGit $dir
            $log = Join-Path $dir 'git.log'
            $target = Join-Path $dir 'src'
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_GIT_LOG = $log; WBT_GIT_MODE = 'fail'
                WBT_GIT_FAILONCE = ''; WBT_GIT_TARGET = $target
            } {
                Assert-Throws { Invoke-GitClone -RepoUrl 'https://example.invalid/repo.git' -SourceDir $target -Branch 'main' -MaxAttempts 3 -InitialDelaySeconds 0 3>$null } `
                    -MessagePattern 'after 3 attempts' `
                    'a persistent failure must throw, naming the attempt count'
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 3 $calls.Count 'exactly MaxAttempts invocations'
        }
    }

    It 'returns $false (no throw) after MaxAttempts with -SkipOnFailure' {
        Invoke-InTestDir { param($dir)
            & $newFakeGit $dir
            $log = Join-Path $dir 'git.log'
            $target = Join-Path $dir 'src'
            Invoke-WithEnv @{
                PATH = "$dir;$env:PATH"; WBT_GIT_LOG = $log; WBT_GIT_MODE = 'fail'
                WBT_GIT_FAILONCE = ''; WBT_GIT_TARGET = $target
            } {
                $r = Invoke-GitClone -RepoUrl 'https://example.invalid/repo.git' -SourceDir $target -Branch 'main' -MaxAttempts 2 -InitialDelaySeconds 0 -SkipOnFailure 3>$null
                Assert-Equal $false $r 'SkipOnFailure degrades a persistent failure to $false'
            }.GetNewClosure()
            $calls = @(Get-Content -LiteralPath $log)
            Assert-Equal 2 $calls.Count 'SkipOnFailure still exhausts the attempts first'
        }
    }
}
