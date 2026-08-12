#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Moved up from a consumer repo (Kataglyphis-BeschleunigerBallett,
# scripts/windows/tests) on 2026-08-07 - see WindowsCMake.Common.Tests.ps1 for
# the rationale. Converted from Pester 3.4 to Pester 5+ syntax in the move.

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
      # -ModuleName is required: the download script ships next to the module
      # (windows/scripts/certificates), so it always exists on disk and only a
      # module-scoped Test-Path mock can simulate the missing-script path. An
      # unscoped mock never reaches the module's internal call and the test
      # would run the full download flow against a real WebDAV host.
      Mock -ModuleName WindowsWebDav.Common -CommandName Test-Path { return $false }
      Mock -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal { return 0 }

      $logDir = Join-Path $script:workspace 'logs'
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
      $ctx = New-BuildContext -Workspace $script:workspace -LogDir $logDir

      Invoke-EarlyWebDavDownload -Context $ctx -WorkspacePath $script:workspace `
        -WebDavHost 'h' -WebDavUser 'u' -WebDavPass 'p' `
        -WebDavRemote 'r' -WebDavLocal $script:workspace

      # The point of the skip path: no external process is spawned. The old
      # suite asserted `$true | Should Be $true` here, which proved nothing.
      Should -Invoke -ModuleName WindowsWebDav.Common -CommandName Invoke-BuildExternal -Times 0 -Exactly
    }
  }
}
