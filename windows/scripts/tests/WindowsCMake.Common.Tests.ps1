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
}
