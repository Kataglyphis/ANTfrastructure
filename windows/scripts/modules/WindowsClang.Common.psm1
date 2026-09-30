# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# clang-tidy, apart from WindowsFormatting.Common because tidy needs a compile-commands database.

Set-StrictMode -Version Latest

# Unforced: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'WindowsFormatting.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'WindowsCMake.Common.psm1')

function Test-IsCxxModuleTranslationUnit {
  <#
  .SYNOPSIS
      True when a translation unit imports a C++20 named module.
  .DESCRIPTION
      clang-tidy needs the BMIs, which the compile-commands database lacks, so such TUs are skipped.
  .PARAMETER Pattern
      Module-import regex; defaults to this org's prefix, '(?m)^\s*import\s+\w' skips every named module.
  #>
  param(
    [string]$Content,
    [string]$Path,
    [string]$Pattern = '(?m)^\s*import\s+kataglyphis'
  )

  if (-not $PSBoundParameters.ContainsKey('Content')) {
    $Content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
  }

  return [bool]($Content -match $Pattern)
}

function Invoke-ClangTidyFixStep {
  <#
  .SYNOPSIS
      Runs clang-tidy over a project's own C++ sources.
  .PARAMETER SourceSubdirectory
      Workspace-relative directory to analyse and --header-filter on (default 'Src').
  .PARAMETER Checks
      Extra clang-tidy arguments, empty by default: a forced --checks crashed some clang-tidy versions.
  #>
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [string]$SourceSubdirectory = 'Src',
    [string[]]$Checks = @(),
    [string]$ModuleImportPattern = '(?m)^\s*import\s+kataglyphis',
    [string[]]$Extension = @('.cpp', '.cc', '.cxx'),
    [switch]$Fix
  )

  $clangTidyCommand = Get-Command 'clang-tidy' -ErrorAction SilentlyContinue
  if (-not $clangTidyCommand) {
    throw 'clang-tidy not found on PATH.'
  }

  $compileDb = Get-CompileCommandsDatabase -Context $Context -BuildRoot $BuildRoot
  Write-BuildLog -Context $Context -Message "clang-tidy compile database: $compileDb"

  $srcDir = Join-Path $WorkspacePath $SourceSubdirectory
  $tidyFiles = @(Get-ProjectCppFiles -WorkspacePath $WorkspacePath |
    Where-Object { $_ -like "$srcDir*" -and [System.IO.Path]::GetExtension($_) -in $Extension })

  $filteredFiles = @()
  foreach ($f in $tidyFiles) {
    $content = Get-Content $f -Raw -ErrorAction SilentlyContinue
    if (Test-IsCxxModuleTranslationUnit -Content $content -Pattern $ModuleImportPattern) {
      Write-BuildLog -Context $Context -Message "Skipping clang-tidy for $f (uses C++20 module syntax)"
      continue
    }
    $filteredFiles += $f
  }
  $tidyFiles = $filteredFiles

  if ($tidyFiles.Count -eq 0) {
    Write-BuildLog -Context $Context -Message "No C/C++ source files found under $SourceSubdirectory for clang-tidy."
    return
  }

  $baseParams = @('-p', $BuildRoot) + $Checks
  # Keeps dependency headers out of the report.
  $baseParams += "--header-filter=$([regex]::Escape($srcDir)).*"
  if ($Fix) { $baseParams += '--fix' }

  foreach ($tidyFile in $tidyFiles) {
    Invoke-BuildExternal -Context $Context -File $clangTidyCommand.Source -Parameters @($baseParams + $tidyFile) | Out-Null
  }
}

Export-ModuleMember -Function @(
  'Invoke-ClangTidyFixStep',
  'Test-IsCxxModuleTranslationUnit'
)
