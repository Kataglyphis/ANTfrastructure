#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Real metadata fixtures and callback observers cover version selection, not compiled wheels or device execution.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.CallAssertions.psm1') -ErrorAction Stop

function script:Invoke-TvmFfiVersionFixture {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $prelude = @'
param($State)
$script:ffiState = $State
function Get-TvmFfiSourceVersion { param($SourceDir) $script:ffiState.Source = $SourceDir; '0.1.14.post0' }
function Assert-TvmFfiPackageVersion {
    param($Python, $ExpectedVersion, $WheelPath)
    $script:ffiState.Checks.Add(@($Python.Exe, $ExpectedVersion, $WheelPath))
    if ($script:ffiState.FailCheck) { throw 'fixture metadata refusal' }
}
'@
    $state = [pscustomobject]@{ Source = ''; Checks = [Collections.Generic.List[object]]::new(); FailCheck = $false }
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsTvm.Common.psm1' -FunctionName Invoke-TvmFfiPythonBuild -Prelude $prelude -ArgumentList @($state) `
        -Body $Body -BodyArgumentList @($state)
}

Describe 'TVM-FFI source version and process environment' {
    It 'uses the nearest release tag and falls back when the real git probe fails' {
        Invoke-InTestDir -Files @{ 'pyproject.toml' = '[project]`ndependencies = ["apache-tvm-ffi>=0.1.14.post0"]' } -Body { param($dir)
            $state = [pscustomobject]@{ ExitCode = 0; Text = 'v0.1.13-post3'; Args = @() }
            $prelude = 'param($State); $script:ffiState = $State; function Invoke-NativeProbeProcess { param($FilePath, $ArgumentList) $script:ffiState.Args = @($FilePath) + $ArgumentList; $script:ffiState }'
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsTvm.Common.psm1' -FunctionName Get-TvmFfiSourceVersion -Prelude $prelude -ArgumentList @($state) `
                -BodyArgumentList @($state, $dir) -Body { param($fixture, $root)
                    Assert-Equal '0.1.13.post3' (Get-MutTvmFfiSourceVersion -SourceDir $root)
                    Assert-TestSequence -Actual $fixture.Args -Expected @('git', '-C', (Join-Path $root '3rdparty/tvm-ffi'), 'describe', '--tags', '--abbrev=0', '--match', 'v*')
                    $fixture.ExitCode = 128; $fixture.Text = 'v99.0'
                    Assert-Equal '0.1.14.post0' (Get-MutTvmFfiSourceVersion -SourceDir $root) 'failed probe output cannot become a release tag'
                }
        }
    }

    It 'scopes both build kinds, preserves the global override and restores the specific one' {
        Invoke-WithProcessEnvironment -Environment @{ SETUPTOOLS_SCM_PRETEND_VERSION = '9.9.0'; SETUPTOOLS_SCM_PRETEND_VERSION_FOR_APACHE_TVM_FFI = 'prior' } -ScriptBlock {
            Invoke-TvmFfiVersionFixture -Body { param($state)
                foreach ($wheel in $false, $true) {
                    $result = Invoke-MutTvmFfiPythonBuild -Python @{ Exe = 'fixture-python' } -SourceDir 'fixture-source' -Wheel:$wheel -Build {
                        Assert-Equal '0.1.14.post0' $env:SETUPTOOLS_SCM_PRETEND_VERSION_FOR_APACHE_TVM_FFI
                        Assert-Equal '9.9.0' $env:SETUPTOOLS_SCM_PRETEND_VERSION
                        if ($wheel) { 'fixture twin.whl' }
                    }
                    Assert-Equal 'prior' $env:SETUPTOOLS_SCM_PRETEND_VERSION_FOR_APACHE_TVM_FFI
                    Assert-Equal $(if ($wheel) { 'fixture twin.whl' } else { $null }) $result
                }
                Assert-Equal 'fixture-source' $state.Source
                Assert-Equal 2 $state.Checks.Count
                Assert-TestSequence -Actual $state.Checks[0] -Expected @('fixture-python', '0.1.14.post0', '')
                Assert-TestSequence -Actual $state.Checks[1] -Expected @('fixture-python', '0.1.14.post0', 'fixture twin.whl')
            }
        }
    }

    It 'propagates build and metadata failures and retains a legitimate absent twin' {
        Invoke-WithProcessEnvironment -Environment @{ SETUPTOOLS_SCM_PRETEND_VERSION_FOR_APACHE_TVM_FFI = 'prior' } -ScriptBlock {
            Invoke-TvmFfiVersionFixture -Body { param($state)
                Assert-Throws { Invoke-MutTvmFfiPythonBuild -Python @{ Exe = 'p' } -SourceDir s -Build { throw 'fixture build failed' } } -MessagePattern 'fixture build failed'
                Assert-Equal 'prior' $env:SETUPTOOLS_SCM_PRETEND_VERSION_FOR_APACHE_TVM_FFI
                Assert-Equal 0 $state.Checks.Count
                Assert-Null (Invoke-MutTvmFfiPythonBuild -Python @{ Exe = 'p' } -SourceDir s -Wheel -Build { $null })
                Assert-Equal 0 $state.Checks.Count
                $state.FailCheck = $true
                Assert-Throws { Invoke-MutTvmFfiPythonBuild -Python @{ Exe = 'p' } -SourceDir s -Build {} } -MessagePattern 'fixture metadata refusal'
                Assert-Equal 'prior' $env:SETUPTOOLS_SCM_PRETEND_VERSION_FOR_APACHE_TVM_FFI
            }
        }
    }

    It 'wraps the real GIL install and twin build while the cross path uses the same selector' {
        $calls = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-TvmFromSource.ps1' -Name Invoke-TvmFfiPythonBuild)
        Assert-Equal 2 $calls.Count
        Assert-Equal 1 @(Get-TestAstCommands -Ast $calls[0] -Name Invoke-CpythonPip).Count
        Assert-Equal 1 @(Get-TestAstCommands -Ast $calls[1] -Name Invoke-FreeThreadedTwinWheel).Count
        Assert-False ('-Wheel' -in @($calls[0].CommandElements.Extent.Text))
        Assert-True ('-Wheel' -in @($calls[1].CommandElements.Extent.Text))
        Assert-TestAstCommand -Command @(Get-TestScriptCommands -ScriptPath 'windows/scripts/build/Build-TvmFromSource.ps1' -Name Get-TvmFfiSourceVersion) `
            -Text 'Get-TvmFfiSourceVersion -SourceDir $SourceDir' -Assignment '$ffiVersion'
    }
}

Describe 'TVM-FFI installed and wheel metadata gate' {
    BeforeAll {
        $script:ffiRoot = New-TestDir -Prefix 'tvm-ffi-metadata-'
        $hostPython = @(Get-Command python, python3 -CommandType Application -ErrorAction SilentlyContinue)[0].Source
        $venv = Join-Path $script:ffiRoot 'isolated python'
        & $hostPython -I -m venv --without-pip $venv | Out-Host
        Assert-Equal 0 $LASTEXITCODE 'create a real isolated metadata environment'
        $script:ffiPython = @{ Exe = (Join-Path $venv $(if ($IsWindows) { 'Scripts/python.exe' } else { 'bin/python' })) }
        $script:ffiSite = (& $script:ffiPython.Exe -I -c 'import sysconfig; print(sysconfig.get_path("purelib"))').Trim()
        Assert-Equal 0 $LASTEXITCODE
        $script:ffiDist = 'apache_tvm_ffi-0.1.14.post0.dist-info/METADATA'
    }
    AfterAll { Remove-TestDir -Path $script:ffiRoot }

    It 'reads actual installed metadata and rejects a development version, wrong name or absent distribution' {
        foreach ($case in @(
            @{ Name = 'apache-tvm-ffi'; Version = '0.1.14.post0'; Failure = '' },
            @{ Name = 'apache-tvm-ffi'; Version = '0.1.dev1+gdaf594da8'; Failure = 'differs from selected' },
            @{ Name = 'another-package'; Version = '0.1.14.post0'; Failure = 'Expected exactly one' }
        )) {
            Write-TestFileTree -Root $script:ffiSite -Files @{ $script:ffiDist = "Metadata-Version: 2.1`nName: $($case.Name)`nVersion: $($case.Version)`n" }
            $check = { Assert-TvmFfiPackageVersion -Python $script:ffiPython -ExpectedVersion '0.1.14.post0' }
            if ($case.Failure) { Assert-Throws $check -MessagePattern $case.Failure } else { & $check }
        }
        Write-TestFileTree -Root $script:ffiSite -Files @{
            $script:ffiDist = "Name: apache-tvm-ffi`nVersion: 0.1.14.post0`n"
            'apache_tvm_ffi-0.1.dev1.dist-info/METADATA' = "Name: apache-tvm-ffi`nVersion: 0.1.dev1`n"
        }
        Assert-Throws { Assert-TvmFfiPackageVersion -Python $script:ffiPython -ExpectedVersion '0.1.14.post0' } -MessagePattern 'Expected exactly one'
        Remove-Item -LiteralPath (Join-Path $script:ffiSite 'apache_tvm_ffi-0.1.dev1.dist-info') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $script:ffiSite 'apache_tvm_ffi-0.1.14.post0.dist-info') -Recurse -Force
        Assert-Throws { Assert-TvmFfiPackageVersion -Python $script:ffiPython -ExpectedVersion '0.1.14.post0' } -MessagePattern 'Expected exactly one'
    }

    It 'reads the saved twin archive and refuses wrong versions, multiple distributions and missing metadata' {
        foreach ($kind in 'valid', 'development', 'multiple', 'empty') {
            $members = @{}
            if ($kind -ne 'empty') {
                $version = if ($kind -eq 'development') { '0.1.dev1' } else { '0.1.14.post0' }
                $members[$script:ffiDist] = "Metadata-Version: 2.1`nName: apache_tvm_ffi`nVersion: $version`n"
            }
            if ($kind -eq 'multiple') { $members['other-1.dist-info/METADATA'] = "Name: other`nVersion: 1`n" }
            $wheel = New-TestWheel -Path (Join-Path $script:ffiRoot "$kind twin.whl") -Member $members
            $check = { Assert-TvmFfiPackageVersion -Python $script:ffiPython -ExpectedVersion '0.1.14.post0' -WheelPath $wheel }
            if ($kind -eq 'valid') { & $check } else {
                $pattern = if ($kind -eq 'development') { 'differs from selected' } else { 'Expected exactly one' }
                Assert-Throws $check -MessagePattern $pattern
            }
        }
    }
}
