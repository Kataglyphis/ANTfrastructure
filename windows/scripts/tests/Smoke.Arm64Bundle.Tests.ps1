#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The floor is the gate's only defence against a device that ran nothing and still looks green.

Describe 'Test-Arm64Bundle: the floor decides the verdict' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-Arm64Bundle.ps1' -FunctionName 'Get-BundleVerdict')
        $script:ok = [pscustomobject]@{ Name = 'a'; Ok = $true; Detail = '' }
        $script:bad = [pscustomobject]@{ Name = 'b'; Ok = $false; Detail = 'exit 1' }
    }

    It 'passes when every step passed and the floor is met' {
        $v = Get-BundleVerdict -Results @($script:ok, $script:ok) -MinPassed 2
        Assert-True $v.Ok 'two passes at floor 2 must pass'
        Assert-Equal 2 $v.Passed 'passed count'
        Assert-Equal 0 $v.Failed 'failed count'
    }

    It 'fails below the floor even with zero failures' {
        $v = Get-BundleVerdict -Results @($script:ok) -MinPassed 9
        Assert-True (-not $v.Ok) 'one pass below floor 9 must fail'
        Assert-Match 'passed 1, floor 9' $v.Reason 'reason names the floor'
    }

    It 'fails when a step failed, floor or not' {
        $v = Get-BundleVerdict -Results @($script:ok, $script:bad) -MinPassed 1
        Assert-True (-not $v.Ok) 'a failed step must fail the run'
        Assert-Match '1 step\(s\) failed' $v.Reason 'reason names the failures'
    }

    It 'refuses MinPassed 0 without -AllowEmptyRun' {
        Assert-Throws { Get-BundleVerdict -Results @() -MinPassed 0 } 'empty floor' -MessagePattern 'AllowEmptyRun'
    }

    It 'permits an empty run only explicitly' {
        $v = Get-BundleVerdict -Results @() -MinPassed 0 -AllowEmptyRun
        Assert-True $v.Ok 'an explicitly allowed empty run passes'
    }
}
