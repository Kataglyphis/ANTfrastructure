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
# It is baked into windows-media-core-builder (see Dockerfile.media-core-builder)
# and invoked as: powershell -NoProfile -ExecutionPolicy Bypass -File <thisscript>.
# Version/config come from environment variables baked into the builder image.
#
# NOTE: unlike a multi-RUN `docker build`, a single `docker run` has no per-stage
# layer cache — a mid-chain failure re-runs the whole chain. The persistent sccache
# remote (SCCACHE_WEBDAV_ENDPOINT) mitigates recompilation across attempts.

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Preference variables inherit into the child scripts invoked with '&' below, so
# each behaves exactly as it did under the Dockerfile SHELL (EAP=Stop).
$stages = @(
    @{ Name = 'ONNX Runtime'; Script = 'build-onnx-from-source.ps1';       SourceDir = 'C:\temp\onnx-src' }
    @{ Name = 'ONNX GenAI';   Script = 'build-onnx-genai-from-source.ps1'; SourceDir = 'C:\temp\onnx-genai-src' }
    @{ Name = 'OpenCV';       Script = 'build-opencv-from-source.ps1';     SourceDir = 'C:\temp\opencv-src' }
    @{ Name = 'FFmpeg';       Script = 'build-ffmpeg-from-source.ps1';     SourceDir = 'C:\temp\ffmpeg-src' }
)

foreach ($stage in $stages) {
    Write-Host "`n=== media-core stage: $($stage.Name) ($([string]::Format('{0:HH:mm:ss}', (Get-Date)))) ==="
    & (Join-Path $ScriptDir $stage.Script) -SourceDir $stage.SourceDir -InstallDir $InstallDir
    if ($LASTEXITCODE) { throw "$($stage.Name) build failed (exit $LASTEXITCODE)" }
}

# FFmpeg's msvc install routes the import libs (avcodec.lib, ...) into bin\ while its
# pkgconfig files point linkers at lib\ — gst-libav's link (downstream) fails without
# this normalization. (Mirrors the final RUN that Dockerfile.media-core carried.)
if (Test-Path 'C:\runtime\ffmpeg\bin') {
    Copy-Item 'C:\runtime\ffmpeg\bin\*.lib' 'C:\runtime\ffmpeg\lib\' -Force -ErrorAction SilentlyContinue
    Write-Host ('import libs in lib\: ' + @(Get-ChildItem 'C:\runtime\ffmpeg\lib\*.lib' -ErrorAction SilentlyContinue).Count)
}

Write-Host "`n=== media-core chain completed ==="
