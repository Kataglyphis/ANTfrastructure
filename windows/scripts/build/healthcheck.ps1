#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Comprehensive Docker HEALTHCHECK for Windows developer image.
# Exits 0 if all critical components respond, 1 otherwise.


$ErrorActionPreference = 'Continue'
# StrictMode is safe here: the script stays standalone (no module imports) and every
# variable/property read below is guarded. Parses fine under PS 5.1 as well.
Set-StrictMode -Version Latest
$failed = $false

# CROSS BUNDLE: every check below verifies by EXECUTING a staged binary
# (gst-launch --version, ffmpeg -version, python -c "import cv2", ...). On the
# arm64 lane those binaries are aarch64 while the container is windows/amd64,
# and Windows x64 has no ARM64 emulation - so each one fails for a reason that
# says nothing about the bundle's health.
#
# The Dockerfile's HEALTHCHECK is unconditional (a Dockerfile cannot branch on an
# ARG), and the SAME final Dockerfile produces :winarm64, so without this the
# shipped cross bundle would sit in a permanent `unhealthy` state and retry every
# five minutes forever. Report the truth instead: this image is an ARTIFACT
# BUNDLE, deliberately not runnable, and its verification is the static PE
# machine-type gate that already ran in the merge stage.
#
# WINDOWS_TARGET_ARCH is baked as ENV from the media stage onward, so it is
# present in the final image; anything other than the host arch means cross.
$hcTargetArch = if ($env:WINDOWS_TARGET_ARCH) { $env:WINDOWS_TARGET_ARCH } else { 'amd64' }
if ($hcTargetArch -ne 'amd64') {
    Write-Host "[SKIP] health checks: this is a $hcTargetArch CROSS-COMPILED ARTIFACT BUNDLE, not a runnable image."
    Write-Host '       Every check here verifies by executing a staged binary, and aarch64 code cannot run on this'
    Write-Host '       windows/amd64 container. The bundle is verified statically instead, by verify-target-arch.ps1'
    Write-Host '       (PE machine type over the whole install prefix) in the merge stage. See docs/windows-cross-builds.md.'
    exit 0
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

# Resolve a tool's full path, preferring an explicit <TOOL>_BIN env var (env-driven,
# no hardcoded install roots) and falling back to PATH lookup. Returns $null if neither
# yields a path. Kept local: healthcheck is a self-contained Docker HEALTHCHECK payload
# with no module imports.
function Resolve-ToolPath {
    param(
        [string]$BinEnvVar,
        [Parameter(Mandatory)][string]$ExeName
    )
    $binDir = if ($BinEnvVar) { [Environment]::GetEnvironmentVariable($BinEnvVar) } else { $null }
    if ($binDir) { return (Join-Path $binDir $ExeName) }
    # The PATH miss is a designed outcome: capture first so the .Source read never
    # dereferences $null (which throws under StrictMode).
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
Check "ffmpeg --version" {
    $ffmpegExe = Resolve-ToolPath -BinEnvVar 'FFMPEG_BIN' -ExeName 'ffmpeg.exe'
    if (-not $ffmpegExe) { throw 'ffmpeg.exe not found (FFMPEG_BIN env var unset and ffmpeg.exe not on PATH)' }
    $global:LASTEXITCODE = $null   # see stale-LASTEXITCODE note at the gst-plugin loop below
    $v = & $ffmpegExe -version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg -version failed (exit code [$LASTEXITCODE]): $v" }
    if (-not $v) { throw "ffmpeg not found or failed" }
}

# GStreamer -- prefer $env:GSTREAMER_BIN, fall back to Get-Command.
Check "gst-launch-1.0 --version" {
    $gstLaunch = Resolve-ToolPath -BinEnvVar 'GSTREAMER_BIN' -ExeName 'gst-launch-1.0.exe'
    if (-not $gstLaunch) { throw 'gst-launch-1.0.exe not found (GSTREAMER_BIN env var unset and gst-launch-1.0.exe not on PATH)' }
    $global:LASTEXITCODE = $null   # see stale-LASTEXITCODE note at the gst-plugin loop below
    $v = & $gstLaunch --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gst-launch-1.0 --version failed (exit code [$LASTEXITCODE]): $v" }
    if (-not $v) { throw "gst-launch-1.0 not found or failed" }
}

# Mandatory GStreamer plugin integrations. The set is Get-RequiredGstPlugin's —
# ONE definition shared with the build gate and the smoke test, because these
# three disagreeing is exactly what let opencv/libav go missing from a shipped
# image while this file printed [PASS] for them (2026-07-11). The old list also
# probed `tensorfilter`, an NNStreamer element this repo never builds.
#
# A container healthcheck must stay CHEAP and must not flap a running container,
# so a missing plugin is reported loudly here but does not fail the check — the
# build gate and the smoke test are the enforcing layers. What changed is that
# it can no longer report a plugin as present when it is not.
$gstInspect = Resolve-ToolPath -BinEnvVar 'GSTREAMER_BIN' -ExeName 'gst-inspect-1.0.exe'
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$gstPluginModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
$requiredGstPlugins = if (Test-Path $gstPluginModule) {
    Import-Module $gstPluginModule -Force -DisableNameChecking
    @(Get-RequiredGstPlugin | ForEach-Object { $_.Name })
} else {
    # Older image without the module: fall back to the literal contract rather
    # than silently probing nothing. MUST mirror Get-RequiredGstPlugin — this
    # list re-diverged once already (tflite missing, caught 2026-08-21).
    @('libav', 'opencv', 'onnx', 'tflite')
}
foreach ($gstPlugin in $requiredGstPlugins) {
    # Guard the invoke: with $gstInspect null/missing, `& $null` throws a statement-terminating
    # error while $LASTEXITCODE keeps the PREVIOUS native call's 0 -- printing a false [PASS]
    # for a plugin that was never probed. Reset the exit code before each probe for the same reason.
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

