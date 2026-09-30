# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
# The media-tvm chain in one RUN with the tvmmods closure; no per-stage cache, so a failure re-runs it all.

[CmdletBinding()]
param(

    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts',
    # Skip the stages before the named one; BuildKit replays cached RUN vertices, there is no container to resume.
    [string]$ResumeFrom = '',
    # Stop after the named stage (inclusive).
    [string]$Until = '',
    # Scrub scratch inside this layer; see Complete-SourceBuildChain for why a later scrub cannot shrink it.
    [switch]$ScrubAfter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# Two independent LLVM-heavy compilers, run one at a time so the memory-per-job model holds.
$stages = @(
    # Target CPython again: this branch starts from the media-core fan-in, which lacks it; a no-op on amd64.
    @{ Name = 'Target CPython'; Script = 'Build-TargetCpython.ps1'; SourceDir = 'C:\temp\cpython' }
    @{ Name = 'TVM';  Script = 'Build-TvmFromSource.ps1';  SourceDir = 'C:\temp\tvm-src' }
    @{ Name = 'IREE'; Script = 'Build-IreeFromSource.ps1'; SourceDir = 'C:\temp\iree-src' }
)

Invoke-SourceBuildChain -Label 'media-tvm' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir -StartAt $ResumeFrom -Until $Until

Complete-SourceBuildChain -Label 'media-tvm' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0