#requires -Version 7.0
# Phases are script-level try/catch brackets that must not eat cross-phase variables, or every phase-split script breaks.

Describe 'Build phase machinery (#109)' {

    It 'is scope-transparent: a variable set inside a phase is visible after it' {
        $p = Start-BuildPhase 'set-state' 6>$null
        try {
            $crossPhase = 'survived'
        } catch { Complete-BuildPhase $p -ErrorRecord $_ 6>$null; throw }
        Complete-BuildPhase $p 6>$null
        Assert-Equal 'survived' $crossPhase 'try/catch phases must not open a variable scope'
    }

    It 'stamps timing on completion and reports ok in the summary' {
        $p = Start-BuildPhase 'timed' 6>$null
        Complete-BuildPhase $p 6>$null
        Assert-True ($p.Seconds -ge 0) 'Seconds stamped'
        Assert-Equal $false $p.Failed 'clean completion is not failed'
        $out = Write-BuildPhaseSummary -Label 't' 6>&1 | Out-String
        Assert-Match 'timed' $out 'summary names the phase'
        Assert-Match '\[ ok \]' $out 'summary marks it ok'
    }

    It 'marks a failed phase and keeps the original error flowing' {
        $p = Start-BuildPhase 'doomed' 6>$null
        $thrown = $null
        try {
            try {
                throw 'phase-body error'
            } catch { Complete-BuildPhase $p -ErrorRecord $_ 6>$null; throw }
        } catch { $thrown = $_ }
        Assert-True ($null -ne $thrown) 'the original error still propagates'
        Assert-Match 'phase-body error' $thrown.Exception.Message 'error message preserved'
        Assert-Equal $true $p.Failed 'phase marked failed'
        $out = Write-BuildPhaseSummary 6>&1 | Out-String
        Assert-Match '\[FAIL\] doomed' $out 'summary marks the failure'
    }

    It 'summary resets the table (a second summary is empty)' {
        $p = Start-BuildPhase 'once' 6>$null
        Complete-BuildPhase $p 6>$null
        $null = Write-BuildPhaseSummary 6>&1
        $out = Write-BuildPhaseSummary 6>&1 | Out-String
        Assert-False ($out -match 'once') 'the table was reset after the first summary'
    }

    It 'Switch-BuildPhase auto-completes the tracked phase; Complete-CurrentBuildPhase is a safe no-op after' {
        Switch-BuildPhase 'first' 6>$null
        Switch-BuildPhase 'second' 6>$null            # must complete 'first' itself
        Complete-CurrentBuildPhase 6>$null            # closes 'second'
        Complete-CurrentBuildPhase 6>$null            # idempotent: nothing open, must not throw
        $out = Write-BuildPhaseSummary -Label 'switch' 6>&1 | Out-String
        Assert-Match '\[ ok \] first' $out 'first phase completed by the switch'
        Assert-Match '\[ ok \] second' $out 'second phase completed by Complete-CurrentBuildPhase'
    }

    It 'Complete-CurrentBuildPhase -ErrorRecord stamps the tracked phase as failed' {
        Switch-BuildPhase 'doomed-current' 6>$null
        try { throw 'current-phase error' } catch { Complete-CurrentBuildPhase -ErrorRecord $_ 6>$null }
        $out = Write-BuildPhaseSummary 6>&1 | Out-String
        Assert-Match '\[FAIL\] doomed-current' $out 'tracked phase stamped failed'
    }

    It 'summarizes the failed phase before the caller rethrows' {
        $failure = $null
        $output = ''
        try {
            Switch-BuildPhase 'source phase' 6>$null
            try { throw 'source phase failure' } catch {
                $output = Complete-SourceBuildFailure -Label 'source-builder' -ErrorRecord $_ 6>&1 | Out-String
                throw
            }
        } catch { $failure = $_ }
        Assert-Match 'PHASE FAILED: source phase' $output 'phase is marked failed before the summary'
        Assert-Match 'phase summary \(source-builder\)' $output 'summary keeps the caller label'
        Assert-Match '\[FAIL\] source phase' $output 'summary contains the failed phase'
        Assert-Match 'source phase failure' $failure.Exception.Message 'caller rethrows the original error'
    }

    It 'mutation control catches a missing source-build failure summary' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsSourceBuild.Common.psm1' `
            -FunctionName Start-BuildPhase, Switch-BuildPhase, Complete-BuildPhase, Complete-CurrentBuildPhase, Complete-SourceBuildFailure, Write-BuildPhaseSummary `
            -Find 'Write-BuildPhaseSummary -Label $Label' -Replace '' -Expected 'failure summary includes its caller label' -IncludeControl -Body {
                Switch-MutBuildPhase 'mutation phase' 6>$null
                $errorRecord = $null
                try { throw 'phase failure' } catch { $errorRecord = $_ }
                $output = Complete-MutSourceBuildFailure -Label 'source-builder' -ErrorRecord $errorRecord 6>&1 | Out-String
                Assert-Match 'phase summary \(source-builder\)' $output 'failure summary includes its caller label'
            }
    }
}
