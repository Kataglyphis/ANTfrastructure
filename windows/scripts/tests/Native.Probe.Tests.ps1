#requires -Version 7.0
# Local child processes cover timeout, capture and environment policies; GPU driver behavior is not exercised.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsNative.Common.psm1') -DisableNameChecking

function Assert-NativeProbeTimeout {
    param([string]$Command = 'Invoke-NativeProbeProcess')
    $code = '[Threading.Thread]::Sleep(30000)'
    $result = & $Command -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $code) -TimeoutSeconds 1
    Assert-Null $result.ExitCode 'a timeout must not report a successful exit'
    Assert-Equal '' $result.Text
}

Describe 'Native probe process transport' {
    It 'forwards argv and child-only environment and preserves requested stdout before stderr' {
        Invoke-InTestDir { param($dir)
            $scriptPath = Join-Path $dir 'child script.ps1'
            [IO.File]::WriteAllText($scriptPath, '[Console]::Write(($args -join "|") + "|" + $env:ANT_PROBE_CHILD + " "); [Console]::Error.Write(" stderr "); exit 23')
            Invoke-WithEnv @{ ANT_PROBE_CHILD = 'parent' } {
                $result = Invoke-NativeProbeProcess -FilePath (Get-Process -Id $PID).Path `
                    -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $scriptPath, 'a b', 'x;y') -Environment @{ ANT_PROBE_CHILD = 'child' } -PreserveOutput
                Assert-Equal 23 $result.ExitCode
                Assert-Equal 'a b|x;y|child  stderr ' $result.Text
                Assert-Equal parent $env:ANT_PROBE_CHILD
            }
        }
    }

    It 'keeps llama''s trimmed capture and the loader''s inherited stderr policies separate' {
        $argv = @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Write(" stdout "); [Console]::Error.Write(" stderr ")')
        $exe = (Get-Process -Id $PID).Path
        $merged = Invoke-NativeProbeProcess -FilePath $exe -ArgumentList $argv
        Assert-Equal 'stdout  stderr' $merged.Text
        $inherited = Invoke-NativeProbeProcess -FilePath $exe -ArgumentList $argv -InheritStandardError -PreserveOutput
        Assert-Equal ' stdout ' $inherited.Text
        Assert-Equal 0 $inherited.ExitCode
    }

    It 'kills a stalled probe and preserves the null exit-code sentinel' { Assert-NativeProbeTimeout }

    It 'kills the whole process tree before returning from a timeout' {
        Invoke-InTestDir { param($dir)
            $record = Join-Path $dir 'grandchild.pid'
            $child = Join-Path $dir 'tree.ps1'
            [IO.File]::WriteAllText($child, @'
$info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', '[Threading.Thread]::Sleep(30000)')) { $info.ArgumentList.Add($argument) }
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$process = [Diagnostics.Process]::Start($info)
[IO.File]::WriteAllText($args[0], [string]$process.Id)
[Threading.Thread]::Sleep(30000)
'@)
            try {
                $result = Invoke-NativeProbeProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $child, $record) -TimeoutSeconds 3
                Assert-Null $result.ExitCode
                Assert-True (Test-Path -LiteralPath $record) 'the child created its descendant before timeout'
                $descendant = [int][IO.File]::ReadAllText($record)
                Assert-Null (Get-Process -Id $descendant -ErrorAction SilentlyContinue) 'no descendant may survive the probe'
            } finally {
                if (Test-Path -LiteralPath $record) { Stop-Process -Id ([int][IO.File]::ReadAllText($record)) -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'detects replacing the timeout sentinel with a success exit code' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsNative.Common.psm1'))
        Invoke-WithFunctionModule -Text $text -FunctionName Invoke-NativeProbeProcess -Find "ExitCode = `$null; Text = ''" -Replace "ExitCode = 0; Text = ''" -Body {
            Assert-Throws { Assert-NativeProbeTimeout -Command Invoke-MutNativeProbeProcess } -MessagePattern 'a timeout must not report a successful exit'
        }
    }
}

Describe 'Python JSON probe report transport' {
    It 'shares last-report selection and exit/no-report verdicts across callers' {
        $parsed = ConvertFrom-PythonJsonProbeOutput -Lines @('diagnostic', '{"value":1}', '{"value":2}') -ExitCode 0
        Assert-Equal 2 $parsed.Report.value 'the last JSON report wins'
        Assert-Null $parsed.Failure 'a successful report has no failure'
        $failed = ConvertFrom-PythonJsonProbeOutput -Lines @('{"value":2}') -ExitCode 7
        Assert-Equal '7 without a report' $failed.Failure 'a valid report cannot excuse a failed process'
        $missing = ConvertFrom-PythonJsonProbeOutput -Lines @('diagnostic') -ExitCode 0 -DiagnosticTail
        Assert-Equal '0 without a report: diagnostic' $missing.Failure 'diagnostic tails are opt-in'
    }

    It 'preserves interpreter/source/argument order, takes the last report and cleans the source even on nonzero exits' {
        $state = New-TestCallState @{ Code = 0; Source = ''; Path = '' }
        Invoke-WithTestNativeCommand -Name Invoke-JsonFixtureInterpreter -Implementation { param($state, $ArgumentList)
            $state.Path = $ArgumentList[1]
            $state.Source = [IO.File]::ReadAllText($state.Path)
            'diagnostic'; '{"value":1}'; '{"value":2}'
        } -FixtureState $state -Body { param($state)
            $options = @{ Python = 'Invoke-JsonFixtureInterpreter'; Source = 'fixture source'; Prefix = 'json-fixture'; InterpreterArgument = '-I'; ArgumentList = @('a b', 'x;y') }
            Assert-Equal 2 (Invoke-PythonJsonProbe @options).value
            Assert-Equal 'fixture source' $state.Source
            Assert-Match '^json-fixture-.+\.py$' (Split-Path $state.Path -Leaf)
            Assert-Equal '-I|a b|x;y' ((@($state.Calls[0][0]) + @($state.Calls[0][2..3])) -join '|')
            Assert-False (Test-Path -LiteralPath $state.Path) 'successful JSON parsing cleans the source'
            $state.Code = 7
            Assert-Throws { Invoke-PythonJsonProbe @options -DiagnosticTail } -MessagePattern 'exit 7 without a report:.*value'
            Assert-False (Test-Path -LiteralPath $state.Path) 'a nonzero result with valid JSON still cleans the source'
        }
    }

    It 'detects accepting JSON from a failed interpreter in the shared parser' {
        Invoke-TestFunctionMutations -ModuleArguments @{ ScriptPath = 'windows\scripts\modules\WindowsNative.Common.psm1'; FunctionName = @('ConvertFrom-PythonJsonProbeOutput') } `
            -Find '$ExitCode -ne 0 -or -not $json' -Replace '-not $json' -Expected 'nonzero exit status must suppress JSON' -IncludeControl -Body {
                $parsed = ConvertFrom-MutPythonJsonProbeOutput -Lines @('{"ok":true}') -ExitCode 4
                Assert-NotNull $parsed.Failure 'nonzero exit status must suppress JSON'
            }
    }

    It 'detects accepting valid JSON from a failed interpreter' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsNative.Common.psm1' -FunctionName Invoke-PythonJsonProbe -Find '$parsed.Failure' -Replace '$false' -Body {
            Invoke-WithTestFunction -Name Invoke-FailedJsonFixture -Definition { '{"ok":true}'; $global:LASTEXITCODE = 4 } -Body {
                Assert-Throws {
                    Assert-Throws { Invoke-MutPythonJsonProbe -Python Invoke-FailedJsonFixture -Source 'fixture' -Prefix json-mutant } -MessagePattern 'exit 4'
                } -MessagePattern 'expected an exception but none was thrown'
            }
        }
    }
}
