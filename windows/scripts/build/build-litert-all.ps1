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
# ONE chain call for both phases (#128, 2026-08-21): the bazel script's own
# signature (-RepositoryCache, no -SourceDir) used to force it OUTSIDE
# Invoke-SourceBuildChain, and this wrapper reimplemented the whole
# -ResumeFrom/-Until partition logic (26 lines) around that split. The chain's
# Invoke-stage shape carries the odd signature now; the chain also owns the
# banner + native-exit check + partition validation + the sccache stats dump.
Invoke-SourceBuildChain -Label 'media-litert' -InstallDir $InstallDir -ScriptDir $ScriptDir `
    -StartAt $ResumeFrom -Until $Until -Stages @(
    @{ Name = 'LiteRT'; Script = 'build-litert-from-source.ps1'; SourceDir = 'C:\temp\litert-src' }
    @{ Name = 'LiteRT-LM'; Invoke = { param($sd, $id)
            # Repository cache mount (optional) for cross-run reuse; the bazel
            # output_base stays container-local (see the script's header).
            & (Join-Path $sd 'build-litert-lm-bazel.ps1') -InstallDir $id -RepositoryCache ([string]$env:BAZEL_REPO_CACHE)
        } }
)

Complete-SourceBuildChain -Label 'media-litert' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0