#requires -Version 7.0
# Fake commands cover scratch, argv and verdict lifecycles; installed compiler, GPU and Python behavior is outside this suite.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSmokeTest.Common.psm1') -Force -DisableNameChecking

Describe 'Smoke command and compilation operations' {
    It 'builds fresh sources, forwards ordered arguments and removes scratch after success and failure' {
        $state = New-TestCallState @{ Code = 0; Content = 'compiled'; Directory = ''; Source = '' }
        Invoke-WithTestNativeCommand -Name Invoke-SmokeFixtureCompiler -Implementation { param($state, $ArgumentList)
            $at = [array]::IndexOf($ArgumentList, '-o')
            $state.Source = [IO.File]::ReadAllText($ArgumentList[$at - 1])
            $state.Directory = Split-Path $ArgumentList[$at - 1] -Parent
            [IO.File]::WriteAllText($ArgumentList[$at + 1], $state.Content)
        } -FixtureState $state -Body { param($state)
            $options = @{ WorkName = 'fixture'; SourceName = 'in.c'; Source = 'fresh source'; OutputName = 'out.obj'; Compiler = 'Invoke-SmokeFixtureCompiler'; ArgumentList = @('-before', 'a b'); AfterArgument = @('-after', 'x;y') }
            Assert-True (Invoke-SmokeCompilation @options)
            Assert-Equal 'fresh source' $state.Source
            Assert-Equal '-before|a b|in.c|-o|out.obj|-after|x;y' (($state.Calls[0] | ForEach-Object { if ($_ -like '*in.c' -or $_ -like '*out.obj') { Split-Path $_ -Leaf } else { $_ } }) -join '|')
            Assert-False (Test-Path -LiteralPath $state.Directory) 'successful compilation cleans its directory'
            $first = $state.Directory
            $state.Code = 8
            Assert-False (Invoke-SmokeCompilation @options) 'a created artifact cannot excuse compiler failure'
            Assert-False (Test-Path -LiteralPath $state.Directory) 'failed compilation cleans its directory'
            Assert-False ($state.Directory -eq $first) 'each invocation owns a new directory'
            $state.Code = 0; $state.Content = ''
            Assert-False (Invoke-SmokeCompilation @options) 'empty output cannot pass'
        }
    }

    It 'cleans scratch when the body throws and rejects a compiler that emits no file' {
        $state = New-TestCallState @{ Directory = '' }
        $scratchBody = { param($dir) $state.Directory = $dir; throw 'body failed' }.GetNewClosure()
        Assert-Throws {
            Invoke-WithSmokeScratch -Name 'throw' -Body $scratchBody
        } -MessagePattern 'body failed'
        Assert-False (Test-Path -LiteralPath $state.Directory)
        Invoke-WithTestFunction -Name Invoke-SmokeNoArtifact -Definition { $global:LASTEXITCODE = 0 } -Body {
            Assert-False (Invoke-SmokeCompilation -WorkName missing -SourceName in.c -Source test -OutputName out.obj -Compiler Invoke-SmokeNoArtifact)
        }
    }

    It 'requires every output pattern and a successful command before counting the assertion' {
        $state = New-TestCallState @{ Code = 0 }
        Invoke-WithTestNativeCommand -Name Invoke-SmokeFixtureOutput -Implementation { param($state, $ArgumentList)
            'first'; 'second'
        } -FixtureState $state -Body { param($state)
            Assert-True (Test-SmokeCommandOutput -Command Invoke-SmokeFixtureOutput -ArgumentList @('a b', 'x;y') -ExpectMatch @('first', 'second'))
            Assert-Equal 'a b|x;y' ($state.Calls[0] -join '|')
            Assert-False (Test-SmokeCommandOutput -Command Invoke-SmokeFixtureOutput -ExpectMatch @('first', 'absent'))
            $state.Code = 9
            Assert-False (Test-SmokeCommandOutput -Command Invoke-SmokeFixtureOutput -ExpectMatch first)
            Initialize-SmokeTestRun
            Assert-SmokeCommandOutput -Name fixture -Command Invoke-SmokeFixtureOutput -ExpectMatch first -FailMessage 'nonzero fixture'
            Assert-Equal 1 (Get-SmokeTestSummary).Failed
        }
    }

    It 'keeps native section execution and cross-lane skip accounting separate' {
        Initialize-SmokeTestRun
        Assert-True (Test-SmokeNativeSection -Name 'fixture' -TargetArch arm64)
        Assert-Equal 0 (Get-SmokeTestSummary).Total
        Assert-False (Test-SmokeNativeSection -Name 'fixture' -TargetArch arm64 -CrossTarget)
        Assert-Equal 1 (Get-SmokeTestSummary).Skipped
    }

    It 'keeps optional roots distinct from required directory assertions and writes ASCII source maps' {
        Invoke-InTestDir -Files @{ 'nested\artifact.dll' = 'artifact' } -Body { param($dir)
            Invoke-WithEnv @{ ANT_SMOKE_ROOT = $dir; ANT_SMOKE_ABSENT = $null } {
                Initialize-SmokeTestRun
                Assert-Equal $dir (Get-SmokeInstallRoot -Name ANT_SMOKE_ROOT)
                Assert-Equal 1 (Get-SmokeTestSummary).Passed
                Assert-Equal $dir (Get-SmokeExistingInstallRoot -Name ANT_SMOKE_ROOT)
                Assert-Equal (Join-Path $dir nested) (Get-SmokeArtifactDirectory -EnvironmentName ANT_SMOKE_ROOT -Filter artifact.dll)
                Assert-Null (Get-SmokeInstallRoot -Name ANT_SMOKE_ABSENT)
                Assert-Equal 1 (Get-SmokeTestSummary).Skipped
                Assert-Null (Get-SmokeExistingInstallRoot -Name ANT_SMOKE_ABSENT)
            }
            Invoke-WithEnv @{ ANT_SMOKE_ROOT = (Join-Path $dir missing) } {
                Assert-Equal $env:ANT_SMOKE_ROOT (Get-SmokeInstallRoot -Name ANT_SMOKE_ROOT) 'a missing required root remains available to its artifact gates'
                Assert-Equal 1 (Get-SmokeTestSummary).Failed
                Assert-Null (Get-SmokeExistingInstallRoot -Name ANT_SMOKE_ROOT) 'an optional absent tree is skipped by its caller'
            }
            Set-SmokeSourceFiles -Directory $dir -Files @{ 'one.cpp' = 'one'; 'two.cmake' = 'two' }
            Assert-Equal ("one" + [Environment]::NewLine) ([IO.File]::ReadAllText((Join-Path $dir one.cpp)))
            Assert-Equal ("two" + [Environment]::NewLine) ([IO.File]::ReadAllText((Join-Path $dir two.cmake)))
        }
    }

    It 'requires an empty finding list and preserves assertion failure and abort accounting' {
        Initialize-SmokeTestRun
        Assert-Test -Name clear -Finding @() -FailMessage clear
        Assert-Test -Name missing -Finding @('missing artifact') -FailMessage 'missing artifact'
        Assert-Equal 1 (Get-SmokeTestSummary).Passed
        Assert-Equal 1 (Get-SmokeTestSummary).Failed
        Assert-Match 'missing artifact' ((Get-SmokeTestSummary).FailureDetails -join '|')
        Initialize-SmokeTestRun -ExitOnFirstFailure
        Assert-Test -Name missing -Finding @('missing artifact') -FailMessage missing
        Assert-Test -Name suppressed -Finding @()
        Assert-Equal 1 (Get-SmokeTestSummary).Total
        Assert-True (Get-SmokeTestSummary).Aborted
    }

    It 'detects a finding verdict that accepts nonempty findings' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSmokeTest.Common.psm1' `
            -FunctionName Initialize-SmokeTestRun, Get-SmokeTestSummary, Complete-SmokeSection, Assert-Test, Request-SmokeAbort `
            -Find '@($Finding).Count -eq 0' -Replace '@($Finding).Count -ge 0' -Body {
            Initialize-MutSmokeTestRun
            Assert-MutTest -Name missing -Finding @('missing artifact')
            Assert-Throws { Assert-Equal 1 (Get-MutSmokeTestSummary).Failed 'nonempty findings must fail' } -MessagePattern 'nonempty findings must fail'
        }
    }

    It 'keeps every FFmpeg listing requirement observable for native, cross, NVIDIA and ROCm policies' {
        $checks = @(
            @{ Cross = $false; Nvidia = $false; Rocm = $false; Expected = 'h264_nvenc,hevc_nvenc|h264_cuvid|h264_amf,hevc_amf' }
            @{ Cross = $false; Nvidia = $true; Rocm = $false; Expected = 'h264_nvenc,hevc_nvenc|h264_cuvid|h264_amf,hevc_amf' }
            @{ Cross = $false; Nvidia = $false; Rocm = $true; Expected = '' }
            @{ Cross = $false; Nvidia = $true; Rocm = $true; Expected = 'h264_nvenc,hevc_nvenc|h264_cuvid' }
            @{ Cross = $true; Nvidia = $false; Rocm = $false; Expected = '' }
            @{ Cross = $true; Nvidia = $true; Rocm = $false; Expected = 'h264_nvenc,hevc_nvenc|h264_cuvid' }
            @{ Cross = $true; Nvidia = $false; Rocm = $true; Expected = '' }
            @{ Cross = $true; Nvidia = $true; Rocm = $true; Expected = 'h264_nvenc,hevc_nvenc|h264_cuvid' }
        )
        foreach ($case in $checks) {
            $plan = @(Get-FfmpegSmokeListingCheck -Nvidia:$case.Nvidia -CrossTarget:$case.Cross -Rocm:$case.Rocm)
            Assert-Equal $case.Expected (($plan | ForEach-Object { $_.Expect -join ',' }) -join '|')
            foreach ($check in $plan) {
                Assert-True ($check.Listing -in @('-encoders', '-decoders'))
                Assert-True ([bool]$check.Name -and [bool]$check.Failure) 'each required listing retains its own counted diagnostic'
            }
        }
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSmokeTest.Common.psm1' -FunctionName Get-FfmpegSmokeListingCheck -Find '$Nvidia -or $nativeDefault' -Replace '$Nvidia' -Body {
            Assert-Throws { Assert-Equal 3 @(Get-MutFfmpegSmokeListingCheck).Count 'native default still requires NVIDIA codec tables' } -MessagePattern 'native default still requires NVIDIA codec tables'
        }
    }

    It 'finds nested artifacts and prefers a companion beside the invoking script' {
        Invoke-InTestDir -Files @{ 'nested\artifact.dll' = 'artifact'; 'fixture.ps1' = 'companion' } -Body { param($dir)
            Assert-Equal 'artifact.dll' (Find-SmokeArtifact -Root $dir -Filter artifact.dll).Name
            Assert-Null (Find-SmokeArtifact -Root $dir -Filter absent.dll)
            Assert-Equal (Join-Path $dir 'fixture.ps1') (Resolve-SmokeCompanion -ScriptRoot $dir -Name fixture.ps1)
            Assert-Null (Resolve-SmokeCompanion -ScriptRoot $dir -Name ('missing-' + [guid]::NewGuid() + '.ps1'))
        }
    }

    It 'detects allowing an empty compiled artifact' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSmokeTest.Common.psm1' -FunctionName Test-SmokeCompiledArtifact -Find '.Length -gt 0' -Replace '.Length -ge 0' -Body {
            Invoke-InTestDir { param($dir)
                $output = Join-Path $dir empty.obj
                [IO.File]::WriteAllText($output, '')
                Invoke-WithTestFunction -Name Invoke-SmokeNoArtifact -Definition { $global:LASTEXITCODE = 0 } -BodyArgumentList $output -Body { param($output)
                    Assert-Throws { Assert-False (Test-MutSmokeCompiledArtifact -Compiler Invoke-SmokeNoArtifact -OutputPath $output) 'empty compiled artifacts must fail' } -MessagePattern 'empty compiled artifacts must fail'
                }
            }
        }
    }

    It 'keeps internal commands visible when a cold consumer imports the smoke module privately' {
        Invoke-InTestDir { param($dir)
            $compiler = Join-Path $dir compiler.cmd
            [IO.File]::WriteAllText($compiler, "@echo off`r`necho compiled > `"%~3`"`r`nexit /b 0`r`n")
            $module = Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSmokeTest.Common.psm1'
            $probe = @'
param($module, $compiler)
$ErrorActionPreference = 'Stop'
$consumer = New-Module -Name SmokeNestedConsumer -ArgumentList $module -ScriptBlock {
    param($module)
    Import-Module $module -DisableNameChecking
    function Invoke-ConsumerSmoke {
        param($compiler)
        Initialize-SmokeTestRun
        Assert-PythonSnippet -Name command -Python (Get-Process -Id $PID).Path -Code "Write-Output nested-ok" -ExpectMatch nested-ok -FailMessage nested-failed
        if (-not (Invoke-SmokeCompilation -WorkName nested -SourceName in.c -Source fixture -OutputName out.obj -Compiler $compiler)) { throw 'compile failed' }
        if (Test-SmokeNativeSection -Name nested -TargetArch arm64 -CrossTarget) { throw 'cross section ran' }
        $summary = Get-SmokeTestSummary
        if ($summary.Passed -ne 1 -or $summary.Failed -ne 0 -or $summary.Skipped -ne 1) { throw 'bad nested accounting' }
        'nested-smoke-ok'
    }
    Export-ModuleMember -Function Invoke-ConsumerSmoke
}
Import-Module $consumer -DisableNameChecking
Invoke-ConsumerSmoke $compiler
'@
            $child = Join-Path $dir child.ps1
            [IO.File]::WriteAllText($child, $probe)
            $output = & pwsh -NoProfile -NonInteractive -File $child $module $compiler 2>&1 | Out-String
            Assert-Equal 0 $LASTEXITCODE $output
            Assert-Match nested-smoke-ok $output
        }
    }
}
