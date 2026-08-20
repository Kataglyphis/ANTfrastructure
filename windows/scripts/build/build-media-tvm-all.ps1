# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
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
    [string]$ScriptDir  = 'C:\temp\scripts',
    # Resume inside a preserved container after a mid-chain failure: skip the
    # stages before the named one (see build.ps1's recovery recipe on failure).
    [string]$ResumeFrom = '',
    # Stop AFTER the named stage (inclusive) — same chain-partition contract
    # as build-media-core-all.ps1 (was asymmetrically missing here).
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

# The two ML compilers are independent installs (C:\runtime\lib\tvm and
# C:\runtime\iree); they share this branch because both are LLVM-heavy compiler
# builds with the same toolchain needs. Sequential: one sccache + one ninja at
# a time keeps the memory-per-job model valid.
$stages = @(
    @{ Name = 'TVM';  Script = 'build-tvm-from-source.ps1';  SourceDir = 'C:\temp\tvm-src' }
    @{ Name = 'IREE'; Script = 'build-iree-from-source.ps1'; SourceDir = 'C:\temp\iree-src' }
)

Invoke-SourceBuildChain -Label 'media-tvm' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir -StartAt $ResumeFrom -Until $Until

Complete-SourceBuildChain -Label 'media-tvm' -ScrubAfter:$ScrubAfter

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0