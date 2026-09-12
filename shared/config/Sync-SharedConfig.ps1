# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
  Checks or refreshes a consumer's copies of the ANTfrastructure-owned shared files.

.DESCRIPTION
  See README.md next to this script for WHY these files are copied into
  consumers rather than referenced, and for the manifest format.

  Two states that used to look alike are now separate. A file the consumer
  DECLARES and holds at different content has DRIFTED - a defect. A file the
  consumer does not declare is simply not its business and is never mentioned.
  A file it declares but does not hold is MISSING, which is its own failure with
  its own message.

  shared/config/sync-shared-config.sh is the bash twin of this script and must
  stay behaviourally identical; both read the same two manifests.

.PARAMETER RepoRoot
  Consumer repository root holding the local copies.

.PARAMETER Check
  Report differences and exit 1 if any. Default when neither switch is given.

.PARAMETER Write
  Overwrite the consumer's copies with the canonical ones.

.PARAMETER Manifest
  Path to the consumer manifest. Defaults to
  <RepoRoot>/.antfrastructure-shared.manifest when that file exists.

.PARAMETER Ignore
  LEGACY, and only honoured when no manifest is in play: file names this project
  deliberately owns, e.g. -Ignore gcovr.cfg.

.OUTPUTS
  Exit code 0 when in sync (or written), 1 when -Check found MISSING or DRIFTED.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$RepoRoot,
  [switch]$Check,
  [switch]$Write,
  [string]$Manifest,
  [string[]]$Ignore = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exit 2 for "this script or its inputs are broken", so it never reads as the
# exit 1 that means "a consumer copy has drifted". The bash twin does the same.
trap {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 2
}

if (-not $Write) { $Check = $true }

$canonicalDir = $PSScriptRoot
$registryPath = Join-Path $canonicalDir 'shared-assets.manifest'
$hubRoot = (Resolve-Path -LiteralPath (Join-Path $canonicalDir '..' '..')).Path
$legacyNames = @('.clang-format', '.clang-tidy', '.cmake-format.yaml', 'gcovr.cfg', '.pre-commit-config.yaml')

function Read-ManifestRow {
  <# Data rows only: '#' comments and blank lines dropped, fields trimmed. #>
  param([string]$Path, [string]$Separator)
  $rows = @()
  foreach ($raw in [System.IO.File]::ReadAllLines($Path)) {
    $line = $raw.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
    $rows += , @($line -split $Separator | ForEach-Object { $_.Trim() })
  }
  # Comma on purpose: returning an array of ONE row would unroll on the way out
  # and hand the caller that row's fields instead, so a single-line manifest
  # read as one character per field ('antfrastructure-sh' -> 'c').
  return , $rows
}

function Get-AssetRegistry {
  <# The OWNER side: every file this repo is the source of truth for. #>
  if (-not (Test-Path -LiteralPath $registryPath)) {
    throw "Asset registry '$registryPath' is missing; nothing can be checked."
  }
  $reg = [ordered]@{}
  foreach ($f in (Read-ManifestRow -Path $registryPath -Separator '\|')) {
    if ($f.Count -lt 4) {
      throw "shared-assets.manifest row '$($f -join '|')' needs id|canonical|default|mode[|knobs]."
    }
    if ($f[3] -notin @('exact', 'body')) { throw "Unknown mode '$($f[3])' for asset '$($f[0])'." }
    $knobs = @()
    if ($f.Count -ge 5 -and $f[4]) { $knobs = @($f[4] -split ';' | Where-Object { $_ }) }
    $reg[$f[0]] = [pscustomobject]@{
      Id = $f[0]; Canonical = $f[1]; Default = $f[2]; Mode = $f[3]; Knobs = $knobs
    }
  }
  return $reg
}

function Test-ProseLine {
  <# Header prose: a blank line, or a comment. '#' covers sh, ps1 and yaml alike. #>
  param([string]$Line)
  $t = $Line.TrimStart()
  return ($t.Length -eq 0 -or $t.StartsWith('#'))
}

function Get-Comparable {
  <#
    The text the gate actually compares. Line endings normalised, because a
    CRLF/LF-only difference is not drift in any sense the reader cares about.
    In 'body' mode the leading prose is dropped - every consumer rewrites the
    header to say where the file came from - and a declared knob line is masked.
  #>
  param([string]$Path, [string]$Mode, [string[]]$Knobs)
  $text = ((Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n").TrimEnd("`n")
  $lines = @($text -split "`n")
  if ($Mode -eq 'body') {
    $first = 0
    while ($first -lt $lines.Count -and (Test-ProseLine $lines[$first])) { $first++ }
    if ($first -ge $lines.Count) {
      throw "'$Path' has no code line; a body-mode file cannot be all prose."
    }
    $lines = @($lines[$first..($lines.Count - 1)])
  }
  $out = foreach ($line in $lines) {
    $hit = $Knobs | Where-Object { $line.TrimStart().StartsWith($_) } | Select-Object -First 1
    if ($hit) { "<knob> $hit" } else { $line }
  }
  return (@($out) -join "`n")
}

function Get-DeclaredAsset {
  <# The CONSUMER side: (asset, local path) pairs this repo declares it takes. #>
  param([string]$Path, $Registry)
  $declared = @()
  foreach ($f in (Read-ManifestRow -Path $Path -Separator '\s+')) {
    $id = $f[0]
    if (-not $Registry.Contains($id)) {
      throw ("$Path declares '$id', which ANTfrastructure does not own. " +
        "Known ids: $($Registry.Keys -join ', ').")
    }
    $local = $Registry[$id].Default
    if ($f.Count -ge 2 -and $f[1]) { $local = $f[1] }
    $declared += [pscustomobject]@{ Asset = $Registry[$id]; Local = $local }
  }
  return $declared
}

function Get-LegacyAsset {
  <# No manifest: the five shared/config names at the consumer root, minus -Ignore. #>
  param($Registry, [string[]]$Skipped)
  $declared = @()
  foreach ($name in $legacyNames) {
    if ($Skipped -contains $name) { continue }
    $asset = $Registry.Values | Where-Object { $_.Default -eq $name } | Select-Object -First 1
    $declared += [pscustomobject]@{ Asset = $asset; Local = $name }
  }
  return $declared
}

function Expand-LegacyIgnore {
  <#
    Accept a COMMA-SEPARATED -Ignore as well as a real array: under `pwsh -File`
    every argument arrives as a plain string, so `-Ignore a,b` would otherwise
    bind as ONE element that matches no file name and silently does nothing.
  #>
  param([string[]]$Raw)
  $names = @($Raw | Where-Object { $_ } | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $unknown = @($names | Where-Object { $_ -notin $legacyNames })
  if ($unknown.Count -gt 0) {
    throw ("-Ignore names nothing this script manages: $($unknown -join ', '). " +
      "Valid names: $($legacyNames -join ', ')")
  }
  return $names
}

function Assert-CanonicalPresent {
  <#
    A missing CANONICAL file is a defect in THIS repo and has to say so loudly:
    -Write would die inside Copy-Item with a bare "path not found" and -Check
    would blame the CONSUMER for a file that is actually missing HERE. Scoped to
    what the consumer DECLARED, for the reason the whole script now exists: an
    asset nobody takes is nobody's failure.
  #>
  param($Declared)
  foreach ($d in $Declared) {
    if (Test-Path -LiteralPath (Join-Path $hubRoot $d.Asset.Canonical)) { continue }
    throw ("Canonical file '$($d.Asset.Canonical)' for asset '$($d.Asset.Id)' is missing from $hubRoot. " +
      'Add the file, or remove the row from shared/config/shared-assets.manifest.')
  }
}

function Write-Copy {
  <#
    -Write is a verbatim copy, so it only serves 'exact' assets. Splicing a
    canonical body under a consumer's own header while preserving its knob
    values is a merge, not a copy; doing it silently wrong would defeat the very
    gate this script is. So body-mode assets refuse, naming the manual step.
  #>
  param($Declared, [string]$Canonical, [string]$Local)
  if ($Declared.Asset.Mode -eq 'body') {
    throw ("Cannot -Write '$($Declared.Local)': asset '$($Declared.Asset.Id)' is body-mode. " +
      "Copy $($Declared.Asset.Canonical) from its first code line down, keeping this repo's " +
      'header prose and its knob values, then re-run -Check.')
  }
  Copy-Item -LiteralPath $Canonical -Destination $Local -Force
}

$registry = Get-AssetRegistry
$resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $Manifest) {
  $default = Join-Path $resolvedRoot '.antfrastructure-shared.manifest'
  if (Test-Path -LiteralPath $default) { $Manifest = $default }
}

$skipped = @()
if ($Manifest) {
  if (-not (Test-Path -LiteralPath $Manifest)) { throw "Manifest '$Manifest' does not exist." }
  if ($Ignore.Count -gt 0) {
    throw ('-Ignore and a manifest cannot be combined: the manifest already says what this repo ' +
      'takes, and a stale -Ignore would silently override a declaration. ' +
      "Drop -Ignore, or delete $Manifest.")
  }
  $declared = @(Get-DeclaredAsset -Path $Manifest -Registry $registry)
} else {
  $skipped = @(Expand-LegacyIgnore -Raw $Ignore)
  $declared = @(Get-LegacyAsset -Registry $registry -Skipped $skipped)
  Write-Host '  NOTE  no consumer manifest; using the legacy -Ignore list.'
}
Assert-CanonicalPresent -Declared $declared

$ok = @()
$drifted = @()
$missing = @()
$written = @()

foreach ($d in $declared) {
  $canonical = Join-Path $hubRoot $d.Asset.Canonical
  $local = Join-Path $resolvedRoot $d.Local

  if (-not (Test-Path -LiteralPath $local)) {
    if (-not $Write) { $missing += $d.Local; continue }
    Write-Copy -Declared $d -Canonical $canonical -Local $local
    $written += $d.Local
    continue
  }

  $a = Get-Comparable -Path $canonical -Mode $d.Asset.Mode -Knobs $d.Asset.Knobs
  $b = Get-Comparable -Path $local -Mode $d.Asset.Mode -Knobs $d.Asset.Knobs
  if ($a -eq $b) { $ok += $d.Local; continue }
  if (-not $Write) { $drifted += $d.Local; continue }

  Write-Copy -Declared $d -Canonical $canonical -Local $local
  $written += $d.Local
}

foreach ($n in $skipped) { Write-Host "  SKIP  $n (project-owned override)" -ForegroundColor Yellow }
foreach ($n in $written) { Write-Host "  WROTE $n" -ForegroundColor Green }

if ($Write) {
  if ($written.Count -eq 0) { Write-Host 'Shared config already up to date.' -ForegroundColor Green }
  exit 0
}

foreach ($n in $ok) { Write-Host "  OK      $n" -ForegroundColor Green }
foreach ($n in $missing) { Write-Host "  MISSING $n" -ForegroundColor Red }
foreach ($n in $drifted) { Write-Host "  DRIFTED $n" -ForegroundColor Red }

if ($missing.Count -gt 0) {
  Write-Host ''
  Write-Host 'DECLARED but not present. Either this repo stopped carrying the file, and its' -ForegroundColor Red
  Write-Host 'line leaves the manifest - or the copy was lost and has to be restored.' -ForegroundColor Red
}
if ($drifted.Count -gt 0) {
  Write-Host ''
  Write-Host 'DECLARED and present, but the content differs from the canonical copy.' -ForegroundColor Red
  Write-Host 'Edit the file UPSTREAM (in ANTfrastructure), then refresh here with:' -ForegroundColor Red
  Write-Host '  pwsh -File third_party/ANTfrastructure/shared/config/Sync-SharedConfig.ps1 -RepoRoot . -Write' -ForegroundColor Red
  Write-Host '  bash third_party/ANTfrastructure/shared/config/sync-shared-config.sh --repo-root . --write' -ForegroundColor Red
  Write-Host 'If this project genuinely owns the file, drop its line from the manifest instead.' -ForegroundColor Red
}
if ($missing.Count -gt 0 -or $drifted.Count -gt 0) { exit 1 }

Write-Host 'Shared config in sync.' -ForegroundColor Green
exit 0
