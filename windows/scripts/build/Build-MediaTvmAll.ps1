# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
#
# Orchestrates the media-tvm source-build chain (TVM -> IREE) in ONE RUN.
# Bind-mounted into the `media-tvm-built` stage (Dockerfile.media-builder), which
# mounts the tvmmods module closure rather than plain buildmods.
#
# NOTE: the whole chain is one RUN, so there is no per-stage layer cache -- a
# mid-chain failure re-runs it. The persistent sccache remote
# (SCCACHE_WEBDAV_ENDPOINT) mitigates recompilation across attempts.

[CmdletBinding()]
param(

    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts',
    # Skip the stages before the named one. BuildKit has no preserved container to
    # resume into; it re-solves and replays cached RUN vertices instead.
    [string]$ResumeFrom = '',
    # Stop AFTER the named stage (inclusive) — same chain-partition contract
    # as Build-MediaCoreAll.ps1 (was asymmetrically missing here).
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
    # Target CPython FIRST (#133, 2026-08-26): the tvm and IREE cross wheels
    # link the aarch64 python3XY.lib exactly like ORT/GenAI/cv2 do in
    # media-core -- but this branch starts from the media-core FAN-IN, not from
    # the ONNX layer that built it (arm64 run 29: "no target CPython import lib
    # at C:\temp\cpython\PCbuild\arm64\python314.lib"). Re-running the ~90 s
    # build here keeps the branch self-contained (no cross-branch COPY). Same
    # contract as media-core: reuses the toolchain layer's C:\temp\cpython, never
    # deletes it, explicit no-op on amd64 (host == target).
    @{ Name = 'Target CPython'; Script = 'Build-TargetCpython.ps1'; SourceDir = 'C:\temp\cpython' }
    @{ Name = 'TVM';  Script = 'Build-TvmFromSource.ps1';  SourceDir = 'C:\temp\tvm-src' }
    @{ Name = 'IREE'; Script = 'Build-IreeFromSource.ps1'; SourceDir = 'C:\temp\iree-src' }
)

Invoke-SourceBuildChain -Label 'media-tvm' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir -StartAt $ResumeFrom -Until $Until

Complete-SourceBuildChain -Label 'media-tvm' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0