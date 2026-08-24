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
# PER-STAGE cross split (#115, 2026-08-24). The two phases have entirely
# different cross stories and the old BRANCH-level drop threw both away:
#   * plain LiteRT is pure CMake through the shared cross choke point, links no
#     prebuilt blob and needs only a host flatc (TFLITE_HOST_TOOLS_DIR) — it
#     cross-builds, and restoring it also restores the tflite GStreamer plugin.
#   * LiteRT-LM's bazel path is genuinely blocked on the cross lane: no
#     windows-arm64 config in upstream's .bazelrc AND the x86_64-only
#     libGemmaModelConstraintProvider prebuilt sits in the default Windows
#     dependency graph (severable only via litert_lm_fst_constraints_disabled).
#     That is real porting work, tracked in the backlog — skipped here with the
#     reason printed, never silently.
$litertStages = @(
    @{ Name = 'LiteRT'; Script = 'build-litert-from-source.ps1'; SourceDir = 'C:\temp\litert-src' }
)
if (Test-WindowsCrossTarget) {
    Write-Host ("media-litert: LiteRT-LM stage SKIPPED on the $(Get-WindowsTargetArch) cross lane -- upstream's bazel " +
                'path has no windows-arm64 config and default-links an x86_64-only prebuilt (see backlog; ' +
                'plain LiteRT above is unaffected and builds).')
    # The merge fan-in COPYs C:\runtime\lib\litert-lm UNCONDITIONALLY
    # (Dockerfile.media-merge-builder:176 -- a Dockerfile cannot branch), and
    # until #115 that path came from a 'media-branch-absent' stand-in stage
    # (retired 2026-08-24 once every cross branch became real). This REAL
    # image feeds the fan-in, so it must provide an empty, marker-carrying
    # tree, or the COPY fails on a path that legitimately does not exist here.
    # This is now THE convention for anything a cross branch cannot build.
    $lmRoot = Join-Path $InstallDir 'lib\litert-lm'
    foreach ($d in @($lmRoot, (Join-Path $lmRoot 'include'), (Join-Path $lmRoot 'bin'))) {
        New-Item -Path $d -ItemType Directory -Force | Out-Null
    }
    Set-Content -Path (Join-Path $lmRoot 'ABSENT-ON-ARM64.txt') -Encoding ASCII -Value @(
        'LiteRT-LM is not built on the arm64 cross lane. Its ACTIVE build path is Bazel, where two'
        'blockers are real: upstream''s .bazelrc has no windows-arm64 config, and the x86_64-only'
        'libGemmaModelConstraintProvider prebuilt sits in the default Windows dependency graph'
        '(severable via the litert_lm_fst_constraints_disabled config_setting). Plain LiteRT IS'
        'built on this lane (see C:\runtime\lib\litert). See docs/windows-cross-builds.md.'
    )
    Write-Host "media-litert: staged empty litert-lm stand-in tree at $lmRoot (merge fan-in COPY contract)"
} else {
    $litertStages += @{ Name = 'LiteRT-LM'; Invoke = { param($sd, $id)
            # Repository cache mount (optional) for cross-run reuse; the bazel
            # output_base stays container-local (see the script's header).
            & (Join-Path $sd 'build-litert-lm-bazel.ps1') -InstallDir $id -RepositoryCache ([string]$env:BAZEL_REPO_CACHE)
        } }
}
Invoke-SourceBuildChain -Label 'media-litert' -InstallDir $InstallDir -ScriptDir $ScriptDir `
    -StartAt $ResumeFrom -Until $Until -Stages $litertStages

Complete-SourceBuildChain -Label 'media-litert' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0