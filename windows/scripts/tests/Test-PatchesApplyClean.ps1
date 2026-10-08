# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#requires -Version 7.0

<#
.SYNOPSIS
    Check that every static .patch under windows/scripts/patches/ still applies to its pinned upstream.

.DESCRIPTION
    Sparse-clones each pinned upstream and runs the build's own `git apply --check -p1 --ignore-whitespace`,
    then GNU patch's dry run, which is what Invoke-SourcePatch uses on a tarball (non-git) source.
    Needs network, git and patch.exe; run it before a version bump. See windows/scripts/patches/README.md.

.PARAMETER PatchRoot
    Root of the patch tree (default: windows/scripts/patches).

.PARAMETER Versions
    Hashtable overriding the pinned ref per repo key; MIGRAPHX takes a 40-hex commit.

.PARAMETER WorkDir
    Scratch dir for the clones (default: a temp dir, removed afterwards).

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

# Refs come from versions.env; these literals are only the fallback when it is missing.
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -Force -DisableNameChecking
$versionsFile = Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'
$defaultRefs = @{
    ONNXRUNTIME = 'v1.27.0'
    OPENCV      = '5.x'
    FFMPEG      = 'master'
    GSTREAMER   = '1.29.2'
    LLVM        = 'llvmorg-23.1.0'
    HAILORT     = 'v5.4.0'
    MIGRAPHX    = '95672916ed289d4be9d230a9be732e1bbad97e8c'
}
if (Test-Path $versionsFile) {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsScripts.Shared.psm1') -Force
    $fileVersions = ConvertFrom-VersionsEnv -Path $versionsFile
    foreach ($entry in @(
            @{ Ref = 'ONNXRUNTIME'; Key = 'ONNXRUNTIME_VERSION' },
            @{ Ref = 'OPENCV';      Key = 'OPENCV_VERSION' },
            @{ Ref = 'FFMPEG';      Key = 'FFMPEG_VERSION' },
            @{ Ref = 'GSTREAMER';   Key = 'GSTREAMER_VERSION' },
            @{ Ref = 'LLVM';        Key = 'LLVM_WINDOWS_VERSION'; Fmt = 'llvmorg-{0}' },
            # The tag Build-HailortFromSource.ps1 downloads (archive/refs/tags/v<ver>).
            @{ Ref = 'HAILORT';     Key = 'HAILORT_VERSION';      Fmt = 'v{0}' },
            # A commit, not a tag: the one Build-MigraphxFromSource.ps1 downloads (archive/<sha>).
            @{ Ref = 'MIGRAPHX';    Key = 'MIGRAPHX_WINDOWS_COMMIT' }
        )) {
        if ($fileVersions.Contains($entry.Key)) {
            $val = $fileVersions[$entry.Key]
            if ($entry.Contains('Fmt')) { $val = $entry.Fmt -f $val }
            $defaultRefs[$entry.Ref] = $val
        }
    }
}
foreach ($k in $Versions.Keys) { $defaultRefs[$k] = $Versions[$k] }

$repoMap = @{
    'onnxruntime'    = @{ Url = 'https://github.com/microsoft/onnxruntime.git';   Ref = $defaultRefs.ONNXRUNTIME }
    'opencv'         = @{ Url = 'https://github.com/opencv/opencv.git';           Ref = $defaultRefs.OPENCV }
    'opencv_contrib' = @{ Url = 'https://github.com/opencv/opencv_contrib.git';   Ref = $defaultRefs.OPENCV }
    'ffmpeg'         = @{ Url = 'https://github.com/FFmpeg/FFmpeg.git';           Ref = $defaultRefs.FFMPEG }
    'gstreamer'      = @{ Url = 'https://github.com/gstreamer/gstreamer.git';     Ref = $defaultRefs.GSTREAMER }
    'llvm'           = @{ Url = 'https://github.com/llvm/llvm-project.git';       Ref = $defaultRefs.LLVM }
    'hailo'          = @{ Url = 'https://github.com/hailo-ai/hailort.git';        Ref = $defaultRefs.HAILORT }
    'migraphx'       = @{ Url = 'https://github.com/ROCm/AMDMIGraphX.git';        Ref = $defaultRefs.MIGRAPHX }
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

# The image's patch.exe is Git for Windows' GNU patch; Strawberry Perl's patch 2.5.9 (first on the dev host's PATH) asserts on every patch.
function Resolve-GnuPatchExe {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    $candidates = @(
        if ($git) { Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'usr\bin\patch.exe' }
        Get-Command patch.exe -All -ErrorAction SilentlyContinue | ForEach-Object Source
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    foreach ($c in $candidates) {
        if ("$(& $c --version 2>&1 | Select-Object -First 1)" -match '^GNU patch ') { return $c }
    }
    throw "no GNU patch.exe found (tried: $($candidates -join ', ')): Invoke-SourcePatch applies tarball patches with it, so this gate must too."
}
$patchExe = Resolve-GnuPatchExe

# @(): a -PatchRoot holding one patch yields a scalar, and StrictMode refuses .Count on it.
$patches = @(Get-ChildItem -Path $PatchRoot -Recurse -Filter '*.patch' | Sort-Object FullName)
if (-not $patches) { Write-Host 'No .patch files found.'; return }

Write-Host "Checking $($patches.Count) patch(es) against pinned upstreams..." -ForegroundColor Cyan
$results = [System.Collections.Generic.List[object]]::new()
$clones = @{}   # repoKey|ref -> clone dir (reused across patches for the same repo)

try {
    foreach ($p in $patches) {
        $repoKey = Split-Path (Split-Path $p.FullName -Parent) -Leaf
        $spec = $repoMap[$repoKey]
        if (-not $spec) {
            # FAIL, not SKIP: an unmapped patch directory would otherwise escape this gate silently.
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = '?'; Status = 'FAIL (no repo mapping - add it to $repoMap)' })
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
            # --branch takes names only; a 40-hex commit pin (MIGraphX) needs --revision (git >= 2.49).
            $refArgs = @(if ($spec.Ref -match '^[0-9a-f]{40}$') { "--revision=$($spec.Ref)" } else { '--branch', $spec.Ref })
            # LF like the build's tarball and container checkouts; a host's autocrlf=true would red every GNU patch check.
            & git clone --config core.autocrlf=false --depth 1 @refArgs --filter=blob:none --sparse $spec.Url $clone 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = 'FAIL (clone)' })
                continue
            }
            $clones[$cacheKey] = $clone
        }
        # Non-cone `set` with literal paths: cone mode rejects some valid dirs and can silently skip a later file.
        $targetArgs = @($targets)
        $scOut = & git -C $clone sparse-checkout set --no-cone -- @targetArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = "FAIL (sparse-checkout: $($scOut | Select-Object -First 1))" })
            continue
        }
        # Report a missing target apart from a hunk mismatch, or a checkout gap looks like patch rot.
        $missing = @($targets | Where-Object { -not (Test-Path (Join-Path $clone $_)) })
        if ($missing.Count -gt 0) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = "FAIL (target not checked out: $($missing[0]))" })
            continue
        }
        # The exact flags Invoke-SourcePatch uses. Capture stderr so a real mismatch is explained.
        $applyOut = & git -C $clone apply --check -p1 --ignore-whitespace $p.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            $reason = ($applyOut | Where-Object { $_ -match 'error:' } | Select-Object -First 1)
            if (-not $reason) { $reason = ($applyOut | Select-Object -First 1) }
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = "FAIL ($reason)" })
            continue
        }
        # --force never prompts; GNU patch reads `index 0000000..` as a new file and anchors short trailing context at EOF.
        $gnuOut = & $patchExe -p1 --dry-run --force -d $clone -i $p.FullName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = 'OK' })
        } else {
            $reason = ($gnuOut | Where-Object { $_ -match 'FAILED|exists|malformed|reversed|can.t find' } | Select-Object -First 1)
            if (-not $reason) { $reason = ($gnuOut | Select-Object -First 1) }
            $results.Add([pscustomobject]@{ Patch = $p.Name; Repo = $repoKey; Ref = $spec.Ref; Status = "FAIL (GNU patch: $reason)" })
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

