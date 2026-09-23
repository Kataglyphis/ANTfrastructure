# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm image: FFmpeg carries AMD AMF (encoders, decoders, filters, hwdevice) and its headers.
.DESCRIPTION
    Writes one finding per gap; nothing means pass. Listings read FFmpeg's static tables, so no
    GPU is needed. NOT covered: that an AMF session opens (amfrt64.dll comes from the host's
    AMD driver). docs/windows-builds.md § ROCm layer.
#>

Set-StrictMode -Version Latest

# Listed names at FFmpeg n9.0.2. The capture source is configured as amf_capture but listed
# as vsrc_amf; Build-FfmpegFromSource.ps1 Get-FfmpegAmfConfigSymbol is the configure-side twin.
function Get-FfmpegAmfExpectation {
    return [ordered]@{
        encoders = @('h264_amf', 'hevc_amf', 'av1_amf')
        decoders = @('h264_amf', 'hevc_amf', 'av1_amf', 'vp9_amf')
        filters  = @('vpp_amf', 'sr_amf', 'frc_amf', 'vsrc_amf')
        hwaccels = @('amf')
    }
}

# $Listing maps encoders/decoders/filters/hwaccels/version to ffmpeg's output text.
function Get-FfmpegAmfListingFinding {
    param([Parameter(Mandatory)][hashtable]$Listing)
    $expected = Get-FfmpegAmfExpectation
    foreach ($kind in $expected.Keys) {
        $text = [string]$Listing[$kind]
        foreach ($name in $expected[$kind]) {
            # Codec/filter rows are '<flags> <name> ...'; -hwaccels rows are the bare name.
            $row = if ($kind -eq 'hwaccels') { "(?m)^\s*$name\s*$" } else { "(?m)^\s*\S+\s+$name\s" }
            if ($text -notmatch $row) { "FFmpeg: ffmpeg -$kind does not list $name" }
        }
    }
    if ([string]$Listing['version'] -notmatch '--enable-amf\b') {
        'FFmpeg: the -version configuration line lacks --enable-amf'
    }
}

# Headers beside the installed hwcontext_amf.h; the driver's AMF runtime must never be shipped.
function Get-FfmpegAmfInstallFinding {
    param([Parameter(Mandatory)][string]$Prefix)
    $version = Join-Path $Prefix 'include\AMF\core\Version.h'
    if (-not (Test-Path -LiteralPath $version -PathType Leaf)) {
        "FFmpeg: $version is missing (libavutil/hwcontext_amf.h includes <AMF/core/Factory.h>)"
    }
    foreach ($dll in @(Get-ChildItem -LiteralPath $Prefix -Recurse -File -Filter 'amfrt*.dll' -ErrorAction SilentlyContinue)) {
        "FFmpeg: $($dll.FullName) ships AMD's proprietary AMF runtime; it must come from the host driver"
    }
}

$ffBin = $env:FFMPEG_BIN ?? 'C:\runtime\ffmpeg\bin'
$ffExe = [System.IO.Path]::Combine($ffBin, 'ffmpeg.exe')
if (-not [System.IO.File]::Exists($ffExe)) { return "FFmpeg: $ffExe not found" }
$listing = @{}
$savedPath = $env:PATH
try {
    # Launched the way Test-Container.ps1 section 18 launches it: its bin dir first on PATH.
    $env:PATH = "$ffBin;$env:PATH"
    foreach ($kind in 'encoders', 'decoders', 'filters', 'hwaccels', 'version') {
        $listing[$kind] = (& $ffExe -hide_banner "-$kind" 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) { "FFmpeg: ffmpeg -$kind exited $LASTEXITCODE" }
    }
} finally {
    $env:PATH = $savedPath
}
Get-FfmpegAmfListingFinding -Listing $listing
Get-FfmpegAmfInstallFinding -Prefix (Split-Path $ffBin -Parent)
