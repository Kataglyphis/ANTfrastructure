#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Moved up from a consumer repo (BeschleunigerBallett,
# scripts/windows/tests) on 2026-08-07 - see WindowsCMake.Common.Tests.ps1 for
# the rationale. Converted from Pester 3.4 to Pester 5+ syntax in the move.

Describe 'WindowsMsix.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsMsix.Common.psm1'
    Import-Module $modulePath -Force

    $script:tmp = (New-Item -ItemType Directory `
        -Path (Join-Path $env:TEMP ('msix-common-' + (Get-Random))) -Force).FullName
  }

  AfterAll {
    Remove-Item -LiteralPath $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Expand-XmlTemplateTokens' {
    It 'XML-escapes the substituted value' {
      Expand-XmlTemplateTokens -Template '<root>__TOKEN__</root>' -TokenMap @{ '__TOKEN__' = 'A & B <C>' } |
        Should -Be '<root>A &amp; B &lt;C&gt;</root>'
    }
  }

  Context 'Resolve-WindowsSdkToolPath' {
    It 'returns $null when the tool is on neither PATH nor any SDK candidate directory' {
      # Both mocks must be -ModuleName scoped: the function calls Get-Command
      # and Test-Path from inside the module. Test-Path must be mocked too,
      # otherwise the Windows Kits scan below runs against the real host and a
      # machine with the SDK installed would resolve a real path.
      Mock -ModuleName WindowsMsix.Common -CommandName Get-Command { return $null }
      Mock -ModuleName WindowsMsix.Common -CommandName Test-Path { return $false }

      Resolve-WindowsSdkToolPath -ToolName 'nonexistent.exe' -OverridePath $null | Should -BeNullOrEmpty
    }

    It 'throws when an explicit override path does not exist' {
      Mock -ModuleName WindowsMsix.Common -CommandName Test-Path { return $false }

      { Resolve-WindowsSdkToolPath -ToolName 'signtool.exe' -OverridePath 'C:\does\not\exist.exe' } |
        Should -Throw -ExpectedMessage '*does not exist*'
    }
  }

  Context 'New-TransparentPng' {
    It 'writes a non-empty PNG file' {
      $out = Join-Path $script:tmp 't.png'
      New-TransparentPng -Path $out -Width 16 -Height 16

      Test-Path $out | Should -BeTrue
      (Get-Item -LiteralPath $out).Length | Should -BeGreaterThan 0
    }
  }
}
