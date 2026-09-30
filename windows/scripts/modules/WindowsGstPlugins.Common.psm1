#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Merge-lane leaf, never in the media-builder buildmods: see docs/windows-build-resources.md § The Windows cache, tier by tier

Set-StrictMode -Version Latest

# Arch filtering lives in the contract, never at a call site: see docs/windows-build-invariants.md § The mandatory GStreamer plugin set is a contract
$gstTargetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
if (Test-Path $gstTargetArchPath) {
    if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $gstTargetArchPath }
} else {
    throw ("WindowsGstPlugins.Common: required sibling module not found at $gstTargetArchPath. " +
           'Get-RequiredGstPlugin filters the contract per target arch and cannot answer correctly ' +
           'without it. Add WindowsTargetArch.Common.psm1 to the COPY list that carries this module.')
}

function Get-RequiredGstPlugin {
    # The one plugin contract build, smoke test and healthcheck share; Detection says how upstream finds each dependency.
    [CmdletBinding()]
    param([string]$Arch = '')

    $gstArch = Get-WindowsTargetArch -Arch $Arch

    $contract = @(
        [pscustomobject]@{
            Name      = 'libav'
            Provides  = 'avdec_* / avenc_* / avmux_* — the FFmpeg codec bridge'
            Detection = 'pkg-config'
            NeedsPc   = @('libavcodec', 'libavformat', 'libavutil', 'libavfilter')
            Why       = 'the single largest codec surface in the image; without it GStreamer decodes almost nothing this build claims to support'
            # FFmpeg is cross-built for every target this repo supports.
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'opencv'
            Provides  = 'cvtracker, cvdilate, cvlaplace, faceblur, … CV filter elements'
            Detection = 'pkg-config'
            NeedsPc   = @('opencv4')
            Why       = 'the reason OpenCV 5 is built from source into this image at all — the CV pipeline elements are the consumer'
            # OpenCV 5 is cross-built for aarch64 (NEON HAL included).
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'onnx'
            Provides  = 'onnxinference — ONNX Runtime inference inside a pipeline'
            Detection = 'pkg-config'
            NeedsPc   = @('libonnxruntime')
            Why       = 'the inference path of the media stack; ORT is built with CUDA/DML/TensorRT EPs specifically so pipelines can use it'
            # ORT is cross-built for aarch64; the plugin needs only libonnxruntime, not CUDA or DML.
            UnavailableOn = @{}
        },
        # Meson-native subprojects: nothing to pre-flight, so the post-build DLL and gst-inspect gate proves them.
        [pscustomobject]@{
            Name      = 'webrtc'
            Provides  = 'webrtcbin — WebRTC peer connection inside a pipeline (gst-plugins-bad ext/webrtc)'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'gst-plugins-bad:webrtc'
            Why       = 'the only contract plugin that was silently lane-specific; a WebRTC pipeline on the arm64 bundle would have had no webrtcbin'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'nice'
            Provides  = 'nicesrc / nicesink — ICE transport for webrtcbin (libnice gstreamer plugin)'
            Detection = 'meson'
            NeedsPc   = @()
            MesonOption = 'libnice:gstreamer'
            Why       = 'webrtcbin cannot negotiate a connection without the ICE elements'
            UnavailableOn = @{}
        },
        [pscustomobject]@{
            Name      = 'tflite'
            Provides  = 'tfliteinference — TensorFlow Lite / LiteRT inference inside a pipeline'
            Detection = 'compiler'
            NeedsPc   = @()
            # ext/tflite probes the compiler for the pre-rename header, so LiteRT's tflite/ tree needs an alias.
            NeedsHeader = 'tensorflow/lite/c/c_api.h'
            NeedsLib    = @('tensorflowlite_c', 'tensorflow-lite')
            Why         = 'LiteRT is built from source into this image; without this plugin nothing in a GStreamer pipeline can use it'
            # Required on the cross lane too: a cross merge that fails to build it must go red.
            UnavailableOn = @{}
        }
    )

    # A dropped entry is logged: a silent removal is how an image once shipped without plugins.
    $available = @($contract | Where-Object { -not $_.UnavailableOn.ContainsKey($gstArch) })
    foreach ($dropped in @($contract | Where-Object { $_.UnavailableOn.ContainsKey($gstArch) })) {
        Write-Verbose "Get-RequiredGstPlugin: '$($dropped.Name)' is not required on $gstArch - $($dropped.UnavailableOn[$gstArch])"
    }
    return $available
}

function Write-PkgConfigFile {
    # Meson finds OpenCV and ORT only through .pc files they do not ship; forward slashes, as pkg-config escapes on '\'.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,           # module name == <Name>.pc, what dependency() looks up
        [Parameter(Mandatory)][string]$Version,        # must satisfy the consumer's constraint
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$IncludeDir,
        [Parameter(Mandatory)][string]$LibDir,
        [Parameter(Mandatory)][string[]]$Library,      # link names WITHOUT extension
        [Parameter(Mandatory)][string]$PkgConfigDir,
        [string[]]$ExtraCflags = @(),
        # Read only via get_variable('prefix') (opencv's share/opencv4); pass the install root then, default LibDir.
        [string]$Prefix = ''
    )
    $fwd = { param($p) ($p -replace '\\', '/') }
    New-Item -ItemType Directory -Force -Path $PkgConfigDir | Out-Null
    $cflags = @($IncludeDir | Where-Object { $_ } | ForEach-Object { '-I' + (& $fwd $_) }) + $ExtraCflags
    $libs = @('-L' + (& $fwd $LibDir)) + @($Library | ForEach-Object { '-l' + $_ })
    $prefixVal = if ($Prefix) { & $fwd $Prefix } else { & $fwd $LibDir }
    $content = @(
        "prefix=$prefixVal",
        '',
        "Name: $Name",
        "Description: $Description",
        "Version: $Version",
        "Cflags: $($cflags -join ' ')",
        "Libs: $($libs -join ' ')"
    )
    $path = Join-Path $PkgConfigDir "$Name.pc"
    Set-Content -Path $path -Value $content -Encoding ascii
    Write-Host "Wrote pkg-config file: $path (Version $Version, $($Library.Count) lib(s))"
    return $path
}

function Get-LibraryLinkName {
    # Enumerated, not hardcoded: OpenCV's per-module .lib set changes with its module list.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LibDir,
        [string]$Filter = '*.lib',
        # pkg-config has no config concept, and linking both flavours duplicates symbols.
        [switch]$ExcludeDebug
    )
    if (-not (Test-Path $LibDir)) { return @() }
    $libs = @(Get-ChildItem -Path $LibDir -Filter $Filter -File -ErrorAction SilentlyContinue |
            ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
    if ($ExcludeDebug) { $libs = @($libs | Where-Object { $_ -notmatch 'd$' -or $_ -match '\dd?$' }) }
    return @($libs | Sort-Object -Unique)
}

function Assert-PkgConfigModule {
    # Before meson: a missing module otherwise becomes a silently skipped plugin an hour later.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Module,
        [string]$PkgConfigPath = $env:PKG_CONFIG_PATH,
        [string]$Context = 'GStreamer plugin integrations',
        # module -> minimum version the consumer demands; presence alone passes a .pc whose Version is "..".
        [hashtable]$MinimumVersion = @{}
    )
    if ($Module.Count -eq 0) { return }
    $pkgConfig = Get-Command pkg-config -ErrorAction SilentlyContinue
    if (-not $pkgConfig) {
        throw ("pkg-config is not on PATH, so $Context cannot be resolved at all. " +
            'It is installed by Install-ScoopTools.ps1 into the base image; a missing binary here means the base is wrong.')
    }
    $missing = @()
    $tooOld = @()
    foreach ($m in $Module) {
        $global:LASTEXITCODE = 0
        $null = & $pkgConfig.Source '--exists' $m 2>&1
        if ($LASTEXITCODE -ne 0) { $missing += $m; continue }
        $ver = (& $pkgConfig.Source '--modversion' $m 2>&1 | Select-Object -First 1)
        $wanted = $MinimumVersion[$m]
        if ($wanted) {
            # The same comparison meson would make, so a malformed version fails here.
            $global:LASTEXITCODE = 0
            $null = & $pkgConfig.Source "--atleast-version=$wanted" $m 2>&1
            if ($LASTEXITCODE -ne 0) {
                $tooOld += "$m (has '$ver', needs >= $wanted)"
                continue
            }
            Write-Host "  pkg-config OK: $m ($ver >= $wanted)"
        } else {
            Write-Host "  pkg-config OK: $m ($ver)"
        }
    }
    if ($missing.Count -gt 0) {
        throw ("pkg-config cannot resolve: $($missing -join ', ') — $Context WOULD BE SILENTLY SKIPPED by meson. " +
            "PKG_CONFIG_PATH=$PkgConfigPath. Fix the .pc emission (Write-PkgConfigFile) or the install layout; " +
            'do NOT relax the meson feature back to auto — that is what hid this for months.')
    }
    if ($tooOld.Count -gt 0) {
        throw ("pkg-config resolves these, but NOT at the version the consumer demands: $($tooOld -join '; '). " +
            "$Context would be silently skipped by meson. A version like '..' means the producing build never " +
            "determined its own version (FFmpeg does this when configure finds neither a VERSION file nor git " +
            'tags) — fix it at the producing stage, not by relaxing the constraint.')
    }
    $global:LASTEXITCODE = 0
}

Export-ModuleMember -Function Get-RequiredGstPlugin, Write-PkgConfigFile,
    Get-LibraryLinkName, Assert-PkgConfigModule
