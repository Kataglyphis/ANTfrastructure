#requires -Version 7.0
# The BK retry classifier and cooldown otherwise run only in real builds, where a regression decides which hours are thrown away.

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

Describe 'Invoke-TransientCooldown determinism gate' {

    # A flake changes between attempts; a poisoned snapshot fails with byte-identical IDs.

    It 'refuses to retry when the failure is byte-identical to the previous one' {
        $tail = 'failed to commit 3p059m2d68o to o47dumb0ovs4 during finalize: failed to reimport snapshot: hcsshim::ImportLayer failed'
        $r = Invoke-TransientCooldown -Tail $tail -PreviousTail $tail -Attempt 1 -MaxAttempts 3 -CooldownSeconds 0 -Label 't'
        Assert-False $r 'an identical failure is deterministic, not transient'
    }

    It 'ignores buildkit timing prefixes when comparing (they differ every attempt)' {
        # buildkit prefixes each line with "#<vertex> <elapsed> ", so raw lines would never compare equal.
        $a = "#9 627.3 failed to reimport snapshot: hcsshim::ImportLayer failed"
        $b = "#9 1841.7 failed to reimport snapshot: hcsshim::ImportLayer failed"
        $r = Invoke-TransientCooldown -Tail $b -PreviousTail $a -Attempt 1 -MaxAttempts 3 -CooldownSeconds 0 -Label 't'
        Assert-False $r 'same failure with different elapsed times must still count as identical'
    }

    It 'still retries when the failure CHANGED between attempts (a real flake)' {
        $a = 'ttrpc: closed'
        $b = 'failed to create shim task'
        $r = Invoke-TransientCooldown -Tail $b -PreviousTail $a -Attempt 1 -MaxAttempts 3 -CooldownSeconds 0 -Label 't'
        Assert-True $r 'a differing transient tail must still be retried'
    }

    It 'behaves exactly as before when no previous tail is supplied' {
        # Back-compat: every existing call site passes no -PreviousTail.
        $r = Invoke-TransientCooldown -Tail 'ttrpc: closed' -Attempt 1 -MaxAttempts 3 -CooldownSeconds 0 -Label 't'
        Assert-True $r 'the gate must not change the classic behaviour'
    }
}

Describe 'Mount contention: classified transient AND exempt from the determinism gate' {

    # A mount failure is transient yet names the same layer every time; for finalize failures identical means poisoned.

    It 'classifies a windows-layer mount failure as transient' {
        Initialize-BuildDriverContext `
            -TransientPattern 'failed to mount \{windows-layer|failed to calculate checksum of ref'
        $tail = 'ERROR: failed to calculate checksum of ref abc::def: failed to mount {windows-layer C:\ProgramData\containerd\...}'
        Assert-True (Test-TransientDockerFailure -Tail $tail) 'mount contention must be retryable'
    }

    It 'retries mount contention even when the tail repeats verbatim' {
        $tail = 'failed to mount {windows-layer C:\ProgramData\containerd\root\...\snapshots\2039 [ro parentLayerPaths=...]}'
        $r = Invoke-TransientCooldown -Tail $tail -PreviousTail $tail -Attempt 1 -MaxAttempts 5 `
            -CooldownSeconds 0 -Label 't' -AssumeTransient
        Assert-True $r 'the determinism gate must not veto snapshot-mount contention'
    }

    It 'still vetoes an identical FINALIZE failure (the poisoned-snapshot case)' {
        $tail = 'failed to commit abc to def during finalize: failed to reimport snapshot: hcsshim::ImportLayer failed'
        $r = Invoke-TransientCooldown -Tail $tail -PreviousTail $tail -Attempt 1 -MaxAttempts 5 `
            -CooldownSeconds 0 -Label 't' -AssumeTransient
        Assert-False $r 'an identical finalize failure is deterministic and must not be retried'
    }
}
