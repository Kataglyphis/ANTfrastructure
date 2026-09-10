#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The THIRD BUCKET on the Windows half: Add-BuildGateSkip and
# Assert-BuildGates -TolerateSkips, the twin of gate_skip / assert_gates
# --tolerate-skips in linux/scripts/01-core/gates.sh. The assertions are that an
# unrunnable gate is RECORDED, that recording it is red until a call site asks
# for tolerance in writing, and that tolerance never leaks into the other two
# buckets. The last case MEASURES the one place the two halves deliberately
# differ, rather than trusting the doc's word for it.
# docs/shared-script-libraries.md#gate-aggregation-01-coregatessh

$script:GateModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsBuild.Common.psm1'
# Un-Forced on purpose (repo rule, 2026-08-04): -Force in a harness suite
# unloads a module the runner's other imports are already bound to -- one such
# import silently dropped 104 assertions on 2026-08-28.
Import-Module $script:GateModule -DisableNameChecking

# One owner for the throwaway directory both fixtures below need.
function script:New-ScratchDir {
    param([Parameter(Mandatory)][string]$Prefix)
    $dir = Join-Path $env:TEMP ($Prefix + '-' + (Get-Random))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# A build context with its log writer OPEN, so the messages a gate emits can be
# read back and asserted on; SuppressConsoleOutput keeps the suite readable.
function script:New-GateContext {
    $dir = New-ScratchDir -Prefix 'gatebucket'
    $ctx = New-BuildContext -Workspace $dir -LogDir $dir
    $ctx.SuppressConsoleOutput = $true
    Open-BuildLog -Context $ctx
    return $ctx
}

# Closes the writer first: an un-flushed StreamWriter reads back short, which
# would make every log assertion below fail for the wrong reason.
function script:Get-GateLog {
    param([Parameter(Mandatory)][pscustomobject]$Context)
    Close-BuildLog -Context $Context
    return ('' + (Get-Content -Raw -LiteralPath $Context.LogPath))
}

# One owner for "this batch must be refused, and the refusal must say WHY":
# four cases below differ only in the batch they build and the phrase the throw
# has to carry, and the duplication gate caught the copies.
function script:Assert-BatchRefused {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Because,
        [switch]$TolerateSkips
    )
    Assert-Throws -MessagePattern $Pattern -Message $Because -Body {
        Assert-BuildGates -Context $Context -Label 'T' -TolerateSkips:$TolerateSkips
    }
}

# The batch the tolerance cases all need: one gate that RAN, one that could not.
# Second owner the dupes gate asked for, same reason as Assert-BatchRefused.
function script:New-SkippedBatch {
    $ctx = New-GateContext
    Invoke-BuildGate -Context $ctx -Name 'ran' -Script { } | Out-Null
    Add-BuildGateSkip -Context $ctx -Name 'missing-tool' -Reason 'no such binary' | Out-Null
    return $ctx
}

Describe 'WindowsBuild.Common gates: the third bucket' {

    It 'Add-BuildGateSkip records the gate and its reason, and grades nothing' {
        $ctx = New-GateContext
        Add-BuildGateSkip -Context $ctx -Name 'clang-tidy' -Reason 'not installed on this runner'
        Assert-Equal 'clang-tidy' ($ctx.Results['GateSkips'] -join ',')
        Assert-Equal 0 $ctx.Results['Gates'].Count `
            'counting a skip as a gate that RAN makes a batch of nothing but skips green'
        Assert-Match 'clang-tidy: SKIPPED \(not installed on this runner\)' (Get-GateLog -Context $ctx) `
            'a skip without its reason reads the same as a gate somebody quietly deleted'
    }

    It 'the reason is optional, and the buckets appear only on first use' {
        $ctx = New-GateContext
        Assert-False $ctx.Results.ContainsKey('GateSkips') `
            'a context that never used a gate must not look like a batch that started'
        Add-BuildGateSkip -Context $ctx -Name 'bare'
        Assert-Equal 'bare' ($ctx.Results['GateSkips'] -join ',')
        Assert-Match 'bare: SKIPPED ==' (Get-GateLog -Context $ctx)
    }

    It 'a skip is RED by default, and the throw names the gate AND the switch' {
        $ctx = New-SkippedBatch
        Assert-BatchRefused -Context $ctx -Pattern 'missing-tool' `
            -Because 'a silently tolerated skip is the "allowed to fail" default the fleet rule forbids'
        Assert-BatchRefused -Context $ctx -Pattern '\-TolerateSkips' `
            -Because 'without the switch named, the only visible way out of the red is to delete the gate'
    }

    It '-TolerateSkips is what makes that same batch green' {
        $ctx = New-SkippedBatch
        Assert-BuildGates -Context $ctx -Label 'T' -TolerateSkips
        Assert-Match 'T OK \(1 gate\(s\), 1 skipped\)' (Get-GateLog -Context $ctx) `
            'a tolerated skip is still printed: tolerated is not the same as invisible'
    }

    It '-TolerateSkips reaches the skip bucket and nothing else' {
        # The two batches it must still refuse. Kept in one case because the
        # duplication gate is right that they are the same four lines twice.
        $only = New-GateContext
        foreach ($absent in 'one', 'two') {
            Add-BuildGateSkip -Context $only -Name $absent -Reason 'absent'
        }
        Assert-BatchRefused -Context $only -TolerateSkips -Pattern 'no gate ran - all 2 were skipped' `
            -Because 'nothing was graded, so there is no result to tolerate: vacuity outranks the switch'

        $mixed = New-GateContext
        Invoke-BuildGate -Context $mixed -Name 'broken' -Script { throw 'nope' }
        Add-BuildGateSkip -Context $mixed -Name 'absent' -Reason 'no binary'
        Assert-BatchRefused -Context $mixed -TolerateSkips -Pattern 'T FAILED \(1 of 1\): broken' `
            -Because 'one switch covering both buckets makes a missing tool a way to pass a failing one'
    }

    It 'an empty batch is still red, and does not blame a skip for it' {
        $ctx = New-GateContext
        Assert-BatchRefused -Context $ctx -Pattern 'refusing to report green over nothing' `
            -Because 'an aggregator that graded nothing reporting OK is the hazard, not an edge case'
    }

    It 'a gate that THROWS is contained, and the gates after it still run' {
        $ctx = New-GateContext
        Invoke-BuildGate -Context $ctx -Name 'before' -Script { }
        Invoke-BuildGate -Context $ctx -Name 'erring' -Script { throw 'helper says no' }
        Invoke-BuildGate -Context $ctx -Name 'after'  -Script { }
        Assert-Equal 'before,erring,after' ($ctx.Results['Gates'] -join ',') `
            'stopping at the first failure costs one push per finding'
        Assert-Equal 'erring' ($ctx.Results['GateFailures'] -join ',')
        Assert-BatchRefused -Context $ctx -Pattern 'T FAILED \(1 of 3\): erring' `
            -Because 'the verdict must be REACHED and must still name the one gate that failed'
    }
}

Describe 'gate aggregation: the two halves, and the one place they differ' {

    It 'both halves REFUSE a skip by default and both spell the opt-out' {
        $ps = Get-Content -Raw -LiteralPath $script:GateModule
        Assert-Match '\[switch\]\$TolerateSkips' $ps `
            'a [switch] is false unless passed, and that IS the inverted default'
        Assert-Match 'not tolerated here' $ps
        $sh = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\gates.sh')
        Assert-Match 'tolerate_skips=0' $sh `
            'the shell half defaulting to 1 would leave the two halves disagreeing on the only thing that matters here'
        Assert-Match '\-\-tolerate-skips' $sh
    }

    It 'MEASURED: a gate that calls exit kills the PowerShell driver' {
        # run_gate wraps its command in a SUBSHELL because bash check helpers
        # report failure with err(), which is `exit 1`. PowerShell has no
        # in-process twin for that containment: `&` and ScriptBlock.Invoke()
        # both let `exit` terminate the whole script, and a child runspace would
        # break every closure a gate scriptblock relies on. So the contract on
        # this half is that a gate reports failure by THROWING -- which the case
        # above proves is contained. This one measures the rest of the sentence,
        # so the asymmetry recorded in the doc is a fact, not an assumption.
        $dir = New-ScratchDir -Prefix 'gate-exit'
        $driver = Join-Path $dir 'driver.ps1'
        $body = @"
Import-Module '$script:GateModule' -DisableNameChecking
`$ctx = New-BuildContext -Workspace '$dir' -LogDir '$dir'
`$ctx.SuppressConsoleOutput = `$true
Invoke-BuildGate -Context `$ctx -Name 'before'  -Script { }
Invoke-BuildGate -Context `$ctx -Name 'exiting' -Script { exit 1 }
Invoke-BuildGate -Context `$ctx -Name 'after'   -Script { }
Write-Output ('REACHED gates=' + (`$ctx.Results['Gates'] -join ','))
"@
        Set-Content -LiteralPath $driver -Value $body -Encoding utf8
        $out = ('' + (& pwsh -NoProfile -File $driver 2>&1 | Out-String))
        $rc = $LASTEXITCODE
        Assert-Equal 1 $rc 'the exit propagated out of the driver, which is the whole point of the case'
        Assert-False ($out -match 'REACHED') `
            'the driver survived exit: PowerShell now contains it, so run_gate has a twin here and the doc must stop calling this an asymmetry'
        Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue
    }
}
