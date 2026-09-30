# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
# The media-core chain, run by four RUNs with their own -ResumeFrom/-Until windows; an edit re-keys all four.

[CmdletBinding()]
param(

    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts',
    # Skip the stages before the named one; BuildKit replays cached RUN vertices, there is no container to resume.
    [string]$ResumeFrom = '',
    # Stop after the named stage; callers pass both bounds, never a stage's position (one 25 GB layer broke ExportLayer).
    [string]$Until = '',
    # Scrub inside this process: `exit 0` ends the RUN's pwsh, and a later layer's scrub cannot shrink this one.
    [switch]$ScrubAfter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference    = 'SilentlyContinue'

Import-Module (Join-Path $ScriptDir 'modules\WindowsSourceBuild.Common.psm1') -Force

# Sequential, each on the prior install; FFmpeg precedes OpenCV, which otherwise downloads its own prebuilt FFmpeg.
$stages = @(
    # Target CPython first: the cross consumers link its python3XY.lib; it reuses the toolchain's tree, never deleted.
    @{ Name = 'Target CPython'; Script = 'Build-TargetCpython.ps1';       SourceDir = 'C:\temp\cpython' }
    @{ Name = 'ONNX Runtime'; Script = 'Build-OnnxFromSource.ps1';       SourceDir = 'C:\temp\onnx-src' }
    @{ Name = 'ONNX GenAI';   Script = 'Build-OnnxGenaiFromSource.ps1'; SourceDir = 'C:\temp\onnx-genai-src' }
    @{ Name = 'FFmpeg';       Script = 'Build-FfmpegFromSource.ps1';     SourceDir = 'C:\temp\ffmpeg-src' }
    @{ Name = 'OpenCV';       Script = 'Build-OpencvFromSource.ps1';     SourceDir = 'C:\temp\opencv-src' }
)

Invoke-SourceBuildChain -Label 'media-core' -Stages $stages -InstallDir $InstallDir -ScriptDir $ScriptDir -StartAt $ResumeFrom -Until $Until

Complete-SourceBuildChain -Label 'media-core' -ScrubAfter:$ScrubAfter

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0