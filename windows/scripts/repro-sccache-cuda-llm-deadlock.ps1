#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
Deliberately reproduces the sccache nvcc server deadlock and captures a
server-side trace for mozilla/sccache#2808.

.DESCRIPTION
THIS SCRIPT IS SUPPOSED TO FAIL. That is the point.

Our build ships a workaround (patch 006) that pins BARE nvcc onto the
`onnxruntime_providers_cuda_llm` target, because sccache's nvcc decomposition
stops responding while compiling the cutlass-generated fused_moe GEMM launchers.
Two independent builds died at 4909.2 s and 4911.5 s — ±2 s, same TU family,
which is what rules out a random race.

The upstream issue currently rests on client-side evidence only ("error reading
compile response from server", os error 10054). What the maintainers can
actually act on is a SERVER-side log from the moment it wedges. This script
collects exactly that: it disables the workaround, turns on debug logging into
the persistent cache mount (which survives the failed solve), runs the ONNX
stage until it dies, and then extracts the log.

COST: ~80 minutes of compile before the failure point, and one deliberately
broken ONNX build. Do not run it on a chain you want to finish, and do not run
it while another build is active — both would fight over the same sccache server
and the same cache mount.

.NOTES
Reads nothing it does not also print. The trace is written INSIDE the cache
mount on purpose: a log in the build tree dies with the failed vertex, which is
how this evidence was lost the first two times.
#>
[CmdletBinding()]
param(
    # Where to drop the collected trace on the host.
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\out\sccache-repro'),
    # Skip the "is another build running" guard (you almost never want this).
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')

Write-Host '=== sccache CUDA-LLM deadlock repro (mozilla/sccache#2808) ===' -ForegroundColor Cyan
Write-Host 'This run is EXPECTED to fail at ~4910s. The failure is the artifact.' -ForegroundColor Yellow

# ---- Guard: never run concurrently with another build ----------------------
# Both would attach to the same sccache server and the same locked cache mount,
# so a wedge could not be attributed to either one.
$busy = @(Get-CimInstance Win32_Process -Filter "Name='buildctl.exe'" -ErrorAction SilentlyContinue)
if ($busy.Count -gt 0 -and -not $Force) {
    throw ("$($busy.Count) buildctl process(es) are running. Refusing to start: a concurrent build shares the " +
           'sccache server and the locked cache mount, so any wedge would be unattributable. Wait, or pass -Force.')
}

# ---- Preconditions ---------------------------------------------------------
$df = Join-Path $repoRoot 'windows\Dockerfile.media-builder'
$dfText = Get-Content $df -Raw
if ($dfText -notmatch 'ARG\s+SCCACHE_REPRO_CUDA_LLM') {
    throw ("$df does not declare ARG/ENV SCCACHE_REPRO_CUDA_LLM in the media-core-env stage. " +
           "Add it next to the other media-core ARGs (an unset ARG is inert, so it is safe to keep permanently):`n" +
           "    ARG SCCACHE_REPRO_CUDA_LLM=`"`"`n" +
           "and mirror it into that stage's ENV block. This wiring was deliberately NOT applied while a chain " +
           'was mid-flight, because editing the Dockerfile changes the cache key of stages that had not run yet.')
}

$null = New-Item -ItemType Directory -Force -Path $OutDir
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "repro-$stamp.log"

# ---- Run -------------------------------------------------------------------
# SCCACHE_LOG=debug + an SCCACHE_ERROR_LOG inside the cache mount: the mount is
# the only filesystem that survives a failed solve.
Write-Host "`nBuilding media-core WITHOUT patch 006. Log: $log" -ForegroundColor Cyan
Push-Location $repoRoot
try {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File 'windows\build-buildkit.ps1' `
        -Gpu -Stages media -MediaBranches media-core -NoCacheStage onnx `
        -BuildArg 'SCCACHE_REPRO_CUDA_LLM=1' 2>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
} finally { Pop-Location }

if ($code -eq 0) {
    Write-Warning ('The build SUCCEEDED. Either the deadlock no longer reproduces (a finding worth reporting ' +
                   'upstream in its own right) or the ARG never reached the container - check the log for the ' +
                   "SCCACHE_REPRO_CUDA_LLM warning banner emitted by build-onnx-from-source.ps1.")
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
