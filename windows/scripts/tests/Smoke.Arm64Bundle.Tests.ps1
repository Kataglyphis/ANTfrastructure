#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The floor is the gate's only defence against a device that ran nothing and still looks green.

Describe 'Test-Arm64Bundle: the floor decides the verdict' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-Arm64Bundle.ps1' -FunctionName 'Get-BundleVerdict', 'Invoke-BundleStep', 'Invoke-ShippedBundleStep', 'Invoke-TwinDeviceProof')
        $script:ok = [pscustomobject]@{ Name = 'a'; Ok = $true; Detail = '' }
        $script:bad = [pscustomobject]@{ Name = 'b'; Ok = $false; Detail = 'exit 1' }
        $script:gateText = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-Arm64Bundle.ps1'))
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
        Assert-Match "Join-Path \`$BundleRoot 'python-freethreaded\\python3\.\*t\.exe'" $script:gateText 'found by pattern, not by a pinned version'
        Assert-Match "& \`$exe -I -c `".*assert not g and d == 1 and 'ARM64' in sys\.version" $script:gateText 'sys._is_gil_enabled(), Py_GIL_DISABLED and the arch marker'
    }

    It 'proves every shipped cp3XYt twin with the helper Export-Arm64Bundle.ps1 puts beside it' {
        Assert-Match "Invoke-ShippedBundleStep 'free-threaded wheels: every cp314t twin loads with the GIL off' \(Join-Path \`$BundleRoot 'wheels-cp314t\\\*\.whl'\)" $script:gateText 'counted only in a bundle that ships twins'
        Assert-Match "-Helper \(Join-Path \`$PSScriptRoot 'free-threaded-wheel\.py'\)" $script:gateText 'the helper travels beside the gate'
        Assert-Match "& \`$venvPy -I \`$Helper prove " $script:gateText 'the build lanes'' own proof'
        Assert-Match '--no-index --no-deps' $script:gateText 'each twin alone and offline'
    }

    It 'the twin proof refuses a missing helper or an empty store, and names every twin that fails (mutation)' {
        Invoke-InTestDir { param($d)
            $null = New-Item -ItemType Directory -Force -Path "$d\store"
            Set-Content -LiteralPath "$d\helper.py" -Value '# stand-in'
            Assert-Throws { Invoke-TwinDeviceProof -Interpreter "$d\py.cmd" -Store "$d\store" -Helper "$d\none.py" } -MessagePattern 'no .*none\.py to prove the twins with'
            Assert-Throws { Invoke-TwinDeviceProof -Interpreter "$d\py.cmd" -Store "$d\store" -Helper "$d\helper.py" } -MessagePattern 'no wheel in'
            # An interpreter that cannot make a venv fails each twin by name, and the run once.
            Set-Content -LiteralPath "$d\py.cmd" -Value '@exit /b 3'
            foreach ($w in 'av-1.0-cp314-cp314t-win_arm64.whl', 'onnxruntime-1.0-cp314-cp314t-win_arm64.whl') { Set-Content -LiteralPath "$d\store\$w" -Value 'w' }
            Assert-Throws { Invoke-TwinDeviceProof -Interpreter "$d\py.cmd" -Store "$d\store" -Helper "$d\helper.py" } `
                -MessagePattern '2 of 2 twin\(s\) failed: av-1\.0-cp314-cp314t-win_arm64\.whl: venv exited 3; onnxruntime-1\.0-cp314-cp314t-win_arm64\.whl: venv exited 3'
        }
    }
}
