# Tests for WindowsBuildDriver.Common.psm1 — the classic-lane retry engine
# extracted from build.ps1. These failure paths previously only ever executed
# during real multi-hour builds; a regression here silently changes when hours
# of compile work get retried, preserved, or thrown away.

Describe 'Test-TransientDockerFailure' {

    It 'classifies the known container-infrastructure signatures as transient' {
        foreach ($sig in @(
                'failed to create shim task: ttrpc: closed',
                'hcsshim::ActivateLayer failed in Win32',
                'error during connect: open //./pipe/docker_engine',
                'failed to create task for container xyz')) {
            Assert-True (Test-TransientDockerFailure -Tail $sig) "'$sig' must classify transient"
        }
    }

    It 'does NOT classify compile errors or empty tails as transient' {
        Assert-False (Test-TransientDockerFailure -Tail 'error C2039: no member named foo') 'compiler error is not transient'
        Assert-False (Test-TransientDockerFailure -Tail 'lld-link: error: undefined symbol') 'link error is not transient'
        Assert-False (Test-TransientDockerFailure -Tail '') 'empty tail is not transient'
    }
}

Describe 'Invoke-TransientCooldown' {

    It 'returns $false when no retry remains, even for a transient tail' {
        $r = Invoke-TransientCooldown -Tail 'ttrpc: closed' -Attempt 3 -MaxAttempts 3 -CooldownSeconds 0
        Assert-False $r 'attempt == max must not retry'
    }

    It '-AssumeTransient retries a tail the classifier would reject' {
        $r = Invoke-TransientCooldown -Tail 'error C2039' -Attempt 1 -MaxAttempts 3 -CooldownSeconds 0 -AssumeTransient
        Assert-True $r 'caller-side classification must win'
        $r2 = Invoke-TransientCooldown -Tail 'error C2039' -Attempt 1 -MaxAttempts 3 -CooldownSeconds 0
        Assert-False $r2 'without -AssumeTransient the classifier decides'
    }
}

Describe 'Invoke-DockerWithRetry' {

    It 'runs OnSuccess exactly once on a first-try success and never the failure hooks' {
        Invoke-InTestDir { param($dir)
            $calls = @{ action = 0; success = 0; failed = 0; final = 0 }
            Invoke-DockerWithRetry -Label 't' -MaxAttempts 3 -CooldownSeconds 0 `
                -Action { param($a) $calls.action++; & cmd /c "exit 0" }.GetNewClosure() `
                -OnSuccess { $calls.success++ }.GetNewClosure() `
                -OnFailedAttempt { $calls.failed++ }.GetNewClosure() `
                -OnFinalFailure { $calls.final++ }.GetNewClosure()
            Assert-Equal 1 $calls.action 'action ran once'
            Assert-Equal 1 $calls.success 'success hook ran once'
            Assert-Equal 0 $calls.failed 'no per-attempt cleanup on success'
            Assert-Equal 0 $calls.final 'no final-failure hook on success'
        }
    }

    It 'retries a transient failure (running OnFailedAttempt) and succeeds on the next attempt' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'run.log'
            Set-Content $log 'failed to create shim task: ttrpc: closed'
            $calls = @{ action = 0; success = 0; failed = 0; final = 0 }
            Invoke-DockerWithRetry -Label 't' -MaxAttempts 3 -CooldownSeconds 0 -LogFile $log `
                -Action { param($a) $calls.action++; if ($a -lt 2) { & cmd /c "exit 1" } else { & cmd /c "exit 0" } }.GetNewClosure() `
                -OnSuccess { $calls.success++ }.GetNewClosure() `
                -OnFailedAttempt { $calls.failed++ }.GetNewClosure() `
                -OnFinalFailure { $calls.final++ }.GetNewClosure()
            Assert-Equal 2 $calls.action 'action ran twice (fail + success)'
            Assert-Equal 1 $calls.failed 'per-attempt cleanup ran before the retry'
            Assert-Equal 1 $calls.success 'success hook ran after the retry'
            Assert-Equal 0 $calls.final 'no final-failure hook'
        }
    }

    It 'a NON-transient failure throws immediately with OnFinalFailure but WITHOUT OnFailedAttempt (container preservation invariant)' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'run.log'
            Set-Content $log 'lld-link: error: undefined symbol: main'
            $calls = @{ action = 0; failed = 0; final = 0 }
            # Hooks are closed over HERE (test scope) — nesting .GetNewClosure()
            # inside an already-closured outer block silently drops the outer
            # closure's variables (the hooks would mutate a $null $calls).
            $action   = { param($a) $calls.action++; & cmd /c "exit 1" }.GetNewClosure()
            $onFailed = { $calls.failed++ }.GetNewClosure()
            $onFinal  = { $calls.final++ }.GetNewClosure()
            Assert-Throws {
                Invoke-DockerWithRetry -Label 't' -MaxAttempts 3 -CooldownSeconds 0 -LogFile $log `
                    -Action $action -OnFailedAttempt $onFailed -OnFinalFailure $onFinal
            }.GetNewClosure() 'non-transient must throw'
            Assert-Equal 1 $calls.action 'no retry on a non-transient failure'
            Assert-Equal 0 $calls.failed 'per-attempt cleanup must NOT run on the final failure (it would delete the preserved container)'
            Assert-Equal 1 $calls.final 'final-failure hook ran once'
        }
    }

    It 'exhausting MaxAttempts on transient failures ends with OnFinalFailure + throw' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'run.log'
            Set-Content $log 'hcsshim::ActivateLayer failed'
            $calls = @{ action = 0; failed = 0; final = 0 }
            $action   = { param($a) $calls.action++; & cmd /c "exit 1" }.GetNewClosure()
            $onFailed = { $calls.failed++ }.GetNewClosure()
            $onFinal  = { $calls.final++ }.GetNewClosure()
            Assert-Throws {
                Invoke-DockerWithRetry -Label 't' -MaxAttempts 2 -CooldownSeconds 0 -LogFile $log `
                    -Action $action -OnFailedAttempt $onFailed -OnFinalFailure $onFinal
            }.GetNewClosure() 'exhaustion must throw'
            Assert-Equal 2 $calls.action 'ran MaxAttempts times'
            Assert-Equal 1 $calls.failed 'cleanup ran only before the actual retry, not on the final attempt'
            Assert-Equal 1 $calls.final 'final-failure hook ran once'
        }
    }
}

Describe 'Get-DockerBuildArgList' {

    It 'shapes the arg list deterministically: sorted build-args, isolation flag, tail order' {
        Initialize-BuildDriverContext -Docker 'docker.exe' -LogDir $env:TEMP
        Set-BuildDriverIsolation -Isolation 'hyperv'
        $argList = Get-DockerBuildArgList -Dockerfile 'windows/Dockerfile.base' -Tag 't:1' `
            -BuildArgs @{ ZED = '2'; ALPHA = '1'; EMPTY = ''; NULLED = $null } -ExtraFlags @('--target', 'x')
        $joined = $argList -join ' '
        Assert-Equal 'build' $argList[0] 'starts with build'
        Assert-Match '--isolation hyperv' $joined 'isolation from context'
        Assert-True ($joined.IndexOf('ALPHA=1') -lt $joined.IndexOf('ZED=2')) 'build-args sorted (cache-key stability)'
        Assert-False ($joined -match 'EMPTY=|NULLED=') 'empty/null build-args are dropped'
        Assert-Match '--target x -t t:1 -f windows/Dockerfile.base \.$' $joined 'extra flags then -t/-f/context tail'
    }
}
