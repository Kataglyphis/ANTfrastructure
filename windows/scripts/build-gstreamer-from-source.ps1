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
    [string[]]$MesonSetupArgs  = @()
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

# Re-import Shared LAST: the nested `Import-Module ...Shared -Force` inside the two
# modules above unloads the top-level Shared import (PS 5.1 module scoping) and
# rebinds it into their private scopes, making Resolve-DirectoryPath & friends
# invisible to this script. Verified in PS 5.1.
Import-Module $sharedPath -Force

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
    $script:mesonExe = $mesonExe

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
    # Locate the actual GStreamer source dir (skip cpython/)
    $gstDirs = @(Get-ChildItem -Path $resolvedSrcDir -Directory -Filter 'gstreamer*')
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
        # Individual lib integrations (opencv, onnx, tflite) are auto-detected
        # via PKG_CONFIG_PATH set in Dockerfile.media-merge-builder. If a
        # dependency is not found, that plugin is simply skipped -- no build failure.
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

    # ---- 8b. verify plugin integrations (non-fatal) ----
    $gstInspect = Join-Path $resolvedInstallDir 'bin\gst-inspect-1.0.exe'
    if (Test-Path $gstInspect) {
        $integrationPlugins = @('opencv', 'onnx', 'tensorfilter', 'libav')
        foreach ($p in $integrationPlugins) {
            try {
                $null = & $gstInspect $p 2>&1
                if ($LASTEXITCODE -eq 0) {
                    log "  [PASS] GStreamer plugin '$p' found"
                } else {
                    log "  [INFO] GStreamer plugin '$p' not available"
                }
            } catch { log "  [INFO] GStreamer plugin '$p' check skipped" }
        }
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
    log "See structured log: $($logContext.StructuredLogFile)"
    exit 2
} finally {
    Stop-StructuredLogging -Context $logContext
}

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0