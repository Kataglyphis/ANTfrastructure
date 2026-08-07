# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The mandatory-GStreamer-plugin contract and the pkg-config plumbing that makes
# it satisfiable.
#
# WHY THIS IS ITS OWN MODULE — CACHE BOUNDARY, NOT TASTE.
# Dockerfile.media-builder's `buildmods` stage mounts exactly five modules into
# ALL SIX media compile RUNs (ONNX ~75 min, OpenCV, FFmpeg, GenAI, litert, tvm),
# and Dockerfile.media-merge-builder mounts those five plus Installer.Common.
# Editing any module inside the FIVE therefore re-runs the entire media chain.
# This code is used by exactly one consumer — the GStreamer build in the merge
# stage — plus the smoke test and healthcheck in the final image, so putting it
# in Shared.psm1 or SourceBuild.Common.psm1 (both in the compile closure) would
# have cost hours of rebuild for code those layers never call. It lives here,
# mounted only by the merge builder, so a change to the plugin contract costs
# the GStreamer layer and nothing else.
#
# Keep that property: do NOT add this module to Dockerfile.media-builder's
# buildmods stage, and do not move these functions into a module that is.

Set-StrictMode -Version Latest

function Get-RequiredGstPlugin {
    # THE contract for which GStreamer plugin integrations must exist in a
    # shipped image. One definition, three consumers: the GStreamer build gates
    # on it, the smoke test asserts it, the healthcheck reports it. Those three
    # previously disagreed, and the cost was 2026-07-11: `gst-inspect-1.0
    # opencv|libav` exited -1 in the published winamd64 image while the
    # healthcheck printed [PASS] for them. Nothing ever failed; the image simply
    # shipped without the plugins.
    #
    # Each entry carries WHY it is mandatory and what supplies it, because a bare
    # name gives a future maintainer no way to judge a removal request.
    #
    # Detection tells the pre-flight HOW upstream looks the dependency up, which
    # is not uniform: opencv/onnx/libav go through pkg-config, tflite does not
    # use pkg-config at all (cc.find_library + cc.has_header). Checking the wrong
    # way would either pass vacuously or demand a .pc that nothing consumes.
    #
    # NOT in this list, deliberately:
    #   tensorfilter — an NNStreamer element, NOT a GStreamer plugin. This repo
    #     does not build NNStreamer, so it was never going to exist; it appeared
    #     in the old probe lists purely because the lying healthcheck "found" it.
    #     Requiring it would make every build fail forever. If NNStreamer is
    #     wanted, that is a new source-build stage, not a plugin gate entry.
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{
            Name      = 'libav'
            Provides  = 'avdec_* / avenc_* / avmux_* — the FFmpeg codec bridge'
            Detection = 'pkg-config'
            NeedsPc   = @('libavcodec', 'libavformat', 'libavutil', 'libavfilter')
            Why       = 'the single largest codec surface in the image; without it GStreamer decodes almost nothing this build claims to support'
        },
        [pscustomobject]@{
            Name      = 'opencv'
            Provides  = 'cvtracker, cvdilate, cvlaplace, faceblur, … CV filter elements'
            Detection = 'pkg-config'
            NeedsPc   = @('opencv4')
            Why       = 'the reason OpenCV 5 is built from source into this image at all — the CV pipeline elements are the consumer'
        },
        [pscustomobject]@{
            Name      = 'onnx'
            Provides  = 'onnxinference — ONNX Runtime inference inside a pipeline'
            Detection = 'pkg-config'
            NeedsPc   = @('libonnxruntime')
            Why       = 'the inference path of the media stack; ORT is built with CUDA/DML/TensorRT EPs specifically so pipelines can use it'
        },
        [pscustomobject]@{
            Name      = 'tflite'
            Provides  = 'tfliteinference — TensorFlow Lite / LiteRT inference inside a pipeline'
            Detection = 'compiler'
            NeedsPc   = @()
            # gst-plugins-bad ext/tflite probes the COMPILER, not pkg-config:
            #   cc.find_library('tensorflowlite_c')  (fallback: 'tensorflow-lite')
            #   cc.has_function('TfLiteInterpreterCreate', ...)
            #   cc.has_header('tensorflow/lite/c/c_api.h', ...)
            # The header path is the pre-rename TensorFlow one. LiteRT v2.x
            # stages its headers under tflite/ (Google renamed TFLite → LiteRT),
            # so an alias tree is required — see the pre-flight in
            # build-gstreamer-from-source.ps1.
            NeedsHeader = 'tensorflow/lite/c/c_api.h'
            NeedsLib    = @('tensorflowlite_c', 'tensorflow-lite')
            Why         = 'LiteRT is built from source into this image; without this plugin nothing in a GStreamer pipeline can use it'
        }
    )
}

function Write-PkgConfigFile {
    # Author a pkg-config .pc file for a CMake-installed library that ships none.
    #
    # WHY THIS EXISTS: GStreamer's meson finds most optional integrations ONLY
    # through pkg-config. Two of this image's headline libraries provide no .pc
    # file at all — OpenCV's CMake install emits pkg-config only when
    # OPENCV_GENERATE_PKGCONFIG is on (off by default, and its name would be
    # opencv5.pc, which `dependency('opencv4')` does not look for), and ONNX
    # Runtime ships none on any platform. So gst-plugins-bad silently skipped the
    # opencv and onnx plugins, and the image shipped without them for months.
    #
    # Paths are emitted with FORWARD slashes: pkg-config treats a backslash as an
    # escape character, so a Windows path written natively silently mangles into
    # an unusable -I/-L flag.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,           # module name == <Name>.pc, what dependency() looks up
        [Parameter(Mandatory)][string]$Version,        # must satisfy the consumer's constraint
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$IncludeDir,
        [Parameter(Mandatory)][string]$LibDir,
        [Parameter(Mandatory)][string[]]$Library,      # link names WITHOUT extension
        [Parameter(Mandatory)][string]$PkgConfigDir,
        [string[]]$ExtraCflags = @()
    )
    $fwd = { param($p) ($p -replace '\\', '/') }
    New-Item -ItemType Directory -Force -Path $PkgConfigDir | Out-Null
    $cflags = @($IncludeDir | Where-Object { $_ } | ForEach-Object { '-I' + (& $fwd $_) }) + $ExtraCflags
    $libs = @('-L' + (& $fwd $LibDir)) + @($Library | ForEach-Object { '-l' + $_ })
    $content = @(
        "prefix=$(& $fwd $LibDir)",
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
    # The -l names for every import library in a directory, optionally filtered.
    # Enumerated rather than hardcoded: OpenCV with BUILD_opencv_world=OFF emits
    # one .lib per module and the SET changes with the enabled module list, so a
    # hand-maintained list would rot into a link error on the next OpenCV bump.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LibDir,
        [string]$Filter = '*.lib',
        # Drop debug-suffixed libs (…d.lib) — pkg-config has no config concept
        # and linking both flavours is a duplicate-symbol trap.
        [switch]$ExcludeDebug
    )
    if (-not (Test-Path $LibDir)) { return @() }
    $libs = @(Get-ChildItem -Path $LibDir -Filter $Filter -File -ErrorAction SilentlyContinue |
            ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
    if ($ExcludeDebug) { $libs = @($libs | Where-Object { $_ -notmatch 'd$' -or $_ -match '\dd?$' }) }
    return @($libs | Sort-Object -Unique)
}

function Assert-PkgConfigModule {
    # Fail-fast gate: every named module must resolve through pkg-config BEFORE
    # meson runs. A missing one otherwise surfaces as a silently-skipped plugin
    # after a ~60-minute configure+compile, which is how the opencv/onnx/libav
    # gap survived unnoticed. Seconds here, an hour there.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Module,
        [string]$PkgConfigPath = $env:PKG_CONFIG_PATH,
        [string]$Context = 'GStreamer plugin integrations',
        # module -> minimum version the CONSUMER demands. Checking presence alone
        # is not enough: FFmpeg shipped seven .pc files whose `Version:` field was
        # literally ".." (its configure found neither a VERSION file nor git
        # tags), so `--exists` passed while every consumer constraint failed.
        # That defect survived months precisely because the files were there.
        [hashtable]$MinimumVersion = @{}
    )
    if ($Module.Count -eq 0) { return }
    $pkgConfig = Get-Command pkg-config -ErrorAction SilentlyContinue
    if (-not $pkgConfig) {
        throw ("pkg-config is not on PATH, so $Context cannot be resolved at all. " +
            'It is installed by setup-scoop-tools.ps1 into the base image; a missing binary here means the base is wrong.')
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
            # --atleast-version does the comparison pkg-config itself would do
            # for the consumer, so a malformed version ('..') fails here rather
            # than surfacing an hour later as a silently skipped meson feature.
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
