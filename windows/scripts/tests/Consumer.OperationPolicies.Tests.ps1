#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Covers accounting, rendering and fake client transports; no real container, certificate or native pipe is exercised.

$consumerModuleDir = Join-Path (Get-RepoRoot) 'windows\scripts\modules'
foreach ($moduleName in 'WindowsScripts.Shared', 'WindowsBuild.Common', 'WindowsPerfBaseline.Common') {
    Import-Module (Join-Path $consumerModuleDir "$moduleName.psm1")
}

function Invoke-ConsumerBuildFixture {
    param([scriptblock]$Body)
    Invoke-InTestDir { param($dir)
        $context = New-BuildContext -Workspace $dir -LogDir 'logs' -StopOnError
        $context.SuppressConsoleOutput = $true
        $context.Results.Durations = $null
        & $Body $context
    }
}

Describe 'Shared build log and Rust package paths' {
    It 'anchors relative paths at the workspace and preserves external absolute paths' {
        Import-Module (Join-Path $consumerModuleDir 'WindowsScripts.Shared.psm1') -DisableNameChecking
        $ast = Get-TestScriptAst -ScriptPath 'windows/scripts/rust/New-MsixPackage.ps1'
        $assignment = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$resolvedCargoTargetDir'
        }, $true))
        Assert-Equal 1 $assignment.Count 'one Cargo target assignment'
        $resolve = [scriptblock]::Create('param($Workspace, $CargoTargetDir); ' + $assignment[0].Extent.Text + '; $resolvedCargoTargetDir')
        Invoke-InTestDir { param($dir)
            $workspace = Join-Path $dir workspace
            foreach ($case in @(
                @{ Input = 'relative tree'; Expected = (Join-Path $workspace 'relative tree') }
                @{ Input = (Join-Path $dir 'external tree'); Expected = (Join-Path $dir 'external tree') }
            )) {
                Assert-Equal $case.Expected (& $resolve $workspace $case.Input)
                $context = New-BuildContext -Workspace $workspace -LogDir $case.Input
                Assert-Equal $case.Expected ([IO.Path]::GetDirectoryName($context.LogPath))
            }
        }
    }
}

function Invoke-ConsumerProbeFixture {
    param([scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $state = [pscustomobject]@{ Code = 9; Error = 'fixture client notice'; Output = 'fixture stdout' }
    $prelude = @'
$script:State = $State
function Test-FixtureClient {
    if ($script:State.Error) { Write-Error $script:State.Error }
    $script:State.Output
    $global:LASTEXITCODE = $script:State.Code
}
'@
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsContainerBuild.Reuse.psm1' `
        -FunctionName Invoke-ContainerClientCommand, Invoke-ContainerClientAttempt, Get-ContainerInspectField `
        -Find $Find -Replace $Replace -FixtureState $state -Prelude $prelude -Body $Body
}

function Invoke-ConsumerOptionalCase {
    param([scriptblock]$Script, [scriptblock]$Verify)
    Invoke-ConsumerBuildFixture {
        param($context)
        $optional = @(Invoke-BuildOptional -Context $context -Name optional -Script $Script)
        & $Verify $context $optional
    }
}

function Invoke-ConsumerTarFixture {
    param([scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $state = [pscustomobject]@{ Commands = [Collections.Generic.List[string]]::new(); ExitCode = 0 }
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsContainerBuild.Reuse.psm1' -FunctionName Get-ContainerTarExcludeArgs, Invoke-ContainerTarPipe, Copy-IntoBuildContainer, Copy-FromBuildContainer `
        -Find $Find -Replace $Replace -FixtureState $state -Body $Body `
        -Prelude '$script:State = $State; function cmd { $script:State.Commands.Add($args[1]); "transport line"; $global:LASTEXITCODE = $script:State.ExitCode }'
}

function Invoke-ConsumerBinaryenFixture {
    param([scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $state = [pscustomobject]@{ Checks = 0; Extracts = 0; BadHash = $false }
    $prelude = @'
$script:State = $State
function Get-BinaryenPin { [pscustomobject]@{ Version = 'fixture'; Asset = 'fixture.tar.gz'; Url = 'fixture'; Sha256 = 'expected' } }
function Invoke-DownloadWithRetry { param($Url, $DestinationPath) [IO.File]::WriteAllText($DestinationPath, 'archive') }
function Assert-FileSha256 {
    param($Path, $Expected, $Label)
    if ($Expected -ne 'expected' -or $Label -ne 'binaryen download checksum' -or -not (Test-Path -LiteralPath $Path)) { throw 'checksum input lost' }
    $script:State.Checks++
    if ($script:State.BadHash) { throw 'binaryen download checksum mismatch' }
}
function tar {
    $script:State.Extracts++
    $bin = Join-Path $args[3] 'binaryen-fixture\bin'
    $null = New-Item -ItemType Directory -Path $bin -Force
    [IO.File]::WriteAllText((Join-Path $bin 'wasm-opt.exe'), 'tool')
    $global:LASTEXITCODE = 0
}
'@
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsWasmOpt.Common.psm1' -FunctionName Install-WasmOpt -Find $Find -Replace $Replace `
        -Prelude $prelude -FixtureState $state -Body $Body
}

Describe 'Consumer operation accounting' {
    It 'preserves optional output and step verdicts while recreating an empty duration bucket' {
        Invoke-ConsumerOptionalCase -Script { 'optional output' } -Verify {
            param($context, $optional)
            Assert-Equal 'optional output' ($optional -join '|')
            $context.Results.Durations = $null
            $step = @(Invoke-BuildStep -Context $context -StepName step -Script { 'step output' })
            Assert-Equal 2 $step.Count
            Assert-Equal 'step output' $step[0]
            Assert-Equal $true $step[1]
            Assert-True ($context.Results.Durations['step'] -ge 0)
            Assert-Equal 'optional,step' ($context.Results.Succeeded -join ',')
        }
    }

    It 'keeps optional and critical failures distinct and records both durations' {
        Invoke-ConsumerOptionalCase -Script { throw 'optional failed' } -Verify {
            param($context, $optional)
            Assert-Equal 0 $optional.Count
            Assert-True ($context.Results.Durations['optional'] -ge 0)
            Assert-Equal 'optional failed' $context.Results.Errors['optional']
            Assert-Equal 'optional' ($context.Results.AllowedFailures -join ',')
            Assert-Throws { Invoke-BuildStep -Context $context -StepName critical -Critical -Script { throw 'critical failed' } } `
                -MessagePattern "Critical step 'critical' failed: critical failed"
            Assert-True ($context.Results.Durations['critical'] -ge 0)
            Assert-Equal 'critical failed' $context.Results.Errors['critical']
            Assert-Equal 'critical' ($context.Results.Failed -join ',')
        }
    }

    It 'rejects corrupted shared duration accounting' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsBuild.Common.psm1' -FunctionName Set-BuildOperationDuration, Invoke-BuildOperationBody, Invoke-BuildOptional `
            -Find '$Context.Results.Durations[$Name] = $Stopwatch.Elapsed.TotalSeconds' `
            -Replace '$Context.Results.Durations[$Name] = -1' -Body {
                Assert-Throws {
                    Invoke-ConsumerBuildFixture {
                        param($context)
                        Invoke-MutBuildOptional -Context $context -Name duration -Script { }
                        Assert-True ($context.Results.Durations['duration'] -ge 0) 'duration must be nonnegative'
                    }
                } -MessagePattern 'duration must be nonnegative'
            }
    }

    It 'detects shared operation execution swallowing the script output' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsBuild.Common.psm1' -FunctionName Set-BuildOperationDuration, Invoke-BuildOperationBody `
            -Find '& $Script' -Replace '$null = & $Script' -Body {
                Invoke-ConsumerBuildFixture {
                    param($context)
                    $operation = @{}
                    $output = @(Invoke-MutBuildOperationBody -Context $context -Name operation -Script { 'operation output' } -Outcome $operation)
                    Assert-Throws { Assert-Equal 'operation output' ($output -join '|') } -MessagePattern 'expected \[operation output\]'
                }
            }
    }

}

Describe 'Benchmark row construction and rendering' {
    It 'keeps one row schema, missing values, ordinal order and shared regression identity' {
        $comparison = Compare-BenchmarkTimeMap -BaselineMap @{ A = 10; C = 30; Z = 0 } -CandidateMap @{ A = 20; B = 999; Z = 10 }
        Assert-Equal 'A,B,C,Z' ($comparison.Rows.Name -join ',')
        Assert-True ([object]::ReferenceEquals($comparison.Rows[0], $comparison.Regressions[0]))
        Assert-Null $comparison.Rows[1].Baseline
        Assert-Null $comparison.Rows[1].Delta
        Assert-Null $comparison.Rows[2].Candidate
        Assert-Equal 0 $comparison.Rows[3].Delta
        Assert-Equal 'compared,only-cand,only-base,compared' ($comparison.Rows.Status -join ',')
        $rendered = @(Write-BenchmarkComparisonReport -Comparison $comparison -BaselinePath baseline -CandidatePath candidate 6>&1) -join "`n"
        Assert-Match 'A\s+10\.0\s+20\.0\s+\+100%' $rendered
        Assert-Match 'A: 10\.0 ns -> 20\.0 ns \(\+100%\)' $rendered
    }

    It 'rejects a row that loses its one-sided classification' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsPerfBaseline.Common.psm1' -FunctionName Compare-BenchmarkTimeMap `
            -Find '$row.Status = ''only-base''' -Replace '$row.Status = ''compared''' -Body {
                $result = Compare-MutBenchmarkTimeMap -BaselineMap @{ removed = 1 } -CandidateMap @{}
                Assert-Throws { Assert-Equal 'only-base' $result.Rows[0].Status } -MessagePattern 'expected \[only-base\]'
            }
    }
}

Describe 'Best-effort container client transport' {
    It 'captures stdout and failure code while containing nonterminating client diagnostics' {
        Invoke-ConsumerProbeFixture -Body {
            param($state)
            $savedPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                $attempt = Invoke-MutContainerClientAttempt -DockerExe Test-FixtureClient -Arguments @('inspect', 'container')
                Assert-Equal 'fixture stdout' ($attempt.Output -join '|')
                Assert-Equal 9 $attempt.ExitCode
                Assert-Equal 'Stop' $ErrorActionPreference
                Assert-Throws { Invoke-MutContainerClientAttempt -DockerExe Missing-FixtureClient -Arguments @() } -MessagePattern 'Missing-FixtureClient'
                Assert-Equal 'Stop' $ErrorActionPreference

                foreach ($case in @(
                    @{ Code = 0; Error = 'WARNING: client notice'; Output = 'running'; Value = 'running'; Diagnostic = 'WARNING: client notice'; Missing = $false }
                    @{ Code = 1; Error = ''; Output = 'Error: No such object: fixture'; Value = ''; Diagnostic = 'Error: No such object: fixture'; Missing = $true }
                )) {
                    $state.Code = $case.Code; $state.Error = $case.Error; $state.Output = $case.Output
                    $inspect = Get-MutContainerInspectField -DockerExe Test-FixtureClient -Name fixture -Format '{{.State.Status}}'
                    Assert-Equal $case.Code $inspect.ExitCode
                    Assert-Equal $case.Value $inspect.Value 'stderr must never become the inspected value'
                    Assert-Equal $case.Diagnostic $inspect.Error 'inspect diagnostics keep their stderr-first policy'
                    Assert-Equal $case.Missing $inspect.Missing 'stdout-only docker failures remain classifiable'
                }
                Assert-Equal 'Stop' $ErrorActionPreference
            } finally { $ErrorActionPreference = $savedPreference }
        }
    }

    It 'rejects a shared client call that lets diagnostic errors terminate the build' {
        Invoke-ConsumerProbeFixture -Find '$ErrorActionPreference = ''Continue''' -Replace '$ErrorActionPreference = ''Stop''' -Body {
            Assert-Throws { Invoke-MutContainerClientAttempt -DockerExe Test-FixtureClient -Arguments @() } -MessagePattern 'fixture client notice'
        }
    }
}

Describe 'MSIX signing command transport' {
    It 'dispatches both commands through the selected invoker and leaves failures visible' {
        $fixtureState = [pscustomobject]@{ Trace = [Collections.Generic.List[string]]::new() }
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsMsix.Signing.psm1' -FunctionName Invoke-MsixSigningCommand -FixtureState $fixtureState `
            -Prelude '$script:State = $State; function Invoke-BuildExternal { param($Context, $File, $Parameters) $script:State.Trace.Add("fallback:$($Parameters -join '','')"); "transport output" }' `
            -Body {
                param($fixtureState)
                $delegate = { param($Context, $File, $Parameters) $fixtureState.Trace.Add("delegate:$($Parameters -join ',')"); 'delegate output' }.GetNewClosure()
                $output = @(Invoke-MutMsixSigningCommand -Context ([pscustomobject]@{}) -File 'signtool' -Parameters @('sign', 'package') -Invoker $delegate)
                $output += @(Invoke-MutMsixSigningCommand -Context ([pscustomobject]@{}) -File 'signtool' -Parameters @('verify', 'package'))
                Assert-Equal 0 $output.Count
                Assert-Equal 'delegate:sign,package|fallback:verify,package' ($fixtureState.Trace -join '|')
                Assert-Throws { Invoke-MutMsixSigningCommand -Context ([pscustomobject]@{}) -File 'signtool' -Parameters sign -Invoker { throw 'signer unavailable' } } `
                    -MessagePattern 'signer unavailable'
            }
    }
}

Describe 'Container log pipeline' {
    It 'logs manual and command lines once and returns only the native exit code' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsContainerLog.Common.psm1' -FunctionName Start-ContainerLog, Write-ContainerLog, Invoke-ContainerLoggedCommand `
            -Prelude '$script:ContainerLogPath = $null; function cmd { "first"; ""; "third"; $global:LASTEXITCODE = 7 }' -Body {
                Invoke-InTestDir { param($dir)
                    $log = Join-Path $dir 'container.log'
                    Start-MutContainerLog -Path $log
                    Write-MutContainerLog 'manual' 6>$null
                    $exit = @(Invoke-MutContainerLoggedCommand -CommandLine 'fixture' 6>$null)
                    Assert-Equal '7' ($exit -join '|')
                    Assert-Equal 'manual|first||third' ((Get-Content -LiteralPath $log) -join '|')
                }
            }
    }
}

Describe 'Consumer relative path policies' {
    It 'keeps absent and rooted agent prompts while rooting overlays in the repository' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsAgenticLoop.Common.psm1' -FunctionName Resolve-AgenticPromptAsset -Body {
            Invoke-InTestDir { param($dir)
                Assert-Null (Resolve-MutAgenticPromptAsset -Path $null -RepoRoot $dir)
                Assert-Equal '' (Resolve-MutAgenticPromptAsset -Path '' -RepoRoot $dir)
                $absolute = Join-Path $dir 'external\planner.md'
                Assert-Equal $absolute (Resolve-MutAgenticPromptAsset -Path $absolute -RepoRoot 'C:\elsewhere')
                Assert-Equal (Join-Path $dir 'overlays\executor.md') (Resolve-MutAgenticPromptAsset -Path 'overlays\executor.md' -RepoRoot $dir)
            }
        }
    }

    It 'uses the same relative and absolute venv paths for creation and initialization' {
        Import-Module (Join-Path $consumerModuleDir 'WindowsUv.Common.psm1')
        Invoke-WithEnv @{ UV_PROJECT_ENVIRONMENT = $null } {
            Invoke-InTestDir { param($dir)
                $calls = [Collections.Generic.List[object]]::new()
                $runner = { param($File, $Arguments) $calls.Add($Arguments) }.GetNewClosure()
                $absolute = Join-Path $dir 'absolute venv'
                $scenarios = @(@{ Name = 'relative venv'; Expected = (Join-Path $dir 'relative venv') }, @{ Name = $absolute; Expected = $absolute })
                foreach ($scenario in $scenarios) {
                    $created = New-UvProjectEnvironment -Workspace $dir -PythonVersion fixture-python -EnvName $scenario.Name -CommandRunner $runner
                    $python = Initialize-UvVenv -Workspace $dir -PythonVersion fixture-python -EnvName $scenario.Name -CommandRunner $runner
                    Assert-Equal $scenario.Expected $created
                    Assert-Equal (Join-Path $scenario.Expected 'Scripts\python.exe') $python
                    Assert-Equal $scenario.Expected $env:UV_PROJECT_ENVIRONMENT
                    Assert-Equal $scenario.Expected $calls[-1][-1]
                }
                Assert-Equal 4 $calls.Count
            }
        }
    }

    It 'rejects rebasing an already rooted package or venv path' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Resolve-PathFromRoot `
            -Find 'if ([IO.Path]::IsPathRooted($Path)) { return $Path }' -Replace 'if ($false) { return $Path }' -Body {
                Invoke-InTestDir { param($dir)
                    $absolute = Join-Path $dir 'absolute path'
                    Assert-Throws {
                        Assert-Equal $absolute (Resolve-MutPathFromRoot -Root (Join-Path $dir 'workspace') -Path $absolute)
                    } -MessagePattern 'Assert-Equal'
                }
            }
    }
}

Describe 'Container source and artifact tar transfers' {
    It 'shares the raw pipe while preserving inbound quoting, outbound literals and native output' {
        Invoke-ConsumerTarFixture -Body {
            param($state)
            $inbound = @(Copy-MutIntoBuildContainer -DockerExe 'C:\program files\docker.exe' -Container build `
                -SourceRoot 'C:\source tree' -TargetPath 'C:\ws' -Items @('one path', 'two') -Exclude 'build space')
            Assert-Equal 'transport line' $inbound[0]
            Assert-Equal $true $inbound[1]
            $state.ExitCode = 9
            $output = @(Copy-MutFromBuildContainer -DockerExe 'C:\program files\docker.exe' -Container build `
                -SourcePath 'C:\ws' -TargetRoot 'C:\host tree' -Items @('bin', 'logs') -Exclude 'build space')
            Assert-Equal $false $output[-1]
            Assert-Equal 'tar -cf - --exclude "build space" -C "C:\source tree" "one path" "two" | "C:\program files\docker.exe" exec -i build tar -xf - -C C:\ws' $state.Commands[0]
            Assert-Equal '"C:\program files\docker.exe" exec build tar -cf - --exclude "build space" -C C:\ws bin logs | tar -xf - -C "C:\host tree"' $state.Commands[1]
        }
    }

    It 'rejects reversing the common transfer success verdict' {
        Invoke-ConsumerTarFixture -Find 'return ($LASTEXITCODE -eq 0)' -Replace 'return ($LASTEXITCODE -ne 0)' -Body {
            Assert-Throws {
                $result = @(Copy-MutIntoBuildContainer -DockerExe docker -Container build -SourceRoot source -TargetPath target)
                Assert-True $result[-1] 'tar transfer verdict'
            } -MessagePattern 'tar transfer verdict'
        }
    }
}

Describe 'Cross Python layout staging' {
    It 'keeps the distinct root and DLLs extension policies and lets DLLs overwrite root copies' {
        $state = [pscustomobject]@{ Arguments = @() }
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsPythonApp.Common.psm1' -FunctionName Initialize-PythonAppDirectory, New-PythonAppCrossRuntime -FixtureState $state `
            -Prelude '$script:State = $State; function Invoke-PythonAppLayout { param($HostPython, $SourceDir, $Destination, $Arguments) $script:State.Arguments = $Arguments; Join-Path $Destination "python.exe" }' `
            -Body {
                param($state)
                Invoke-InTestDir -Files @{
                    'target\python.exe' = 'python'; 'target\overlap.dll' = 'root'; 'target\root.pyd' = 'excluded'
                    'target\DLLs\module.pyd' = 'extension'; 'target\DLLs\overlap.dll' = 'dlls'; 'target\DLLs\tool.exe' = 'excluded'
                    'source\LICENSE' = 'license'
                } -Body { param($dir)
                    $target = Join-Path $dir 'target'
                    $source = Join-Path $dir 'source'
                    $null = New-Item -ItemType Directory -Path (Join-Path $source 'PC\layout') -Force
                    $destination = Join-Path $dir 'runtime'
                    Assert-Equal (Join-Path $destination 'python.exe') (New-MutPythonAppCrossRuntime -TargetPython $target -SourceDir $source -HostPython host-python -Arch arm64 -WorkDir $dir -Destination $destination)
                    $flat = Join-Path $dir 'pcbuild-arm64'
                    Assert-Equal 'LICENSE.txt,module.pyd,overlap.dll,python.exe' ((Get-ChildItem -LiteralPath $flat -File | Sort-Object Name).Name -join ',')
                    Assert-Equal 'dlls' ([IO.File]::ReadAllText((Join-Path $flat 'overlap.dll')))
                    Assert-Equal ("--build|$flat|--arch|arm64") ($state.Arguments -join '|')
                }
            }
    }
}

Describe 'Binaryen shared checksum policy' {
    It 'checks downloaded archives before extraction and removes a rejected archive' {
        Invoke-ConsumerBinaryenFixture -Body {
            param($state)
            Invoke-WithEnv @{ PATH = $env:PATH } {
                Invoke-InTestDir { param($dir)
                    $state.BadHash = $true
                    Assert-Throws { $null = Install-MutWasmOpt -CacheRoot $dir -Force } -MessagePattern 'binaryen download checksum mismatch'
                    Assert-Equal 1 $state.Checks
                    Assert-Equal 0 $state.Extracts
                    Assert-False (Test-Path -LiteralPath (Join-Path $dir 'fixture.tar.gz'))
                    $state.BadHash = $false
                    $tool = Install-MutWasmOpt -CacheRoot $dir -Force
                    Assert-True (Test-Path -LiteralPath $tool)
                    Assert-Equal 2 $state.Checks
                    Assert-Equal 1 $state.Extracts
                }
            }
        }
    }

    It 'rejects a bootstrap that bypasses the shared checksum assertion' {
        Invoke-ConsumerBinaryenFixture -Find 'Assert-FileSha256 -Path $archivePath -Expected $pin.Sha256 -Label ''binaryen download checksum''' `
            -Replace 'Write-Verbose ''checksum bypassed''' -Body {
                param($state)
                $state.BadHash = $true
                Invoke-WithEnv @{ PATH = $env:PATH } {
                    Invoke-InTestDir { param($dir)
                        Assert-Throws {
                            Assert-Throws { $null = Install-MutWasmOpt -CacheRoot $dir -Force } -MessagePattern 'binaryen download checksum mismatch'
                        } -MessagePattern 'expected an exception but none was thrown'
                    }
                }
            }
    }
}

Describe 'Shared development signing passwords' {
    It 'returns a secure password and keeps whitespace rejection in the Rust caller' {
        Import-Module (Join-Path $consumerModuleDir 'WindowsScripts.Shared.psm1')
        $password = ConvertTo-MsixSigningPassword -Password 'fixture password'
        Assert-True ($password -is [securestring])
        Assert-Equal 'fixture password' ([Net.NetworkCredential]::new('', $password).Password)
        $whitespace = ConvertTo-MsixSigningPassword -Password '  '
        Assert-Equal '  ' ([Net.NetworkCredential]::new('', $whitespace).Password)
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/rust/New-MsixPackage.ps1' -FunctionName New-PasswordSecureString)
        Assert-Throws { New-PasswordSecureString -Password '  ' } -MessagePattern 'non-empty -CertificatePassword is required'
        Assert-True ((New-PasswordSecureString -Password fixture) -is [securestring])
        Import-Module (Join-Path $consumerModuleDir 'WindowsMsix.Signing.psm1')
        $signingPassword = & (Get-Module WindowsMsix.Signing) { ConvertTo-MsixSigningPassword -Password fixture }
        Assert-True ($signingPassword -is [securestring])
    }
}
