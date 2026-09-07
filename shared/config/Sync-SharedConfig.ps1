# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
  Checks or refreshes a consumer's copies of the shared tool configs.

.DESCRIPTION
  See README.md next to this script for WHY these configs are copied into
  consumers rather than referenced: clang-format, clang-tidy, cmake-format and
  pre-commit discover their config by walking UP from the file being processed,
  so a config inside a submodule is never found - and dropping the local copy
  would silently disable format-on-save in every editor while CI kept passing.

  The copy therefore stays and this script makes drift impossible instead of
  unnoticed.

.PARAMETER RepoRoot
  Consumer repository root holding the local copies.

.PARAMETER Check
  Report differences and exit 1 if any. Default when neither switch is given.

.PARAMETER Write
  Overwrite the consumer's copies with the canonical ones.

.PARAMETER Ignore
  File names this project deliberately owns, e.g. -Ignore gcovr.cfg. Reported as
  skipped so an intentional exception never looks like drift.

.OUTPUTS
  Exit code 0 when in sync (or written), 1 when -Check found differences.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$RepoRoot,
  [switch]$Check,
  [switch]$Write,
  [string[]]$Ignore = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Write) { $Check = $true }

# Accept a COMMA-SEPARATED -Ignore as well as a real array.
#
# The README documents invoking this with `pwsh -File`, and under -File every
# argument arrives as a plain string: `-Ignore a,b,c` binds the whole thing as
# ONE element "a,b,c", which then matches no file name and the ignore silently
# does nothing. A consumer that legitimately owns several of these files would
# see its documented escape hatch fail with no explanation (found doing exactly
# that for AccelerANTgine, 2026-08-11). Splitting here makes -File
# and -Command behave the same.
$Ignore = @($Ignore | Where-Object { $_ } | ForEach-Object { $_ -split ',' } |
  ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Typo guard: an -Ignore entry that is not one of the canonical names is almost
# certainly a mistake ('.clang_tidy', 'gcovr.conf'), and silently ignoring it
# would leave the caller believing an exception is recorded when it is not.
$unknownIgnore = @($Ignore | Where-Object { $_ -notin @('.clang-format', '.clang-tidy', '.cmake-format.yaml', 'gcovr.cfg', '.pre-commit-config.yaml') })
if ($unknownIgnore.Count -gt 0) {
  throw ("-Ignore names nothing this script manages: $($unknownIgnore -join ', '). " +
    'Valid names: .clang-format, .clang-tidy, .cmake-format.yaml, gcovr.cfg, .pre-commit-config.yaml')
}

$canonicalDir = $PSScriptRoot
# .cmake-format.yaml joined 2026-09-05: both runners hard-code the consumer-root
# name, so nothing could check it. See README.md next to this script.
$names = @('.clang-format', '.clang-tidy', '.cmake-format.yaml', 'gcovr.cfg', '.pre-commit-config.yaml')

$resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$drifted = @()
$missing = @()
$skipped = @()
$written = @()

foreach ($name in $names) {
  if ($Ignore -contains $name) { $skipped += $name; continue }

  $canonical = Join-Path $canonicalDir $name
  $local = Join-Path $resolvedRoot $name

  # A missing CANONICAL file is a defect in THIS repo, and it has to say so
  # loudly. Until 2026-08-11 three of the four names then listed had no file next
  # to this script at all, and neither branch below coped: -Write died inside
  # Copy-Item with a bare "path not found", and -Check blamed the CONSUMER for a
  # file that was missing HERE. Both readings sent you looking in the wrong repo.
  if (-not (Test-Path -LiteralPath $canonical)) {
    throw ("Canonical config '$name' is missing from $canonicalDir. " +
      'The name is listed in this script but no file backs it, so nothing can be checked or written. ' +
      'Add the file here (this repo owns it), or remove the name from $names.')
  }

  if (-not (Test-Path -LiteralPath $local)) {
    if ($Write) {
      Copy-Item -LiteralPath $canonical -Destination $local -Force
      $written += $name
    } else {
      $missing += $name
    }
    continue
  }

  # Compare content with line endings normalised: these files are checked out
  # with whatever core.autocrlf the consumer's host uses, and a CRLF/LF-only
  # difference is not drift in any sense the reader cares about.
  $a = (Get-Content -LiteralPath $canonical -Raw) -replace "`r`n", "`n"
  $b = (Get-Content -LiteralPath $local -Raw) -replace "`r`n", "`n"

  if ($a -ne $b) {
    if ($Write) {
      Copy-Item -LiteralPath $canonical -Destination $local -Force
      $written += $name
    } else {
      $drifted += $name
    }
  }
}

foreach ($n in $skipped) { Write-Host "  SKIP  $n (project-owned override)" -ForegroundColor Yellow }
foreach ($n in $written) { Write-Host "  WROTE $n" -ForegroundColor Green }

if ($Write) {
  if ($written.Count -eq 0) { Write-Host 'Shared config already up to date.' -ForegroundColor Green }
  exit 0
}

foreach ($n in $missing) { Write-Host "  MISSING $n" -ForegroundColor Red }
foreach ($n in $drifted) { Write-Host "  DRIFTED $n" -ForegroundColor Red }

if ($missing.Count -gt 0 -or $drifted.Count -gt 0) {
  Write-Host ''
  Write-Host 'Local tool config differs from the canonical copy in ContainerHub.' -ForegroundColor Red
  Write-Host 'Edit the config UPSTREAM (shared/config/), then refresh here with:' -ForegroundColor Red
  Write-Host '  pwsh -File third_party/ContainerHub/shared/config/Sync-SharedConfig.ps1 -RepoRoot . -Write' -ForegroundColor Red
  Write-Host 'If this project genuinely owns the file, pass -Ignore <name> instead.' -ForegroundColor Red
  exit 1
}

Write-Host 'Shared config in sync.' -ForegroundColor Green
exit 0
