# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
#
# Orchestrates the media-litert chain (LiteRT -> LiteRT-LM) inside ONE container.
# This is the payload for the run+commit path in windows/build.ps1 (sequential mode):
# because this host's `docker build` is hard-capped at 2 CPUs (Hyper-V) and process
# isolation cannot commit layers, the CPU-bound LiteRT/LiteRT-LM compiles run via
# `docker run --cpu-count N` (which DOES get N CPUs under Hyper-V) followed by
# `docker commit`. LiteRT-LM depends on LiteRT's install, so the two stay sequential.
#
# It is baked into windows-media-litert-builder (see Dockerfile.media-builder --target media-litert)
# and invoked as: pwsh -NoProfile -ExecutionPolicy Bypass -File <thisscript>.
# Version/config come from environment variables baked into the builder image.

[CmdletBinding()]
param(

    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts',
    # Resume inside a preserved container after a mid-chain failure: skip the
    # stages before the named one (see build.ps1's recovery recipe on failure).
    [string]$ResumeFrom = '',
    # Stop AFTER the named stage (inclusive) — same chain-partition contract
    # as build-media-core-all.ps1 / build-media-tvm-all.ps1 (was asymmetrically
    # missing here).
    [string]$Until = '',
    # Scrub package/temp scratch INSIDE this process, i.e. inside the layer that
    # created it — see Complete-SourceBuildChain for why a downstream scrub
    # cannot shrink this layer.
    [switch]$ScrubAfter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# Two phases, sequential (LiteRT-LM needs no LiteRT SDK install, but they share
# the branch and export order):
#   1. LiteRT — the C++ SDK (headers + .lib for C:\runtime\lib\litert). STILL
#      CMake (build-litert-from-source.ps1): it works and is a separate concern.
#   2. LiteRT-LM — the litert_lm_main.exe runner. MIGRATED TO BAZEL 2026-08-12
#      (build-litert-lm-bazel.ps1): Google's CI-tested path builds it in ~9 min
#      with zero patches, ending the CMake port's unbounded staleness-shell
#      peeling (proto/absl/litert-pin/examples/ruy, ~2.5 h each). The CMake port
#      (build-litert-lm-from-source.ps1) + its export bridge stay in-tree as the
#      documented frozen fallback. The bazel script has its OWN signature
#      (-InstallDir/-RepositoryCache, no -SourceDir), so it runs OUTSIDE
#      Invoke-SourceBuildChain.
$phases = @('LiteRT', 'LiteRT-LM')
if ($ResumeFrom -and ($phases -notcontains $ResumeFrom)) { throw "build-litert-all: -ResumeFrom '$ResumeFrom' not in: $($phases -join ', ')" }
if ($Until -and ($phases -notcontains $Until)) { throw "build-litert-all: -Until '$Until' not in: $($phases -join ', ')" }
$startIdx = if ($ResumeFrom) { $phases.IndexOf($ResumeFrom) } else { 0 }
$stopIdx = if ($Until) { $phases.IndexOf($Until) } else { $phases.Count - 1 }

if ($startIdx -le 0 -and $stopIdx -ge 0) {
    # Invoke-SourceBuildChain owns the banner + native-exit check + EAP=Stop
    # inheritance + the sccache stats dump the CMake SDK build relies on.
    Invoke-SourceBuildChain -Label 'media-litert' -InstallDir $InstallDir -ScriptDir $ScriptDir -Stages @(
        @{ Name = 'LiteRT'; Script = 'build-litert-from-source.ps1'; SourceDir = 'C:\temp\litert-src' }
    )
} else {
    Write-Host "`n=== media-litert stage: LiteRT — SKIPPED (partition) ==="
}

if ($startIdx -le 1 -and $stopIdx -ge 1) {
    Write-Host "`n=== media-litert stage: LiteRT-LM (bazel) ($([string]::Format('{0:HH:mm:ss}', (Get-Date)))) ==="
    # Repository cache mount (optional) for cross-run reuse; the bazel
    # output_base stays container-local (see the script's header).
    & (Join-Path $ScriptDir 'build-litert-lm-bazel.ps1') -InstallDir $InstallDir -RepositoryCache ([string]$env:BAZEL_REPO_CACHE)
    $lmExit = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($lmExit) { throw "LiteRT-LM (bazel) build failed (exit $lmExit)" }
} else {
    Write-Host "`n=== media-litert stage: LiteRT-LM — SKIPPED (partition) ==="
}

Complete-SourceBuildChain -Label 'media-litert' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0