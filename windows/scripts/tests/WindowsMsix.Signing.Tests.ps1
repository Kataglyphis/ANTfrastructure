#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Moved up from a consumer repo (Kataglyphis-BeschleunigerBallett,
# scripts/windows/tests) on 2026-08-07 - see WindowsCMake.Common.Tests.ps1 for
# the rationale.
#
# Rewritten rather than transliterated. The Pester 3.4 original tried to
# neutralize signtool by REDEFINING functions (`function Resolve-WindowsSdkToolPath
# { $null }`) in the suite's own scope, which never reaches a call made from
# inside the module - so two of its three cases ended at `$true | Should Be $true`
# and asserted nothing. Module-scoped mocks plus the module's own
# -InvokerScriptBlock seam let each case assert what actually happened.

Describe 'WindowsMsix.Signing' {
  BeforeAll {
    $modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
    foreach ($m in @('WindowsScripts.Shared', 'WindowsBuild.Common', 'WindowsConfig.Common',
        'WindowsMsix.Common', 'WindowsMsix.Signing')) {
      Import-Module (Join-Path $modDir "$m.psm1") -Force -DisableNameChecking
    }

    $script:workspace = (New-Item -ItemType Directory `
        -Path (Join-Path $env:TEMP ('msix-signing-' + (Get-Random))) -Force).FullName
    $script:ctx = New-BuildContext -Workspace $script:workspace `
      -LogDir (Join-Path $script:workspace 'logs')
    $script:msixOut = Join-Path $script:workspace 'out.msix'
  }

  AfterAll {
    Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
  }

  BeforeEach {
    # Never import a certificate into the machine store from a test run, and
    # never depend on the runner being elevated: the not-Administrator branch
    # only logs a warning.
    Mock -ModuleName WindowsMsix.Signing -CommandName Test-Administrator { return $false }
    Get-ChildItem -Path $script:workspace -Filter '*.pfx' -File -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
  }

  Context 'Invoke-MsixSign' {
    It 'does not invoke signtool when it cannot be resolved' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath { return $null }
      New-Item -Path (Join-Path $script:workspace 'test.pfx') -ItemType File -Force | Out-Null

      $script:calls = [System.Collections.Generic.List[object]]::new()
      $invoker = { param($Context, $File, $Parameters) $script:calls.Add($Parameters); return 0 }

      Invoke-MsixSign -Context $script:ctx -WorkspacePath $script:workspace `
        -MsixOutPath $script:msixOut -InvokerScriptBlock $invoker

      $script:calls.Count | Should -Be 0
    }

    It 'does not invoke signtool when the workspace holds no .pfx' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath { return 'C:\signtool.exe' }

      $script:calls = [System.Collections.Generic.List[object]]::new()
      $invoker = { param($Context, $File, $Parameters) $script:calls.Add($Parameters); return 0 }

      Invoke-MsixSign -Context $script:ctx -WorkspacePath $script:workspace `
        -MsixOutPath $script:msixOut -InvokerScriptBlock $invoker

      $script:calls.Count | Should -Be 0
    }

    It 'signs and then verifies when a .pfx is present' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath { return 'C:\signtool.exe' }
      New-Item -Path (Join-Path $script:workspace 'test.pfx') -ItemType File -Force | Out-Null

      $script:calls = [System.Collections.Generic.List[object]]::new()
      $invoker = { param($Context, $File, $Parameters) $script:calls.Add($Parameters); return 0 }

      Invoke-MsixSign -Context $script:ctx -WorkspacePath $script:workspace `
        -MsixOutPath $script:msixOut -InvokerScriptBlock $invoker

      $script:calls.Count | Should -Be 2
      $script:calls[0][0] | Should -Be 'sign'
      $script:calls[0] | Should -Contain $script:msixOut
      $script:calls[1][0] | Should -Be 'verify'
      $script:calls[1] | Should -Contain $script:msixOut
    }
  }
}
