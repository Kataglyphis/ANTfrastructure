# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Orchestrates the media-core source-build chain (ONNX Runtime -> ONNX GenAI ->
# OpenCV -> FFmpeg) inside ONE container. This is the payload for the run+commit
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
#requires -Version 7.0

    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# Each stage consumes the prior stage's install, so they stay sequential.
# Invoke-SourceBuildChain owns the banner + native-exit check + EAP=Stop inheritance.
$stages = @(
    @{ Name = 'ONNX Runtime'; Script = 'build-onnx-from-source.ps1';       SourceDir = 'C:\temp\onnx-src' }
    @{ Name = 'ONNX GenAI';   Script = 'build-onnx-genai-from-source.ps1'; SourceDir = 'C:\temp\onnx-genai-src' }
    @{ Name = 'OpenCV';       Script = 'build-opencv-from-source.ps1';     SourceDir = 'C:\temp\opencv-src' }
    @{ Name = 'FFmpeg';       Script = 'build-ffmpeg-from-source.ps1';     SourceDir = 'C:\temp\ffmpeg-src' }
)

Invoke-SourceBuildChain -Label 'media-core' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir

# (FFmpeg import-lib normalization now lives INSIDE build-ffmpeg-from-source.ps1
# — it harvests .lib/.def from prefix+build tree and regenerates from .def; the
# bin\->lib\ copy that used to sit here would silently mask a regression there.)

# Hit/miss counters die with this container -- dump them into the run log now.
Write-SccacheStats -Label 'media-core'

Write-Host "`n=== media-core chain completed ==="

