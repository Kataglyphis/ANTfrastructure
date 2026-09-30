#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
Reproduces the sccache nvcc server deadlock on purpose and captures a server-side trace for mozilla/sccache#2808.
.DESCRIPTION
Expected to fail after ~80 minutes of compile; never run it beside another build, which shares the server and cache mount.
The trace goes inside the cache mount, since a log in the build tree dies with the failed vertex.
#>
[CmdletBinding()]
param(
    # Empty = resolved below, since a param default cannot use the layout resolver.
    [string]$OutDir = '',
    # Skip the "is another build running" guard (you almost never want this).
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $scriptAssetRoot '..\..\out\sccache-repro' }
$repoRoot = Resolve-Path (Join-Path $scriptAssetRoot '..\..')

Write-Host '=== sccache CUDA-LLM deadlock repro (mozilla/sccache#2808) ===' -ForegroundColor Cyan
Write-Host 'This run is EXPECTED to fail at ~4910s. The failure is the artifact.' -ForegroundColor Yellow

# Never beside another build: a shared server and cache mount would make a wedge unattributable.
$busy = @(Get-CimInstance Win32_Process -Filter "Name='buildctl.exe'" -ErrorAction SilentlyContinue)
if ($busy.Count -gt 0 -and -not $Force) {
    throw ("$($busy.Count) buildctl process(es) are running. Refusing to start: a concurrent build shares the " +
           'sccache server and the locked cache mount, so any wedge would be unattributable. Wait, or pass -Force.')
}

# Preconditions
$df = Join-Path $repoRoot 'windows\Dockerfile.media-builder'
$dfText = Get-Content $df -Raw
if ($dfText -notmatch 'ARG\s+SCCACHE_REPRO_CUDA_LLM' -or $dfText -notmatch 'ARG\s+SCCACHE_CUDA_LAUNCHER') {
    throw ("$df does not declare ARG/ENV for SCCACHE_REPRO_CUDA_LLM and SCCACHE_CUDA_LAUNCHER " +
           "(both live in the media-core-built-onnx stage since 2026-08-17; unset ARGs are inert). " +
           'Without the declarations buildctl silently discards the --opt build-args and this repro ' +
           'compiles bare nvcc — a false all-clear.')
}

# Runs WebDAV-only: a wedge is sccache-internal, a clean run means the old deadlock was write-failure collateral.

$null = New-Item -ItemType Directory -Force -Path $OutDir
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "repro-$stamp.log"

# Run; the cache mount is the only filesystem that survives a failed solve.
Write-Host "`nBuilding media-core WITHOUT patch 006. Log: $log" -ForegroundColor Cyan
Push-Location $repoRoot
try {
    # Both args, invoked directly: without the launcher, or through pwsh -File, the compiles run bare and pass falsely.
    & 'windows\Build-Buildkit.ps1' `
        -Gpu -Stages media -MediaBranches media-core -NoCacheStage onnx `
        -BuildArg 'SCCACHE_REPRO_CUDA_LLM=1', 'SCCACHE_CUDA_LAUNCHER=1' *>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
} finally { Pop-Location }

if ($code -eq 0) {
    Write-Warning ('The build SUCCEEDED. Either the deadlock no longer reproduces (a finding worth reporting ' +
                   'upstream in its own right) or the ARG never reached the container - check the log for the ' +
                   "SCCACHE_REPRO_CUDA_LLM warning banner emitted by Build-OnnxFromSource.ps1.")
} else {
    Write-Host "`nBuild failed as expected (exit $code). Now extract the server trace from the cache mount:" -ForegroundColor Green
}

Write-Host @'

NEXT: pull the trace out of the persistent cache mount (it is NOT in the build
log — that is the whole reason it was lost the first two times):

  buildctl build --frontend dockerfile.v0 --local context=. --local dockerfile=<a dir with a tiny Dockerfile> ...
  RUN --mount=type=cache,target=C:\sccache,id=sccache-winamd64-2 Get-Content C:\sccache\logs\sccache-error.log

Attach to https://github.com/mozilla/sccache/issues/2808:
  - the last ~200 lines of the server log around the wedge
  - the elapsed time at which it stopped responding (compare to 4909.2 / 4911.5 s)
  - `sccache --show-stats` from the failed run
'@ -ForegroundColor Cyan
