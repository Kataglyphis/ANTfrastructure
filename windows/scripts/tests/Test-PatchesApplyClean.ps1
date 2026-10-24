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
    LITERT      = 'v2.3.0'
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
            @{ Ref = 'MIGRAPHX';    Key = 'MIGRAPHX_WINDOWS_COMMIT' },
            # The tag Build-LitertWheelBazel.ps1 clones; its patches feed the ai-edge-litert wheel.
            @{ Ref = 'LITERT';      Key = 'LITERT_VERSION' }
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
    'litert'         = @{ Url = 'https://github.com/google-ai-edge/LiteRT.git';   Ref = $defaultRefs.LITERT }
}

function Get-PatchTargetPaths {
    param([string]$PatchFile)
    # Pull the b/<path> side of every diff header; return the unique parent dirs for sparse-checkout.
    $paths = [System.Collections.Generic.List[string]]::new()
    $previous = ''
    foreach ($line in [System.IO.File]::ReadAllLines($PatchFile)) {
        # A file the patch creates (--- /dev/null) is not there to check out yet.
        if ($line -match '^\+\+\+ b/(.+?)\s*$' -and $previous -ne '--- /dev/null') { $paths.Add($Matches[1]) }
        $previous = $line
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

function Get-PatchClone {
    param([string]$RepoKey, [hashtable]$Spec, [hashtable]$Clones, [string]$WorkDir)
    $cacheKey = "$RepoKey|$($Spec.Ref)"
    if ($Clones[$cacheKey]) { return [pscustomobject]@{ Path = $Clones[$cacheKey]; Error = '' } }
    $clone = Join-Path $WorkDir $cacheKey.Replace('|', '_').Replace('/', '_')
    Write-Host "  clone $RepoKey @ $($Spec.Ref) (sparse)..." -ForegroundColor DarkGray
    $refArgs = @(if ($Spec.Ref -match '^[0-9a-f]{40}$') { "--revision=$($Spec.Ref)" } else { '--branch', $Spec.Ref })
    & git clone --config core.autocrlf=false --depth 1 @refArgs --filter=blob:none --sparse $Spec.Url $clone 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Path = ''; Error = 'FAIL (clone)' } }
    $Clones[$cacheKey] = $clone
    return [pscustomobject]@{ Path = $clone; Error = '' }
}

function Get-PatchApplyStatus {
    param([string]$Clone, [string[]]$Targets, [string]$PatchFile, [string]$PatchExe)
    $sparseOutput = & git -C $Clone sparse-checkout set --no-cone -- @Targets 2>&1
    if ($LASTEXITCODE -ne 0) { return "FAIL (sparse-checkout: $($sparseOutput | Select-Object -First 1))" }
    $missing = @($Targets | Where-Object { -not (Test-Path (Join-Path $Clone $_)) })
    if ($missing.Count -gt 0) { return "FAIL (target not checked out: $($missing[0]))" }
    $applyOutput = & git -C $Clone apply --check -p1 --ignore-whitespace $PatchFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        $reason = ($applyOutput | Where-Object { $_ -match 'error:' } | Select-Object -First 1)
        if (-not $reason) { $reason = ($applyOutput | Select-Object -First 1) }
        return "FAIL ($reason)"
    }
    $gnuOutput = & $PatchExe -p1 --dry-run --force -d $Clone -i $PatchFile 2>&1
    if ($LASTEXITCODE -eq 0) { return 'OK' }
    $reason = ($gnuOutput | Where-Object { $_ -match 'FAILED|exists|malformed|reversed|can.t find' } | Select-Object -First 1)
    if (-not $reason) { $reason = ($gnuOutput | Select-Object -First 1) }
    return "FAIL (GNU patch: $reason)"
}

function Get-StaticPatchResult {
    param([IO.FileInfo]$Patch, [hashtable]$RepoMap, [hashtable]$Clones, [string]$WorkDir, [string]$PatchExe)
    $repoKey = Split-Path (Split-Path $Patch.FullName -Parent) -Leaf
    $spec = $RepoMap[$repoKey]
    if (-not $spec) {
        return [pscustomobject]@{ Patch = $Patch.Name; Repo = $repoKey; Ref = '?'; Status = 'FAIL (no repo mapping - add it to $repoMap)' }
    }
    $targets = @(Get-PatchTargetPaths -PatchFile $Patch.FullName)
    if (-not $targets) {
        return [pscustomobject]@{ Patch = $Patch.Name; Repo = $repoKey; Ref = $spec.Ref; Status = 'SKIP (no +++ b/ headers)' }
    }
    $checkout = Get-PatchClone -RepoKey $repoKey -Spec $spec -Clones $Clones -WorkDir $WorkDir
    $status = if ($checkout.Error) { $checkout.Error } else {
        Get-PatchApplyStatus -Clone $checkout.Path -Targets $targets -PatchFile $Patch.FullName -PatchExe $PatchExe
    }
    return [pscustomobject]@{ Patch = $Patch.Name; Repo = $repoKey; Ref = $spec.Ref; Status = $status }
}

$patchExe = Resolve-GnuPatchExe

# @(): a -PatchRoot holding one patch yields a scalar, and StrictMode refuses .Count on it.
$patches = @(Get-ChildItem -Path $PatchRoot -Recurse -Filter '*.patch' | Sort-Object FullName)
if (-not $patches) { Write-Host 'No .patch files found.'; return }

Write-Host "Checking $($patches.Count) patch(es) against pinned upstreams..." -ForegroundColor Cyan
$results = [System.Collections.Generic.List[object]]::new()
$clones = @{}   # repoKey|ref -> clone dir (reused across patches for the same repo)

try {
    foreach ($patch in $patches) {
        $results.Add((Get-StaticPatchResult -Patch $patch -RepoMap $repoMap -Clones $clones -WorkDir $WorkDir -PatchExe $patchExe))
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

