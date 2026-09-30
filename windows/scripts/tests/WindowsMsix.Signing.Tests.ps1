#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# A function redefined in the suite's scope never reaches a call inside the module; use Mock -ModuleName.

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
    # Never touch the machine store or depend on elevation: the non-Administrator branch only warns.
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
