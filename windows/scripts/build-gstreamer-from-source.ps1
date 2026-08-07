# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

<#
.SYNOPSIS
    Build GStreamer from source on Windows using Meson with clang-cl.

.DESCRIPTION
    Alternative to the binary BITS installer. Clones the GStreamer monorepo
    and builds everything from source via Meson wraps. Uses clang-cl as the
    compiler (msvc-compatible ABI) with Visual Studio SDK paths.

.PARAMETER GstVersion
    Git tag or branch to build (default: 1.29.2).

.PARAMETER InstallDir
    Target install prefix (default: empty -> resolves to C:\runtime via Initialize-SourceBuildEnvironment).

.PARAMETER SourceDir
    Temporary directory for the git clone (default: C:\temp\gst-source).

.PARAMETER BuildDir
    Meson build directory (default: C:\temp\gst-builddir).

.PARAMETER LogDir
    Log output directory (default: C:\temp\logs).

.PARAMETER GitRepo
    GStreamer monorepo URL (default: https://github.com/gstreamer/gstreamer.git).

.PARAMETER KeepBuildArtifacts
    If set, do not remove source and build directories after install.

.PARAMETER MesonSetupArgs
    Additional arguments passed through to meson setup.
#>
param(
    [string]$GstVersion        = '',
    [string]$InstallDir        = '',
    [string]$SourceDir         = 'C:\temp\gst-source',
    [string]$BuildDir          = 'C:\temp\gst-builddir',
    [string]$LogDir            = 'C:\temp\logs',
    [string]$GitRepo           = 'https://github.com/gstreamer/gstreamer.git',
    [switch]$KeepBuildArtifacts,
    # Scrub package/temp scratch INSIDE this process. This script IS its own
    # layer in the BK lane (Dockerfile.media-merge-builder --target built), and
    # layers are additive: a scrub in any later layer cannot shrink this one.
    [switch]$ScrubAfter,
    [string[]]$MesonSetupArgs  = @(),
    # Escape hatch for the mandatory-plugin contract (Get-RequiredGstPlugin).
    # The gate turns a silently-missing plugin into a build failure, which is the
    # whole point — but while iterating on ONE plugin's toolchain problem you may
    # need an image out of the door. Deliberate exception, never routine: an
    # image built with this flag is by definition not shippable.
    [switch]$SkipPluginGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- module import (logging + build helpers + shared utilities) ----
# NOTE: imports MUST precede any module-function call — Initialize-SourceBuildEnvironment
# below used to be invoked before this block and died with CommandNotFoundException.
$sharedPath = Join-Path $PSScriptRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedPath)) { throw "Required module not found: $sharedPath" }
Import-Module $sharedPath -Force

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

$sourceBuildModule = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Test-Path $sourceBuildModule)) { throw "Required module not found: $sourceBuildModule" }
Import-Module $sourceBuildModule -Force
# (No Shared re-import needed anymore: every nested import — including
# load-versions.ps1's, the last -Force holdout that killed this script twice
# on 2026-08-05 — is guarded/un-Forced now, so the top-level import above
# survives the whole preamble. History in AGENTS.md § import invariant.)

$InstallDir = Initialize-SourceBuildEnvironment -InstallDir $InstallDir

# ---- logging ----
$logContext = New-StructuredLogContext -LogDir $LogDir -Prefix 'gst-source-build'
Start-StructuredLogging -Context $logContext

function log($text) {
    Write-StructuredLogEntry -Context $logContext -Text $text
}

# Extracts a downloaded .tar.gz/.tar.bz2 subproject archive into a scratch dir
# beside $Target (7z two-pass: decompress, then untar the largest inner .tar),
# then moves the single top-level source dir onto $Target. Returns $true when a
# directory was moved. Shared by the wrap pre-extraction loop and the libffi
# force-download below, which used to carry two copies of this body.
function Expand-SubprojectArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Target
    )
    $extractDir = Join-Path (Split-Path -Parent $Target) ('_ext_' + (Split-Path -Leaf $Target))
    New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    cmd.exe /c "7z.exe x ""$Archive"" -o""$extractDir"" -y >nul 2>&1"
    $tarFile = @(Get-ChildItem -Path $extractDir -Filter '*.tar' | Sort-Object Length -Descending | Select-Object -First 1)
    if ($tarFile) {
        cmd.exe /c "7z.exe x ""$($tarFile[0].FullName)"" -o""$extractDir"" -y >nul 2>&1"
        Remove-Item $tarFile[0].FullName -Force -ErrorAction SilentlyContinue
    }
    $extracted = @(Get-ChildItem -Path $extractDir -Directory)
    $moved = $false
    if ($extracted.Count -ge 1) {
        Move-Item -Path $extracted[0].FullName -Destination $Target -Force
        $moved = $true
    }
    Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    return $moved
}

# Load canonical versions from linux/scripts/01-core/versions.env if available
# (its Shared import is guarded since the 2026-08-05 root fix — it can no
# longer unload the top-level import from module scope).
Import-CanonicalVersions -ScriptRoot $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($GstVersion)) {
    $GstVersion = Get-SourceBuildVersion -EnvironmentVariables @('GSTREAMER_VERSION') -DefaultValue '1.29.2'
}

try {
    log "START - GStreamer source build"
    log "Version:   $GstVersion"
    log "Install:   $InstallDir"
    log "SourceDir: $SourceDir"
    log "BuildDir:  $BuildDir"
    log "LogDir:    $LogDir"
    log "GitRepo:   $GitRepo"

    # ---- 1. resolve directories ----
    $resolvedInstallDir = Resolve-DirectoryPath -Path $InstallDir
    $resolvedSrcDir     = Resolve-DirectoryPath -Path $SourceDir
    $resolvedBuildDir   = Resolve-DirectoryPath -Path $BuildDir
    $resolvedLogDir     = Resolve-DirectoryPath -Path $LogDir

    # ---- 2. install Meson via source-built CPython ----
    # The toolchain layer built CPython 3.14 at $env:TEMP_DIR\cpython\PCbuild\amd64\python.exe.
    # pip is bootstrapped here if missing (no ordering assumption on other build
    # scripts — the media build runs in parallel branches).
    log 'Using source-built CPython from toolchain layer...'
    $py = Initialize-ToolchainPythonEnvironment
    $pyExe = $py.Exe
    if (-not (Test-Path $pyExe)) { throw "Source-built Python not found at $pyExe" }
    log "Using Python: $pyExe"
    Install-CpythonPip -Python $py

    log 'Installing Meson via pip...'
    $pipLog = Join-Path $resolvedLogDir 'pip-install.log'
    & cmd.exe /c """$pyExe"" -m pip install meson > ""$pipLog"" 2>&1"
    Get-Content $pipLog | ForEach-Object { if ($_) { log $_ } }

    # Find meson.exe: ask Python where console scripts land. The in-tree PCbuild
    # layout (sys.prefix = the source root) puts them at C:\temp\cpython\Scripts,
    # NOT next to python.exe — pip's install warning confirms that location.
    $pythonScripts = (cmd.exe /c """$pyExe"" -c ""import sysconfig; print(sysconfig.get_path('scripts'))""" | Select-Object -First 1)
    if ($pythonScripts) { $pythonScripts = "$pythonScripts".Trim() }
    if (-not $pythonScripts -or -not (Test-Path (Join-Path $pythonScripts 'meson.exe'))) {
        $pythonScripts = @(
            (Join-Path (Split-Path $pyExe -Parent) 'Scripts'),
            (Join-Path $env:TEMP_DIR 'cpython\Scripts')
        ) | Where-Object { Test-Path (Join-Path $_ 'meson.exe') } | Select-Object -First 1
    }
    if (-not $pythonScripts) { throw 'meson.exe not found after pip install' }
    $mesonExe = Join-Path $pythonScripts 'meson.exe'
    $env:PATH = "$pythonScripts;$env:PATH"
    $mesonVer = & $mesonExe --version 2>&1 | Select-Object -First 1
    log "Meson version: $mesonVer"

    # ---- 3. set clang-cl as the compiler ----
    log 'Setting CC/CXX to clang-cl...'
    $env:CC  = 'clang-cl'
    $env:CXX = 'clang-cl'
    # Verify clang-cl is on PATH
    $clangCheck = Get-Command 'clang-cl' -ErrorAction SilentlyContinue
    if (-not $clangCheck) {
        throw 'clang-cl not found on PATH. Ensure LLVM/Clang is installed.'
    }
    log "clang-cl found at: $($clangCheck.Source)"

    # sccache: meson honors a space-separated launcher in CC/CXX (unlike the
    # cmake builders, which use CMAKE_*_COMPILER_LAUNCHER). Until 2026-08-04
    # this build ran completely uncached (~30 min hot) — the merge builder
    # simply never wired the endpoint through. Same gate as everywhere else:
    # remote backend only; a container-local cache would die with the layer.
    if ((Test-SccacheRemoteConfigured) -and (Get-Command sccache.exe -ErrorAction SilentlyContinue)) {
        if (-not $env:SCCACHE_MAX_JOBS) { $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString() }
        $env:CC  = 'sccache clang-cl'
        $env:CXX = 'sccache clang-cl'
        log "sccache enabled for meson (remote backend, max $env:SCCACHE_MAX_JOBS jobs)"
    } else {
        log 'sccache disabled (no remote backend configured or sccache.exe missing)'
    }

    # Prevent git from hanging/interactive prompts during meson subproject downloads.
    # GIT_SSL_NO_VERIFY is intentionally scoped to THIS ephemeral build container's meson
    # subproject git fetches (not a runtime/production trust boundary); the shared
    # Invoke-GitClone deliberately does NOT force it for ordinary clones.
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_SSL_NO_VERIFY = '1'

    # ---- 4. download GStreamer source tarball ----
    $gstSrcDir = Join-Path $resolvedSrcDir "gstreamer-$GstVersion"
    if (Test-Path $gstSrcDir) {
        log "Removing existing source directory: $gstSrcDir"
        Remove-Item -Path $gstSrcDir -Recurse -Force
    }

    $tarballUrl = "https://github.com/gstreamer/gstreamer/archive/refs/tags/$GstVersion.tar.gz"
    $tarballPath = Join-Path $resolvedLogDir "gstreamer-$GstVersion.tar.gz"
    log "Downloading GStreamer source tarball from $tarballUrl ..."
    # Hardened retry/backoff + redirect-following (GitHub /archive/ -> codeload) via the shared
    # helper -- replaces bare `curl --retry 3`, which no other source download uses. Throws on
    # failure. (The subproject-wrap + libffi fetches below stay on cmd/curl: they need bulk
    # cmd.exe extraction and are a different, per-item flow.)
    Invoke-DownloadWithRetry -Url $tarballUrl -DestinationPath $tarballPath -Description "GStreamer $GstVersion source tarball"
    log 'Tarball downloaded. Extracting...'

    # 7z on Windows handles .tar.gz in two passes: gzip then tar
    & 7z x $tarballPath -o"$resolvedSrcDir" -y 2>&1 | Where-Object { $_ } | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'Failed to decompress GStreamer source tarball' }
    $tarFile = Join-Path $resolvedSrcDir "gstreamer-$GstVersion.tar"
    if (Test-Path $tarFile) {
        log 'Extracting tar archive...'
        & 7z x $tarFile -o"$resolvedSrcDir" -y 2>&1 | Where-Object { $_ } | ForEach-Object { if ($_) { log $_ } }
        Remove-Item $tarFile -Force
    }
    Remove-Item $tarballPath -Force
    # Locate the actual GStreamer source dir (skip cpython/). Require a
    # meson.build at the candidate's root: with -KeepBuildArtifacts a stale
    # sibling like gstreamer-old\ can survive here, and a bare name-prefix
    # match would let it win over the freshly extracted tree.
    $gstDirs = @(Get-ChildItem -Path $resolvedSrcDir -Directory -Filter 'gstreamer*' |
        Where-Object { Test-Path (Join-Path $_.FullName 'meson.build') })
    if ($gstDirs.Count -ge 1) {
        $gstSrcDir = $gstDirs[0].FullName
        log "Source root: $gstSrcDir"
    } elseif ( -not (Test-Path (Join-Path $gstSrcDir 'meson.build'))) {
        throw "Could not find GStreamer source with meson.build in $resolvedSrcDir"
    }
    log 'Extraction complete.'

    # git-init the extracted tarball so Invoke-SourcePatch takes its .git fast-path (git
    # apply); the helper shields git's stderr via cmd.exe (else PS 5.1 EAP=Stop throws).
    Initialize-ExtractedGitRepo -Path $gstSrcDir

    # ---- 5. pre-extract all wrap-git subprojects via tarball ----
    $subprojDir = Join-Path $gstSrcDir 'subprojects'
    Get-ChildItem -Path $subprojDir -Filter '*.wrap' | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $fname = $_.Name
        if ($content -match '^\[wrap-git\]') {
            $url = if ($content -match '(?ms)url\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
            $rev = if ($content -match '(?ms)revision\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
            $dir = if ($content -match '(?ms)directory\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
            $target = Join-Path $subprojDir $dir
            if (Test-Path $target) { Remove-Item -Path $_.FullName -Force; return }
            # Build tarball URL
            if ($url -match 'github\.com') {
                $base = $url -replace '\.git$', ''
                $tarballUrl = "$base/archive/$rev.tar.gz"
            } else {
                $tarballUrl = "$url/-/archive/$rev/$dir-$rev.tar.bz2"
            }
            $tmp = Join-Path $resolvedLogDir "$dir-$rev.tar"
            $tmpFile = "$tmp.gz"; if ($tarballUrl -match '\.bz2$') { $tmpFile = "$tmp.bz2" }
            log "Pre-extracting $fname..."
            cmd.exe /c "curl.exe -fsSL --retry 3 ""$tarballUrl"" -o ""$tmpFile"" 2>nul"
            if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpFile)) {
                if (Expand-SubprojectArchive -Archive $tmpFile -Target $target) {
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    log "Pre-extracted $fname to $target"
                }
            } else {
                log "WARNING: Failed to download $fname, features may be disabled"
            }
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
    # Force-download libffi via PowerShell's & (bypasses cmd.exe path issues)
    $libffiTarget = Join-Path $subprojDir 'libffi'
    if (-not (Test-Path $libffiTarget)) {
        log 'Force-downloading libffi...'
        $libffiVer = if ($env:LIBFFI_MESON_VERSION) { $env:LIBFFI_MESON_VERSION } else { '3.2.9999.4' }
        $libffiUrl = "https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/meson-$libffiVer/libffi-meson-$libffiVer.tar.bz2"
        $libffiTmp = Join-Path $resolvedLogDir 'libffi.tar.bz2'
        & curl.exe -fsSL --retry 3 $libffiUrl -o $libffiTmp 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $libffiTmp)) {
            if (Expand-SubprojectArchive -Archive $libffiTmp -Target $libffiTarget) {
                log "Force-pre-extracted libffi"
            }
        } else {
            log "WARNING: Force-download of libffi failed (exit $LASTEXITCODE)"
        }
        Remove-Item -Path $libffiTmp -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $subprojDir 'libffi.wrap') -Force -ErrorAction SilentlyContinue
    }

    # Recursively delete ALL [wrap-git] wraps across the entire source tree.
    # Any subproject can bundle its own wraps (e.g. GLib bundles libffi.wrap,
    # gst-plugins-base may bundle gl-headers.wrap). Git clone fails inside
    # Windows containers, so we remove them all to prevent FATAL ERRORs from
    # Meson.  Pre-extracted wraps (both top-level and bundled) are handled
    # above; anything remaining will fail if git-cloned.
    Get-ChildItem -Path $gstSrcDir -Filter '*.wrap' -Recurse | Where-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        $c -match '^\[wrap-git\]'
    } | ForEach-Object {
        $p = $_.FullName
        Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
        $rel = $p.Substring($gstSrcDir.Length + 1)
        log "Removed bundled [wrap-git]: $rel"
    }

    # ---- 5b. create stub unistd.h + fixed intrin.h for platform compat ----
    $stubDir = Join-Path $env:TEMP_DIR 'includes'
    if (-not (Test-Path $stubDir)) { New-Item -Path $stubDir -ItemType Directory -Force | Out-Null }
    # unistd.h: flex/bison generated files + POSIX compat on Windows
    $stubFile = Join-Path $stubDir 'unistd.h'
    if (-not (Test-Path $stubFile)) {
        '#pragma once
int _isatty(int);
#define isatty _isatty
#define fileno _fileno' | Out-File -FilePath $stubFile -Encoding ASCII
        log "Created stub unistd.h at $stubFile"
    }
    # (LLVM 22 mmintrin.h bug: cairo Win32 backend disabled via -Dcairo:win32=disabled)
    # (Cairo Win32 stubs handled in retry loop after meson downloads cairo)

    # ---- 5c. detect CUDA (available from Dockerfile.nvidia layer) ----
    # Get-GpuEnvironment sets $env:CUDA_PATH / CUDA_HOME and prepends CUDA bin to PATH
    # -- all this script needs on top is logging and the GpuType for downstream logic.
    $gpuEnv = Get-GpuEnvironment
    if ($gpuEnv.GpuType -eq 'nvidia' -and $gpuEnv.CudaRoot) {
        log "CUDA detected at: $($gpuEnv.CudaRoot)"
    } else {
        log 'CUDA not detected -- nvcodec/cuda plugins will be auto-detected by Meson'
    }

    # ---- 5d. find compiler-rt for lld-link (__udivti3, etc.) ----
    # Resolve the LLVM install dir via clang-cl on PATH (single source of truth) rather
    # than hardcoding the scoop app dir layout -- survives a LLVM/scoop install relocation.
    $clangClCmd = Get-Command 'clang-cl' -ErrorAction SilentlyContinue
    $llvmRoot = if ($clangClCmd) { Split-Path (Split-Path $clangClCmd.Source) } else { Join-Path $env:USERPROFILE 'scoop\apps\llvm\current' }
    $compilerRtLib = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter '*builtins*.lib' -ErrorAction SilentlyContinue | Select-Object -First 1)
    $rtFullPath = ''
    if ($compilerRtLib) {
        $rtFullPath = $compilerRtLib.FullName -replace '\\', '/'
        log "Found compiler-rt: $rtFullPath"
    }

    # ---- 5e. Windows SDK GUID import libs for clang-cl/lld-link ----
    # MSVC's link.exe auto-pulls COM/DirectShow/MediaFoundation/KernelStreaming
    # GUIDs (IID_*/CLSID_*) from the default uuid.lib; clang-cl's lld-link does
    # NOT resolve all of them the same way, which is what previously forced
    # wasapi off and would also break mediafoundation. Naming these SDK import
    # libs explicitly in the link args resolves the GUID symbols. They are on
    # the --vsenv lib path; unreferenced symbols are not pulled, so this is
    # harmless for plugins that don't need them (/FORCE:MULTIPLE covers dups).
    $guidLibs = @(
        'uuid.lib', 'mfuuid.lib', 'strmiids.lib', 'ksuser.lib', 'dxguid.lib',
        'dmoguids.lib', 'wmcodecdspuuid.lib', 'mfplat.lib', 'mf.lib', 'mfreadwrite.lib'
    )
    $linkArgElems = ((@('/FORCE:MULTIPLE', $rtFullPath) + $guidLibs) |
        Where-Object { $_ } | ForEach-Object { "'$_'" }) -join ','
    log "Link args: [$linkArgElems]"

    # ---- 5f. patch gst-plugins-bad mediafoundation for clang-cl ----
    # The mediafoundation plugin's WinRT-app-partition detection lacks the
    # `cxx.get_id() == 'msvc'` guard that its required GstWinRt helper library
    # DOES have (gst-libs/gst/winrt/meson.build: `if cxx.get_id() != 'msvc' ->
    # subdir_done()`). So under clang-cl, GstWinRt is never built, yet
    # mediafoundation still detects winapi_app (the WinRT test compiles fine
    # with the desktop SDK) and demands gstwinrt_dep -> hard error when the
    # plugin is enabled explicitly. Gate winapi_app on msvc too, matching the
    # library's own guard: under clang-cl only the desktop path (mfvideosrc, the
    # webcam source) builds; the UWP app path is msvc-only and not needed here.
    $mfMeson = Join-Path $gstSrcDir 'subprojects\gst-plugins-bad\sys\mediafoundation\meson.build'
    [void](Edit-SourceFile -Path $mfMeson -Marker "if runtimeobject_lib\.found\(\) and cxx\.get_id\(\) == 'msvc'" `
            -Description 'mediafoundation meson.build: gate winapi_app detection on msvc (clang-cl builds desktop path only)' `
            -WarnMessage 'mediafoundation winapi_app guard not found; mediafoundation=enabled may fail if GstWinRt is unavailable under clang-cl' `
            -Transform {
            param($mfContent)
            [regex]::Replace($mfContent, "if runtimeobject_lib\.found\(\)(\s*\r?\n)", "if runtimeobject_lib.found() and cxx.get_id() == 'msvc'`$1", 1)
        })

    # ---- 5c. MANDATORY PLUGIN PRE-FLIGHT ─────────────────────────────────────
    # Everything below exists because of the 2026-07-11 finding: `gst-inspect-1.0
    # opencv|libav` exited -1 in the SHIPPED winamd64 image. Nothing failed —
    # meson auto-detected the integrations, found nothing, and skipped them, and
    # the healthcheck then printed [PASS] for plugins that were not there.
    #
    # Three independent root causes, one per plugin:
    #
    #  opencv — gst-plugins-bad resolves `dependency('opencv4', '>= 4.0.0')`.
    #    OpenCV's CMake install emits NO pkg-config file by default, and even
    #    with OPENCV_GENERATE_PKGCONFIG it would be named opencv5.pc, which that
    #    lookup does not consider. PKG_CONFIG_PATH pointed at a directory that
    #    never existed. Fixed by emitting an opencv4.pc that describes the
    #    OpenCV 5 install (upstream dropped the old `< 4.x` upper bound, so the
    #    version itself is acceptable — verified against 1.29.2 sources).
    #
    #  onnx — gst-plugins-bad resolves `dependency('libonnxruntime', '>= 1.16.1')`
    #    and calls subdir_done() when missing. ONNX Runtime ships no .pc on any
    #    platform. Fixed by emitting one.
    #
    #  libav — the real trap. gstreamer ships subprojects/FFmpeg.wrap, which
    #    PROVIDES libavcodec/libavformat/libavutil/libavfilter pinned to
    #    FFmpeg 7.1.1. Combined with -Dwrap_mode=forcefallback below, meson is
    #    FORCED to use that wrap and never looks at pkg-config — so this build
    #    was trying to fetch and build a second, older FFmpeg instead of using
    #    the n9.0 it had just built, and gst-libav was dropped when that failed.
    #    Even succeeding would have been wrong: gst-libav would link a different
    #    FFmpeg than the image's own ffmpeg.exe and libav* DLLs. Fixed by
    #    neutralising the wrap so the four modules resolve from OUR install.
    #
    # The .pc files are authored HERE rather than by the OpenCV/ONNX builds on
    # purpose: those are the two most expensive layers in the chain (~30 and ~75
    # minutes), and emitting a text file is not worth invalidating them. This
    # stage consumes the canonical env contract (OPENCV_ROOT / ONNX_ROOT / …)
    # that the merge image already defines, so nothing is hardcoded.
    $requiredPlugins = @(Get-RequiredGstPlugin)
    if ($SkipPluginGate) {
        log 'WARNING: -SkipPluginGate — the mandatory GStreamer plugin contract is DISABLED for this build.'
        log "WARNING: the resulting image is NOT shippable. Required set: $(($requiredPlugins | ForEach-Object { $_.Name }) -join ', ')"
    } else {
        log '--- mandatory plugin pre-flight ---'

        # opencv4.pc — describes the OpenCV 5 install under $OPENCV_ROOT.
        $ocvRoot = if ($env:OPENCV_ROOT) { $env:OPENCV_ROOT } else { Join-Path $resolvedInstallDir 'lib\opencv5' }
        $ocvLib = if ($env:OPENCV_LIB) { $env:OPENCV_LIB } else { Join-Path $ocvRoot 'x64\vc18\lib' }
        # Header root = the directory CONTAINING opencv2/, found rather than
        # assumed: OpenCV's Windows layout has moved between majors (include\
        # vs include\opencv4\) and guessing wrong yields a .pc that resolves but
        # cannot compile.
        $ocvHeader = Get-ChildItem -Path $ocvRoot -Recurse -Filter 'opencv.hpp' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.DirectoryName -match 'opencv2$' } | Select-Object -First 1
        if (-not $ocvHeader) { throw "opencv2/opencv.hpp not found under $ocvRoot — cannot describe the OpenCV install to pkg-config." }
        $ocvInclude = Split-Path (Split-Path $ocvHeader.FullName -Parent) -Parent
        $ocvLibs = @(Get-LibraryLinkName -LibDir $ocvLib)
        if ($ocvLibs.Count -eq 0) { throw "no import libraries found in $ocvLib — the OpenCV install is incomplete." }
        # Version: satisfies '>= 4.0.0' while naming the real OpenCV 5 release.
        $ocvVersion = if ($env:OPENCV_SOURCE_VERSION -match '^(\d+)') { "$($Matches[1]).0.0" } else { '5.0.0' }
        [void](Write-PkgConfigFile -Name 'opencv4' -Version $ocvVersion `
                -Description 'OpenCV 5 (opencv4-named alias so gst-plugins-bad can resolve it)' `
                -IncludeDir @($ocvInclude) -LibDir $ocvLib -Library $ocvLibs `
                -PkgConfigDir (Join-Path $ocvLib 'pkgconfig'))

        # libonnxruntime.pc — ORT ships none on any platform.
        $ortRoot = if ($env:ONNX_ROOT) { $env:ONNX_ROOT } else { Join-Path $resolvedInstallDir 'lib\onnxruntime-source' }
        $ortLib = Join-Path $ortRoot 'lib'
        $ortInclude = Join-Path $ortRoot 'include'
        if (-not (Test-Path (Join-Path $ortLib 'onnxruntime.lib'))) { throw "onnxruntime.lib not found in $ortLib — cannot describe ONNX Runtime to pkg-config." }
        $ortVersion = ([string]$env:ONNX_VERSION).TrimStart('v')
        if (-not $ortVersion) { $ortVersion = '1.28.0' }
        # ORT's headers sit at include\ AND include\onnxruntime\core\session on
        # some layouts; both are handed over so the plugin's #include resolves
        # either way.
        $ortIncludes = @($ortInclude, (Join-Path $ortInclude 'onnxruntime'),
            (Join-Path $ortInclude 'onnxruntime\core\session')) | Where-Object { Test-Path $_ }
        [void](Write-PkgConfigFile -Name 'libonnxruntime' -Version $ortVersion `
                -Description 'ONNX Runtime (source build; ships no pkg-config file of its own)' `
                -IncludeDir $ortIncludes -LibDir $ortLib -Library @('onnxruntime') `
                -PkgConfigDir (Join-Path $ortLib 'pkgconfig'))

        # Make the two new pkgconfig dirs visible to meson for THIS process.
        $newPcDirs = @((Join-Path $ocvLib 'pkgconfig'), (Join-Path $ortLib 'pkgconfig'))
        $env:PKG_CONFIG_PATH = (@($newPcDirs + ($env:PKG_CONFIG_PATH -split ';' | Where-Object { $_ })) | Select-Object -Unique) -join ';'
        log "PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH"

        # Neutralise FFmpeg.wrap so libav* resolve from OUR FFmpeg install rather
        # than the wrap's pinned 7.1.1 (see the header comment above).
        $ffmpegWrap = Join-Path $gstSrcDir 'subprojects\FFmpeg.wrap'
        if (Test-Path $ffmpegWrap) {
            Move-Item -Path $ffmpegWrap -Destination "$ffmpegWrap.disabled" -Force
            log 'Disabled subprojects/FFmpeg.wrap — gst-libav must link the FFmpeg this image ships, not a wrap-pinned 7.1.1.'
        }

        # Everything the required set needs must resolve NOW, not after an hour.
        Assert-PkgConfigModule -Module @($requiredPlugins | ForEach-Object { $_.NeedsPc } | Select-Object -Unique) `
            -Context ('mandatory GStreamer plugins: ' + (($requiredPlugins | ForEach-Object { $_.Name }) -join ', '))
        log '--- pre-flight OK: every mandatory plugin dependency resolves ---'
    }

    # ---- 6. meson setup (retry with wrap cleanup) ----
    $setupArgs = @(
        'setup', '--vsenv',
        $resolvedBuildDir, $gstSrcDir,
        "--prefix=$resolvedInstallDir",
        '-Dwrap_mode=forcefallback',
        '-Ddoc=disabled',
        '-Dgtk_doc=disabled',
        '-Dintrospection=disabled',
        '-Dtests=disabled',
        '-Dexamples=disabled',
        # Enable all GStreamer plugin sets.
        # Individual lib integrations used to be left at meson's `auto`, which
        # means "skip silently if the dependency is missing" — that is precisely
        # how opencv/onnx/libav went missing from a SHIPPED image without one
        # line of red in the log (2026-07-11). The mandatory set is now `enabled`,
        # so a missing dependency fails meson setup in SECONDS instead of
        # producing a quietly incomplete image an hour later. The pre-flight
        # above has already proven the .pc files resolve, so reaching a failure
        # here means a genuine toolchain problem worth seeing.
        '-Dgpl=enabled',
        '-Dbase=enabled',
        '-Dgood=enabled',
        '-Dugly=enabled',
        '-Dbad=enabled',
        '-Dges=enabled',
        '-Drtsp_server=enabled',
        '-Dtools=enabled',
        # Provide stub unistd.h for Windows CRT compatibility
        "-Dc_args=-I$env:TEMP_DIR\includes -FIio.h -Disatty=_isatty -Dfileno=_fileno -Dclose=_close -Dwrite=_write -DSTDOUT_FILENO=1 -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types",
        # ── Maximum feature set (see also $guidLibs above for the GUID fix) ──
        # mediafoundation ENABLED: modern Windows webcam capture (mfvideosrc +
        # MF device provider) required by the Rust capture path. Needs the GUID
        # import libs added to the link args below.
        '-Dgst-plugins-bad:mediafoundation=enabled',
        # wasapi (v1) stays DISABLED: it links against Core Audio interface
        # GUIDs (IID_IAudioClient, IID_IMMEndpoint, IID_IAudioRenderClient,
        # IID_IAudioCaptureClient, IID_IAudioClock, ...) that live in NO SDK
        # import lib -- upstream expects them instantiated via source-level
        # INITGUID, which doesn't happen under clang-cl, so lld-link reports
        # them undefined even with the $guidLibs above. NOT a feature loss:
        # wasapi2 (the modern replacement, built by default and present in the
        # image) provides WASAPI capture/render. Only the deprecated v1 is off.
        '-Dgst-plugins-bad:wasapi=disabled',
        # svtjpegxs stays DISABLED: its SVT-JPEG-XS codec subproject does not
        # compile under clang-cl (Mct.c: "conflicting types" / "too many
        # arguments" -- the local access() clash was only the first of several
        # incompatibilities; remapping access did not make the rest build). A
        # niche JPEG-XS codec; not worth patching the vendored SVT source.
        '-Dgst-plugins-bad:svtjpegxs=disabled',
        # ── Genuinely-hard blockers under clang-cl: kept OFF (documented) ──
        # cairo:win32 crashes clang-cl (LLVM 22 mmintrin.h __builtin_shufflevector);
        # -Dcairo:win32=disabled intentionally fails cairo at meson setup.
        '-Dcairo:win32=disabled',
        '-Dopus:intrinsics=disabled',
        # nvcodec: gstnvdecoder.cpp uses GST_CAPS_FEATURE_MEMORY_D3D11_MEMORY,
        # undeclared under clang-cl (gst-d3d11 headers not found). GPU-specific;
        # CUDA gst-lib is auto-detected separately. Kept off pending a headers fix.
        '-Dgst-plugins-bad:nvcodec=disabled',
        # dots-viewer: Rust subproject; cargo crates.io index fetch fails in the
        # offline container. Dev tool, not a media feature.
        '-Dgst-devtools:dots-viewer=disabled',
        # /FORCE:MULTIPLE for libffi dups; compiler-rt for lld-link (__udivti3
        # etc.); GUID import libs (see $guidLibs) for MF/WASAPI/DShow/KS symbols.
        "-Dc_link_args=[$linkArgElems]",
        "-Dcpp_link_args=[$linkArgElems]"
    ) + $(
        # The mandatory contract, expressed to meson. Held back behind the same
        # switch as the pre-flight so -SkipPluginGate really does mean "let the
        # build proceed without them" rather than failing at configure anyway.
        if ($SkipPluginGate) { @() } else {
            @(
                '-Dlibav=enabled',
                '-Dgst-plugins-bad:opencv=enabled',
                '-Dgst-plugins-bad:onnx=enabled'
            )
        }
    ) + $MesonSetupArgs

    $setupArgsString = "meson $($setupArgs -join ' ')"
    $mesonSucceeded = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        log "Running meson setup (attempt $attempt/2)..."
        log $setupArgsString
        # Redirect ONLY stdout to file to avoid PowerShell's ErrorRecord trap
        # from native stderr when $ErrorActionPreference='Stop'.
        $outFile = Join-Path $resolvedLogDir "meson-setup-$attempt-out.txt"
        & $mesonExe @setupArgs > $outFile
        $mesonExitCode = $LASTEXITCODE
        if (Test-Path $outFile) { Get-Content $outFile | ForEach-Object { if ($_) { log $_ } } }
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        if ($mesonExitCode -eq 0) { $mesonSucceeded = $true; break }

        if ($attempt -eq 1) {
            # Delete known-problematic [wrap-git] wraps inside downloaded subprojects
            Get-ChildItem -Path $gstSrcDir -Filter 'gi-docgen.wrap' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $gstSrcDir -Filter 'gtk-doc.wrap' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
            if (Test-Path $resolvedBuildDir) { Remove-Item -Path $resolvedBuildDir -Recurse -Force }
        }
    }
    if (-not $mesonSucceeded) { throw 'meson setup failed after 2 attempts' }
    log 'meson setup completed.'

    # Inline patch (kept inline, NOT a .patch file): the webrtc-audio-processing
    # wrap version floats with the GStreamer release, so a static .patch would rot.
    # Its AVX2/SSE2 kernels index SIMD vectors via MSVC's union members
    # (x.m256_f32[i]); clang-cl's __m256 is a native vector type without members
    # ("member reference base type '__m256' is not a structure or union") but
    # supports direct subscripting x[i], which is what this substitution produces.
    $wrtcDir = Get-ChildItem -Path (Join-Path $gstSrcDir 'subprojects') -Directory -Filter 'webrtc-audio-processing-*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wrtcDir) {
        $simdMemberPatterns = @(
            '\.m256_f32\[', '\.m256d_f64\[', '\.m256i_(?:i|u)(?:8|16|32|64)\[',
            '\.m128_f32\[', '\.m128d_f64\[', '\.m128i_(?:i|u)(?:8|16|32|64)\['
        )
        Get-ChildItem -Path $wrtcDir.FullName -Recurse -Include '*.cc', '*.h' | ForEach-Object {
            $content = [System.IO.File]::ReadAllText($_.FullName)
            $patched = $content
            foreach ($p in $simdMemberPatterns) { $patched = $patched -replace $p, '[' }
            if ($patched -ne $content) {
                [System.IO.File]::WriteAllText($_.FullName, $patched)
                log "Patched MSVC SIMD member access for clang-cl: $($_.Name)"
            }
        }
    }

    # Inline patch (kept inline, NOT a .patch file): FFMPEG_VERSION=master floats,
    # and FFmpeg master removed the V308/V408/V410 raw packed-video codec IDs that
    # gst-libav 1.29.x still lists in its "no quasi codecs" EXCLUSION conditions.
    # Excluding codecs that no longer exist is moot — drop those comparisons
    # (R210 sharing the V410 line still exists and is kept).
    foreach ($avFile in @('gstavvidenc.c', 'gstavviddec.c')) {
        [void](Edit-SourceFile -Path (Join-Path $gstSrcDir "subprojects\gst-libav\ext\libav\$avFile") `
                -Description "${avFile}: remove V308/V408/V410 exclusions (codec IDs dropped by FFmpeg)" `
                -WarnMessage "${avFile} present but the V308/V408/V410 exclusion lines did not match; if the pinned FFmpeg has dropped these codec IDs, gst-libav will fail with 'undeclared identifier AV_CODEC_ID_V308'." `
                -Transform {
                param($avContent)
                $avContent = $avContent -replace '(?m)^\s*in_plugin->id == AV_CODEC_ID_V[34]08 \|\|\r?\n', ''
                $avContent -replace 'in_plugin->id == AV_CODEC_ID_V410 \|\| ', ''
            })
    }

    # ---- 6. compile (retry once to work around LLVM 22 mmintrin.h bug in Cairo) ----
    $compileSucceeded = $false
    for ($cAttempt = 1; $cAttempt -le 2; $cAttempt++) {
        log "Compiling GStreamer (attempt $cAttempt/2, may take 30-60 min)..."
        & $mesonExe compile -C $resolvedBuildDir 2>&1 | ForEach-Object { if ($_) { log $_ } }
        if ($LASTEXITCODE -eq 0) { $compileSucceeded = $true; break }
        if ($cAttempt -eq 1) {
            log 'Compile attempt 1 failed; patching _commit conflict in GES and retrying...'
            # Reactive by design -- only rename GES's `_commit` when a compile actually failed. clang-cl's
            # -FIio.h force-include declares the CRT `_commit`, which can collide with ges-validate.c's own
            # `_commit` validate-action. In gstreamer 1.29.2 there is NO collision (ges-validate.c compiles
            # clean on attempt 1), so this path stays DORMANT -- applying the rename unconditionally would
            # needlessly redefine `_commit` where there is nothing to fix. The reviewable .patch below
            # (patches/gstreamer/001-ges-commit-rename.patch, kept git-appliable) fires only if a future
            # clang / io.h / gstreamer combination reintroduces the clash. NOT dead code: dormant insurance.
            $gesValidate = Join-Path $gstSrcDir 'subprojects/gst-editing-services/ges/ges-validate.c'
            $gesPatch = Join-Path $PSScriptRoot 'patches\gstreamer\001-ges-commit-rename.patch'
            if ((Test-Path $gesValidate) -and (Test-Path $gesPatch)) {
                try {
                    Invoke-SourcePatch -PatchFile $gesPatch -SourceDir $gstSrcDir -IgnoreWhitespace
                    log "Patched: ges-validate.c (_commit -> ges__commit)"
                } catch {
                    # Fallback to the previous inline form if the .patch context has drifted.
                    log "GES .patch did not apply cleanly, falling back to inline #define"
                    [void](Add-FileBlockOnce -Path $gesValidate -Prepend -Marker '#define _commit ges__commit' `
                            -Content "#define _commit ges__commit`n" `
                            -Description 'ges-validate.c: _commit -> ges__commit (inline fallback)')
                }
            }
        }
    }
    if (-not $compileSucceeded) { throw 'meson compile failed after 2 attempts' }
    log 'Compilation complete.'

    # ---- 7. install ----
    log 'Installing GStreamer...'
    & $mesonExe install -C $resolvedBuildDir 2>&1 | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'meson install failed' }
    log 'Installation complete.'

    # ---- 8. verify ----
    $gstLaunch = Join-Path $resolvedInstallDir 'bin\gst-launch-1.0.exe'
    if (Test-Path $gstLaunch) {
        log "Verification OK: $gstLaunch"
    } else {
        log "WARNING: gst-launch-1.0.exe not found at expected path: $gstLaunch"
        log 'Build may have completed but binaries may be elsewhere. Check logs.'
    }

    # ---- 8b. MANDATORY PLUGIN GATE (fatal) ───────────────────────────────────
    # This block used to log "[INFO] plugin not available" and carry on, which
    # is how a shipped image ended up without opencv and libav. The repo rule is
    # explicit — "a missing stage artifact is a THROW, not a warning" (AGENTS.md)
    # — and a plugin the media stack is built around is a stage artifact.
    #
    # It is a SEPARATE check from the meson feature flags on purpose: `enabled`
    # only guarantees the dependency was found at configure time. A plugin can
    # still fail to build, or build and fail to load at runtime (a missing
    # sidecar DLL is the classic Windows case), and gst-inspect is the only
    # thing that proves what the image can actually USE.
    $gstInspect = Join-Path $resolvedInstallDir 'bin\gst-inspect-1.0.exe'
    if (-not (Test-Path $gstInspect)) {
        throw "gst-inspect-1.0.exe missing at $gstInspect — cannot verify the mandatory plugin set."
    }
    $missingPlugins = @()
    foreach ($plugin in @(Get-RequiredGstPlugin)) {
        $global:LASTEXITCODE = 0
        $null = & $gstInspect $plugin.Name 2>&1
        if ($LASTEXITCODE -eq 0) {
            log "  [PASS] mandatory GStreamer plugin '$($plugin.Name)' present ($($plugin.Provides))"
        } else {
            log "  [FAIL] mandatory GStreamer plugin '$($plugin.Name)' MISSING — $($plugin.Why)"
            $missingPlugins += $plugin
        }
    }
    $global:LASTEXITCODE = 0
    if ($missingPlugins.Count -gt 0) {
        $detail = ($missingPlugins | ForEach-Object { "$($_.Name) (needs pkg-config: $($_.NeedsPc -join ', '))" }) -join '; '
        if ($SkipPluginGate) {
            log "WARNING: mandatory plugins missing but -SkipPluginGate was passed: $detail"
            log 'WARNING: this image is NOT shippable.'
        } else {
            throw ("mandatory GStreamer plugin(s) MISSING from the install: $detail. " +
                'The build reached this point, so the dependency resolved at configure time and the plugin ' +
                "failed to compile or to load — check meson-setup/compile logs in $resolvedLogDir for that plugin's " +
                'subdir. Do NOT "fix" this by relaxing the meson feature back to auto; that is what shipped an ' +
                'image without opencv and libav for months. Deliberate exception: -SkipPluginGate.')
        }
    } else {
        log "All $(@(Get-RequiredGstPlugin).Count) mandatory GStreamer plugins verified present."
    }

    # ---- 9. cleanup ----
    if (-not $KeepBuildArtifacts.IsPresent -and $env:KEEP_BUILD_ARTIFACTS -ne '1') {
        log 'Cleaning up source and build directories...'
        Remove-SourceBuildTree -Path @($gstSrcDir, $resolvedBuildDir)
    }

    # This script is not chain-run (no Invoke-SourceBuildChain tail), so dump
    # the sccache counters itself — they die with the container otherwise.
    Write-SccacheStats -Label 'gstreamer'

    log 'END - GStreamer source build completed successfully.'

} catch {
    log "FATAL ERROR: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        log "Inner: $($_.Exception.InnerException.Message)"
    }
    # Position + stack: without these a 60-min meson run died with a bare
    # message and no line number to start from.
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        log "Position: $($_.InvocationInfo.PositionMessage)"
    }
    if ($_.ScriptStackTrace) {
        log "ScriptStackTrace: $($_.ScriptStackTrace)"
    }
    log "See structured log: $($logContext.StructuredLogFile)"
    exit 2
} finally {
    Stop-StructuredLogging -Context $logContext
}

if ($ScrubAfter) { Clear-BuildScratch }

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0