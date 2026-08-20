#requires -Version 7.0
# Tests for the #109 build-phase machinery (Start-/Complete-BuildPhase,
# Write-BuildPhaseSummary). The load-bearing property is SCOPE TRANSPARENCY:
# phases are try/catch brackets at script level, and try/catch must not eat
# cross-phase variable state - a regression here silently breaks every
# phase-split monolith at once.

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
}
