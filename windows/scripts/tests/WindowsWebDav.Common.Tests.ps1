#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsWebDav.Common' {
  BeforeAll {
    $modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
    Import-Module (Join-Path $modDir 'WindowsScripts.Shared.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $modDir 'WindowsBuild.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $modDir 'WindowsWebDav.Common.psm1') -Force -DisableNameChecking

    $script:workspace = (New-Item -ItemType Directory `
        -Path (Join-Path $env:TEMP ('webdav-common-' + (Get-Random))) -Force).FullName
  }

  AfterAll {
    Remove-Item -LiteralPath $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Invoke-EarlyWebDavDownload' {
    It 'returns without invoking python when the download script is missing' {
      # The script always ships beside the module, so only a module-scoped Test-Path mock can hide it.
      Mock -ModuleName WindowsWebDav.Common -CommandName Test-Path { return $false }
      Mock -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal { return 0 }

      $logDir = Join-Path $script:workspace 'logs'
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
      $ctx = New-BuildContext -Workspace $script:workspace -LogDir $logDir

      Invoke-EarlyWebDavDownload -Context $ctx -WorkspacePath $script:workspace `
        -WebDavHost 'h' -WebDavUser 'u' -WebDavPass 'p' `
        -WebDavRemote 'r' -WebDavLocal $script:workspace

      # The skip path must spawn no external process.
      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal -Times 0 -Exactly
    }
  }

  Context 'Get-WebDavClientRequirement' {
    It 'installs the pinned commit from its source archive, never through git' {
      # A git requirement recurses into the client's old submodule chain and hits Git for Windows' gitdir limit.
      $sha = '4f3f116d9ce7d1e223894513b4dc7a90b5085a9f'
      $requirement = Get-WebDavClientRequirement -Ref $sha
      $requirement | Should -Be "kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/$sha.tar.gz"
      $requirement | Should -Not -Match 'git\+'
    }

    It 'refuses a ref that is not a full commit sha' {
      # A branch name would install whatever that branch was that day.
      { Get-WebDavClientRequirement -Ref 'main' } | Should -Throw
      { Get-WebDavClientRequirement -Ref '4f3f116' } | Should -Throw
    }
  }
}
