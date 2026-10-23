#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Report-only stays the default; -FailOnDeviation and -ExpectedVersion are what a swept project gates on (CON71).

Describe 'Invoke-ClangFormatCheck' {
  BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsFormatting.Common.psm1') -Force

    $script:root = New-TestDir -Prefix 'fmt-check-'
    # --dry-run -Werror <file>: the third argument is the file, and a name with "bad" in it deviates.
    $script:fake = New-TestBatchTool -Directory $script:root -Name 'clang-format.cmd' -Line @(
      'if "%~1"=="--version" (echo clang-format version 23.1.1 & exit /b 0)',
      'echo %~3| findstr /i "bad" >nul && exit /b 1')
    $script:good = Join-Path $script:root 'good.cpp'
    $script:bad = Join-Path $script:root 'bad.cpp'

    function Set-FormatStub([string[]]$Files) {
      $script:stubFiles = $Files
      Mock -ModuleName WindowsFormatting.Common -CommandName Get-Command { [pscustomobject]@{ Source = $script:fake } }
      Mock -ModuleName WindowsFormatting.Common -CommandName Get-ProjectCppFiles { $script:stubFiles }
      Mock -ModuleName WindowsFormatting.Common -CommandName Write-BuildLog { }
    }
    function Invoke-Check { Invoke-ClangFormatCheck -Context ([pscustomobject]@{ }) -WorkspacePath $script:root @args }
    # The default -ExpectedVersion is this pin, so the stand-in's release is it unless a case says otherwise.
    $script:pinBefore = $env:LLVM_WINDOWS_VERSION
    $env:LLVM_WINDOWS_VERSION = '23.1.1'
  }

  AfterAll {
    $env:LLVM_WINDOWS_VERSION = $script:pinBefore
    Remove-TestDir -Path $script:root
  }

  It 'reports a deviating file without failing by default' {
    Set-FormatStub -Files @($script:good, $script:bad)
    { Invoke-Check } | Should -Not -Throw
    Should -Invoke Write-BuildLog -ModuleName WindowsFormatting.Common -ParameterFilter { $Message -like '*1 of 2 files deviate*' }
  }

  It 'fails on a deviating file with -FailOnDeviation, and passes a clean tree' {
    Set-FormatStub -Files @($script:good, $script:bad)
    Assert-Throws -MessagePattern '1 of 2 file\(s\) deviate' -Body { Invoke-Check -FailOnDeviation }
    Set-FormatStub -Files @($script:good)
    { Invoke-Check -FailOnDeviation } | Should -Not -Throw
  }

  It 'refuses a clang-format of another release with -ExpectedVersion' {
    Set-FormatStub -Files @($script:good)
    { Invoke-Check -ExpectedVersion '23.1.1' } | Should -Not -Throw
    Assert-Throws -MessagePattern 'not clang-format 23\.1' -Body { Invoke-Check -ExpectedVersion '23.1' }
  }

  It 'refuses another release by default: LLVM_WINDOWS_VERSION, else versions.env; an explicit empty version skips' {
    Set-FormatStub -Files @($script:good)
    $env:LLVM_WINDOWS_VERSION = '23.1.9'
    try {
      Assert-Throws -MessagePattern 'not clang-format 23\.1\.9' -Body { Invoke-Check }
      $env:LLVM_WINDOWS_VERSION = $null
      $pinned = ((Get-Content (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env')) -match '^LLVM_WINDOWS_VERSION=') -replace '^LLVM_WINDOWS_VERSION=', ''
      Assert-Throws -MessagePattern ('not clang-format ' + [regex]::Escape($pinned)) -Body { Invoke-Check }
      { Invoke-Check -ExpectedVersion '' } | Should -Not -Throw
    } finally {
      $env:LLVM_WINDOWS_VERSION = '23.1.1'
    }
  }

  It 'fails instead of skipping when the gate has no clang-format to run' {
    Set-FormatStub -Files @($script:good)
    Mock -ModuleName WindowsFormatting.Common -CommandName Get-Command { $null }
    Mock -ModuleName WindowsFormatting.Common -CommandName Test-Path { $false }
    Assert-Throws -MessagePattern 'clang-format not found' -Body { Invoke-Check -FailOnDeviation }
    { Invoke-Check } | Should -Not -Throw
  }
}

Describe 'The source walk without a git checkout' {
  BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsFormatting.Common.psm1') -Force
    $script:tree = New-TestDir -Prefix 'fmt-walk-'
    $own = 'src\app.cpp', 'src\CMakeLists.txt', 'windows\flutter\generated_plugin_registrant.cc'
    $untracked = '.opencode\node_modules\msgpackr-extract\src\extract.cpp', 'node_modules\addon\CMakeLists.txt',
      '.pub-cache\hosted\fl_chart\example\linux\main.cc', '.dart_tool\gen.h', 'android\app\.cxx\gen.cpp',
      'android\.gradle\gen.c', '.cargo\registry\src\cc\x.c', 'windows\flutter\ephemeral\cpp_client_wrapper\core.cc'
    foreach ($f in @($own) + @($untracked)) { $null = New-Item -ItemType File -Force -Path (Join-Path $script:tree $f) }
    # A tar-piped container has no .git, so git cannot list the tree.
    Mock -ModuleName WindowsFormatting.Common -CommandName Get-Command -ParameterFilter { $Name -eq 'git' } { $null }
    function Get-Relative([string[]]$Paths) { @($Paths | ForEach-Object { $_.Substring($script:tree.Length + 1) } | Sort-Object) -join ',' }
  }

  AfterAll {
    Remove-TestDir -Path $script:tree
  }

  It 'grades the repository''s own C/C++ files and skips every dependency and output tree' {
    Get-Relative (Get-ProjectCppFiles -WorkspacePath $script:tree) |
      Should -Be 'src\app.cpp,windows\flutter\generated_plugin_registrant.cc'
  }

  It 'skips them for the CMake walk too' {
    Get-Relative (Get-ProjectCmakeFiles -WorkspacePath $script:tree) | Should -Be 'src\CMakeLists.txt'
  }
}
