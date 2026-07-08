# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Orchestrates the media-litert chain (LiteRT -> LiteRT-LM) inside ONE container.
# This is the payload for the run+commit path in windows/build.ps1 (sequential mode):
# because this host's `docker build` is hard-capped at 2 CPUs (Hyper-V) and process
# isolation cannot commit layers, the CPU-bound LiteRT/LiteRT-LM compiles run via
# `docker run --cpu-count N` (which DOES get N CPUs under Hyper-V) followed by
# `docker commit`. This replaces the two sequential RUN steps that Dockerfile.media-litert
# used to contain. LiteRT-LM depends on LiteRT's install, so the two stay sequential.
#
# It is baked into windows-media-litert-builder (see Dockerfile.media-litert-builder)
# and invoked as: powershell -NoProfile -ExecutionPolicy Bypass -File <thisscript>.
# Version/config come from environment variables baked into the builder image.

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# LiteRT-LM depends on LiteRT's install, so the two stay sequential. Invoke-SourceBuildChain
# owns the banner + native-exit check + EAP=Stop inheritance the child scripts rely on.
$stages = @(
    @{ Name = 'LiteRT';    Script = 'build-litert-from-source.ps1';    SourceDir = 'C:\temp\litert-src' }
    @{ Name = 'LiteRT-LM'; Script = 'build-litert-lm-from-source.ps1'; SourceDir = 'C:\temp\litert-lm-src' }
)

Invoke-SourceBuildChain -Label 'media-litert' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir

Write-Host "`n=== media-litert chain completed ==="
