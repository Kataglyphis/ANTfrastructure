# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0
#
# Classic-lane merge payload (audit 2026-08-21 #1): GStreamer AND the OpenCV
# GStreamer plugin in ONE run+commit container. The plugin RUN existed only in
# the BK-only `built` target, so the classic lane shipped a merge image whose
# smoke test hard-fails on cv2.CAP_GSTREAMER — discovered by review, one ride
# before it would have burned a ~5 h chain. A wrapper .ps1 (not pwsh -Command
# chaining): the leaf scripts end in `exit 0`, which terminates a -Command
# session but returns cleanly to an &-invoking SCRIPT (verified).

[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir  = 'C:\temp\scripts',
    [string]$LogDir     = 'C:\temp\logs',
    [switch]$ScrubAfter
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

& (Join-Path $ScriptDir 'build-gstreamer-from-source.ps1') -InstallDir $InstallDir -LogDir $LogDir -ScrubAfter:$ScrubAfter
$code = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
if ($code) { throw "GStreamer build failed (exit $code)" }

& (Join-Path $ScriptDir 'build-opencv-gstreamer-plugin.ps1') -InstallDir $InstallDir
$code = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
if ($code) { throw "OpenCV GStreamer plugin build failed (exit $code)" }

Write-Host '=== merge payload (GStreamer + OpenCV gst plugin) completed ==='
# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0
