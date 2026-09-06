#requires -Version 7.0
# Tests for WindowsBuildDriver.Common.psm1 — the transient-failure classifier and
# cooldown gate behind Build-Buildkit.ps1. These failure paths previously only ever executed
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

Describe 'Invoke-TransientCooldown determinism gate' {

    # 2026-08-07: ImportLayer 0xb7 failed three times with byte-identical
    # snapshot IDs. The tail matched the transient pattern, so the engine paid
    # two retries plus cool-downs before giving up. A flake changes between
    # attempts; a poisoned snapshot does not.

    It 'refuses to retry when the failure is byte-identical to the previous one' {
        $tail = 'failed to commit 3p059m2d68o to o47dumb0ovs4 during finalize: failed to reimport snapshot: hcsshim::ImportLayer failed'
        $r = Invoke-TransientCooldown -Tail $tail -PreviousTail $tail -Attempt 1 -MaxAttempts 3 -CooldownSeconds 0 -Label 't'
        Assert-False $r 'an identical failure is deterministic, not transient'
    }

    It 'ignores buildkit timing prefixes when comparing (they differ every attempt)' {
        # buildkit prefixes each line with "#<vertex> <elapsed> " — comparing raw
        # would never match and the gate would never fire.
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

    # Two coupled defects found while the merge stage failed live (2026-08-07):
    #
    # 1. The media merge was given -MaxAttempts 5 on 2026-08-06 because
    #    'failed to mount {windows-layer}' was measured going green only on the
    #    third attempt — but that text was never in the transient pattern, so
    #    the classifier said NON-transient and the retries never fired. The
    #    raised attempt count was dead code for the failure it was raised for.
    # 2. Once the pattern matches, the determinism gate would kill exactly those
    #    retries, because the mount error names the same layer path each time.
    #    Finalize failures are the opposite: identical there means poisoned.

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
