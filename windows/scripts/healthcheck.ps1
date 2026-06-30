# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Comprehensive Docker HEALTHCHECK for Windows developer image.
# Exits 0 if all critical components respond, 1 otherwise.

$ErrorActionPreference = 'Continue'
$failed = $false

function Check {
    param([string]$Label, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "[PASS] $Label"
    } catch {
        Write-Host "[FAIL] $Label -- $_"
        $failed = $true
    }
}

# ONNX Runtime (source-built C/C++ runtime; ENABLE_PYTHON=OFF so no Python module)
Check "onnxruntime DLL" {
    $onnxRoot = [Environment]::GetEnvironmentVariable('ONNX_ROOT')
    if (-not $onnxRoot) { throw 'ONNX_ROOT env var not set' }
    $dll = Get-ChildItem -Path $onnxRoot -Filter 'onnxruntime*.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) { throw "No onnxruntime*.dll found under $onnxRoot" }
    Write-Host "  Found: $($dll.FullName)"
}

# Python interpreter (source-built CPython 3.14)
Check "python --version" {
    $v = & python --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "python --version failed: $v" }
}

# FFmpeg -- prefer $env:FFMPEG_BIN, fall back to Get-Command (env-driven, no hardcoded C:\runtime\ffmpeg\bin).
Check "ffmpeg --version" {
    $ffmpegBin = $env:FFMPEG_BIN
    $ffmpegExe = if ($ffmpegBin) { Join-Path $ffmpegBin 'ffmpeg.exe' } else { (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue).Source }
    if (-not $ffmpegExe) { throw 'ffmpeg.exe not found (FFMPEG_BIN env var unset and ffmpeg.exe not on PATH)' }
    $v = & $ffmpegExe -version 2>&1 | Select-Object -First 1
    if (-not $v) { throw "ffmpeg not found or failed" }
}

# GStreamer -- prefer $env:GSTREAMER_BIN, fall back to Get-Command.
Check "gst-launch-1.0 --version" {
    $gstBin = $env:GSTREAMER_BIN
    $gstLaunch = if ($gstBin) { Join-Path $gstBin 'gst-launch-1.0.exe' } else { (Get-Command gst-launch-1.0.exe -ErrorAction SilentlyContinue).Source }
    if (-not $gstLaunch) { throw 'gst-launch-1.0.exe not found (GSTREAMER_BIN env var unset and gst-launch-1.0.exe not on PATH)' }
    $v = & $gstLaunch --version 2>&1 | Select-Object -First 1
    if (-not $v) { throw "gst-launch-1.0 not found or failed" }
}

# GStreamer plugin integrations (non-fatal -- auto-detected by meson at build time)
$gstInspect = if ($env:GSTREAMER_BIN) { Join-Path $env:GSTREAMER_BIN 'gst-inspect-1.0.exe' } else { (Get-Command gst-inspect-1.0.exe -ErrorAction SilentlyContinue).Source }
foreach ($gstPlugin in @('opencv', 'tensorfilter', 'libav')) {
    $v = & $gstInspect $gstPlugin 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -eq 0) { Write-Host "[PASS] gst-plugin $gstPlugin found" } `
    else { Write-Host "[SKIP] gst-plugin $gstPlugin not available" }
}

# CMake
Check "cmake --version" {
    $v = & cmake --version 2>&1 | Select-Object -First 1
    if (-not $v) { throw "cmake not found" }
}

# clang-cl
Check "clang-cl --version" {
    $v = & clang-cl --version 2>&1 | Select-Object -First 1
    if (-not $v) { throw "clang-cl not found" }
}

if ($failed) { exit 1 }
exit 0
