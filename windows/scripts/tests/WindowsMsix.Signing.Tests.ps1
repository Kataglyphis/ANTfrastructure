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

    # Runs -Call with a recording invoker; returns the recorded signtool argument lists and the call's result.
    function Invoke-SigningFixture {
      param([Parameter(Mandatory)][scriptblock]$Call)
      $calls = [System.Collections.Generic.List[object]]::new()
      $invoker = { param($Context, $File, $Parameters) $calls.Add($Parameters); return 0 }.GetNewClosure()
      $result = & $Call $invoker
      return [pscustomobject]@{ Result = $result; Calls = $calls }
    }
    function Invoke-MsixSigningFixture {
      $run = Invoke-SigningFixture { param($invoker)
        Invoke-MsixSign -Context $script:ctx -WorkspacePath $script:workspace -MsixOutPath $script:msixOut -InvokerScriptBlock $invoker }
      return , $run.Calls
    }
    function Assert-MsixPfx {
      param([Parameter(Mandatory)][string]$PfxPath, [securestring]$Password,
        [Parameter(Mandatory)][string]$Thumbprint)
      Test-Path $PfxPath | Should -BeTrue
      $read = Read-PfxCertificate -PfxPath $PfxPath -SigningPassword $Password
      $read.Thumbprint | Should -Be $Thumbprint
      $read.HasPrivateKey | Should -BeTrue
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

    It 'propagates a missing signing command instead of shipping unsigned' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath {
        throw [System.Management.Automation.CommandNotFoundException]::new('sdk resolver sentinel')
      }

      { Invoke-MsixSigningFixture } | Should -Throw '*sdk resolver sentinel*'
    }

    It 'keeps an ordinary signtool lookup failure advisory' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath { throw 'sdk lookup sentinel' }
      Mock -ModuleName WindowsMsix.Signing -CommandName Write-BuildLogWarning {}

      { Invoke-MsixSigningFixture } | Should -Not -Throw
      Should -Invoke Write-BuildLogWarning -ModuleName WindowsMsix.Signing -Times 1 -Exactly `
        -ParameterFilter { $Message -match 'MSIX signing step failed: sdk lookup sentinel' }
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

  Context 'Invoke-AuthenticodeSign' {
    BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'WindowsAuthenticode.Fixture.psm1') -Force -DisableNameChecking
      $script:signedFile = Join-Path $script:workspace 'setup.exe'
      Set-Content -LiteralPath $script:signedFile -Value 'payload'
      $script:realPfx = Join-Path $script:workspace 'real-signing.pfx.bin'
      $script:realThumb = New-TestSigningCertificate -Subject 'CN=ANTfrastructure Authenticode Test' -PfxPath $script:realPfx
      function Invoke-AuthenticodeFixture {
        param([hashtable]$Extra = @{})
        # A closure sees its own script scope, so the suite's values are copied in as locals.
        $context = $script:ctx
        $file = $script:signedFile
        return Invoke-SigningFixture { param($invoker)
          Invoke-AuthenticodeSign -Context $context -Path $file -InvokerScriptBlock $invoker @Extra }.GetNewClosure()
      }
    }

    It 'warns and returns false without a .pfx, and -Require makes that an error' {
      $run = Invoke-AuthenticodeFixture -Extra @{ PfxPath = '' }
      $run.Result | Should -BeFalse
      $run.Calls.Count | Should -Be 0
      { Invoke-AuthenticodeFixture -Extra @{ PfxPath = ''; Require = $true } } | Should -Throw '*Cannot sign*no signing .pfx*'
      Mock -ModuleName WindowsMsix.Signing -CommandName Resolve-WindowsSdkToolPath { return $null }
      { Invoke-AuthenticodeFixture -Extra @{ PfxPath = $script:realPfx; Require = $true } } | Should -Throw '*signtool.exe not found*'
    }

    It 'passes the password only to signtool and redacts it in the build log' {
      Mock -ModuleName WindowsMsix.Signing -CommandName Invoke-BuildExternal {}
      $null = Invoke-WithEnv @{ KG_TEST_PFX_PASSWORD = 'pw-sentinel' } {
        Invoke-AuthenticodeSign -Context $script:ctx -Path $script:signedFile -PfxPath $script:realPfx -SecretEnvironmentName 'KG_TEST_PFX_PASSWORD'
      }
      Should -Invoke Invoke-BuildExternal -ModuleName WindowsMsix.Signing -Times 1 -Exactly -ParameterFilter {
        $Parameters[0] -eq 'sign' -and $Parameters -contains 'pw-sentinel' -and $RedactParameterValues -contains 'pw-sentinel'
      }
    }

    It 'leaves out the timestamp when the URL is empty and runs the hook between sign and verify' {
      $order = [System.Collections.Generic.List[string]]::new()
      $hook = { param($pfx, [securestring]$securePassword) $order.Add('hook') }.GetNewClosure()
      $run = Invoke-AuthenticodeFixture -Extra @{ PfxPath = $script:realPfx; TimestampUrl = ''; BeforeVerify = $hook }
      $run.Result | Should -BeTrue
      $run.Calls[0] | Should -Not -Contain '/tr'
      $run.Calls[1][0] | Should -Be 'verify'
      $order | Should -Be @('hook')
    }

    It 'checks the signer instead of running signtool verify under -Verify Signer' {
      $run = Invoke-AuthenticodeFixture -Extra @{ PfxPath = $script:realPfx; Verify = 'Signer'; SignatureReader = (New-FakeAuthenticode $script:realThumb) }
      $run.Result | Should -BeTrue
      $run.Calls.Count | Should -Be 1
    }

    # The mutation shards run the same refusals through the harness in Nsis.Common.Tests.ps1.
    It 'refuses a <Name> under -Verify Signer' -ForEach @(
      @{ Name = 'foreign signer'; Own = $false; Status = 'Valid'; Expected = '*not the signing certificate*' }
      @{ Name = 'broken hash'; Own = $true; Status = 'HashMismatch'; Expected = '*is HashMismatch*' }
    ) {
      $signer = if ($Own) { (Read-PfxCertificate -PfxPath $script:realPfx).Thumbprint } else { 'F' * 40 }
      { Invoke-AuthenticodeFixture -Extra @{ PfxPath = $script:realPfx; Verify = 'Signer'; SignatureReader = (New-FakeAuthenticode $signer $Status) } } |
        Should -Throw $Expected
    }
  }

  Context 'New-TestSigningCertificate' {
    It 'writes a PFX with a private key and a matching public certificate' {
      $pfx = Join-Path $script:workspace 'throwaway.pfx'
      $cer = Join-Path $script:workspace 'throwaway.cer'
      $password = [securestring]::new()
      foreach ($char in 'fixture-password'.ToCharArray()) { $password.AppendChar($char) }
      try {
        $thumbprint = New-TestSigningCertificate -Subject 'CN=ANTfrastructure Test' `
          -PfxPath $pfx -CerPath $cer -Password $password
        Assert-MsixPfx -PfxPath $pfx -Password $password -Thumbprint $thumbprint
      } finally { $password.Dispose() }

      Test-Path $cer | Should -BeTrue
      $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new($cer)
      try {
        $public.Thumbprint | Should -Be $thumbprint
        $public.HasPrivateKey | Should -BeFalse
      } finally { $public.Dispose() }
    }

    It 'writes an unprotected PFX without a separate public file by default' {
      $pfx = Join-Path $script:workspace 'unprotected.pfx'
      $cer = Join-Path $script:workspace 'unprotected.cer'
      $thumbprint = New-TestSigningCertificate -Subject 'CN=ANTfrastructure Unprotected Test' -PfxPath $pfx

      Test-Path $cer | Should -BeFalse
      Assert-MsixPfx -PfxPath $pfx -Thumbprint $thumbprint
    }
  }
}
