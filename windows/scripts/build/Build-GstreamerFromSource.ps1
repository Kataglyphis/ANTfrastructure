# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

<#
.SYNOPSIS
    Build GStreamer from source on Windows using Meson with clang-cl.

.DESCRIPTION
    Builds the GStreamer monorepo from source via Meson wraps: downloads the
    GitHub /archive/ release tarball, extracts it with 7z, and compiles with
    clang-cl (msvc-compatible ABI) against Visual Studio SDK paths.

.PARAMETER GstVersion
    Git tag or branch to build (default: 1.29.2).

.PARAMETER InstallDir
    Target install prefix (default: empty -> resolves to C:\runtime via Initialize-SourceBuildEnvironment).

.PARAMETER SourceDir
    Temporary directory for the extracted source tarball (default: C:\temp\gst-source).

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
    # Scrub package/temp scratch INSIDE this process: this script IS its own layer
    # in the BK lane, and layers are additive.
    [switch]$ScrubAfter,
    [string[]]$MesonSetupArgs  = @(),
    # Escape hatch for the mandatory-plugin contract (Get-RequiredGstPlugin).
    # Deliberate exception, never routine: an image built with this flag is by
    # definition not shippable.
    [switch]$SkipPluginGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- module import (logging + build helpers + shared utilities) ----
# Imports MUST precede any module-function call. #108: shared assets sit beside
# this script in the flat container mount and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedPath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedPath)) { throw "Required module not found: $sharedPath" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($sharedPath)))) { Import-Module $sharedPath }

$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

# The mandatory-plugin contract + pkg-config emitter. A separate module ON PURPOSE:
# it is mounted by the merge builder only, so editing the contract cannot
# invalidate the six media compile RUNs (see Dockerfile.media-merge-builder).
$gstPluginModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
if (-not (Test-Path $gstPluginModule)) { throw "Required module not found: $gstPluginModule" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($gstPluginModule)))) { Import-Module $gstPluginModule }

$sourceBuildModule = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Test-Path $sourceBuildModule)) { throw "Required module not found: $sourceBuildModule" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($sourceBuildModule)))) { Import-Module $sourceBuildModule }

# Merge-lane leaf modules (#134), mounted by Dockerfile.media-merge-builder ONLY,
# so editing them costs the GStreamer layer and nothing else. Do NOT fold them
# into WindowsSourceBuild.Common -- that one is in the closure of all 11 media RUNs.
foreach ($leafModule in @('WindowsMeson.Common.psm1', 'WindowsRustToolchain.Common.psm1')) {
    $leafPath = Join-Path $scriptAssetRoot "modules\$leafModule"
    if (-not (Test-Path $leafPath)) { throw "Required module not found: $leafPath" }
    if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($leafPath)))) { Import-Module $leafPath }
}

# Target-arch state, resolved ONCE: five decisions far apart in this file depend on
# it (builtins selection, plugin contract, tflite pre-flight, meson options, the
# post-install verification), and resolving late left the earliest arch-blind.
$script:GstTargetArch = Get-WindowsTargetArch
$script:GstCross      = Test-WindowsCrossTarget -Arch $script:GstTargetArch

$InstallDir = Initialize-SourceBuildEnvironment -InstallDir $InstallDir

# ---- logging ----
$logContext = New-StructuredLogContext -LogDir $LogDir -Prefix 'gst-source-build'
Start-StructuredLogging -Context $logContext

function log($text) {
    Write-StructuredLogEntry -Context $logContext -Text $text
}

# Load canonical versions from linux/scripts/01-core/versions.env if available.
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

    Switch-BuildPhase '1. resolve directories'
    # ---- 1. resolve directories ----
    $resolvedInstallDir = Resolve-DirectoryPath -Path $InstallDir
    $resolvedSrcDir     = Resolve-DirectoryPath -Path $SourceDir
    $resolvedBuildDir   = Resolve-DirectoryPath -Path $BuildDir
    $resolvedLogDir     = Resolve-DirectoryPath -Path $LogDir

    Switch-BuildPhase '2. Meson via source CPython'
    # ---- 2. install Meson via source-built CPython ----
    # pip is bootstrapped here if missing: the media branches build in parallel,
    # so no ordering assumption on the other build scripts is safe.
    log 'Using source-built CPython from toolchain layer...'
    $py = Initialize-ToolchainPythonEnvironment
    $pyExe = $py.Exe
    if (-not (Test-Path $pyExe)) { throw "Source-built Python not found at $pyExe" }
    log "Using Python: $pyExe"
    Install-CpythonPip -Python $py

    log 'Installing Meson via pip...'
    $pipLog = Join-Path $resolvedLogDir 'pip-install.log'
    & cmd.exe /c """$pyExe"" -m pip install meson > ""$pipLog"" 2>&1"
    $pipExit = $LASTEXITCODE
    Get-Content $pipLog | ForEach-Object { if ($_) { log $_ } }
    # A pip failure used to surface eight lines later as the misleading
    # 'meson.exe not found after pip install'.
    if ($pipExit -ne 0) { throw "pip install meson failed (exit $pipExit) -- see $pipLog (logged above)" }

    # Ask Python where console scripts land: the in-tree PCbuild layout puts them
    # under the source root, NOT next to python.exe.
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

    # meson 1.12.0 build-only subproject fixes (glib(build) poisoning the host glib
    # -> libnice -> webrtc/nice gone). Located through the interpreter module itself
    # so a relocated site-packages cannot silently skip it; no-op on amd64.
    $mesonInterp = (cmd.exe /c """$pyExe"" -c ""import mesonbuild.interpreter.interpreter as m; print(m.__file__)""" | Select-Object -First 1)
    if ($mesonInterp) { $mesonInterp = "$mesonInterp".Trim() }
    if (-not $mesonInterp -or -not (Test-Path $mesonInterp)) {
        throw "mesonbuild.interpreter.interpreter is not importable from $pyExe (got '$mesonInterp') -- cannot apply the build-subproject fixes"
    }
    [void](Invoke-MesonBuildSubprojectPatch -InterpreterPath $mesonInterp)

    Switch-BuildPhase '3. clang-cl toolchain + sccache'
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

    # meson honors a space-separated launcher in CC/CXX (unlike the cmake builders).
    # Same gate as everywhere else: remote backend only, since a container-local
    # cache would die with the layer. #128: this script runs OUTSIDE
    # Invoke-SourceBuildChain, so it makes the chain's fresh-server call itself.
    Start-SccacheServerSession
    if ((Test-SccacheRemoteConfigured) -and (Get-Command sccache.exe -ErrorAction SilentlyContinue)) {
        if (-not $env:SCCACHE_MAX_JOBS) { $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString() }
        $env:CC  = 'sccache clang-cl'
        $env:CXX = 'sccache clang-cl'
        log "sccache enabled for meson (remote backend, max $env:SCCACHE_MAX_JOBS jobs)"
    } else {
        log 'sccache disabled (no remote backend configured or sccache.exe missing)'
    }

    # GIT_SSL_NO_VERIFY is scoped to THIS ephemeral build container's meson
    # subproject fetches, not a runtime trust boundary; Invoke-GitClone never
    # forces it for ordinary clones.
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_SSL_NO_VERIFY = '1'
    # meson fetches [wrap-file] subprojects with urllib, which verifies TLS against
    # a CA store this source-built CPython does not ship -- every wrap then burns
    # its full retry budget. Same trust-boundary reasoning as GIT_SSL_NO_VERIFY.
    $env:PYTHONHTTPSVERIFY = '0'

    # ---- 3b. EARLY fan-in fast-fail (backlog #66) ----------------------------
    # Presence-only mirror of the full "must resolve NOW" pre-flight further down,
    # which cannot move because it authors .pc files: a missing media fan-in fails
    # in seconds instead of after the tarball, ~20 wrap downloads and five patch
    # loops. Version floors and .pc semantics remain the full gate's job.
    if (-not $SkipPluginGate) {
        $earlyOcvRoot = if ($env:OPENCV_ROOT) { $env:OPENCV_ROOT } else { Join-Path $resolvedInstallDir 'lib\opencv5' }
        $earlyOrtRoot = if ($env:ONNX_ROOT) { $env:ONNX_ROOT } else { Join-Path $resolvedInstallDir 'lib\onnxruntime-source' }
        $earlyLitertRoot = if ($env:LITERT_ROOT) { $env:LITERT_ROOT } else { Join-Path $resolvedInstallDir 'lib\litert' }
        $earlyChecks = @(
            @{ Path = $earlyOcvRoot;    What = 'OpenCV install (gst-plugins-bad ext/opencv)' }
            @{ Path = $earlyOrtRoot;    What = 'ONNX Runtime install (gst onnx plugin)' }
            @{ Path = $earlyLitertRoot; What = 'LiteRT install (gst tflite plugin)' }
        )
        $earlyMissing = @($earlyChecks | Where-Object { -not (Test-Path $_.Path) })
        if ($earlyMissing) {
            throw ("GStreamer pre-flight (early, #66): media fan-in missing BEFORE any download was spent: " +
                (($earlyMissing | ForEach-Object { "$($_.What) at $($_.Path)" }) -join '; ') +
                ". The merge image is incomplete; fix the fan-in instead of paying the provisioning phase first.")
        }
        log 'Early fan-in fast-fail passed (OpenCV/ONNX/LiteRT roots present).'
    }

    Switch-BuildPhase '4. source tarball'
    # ---- 4. download GStreamer source tarball ----
    $gstSrcDir = Join-Path $resolvedSrcDir "gstreamer-$GstVersion"
    if (Test-Path $gstSrcDir) {
        log "Removing existing source directory: $gstSrcDir"
        Remove-Item -Path $gstSrcDir -Recurse -Force
    }

    $tarballUrl = "https://github.com/gstreamer/gstreamer/archive/refs/tags/$GstVersion.tar.gz"
    $tarballPath = Join-Path $resolvedLogDir "gstreamer-$GstVersion.tar.gz"
    log "Downloading GStreamer source tarball from $tarballUrl ..."
    # Shared helper: retry/backoff + redirect-following (GitHub /archive/ ->
    # codeload). The wrap and libffi fetches below stay on cmd/curl -- bulk
    # cmd.exe extraction, a different per-item flow.
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
    # Locate the real source dir (skip cpython/) and require a meson.build at its
    # root: with -KeepBuildArtifacts a stale sibling could win a name-prefix match.
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

    Switch-BuildPhase '5. wrap prefetch + meson fixups'
    # ---- 5. pre-extract all wrap-git subprojects via tarball ----
    # $libffiVer stays HERE: SourceBuild.PinParity's W1c scanner keys the pin site
    # by FILE NAME, and moving it into the module makes the pin invisible to that gate.
    $libffiVer = if ($env:LIBFFI_MESON_VERSION) { $env:LIBFFI_MESON_VERSION } else { '3.2.9999.4' }
    $subprojDir = Join-Path $gstSrcDir 'subprojects'
    # @(): the helper comma-wraps, but an empty result must still expose .Count.
    $wrapFailures = @(Invoke-GstWrapProvisioning -SubprojectDir $subprojDir -TempDir $resolvedLogDir `
        -LibffiVersion $libffiVer -Logger { param($m) log $m })

    # FAIL CLOSED on any wrap loss (#88): what reaches this point is persistent
    # (moved revision, dead mirror, broken TLS), because transient blips are
    # already absorbed by the helper's retry/backoff.
    if ($wrapFailures.Count -gt 0) {
        throw ("GStreamer subproject provisioning failed for $($wrapFailures.Count) wrap(s): " +
            ($wrapFailures -join ' | ') +
            ' — refusing to build a feature-reduced GStreamer (backlog #88).')
    }

    # Delete ALL remaining [wrap-git] wraps tree-wide: any subproject can bundle
    # its own, and git clone fails inside Windows containers. Pre-extracted wraps
    # were handled above; anything left would FATAL in meson.
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
    # io.h force-include shim, used INSTEAD of a bare -FIio.h on the cross lane:
    # meson hands c_args to .S files too, so a force-included C header is parsed as
    # assembly ("unrecognized instruction mnemonic" on openh264's aarch64 .S, and
    # dav1d/libvpx/x264 ship aarch64 .S as well). __ASSEMBLER__ is clang-defined
    # only for .S, so this is byte-identical to -FIio.h everywhere else.
    $ioShim = Join-Path $stubDir 'gst-io-shim.h'
    if (-not (Test-Path $ioShim)) {
        '#pragma once
/* See Build-GstreamerFromSource.ps1: meson passes c_args to .S files too. */
#ifndef __ASSEMBLER__
#include <io.h>
#endif' | Out-File -FilePath $ioShim -Encoding ASCII
        log "Created io.h force-include shim at $ioShim (assembly-safe)"
    }

    # ---- 5b-bis. pre-place the win-pkgconfig binary (resilience, both lanes) ----
    # win-pkgconfig is the ONE subproject that fetches with no fallback (a single
    # MIRROR_URL, one urlopen, zero retries) and it alone cost three chain runs.
    # download-binary.py exits early when the archive is already present with a
    # matching sha256, so pre-placing it removes the network from the critical
    # path. A failure here is a WARNING, not a throw -- meson still has its own try.
    $wpcDir = Join-Path $gstSrcDir 'subprojects/win-pkgconfig'
    $wpcMeson = Join-Path $wpcDir 'meson.build'
    if (Test-Path $wpcMeson) {
        $wpcText = Get-Content -LiteralPath $wpcMeson -Raw
        $wpcVer = ([regex]::Match($wpcText, "version\s*:\s*'([^']+)'")).Groups[1].Value
        $wpcSha = ([regex]::Match($wpcText, "zip_hash\s*=\s*'([0-9a-fA-F]{64})'")).Groups[1].Value
        if ($wpcVer -and $wpcSha) {
            $wpcZip = Join-Path $wpcDir "pkg-config-$wpcVer.zip"
            $wpcHave = (Test-Path $wpcZip) -and ((Get-FileHash -LiteralPath $wpcZip -Algorithm SHA256).Hash -ieq $wpcSha)
            if ($wpcHave) {
                log "win-pkgconfig: pkg-config-$wpcVer.zip already present and matches $($wpcSha.Substring(0,12))..."
            } else {
                # LAN preseed FIRST, upstream second: retries do not help against a
                # sustained outage (the same reasoning as the Vulkan SDK in
                # Build-Buildkit.ps1). Self-seeding -- whichever source works, the
                # archive is PUT back, so the first success immunises the next run.
                # Every step is fail-open; a preseed miss is not an error.
                $wpcUpstream = "https://gstreamer.freedesktop.org/src/mirror/pkg-config/pkg-config-$wpcVer.zip"
                $wpcDav = if ($env:SCCACHE_WEBDAV_ENDPOINT) { "$($env:SCCACHE_WEBDAV_ENDPOINT.TrimEnd('/'))/preseed/pkg-config-$wpcVer.zip" } else { '' }
                $wpcUrl = if ($wpcDav) { $wpcDav } else { $wpcUpstream }
                try {
                    try {
                        Invoke-DownloadWithRetry -Url $wpcUrl -DestinationPath $wpcZip -MaxAttempts 2
                        if ($wpcDav) { log "win-pkgconfig: fetched from the LAN preseed ($wpcDav)" }
                    } catch {
                        if (-not $wpcDav) { throw }
                        log "win-pkgconfig: preseed miss ($($_.Exception.Message)) - falling back to upstream"
                        Invoke-DownloadWithRetry -Url $wpcUpstream -DestinationPath $wpcZip
                        # Seed it for next time; failure here is irrelevant to this build.
                        $wpcCurl = Join-Path $env:SystemRoot 'System32\curl.exe'
                        if (Test-Path $wpcCurl) {
                            & $wpcCurl -sf --retry 2 --retry-delay 3 -T $wpcZip $wpcDav *> $null
                            if ($LASTEXITCODE -eq 0) { log "win-pkgconfig: seeded $wpcDav for future runs" }
                            $global:LASTEXITCODE = 0
                        }
                    }
                    $got = (Get-FileHash -LiteralPath $wpcZip -Algorithm SHA256).Hash
                    if ($got -ieq $wpcSha) {
                        log "win-pkgconfig: pre-placed pkg-config-$wpcVer.zip (sha256 verified) - meson will skip its own download"
                    } else {
                        Remove-Item -LiteralPath $wpcZip -Force -ErrorAction SilentlyContinue
                        log "WARNING: win-pkgconfig prefetch sha256 mismatch (got $($got.Substring(0,12))..., want $($wpcSha.Substring(0,12))...) - removed; meson will retry the download itself"
                    }
                } catch {
                    log "WARNING: win-pkgconfig prefetch failed ($($_.Exception.Message)) - meson will try its own single-shot download"
                }
            }
        } else {
            log "NOTE: could not parse version/zip_hash from $wpcMeson - skipping the win-pkgconfig prefetch"
        }
    }

    # ---- 5c. detect CUDA (available from Dockerfile.nvidia layer) ----
    # Get-GpuEnvironment sets CUDA_PATH/CUDA_HOME and prepends CUDA bin to PATH.
    $gpuEnv = Get-GpuEnvironment
    if ($gpuEnv.HasCuda) {
        log "CUDA detected at: $($gpuEnv.CudaRoot)"
    } else {
        log 'CUDA not detected -- nvcodec/cuda plugins will be auto-detected by Meson'
    }

    # ---- 5d. find compiler-rt for lld-link (__udivti3, etc.) ----
    # Resolve the LLVM install dir via clang-cl on PATH rather than a hardcoded
    # scoop layout -- survives an LLVM/scoop relocation.
    $clangClCmd = Get-Command 'clang-cl' -ErrorAction SilentlyContinue
    $llvmRoot = if ($clangClCmd) { Split-Path (Split-Path $clangClCmd.Source) } else { Join-Path $env:USERPROFILE 'scoop\apps\llvm\current' }
    # TARGET-FILTERED ON BOTH LANES: LLVM ships one builtins lib PER TARGET and this
    # path goes straight to lld-link. Once Install-ScoopTools.ps1 also installed the
    # aarch64 counterpart, amd64's arch-blind alphabetical -First 1 flipped to it and
    # the merge died linking gstreamer-1.0-0.dll ("machine type arm64 conflicts with
    # x64"). A selection that depends on what happens to be installed is no selection.
    $rtCandidates = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter '*builtins*.lib' -ErrorAction SilentlyContinue)
    $wantRt = (Get-ClangTargetTriple -Arch $script:GstTargetArch) -replace '-.*$', ''   # x86_64/aarch64-pc-windows-msvc -> x86_64/aarch64
    $rtCandidates = @($rtCandidates | Where-Object { $_.Name -match [regex]::Escape($wantRt) })
    if ($script:GstCross) {
        if ($rtCandidates.Count -eq 0) {
            # SELF-HEAL: the source-built toolchain (#135) ships the host builtins
            # only, so the arm64 GStreamer link would die on __udivti3. Mine the
            # aarch64 counterpart from the LLVM release archive (same recipe as
            # Install-ScoopTools.ps1); only the one .lib is kept.
            $rtHostLib = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter 'clang_rt.builtins-x86_64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($rtHostLib.Count -gt 0) {
                $rtVer = Get-SourceBuildVersion -EnvironmentVariables @('LLVM_WINDOWS_VERSION') -DefaultValue '23.1.0'
                $rtArchive = Join-Path $resolvedLogDir "clang+llvm-$rtVer-aarch64-pc-windows-msvc.tar.xz"
                $rtExtract = Join-Path $resolvedLogDir 'llvm-aarch64-rt'
                try {
                    log "Fetching aarch64 compiler-rt (LLVM $rtVer) - the patched toolchain ships x86_64 builtins only"
                    Invoke-DownloadWithRetry -Url "https://github.com/llvm/llvm-project/releases/download/llvmorg-$rtVer/clang%2Bllvm-$rtVer-aarch64-pc-windows-msvc.tar.xz" -DestinationPath $rtArchive
                    # System32 bsdtar, never the GNU tar that may be on PATH: GNU
                    # parses `C:\...` as a remote-host spec ("Cannot connect to C:").
                    $rtTar = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
                    if (-not $rtTar) { throw 'No tar.exe found to extract the aarch64 compiler-rt archive.' }
                    New-Item -ItemType Directory -Force -Path $rtExtract | Out-Null
                    & $rtTar -xf $rtArchive -C $rtExtract '*clang_rt.builtins-aarch64.lib'
                    $rtFound = @(Get-ChildItem -Path $rtExtract -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
                    if ($rtFound.Count -gt 0) {
                        Copy-Item -Path $rtFound[0].FullName -Destination $rtHostLib[0].Directory.FullName -Force
                        log "Installed aarch64 compiler-rt -> $(Join-Path $rtHostLib[0].Directory.FullName 'clang_rt.builtins-aarch64.lib')"
                    } else {
                        Write-Warning "clang_rt.builtins-aarch64.lib was not found inside $rtArchive - the upstream archive layout changed."
                    }
                } catch {
                    Write-Warning "aarch64 compiler-rt fetch failed: $($_.Exception.Message)"
                } finally {
                    Remove-Item -Path $rtArchive -Force -ErrorAction SilentlyContinue
                    Remove-Item -Path $rtExtract -Recurse -Force -ErrorAction SilentlyContinue
                }
                $rtCandidates = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter '*builtins*.lib' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [regex]::Escape($wantRt) })
            }
        }
        if ($rtCandidates.Count -eq 0) {
            # WARN, do not throw: absence is already tolerated on amd64, so throwing
            # only here would apply a stricter policy to the cross lane. Linking
            # nothing is the honest outcome -- lld-link then names the missing
            # __udivti3 & co precisely, unlike a machine-type conflict.
            Write-Warning ("compiler-rt builtins for '$wantRt' not found under $llvmRoot\lib\clang " +
                           "(present: $((@(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter '*builtins*.lib' -ErrorAction SilentlyContinue).Name | Sort-Object -Unique) -join ', ')). " +
                           'Linking WITHOUT compiler-rt rather than linking the host-arch library. If the link ' +
                           'later fails on __udivti3/__umodti3 & co, this is the cause and the fix is an aarch64 ' +
                           'compiler-rt, not the x86_64 one.')
        }
    }
    $compilerRtLib = @($rtCandidates | Select-Object -First 1)
    $rtFullPath = ''
    if ($compilerRtLib) {
        $rtFullPath = $compilerRtLib.FullName -replace '\\', '/'
        log "Found compiler-rt: $rtFullPath"
    }

    # ---- 5d-bis. Vulkan import library must match the TARGET ----
    # LunarG ships the aarch64 import libs in $VULKAN_SDK\Lib-ARM64 (an optional
    # component); nothing pointed lld-link there, so gst-plugins-bad's Vulkan
    # library linked the HOST import lib ("machine type x64 conflicts with arm64").
    # LIB is searched in order, so prepending is enough.
    if ($script:GstCross) {
        if ([string]::IsNullOrWhiteSpace($env:VULKAN_SDK)) {
            throw 'VULKAN_SDK is not set, so the target-arch Vulkan import library cannot be located. gst-plugins-bad would link the host vulkan-1.lib and fail with a machine-type conflict.'
        }
        $vkArchLib = Join-Path $env:VULKAN_SDK (Get-VulkanLibDirName -Arch $script:GstTargetArch)
        if (-not (Test-Path (Join-Path $vkArchLib 'vulkan-1.lib'))) {
            throw ("Vulkan import library for $($script:GstTargetArch) not found at $vkArchLib\vulkan-1.lib. " +
                   'It ships as the OPTIONAL com.lunarg.vulkan.arm64 component of the x64 SDK and is installed by ' +
                   'Install-ScoopTools.ps1 (warn-only there, so a base built before that step will lack it). ' +
                   'Without it lld-link picks the x64 vulkan-1.lib and fails with a machine-type conflict.')
        }
        $env:LIB = (@($vkArchLib) + @($env:LIB -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
        log "Vulkan: prepended $vkArchLib to LIB (target-arch import library)"
    }

    # ---- 5e. Windows SDK GUID import libs for clang-cl/lld-link ----
    # clang-cl's lld-link does not resolve the COM/DirectShow/MediaFoundation/KS
    # GUIDs that link.exe auto-pulls from uuid.lib, so name the SDK import libs
    # explicitly. Unreferenced symbols are not pulled, so this is harmless for
    # plugins that do not need them (/FORCE:MULTIPLE covers dups).
    $guidLibs = @(
        'uuid.lib', 'mfuuid.lib', 'strmiids.lib', 'ksuser.lib', 'dxguid.lib',
        'dmoguids.lib', 'wmcodecdspuuid.lib', 'mfplat.lib', 'mf.lib', 'mfreadwrite.lib'
    )
    # Resolved HERE because both the link args below and the meson cross file in
    # phase 6 need it: meson passes c_link_args THROUGH the compiler driver, which
    # defaults to the HOST triple, so without --target lld-link is handed
    # /machine:x64. Empty on amd64 and dropped below, so that lane is unchanged.
    $gstTargetArch = $script:GstTargetArch   # resolved once at the top of this script
    $gstCrossArg = if ($script:GstCross) { "--target=$(Get-ClangTargetTriple -Arch $gstTargetArch)" } else { '' }
    $linkArgElems = ((@('/FORCE:MULTIPLE', $gstCrossArg, $rtFullPath) + $guidLibs) |
        Where-Object { $_ } | ForEach-Object { "'$_'" }) -join ','
    log "Link args: [$linkArgElems]"

    # ---- 5f. patch gst-plugins-bad mediafoundation for clang-cl ----
    # The plugin's WinRT-app-partition detection lacks the msvc guard its required
    # GstWinRt helper library does have, so under clang-cl GstWinRt is never built
    # yet mediafoundation still detects winapi_app and demands gstwinrt_dep. Gate
    # winapi_app on msvc too: clang-cl then builds the desktop path (mfvideosrc).
    $mfMeson = Join-Path $gstSrcDir 'subprojects\gst-plugins-bad\sys\mediafoundation\meson.build'
    [void](Edit-SourceFile -Path $mfMeson -Marker "if runtimeobject_lib\.found\(\) and cxx\.get_id\(\) == 'msvc'" `
            -Description 'mediafoundation meson.build: gate winapi_app detection on msvc (clang-cl builds desktop path only)' `
            -WarnMessage 'mediafoundation winapi_app guard not found; mediafoundation=enabled may fail if GstWinRt is unavailable under clang-cl' `
            -Transform {
            param($mfContent)
            [regex]::Replace($mfContent, "if runtimeobject_lib\.found\(\)(\s*\r?\n)", "if runtimeobject_lib.found() and cxx.get_id() == 'msvc'`$1", 1)
        })

    # ---- 5g. bump cpp_std=c++11 pins to c++17 for the VS 18 MSVC STL ----
    # Several gst-plugins-bad C++ libs pin cpp_std=c++11 (dxva, d3d11/12, ...), but
    # VS 18's MSVC STL (14.51+) uses C++14 constructs unconditionally, which clang-cl
    # rejects in C++11 mode. Bump every pin to c++17, what the rest of this image
    # compiles with; wrap subprojects are pure C and carry no such pin.
    $cppStdPatched = 0
    Get-ChildItem -Path $gstSrcDir -Filter 'meson.build' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $content = [System.IO.File]::ReadAllText($_.FullName)
        if ($content -match 'cpp_std=c\+\+11') {
            [System.IO.File]::WriteAllText($_.FullName, ($content -replace 'cpp_std=c\+\+11', 'cpp_std=c++17'))
            $cppStdPatched++
        }
    }
    if ($cppStdPatched -eq 0) {
        Write-Warning 'cpp_std patch matched 0 meson.build files — upstream likely bumped past c++11; verify and retire this patch (or the MSVC-14.51 STL build breaks return)'
    }
    log "Bumped cpp_std=c++11 -> c++17 in $cppStdPatched gst meson.build file(s) (VS 18 MSVC STL needs >= C++14 under clang-cl)"

    # ---- 5h. port gst-plugins-bad ext/opencv to the OpenCV 5 header layout ----
    # gstreamer 1.29.2's opencv plugin is written for OpenCV 4, which RELOCATED the
    # APIs it uses (CascadeClassifier/CASCADE_* -> xobjdetect, contourArea &
    # approxPolyDP & convexHull -> geometry, findChessboardCorners & findCirclesGrid
    # & CALIB_CB_* -> calib + objdetect). Add the new header after each file's first
    # opencv2 include -- same classic APIs, new homes, not a behavioural change.
    $ocvExtDir = Join-Path $gstSrcDir 'subprojects\gst-plugins-bad\ext\opencv'
    $ocv5IncludeMap = @(
        @{ Pattern = 'CascadeClassifier|CASCADE_DO_CANNY_PRUNING|CASCADE_SCALE_IMAGE'; Add = @('opencv2/xobjdetect.hpp') },
        @{ Pattern = 'contourArea|approxPolyDP|convexHull';                            Add = @('opencv2/geometry.hpp') },
        @{ Pattern = 'findChessboardCorners|findCirclesGrid|CALIB_CB_';                Add = @('opencv2/calib.hpp', 'opencv2/objdetect.hpp') }
    )
    $ocvPortPatched = 0
    Get-ChildItem -Path $ocvExtDir -Include '*.cpp', '*.h', '*.hpp' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $c = [System.IO.File]::ReadAllText($_.FullName)
        $orig = $c
        foreach ($map in $ocv5IncludeMap) {
            if ($c -match $map.Pattern) {
                foreach ($hdr in $map.Add) {
                    if ($c -notmatch [regex]::Escape($hdr)) {
                        # Insert after the FIRST #include <opencv2/...> line in the file.
                        $c = [regex]::Replace($c, "(#include <opencv2/[^>]+>\r?\n)", "`${1}#include <$hdr>`n", 1)
                    }
                }
            }
        }
        # POSIX ftello/fseeko are absent under the Windows CRT -> use the 64-bit
        # MSVC equivalents (this build is Windows/clang-cl only).
        $c = $c -replace '\bftello\b', '_ftelli64' -replace '\bfseeko\b', '_fseeki64'
        if ($c -ne $orig) { [System.IO.File]::WriteAllText($_.FullName, $c); $ocvPortPatched++; log "OpenCV5 port -> $($_.Name)" }
    }
    log "OpenCV 5 header port applied to $ocvPortPatched gst ext/opencv file(s)"
    # gst hardcodes the UNVERSIONED -lopencv_tracking (Linux naming), but OpenCV's
    # Windows libs are versioned and already arrive with their real names via the
    # opencv4.pc dependency, so lld-link cannot open the bare import lib.
    $ocvMeson = Join-Path $ocvExtDir 'meson.build'
    if (Test-Path $ocvMeson) {
        $mc = [System.IO.File]::ReadAllText($ocvMeson)
        $mc2 = $mc -replace "\s*,\s*'-lopencv_tracking'", '' -replace "'-lopencv_tracking'\s*,\s*", '' -replace "'-lopencv_tracking'", ''
        if ($mc2 -ne $mc) { [System.IO.File]::WriteAllText($ocvMeson, $mc2); log 'Removed hardcoded -lopencv_tracking from ext/opencv/meson.build (opencv4.pc provides the versioned lib)' }
    }

    # ---- 5c. MANDATORY PLUGIN PRE-FLIGHT ─────────────────────────────────────
    # The three root causes (a missing opencv4.pc, ONNX Runtime shipping no .pc at
    # all, and the FFmpeg.wrap trap that would build a second, older FFmpeg) plus
    # the per-plugin mechanisms: docs/windows-builds.md § Mandatory GStreamer
    # plugins (the contract).
    #
    # The .pc files are authored HERE, not by the OpenCV and ONNX builds: those are
    # the two most expensive layers in the chain and a text file is not worth
    # invalidating them. Arch filtering (dropping tflite) lives in the CONTRACT,
    # never here -- pre-flight, smoke test and healthcheck disagreeing is the
    # 2026-07-11 regression that shipped an image without plugins.
    $requiredPlugins = @(Get-RequiredGstPlugin -Arch $script:GstTargetArch)
    # Declared before the branch so the meson args below can interpolate it
    # unconditionally: StrictMode would fault on an undefined variable.
    $script:TfliteIncludeArg = ''
    if ($SkipPluginGate) {
        log 'WARNING: -SkipPluginGate — the mandatory GStreamer plugin contract is DISABLED for this build.'
        log "WARNING: the resulting image is NOT shippable. Required set: $(($requiredPlugins | ForEach-Object { $_.Name }) -join ', ')"
    } else {
        log '--- mandatory plugin pre-flight ---'

        # opencv4.pc — describes the OpenCV 5 install under $OPENCV_ROOT.
        $ocvRoot = if ($env:OPENCV_ROOT) { $env:OPENCV_ROOT } else { Join-Path $resolvedInstallDir 'lib\opencv5' }
        # The arch component of OpenCV's Windows layout (<root>\<arch>\vc18) is the
        # one token that moves with the target, so it comes from the arch table.
        $ocvLib = if ($env:OPENCV_LIB) { $env:OPENCV_LIB } else { Join-Path $ocvRoot "$(Get-OpenCvArchDir)\vc18\lib" }
        # Header root = the directory CONTAINING opencv2/, found rather than assumed:
        # OpenCV's Windows layout has moved between majors, and guessing wrong yields
        # a .pc that resolves but cannot compile.
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
        # gst derives its cascade-data dir from the opencv dependency's prefix +
        # share/{opencv,OpenCV,opencv4} and errors when none is a directory -- but
        # pkgconf RELOCATES that prefix from the .pc file LOCATION, ignoring the
        # explicit prefix= line. So create share\opencv4 under every plausible
        # prefix root and fill each from <root>\etc.
        $ocvPrefixCandidates = @($ocvRoot, (Split-Path $ocvLib -Parent), $ocvLib) |
            Where-Object { $_ } | Select-Object -Unique
        foreach ($base in $ocvPrefixCandidates) {
            $shareDir = Join-Path $base 'share\opencv4'
            if (Test-Path $shareDir) { continue }
            New-Item -ItemType Directory -Force -Path $shareDir | Out-Null
            $filled = $false
            foreach ($d in @('haarcascades', 'lbpcascades')) {
                $src = Join-Path $ocvRoot "etc\$d"
                if (Test-Path $src) { Copy-Item $src (Join-Path $shareDir $d) -Recurse -Force; $filled = $true }
            }
            log ("Ensured OpenCV data dir $shareDir" + $(if ($filled) { ' (populated from etc\)' } else { ' (empty; no etc\haarcascades found)' }))
        }

        # libonnxruntime.pc — ORT ships none on any platform.
        $ortRoot = if ($env:ONNX_ROOT) { $env:ONNX_ROOT } else { Join-Path $resolvedInstallDir 'lib\onnxruntime-source' }
        $ortLib = Join-Path $ortRoot 'lib'
        $ortInclude = Join-Path $ortRoot 'include'
        if (-not (Test-Path (Join-Path $ortLib 'onnxruntime.lib'))) { throw "onnxruntime.lib not found in $ortLib — cannot describe ONNX Runtime to pkg-config." }
        # Same env-name order as Build-OnnxFromSource.ps1: reading only ONNX_VERSION
        # wrote a 1.28.0 .pc against a 1.29.0 install in standalone runs, and passed
        # the >= 1.16.1 constraint silently.
        $ortVersion = Get-SourceBuildVersion -Value '' -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.29.0' -StripVPrefix
        # ORT's headers sit at include\ AND include\onnxruntime\core\session on some
        # layouts; both are handed over so the plugin's #include resolves either way.
        $ortIncludes = @($ortInclude, (Join-Path $ortInclude 'onnxruntime'),
            (Join-Path $ortInclude 'onnxruntime\core\session')) | Where-Object { Test-Path $_ }
        [void](Write-PkgConfigFile -Name 'libonnxruntime' -Version $ortVersion `
                -Description 'ONNX Runtime (source build; ships no pkg-config file of its own)' `
                -IncludeDir $ortIncludes -LibDir $ortLib -Library @('onnxruntime') `
                -PkgConfigDir (Join-Path $ortLib 'pkgconfig'))

        # OpenSSL for the TARGET arch (cross lane only): scoop installs the host
        # architecture only, so pkg-config found the x64 .pc first and four targets
        # (hls, dtls, aes, glib-networking's TLS backend) died with "machine type x64
        # conflicts with arm64". The lib dir is found by SEARCH -- slproweb's layout
        # is upstream's business -- and upstream .pc files win if the tree ships any.
        $sslPcDirs = @()
        if ($script:GstCross) {
            $sslRoot = 'C:\opt\openssl-arm64'
            $sslLibHit = @(Get-ChildItem -Path $sslRoot -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($sslLibHit.Count -eq 0) {
                throw ("OpenSSL for $($script:GstTargetArch) not found under $sslRoot (no libcrypto.lib). " +
                       'Install-ScoopTools.ps1 installs it warn-only, so a base built before that step will lack it. ' +
                       "Without it gst-plugins-bad's hls/dtls/aes and glib-networking's openssl backend link the x64 " +
                       'import library and fail with a machine-type conflict.')
            }
            $sslLibDir = $sslLibHit[0].Directory.FullName
            # The include dir is FOUND, not composed: innounp extracts InnoSetup
            # payloads under a literal {app} directory, so a composed <root>\include
            # would silently not exist. opensslv.h sits at <include>\openssl\.
            $sslIncHit = @(Get-ChildItem -Path $sslRoot -Recurse -Filter 'opensslv.h' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($sslIncHit.Count -eq 0) {
                throw "OpenSSL headers for $($script:GstTargetArch) not found under $sslRoot (no opensslv.h). The extracted package layout changed."
            }
            $sslInc = $sslIncHit[0].Directory.Parent.FullName
            $sslOwnPc = @(Get-ChildItem -Path $sslRoot -Recurse -Filter 'openssl.pc' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($sslOwnPc.Count -gt 0) {
                $sslPcDirs = @($sslOwnPc[0].Directory.FullName)
                log "OpenSSL ($($script:GstTargetArch)): using upstream pkgconfig at $($sslPcDirs[0])"
            } else {
                $sslPcDir = Join-Path $resolvedLogDir 'openssl-arm64-pkgconfig'
                New-Item -Path $sslPcDir -ItemType Directory -Force | Out-Null
                # Three modules: consumers ask for libcrypto, libssl or the
                # umbrella 'openssl' depending on the plugin.
                [void](Write-PkgConfigFile -Name 'libcrypto' -Version '4.0.1' -Description 'OpenSSL cryptography library (aarch64)' `
                        -IncludeDir @($sslInc) -LibDir $sslLibDir -Library @('libcrypto') -PkgConfigDir $sslPcDir)
                [void](Write-PkgConfigFile -Name 'libssl' -Version '4.0.1' -Description 'OpenSSL TLS library (aarch64)' `
                        -IncludeDir @($sslInc) -LibDir $sslLibDir -Library @('libssl', 'libcrypto') -PkgConfigDir $sslPcDir)
                [void](Write-PkgConfigFile -Name 'openssl' -Version '4.0.1' -Description 'OpenSSL (aarch64)' `
                        -IncludeDir @($sslInc) -LibDir $sslLibDir -Library @('libssl', 'libcrypto') -PkgConfigDir $sslPcDir)
                $sslPcDirs = @($sslPcDir)
                log "OpenSSL ($($script:GstTargetArch)): authored libcrypto/libssl/openssl .pc in $sslPcDir (lib dir $sslLibDir)"
            }
        }

        # Make the new pkgconfig dirs visible to meson for THIS process; the OpenSSL
        # ones go FIRST so they win over the image's x64 openssl.pc. NB the explicit
        # @(..) + @(..): '+' binds tighter than ',', so @($a + $b, $c) would nest.
        $newPcDirs = @($sslPcDirs) + @((Join-Path $ocvLib 'pkgconfig'), (Join-Path $ortLib 'pkgconfig'))
        $env:PKG_CONFIG_PATH = (@($newPcDirs + ($env:PKG_CONFIG_PATH -split ';' | Where-Object { $_ })) | Select-Object -Unique) -join ';'
        log "PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH"

        # Neutralise FFmpeg.wrap so libav* resolve from OUR FFmpeg install rather
        # than the wrap's pinned 7.1.1 (see the header comment above).
        $ffmpegWrap = Join-Path $gstSrcDir 'subprojects\FFmpeg.wrap'
        if (Test-Path $ffmpegWrap) {
            Move-Item -Path $ffmpegWrap -Destination "$ffmpegWrap.disabled" -Force
            log 'Disabled subprojects/FFmpeg.wrap — gst-libav must link the FFmpeg this image ships, not a wrap-pinned 7.1.1.'
        }

        # PRESENCE-DRIVEN since #115: the cross lane BUILDS plain LiteRT, so the
        # decision input is the artifact (tensorflowlite_c.lib in the fanned-in
        # tree), never the lane. A cross merge from an older LiteRT-less core
        # degrades to disabled-with-reason instead of throwing.
        $script:GstTfliteLibDir = if ($env:LITERT_LIB) { $env:LITERT_LIB } else { Join-Path $resolvedInstallDir 'lib\litert\lib' }
        $script:GstTfliteAvailable = (-not $script:GstCross) -or (Test-Path (Join-Path $script:GstTfliteLibDir 'tensorflowlite_c.lib'))
        if (-not $script:GstTfliteAvailable) {
            log ("tflite integration skipped: no tensorflowlite_c.lib in $script:GstTfliteLibDir -- this cross image " +
                 'predates the #115 LiteRT cross build (or media-litert was not fanned in). The meson feature is set ' +
                 'to disabled EXPLICITLY below, never auto.')
        } else {
            # ── tflite: the one integration that does NOT use pkg-config ──────────
            # gst ext/tflite probes the compiler for tensorflow/lite/c/c_api.h -- the
            # PRE-RENAME TensorFlow path -- while LiteRT stages its headers under
            # include\tflite\. A namespace mismatch, not a missing dependency: mirror
            # the header tree under the name upstream probes for; the copies' own
            # tflite/... includes still resolve from the same include root.
            $litertRoot = if ($env:LITERT_ROOT) { $env:LITERT_ROOT } else { Join-Path $resolvedInstallDir 'lib\litert' }
            $litertInclude = if ($env:LITERT_INCLUDE) { $env:LITERT_INCLUDE } else { Join-Path $litertRoot 'include' }
            $litertLib = if ($env:LITERT_LIB) { $env:LITERT_LIB } else { Join-Path $litertRoot 'lib' }
            $tfliteHeaderTree = Join-Path $litertInclude 'tflite'
            $tfAliasRoot = Join-Path $litertInclude 'tensorflow\lite'
            $tfAliasProbe = Join-Path $litertInclude 'tensorflow\lite\c\c_api.h'
            if (-not (Test-Path $tfAliasProbe)) {
                if (-not (Test-Path (Join-Path $tfliteHeaderTree 'c\c_api.h'))) {
                    throw ("LiteRT headers not found: neither $tfAliasProbe nor $(Join-Path $tfliteHeaderTree 'c\c_api.h') exists. " +
                        'The tflite plugin cannot be built without the TFLite C API headers — check that the media-litert ' +
                        'branch image was fanned in (COPY --from=media-litert C:\runtime\lib\litert).')
                }
                New-Item -ItemType Directory -Force -Path (Split-Path $tfAliasRoot -Parent) | Out-Null
                Copy-Item -Path $tfliteHeaderTree -Destination $tfAliasRoot -Recurse -Force
                log "Staged tensorflow/lite/ header alias from $tfliteHeaderTree (LiteRT ships the post-rename tflite/ layout; gst probes the old path)."
            }
            if (-not (Test-Path $tfAliasProbe)) { throw "tensorflow/lite/c/c_api.h still missing at $tfAliasProbe after staging the alias tree." }
    
            # The link name upstream asks for, in preference order. If neither exists,
            # say what IS there -- a bare "not found" would send someone hunting
            # PKG_CONFIG_PATH for a plugin that never consults it.
            $tfliteLibName = $null
            foreach ($candidate in @($requiredPlugins | Where-Object { $_.Name -eq 'tflite' }).NeedsLib) {
                if (Test-Path (Join-Path $litertLib "$candidate.lib")) { $tfliteLibName = $candidate; break }
            }
            if (-not $tfliteLibName) {
                $present = @(Get-LibraryLinkName -LibDir $litertLib)
                throw ("neither tensorflowlite_c.lib nor tensorflow-lite.lib is present in $litertLib, so gst's " +
                    "cc.find_library() probe cannot succeed. Libraries actually staged there: $($present -join ', '). " +
                    'If LiteRT now emits the C API under a different name, add it to NeedsLib in Get-RequiredGstPlugin ' +
                    'rather than renaming the binary.')
            }
            log "TFLite C API library: $tfliteLibName.lib in $litertLib"
    
            # cc.find_library / cc.has_header consult the COMPILER's search paths, so
            # INCLUDE/LIB is the mechanism that works here (lld-link reads LIB for its
            # default search path). Do NOT also pass the dir as a /LIBPATH: c_link_arg
            # -- clang-cl treats the whole token as an input filename and meson's
            # compile+link sanity check fails before any plugin is configured.
            $env:INCLUDE = (@($litertInclude) + @($env:INCLUDE -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
            $env:LIB = (@($litertLib) + @($env:LIB -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
            # Forward slashes inside the meson array literal: meson parses those
            # strings with escape sequences, so a native drive path would mangle.
            $script:TfliteIncludeArg = '-I' + ($litertInclude -replace '\\', '/')
            log "INCLUDE += $litertInclude ; LIB += $litertLib"
        }

        # Everything the required set needs must resolve NOW, not after an hour.
        $pcModules = @($requiredPlugins | Where-Object { $_.Detection -eq 'pkg-config' } |
                ForEach-Object { $_.NeedsPc } | Select-Object -Unique)
        # The version floors upstream actually applies -- presence alone is not
        # enough: FFmpeg shipped .pc files declaring `Version: ..`, which passes
        # --exists and fails every constraint, so gst-libav was skipped silently.
        $pcMinimum = @{
            'libavcodec'     = '58.18.100'   # gst-libav/meson.build
            'libavformat'    = '58.12.100'
            'libavutil'      = '56.14.100'
            'libavfilter'    = '7.16.100'
            'opencv4'        = '4.0.0'       # gst-plugins-bad/gst-libs/gst/opencv
            'libonnxruntime' = '1.16.1'      # gst-plugins-bad/ext/onnx
        }
        Assert-PkgConfigModule -Module $pcModules -MinimumVersion $pcMinimum `
            -Context ('mandatory GStreamer plugins: ' + (($requiredPlugins | ForEach-Object { $_.Name }) -join ', '))
        log '--- pre-flight OK: every mandatory plugin dependency resolves ---'
    }

    # ── gst-plugins-base x86 SIMD gate (ARM cross only) ──────────────────────
    # Upstream bug in gst-plugins-base/meson.build: the msvc branch assumes "not
    # x86_64" means x86 32-bit, so have_sse/have_sse2 are set for aarch64 (only
    # have_sse41 carries the cpu_family guard) and clang-cl accepts /arch:SSE for an
    # aarch64 target silently. The x86 resampler sources then die in mmintrin.h.
    # The fix extends the guard upstream already applies to have_sse41.
    if ($script:GstCross) {
        $gstBaseMeson = Join-Path $gstSrcDir 'subprojects/gst-plugins-base/meson.build'
        if (-not (Test-Path $gstBaseMeson)) {
            log "NOTE: $gstBaseMeson not found - skipping the x86 SIMD guard (layout changed?)"
        } elseif ((Get-Content -LiteralPath $gstBaseMeson -Raw) -match "cpu_family\(\) in \['x86'") {
            log 'gst-plugins-base x86 SIMD guard already applied.'
        } else {
            # 'have_sse2?' deliberately does NOT match have_sse41: after 'have_sse'
            # the next character there is '4', which fails the '\s*=' that follows.
            [void](Invoke-InlineRegexPatch -Path $gstBaseMeson -Guard 'have_sse\s*=\s*cc\.has_argument' `
                    -Pattern 'have_sse2?\s*=\s*cc\.has_argument\(sse2?_args\)' `
                    -Replacement "`$0 and host_machine.cpu_family() in ['x86', 'x86_64']" `
                    -Description 'gst-plugins-base: gate x86 SSE resampler variants on cpu_family')
            $gstBaseText = Get-Content -LiteralPath $gstBaseMeson -Raw
            if ($gstBaseText -notmatch "cpu_family\(\) in \['x86'") {
                throw ("gst-plugins-base meson.build: the have_sse/have_sse2 guard did not apply (upstream layout " +
                       "changed?). Without it the x86 SSE resampler sources are compiled for aarch64 and die in " +
                       "mmintrin.h. Re-check $gstBaseMeson.")
            }
            log 'Patched gst-plugins-base: x86 SSE resampler variants now gated on host_machine.cpu_family().'
        }
    }

    # ── gst-plugins-bad Vulkan lib dir (ARM cross only) ──────────────────────
    # Upstream bug, same class as the SSE gate: vulkan/meson.build picks the lib dir
    # from build_machine (always x86_64 here) and passes it EXPLICITLY via `dirs:`,
    # so no LIB ordering on our side can override it -- the aarch64 build linked the
    # x64 vulkan-1.lib. meson's own VulkanDependencySystem maps build x86_64 + host
    # aarch64 -> Lib-ARM64, which is exactly the branch added here.
    if ($script:GstCross) {
        $gstVkMeson = Join-Path $gstSrcDir 'subprojects/gst-plugins-bad/gst-libs/gst/vulkan/meson.build'
        if (-not (Test-Path $gstVkMeson)) {
            log "NOTE: $gstVkMeson not found - skipping the Vulkan lib-dir fix (layout changed?)"
        } elseif ((Get-Content -LiteralPath $gstVkMeson -Raw) -match "Lib-ARM64") {
            log 'gst-plugins-bad Vulkan lib-dir fix already applied.'
        } else {
            $vkDirName = Get-VulkanLibDirName -Arch $script:GstTargetArch
            $vkCpu = switch ($script:GstTargetArch) {
                'arm64' { 'aarch64' }
                default { throw "build-gstreamer: no meson cpu_family mapping for '$($script:GstTargetArch)' in the Vulkan lib-dir fix." }
            }
            [void](Invoke-InlineRegexPatch -Path $gstVkMeson `
                    -Guard "build_machine\.cpu_family\(\) == 'x86_64'" `
                    -Pattern "if build_machine\.cpu_family\(\) == 'x86_64'\r?\n(\s*)vulkan_lib_dir = join_paths\(vulkan_root, 'Lib'\)" `
                    -Replacement "if host_machine.cpu_family() == '$vkCpu'`n`${1}vulkan_lib_dir = join_paths(vulkan_root, '$vkDirName')`n    elif build_machine.cpu_family() == 'x86_64'`n`${1}vulkan_lib_dir = join_paths(vulkan_root, 'Lib')" `
                    -Description "gst-plugins-bad: Vulkan lib dir follows host_machine, not build_machine")
            if ((Get-Content -LiteralPath $gstVkMeson -Raw) -notmatch [regex]::Escape($vkDirName)) {
                throw ("gst-plugins-bad vulkan/meson.build: the lib-dir fix did not apply (upstream layout changed?). " +
                       "Without it the aarch64 build links the x64 vulkan-1.lib and fails with a machine-type conflict. Re-check $gstVkMeson.")
            }
            log "Patched gst-plugins-bad: Vulkan lib dir -> $vkDirName (host_machine, not build_machine)."
        }
    }

    Switch-BuildPhase '6. meson setup'
    # ---- 6. meson setup (retry with wrap cleanup) ----
    # Meson cross file. --cross-file is the ONLY way to tell meson host_machine !=
    # build_machine (there is no per-target compiler property); without one every
    # host_machine.cpu_family() branch takes the x86 path and the configure is green
    # but x86-shaped. Written to the LOG dir, which survives the retry's build-dir
    # wipe, and deliberately carrying NO [built-in options] c_args/cpp_args: meson
    # gives the command line higher precedence, so a --target here would be dropped.
    $mesonCrossArgs = @()
    if (Test-WindowsCrossTarget -Arch $gstTargetArch) {
        $gstTriple = Get-ClangTargetTriple -Arch $gstTargetArch
        # meson's own vocabulary, NOT this repo's arch names. A missing mapping
        # THROWS: a wrong cpu_family configures green and yields an x86-shaped build.
        $gstCpuFamily = switch ($gstTargetArch) {
            'arm64' { 'aarch64' }
            default { throw "build-gstreamer: no meson cpu_family mapping for target arch '$gstTargetArch' - add one before building it." }
        }
        # CC/CXX may carry the sccache launcher, and meson [binaries] takes a LIST,
        # so split rather than quote as one word.
        #
        # --target BELONGS IN THE EXELIST, not only in c_args: meson parses the
        # triple out of `<exelist> --version` and derives the linker's and
        # archiver's /MACHINE from it, so without it every archive and DLL is built
        # /MACHINE:x64 over arm64 objects. [host_machine] cpu_family does NOT drive
        # /MACHINE. The duplicate --target in -Dc_args below is harmless and stays:
        # it keeps the flags right for subprojects that rebuild the command.
        $ccList = (((($env:CC -split '\s+') | Where-Object { $_ }) + @("--target=$gstTriple")) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        $cxxList = (((($env:CXX -split '\s+') | Where-Object { $_ }) + @("--target=$gstTriple")) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        # Rust for the TARGET (#128): meson only builds gst-ptp-helper when the cross
        # file names a rust compiler. The aarch64 std is added here and PROVEN with a
        # one-line staticlib first -- a rust entry that fails meson's sanity check
        # fails the whole setup, whereas an absent one just skips the helper.
        $rustTargetLine = ''
        $rustTriple = Get-RustTargetTriple -Arch $gstTargetArch
        $rustup = (Get-Command rustup -ErrorAction SilentlyContinue).Source
        $rustc = (Get-Command rustc -ErrorAction SilentlyContinue).Source
        if ($rustup -and $rustc) {
            # The image's rustup was installed from a local mirror that no longer
            # exists, so `rustup target add` cannot fetch the aarch64 rust-std.
            # Fetching exactly the tarball the cached manifest names lets rustup
            # verify and install it offline-style. Fail-soft: the probe below decides.
            $stdFetch = Install-RustTargetStdFromPinnedManifest -Triple $rustTriple
            log "  rustup| $stdFetch"
            & $rustup target add $rustTriple 2>&1 | ForEach-Object { log "  rustup| $_" }
            $rustProbeDir = Join-Path $resolvedLogDir 'rust-cross-probe'
            New-Item -Path $rustProbeDir -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $rustProbeDir 'probe.rs') -Encoding ASCII -Value '#[no_mangle] pub extern "C" fn kata_probe() -> i32 { 42 }'
            & $rustc --target $rustTriple --crate-type staticlib -o (Join-Path $rustProbeDir 'probe.lib') (Join-Path $rustProbeDir 'probe.rs') 2>&1 | ForEach-Object { log "  rustc| $_" }
            if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $rustProbeDir 'probe.lib'))) {
                $rustTargetLine = "rust = ['$($rustc -replace '\\', '/')', '--target=$rustTriple']"
                log "Rust cross target ${rustTriple}: staticlib probe OK -- gst-ptp-helper will be built for the target"
            } else {
                log "Rust cross target ${rustTriple}: probe FAILED (exit $LASTEXITCODE) -- rust stays OUT of the cross file; gst-ptp-helper is skipped on this lane (a PTP clock helper, not a media feature)"
            }
            $global:LASTEXITCODE = 0
        } else {
            log 'Rust cross target: rustup/rustc not on PATH -- rust stays out of the cross file; gst-ptp-helper is skipped on this lane'
        }
        $crossFile = Join-Path $resolvedLogDir "meson-cross-$gstTargetArch.ini"
        Set-Content -Path $crossFile -Encoding ASCII -Value @"
[binaries]
c = [$ccList]
cpp = [$cxxList]
ar = 'llvm-lib'
strip = 'llvm-strip'
windres = 'llvm-rc'
pkg-config = 'pkg-config'
cmake = 'cmake'
$rustTargetLine

[properties]
# Nothing built here can run on this windows/amd64 host, so every cc.run() and
# subproject sanity exec must be REFUSED rather than silently answered with a
# HOST result. No exe_wrapper is supplied on purpose: there is no emulator.
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$gstCpuFamily'
cpu = '$gstCpuFamily'
endian = 'little'
"@
        # NATIVE file (#128): a cross file describes the HOST machine only, so the
        # BUILD machine had no C compiler at all, the build-machine glib fallback
        # died and libnice's by-name lookup failed -- webrtc, gstwebrtcnice and
        # libnice were the whole plugin-inventory gap between the lanes. Same
        # compilers without the --target, i.e. exactly what the amd64 lane runs.
        $nccList = ((($env:CC -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        $ncxxList = ((($env:CXX -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        # The build machine's LIBRARY dirs: the native compiler's sanity check linked
        # against the arm64 CRT, because the RUN's LIB names the target's dirs and
        # lld-link reads only LIB. /LIBPATH can never ride c_link_args with clang-cl
        # (the driver reads a path-shaped token as an input file), but /vctoolsdir:
        # and /winsdkdir: (+ /winsdkversion:) are understood by both driver and
        # linker and pick the arch from /machine:. Both roots are derived from LIB.
        $vcToolsDir = $null; $winSdkDir = $null; $winSdkVer = $null
        foreach ($entry in @(($env:LIB -split ';') | Where-Object { $_ })) {
            if (-not $vcToolsDir -and $entry -match '^(.*\\VC\\Tools\\MSVC\\[^\\]+)\\+lib\\') { $vcToolsDir = $Matches[1] }
            if (-not $winSdkDir -and $entry -match '^(.*\\Windows Kits\\10)\\+lib\\+([^\\]+)\\+(um|ucrt)\\') { $winSdkDir = $Matches[1]; $winSdkVer = $Matches[2] }
        }
        if (-not $vcToolsDir) { $vcToolsDir = Get-MsvcToolsRoot }
        # The build machine's MSVC PROGRAMS: the libffi meson port preprocesses with
        # cl and assembles with ml64 via find_program, and under VsDevCmd -arch=arm64
        # PATH leads with bin\HostX64\ARM64 -- an ARM64-targeting cl defines _M_ARM64,
        # ffitarget.h never enters its X86_WIN64 branch and ml64 dies. Meson consults
        # [binaries] BEFORE PATH; missing tools throw here, not 40 minutes into ninja.
        $buildCl   = Resolve-BuildMachineMsvcTool -VcToolsDir $vcToolsDir -Name 'cl.exe'
        $buildMl64 = Resolve-BuildMachineMsvcTool -VcToolsDir $vcToolsDir -Name 'ml64.exe'
        $buildLinkArgList = @()
        if ($vcToolsDir -and (Test-Path $vcToolsDir)) { $buildLinkArgList += "/vctoolsdir:$($vcToolsDir -replace '\\', '/')" }
        if ($winSdkDir -and (Test-Path $winSdkDir)) {
            $buildLinkArgList += "/winsdkdir:$($winSdkDir -replace '\\', '/')"
            if ($winSdkVer) { $buildLinkArgList += "/winsdkversion:$winSdkVer" }
        }
        $buildLibDirs = $buildLinkArgList   # logged below under the old name
        $buildLinkArgs = (($buildLinkArgList | ForEach-Object { "'" + $_ + "'" }) -join ', ')
        $nativeFile = Join-Path $resolvedLogDir 'meson-native-amd64.ini'
        Set-Content -Path $nativeFile -Encoding ASCII -Value @"
[binaries]
c = [$nccList]
cpp = [$ncxxList]
ar = 'llvm-lib'
strip = 'llvm-strip'
windres = 'llvm-rc'
pkg-config = 'pkg-config'
cmake = 'cmake'
cl = '$buildCl'
ml64 = '$buildMl64'
$(if ($rustc) { "rust = ['$($rustc -replace '\\', '/')']" } else { '' })

[built-in options]
c_link_args = [$buildLinkArgs]
cpp_link_args = [$buildLinkArgs]
"@
        if ($buildLibDirs.Count -eq 0) { log "WARNING: neither a VC tools root nor a Windows SDK root could be derived from LIB for the build machine -- native links will rely on LIB as-is (expect the build-machine sanity check to fail if LIB is the target's)" }
        $mesonCrossArgs = @('--cross-file', $crossFile, '--native-file', $nativeFile)
        log "Meson cross file for $gstTargetArch ($gstTriple): $crossFile"
        Get-Content $crossFile | ForEach-Object { log "  cross| $_" }
        log "Meson native file for the amd64 build machine: $nativeFile"
        Get-Content $nativeFile | ForEach-Object { log "  native| $_" }
    }
    # amd64 keeps the literal '-FIio.h' so its configure command line is byte-identical.
    $ioFI = if ($script:GstCross) { '-FIgst-io-shim.h' } else { '-FIio.h' }
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
        # Enable all GStreamer plugin sets. meson's `auto` means "skip silently if
        # the dependency is missing" -- which is how opencv/onnx/libav went missing
        # from a SHIPPED image without one line of red. `enabled` fails meson setup
        # in seconds instead, and the pre-flight above has already proven the .pc
        # files resolve, so a failure here is a genuine toolchain problem.
        '-Dgpl=enabled',
        '-Dbase=enabled',
        '-Dgood=enabled',
        '-Dugly=enabled',
        '-Dbad=enabled',
        '-Dges=enabled',
        '-Drtsp_server=enabled',
        '-Dtools=enabled',
        # $script:TfliteIncludeArg rides in c_args AND cpp_args: the tflite plugin's
        # has_header probe runs against the C compiler while its sources are C++.
        # -Wno-incompatible-pointer-types: clang 16+ promoted it to a default error
        # and gst ext/onnx trips it. -Wno-undef: graphene tests bare `__GNUC__` in
        # #if under a -Werror it brings along, and clang-cl defines no __GNUC__.
        # $gstCrossArg must live on the COMMAND LINE, which outranks the cross file;
        # the `if` guards the separator so amd64's value stays byte-identical.
        # $ioFI is the assembly-safe shim on the cross lane -- see phase 5b.
        "-Dc_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg $ioFI -Disatty=_isatty -Dfileno=_fileno -Dclose=_close -Dwrite=_write -DSTDOUT_FILENO=1 -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types -Wno-undef$(if ($gstCrossArg) { " $gstCrossArg" })",
        "-Dcpp_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg $ioFI -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types$(if ($gstCrossArg) { " $gstCrossArg" })",
        # ── Maximum feature set (see also $guidLibs above for the GUID fix) ──
        # mediafoundation ENABLED: modern Windows webcam capture (mfvideosrc + the MF
        # device provider) required by the Rust capture path; needs the GUID libs.
        '-Dgst-plugins-bad:mediafoundation=enabled',
        # wasapi (v1) stays DISABLED: it links against Core Audio interface
        # wasapi (v1) stays DISABLED: it links Core Audio interface GUIDs that live in
        # NO SDK import lib (upstream expects source-level INITGUID, which clang-cl
        # does not do). Not a feature loss -- wasapi2 is built by default.
        '-Dgst-plugins-bad:wasapi=disabled',
        # graphene: its MSVC path calls SSE4.1 intrinsics with no target-feature
        # guard, which clang-cl refuses. The scalar path is correct for geometry math.
        '-Dgraphene:sse2=false',
        # svtjpegxs stays DISABLED: its SVT-JPEG-XS subproject does not compile under
        # clang-cl. A niche codec, not worth patching the vendored SVT source.
        '-Dgst-plugins-bad:svtjpegxs=disabled',
        # ── Genuinely-hard blockers under clang-cl: kept OFF (documented) ──
        # cairo:win32 crashes clang-cl (LLVM 22 mmintrin.h __builtin_shufflevector);
        # -Dcairo:win32=disabled intentionally fails cairo at meson setup.
        '-Dcairo:win32=disabled',
# Opus intrinsics stay DISABLED on both lanes. The x86 MMX/SSE path
        # crashes clang-cl (mmintrin.h), and the cross-lane NEON enablement
        # (tried 2026-08-30, reverted 2026-08-31) died two ways under clang-cl
        # aarch64: RTCD applies -mfpu=neon (ARM32-only flag) and the RTCD CPU
        # probe arm_armcpu.c uses MSVC's __emit, which clang-cl lacks. The
        # working enablement recipe (intrinsics=enabled + rtcd=disabled) is
        # recorded in docs/windows-cross-builds.md and the backlog; re-enable
        # only in a dedicated test window on a real device.
        '-Dopus:intrinsics=disabled',
        # nvcodec: gstnvdecoder.cpp needs gst-d3d11 headers clang-cl cannot find.
        # The CUDA gst-lib is auto-detected separately.
        '-Dgst-plugins-bad:nvcodec=disabled',
        # dots-viewer: Rust subproject; cargo crates.io index fetch fails in the
        # offline container. Dev tool, not a media feature.
        '-Dgst-devtools:dots-viewer=disabled',
        # /FORCE:MULTIPLE for libffi dups; compiler-rt for lld-link (__udivti3
        # etc.); GUID import libs (see $guidLibs) for MF/WASAPI/DShow/KS symbols.
        "-Dc_link_args=[$linkArgElems]",
        "-Dcpp_link_args=[$linkArgElems]"
    ) + $(
        # The mandatory contract expressed to meson, behind the same switch as the
        # pre-flight so -SkipPluginGate really lets the build proceed without them.
        if ($SkipPluginGate) { @() } else {
            @(
                '-Dlibav=enabled',
                '-Dgst-plugins-bad:opencv=enabled',
                '-Dgst-plugins-bad:onnx=enabled',
                # NEVER 'auto' (the repo-wide rule): it would half-configure against
                # an empty LiteRT tree and fail late. Since #115 the switch is
                # ARTIFACT presence, not the lane; amd64 is always enabled.
                $(if ($script:GstTfliteAvailable) { '-Dgst-plugins-bad:tflite=enabled' } else { '-Dgst-plugins-bad:tflite=disabled' })
            ) + @(
                # Meson-native contract entries (#128: webrtc + nice, the one
                # plugin-inventory difference between the lanes). `enabled` each, so
                # a lane that cannot build libnice fails setup in seconds.
                $requiredPlugins | Where-Object { $_.Detection -eq 'meson' } | ForEach-Object { "-D$($_.MesonOption)=enabled" }
            )
        }
    ) + @(
        # glib's own test suite: 562 targets that ship nothing. The top-level
        # -Dtests=disabled covers the GStreamer modules only; glib is a wrap.
        '-Dglib:tests=false'
    ) + $mesonCrossArgs + $MesonSetupArgs

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
        $mesonOut = if (Test-Path $outFile) { @(Get-Content $outFile) } else { @() }
        $mesonOut | ForEach-Object { if ($_) { log $_ } }
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        if ($mesonExitCode -eq 0) { $mesonSucceeded = $true; break }

        # Never swallow logs: meson's stdout only says "cannot compile programs";
        # the compiler command line and its stderr live in meson-log.txt. Dump it
        # BEFORE the attempt-1 cleanup wipes $resolvedBuildDir.
        $mesonLog = Join-Path $resolvedBuildDir 'meson-logs\meson-log.txt'
        $mesonLogLines = @()
        if (Test-Path $mesonLog) {
            $mesonLogLines = @(Get-Content $mesonLog)
            # Excerpt, not the whole file: see Select-MesonLogExcerpt. The
            # retry classification below still scans every line.
            $excerpt = Select-MesonLogExcerpt -Lines $mesonLogLines
            log "---- meson-log.txt excerpt (attempt $attempt, exit $mesonExitCode): $($excerpt.Total) lines; $($excerpt.DiagnosticTotal) diagnostic line(s), showing $($excerpt.Diagnostics.Count) with line numbers + the last $($excerpt.Tail.Count); full file: $mesonLog ----"
            $excerpt.Diagnostics | ForEach-Object { log $_ }
            log "---- meson-log.txt tail (last $($excerpt.Tail.Count) lines) ----"
            $excerpt.Tail | ForEach-Object { if ($_) { log $_ } }
            log '---- end meson-log.txt ----'
        } else {
            log "meson-log.txt not found at $mesonLog"
        }

        # A deterministic meson configure error fails IDENTICALLY on retry, so the
        # attempt-2 cleanup + full wrap re-download is pure waste. Retry ONLY
        # transient failures.
        $failureClass = Get-MesonSetupFailureClass -Output @($mesonOut) -LogLines $mesonLogLines
        $hardError = $failureClass.HardError
        # ... EXCEPT that a failed subproject DOWNLOAD wears exactly that
        # meson.build:LINE:COL costume and is NOT deterministic -- a 503 on
        # gstreamer.freedesktop.org cost a whole chain run -- so a network-shaped
        # failure is retried anyway. Signatures: Get-MesonSetupFailureClass.
        $networkError = $failureClass.NetworkError
        if ($hardError -and -not $networkError) {
            log "meson setup hit a deterministic configure error; NOT retrying (a retry repeats it identically after a full wrap re-download): $($hardError[-1].Trim())"
            break
        }
        if ($hardError) {
            log "meson setup failed with a meson.build error that carries a NETWORK signature - treating as transient and retrying: $($networkError[-1].Trim())"
        }

        if ($attempt -eq 1) {
            # Delete known-problematic [wrap-git] wraps inside downloaded subprojects
            Get-ChildItem -Path $gstSrcDir -Filter 'gi-docgen.wrap' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $gstSrcDir -Filter 'gtk-doc.wrap' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
            if (Test-Path $resolvedBuildDir) { Remove-Item -Path $resolvedBuildDir -Recurse -Force }
        }
    }
    if (-not $mesonSucceeded) { throw 'meson setup failed after 2 attempts' }
    log 'meson setup completed.'

    # Inline patch, NOT a .patch file: the webrtc-audio-processing wrap version
    # floats with the GStreamer release, so a static patch would rot. Its SIMD
    # kernels index vectors via MSVC union members; clang-cl's __m256 is a native
    # vector type without members but supports the direct subscripting produced here.
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

    # Inline patch, NOT a .patch file: FFMPEG_VERSION=master floats, and master
    # removed the V308/V408/V410 codec IDs gst-libav still lists in its exclusion
    # conditions. R210, which shares the V410 line, still exists and is kept.
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

    # graphene's meson.build appends -Werror=undef AFTER our c_args (last flag wins),
    # so its bare `#if __GNUC__` tests die under clang-cl. Drop that ONE flag at the
    # source; ninja regenerates on meson.build changes, so patching here is safe.
    $grapheneMeson = Get-ChildItem -Path (Join-Path $gstSrcDir 'subprojects') -Directory -Filter 'graphene-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'meson.build' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($grapheneMeson) {
        [void](Edit-SourceFile -Path $grapheneMeson `
                -Description 'graphene meson.build: drop -Werror=undef (clang-cl has no __GNUC__)' `
                -WarnMessage 'graphene meson.build present but -Werror=undef not found; if graphene still fails on -Wundef, its warning flags moved.' `
                -Transform {
                param($mbContent)
                $mbContent -replace "'-Werror=undef',?\s*", ''
            })
    }

    Switch-BuildPhase '7. compile'
    # ---- 7. compile (retry once to work around LLVM 22 mmintrin.h bug in Cairo) ----
    # Job budget + stall guard (backlog #65): `meson compile` without -j lets ninja
    # default to cores+2 and ignore MEMORY_LIMIT_GB, and without the guard a wedged
    # sccache server hangs the merge stage indefinitely. 2 GB/job: GStreamer TUs are
    # C-sized, not ONNX-CUDA-sized.
    $gstJobs = Get-BuildJobCount -MemGBPerJob 2
    log "meson compile with -j $gstJobs (MEMORY_LIMIT_GB='$env:MEMORY_LIMIT_GB', cores=$([Environment]::ProcessorCount))"
    $compileSucceeded = $false
    for ($cAttempt = 1; $cAttempt -le 2; $cAttempt++) {
        log "Compiling GStreamer (attempt $cAttempt/2, may take 30-60 min)..."
        $gstStallGuard = Start-SccacheStallGuard -MarkerPath (Join-Path $resolvedLogDir 'gstreamer-stall-guard.marker')
        try {
            # After a GStreamer version bump, re-run the host-arch link sweep with
            # `--ninja-args=-k,0`: ninja stops at the FIRST failing target, so each
            # plugin linking a host-arch third-party lib otherwise costs a full
            # ~22-minute cycle to discover. NB the value needs ONE token with '=':
            # argparse refuses a separate value starting with '-'.
            & $mesonExe compile -C $resolvedBuildDir -j $gstJobs 2>&1 | ForEach-Object { if ($_) { log $_ } }
        } finally {
            Stop-SccacheStallGuard -Guard $gstStallGuard
        }
        if ($LASTEXITCODE -eq 0) { $compileSucceeded = $true; break }
        if ($cAttempt -eq 1) {
            log 'Compile attempt 1 failed; patching _commit conflict in GES and retrying...'
            # Reactive by design: -FIio.h declares the CRT `_commit`, which can collide
            # with ges-validate.c's own `_commit` validate-action. There is NO collision
            # in gstreamer 1.29.2, so this path stays DORMANT insurance for a future
            # clang / io.h / gstreamer combination. Not dead code.
            $gesValidate = Join-Path $gstSrcDir 'subprojects/gst-editing-services/ges/ges-validate.c'
            $gesPatch = Join-Path $scriptAssetRoot 'patches\gstreamer\001-ges-commit-rename.patch'
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

    Switch-BuildPhase '8. install'
    # ---- 8. install ----
    log 'Installing GStreamer...'
    # CROSS LANE: install with DESTDIR set, to the SAME location. A post-install
    # script that cannot run aborts the whole install, and gio-querymodules would
    # have to EXECUTE an aarch64 binary on this x64 host; DESTDIR is meson's
    # "staged/packaging install, do not run target binaries" signal.
    # 'C:\' is chosen because meson's destdir_join drops the drive from the second
    # path, so every installed path is byte-identical to the non-DESTDIR one.
    # amd64 keeps the plain invocation: there every install script CAN run.
    $installArgs = @('install', '-C', $resolvedBuildDir)
    if ($script:GstCross) {
        $installArgs += @('--destdir', 'C:\')
        log 'meson install --destdir C:\ (cross lane: makes meson SKIP install scripts that would have to run target binaries; the path is unchanged - see the comment above)'
    }
    & $mesonExe @installArgs 2>&1 | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'meson install failed' }
    log 'Installation complete.'

    # OpenSSL RUNTIME for the target (cross lane only, #127): the link resolves the
    # import libs but nothing installed the DLLs, so hls/dtls/aes and gio's TLS
    # module shipped importing libcrypto-4-arm64.dll that existed nowhere in the
    # bundle. amd64 resolves scoop's x64 OpenSSL from the image PATH -- an
    # image-level fact a bundle on a clean device cannot rely on.
    if ($script:GstCross) {
        $sslRuntimeRoot = 'C:\opt\openssl-arm64'
        $sslDlls = @(Get-ChildItem -Path $sslRuntimeRoot -Recurse -File -Include 'libcrypto-*.dll', 'libssl-*.dll' -ErrorAction SilentlyContinue)
        if ($sslDlls.Count -eq 0) {
            throw "OpenSSL runtime DLLs (libcrypto-*/libssl-*) not found under $sslRuntimeRoot -- the hls/dtls/aes plugins and gio's TLS module would import a DLL the bundle does not carry (#127)"
        }
        # The package carries each DLL several times; one per name is staged, the
        # copy under a \bin directory preferred, so log and bundle agree.
        $sslByName = @{}
        foreach ($dll in ($sslDlls | Sort-Object { if ($_.DirectoryName -match '\\bin$') { 0 } else { 1 } }, FullName)) {
            if (-not $sslByName.ContainsKey($dll.Name.ToLowerInvariant())) { $sslByName[$dll.Name.ToLowerInvariant()] = $dll }
        }
        $sslWant = Get-PeMachineType -Arch $script:GstTargetArch
        $sslBinDir = Join-Path $resolvedInstallDir 'bin'
        New-Item -Path $sslBinDir -ItemType Directory -Force | Out-Null
        foreach ($dll in @($sslByName.Values | Sort-Object Name)) {
            $m = Get-PeFileMachine -Path $dll.FullName
            if ($m -ne $sslWant) { throw ('OpenSSL runtime {0} is machine 0x{1:X4}, expected 0x{2:X4} -- refusing to stage a wrong-arch DLL into the bundle' -f $dll.FullName, $m, $sslWant) }
            Copy-Item -Path $dll.FullName -Destination (Join-Path $sslBinDir $dll.Name) -Force
        }
        log ("OpenSSL ($($script:GstTargetArch)): staged {0} runtime DLL(s) into {1} ({2} candidate file(s) in the package): {3}" -f $sslByName.Count, $sslBinDir, $sslDlls.Count, (@($sslByName.Values | Sort-Object Name | ForEach-Object { "$($_.Name) <- $($_.DirectoryName)" }) -join '; '))
    }

    Switch-BuildPhase '9. verify (plugin + pc gates)'
    # ---- 9. verify ----
    $gstLaunch = Join-Path $resolvedInstallDir 'bin\gst-launch-1.0.exe'
    if (Test-Path $gstLaunch) {
        log "Verification OK: $gstLaunch"
    } else {
        log "WARNING: gst-launch-1.0.exe not found at expected path: $gstLaunch"
        log 'Build may have completed but binaries may be elsewhere. Check logs.'
    }

    # ---- 8b. MANDATORY PLUGIN GATE (fatal) ───────────────────────────────────
    # A missing stage artifact is a THROW, not a warning (docs/windows-build-invariants.md),
    # and a plugin the media stack is built around is one -- logging "[INFO] not
    # available" here is how a shipped image ended up without opencv and libav.
    # SEPARATE from the meson feature flags on purpose: `enabled` only proves the
    # dependency was found at configure time; gst-inspect proves what the image USES.
    $gstInspect = Join-Path $resolvedInstallDir 'bin\gst-inspect-1.0.exe'
    if (-not (Test-Path $gstInspect)) {
        throw "gst-inspect-1.0.exe missing at $gstInspect — cannot verify the mandatory plugin set."
    }
    $missingPlugins = @()
    # Make every media DLL home searchable for the load probe: the image's runtime
    # PATH listed ONNX under \lib while onnxruntime.dll + DirectML.dll ship in \bin,
    # so onnx failed to load. Mirror the full set so the gate reflects the image.
    foreach ($d in @('C:\runtime\cuda-runtime\bin', "$env:ONNX_ROOT\bin", "$env:ONNX_GENAI_ROOT\bin", $env:FFMPEG_BIN,
            $env:OPENCV_BIN, $env:LITERT_BIN, $env:GSTREAMER_BIN, "$env:TVM_ROOT\bin", $env:IREE_BIN)) {
        if ($d -and (Test-Path $d) -and (($env:PATH -split ';') -notcontains $d)) { $env:PATH = "$d;$env:PATH" }
    }
    # Force a FRESH registry scan against the (now-complete) PATH so a stale
    # blacklist from an earlier partial-PATH scan cannot mask a real fix.
    $gstPluginDir = Join-Path $resolvedInstallDir 'lib\gstreamer-1.0'
    $prevGstDebug = $env:GST_DEBUG
    $prevGstReg = $env:GST_REGISTRY
    $env:GST_REGISTRY = Join-Path $env:TEMP_DIR 'gst-registry-verify.bin'
    Remove-Item $env:GST_REGISTRY -Force -ErrorAction SilentlyContinue
    $env:GST_DEBUG = 'GST_REGISTRY:4,GST_PLUGIN_LOADING:4'
    # HOST tool -- deliberately NOT Get-MsvcTargetBinDir: dumpbin only READS the
    # built DLLs (/dependents is machine-type agnostic) and must itself RUN on the
    # amd64 build host. Retargeting could resolve to NOTHING, since the VC.Tools.ARM64
    # component is only warn-gated in the shared base.
    $dumpbin = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    $dllSearchDirs = @($gstPluginDir) + @($env:PATH -split ';' | Where-Object { $_ }) + @("$env:SystemRoot\System32")
    # Recursively resolve a DLL's dependency tree and return the names that resolve
    # nowhere. api-ms-win-* / ext-ms-win-* are virtual API sets, never "missing".
    function Get-UnresolvedDeps {
        param($DllPath, $Dumpbin, $SearchDirs, $Seen)
        $missing = [System.Collections.Generic.List[string]]::new()
        $deps = @(& $Dumpbin /dependents $DllPath 2>&1 | Select-String '^\s{4,}(\S+\.dll)' | ForEach-Object { $_.Matches.Groups[1].Value })
        foreach ($dep in $deps) {
            if ($dep -match '^(api|ext)-ms-') { continue }   # virtual API sets (loader-resolved)
            if ($Seen.Contains($dep.ToLower())) { continue }
            [void]$Seen.Add($dep.ToLower())
            $hit = $SearchDirs | Where-Object { $_ -and (Test-Path (Join-Path $_ $dep)) } | Select-Object -First 1
            if (-not $hit) { $missing.Add($dep) }
            # Do NOT recurse into OS DLLs: their deep OneCore deps are absent on
            # Server Core but loader-tolerated -- noise. Only walk OUR DLLs.
            elseif ($hit -notmatch '[\\/](System32|SysWOW64|WinSxS)([\\/]|$)') {
                foreach ($m in (Get-UnresolvedDeps (Join-Path $hit $dep) $Dumpbin $SearchDirs $Seen)) { $missing.Add($m) }
            }
        }
        return $missing
    }
    # CROSS LANE: gst-inspect-1.0.exe is an aarch64 binary and cannot RUN on this x64
    # host, but "the DLL exists" is weaker than what this host can verify. Static
    # checks that DO run: a dumpbin /dependents tree walk (catches the 0xC0000135
    # class the old filename glob waved through) and a dumpbin /exports check for the
    # plugin's own marker. The MACHINE check stays Test-TargetArch.ps1's job.
    if ($script:GstCross) {
        foreach ($plugin in @(Get-RequiredGstPlugin -Arch $script:GstTargetArch)) {
            $pluginDll = Get-ChildItem -Path $gstPluginDir -Filter "gst*$($plugin.Name)*.dll" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $pluginDll) {
                log "  [FAIL] mandatory GStreamer plugin '$($plugin.Name)' produced NO DLL in $gstPluginDir — $($plugin.Why)"
                $missingPlugins += $plugin
                continue
            }
            $staticProblems = @()
            if ($dumpbin) {
                $unresolved = @(Get-UnresolvedDeps $pluginDll.FullName $dumpbin $dllSearchDirs ([System.Collections.Generic.HashSet[string]]::new())) | Select-Object -Unique
                if ($unresolved) { $staticProblems += ($unresolved | ForEach-Object { "unresolved dependency: $_" }) }
                # Export marker, MEASURED: modern GStreamer (>= 1.14 per-plugin
                # registration) exports gst_plugin_<name>_get_desc, not the legacy
                # gst_plugin_desc -- asserting the latter failed all four plugins,
                # three of them proven loadable on amd64.
                $exports = @(& $dumpbin /exports $pluginDll.FullName 2>&1)
                $marker = "gst_plugin_$($plugin.Name)_get_desc"
                if (-not ($exports -match [regex]::Escape($marker))) {
                    $exportNames = @($exports | Select-String '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)' |
                        ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 6)
                    $staticProblems += "$marker export missing (exports seen: $($exportNames -join ', '))"
                }
            } else {
                # A gate that verified NOTHING must not report PASS: dumpbin is the
                # x64 host tool every other stage depends on, so its absence is a
                # broken environment, not an optional check. On the cross lane this
                # IS the plugin proof.
                $staticProblems += "dumpbin.exe not found under any VC\Tools\MSVC\*\bin\Hostx64\x64 -- the dependency and export checks could not run, so nothing about this plugin was verified beyond the file existing"
            }
            if ($staticProblems.Count -eq 0) {
                log "  [PASS] mandatory GStreamer plugin '$($plugin.Name)' built: $($pluginDll.Name) (cross lane - deps resolve, gst_plugin_$($plugin.Name)_get_desc exported; load probe impossible on an x64 host)"
            } else {
                $staticProblems | ForEach-Object { log "    $_" }
                log "  [FAIL] mandatory GStreamer plugin '$($plugin.Name)' built but statically broken — $($plugin.Why)"
                $missingPlugins += $plugin
            }
        }
    } else {
    foreach ($plugin in @(Get-RequiredGstPlugin -Arch $script:GstTargetArch)) {
        $global:LASTEXITCODE = 0
        $null = & $gstInspect $plugin.Name 2>&1
        if ($LASTEXITCODE -eq 0) {
            log "  [PASS] mandatory GStreamer plugin '$($plugin.Name)' present ($($plugin.Provides))"
        } else {
            log "  [FAIL] mandatory GStreamer plugin '$($plugin.Name)' MISSING — $($plugin.Why)"
            $pluginDll = Get-ChildItem -Path $gstPluginDir -Filter "gst*$($plugin.Name)*.dll" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pluginDll) {
                log "    load-probing $($pluginDll.Name) directly:"
                & $gstInspect $pluginDll.FullName 2>&1 |
                    Where-Object { $_ -match 'load|dll|error|fail|blacklist|symbol|module|cannot|Failed' } |
                    Select-Object -Last 4 | ForEach-Object { if ($_) { log "      $_" } }
                # Name the actual unresolved DLL(s) anywhere in the dependency tree.
                if ($dumpbin) {
                    $unresolved = @(Get-UnresolvedDeps $pluginDll.FullName $dumpbin $dllSearchDirs ([System.Collections.Generic.HashSet[string]]::new())) | Select-Object -Unique
                    if ($unresolved) { $unresolved | ForEach-Object { log "      unresolved dependency (tree): $_" } }
                    else { log '      (all non-API-set deps resolve; failure may be a delay-load or DllMain init error)' }
                }
            } else {
                log "    (no gst*$($plugin.Name)*.dll found in $gstPluginDir)"
            }
            $missingPlugins += $plugin
        }
    }
    }
    if ($null -ne $prevGstDebug) { $env:GST_DEBUG = $prevGstDebug } else { Remove-Item Env:\GST_DEBUG -ErrorAction SilentlyContinue }
    if ($null -ne $prevGstReg) { $env:GST_REGISTRY = $prevGstReg } else { Remove-Item Env:\GST_REGISTRY -ErrorAction SilentlyContinue }
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
        log "All $(@(Get-RequiredGstPlugin -Arch $script:GstTargetArch).Count) mandatory GStreamer plugins verified present."
    }

    Switch-BuildPhase '10. cleanup'
    # ---- 10. cleanup ----
    if (-not $KeepBuildArtifacts.IsPresent -and $env:KEEP_BUILD_ARTIFACTS -ne '1') {
        log 'Cleaning up source and build directories...'
        Remove-SourceBuildTree -Path @($gstSrcDir, $resolvedBuildDir)
    }

    # This script is not chain-run (no Invoke-SourceBuildChain tail), so dump
    # the sccache counters itself — they die with the container otherwise.
    Write-SccacheStats -Label 'gstreamer'
    # ... and flush/stop the session server the #128 prologue started (the
    # error-log dump only means something after a clean server stop, #107).
    Complete-SccacheServerSession

    Complete-CurrentBuildPhase
    Write-BuildPhaseSummary -Label 'gstreamer'

    log 'END - GStreamer source build completed successfully.'

} catch {
    # #109: name the phase in the failure - a 60-min meson run once died
    # with a bare message; the phase table narrows it before the stack.
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'gstreamer'
    # Flush/stop the #128 session server on the FAILURE path too -- the error-log
    # dump only means something after a clean stop, and the failing run is exactly
    # the one whose log you want.
    try { Complete-SccacheServerSession } catch { Write-Warning "sccache session flush failed in catch: $($_.Exception.Message)" }
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

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0
