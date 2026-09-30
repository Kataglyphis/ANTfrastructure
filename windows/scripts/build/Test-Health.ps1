#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Docker HEALTHCHECK for the Windows image: exits 1 when a critical component fails.


$ErrorActionPreference = 'Continue'
# StrictMode is safe: every variable and property read below is guarded.
Set-StrictMode -Version Latest
$failed = $false

# A cross bundle runs only the host-tool checks: its aarch64 payload cannot execute here and Test-TargetArch.ps1 verifies it.
$hcTargetArch = if ($env:WINDOWS_TARGET_ARCH) { $env:WINDOWS_TARGET_ARCH } else { 'amd64' }
$hcCross = $hcTargetArch -ne 'amd64'
if ($hcCross) {
    Write-Host "[NOTE] $hcTargetArch cross bundle: host-tool checks run; payload-execution checks are skipped"
    Write-Host '       (aarch64 code cannot run on this windows/amd64 container; the payload is verified statically'
    Write-Host '       by Test-TargetArch.ps1 in the merge stage - see docs/windows-cross-builds.md).'
}

function Check {
    param([string]$Label, [scriptblock]$Block)
    try {
        & $Block
        Write-Host "[PASS] $Label"
    } catch {
        Write-Host "[FAIL] $Label -- $_"
        $script:failed = $true
    }
}

# <TOOL>_BIN first, then PATH; kept local so the healthcheck needs no shared module.
function Resolve-ToolPath {
    param(
        [string]$BinEnvVar,
        [Parameter(Mandatory)][string]$ExeName
    )
    $binDir = if ($BinEnvVar) { [Environment]::GetEnvironmentVariable($BinEnvVar) } else { $null }
    if ($binDir) { return (Join-Path $binDir $ExeName) }
    # Captured first: .Source on a PATH miss would throw under StrictMode.
    $cmd = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
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
if ($hcCross) {
    Write-Host '[SKIP] ffmpeg --version (payload execution; ffmpeg.exe is aarch64 on this lane)'
} else {
    Check "ffmpeg --version" {
        $ffmpegExe = Resolve-ToolPath -BinEnvVar 'FFMPEG_BIN' -ExeName 'ffmpeg.exe'
        if (-not $ffmpegExe) { throw 'ffmpeg.exe not found (FFMPEG_BIN env var unset and ffmpeg.exe not on PATH)' }
        $global:LASTEXITCODE = $null   # see stale-LASTEXITCODE note at the gst-plugin loop below
        $v = & $ffmpegExe -version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg -version failed (exit code [$LASTEXITCODE]): $v" }
        if (-not $v) { throw "ffmpeg not found or failed" }
    }
}

# GStreamer -- prefer $env:GSTREAMER_BIN, fall back to Get-Command.
if ($hcCross) {
    Write-Host '[SKIP] gst-launch-1.0 --version (payload execution; gst-launch-1.0.exe is aarch64 on this lane)'
} else {
    Check "gst-launch-1.0 --version" {
        $gstLaunch = Resolve-ToolPath -BinEnvVar 'GSTREAMER_BIN' -ExeName 'gst-launch-1.0.exe'
        if (-not $gstLaunch) { throw 'gst-launch-1.0.exe not found (GSTREAMER_BIN env var unset and gst-launch-1.0.exe not on PATH)' }
        $global:LASTEXITCODE = $null   # see stale-LASTEXITCODE note at the gst-plugin loop below
        $v = & $gstLaunch --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "gst-launch-1.0 --version failed (exit code [$LASTEXITCODE]): $v" }
        if (-not $v) { throw "gst-launch-1.0 not found or failed" }
    }
}

# One plugin contract shared with the build gate and smoke test; a miss is reported but must not flap a running container.
$gstInspect = Resolve-ToolPath -BinEnvVar 'GSTREAMER_BIN' -ExeName 'gst-inspect-1.0.exe'
# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$gstPluginModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
# -Arch is required: a bare call probes amd64's plugin set; an image without the module gets a SKIP, not a wrong contract.
$requiredGstPlugins = if (Test-Path $gstPluginModule) {
    Import-Module $gstPluginModule -Force -DisableNameChecking
    @(Get-RequiredGstPlugin -Arch $hcTargetArch | ForEach-Object { $_.Name })
} else {
    Write-Host '[SKIP] gst-plugin contract not probed (WindowsGstPlugins.Common.psm1 absent in this image)'
    @()
}
if ($hcCross -and $requiredGstPlugins.Count -gt 0) {
    Write-Host "[SKIP] gst-plugin probes for: $($requiredGstPlugins -join ', ') (payload execution; gst-inspect-1.0.exe is aarch64 on this lane)"
    $requiredGstPlugins = @()
}
foreach ($gstPlugin in $requiredGstPlugins) {
    # Stale LASTEXITCODE: `& $null` throws but keeps the previous call's 0, a false [PASS]; hence the guard and the reset.
    if (-not $gstInspect -or -not (Test-Path $gstInspect)) {
        Write-Host "[SKIP] gst-plugin $gstPlugin not probed (gst-inspect-1.0.exe not found)"
        continue
    }
    $global:LASTEXITCODE = 1
    $null = & $gstInspect $gstPlugin 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host "[PASS] gst-plugin $gstPlugin found" }
    else { Write-Host "[FAIL] gst-plugin $gstPlugin MISSING - this image is incomplete (mandatory integration)" }
}

# CMake
Check "cmake --version" {
    $global:LASTEXITCODE = $null   # see stale-LASTEXITCODE note at the gst-plugin loop above
    $v = & cmake --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "cmake --version failed (exit code [$LASTEXITCODE]): $v" }
    if (-not $v) { throw "cmake not found" }
}

# clang-cl
Check "clang-cl --version" {
    $global:LASTEXITCODE = $null   # see stale-LASTEXITCODE note at the gst-plugin loop above
    $v = & clang-cl --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "clang-cl --version failed (exit code [$LASTEXITCODE]): $v" }
    if (-not $v) { throw "clang-cl not found" }
}

if ($failed) { exit 1 }
exit 0

