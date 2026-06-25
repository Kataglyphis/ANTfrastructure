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
        Write-Host "[FAIL] $Label — $_"
        $failed = $true
    }
}

# Python + ONNX Runtime (matches Linux healthcheck)
Check "python + onnxruntime" {
    $result = powershell -NoProfile -Command "python -c 'import onnxruntime; print(onnxruntime.__version__)'" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "onnxruntime import failed: $result" }
}

# FFmpeg
Check "ffmpeg --version" {
    $v = & "C:\runtime\ffmpeg\bin\ffmpeg.exe" -version 2>&1 | Select-Object -First 1
    if (-not $v) { throw "ffmpeg not found or failed" }
}

# GStreamer
Check "gst-launch-1.0 --version" {
    $v = & "C:\runtime\bin\gst-launch-1.0.exe" --version 2>&1 | Select-Object -First 1
    if (-not $v) { throw "gst-launch-1.0 not found or failed" }
}

# GStreamer plugin integrations (non-fatal — auto-detected by meson at build time)
$gstInspect = 'C:\runtime\bin\gst-inspect-1.0.exe'
foreach ($gstPlugin in @('opencv', 'onnx')) {
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
