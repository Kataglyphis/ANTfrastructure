#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Covers child transport and isolation, not real Python CI tools or wheel execution.

Import-Module (Join-Path $PSScriptRoot 'WindowsPythonCi.DriverFixture.psm1') -Force -DisableNameChecking

Describe 'Python CI child fixture transport' {
    It 'preserves child arguments, status and calls while restoring the parent location and environment' {
        Invoke-InTestDir { param($dir)
            $work = Join-Path $dir 'quoted work'
            $null = New-Item -ItemType Directory -Path $work
            $driver = Join-Path $dir 'child driver.ps1'
            Set-Content -LiteralPath $driver -Value @(
                'param([string]$Value)'
                'Add-Content -LiteralPath $env:FAKE_LOG -Value ((Get-Location).Path + "|" + $Value + "|" + $env:CI_FIXTURE_VALUE)'
                'Write-Output ("`e[31mchild failed`e[0m`n  | details")'
                'exit 7'
            )
            $originalLocation = (Get-Location).Path
            Invoke-WithEnv @{ CI_FIXTURE_VALUE = 'parent'; FAKE_LOG = 'parent-log' } {
                $vars = @{ CI_FIXTURE_VALUE = 'child' }
                $result = Invoke-PythonCiFixtureDriver -Dir $dir -Script $driver -Environment $vars -WorkingDirectory $work -Arguments @('-Value', 'a b:c')
                Assert-Equal 7 $result.Code
                Assert-Equal "$work|a b:c|child" ($result.Calls -join ',')
                Assert-Equal 'child failed details' $result.Text
                Assert-Equal 'parent' $env:CI_FIXTURE_VALUE
                Assert-Equal 'parent-log' $env:FAKE_LOG
                Assert-False $vars.ContainsKey('FAKE_LOG') 'fixture environment must remain reusable'
                Assert-Equal $originalLocation (Get-Location).Path
            }
        }
    }

    It 'clears a previous call log and retains an empty call collection on a successful child' {
        Invoke-InTestDir { param($dir)
            $driver = Join-Path $dir 'empty driver.ps1'
            Set-Content -LiteralPath $driver -Value 'exit 0'
            Set-Content -LiteralPath (Join-Path $dir 'calls.log') -Value 'stale call'
            $result = Invoke-PythonCiFixtureDriver -Dir $dir -Script $driver -Environment @{}
            Assert-Equal 0 $result.Code
            Assert-Equal 0 @($result.Calls).Count
            Assert-Equal '' $result.Text
        }
    }

    It 'detects a failed child reported as successful and stale call logs reused by a later run' {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'WindowsPythonCi.DriverFixture.psm1'))
        Invoke-InTestDir { param($dir)
            $driver = Join-Path $dir 'failed child.ps1'
            Set-Content -LiteralPath $driver -Value 'exit 7'
            foreach ($case in @(
                @{ Find = '$code = $LASTEXITCODE'; Replace = '$code = 0'; Check = { param($result) Assert-Equal 7 $result.Code } },
                @{ Find = 'Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue'; Replace = '$null = $log'; Check = { param($result) Assert-Equal 0 @($result.Calls).Count } }
            )) {
                Invoke-WithFunctionModule -Text $text -FunctionName Invoke-PythonCiFixtureDriver -Find $case.Find -Replace $case.Replace -Body {
                    & $case.Check (Invoke-PythonCiFixtureDriver -Dir $dir -Script $driver -Environment @{})
                    Set-Content -LiteralPath (Join-Path $dir 'calls.log') -Value 'stale call'
                    $result = Invoke-MutPythonCiFixtureDriver -Dir $dir -Script $driver -Environment @{}
                    Assert-Throws { & $case.Check $result } -MessagePattern 'Assert-Equal'
                }
            }
        }
    }
}
