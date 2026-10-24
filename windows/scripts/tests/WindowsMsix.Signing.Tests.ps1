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

    $script:workspace = New-TestDir -Prefix 'msix-signing-'
    $script:ctx = New-BuildContext -Workspace $script:workspace `
      -LogDir (Join-Path $script:workspace 'logs')
    $script:msixOut = Join-Path $script:workspace 'out.msix'

    function Invoke-MsixSigningFixture {
      $calls = [System.Collections.Generic.List[object]]::new()
      $invoker = { param($Context, $File, $Parameters) $calls.Add($Parameters); return 0 }.GetNewClosure()
      Invoke-MsixSign -Context $script:ctx -WorkspacePath $script:workspace `
        -MsixOutPath $script:msixOut -InvokerScriptBlock $invoker
      return , $calls
    }
  }

  AfterAll {
    Remove-TestDir -Path $script:workspace
  }

  BeforeEach {
    # Never touch the machine store or depend on elevation: the non-Administrator branch only warns.
    Mock -ModuleName WindowsMsix.Signing -CommandName Test-Administrator { return $false }
    Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath { return 'C:\signtool.exe' }
    Get-ChildItem -Path $script:workspace -Filter '*.pfx' -File -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
    New-Item -Path (Join-Path $script:workspace 'test.pfx') -ItemType File -Force | Out-Null
  }

  Context 'Invoke-MsixSign' {
    It 'does not invoke signtool when it cannot be resolved' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath { return $null }

      $calls = Invoke-MsixSigningFixture

      $calls.Count | Should -Be 0
    }

    It 'does not invoke signtool when the workspace holds no .pfx' {
      Remove-Item -LiteralPath (Join-Path $script:workspace 'test.pfx')

      $calls = Invoke-MsixSigningFixture

      $calls.Count | Should -Be 0
    }

    It 'signs and then verifies when a .pfx is present' {

      $calls = Invoke-MsixSigningFixture

      $calls.Count | Should -Be 2
      $calls[0][0] | Should -Be 'sign'
      $calls[0] | Should -Contain $script:msixOut
      $calls[1][0] | Should -Be 'verify'
      $calls[1] | Should -Contain $script:msixOut
    }

    Context 'Administrator certificate import' {
      BeforeEach { Mock -ModuleName WindowsMsix.Signing -CommandName Test-Administrator { return $true } }

    It 'passes a secure password to certificate import' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Import-PfxCertificate { return [pscustomobject]@{ Thumbprint = 'ABC' } }

      $calls = Invoke-WithEnv @{ MSIX_PFX_PASSWORD = 'test-password'; MSIX_CERT_PASSWORD = $null } { Invoke-MsixSigningFixture }

      $calls.Count | Should -Be 2
      Should -Invoke Import-PfxCertificate -ModuleName WindowsMsix.Signing -Times 1 -Exactly -ParameterFilter {
        $Password -is [securestring] -and $CertStoreLocation -eq 'Cert:\\LocalMachine\\Root'
      }
    }

    It 'keeps certificate import advisory and still verifies the signed package' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Import-PfxCertificate { throw 'trust store unavailable' }

      $calls = Invoke-MsixSigningFixture

      $calls.Count | Should -Be 2
      $calls[1][0] | Should -Be 'verify'
      Should -Invoke Import-PfxCertificate -ModuleName WindowsMsix.Signing -Times 1 -Exactly
    }
    }
  }
}
