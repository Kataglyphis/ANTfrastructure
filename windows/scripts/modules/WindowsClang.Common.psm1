# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# clang-tidy driving. The sibling of WindowsFormatting.Common (clang-format /
# cmake-format), kept separate because tidy needs a compile-commands database
# and formatting does not.
#
# Upstreamed from Kataglyphis-BeschleunigerBallett's vendored
# scripts/windows/modules copy (2026-08-11). The only two project-specific
# things in it -- the source subdirectory and the C++20-module import pattern --
# are now parameters with the previous values as defaults, so the vendored copy
# can be deleted without changing that repo's behaviour.

Set-StrictMode -Version Latest

# Write-BuildLog*, Invoke-BuildExternal. Plain, unforced imports: an entry
# script's -Force -Global copies must not be displaced (see WindowsCMake.Common).
Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
# Get-ProjectCppFiles - the git-ls-files fast path with build/_deps/.venv exclusions.
Import-Module (Join-Path $PSScriptRoot 'WindowsFormatting.Common.psm1')
# Get-CompileCommandsDatabase - generates compile_commands.json from the ninja
# graph when CMake did not emit one.
Import-Module (Join-Path $PSScriptRoot 'WindowsCMake.Common.psm1')

function Test-IsCxxModuleTranslationUnit {
  <#
  .SYNOPSIS
      True when a translation unit imports a C++20 named module.
  .DESCRIPTION
      clang-tidy cannot analyse a TU that imports a named module without the
      BMIs on its command line, and the compile-commands database does not
      carry them -- so such files must be skipped rather than reported as
      thousands of bogus diagnostics.
  .PARAMETER Pattern
      Regex identifying a module import. Defaults to this org's module prefix;
      pass e.g. '(?m)^\s*import\s+\w' to skip every named-module import.
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
      Workspace-relative directory to analyse, also used for --header-filter so
      dependency headers stay out of the report. Defaults to 'Src'.
  .PARAMETER Checks
      Extra clang-tidy arguments (e.g. --checks=...). Empty by default and
      deliberately so: this module used to force --checks=-misc-include-cleaner,
      which crashed some clang-tidy versions. Opt in per project instead.
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
  # Restrict analysis to the source directory to avoid noise from dependency headers.
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
