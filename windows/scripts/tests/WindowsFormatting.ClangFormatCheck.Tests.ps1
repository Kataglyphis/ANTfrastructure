#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Report-only stays the default; -FailOnDeviation and -ExpectedVersion are what a swept project gates on (CON71).

Describe 'Invoke-ClangFormatCheck' {
  BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsFormatting.Common.psm1') -Force

    $script:root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('fmt-check-' + (Get-Random))) -Force).FullName
    $script:fake = Join-Path $script:root 'clang-format.cmd'
    # --dry-run -Werror <file>: the third argument is the file, and a name with "bad" in it deviates.
    Set-Content -LiteralPath $script:fake -Encoding ascii -Value @(
      '@echo off',
      'if "%~1"=="--version" (echo clang-format version 23.1.1 & exit /b 0)',
      'echo %~3| findstr /i "bad" >nul && exit /b 1',
      'exit /b 0')
    $script:good = Join-Path $script:root 'good.cpp'
    $script:bad = Join-Path $script:root 'bad.cpp'

    function Set-FormatStub([string[]]$Files) {
      $script:stubFiles = $Files
      Mock -ModuleName WindowsFormatting.Common -CommandName Get-Command { [pscustomobject]@{ Source = $script:fake } }
      Mock -ModuleName WindowsFormatting.Common -CommandName Get-ProjectCppFiles { $script:stubFiles }
      Mock -ModuleName WindowsFormatting.Common -CommandName Write-BuildLog { }
    }
    function Invoke-Check { Invoke-ClangFormatCheck -Context ([pscustomobject]@{ }) -WorkspacePath $script:root @args }
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
  }

  It 'reports a deviating file without failing by default' {
    Set-FormatStub -Files @($script:good, $script:bad)
    { Invoke-Check } | Should -Not -Throw
    Should -Invoke Write-BuildLog -ModuleName WindowsFormatting.Common -ParameterFilter { $Message -like '*1 of 2 files deviate*' }
  }

  It 'fails on a deviating file with -FailOnDeviation, and passes a clean tree' {
    Set-FormatStub -Files @($script:good, $script:bad)
    { Invoke-Check -FailOnDeviation } |
      Should -Throw -ExpectedMessage '1 of 2 file(s) deviate*'
    Set-FormatStub -Files @($script:good)
    { Invoke-Check -FailOnDeviation } | Should -Not -Throw
  }

  It 'refuses a clang-format of another release with -ExpectedVersion' {
    Set-FormatStub -Files @($script:good)
    { Invoke-Check -ExpectedVersion '23.1.1' } | Should -Not -Throw
    { Invoke-Check -ExpectedVersion '23.1' } |
      Should -Throw -ExpectedMessage "*not clang-format 23.1"
  }

  It 'fails instead of skipping when the gate has no clang-format to run' {
    Set-FormatStub -Files @($script:good)
    Mock -ModuleName WindowsFormatting.Common -CommandName Get-Command { $null }
    Mock -ModuleName WindowsFormatting.Common -CommandName Test-Path { $false }
    { Invoke-Check -FailOnDeviation } |
      Should -Throw -ExpectedMessage 'clang-format not found*'
    { Invoke-Check } | Should -Not -Throw
  }
}
