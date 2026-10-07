#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The floor is the gate's only defence against a device that ran nothing and still looks green.

Describe 'Test-Arm64Bundle: the floor decides the verdict' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-Arm64Bundle.ps1' -FunctionName 'Get-BundleVerdict', 'Invoke-BundleStep', 'Invoke-ShippedBundleStep')
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

    It 'records a step into an EMPTY result list — the first call binds, not throws' {
        $results = [System.Collections.Generic.List[object]]::new()
        Invoke-BundleStep 'probe' { } $results
        Assert-Equal 1 $results.Count 'the empty list must bind and receive the step'
        Assert-True $results[0].Ok 'a quiet body is a pass'
    }

    It 'counts a component''s step only in a bundle that ships it, and names its absence otherwise' {
        Invoke-InTestDir { param($d)
            New-Item -ItemType File -Force (Join-Path $d 'python-freethreaded\python3.14t.exe') | Out-Null
            $results = [System.Collections.Generic.List[object]]::new()
            Invoke-ShippedBundleStep 'shipped' (Join-Path $d 'python-freethreaded\python3.*t.exe') { } $results
            Invoke-ShippedBundleStep 'not shipped' (Join-Path $d 'wheels\pytest-*-py3-none-any.whl') { throw 'must not run' } $results
            Assert-Equal 'shipped' (($results | ForEach-Object Name) -join ',') 'the absent component is neither run nor counted'
        }
    }

    It 'runs the free-threaded interpreter isolated, and fails it unless the GIL is off on ARM64' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-Arm64Bundle.ps1'))
        Assert-Match "Join-Path \`$BundleRoot 'python-freethreaded\\python3\.\*t\.exe'" $text 'found by pattern, not by a pinned version'
        Assert-Match "& \`$exe -I -c `".*assert not g and d == 1 and 'ARM64' in sys\.version" $text 'sys._is_gil_enabled(), Py_GIL_DISABLED and the arch marker'
    }
}
