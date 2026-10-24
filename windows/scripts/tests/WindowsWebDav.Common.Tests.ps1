#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsWebDav.Common' {
  BeforeAll {
    $modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
    Import-Module (Join-Path $modDir 'WindowsScripts.Shared.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $modDir 'WindowsBuild.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $modDir 'WindowsWebDav.Common.psm1') -Force -DisableNameChecking

    $script:workspace = New-TestDir -Prefix 'webdav-common-'
    function New-WebDavTestContext {
      $logDir = Join-Path $script:workspace 'logs'
      $null = New-Item -ItemType Directory -Path $logDir -Force
      return New-BuildContext -Workspace $script:workspace -LogDir $logDir
    }
    function Invoke-WebDavFixture {
      param([string]$HostName = 'h', [string]$User = 'u')
      Invoke-EarlyWebDavDownload -Context (New-WebDavTestContext) -WorkspacePath $script:workspace `
        -WebDavHost $HostName -WebDavUser $User -WebDavPass 'secret' `
        -WebDavRemote 'remote' -WebDavLocal $script:workspace
    }
    function Assert-WebDavWarnedAndRan {
      param([Parameter(Mandatory)][string]$WarningPattern)
      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Write-BuildLogWarning -Times 1 -Exactly `
        -ParameterFilter { $Message -match $WarningPattern }
      Assert-WebDavExternalCall { $Parameters[0] -eq 'run' }
    }
    function Assert-WebDavExternalCall {
      param([Parameter(Mandatory)][scriptblock]$Filter)
      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal -Times 1 -Exactly `
        -ParameterFilter $Filter
    }
  }

  AfterAll {
    Remove-TestDir -Path $script:workspace
  }

  Context 'Invoke-EarlyWebDavDownload' {
    BeforeEach {
      Mock -ModuleName WindowsWebDav.Common -CommandName Get-Command { [pscustomobject]@{ Source = 'uv.exe' } }
      Mock -ModuleName WindowsWebDav.Common -CommandName Initialize-UvVenv {}
      Mock -ModuleName WindowsWebDav.Common -CommandName ConvertFrom-VersionsEnv {
        @{ WEBDAVCLIENT_REF = 'fa9cb699643cdb48a197ef00db0b40133d3b872a' }
      }
      Mock -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal { return 0 }
    }

    It 'returns without invoking python when the download script is missing' {
      # The script always ships beside the module, so only a module-scoped Test-Path mock can hide it.
      Mock -ModuleName WindowsWebDav.Common -CommandName Test-Path { return $false }
      Invoke-WebDavFixture

      # The skip path must spawn no external process.
      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal -Times 0 -Exactly
    }

    It 'warns without spawning when uv is missing' {
      Mock -ModuleName WindowsWebDav.Common -CommandName Get-Command { $null }
      Mock -ModuleName WindowsWebDav.Common -CommandName Write-BuildLogWarning {}
      Invoke-WebDavFixture

      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Write-BuildLogWarning -Times 1 -Exactly `
        -ParameterFilter { $Message -match 'uv not found on PATH' }
      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal -Times 0 -Exactly
    }

    It 'uses the pinned archive and redacts the password on the early download' {
      $sha = 'fa9cb699643cdb48a197ef00db0b40133d3b872a'
      Invoke-WebDavFixture -HostName 'host' -User 'user'

      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Initialize-UvVenv -Times 1 -Exactly
      Assert-WebDavExternalCall { $Parameters[0] -eq 'pip' -and $Parameters[2] -eq "kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/$sha.tar.gz" }
      Assert-WebDavExternalCall { $Parameters[0] -eq 'run' -and $Parameters[2] -eq 'host' -and
          $Parameters[4] -eq 'secret' -and $Parameters[-2] -eq '--extension' -and
          $Parameters[-1] -eq '.pfx' -and $RedactParameterValues -contains 'secret' }
    }

    It 'warns on a failed venv setup yet still invokes the download' {
      Mock -ModuleName WindowsWebDav.Common -CommandName Initialize-UvVenv { throw 'venv sentinel' }
      Mock -ModuleName WindowsWebDav.Common -CommandName Write-BuildLogWarning {}
      Invoke-WebDavFixture

      Assert-WebDavWarnedAndRan -WarningPattern 'uv venv creation failed: venv sentinel'
    }

    It 'runs uv venv through the advisory build transport' {
      Mock -ModuleName WindowsWebDav.Common -CommandName Initialize-UvVenv {
        param($Workspace, $EnvName, $CommandRunner)
        & $CommandRunner 'uv.exe' @('venv', '.venv')
      }
      Invoke-WebDavFixture

      Assert-WebDavExternalCall { $Parameters[0] -eq 'venv' -and $IgnoreExitCode }
    }

    It 'warns on a missing WebDAV client pin but still attempts the early download' {
      Mock -ModuleName WindowsWebDav.Common -CommandName ConvertFrom-VersionsEnv { @{} }
      Mock -ModuleName WindowsWebDav.Common -CommandName Write-BuildLogWarning {}
      Invoke-WebDavFixture

      Assert-WebDavWarnedAndRan -WarningPattern 'WEBDAVCLIENT_REF is not set'
    }
  }

  Context 'Get-WebDavClientRequirement' {
    It 'installs the pinned commit from its source archive, never through git' {
      # A git requirement recurses into the client's old submodule chain and hits Git for Windows' gitdir limit.
      $sha = 'fa9cb699643cdb48a197ef00db0b40133d3b872a'
      $requirement = Get-WebDavClientRequirement -Ref $sha
      $requirement | Should -Be "kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/$sha.tar.gz"
      $requirement | Should -Not -Match 'git\+'
    }

    It 'refuses a ref that is not a full commit sha' {
      # A branch name would install whatever that branch was that day.
      Assert-Throws -MessagePattern 'Ref' -Body { Get-WebDavClientRequirement -Ref 'main' }
      Assert-Throws -MessagePattern 'Ref' -Body { Get-WebDavClientRequirement -Ref 'fa9cb69' }
    }
  }
}
