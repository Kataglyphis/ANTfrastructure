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
    # Where to drop the collected trace on the host. Empty = resolved below
    # (a param default cannot reference the layout resolver defined after it).
    [string]$OutDir = '',
    # Skip the "is another build running" guard (you almost never want this).
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $scriptAssetRoot '..\..\out\sccache-repro' }
$repoRoot = Resolve-Path (Join-Path $scriptAssetRoot '..\..')

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
if ($dfText -notmatch 'ARG\s+SCCACHE_REPRO_CUDA_LLM' -or $dfText -notmatch 'ARG\s+SCCACHE_CUDA_LAUNCHER') {
    throw ("$df does not declare ARG/ENV for SCCACHE_REPRO_CUDA_LLM and SCCACHE_CUDA_LAUNCHER " +
           "(both live in the media-core-built-onnx stage since 2026-08-17; unset ARGs are inert). " +
           'Without the declarations buildctl silently discards the --opt build-args and this repro ' +
           'compiles bare nvcc — a false all-clear.')
}

# CONTEXT since 2026-08-17 (#99): the original deadlock was measured while the
# L0 disk tier sat on a BuildKit cache mount that failed 100 % of writes with
# os error 3 — the server may have wedged inside that error-path storm, not in
# its own decomposition logic. The chain now defaults to WebDAV-only, so THIS
# run tests the deadlock in a storage environment that has never hosted it:
#   * still wedges  -> genuinely sccache-internal; attach the trace to #2808.
#   * runs through  -> the deadlock was #99 collateral; report THAT upstream,
#     and only then run the three-canary miscompile bar (AGENTS.md) before any
#     thought of enabling the CUDA launcher by default.

$null = New-Item -ItemType Directory -Force -Path $OutDir
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "repro-$stamp.log"

# ---- Run -------------------------------------------------------------------
# SCCACHE_LOG=debug + an SCCACHE_ERROR_LOG inside the cache mount: the mount is
# the only filesystem that survives a failed solve.
Write-Host "`nBuilding media-core WITHOUT patch 006. Log: $log" -ForegroundColor Cyan
Push-Location $repoRoot
try {
    # BOTH build-args, and this is load-bearing: since the 2026-08-10 opt-in
    # flip, skipping patch 006 alone leaves the CUDA compiles BARE
    # (Invoke-CmakeConfigure only adds CMAKE_CUDA_COMPILER_LAUNCHER under
    # SCCACHE_CUDA_LAUNCHER=1). Without the second arg this repro "succeeds",
    # and the success branch below reads as "deadlock no longer reproduces" —
    # a false all-clear from an instrument that never touched the fault line.
    #
    # DIRECT invocation, NOT `& pwsh -File`: -File flattens a comma array into
    # ONE literal string INCLUDING the quote characters, so buildctl received
    # --opt build-arg:'SCCACHE_REPRO_CUDA_LLM=1','SCCACHE_CUDA_LAUNCHER=1' — an
    # undeclared ARG name it silently discarded. That produced exactly the
    # false all-clear described above on the first live run (2026-08-18,
    # 88 min: patch 006 applied, CUDA bare, build green, zero signal).
    & 'windows\build-buildkit.ps1' `
        -Gpu -Stages media -MediaBranches media-core -NoCacheStage onnx `
        -BuildArg 'SCCACHE_REPRO_CUDA_LLM=1', 'SCCACHE_CUDA_LAUNCHER=1' *>&1 | Tee-Object -FilePath $log
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
