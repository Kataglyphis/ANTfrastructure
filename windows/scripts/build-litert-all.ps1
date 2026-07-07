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

# Preference variables inherit into the child scripts invoked with '&' below, so
# each behaves exactly as it did under the Dockerfile SHELL (EAP=Stop).
$stages = @(
    @{ Name = 'LiteRT';    Script = 'build-litert-from-source.ps1';    SourceDir = 'C:\temp\litert-src' }
    @{ Name = 'LiteRT-LM'; Script = 'build-litert-lm-from-source.ps1'; SourceDir = 'C:\temp\litert-lm-src' }
)

foreach ($stage in $stages) {
    Write-Host "`n=== media-litert stage: $($stage.Name) ($([string]::Format('{0:HH:mm:ss}', (Get-Date)))) ==="
    & (Join-Path $ScriptDir $stage.Script) -SourceDir $stage.SourceDir -InstallDir $InstallDir
    if ($LASTEXITCODE) { throw "$($stage.Name) build failed (exit $LASTEXITCODE)" }
}

Write-Host "`n=== media-litert chain completed ==="
