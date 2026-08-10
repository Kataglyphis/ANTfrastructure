# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#requires -Version 7.0

<#
.SYNOPSIS
    Pre-bump validator: confirm every static .patch under windows/scripts/patches/ still applies
    cleanly to its pinned upstream via `git apply --check`.

.DESCRIPTION
    The Windows source-build patches are pinned to specific upstream versions (onnxruntime v1.27.0,
    gstreamer 1.29.2, ...). When you bump a version you must re-verify the committed patches still
    apply -- otherwise the build silently falls back to the inline patchers (or fails). This tool
    automates that check WITHOUT a container rebuild:

      for each *.patch:
        1. parse its `+++ b/<path>` headers to learn which files it touches;
        2. shallow + sparse + blobless clone the pinned upstream (only those paths);
        3. `git apply --check -p1 --ignore-whitespace` -- the exact flags Invoke-SourcePatch uses;
        4. report OK / FAIL.

    Requires network + git. Not part of the container build; run it on the host before a version bump
    or in CI. The pinned tags below mirror linux/scripts/01-core/versions.env -- keep them in sync
    (override any with -Versions @{ ONNXRUNTIME = 'v1.28.0' }).

.PARAMETER PatchRoot
    Root of the patch tree (default: the patches/ dir next to this script's parent).

.PARAMETER Versions
    Optional hashtable overriding the pinned tags per repo key (ONNXRUNTIME, OPENCV, FFMPEG, GSTREAMER).

.PARAMETER WorkDir
    Scratch dir for the shallow clones (default: a temp dir; removed on completion).

.EXAMPLE
    pwsh -File windows/scripts/tests/Test-PatchesApplyClean.ps1
.EXAMPLE
    pwsh -File windows/scripts/tests/Test-PatchesApplyClean.ps1 -Versions @{ ONNXRUNTIME = 'v1.28.0' }
#>
[CmdletBinding()]
param(
    [string]$PatchRoot,
    [hashtable]$Versions = @{},
    [string]$WorkDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PatchRoot) { $PatchRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'patches' }
if (-not (Test-Path $PatchRoot)) { throw "patch root not found: $PatchRoot" }
if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("patchcheck_{0}" -f ([guid]::NewGuid().ToString('N'))) }

# Map each patch subdirectory to its upstream repo + the pinned ref.
# Read from versions.env (single source of truth) — no hand-synced duplicate.
$versionsFile = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent) 'linux\scripts\01-core\versions.env'
$defaultRefs = @{
    ONNXRUNTIME = 'v1.27.0'
    OPENCV      = '5.x'
    FFMPEG      = 'master'
    GSTREAMER   = '1.29.2'
}
if (Test-Path $versionsFile) {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsScripts.Shared.psm1') -Force
    $fileVersions = ConvertFrom-VersionsEnv -Path $versionsFile
    foreach ($entry in @(
            @{ Ref = 'ONNXRUNTIME'; Key = 'ONNXRUNTIME_VERSION' },
            @{ Ref = 'OPENCV';      Key = 'OPENCV_VERSION' },
            @{ Ref = 'FFMPEG';      Key = 'FFMPEG_VERSION' },
            @{ Ref = 'GSTREAMER';   Key = 'GSTREAMER_VERSION' }
        )) {
        if ($fileVersions.Contains($entry.Key)) { $defaultRefs[$entry.Ref] = $fileVersions[$entry.Key] }
    }
}
foreach ($k in $Versions.Keys) { $defaultRefs[$k] = $Versions[$k] }

$repoMap = @{
    'onnxruntime'    = @{ Url = 'https://github.com/microsoft/onnxruntime.git';   Ref = $defaultRefs.ONNXRUNTIME }
    'opencv'         = @{ Url = 'https://github.com/opencv/opencv.git';           Ref = $defaultRefs.OPENCV }
    'opencv_contrib' = @{ Url = 'https://github.com/opencv/opencv_contrib.git';   Ref = $defaultRefs.OPENCV }
    'ffmpeg'         = @{ Url = 'https://github.com/FFmpeg/FFmpeg.git';           Ref = $defaultRefs.FFMPEG }
    'gstreamer'      = @{ Url = 'https://github.com/gstreamer/gstreamer.git';     Ref = $defaultRefs.GSTREAMER }
}

function Get-PatchTargetPaths {
    param([string]$PatchFile)
    # Pull the b/<path> side of every diff header; return the unique parent dirs for sparse-checkout.
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($PatchFile)) {
        if ($line -match '^\+\+\+ b/(.+?)\s*$') { $paths.Add($Matches[1]) }
    }
    return $paths
}

$patches = Get-ChildItem -Path $PatchRoot -Recurse -Filter '*.patch' | Sort-Object FullName
if (-not $patches) { Write-Host 'No .patch files found.'; return }

Write-Host "Checking $($patches.Count) patch(es) against pinned upstreams..." -ForegroundColor Cyan
$results = [System.Collections.Generic.List[object]]::new()
$clones = @{}   # repoKey|ref -> clone dir (reused across patches for the same repo)

try {
    foreach ($p in $patches) {
        $repoKey = Split-Path (Split-Path $p.FullName -Parent) -Leaf
        $spec = $repoMap[$repoKey]
        if (-not $spec) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = '?'; Status = 'SKIP (no repo mapping)' })
            continue
        }
        $targets = Get-PatchTargetPaths -PatchFile $p.FullName
        if (-not $targets) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = 'SKIP (no +++ b/ headers)' })
            continue
        }
        $cacheKey = "$repoKey|$($spec.Ref)"
        $clone = $clones[$cacheKey]
        if (-not $clone) {
            $clone = Join-Path $WorkDir $cacheKey.Replace('|', '_').Replace('/', '_')
            Write-Host "  clone $repoKey @ $($spec.Ref) (sparse)..." -ForegroundColor DarkGray
            & git clone --depth 1 --branch $spec.Ref --filter=blob:none --sparse $spec.Url $clone 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = 'FAIL (clone)' })
                continue
            }
            $clones[$cacheKey] = $clone
        }
        # Materialize exactly the files the patch touches, using NON-cone sparse-checkout with the
        # literal target paths. Cone mode's `sparse-checkout add <dir>` rejects some perfectly-valid
        # directory args with "specify directories rather than patterns" and, worse, leaves the tree
        # in a state where a later file silently isn't checked out -- making a good patch look rotten.
        # Non-cone `set` with the exact forward-slash file paths is deterministic and blob-minimal.
        $targetArgs = @($targets)
        $scOut = & git -C $clone sparse-checkout set --no-cone -- @targetArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = "FAIL (sparse-checkout: $($scOut | Select-Object -First 1))" })
            continue
        }
        # Report a missing target file distinctly from a hunk mismatch -- otherwise a checkout gap
        # masquerades as patch rot.
        $missing = @($targets | Where-Object { -not (Test-Path (Join-Path $clone $_)) })
        if ($missing.Count -gt 0) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = "FAIL (target not checked out: $($missing[0]))" })
            continue
        }
        # The exact flags Invoke-SourcePatch uses. Capture stderr so a real mismatch is explained.
        $applyOut = & git -C $clone apply --check -p1 --ignore-whitespace $p.FullName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = 'OK' })
        } else {
            $reason = ($applyOut | Where-Object { $_ -match 'error:' } | Select-Object -First 1)
            if (-not $reason) { $reason = ($applyOut | Select-Object -First 1) }
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = "FAIL ($reason)" })
        }
    }
}
finally {
    if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
}

Write-Host ''
$results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Status -like 'FAIL*' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) patch(es) FAILED to apply -- regenerate them against the new pinned upstream." -ForegroundColor Red
    exit 1
}
Write-Host "All mapped patches apply cleanly." -ForegroundColor Green

