# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    rocm image: FFmpeg carries AMD AMF and Vulkan (encoders, hwaccels, filters, hwdevices).
.DESCRIPTION
    Writes one finding per gap; nothing means pass. Listings read FFmpeg's static tables, so no
    GPU is needed. NOT covered: that an AMF or Vulkan session opens (amfrt64.dll and vulkan-1.dll
    come from the host's driver). docs/windows-rocm.md.
#>

Set-StrictMode -Version Latest

# Codec/filter rows are '<flags> <name> ...'; -hwaccels rows are the bare name.
function Test-FfmpegListingRow {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Text = ''
    )
    $row = if ($Kind -eq 'hwaccels') { "(?m)^\s*$Name\s*$" } else { "(?m)^\s*\S+\s+$Name\s" }
    return $Text -match $row
}

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
        foreach ($name in $expected[$kind]) {
            if (-not (Test-FfmpegListingRow -Kind $kind -Name $name -Text ([string]$Listing[$kind]))) { "FFmpeg: ffmpeg -$kind does not list $name" }
        }
    }
    if ([string]$Listing['version'] -notmatch '--enable-amf\b') {
        'FFmpeg: the -version configuration line lacks --enable-amf'
    }
}

# Listed names at n9.0.2 (--enable-vulkan); Build-FfmpegFromSource.ps1 Get-FfmpegVulkanConfigSymbol is the
# configure-side twin. hwdecoders: native decoders whose `-h decoder=` must list the vulkan device.
function Get-FfmpegVulkanExpectation {
    return [ordered]@{
        encoders   = @('h264_vulkan', 'hevc_vulkan', 'av1_vulkan', 'ffv1_vulkan', 'prores_ks_vulkan')
        filters    = @('avgblur_vulkan', 'blackdetect_vulkan', 'blend_vulkan', 'bwdif_vulkan', 'chromaber_vulkan',
            'color_vulkan', 'flip_vulkan', 'gblur_vulkan', 'hflip_vulkan', 'interlace_vulkan', 'nlmeans_vulkan',
            'overlay_vulkan', 'scale_vulkan', 'scdet_vulkan', 'transpose_vulkan', 'v360_vulkan', 'vflip_vulkan', 'xfade_vulkan')
        hwaccels   = @('vulkan')
        hwdecoders = @('av1', 'h264', 'hevc', 'vp9', 'apv', 'dpx', 'ffv1', 'prores', 'prores_raw')
    }
}

# $Listing as for AMF, plus 'decoder=<name>' keys holding `ffmpeg -h decoder=<name>` output.
function Get-FfmpegVulkanListingFinding {
    param([Parameter(Mandatory)][hashtable]$Listing)
    $expected = Get-FfmpegVulkanExpectation
    foreach ($kind in 'encoders', 'filters', 'hwaccels') {
        foreach ($name in $expected[$kind]) {
            if (-not (Test-FfmpegListingRow -Kind $kind -Name $name -Text ([string]$Listing[$kind]))) { "FFmpeg: ffmpeg -$kind does not list $name" }
        }
    }
    # print_codec's hw-config line; HWACCEL_VULKAN(x) is in it only when x_vulkan_hwaccel was built.
    foreach ($decoder in $expected.hwdecoders) {
        if ([string]$Listing["decoder=$decoder"] -notmatch '(?m)^[ \t]*Supported hardware devices:[^\r\n]*[ \t]vulkan(?=[ \t\r]|$)') {
            "FFmpeg: ffmpeg -h decoder=$decoder does not list the vulkan device (no ${decoder}_vulkan hwaccel)"
        }
    }
    if ([string]$Listing['version'] -notmatch '--enable-vulkan\b') {
        'FFmpeg: the -version configuration line lacks --enable-vulkan'
    }
}

# FFmpeg dlopens vulkan-1.dll (hwcontext_vulkan.c); a static import would stop every FFmpeg consumer on a
# host without a loader (Server Core ships none). $ImportsByFile maps a file name to its imported DLL names.
function Get-FfmpegVulkanImportFinding {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$ImportsByFile)
    # hwcontext_vulkan.c is in avutil; without it read, a clean map proves nothing.
    if (-not @($ImportsByFile.Keys | Where-Object { "$_" -match '^avutil-\d+\.dll$' }).Count) {
        'FFmpeg: no avutil-<major>.dll was read for PE imports, so the vulkan-1.dll import check saw nothing'
    }
    foreach ($file in $ImportsByFile.Keys) {
        foreach ($dll in @($ImportsByFile[$file])) {
            if ("$dll" -match '^vulkan-1\.dll$') { "FFmpeg: $file imports $dll; the Vulkan loader must be dlopened, never linked" }
        }
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
    foreach ($decoder in (Get-FfmpegVulkanExpectation).hwdecoders) {
        $listing["decoder=$decoder"] = (& $ffExe -hide_banner -h "decoder=$decoder" 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) { "FFmpeg: ffmpeg -h decoder=$decoder exited $LASTEXITCODE" }
    }
} finally {
    $env:PATH = $savedPath
}
Get-FfmpegAmfListingFinding -Listing $listing
Get-FfmpegVulkanListingFinding -Listing $listing
Get-FfmpegAmfInstallFinding -Prefix (Split-Path $ffBin -Parent)

$archModule = @((Join-Path $PSScriptRoot '..\..\modules\WindowsTargetArch.Common.psm1'),
    (Join-Path $PSScriptRoot '..\modules\WindowsTargetArch.Common.psm1')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $archModule) { return "FFmpeg: WindowsTargetArch.Common.psm1 not found beside $PSScriptRoot, so no PE import was read" }
if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $archModule }
$imports = [ordered]@{}
foreach ($pe in @(Get-ChildItem -LiteralPath $ffBin -File | Where-Object { $_.Extension -in '.dll', '.exe' })) {
    $imports[$pe.Name] = @(Get-PeImportNames -Path $pe.FullName -IncludeDelayLoad)
}
Get-FfmpegVulkanImportFinding -ImportsByFile $imports
