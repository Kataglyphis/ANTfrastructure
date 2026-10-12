#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The floor is the gate's only defence against a device that ran nothing and still looks green.

Describe 'Test-Arm64Bundle: the floor decides the verdict' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-Arm64Bundle.ps1' -FunctionName 'Get-BundleVerdict', 'Invoke-BundleStep')
        Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1') -Force -DisableNameChecking
        $script:wheelModuleText = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1'))
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

    It 'the default floor is every step, so a bundle that lacks a component fails instead of passing short (mutation)' {
        $steps = [regex]::Matches($script:gateText, "(?m)^Invoke-BundleStep '").Count
        Assert-Match "\[int\]\`$MinPassed = $steps," $script:gateText "the floor equals the $steps steps"
        Assert-False ($script:gateText -match 'Invoke-ShippedBundleStep') 'no step is skipped for a bundle that does not ship its component'
    }

    It 'runs the WebRTC loopback with the bundle''s gst-launch and the module Export-Arm64Bundle.ps1 puts beside it' {
        Assert-Match "Invoke-BundleStep 'WebRTC loopback: webrtcsink -> webrtcsrc decodes 60 frames over DTLS-SRTP'" $script:gateText 'the CON63 step'
        Assert-Match "Assert-GstWebRtcLoopback -GstLaunch \(Join-Path \`$BundleRoot 'bin\\gst-launch-1\.0\.exe'\) -Frames 60" $script:gateText 'the bundle''s own GStreamer, graded as the smoke gate grades it'
        Assert-Match "Import-GateModule 'WindowsGstPlugins\.Common\.psm1'" $script:gateText 'beside the gate or in a hub checkout'
    }

    It 'runs a real ORT session over the smoke suite''s Identity model, graded on the CPU EP alone (CON30)' {
        Assert-Match "\`$identityOnnxHex = '$(Get-IdentityOnnxHex)'" $script:gateText 'the same 63 bytes as Test-Container.ps1'
        Assert-Match "Invoke-BundleStep 'ORT inference: the Identity model returns its input \(CPU EP\)' \{" $script:gateText 'a step every bundle runs'
        Assert-Match "InferenceSession\(bytes\.fromhex\('\`$identityOnnxHex'\), providers=\[sys\.argv\[1\]\]\).*assert y == 42\.0, y`"" $script:gateText 'a session that computes, not an import'
        # The CPU run is the body's last command, so its exit code is the one Invoke-BundleStep grades.
        Assert-Match "& \`$py -c \`$session DmlExecutionProvider 2>&1 \| ForEach-Object \{ Write-Host .*\}\r?\n\s*& \`$py -c \`$session CPUExecutionProvider\r?\n\} \`$results" $script:gateText 'DirectML printed, CPU graded'
    }

    It 'grades the ORT step by the CPU run''s exit code, whatever DirectML did, under the workflow''s native-error preference (mutation)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:gateText, [ref]$null, [ref]$null)
        $step = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$($n.CommandElements[0])" -eq 'Invoke-BundleStep' -and "$($n.CommandElements[1])" -match "^'ORT inference" }, $true)
        $body = $step.CommandElements[2].ScriptBlock.GetScriptBlock()
        Invoke-InTestDir { param($d)
            # The body interpolates it by name; the stand-in never reads the model.
            Set-Variable -Name identityOnnxHex -Value '00'
            $PSNativeCommandUseErrorActionPreference = $true
            foreach ($case in @(@{ Dml = 7; Cpu = 0; Ok = $true }, @{ Dml = 0; Cpu = 3; Ok = $false })) {
                # A stand-in python: its third argument is the provider the gate asks for.
                $py = Join-Path $d "py-$($case.Dml)-$($case.Cpu).cmd"
                Set-Content -LiteralPath $py -Value "@if `"%~3`"==`"DmlExecutionProvider`" exit /b $($case.Dml)`r`n@exit /b $($case.Cpu)"
                $results = [System.Collections.Generic.List[object]]::new()
                Invoke-BundleStep 'ort' $body $results
                Assert-Equal $case.Ok $results[0].Ok "DirectML exit $($case.Dml), CPU exit $($case.Cpu): $($results[0].Detail)"
            }
        }
    }

    It 'runs the free-threaded interpreter isolated, and fails it unless the GIL is off on ARM64' {
        Assert-Match "Join-Path \`$BundleRoot 'python-freethreaded\\python3\.\*t\.exe'" $script:gateText 'found by pattern, not by a pinned version'
        Assert-Match "& \`$exe -I -c `".*assert not g and d == 1 and 'ARM64' in sys\.version" $script:gateText 'sys._is_gil_enabled(), Py_GIL_DISABLED and the arch marker'
    }

    It 'proves every shipped cp3XYt twin with the helper Export-Arm64Bundle.ps1 puts beside it' {
        Assert-Match "Invoke-BundleStep 'free-threaded wheels: every twin loads with the GIL off' \{" $script:gateText 'a step every bundle runs'
        Assert-Match "Find-FirstPath -Root \`$BundleRoot -Name 'wheels-free-threaded', 'wheels-cp314t'" $script:gateText 'the CON91 name first, then the one older bundles carry'
        Assert-Match "-Helper \(Join-Path \`$PSScriptRoot 'free-threaded-wheel\.py'\)" $script:gateText 'the helper travels beside the gate'
        Assert-Match "Import-GateModule 'WindowsPythonWheel\.Common\.psm1'" $script:gateText 'the proof is the wheel module''s, shared with the consumer kit'
        Assert-Match "& \`$venvPy -I \`$Helper prove " $script:wheelModuleText 'the build lanes'' own proof'
        Assert-Match '--disable-pip-version-check --no-index @resolve ' $script:wheelModuleText 'every install offline'
        Assert-Match '\$resolve = Get-TwinInstallArgument -Store \$Store' $script:wheelModuleText 'the resolve words come from the one helper'
    }

    It 'resolves each twin alone, or with the deps\ beside it, as whole words a native command receives (mutation)' {
        Invoke-InTestDir { param($d)
            $alone = Get-TwinInstallArgument -Store $d
            Assert-Equal 1 $alone.Count 'one word, not a string the splat cuts into characters'
            Assert-Equal '--no-deps' ((& cmd /c echo @alone) -join '') 'device gate runs 38180134179 to 38209436310 handed pip ''- - n o - d e p s'''
            $null = New-Item -ItemType Directory -Path (Join-Path $d 'deps')
            $withDeps = Get-TwinInstallArgument -Store $d
            Assert-Equal "--find-links|$d|--find-links|$(Join-Path $d 'deps')" ($withDeps -join '|') 'the store and its deps\ (CON79)'
        }
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
