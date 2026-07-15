# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Orchestrates the media-tvm source-build chain (TVM -> IREE) inside ONE
# container -- the run+commit payload for windows/build.ps1 (docker build is
# hard-capped at 2 CPUs under Hyper-V; the heavy compiles run via
# `docker run --cpu-count N` + `docker commit`). Baked into
# windows-media-tvm-builder (Dockerfile.media-builder --target media-tvm).
#
# NOTE: a single `docker run` has no per-stage layer cache -- a mid-chain
# failure re-runs the whole chain. The persistent sccache remote
# (SCCACHE_WEBDAV_ENDPOINT) mitigates recompilation across attempts.

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# The two ML compilers are independent installs (C:\runtime\lib\tvm and
# C:\runtime\iree); they share this branch because both are LLVM-heavy compiler
# builds with the same toolchain needs. Sequential: one sccache + one ninja at
# a time keeps the memory-per-job model valid.
$stages = @(
    @{ Name = 'TVM';  Script = 'build-tvm-from-source.ps1';  SourceDir = 'C:\temp\tvm-src' }
    @{ Name = 'IREE'; Script = 'build-iree-from-source.ps1'; SourceDir = 'C:\temp\iree-src' }
)

Invoke-SourceBuildChain -Label 'media-tvm' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir

Write-Host "`n=== media-tvm chain completed ==="
