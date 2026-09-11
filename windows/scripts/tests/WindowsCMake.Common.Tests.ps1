#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Moved up from a consumer repo (BeschleunigerBallett,
# scripts/windows/tests) on 2026-08-07. The module was upstreamed on
# 2026-08-02 but its suite stayed behind, so this repo could change
# WindowsCMake.Common with no test signal of its own - the only thing
# exercising it was a consumer's opt-in Windows lane.
#
# Converted from Pester 3.4 dash-less syntax to Pester 5+ in the move: the
# consumer pinned Pester 3.4.0, Invoke-Tests.ps1 here requires >= 5.0.

Describe 'WindowsCMake.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsCMake.Common.psm1'
    Import-Module $modulePath -Force

    $script:buildRoot = (New-Item -ItemType Directory `
        -Path (Join-Path $env:TEMP ('cmake-common-' + (Get-Random))) -Force).FullName
  }

  AfterAll {
    Remove-Item -LiteralPath $script:buildRoot -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Get-CompileCommandsDatabase' {
    It 'throws when neither compile_commands.json nor build.ninja exists' {
      # -ModuleName is required: Get-CompileCommandsDatabase calls Test-Path
      # from inside the module, which an unscoped mock never reaches - the
      # test would then hit the real filesystem and pass for the wrong reason.
      Mock -ModuleName WindowsCMake.Common -CommandName Test-Path { return $false }

      { Get-CompileCommandsDatabase -Context ([pscustomobject]@{ }) -BuildRoot $script:buildRoot } |
        Should -Throw -ExpectedMessage '*compile_commands.json not found*'
    }

    It 'returns the existing compile_commands.json when present' {
      $compilePath = Join-Path $script:buildRoot 'compile_commands.json'
      Set-Content -Path $compilePath -Value '[{"file":"a.cpp"}]' -Encoding utf8

      Get-CompileCommandsDatabase -Context ([pscustomobject]@{ }) -BuildRoot $script:buildRoot |
        Should -Be $compilePath
    }
  }

  Context 'Get-SanitizerRuntimeDlls' {
    It 'stages the runtime Get-AsanRuntimeDirs selects, not clang-cl-on-PATH' {
      # Regression (2026-09-11): this used to walk clang-cl-on-PATH roots
      # first, so inside the Windows image it staged LLVM's DLL while the
      # shared cmake/Sanitizers.cmake links Microsoft's -- every
      # ASAN-instrumented build tool then died at load with
      # STATUS_ENTRYPOINT_NOT_FOUND. Delegation to the one owner of the
      # selection policy (WindowsTesting.Common) is the contract under test.
      $fakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("kataglyphis-asan-fake-" + $PID)
      $null = New-Item -ItemType Directory -Path $fakeDir -Force
      $fakeDll = Join-Path $fakeDir 'clang_rt.asan_dynamic-x86_64.dll'
      Set-Content -Path $fakeDll -Value 'x'

      try {
        InModuleScope WindowsCMake.Common {
          $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("kataglyphis-asan-fake-" + $PID)
          Mock Get-AsanRuntimeDirs { @($dir) }

          $result = @(Get-SanitizerRuntimeDlls)
          $result.Count | Should -Be 1
          $result[0].FullName | Should -Be (Join-Path $dir 'clang_rt.asan_dynamic-x86_64.dll')
        }
      } finally {
        Remove-Item -LiteralPath $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
      }
    }

    It 'returns an empty array when no runtime directory is selected' {
      InModuleScope WindowsCMake.Common {
        Mock Get-AsanRuntimeDirs { @() }

        $result = @(Get-SanitizerRuntimeDlls)
        $result.Count | Should -Be 0
      }
    }
  }
}
