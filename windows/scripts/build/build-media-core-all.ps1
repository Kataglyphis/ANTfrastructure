# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
#
# Orchestrates the media-core source-build chain (ONNX Runtime -> ONNX GenAI ->
# FFmpeg -> OpenCV) inside ONE container. FFmpeg BEFORE OpenCV is load-bearing
# (#94): OpenCV's video backend links what FFmpeg installed. $stages below is
# the authority -- this header drifted from it once already. This is the payload for the run+commit
# path in windows/build.ps1: because this host's `docker build` is hard-capped at
# 2 CPUs (Hyper-V) and process isolation cannot commit layers, the heavy compiles
# run via `docker run --cpu-count N` (which DOES get N CPUs under Hyper-V) followed
# by `docker commit`. This script therefore replaces the sequential RUN steps that
# Dockerfile.media-core used to contain.
#
# It is baked into windows-media-core-builder (see Dockerfile.media-builder --target media-core)
# and invoked as: pwsh -NoProfile -ExecutionPolicy Bypass -File <thisscript>.
# Version/config come from environment variables baked into the builder image.
#
# NOTE: unlike a multi-RUN `docker build`, a single `docker run` has no per-stage
# layer cache — a mid-chain failure re-runs the whole chain. The persistent sccache
# remote (SCCACHE_WEBDAV_ENDPOINT) mitigates recompilation across attempts.

[CmdletBinding()]
param(

    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts',
    # Resume inside a preserved container after a mid-chain failure: skip the
    # stages before the named one (see build.ps1's recovery recipe on failure).
    [string]$ResumeFrom = '',
    # Stop after the named stage (inclusive). The BuildKit lane splits this chain
    # across two RUN layers (ONNX+GenAI, then OpenCV+FFmpeg): a single ~25 GB
    # layer failed hcsshim ExportLayer at snapshot finalize (2026-08-03), and the
    # split also gives per-half layer caching.
    [string]$Until = '',
    # Run Clear-BuildScratch after the chain, INSIDE this process (the trailing
    # `exit 0` ends the RUN's pwsh, so a scrub appended after the `&` call in a
    # Dockerfile RUN would be dead code — and a scrub in a LATER layer would not
    # shrink the exported one). Used by the LAST media-core direct-solve layer
    # (de-warming 2026-08-05; replaces bk-materialize's -Scrub).
    [switch]$ScrubAfter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# Each stage consumes the prior stage's install, so they stay sequential.
# Invoke-SourceBuildChain owns the banner + native-exit check + EAP=Stop inheritance.
# FFmpeg BEFORE OpenCV (swapped 2026-08-16, backlog #94): OpenCV's videoio only
# links this chain's FFmpeg if FFmpeg is already installed when OpenCV
# configures; otherwise it silently downloads and uses its own prebuilt one
# (`FFMPEG: YES (prebuilt binaries)`, avcodec 61 vs the chain's 63). The reverse
# dependency does not exist — FFmpeg is configured without `--enable-libopencv`
# — so this is a plain reorder, not a cycle break. Callers must pass BOTH
# -ResumeFrom and -Until; relying on a component's POSITION here is what made
# the old ffmpeg invocation (-ResumeFrom only) order-dependent.
$stages = @(
    # Target CPython FIRST (backlog #120): on the cross lane it produces the
    # aarch64 interpreter + python3XY.lib that the ORT wheel / GenAI bindings /
    # cv2 consumers need; on amd64 it is an explicit no-op (host == target).
    # It reuses C:\temp\cpython — the toolchain layer's source tree — so its
    # SourceDir is NOT a clone target and the script never deletes it.
    @{ Name = 'Target CPython'; Script = 'build-target-cpython.ps1';       SourceDir = 'C:\temp\cpython' }
    @{ Name = 'ONNX Runtime'; Script = 'build-onnx-from-source.ps1';       SourceDir = 'C:\temp\onnx-src' }
    @{ Name = 'ONNX GenAI';   Script = 'build-onnx-genai-from-source.ps1'; SourceDir = 'C:\temp\onnx-genai-src' }
    @{ Name = 'FFmpeg';       Script = 'build-ffmpeg-from-source.ps1';     SourceDir = 'C:\temp\ffmpeg-src' }
    @{ Name = 'OpenCV';       Script = 'build-opencv-from-source.ps1';     SourceDir = 'C:\temp\opencv-src' }
)

Invoke-SourceBuildChain -Label 'media-core' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir -StartAt $ResumeFrom -Until $Until

# (FFmpeg import-lib normalization now lives INSIDE build-ffmpeg-from-source.ps1
# — it harvests .lib/.def from prefix+build tree and regenerates from .def; the
# bin\->lib\ copy that used to sit here would silently mask a regression there.)


Complete-SourceBuildChain -Label 'media-core' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0