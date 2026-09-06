#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Moved up from a consumer repo (BeschleunigerBallett,
# scripts/windows/tests) on 2026-08-07 - see WindowsCMake.Common.Tests.ps1 for
# the rationale. Converted from Pester 3.4 to Pester 5+ syntax in the move.

Describe 'WindowsConfig.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsConfig.Common.psm1'
    Import-Module $modulePath -Force
  }

  Context 'Get-ConfigValue' {
    It 'returns the nested value when the path exists' {
      $cfg = @{ Build = @{ WorkspaceRootEnv = 'WORKSPACE' } }
      Get-ConfigValue -Config $cfg -Path 'Build.WorkspaceRootEnv' | Should -Be 'WORKSPACE'
    }

    It 'returns $null for a missing path' {
      $cfg = @{ A = @{ B = 1 } }
      Get-ConfigValue -Config $cfg -Path 'A.C' | Should -BeNullOrEmpty
    }
  }

  Context 'Get-SelectedConfigurations' {
    It 'expands "all" into every available configuration' {
      $set = Get-SelectedConfigurations -Configurations @('all') -AvailableConfigurations @('a', 'b', 'c')

      $set.Contains('a') | Should -BeTrue
      $set.Contains('b') | Should -BeTrue
      $set.Contains('c') | Should -BeTrue
    }

    It 'parses comma-separated values and normalizes case and whitespace' {
      $set = Get-SelectedConfigurations -Configurations @('MSVC-DEBUG, clangcl-release') `
        -AvailableConfigurations @('msvc-debug', 'clangcl-release')

      $set.Contains('msvc-debug') | Should -BeTrue
      $set.Contains('clangcl-release') | Should -BeTrue
    }

    It 'throws on an unknown configuration' {
      { Get-SelectedConfigurations -Configurations @('unknown') -AvailableConfigurations @('x') } |
        Should -Throw
    }
  }
}
