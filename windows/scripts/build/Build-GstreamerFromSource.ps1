# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

<#
.SYNOPSIS
    Build GStreamer from source on Windows using Meson with clang-cl.

.DESCRIPTION
    Builds the GStreamer monorepo via Meson wraps from the GitHub release tarball,
    compiling with clang-cl against the Visual Studio SDK.

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
    # Scrub scratch inside this process: this script is its own additive layer in the BK lane.
    [switch]$ScrubAfter,
    [string[]]$MesonSetupArgs  = @(),
    # Skips the mandatory-plugin contract; an image built with it is not shippable.
    [switch]$SkipPluginGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Imports first; shared assets sit beside this script in the flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedPath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedPath)) { throw "Required module not found: $sharedPath" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($sharedPath)))) { Import-Module $sharedPath }

$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

# Separate on purpose: only the merge builder mounts it, so contract edits spare the media compile RUNs.
$gstPluginModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
if (-not (Test-Path $gstPluginModule)) { throw "Required module not found: $gstPluginModule" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($gstPluginModule)))) { Import-Module $gstPluginModule }

$sourceBuildModule = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Test-Path $sourceBuildModule)) { throw "Required module not found: $sourceBuildModule" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($sourceBuildModule)))) { Import-Module $sourceBuildModule }
# G2's gate: modules\ in the repo, a per-file mount under ortmods\ in the container (never the shared closure).
$ortGateModule = @('modules', 'ortmods') | ForEach-Object { Join-Path $scriptAssetRoot $_ 'WindowsOrtProvenance.Build.psm1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
Import-Module ($ortGateModule ?? $(throw 'WindowsOrtProvenance.Build.psm1 (the G2 ORT gate) is not mounted')) -DisableNameChecking

# Merge-lane leaf modules: do not fold them into WindowsSourceBuild.Common, which every media RUN mounts.
foreach ($leafModule in @('WindowsMeson.Common.psm1', 'WindowsRustToolchain.Common.psm1')) {
    $leafPath = Join-Path $scriptAssetRoot "modules\$leafModule"
    if (-not (Test-Path $leafPath)) { throw "Required module not found: $leafPath" }
    if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($leafPath)))) { Import-Module $leafPath }
}

# Resolved once, up front: five decisions far apart in this file depend on it.
$script:GstTargetArch = Get-WindowsTargetArch
$script:GstCross      = Test-WindowsCrossTarget -Arch $script:GstTargetArch

$InstallDir = Initialize-SourceBuildEnvironment -InstallDir $InstallDir

# ---- logging ----
$logContext = New-StructuredLogContext -LogDir $LogDir -Prefix 'gst-source-build'
Start-StructuredLogging -Context $logContext

function log($text) {
    Write-StructuredLogEntry -Context $logContext -Text $text
}

# rocm lane only; hip's `enabled` cannot fail setup at 1.29.2, so Get-GstRocmMissingArtifact backs all four.
function Get-GstRocmMesonArgs {
    param([Parameter(Mandatory)][hashtable]$GpuEnv)
    if (-not $GpuEnv.HasRocm) { return @() }
    return @('-Dgst-plugins-bad:hip=enabled', '-Dgst-plugins-bad:amfcodec=enabled',
        '-Dgst-plugins-bad:d3d11=enabled', '-Dgst-plugins-bad:d3d12=enabled')
}

# Upstream 17d22abe89's bio_method_read hunk: OpenSSL 4 takes a 0-byte read as EOF, so an empty BIO must signal retry.
function ConvertTo-GstDtlsRetryRead {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return [regex]::Replace($Text, 'GST_LOG_OBJECT \(self, "BIO: EOF"\);(\r?\n)([ \t]*)return 0;',
        'GST_LOG_OBJECT (self, "BIO: no data available, retry later");$1$2BIO_set_retry_read (bio);$1$2return -1;', 1)
}

# `enabled` makes a lost gdkpixbuf plugin fail setup; cross has no build-machine glib-compile-resources. docs/windows-cross-builds.md
function Get-GstGdkPixbufMesonArgs {
    param([switch]$Cross)
    if ($Cross) { return @() }
    return @('-Dgst-plugins-good:gdk-pixbuf=enabled', '-Dgdk-pixbuf:man=false',
        '-Dgdk-pixbuf:tests=false', '-Dgdk-pixbuf:introspection=disabled')
}

# Per search-path variable meson or its cmake probe reads, the entries under the ROCm root; only changed variables.
function Get-GstRocmScrubbedSearchPath {
    param(
        [Parameter(Mandatory)][string]$RocmRoot,
        [hashtable]$Environment = $null,
        [string[]]$Name = @('PATH', 'PKG_CONFIG_PATH', 'PKG_CONFIG_LIBDIR', 'CMAKE_PREFIX_PATH', 'CMAKE_INCLUDE_PATH',
            'CMAKE_LIBRARY_PATH', 'CMAKE_PROGRAM_PATH', 'INCLUDE', 'LIB')
    )
    if ($null -eq $Environment) {
        $Environment = @{}
        Get-ChildItem Env: | Where-Object Name -In $Name | ForEach-Object { $Environment[$_.Name] = $_.Value }
    }
    # A trailing '\' on both sides makes "is the root or under it" one prefix test.
    $prefix = ($RocmRoot.Trim('"') -replace '/', '\').TrimEnd('\') + '\'
    $result = [ordered]@{}
    foreach ($var in @($Environment.Keys | Sort-Object)) {
        $entries = "$($Environment[$var])".Split(';', [StringSplitOptions]::RemoveEmptyEntries)
        $removed = @($entries | Where-Object { (($_.Trim('"') -replace '/', '\').TrimEnd('\') + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
        if ($removed.Count -eq 0) { continue }
        $result[$var] = [pscustomobject]@{ Value = (@($entries | Where-Object { $removed -notcontains $_ }) -join ';'); Removed = $removed }
    }
    return $result
}

# The proof for the scrub above: any mention of the ROCm tree in the configured build is a finding.
function Get-GstRocmLeakFinding {
    param(
        [Parameter(Mandatory)][string]$RocmRoot,
        [Parameter(Mandatory)][string[]]$Path
    )
    $root = ($RocmRoot.Trim('"') -replace '/', '\').TrimEnd('\')
    $needles = @($root, ($root -replace '\\', '/'), ($root -replace '\\', '\\'))
    foreach ($file in $Path) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { "$file is missing, so nothing proves the ROCm tree stayed out"; continue }
        foreach ($hit in @(Select-String -LiteralPath $file -SimpleMatch -Pattern $needles | Select-Object -First 3)) {
            $line = $hit.Line.Trim()
            "$($hit.Filename):$($hit.LineNumber) names the ROCm tree: $($line.Substring(0, [Math]::Min(240, $line.Length)))"
        }
    }
}

# An emptied variable is removed: pkg-config reads an empty PKG_CONFIG_LIBDIR as "no default dirs".
function Set-GstRocmIsolation {
    param([Parameter(Mandatory)][string]$RocmRoot)
    $scrub = Get-GstRocmScrubbedSearchPath -RocmRoot $RocmRoot
    foreach ($name in @($scrub.Keys)) {
        if ($scrub[$name].Value) { [Environment]::SetEnvironmentVariable($name, $scrub[$name].Value) }
        else { [Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
    }
    return $scrub
}

# Gives PATH its ROCm entries back, LAST as in the image; an empty scrub (cpu/nvidia) changes nothing.
function Restore-GstRocmPath {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Scrub)
    if (-not $Scrub.Contains('PATH')) { return }
    $env:PATH = (@($env:PATH -split ';' | Where-Object { $_ }) + @($Scrub['PATH'].Removed)) -join ';'
}

# rocm lane, after install: what a lost AMD path left out (bin\gsthip-0.dll is the library gsthip.dll imports).
function Get-GstRocmMissingArtifact {
    param([Parameter(Mandatory)][string]$InstallDir)
    $plugins = foreach ($p in 'gsthip', 'gstamfcodec', 'gstd3d11', 'gstd3d12') { "lib\gstreamer-1.0\$p.dll" }
    foreach ($rel in @('bin\gsthip-0.dll') + $plugins) {
        if (-not [System.IO.File]::Exists((Join-Path $InstallDir $rel))) { $rel }
    }
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
    $resolvedInstallDir = Resolve-DirectoryPath -Path $InstallDir
    $resolvedSrcDir     = Resolve-DirectoryPath -Path $SourceDir
    $resolvedBuildDir   = Resolve-DirectoryPath -Path $BuildDir
    $resolvedLogDir     = Resolve-DirectoryPath -Path $LogDir

    Switch-BuildPhase '2. Meson via source CPython'
    # pip is bootstrapped here: the media branches build in parallel, so no other script's order can be assumed.
    log 'Using source-built CPython from toolchain layer...'
    $py = Initialize-ToolchainPythonEnvironment
    $pyExe = $py.Exe
    if (-not (Test-Path $pyExe)) { throw "Source-built Python not found at $pyExe" }
    log "Using Python: $pyExe"
    Install-CpythonPip -Python $py

    # Pinned: the build-subproject fixes below match meson's source by regex, and a floating meson moves under them.
    $mesonPin = [string]$env:PY_MESON_VERSION
    if ([string]::IsNullOrWhiteSpace($mesonPin)) { throw 'PY_MESON_VERSION is not set (versions.env not loaded?) -- refusing an unpinned meson' }
    log "Installing Meson $mesonPin via pip..."
    $pipLog = Join-Path $resolvedLogDir 'pip-install.log'
    & cmd.exe /c """$pyExe"" -m pip install meson==$mesonPin > ""$pipLog"" 2>&1"
    $pipExit = $LASTEXITCODE
    Get-Content $pipLog | ForEach-Object { if ($_) { log $_ } }
    # Fail here, not later as a misleading 'meson.exe not found'.
    if ($pipExit -ne 0) { throw "pip install meson failed (exit $pipExit) -- see $pipLog (logged above)" }

    # The in-tree PCbuild layout puts console scripts under the source root, not beside python.exe.
    $findMesonScripts = {
        $dir = (cmd.exe /c """$pyExe"" -c ""import sysconfig; print(sysconfig.get_path('scripts'))""" | Select-Object -First 1)
        if ($dir) { $dir = "$dir".Trim() }
        if ($dir -and (Test-Path (Join-Path $dir 'meson.exe'))) { return $dir }
        @(
            (Join-Path (Split-Path $pyExe -Parent) 'Scripts'),
            (Join-Path $env:TEMP_DIR 'cpython\Scripts')
        ) | Where-Object { Test-Path (Join-Path $_ 'meson.exe') } | Select-Object -First 1
    }
    $pythonScripts = & $findMesonScripts
    # The merge copies media-core's site-packages without their Scripts dir: pip finds meson installed and writes no meson.exe.
    if (-not $pythonScripts) {
        log 'meson is installed but meson.exe is missing; reinstalling it to regenerate the launcher...'
        & cmd.exe /c """$pyExe"" -m pip install --force-reinstall --no-deps meson==$mesonPin >> ""$pipLog"" 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "pip reinstall of meson failed (exit $LASTEXITCODE) -- see $pipLog" }
        $pythonScripts = & $findMesonScripts
    }
    if (-not $pythonScripts) { throw 'meson.exe not found after pip install' }
    $mesonExe = Join-Path $pythonScripts 'meson.exe'
    $env:PATH = "$pythonScripts;$env:PATH"
    $mesonVer = & $mesonExe --version 2>&1 | Select-Object -First 1
    log "Meson version: $mesonVer"

    # meson 1.12.0 build-subproject fixes, found via the module so a moved site-packages cannot skip them.
    $mesonInterp = (cmd.exe /c """$pyExe"" -c ""import mesonbuild.interpreter.interpreter as m; print(m.__file__)""" | Select-Object -First 1)
    if ($mesonInterp) { $mesonInterp = "$mesonInterp".Trim() }
    if (-not $mesonInterp -or -not (Test-Path $mesonInterp)) {
        throw "mesonbuild.interpreter.interpreter is not importable from $pyExe (got '$mesonInterp') -- cannot apply the build-subproject fixes"
    }
    [void](Invoke-MesonBuildSubprojectPatch -InterpreterPath $mesonInterp)

    Switch-BuildPhase '3. clang-cl toolchain + sccache'
    log 'Setting CC/CXX to clang-cl...'
    $env:CC  = 'clang-cl'
    $env:CXX = 'clang-cl'
    $clangCheck = Get-Command 'clang-cl' -ErrorAction SilentlyContinue
    if (-not $clangCheck) {
        throw 'clang-cl not found on PATH. Ensure LLVM/Clang is installed.'
    }
    log "clang-cl found at: $($clangCheck.Source)"

    # Outside Invoke-SourceBuildChain, so start the server here; remote backend only, a local cache dies with the layer.
    Start-SccacheServerSession
    if ((Test-SccacheRemoteConfigured) -and (Get-Command sccache.exe -ErrorAction SilentlyContinue)) {
        if (-not $env:SCCACHE_MAX_JOBS) { $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString() }
        $env:CC  = 'sccache clang-cl'
        $env:CXX = 'sccache clang-cl'
        log "sccache enabled for meson (remote backend, max $env:SCCACHE_MAX_JOBS jobs)"
    } else {
        log 'sccache disabled (no remote backend configured or sccache.exe missing)'
    }

    # Scoped to this ephemeral container's meson subproject fetches; Invoke-GitClone never forces it.
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_SSL_NO_VERIFY = '1'
    # meson's urllib wrap fetches verify TLS against a CA store this CPython lacks.
    $env:PYTHONHTTPSVERIFY = '0'

    # Early presence-only fan-in check: fails in seconds, before any download; the full pre-flight below owns the .pc files.
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
    # The wrap and libffi fetches below stay on cmd/curl: bulk extraction is a different per-item flow.
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
    # Require a meson.build: with -KeepBuildArtifacts a stale sibling could win a name-prefix match.
    $gstDirs = @(Get-ChildItem -Path $resolvedSrcDir -Directory -Filter 'gstreamer*' |
        Where-Object { Test-Path (Join-Path $_.FullName 'meson.build') })
    if ($gstDirs.Count -ge 1) {
        $gstSrcDir = $gstDirs[0].FullName
        log "Source root: $gstSrcDir"
    } elseif ( -not (Test-Path (Join-Path $gstSrcDir 'meson.build'))) {
        throw "Could not find GStreamer source with meson.build in $resolvedSrcDir"
    }
    log 'Extraction complete.'

    # git-init so Invoke-SourcePatch takes its git-apply fast path.
    Initialize-ExtractedGitRepo -Path $gstSrcDir

    Switch-BuildPhase '5. wrap prefetch + meson fixups'
    # $libffiVer stays in this file: SourceBuild.PinParity finds the pin site by file name.
    $libffiVer = if ($env:LIBFFI_MESON_VERSION) { $env:LIBFFI_MESON_VERSION } else { '3.2.9999.4' }
    $subprojDir = Join-Path $gstSrcDir 'subprojects'
    # @(): the helper comma-wraps, but an empty result must still expose .Count.
    $wrapFailures = @(Invoke-GstWrapProvisioning -SubprojectDir $subprojDir -TempDir $resolvedLogDir `
        -LibffiVersion $libffiVer -Logger { param($m) log $m })

    # Fail closed on any wrap loss: the helper's retries already absorbed transient blips.
    if ($wrapFailures.Count -gt 0) {
        throw ("GStreamer subproject provisioning failed for $($wrapFailures.Count) wrap(s): " +
            ($wrapFailures -join ' | ') +
            ' — refusing to build a feature-reduced GStreamer (backlog #88).')
    }

    # Delete every remaining [wrap-git] wrap tree-wide: git clone fails inside Windows containers.
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
    # Instead of a bare -FIio.h on cross: meson hands c_args to aarch64 .S files too, which cannot parse a C header.
    $ioShim = Join-Path $stubDir 'gst-io-shim.h'
    if (-not (Test-Path $ioShim)) {
        '#pragma once
/* See Build-GstreamerFromSource.ps1: meson passes c_args to .S files too. */
#ifndef __ASSEMBLER__
#include <io.h>
#endif' | Out-File -FilePath $ioShim -Encoding ASCII
        log "Created io.h force-include shim at $ioShim (assembly-safe)"
    }

    # Pre-place win-pkgconfig, the one subproject meson fetches with no retry; failure only warns, meson still tries.
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
                # LAN preseed first, since retries do not help against a sustained outage; an upstream hit seeds it back.
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

    # Get-GpuEnvironment also sets CUDA_PATH/CUDA_HOME and prepends CUDA bin to PATH.
    $gpuEnv = Get-GpuEnvironment
    if ($gpuEnv.HasCuda) {
        log "CUDA detected at: $($gpuEnv.CudaRoot)"
    } else {
        log 'CUDA not detected -- nvcodec/cuda plugins will be auto-detected by Meson'
    }
    # rocm lane: TheRock stays invisible to pre-flight, setup, compile and install; phase 9 gets PATH back.
    $rocmScrub = [ordered]@{}
    if ($gpuEnv.HasRocm) {
        $rocmScrub = Set-GstRocmIsolation -RocmRoot $gpuEnv.RocmRoot
        foreach ($name in @($rocmScrub.Keys)) { log "ROCm isolation: $name no longer lists $($rocmScrub[$name].Removed -join ';')" }
        log "ROCm lane ($($gpuEnv.RocmRoot)): meson pins $((Get-GstRocmMesonArgs -GpuEnv $gpuEnv) -join ' ')"
    }

    # compiler-rt for lld-link (__udivti3 & co), found via clang-cl on PATH rather than a scoop layout.
    $clangClCmd = Get-Command 'clang-cl' -ErrorAction SilentlyContinue
    $llvmRoot = if ($clangClCmd) { Split-Path (Split-Path $clangClCmd.Source) } else { Join-Path $env:USERPROFILE 'scoop\apps\llvm\current' }
    # Target-filtered on both lanes: LLVM ships one builtins lib per target, and an arch-blind pick once linked arm64 into amd64.
    $rtCandidates = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter '*builtins*.lib' -ErrorAction SilentlyContinue)
    $wantRt = (Get-ClangTargetTriple -Arch $script:GstTargetArch) -replace '-.*$', ''   # x86_64/aarch64-pc-windows-msvc -> x86_64/aarch64
    $rtCandidates = @($rtCandidates | Where-Object { $_.Name -match [regex]::Escape($wantRt) })
    if ($script:GstCross) {
        if ($rtCandidates.Count -eq 0) {
            # SELF-HEAL: the source-built toolchain ships host builtins only, when the toolchain stage has not staged them.
            $rtHostLib = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter 'clang_rt.builtins-x86_64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($rtHostLib.Count -gt 0) {
                $rtVer = Get-SourceBuildVersion -EnvironmentVariables @('LLVM_WINDOWS_VERSION') -DefaultValue '23.1.3'
                $rtUrl = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$rtVer/clang%2Bllvm-$rtVer-aarch64-pc-windows-msvc.tar.xz"
                try {
                    log "Fetching aarch64 compiler-rt (LLVM $rtVer) - the patched toolchain ships x86_64 builtins only"
                    $rtStaged = Install-AArch64CompilerRt -Url $rtUrl -DestinationDir $rtHostLib[0].Directory.FullName `
                        -LibName 'clang_rt.builtins-aarch64.lib' `
                        -ExpectedSha256 ([string]$env:LLVM_WINDOWS_AARCH64_RT_SHA256) -WorkDir $resolvedLogDir
                    log "Installed aarch64 compiler-rt -> $rtStaged"
                } catch {
                    Write-Warning "aarch64 compiler-rt fetch failed: $($_.Exception.Message)"
                }
                $rtCandidates = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter '*builtins*.lib' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match [regex]::Escape($wantRt) })
            }
        }
        if ($rtCandidates.Count -eq 0) {
            # WARN, do not throw: amd64 tolerates absence too, and lld-link then names the missing __udivti3 precisely.
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

    # The Vulkan import lib must match the target; LIB is searched in order, so prepending the arch dir is enough.
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

    # lld-link does not auto-pull the COM/DirectShow/MF/KS GUIDs link.exe gets from uuid.lib; unused ones are not pulled.
    $guidLibs = @(
        'uuid.lib', 'mfuuid.lib', 'strmiids.lib', 'ksuser.lib', 'dxguid.lib',
        'dmoguids.lib', 'wmcodecdspuuid.lib', 'mfplat.lib', 'mf.lib', 'mfreadwrite.lib'
    )
    # meson links through the compiler driver, which defaults to the host triple, so link args need --target too.
    $gstTargetArch = $script:GstTargetArch   # resolved once at the top of this script
    $gstCrossArg = if ($script:GstCross) { "--target=$(Get-ClangTargetTriple -Arch $gstTargetArch)" } else { '' }
    # Never /FORCE:MULTIPLE: it once let libffi link a zeroed type table; see docs/windows-builds.md § libffi's type exports.
    $linkArgElems = ((@($gstCrossArg, $rtFullPath) + $guidLibs) |
        Where-Object { $_ } | ForEach-Object { "'$_'" }) -join ','
    log "Link args: [$linkArgElems]"

    # mediafoundation lacks GstWinRt's msvc guard, so under clang-cl it demands a GstWinRt that is never built.
    $mfMeson = Join-Path $gstSrcDir 'subprojects\gst-plugins-bad\sys\mediafoundation\meson.build'
    [void](Edit-SourceFile -Path $mfMeson -Marker "if runtimeobject_lib\.found\(\) and cxx\.get_id\(\) == 'msvc'" `
            -Description 'mediafoundation meson.build: gate winapi_app detection on msvc (clang-cl builds desktop path only)' `
            -WarnMessage 'mediafoundation winapi_app guard not found; mediafoundation=enabled may fail if GstWinRt is unavailable under clang-cl' `
            -Transform {
            param($mfContent)
            [regex]::Replace($mfContent, "if runtimeobject_lib\.found\(\)(\s*\r?\n)", "if runtimeobject_lib.found() and cxx.get_id() == 'msvc'`$1", 1)
        })

    # Upstream 17d22abe89, until GSTREAMER_VERSION moves past 1.29.2: see docs/windows-builds.md § DTLS with OpenSSL 4.
    $dtlsConn = Join-Path $gstSrcDir 'subprojects\gst-plugins-bad\ext\dtls\gstdtlsconnection.c'
    $dtlsPatched = Edit-SourceFile -Path $dtlsConn -Require -Marker ([regex]::Escape('BIO: no data available, retry later')) `
        -Description 'gstdtlsconnection.c: an empty BIO read signals retry, not EOF (upstream 17d22abe89)' `
        -Transform { param($dtlsContent) ConvertTo-GstDtlsRetryRead -Text $dtlsContent }
    if (-not [System.IO.File]::ReadAllText($dtlsConn).Contains('BIO: no data available, retry later')) {
        throw ("gstdtlsconnection.c: the OpenSSL 4 BIO fix (upstream 17d22abe89) neither applied nor is upstream. Without it " +
            "every DTLS handshake fails with 'unexpected eof while reading', so WebRTC carries no media. Re-check $dtlsConn.")
    }
    if (-not $dtlsPatched) { log 'gstdtlsconnection.c already carries upstream 17d22abe89; retire the DTLS patch.' }

    # c++11 pins become c++17: VS 18's MSVC STL uses C++14 constructs that clang-cl rejects in C++11 mode.
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

    # The opencv plugin targets OpenCV 4; OpenCV 5 moved the same APIs to new headers, so add those.
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
        # The Windows CRT has no POSIX ftello/fseeko.
        $c = $c -replace '\bftello\b', '_ftelli64' -replace '\bfseeko\b', '_fseeki64'
        if ($c -ne $orig) { [System.IO.File]::WriteAllText($_.FullName, $c); $ocvPortPatched++; log "OpenCV5 port -> $($_.Name)" }
    }
    log "OpenCV 5 header port applied to $ocvPortPatched gst ext/opencv file(s)"
    # gst hardcodes Linux's unversioned -lopencv_tracking; opencv4.pc already brings the versioned Windows lib.
    $ocvMeson = Join-Path $ocvExtDir 'meson.build'
    if (Test-Path $ocvMeson) {
        $mc = [System.IO.File]::ReadAllText($ocvMeson)
        $mc2 = $mc -replace "\s*,\s*'-lopencv_tracking'", '' -replace "'-lopencv_tracking'\s*,\s*", '' -replace "'-lopencv_tracking'", ''
        if ($mc2 -ne $mc) { [System.IO.File]::WriteAllText($ocvMeson, $mc2); log 'Removed hardcoded -lopencv_tracking from ext/opencv/meson.build (opencv4.pc provides the versioned lib)' }
    }

    # Mandatory plugin pre-flight; .pc files authored here spare the costly OpenCV/ORT layers. See docs/windows-builds.md § Mandatory GStreamer plugins (the contract)
    $requiredPlugins = @(Get-RequiredGstPlugin -Arch $script:GstTargetArch)
    # Declared before the branch: the meson args interpolate it and StrictMode faults on an undefined variable.
    $script:TfliteIncludeArg = ''
    if ($SkipPluginGate) {
        log 'WARNING: -SkipPluginGate — the mandatory GStreamer plugin contract is DISABLED for this build.'
        log "WARNING: the resulting image is NOT shippable. Required set: $(($requiredPlugins | ForEach-Object { $_.Name }) -join ', ')"
    } else {
        log '--- mandatory plugin pre-flight ---'

        # opencv4.pc — describes the OpenCV 5 install under $OPENCV_ROOT.
        $ocvRoot = if ($env:OPENCV_ROOT) { $env:OPENCV_ROOT } else { Join-Path $resolvedInstallDir 'lib\opencv5' }
        # The <arch> in <root>\<arch>\vc18 moves with the target, so it comes from the arch table.
        $ocvLib = if ($env:OPENCV_LIB) { $env:OPENCV_LIB } else { Join-Path $ocvRoot "$(Get-OpenCvArchDir)\vc18\lib" }
        # Found, not assumed: OpenCV's Windows layout moved between majors, and a wrong guess compiles nothing.
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
        # gst needs share\opencv4 under the prefix, which pkgconf relocates from the .pc location: create it under each candidate.
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
        # Same env-name order as Build-OnnxFromSource.ps1, or a standalone run writes a stale version into the .pc.
        $ortVersion = Get-SourceBuildVersion -Value '' -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.30.0' -StripVPrefix
        # Some layouts put ORT's headers under include\onnxruntime\core\session too.
        $ortIncludes = @($ortInclude, (Join-Path $ortInclude 'onnxruntime'),
            (Join-Path $ortInclude 'onnxruntime\core\session')) | Where-Object { Test-Path $_ }
        [void](Write-PkgConfigFile -Name 'libonnxruntime' -Version $ortVersion `
                -Description 'ONNX Runtime (source build; ships no pkg-config file of its own)' `
                -IncludeDir $ortIncludes -LibDir $ortLib -Library @('onnxruntime') `
                -PkgConfigDir (Join-Path $ortLib 'pkgconfig'))

        # Target OpenSSL on cross: scoop's is host-only; its layout is searched, and upstream .pc files win if shipped.
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
            # Found, not composed: innounp extracts under a literal {app} directory.
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
                # Plugins ask for libcrypto, libssl or the umbrella openssl.
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

        # OpenSSL's dirs first, over the image's x64 openssl.pc; @() + @() because '+' binds tighter than ','.
        $newPcDirs = @($sslPcDirs) + @((Join-Path $ocvLib 'pkgconfig'), (Join-Path $ortLib 'pkgconfig'))
        $env:PKG_CONFIG_PATH = (@($newPcDirs + ($env:PKG_CONFIG_PATH -split ';' | Where-Object { $_ })) | Select-Object -Unique) -join ';'
        log "PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH"

        # Disable FFmpeg.wrap so libav* resolve from our FFmpeg, not the wrap's pinned 7.1.1.
        $ffmpegWrap = Join-Path $gstSrcDir 'subprojects\FFmpeg.wrap'
        if (Test-Path $ffmpegWrap) {
            Move-Item -Path $ffmpegWrap -Destination "$ffmpegWrap.disabled" -Force
            log 'Disabled subprojects/FFmpeg.wrap — gst-libav must link the FFmpeg this image ships, not a wrap-pinned 7.1.1.'
        }

        # Keyed on the fanned-in tensorflowlite_c.lib, not the lane: an older LiteRT-less cross core disables with a reason.
        $script:GstTfliteLibDir = if ($env:LITERT_LIB) { $env:LITERT_LIB } else { Join-Path $resolvedInstallDir 'lib\litert\lib' }
        $script:GstTfliteAvailable = (-not $script:GstCross) -or (Test-Path (Join-Path $script:GstTfliteLibDir 'tensorflowlite_c.lib'))
        if (-not $script:GstTfliteAvailable) {
            log ("tflite integration skipped: no tensorflowlite_c.lib in $script:GstTfliteLibDir -- this cross image " +
                 'predates the #115 LiteRT cross build (or media-litert was not fanned in). The meson feature is set ' +
                 'to disabled EXPLICITLY below, never auto.')
        } else {
            # tflite skips pkg-config and probes the pre-rename tensorflow/lite path, so mirror LiteRT's tflite\ headers there.
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
    
            # If neither link name exists, say what is there: this plugin never consults PKG_CONFIG_PATH.
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
    
            # INCLUDE/LIB, not a /LIBPATH: c_link_arg, which clang-cl reads as an input file and fails meson's sanity check.
            $env:INCLUDE = (@($litertInclude) + @($env:INCLUDE -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
            $env:LIB = (@($litertLib) + @($env:LIB -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
            # Forward slashes: meson parses escape sequences in its array literals.
            $script:TfliteIncludeArg = '-I' + ($litertInclude -replace '\\', '/')
            log "INCLUDE += $litertInclude ; LIB += $litertLib"
        }

        # Everything the required set needs must resolve NOW, not after an hour.
        $pcModules = @($requiredPlugins | Where-Object { $_.Detection -eq 'pkg-config' } |
                ForEach-Object { $_.NeedsPc } | Select-Object -Unique)
        # Upstream's version floors: a .pc with `Version: ..` passes --exists but fails every constraint.
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

    # gst-plugins-base's msvc branch sets have_sse/have_sse2 on aarch64; extend have_sse41's cpu_family guard to them.
    if ($script:GstCross) {
        $gstBaseMeson = Join-Path $gstSrcDir 'subprojects/gst-plugins-base/meson.build'
        if (-not (Test-Path $gstBaseMeson)) {
            log "NOTE: $gstBaseMeson not found - skipping the x86 SIMD guard (layout changed?)"
        } elseif ((Get-Content -LiteralPath $gstBaseMeson -Raw) -match "cpu_family\(\) in \['x86'") {
            log 'gst-plugins-base x86 SIMD guard already applied.'
        } else {
            # 'have_sse2?' cannot match have_sse41: the '4' fails the '\s*=' that follows.
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

    # vulkan/meson.build picks its lib dir from build_machine via `dirs:`, which LIB order cannot override; key it on host.
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
    # Only a cross file makes host_machine differ; it lives in the log dir, which survives the retry's build-dir wipe.
    $mesonCrossArgs = @()
    if (Test-WindowsCrossTarget -Arch $gstTargetArch) {
        $gstTriple = Get-ClangTargetTriple -Arch $gstTargetArch
        # A missing mapping throws: a wrong cpu_family configures green and builds x86-shaped.
        $gstCpuFamily = switch ($gstTargetArch) {
            'arm64' { 'aarch64' }
            default { throw "build-gstreamer: no meson cpu_family mapping for target arch '$gstTargetArch' - add one before building it." }
        }
        # --target in the exelist: meson derives the linker's and archiver's /MACHINE from `<exelist> --version`.
        $ccList = (((($env:CC -split '\s+') | Where-Object { $_ }) + @("--target=$gstTriple")) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        $cxxList = (((($env:CXX -split '\s+') | Where-Object { $_ }) + @("--target=$gstTriple")) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        # Target rust (for gst-ptp-helper) is proven first: a failing rust entry fails setup, an absent one skips the helper.
        $rustTargetLine = ''
        $rustTriple = Get-RustTargetTriple -Arch $gstTargetArch
        $rustup = (Get-Command rustup -ErrorAction SilentlyContinue).Source
        $rustc = (Get-Command rustc -ErrorAction SilentlyContinue).Source
        if ($rustup -and $rustc) {
            # The image's rustup mirror is gone, so fetch the rust-std its cached manifest names; the probe below decides.
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
        # A native file gives the build machine its compilers; without one the build-machine glib fallback and webrtc/nice die.
        $nccList = ((($env:CC -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        $ncxxList = ((($env:CXX -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        # LIB names the target's dirs; /vctoolsdir: and /winsdkdir: pick the arch from /machine:, unlike /LIBPATH under clang-cl.
        $vcToolsDir = $null; $winSdkDir = $null; $winSdkVer = $null
        foreach ($entry in @(($env:LIB -split ';') | Where-Object { $_ })) {
            if (-not $vcToolsDir -and $entry -match '^(.*\\VC\\Tools\\MSVC\\[^\\]+)\\+lib\\') { $vcToolsDir = $Matches[1] }
            if (-not $winSdkDir -and $entry -match '^(.*\\Windows Kits\\10)\\+lib\\+([^\\]+)\\+(um|ucrt)\\') { $winSdkDir = $Matches[1]; $winSdkVer = $Matches[2] }
        }
        if (-not $vcToolsDir) { $vcToolsDir = Get-MsvcToolsRoot }
        # libffi finds cl/ml64 on PATH, which VsDevCmd -arch=arm64 leads with ARM64-targeting tools; [binaries] wins over PATH.
        $buildCl   = Resolve-BuildMachineMsvcTool -VcToolsDir $vcToolsDir -Name 'cl.exe'
        $buildMl64 = Resolve-BuildMachineMsvcTool -VcToolsDir $vcToolsDir -Name 'ml64.exe'
        $buildLinkArgList = @()
        if ($vcToolsDir -and (Test-Path $vcToolsDir)) { $buildLinkArgList += "/vctoolsdir:$($vcToolsDir -replace '\\', '/')" }
        if ($winSdkDir -and (Test-Path $winSdkDir)) {
            $buildLinkArgList += "/winsdkdir:$($winSdkDir -replace '\\', '/')"
            if ($winSdkVer) { $buildLinkArgList += "/winsdkversion:$winSdkVer" }
        }
        $buildLibDirs = $buildLinkArgList
        $buildLinkArgs = (($buildLinkArgList | ForEach-Object { "'" + $_ + "'" }) -join ', ')
        # The build machine links its own ffi-7.dll (a default target) from the same ffi.h, so it needs -fcommon too.
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
c_args = ['-fcommon']
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
        # The monorepo defaults to debugoptimized, which ships GLib with its debug checks on.
        '-Dbuildtype=release',
        # meson keeps assert() in release builds; if-release defines NDEBUG in every subproject.
        '-Db_ndebug=if-release',
        # `enabled`, never `auto`: auto skips a plugin silently when its dependency is missing.
        '-Dgpl=enabled',
        '-Dbase=enabled',
        '-Dgood=enabled',
        '-Dugly=enabled',
        '-Dbad=enabled',
        '-Dges=enabled',
        '-Drtsp_server=enabled',
        '-Dtools=enabled',
        # tflite's has_header probe uses the C compiler for C++ sources; -Wno-undef: graphene tests __GNUC__ under -Werror; -fcommon: see docs/windows-builds.md § libffi's type exports.
        "-Dc_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg $ioFI -Disatty=_isatty -Dfileno=_fileno -Dclose=_close -Dwrite=_write -DSTDOUT_FILENO=1 -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types -Wno-undef -fcommon$(if ($gstCrossArg) { " $gstCrossArg" })",
        "-Dcpp_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg $ioFI -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types$(if ($gstCrossArg) { " $gstCrossArg" })",
        # mediafoundation (mfvideosrc) is what the Rust capture path uses; it needs the GUID libs above.
        '-Dgst-plugins-bad:mediafoundation=enabled',
        # wasapi v1 needs Core Audio GUIDs no SDK import lib carries; wasapi2 is built by default.
        '-Dgst-plugins-bad:wasapi=disabled',
        # graphene's MSVC path calls SSE4.1 intrinsics without a target-feature guard, which clang-cl refuses.
        '-Dgraphene:sse2=false',
        # SVT-JPEG-XS does not compile under clang-cl.
        '-Dgst-plugins-bad:svtjpegxs=disabled',
        # cairo:win32 crashes clang-cl (LLVM 22 mmintrin.h __builtin_shufflevector).
        '-Dcairo:win32=disabled',
        # x86 crashes clang-cl and aarch64 RTCD needs MSVC's __emit; intrinsics=enabled + rtcd=disabled is the recipe (docs/windows-cross-builds.md).
        '-Dopus:intrinsics=disabled',
        # gstnvdecoder.cpp needs gst-d3d11 headers clang-cl cannot find; the CUDA gst-lib is detected separately.
        '-Dgst-plugins-bad:nvcodec=disabled',
        # A Rust dev tool whose crates.io index fetch fails in the offline container.
        '-Dgst-devtools:dots-viewer=disabled',
        "-Dc_link_args=[$linkArgElems]",
        "-Dcpp_link_args=[$linkArgElems]"
    ) + $(
        # The mandatory contract, behind the same switch as the pre-flight.
        if ($SkipPluginGate) { @() } else {
            @(
                '-Dlibav=enabled',
                '-Dgst-plugins-bad:opencv=enabled',
                '-Dgst-plugins-bad:onnx=enabled',
                # Never auto, which would half-configure against an empty LiteRT tree; the artifact decides.
                $(if ($script:GstTfliteAvailable) { '-Dgst-plugins-bad:tflite=enabled' } else { '-Dgst-plugins-bad:tflite=disabled' })
            ) + @(
                # Meson-native contract entries (webrtc, nice), each enabled so a missing libnice fails setup.
                $requiredPlugins | Where-Object { $_.Detection -eq 'meson' } | ForEach-Object { "-D$($_.MesonOption)=enabled" }
            )
        }
    ) + @(Get-GstGdkPixbufMesonArgs -Cross:$script:GstCross) + @(
        # -Dtests=disabled covers GStreamer's modules only; glib is a wrap.
        '-Dglib:tests=false'
    ) + @(Get-GstRocmMesonArgs -GpuEnv $gpuEnv) + $mesonCrossArgs + $MesonSetupArgs

    $setupArgsString = "meson $($setupArgs -join ' ')"
    $mesonSucceeded = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        log "Running meson setup (attempt $attempt/2)..."
        log $setupArgsString
        # Only stdout to a file: native stderr becomes a terminating ErrorRecord under EAP=Stop.
        $outFile = Join-Path $resolvedLogDir "meson-setup-$attempt-out.txt"
        & $mesonExe @setupArgs > $outFile
        $mesonExitCode = $LASTEXITCODE
        $mesonOut = if (Test-Path $outFile) { @(Get-Content $outFile) } else { @() }
        $mesonOut | ForEach-Object { if ($_) { log $_ } }
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        if ($mesonExitCode -eq 0) { $mesonSucceeded = $true; break }

        # The real compiler error lives in meson-log.txt; dump it before the attempt-1 cleanup wipes the build dir.
        $mesonLog = Join-Path $resolvedBuildDir 'meson-logs\meson-log.txt'
        $mesonLogLines = @()
        if (Test-Path $mesonLog) {
            $mesonLogLines = @(Get-Content $mesonLog)
            # An excerpt; the retry classification below still scans every line.
            $excerpt = Select-MesonLogExcerpt -Lines $mesonLogLines
            log "---- meson-log.txt excerpt (attempt $attempt, exit $mesonExitCode): $($excerpt.Total) lines; $($excerpt.DiagnosticTotal) diagnostic line(s), showing $($excerpt.Diagnostics.Count) with line numbers + the last $($excerpt.Tail.Count); full file: $mesonLog ----"
            $excerpt.Diagnostics | ForEach-Object { log $_ }
            log "---- meson-log.txt tail (last $($excerpt.Tail.Count) lines) ----"
            $excerpt.Tail | ForEach-Object { if ($_) { log $_ } }
            log '---- end meson-log.txt ----'
        } else {
            log "meson-log.txt not found at $mesonLog"
        }

        # A deterministic configure error fails identically on retry, so retry only transient failures.
        $failureClass = Get-MesonSetupFailureClass -Output @($mesonOut) -LogLines $mesonLogLines
        $hardError = $failureClass.HardError
        # A failed subproject download looks the same but is transient, so a network signature is retried anyway.
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
    if ($gpuEnv.HasRocm) {
        $rocmLeaks = @(Get-GstRocmLeakFinding -RocmRoot $gpuEnv.RocmRoot -Path @(
                (Join-Path $resolvedBuildDir 'build.ninja'), (Join-Path $resolvedBuildDir 'meson-info\intro-dependencies.json')))
        if ($rocmLeaks.Count -gt 0) { throw "ROCm tree leaked into the GStreamer configure: $($rocmLeaks -join ' | ')" }
        log 'ROCm isolation proven: build.ninja and intro-dependencies.json never name the ROCm tree.'
    }

    # Inline, as the wrap version floats: MSVC's __m256 union members do not exist in clang-cl, which subscripts directly.
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

    # Inline, as FFmpeg master floats: it removed codec IDs gst-libav still excludes; R210 on the V410 line stays.
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

    # graphene appends -Werror=undef after our c_args, so its bare `#if __GNUC__` dies under clang-cl.
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
    # Explicit -j, or ninja ignores MEMORY_LIMIT_GB; the stall guard stops a wedged sccache hanging the merge.
    $gstJobs = Get-BuildJobCount -MemGBPerJob 2
    log "meson compile with -j $gstJobs (MEMORY_LIMIT_GB='$env:MEMORY_LIMIT_GB', cores=$([Environment]::ProcessorCount))"
    $compileSucceeded = $false
    for ($cAttempt = 1; $cAttempt -le 2; $cAttempt++) {
        log "Compiling GStreamer (attempt $cAttempt/2, may take 30-60 min)..."
        $gstStallGuard = Start-SccacheStallGuard -MarkerPath (Join-Path $resolvedLogDir 'gstreamer-stall-guard.marker')
        try {
            # After a version bump, sweep host-arch links with `--ninja-args=-k,0` (one token: argparse refuses a leading '-').
            & $mesonExe compile -C $resolvedBuildDir -j $gstJobs 2>&1 | ForEach-Object { if ($_) { log $_ } }
        } finally {
            Stop-SccacheStallGuard -Guard $gstStallGuard
        }
        if ($LASTEXITCODE -eq 0) { $compileSucceeded = $true; break }
        if ($cAttempt -eq 1) {
            log 'Compile attempt 1 failed; patching _commit conflict in GES and retrying...'
            # Dormant insurance, not dead code: -FIio.h's CRT `_commit` can collide with ges-validate.c's own.
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
    log 'Installing GStreamer...'
    # Cross: DESTDIR C:\ skips install scripts that would run aarch64 binaries, and destdir_join keeps paths unchanged.
    $installArgs = @('install', '-C', $resolvedBuildDir)
    if ($script:GstCross) {
        $installArgs += @('--destdir', 'C:\')
        log 'meson install --destdir C:\ (cross lane: makes meson SKIP install scripts that would have to run target binaries; the path is unchanged - see the comment above)'
    }
    & $mesonExe @installArgs 2>&1 | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'meson install failed' }
    log 'Installation complete.'

    # Stage the target OpenSSL DLLs on both lanes: nothing else installs them, and neither a bundle nor the image's PATH carries them.
    $sslRuntimeRoot = if ($script:GstCross) { 'C:\opt\openssl-arm64' } else { [string]$env:OPENSSL_ROOT_DIR }
    if ([string]::IsNullOrWhiteSpace($sslRuntimeRoot)) { throw 'OPENSSL_ROOT_DIR is unset, so the OpenSSL runtime gstdtls.dll imports cannot be staged beside it' }
    $sslDlls = @(Get-ChildItem -Path $sslRuntimeRoot -Recurse -File -Include 'libcrypto-*.dll', 'libssl-*.dll' -ErrorAction SilentlyContinue)
    if ($sslDlls.Count -eq 0) {
        throw "OpenSSL runtime DLLs (libcrypto-*/libssl-*) not found under $sslRuntimeRoot -- the hls/dtls/aes plugins and gio's TLS module would import a DLL the bundle does not carry (#127)"
    }
    # One copy per name, preferring \bin, so log and bundle agree.
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

    if ($gpuEnv.HasRocm) {
        $rocmMissing = @(Get-GstRocmMissingArtifact -InstallDir $resolvedInstallDir)
        if ($rocmMissing.Count -gt 0) { throw "rocm lane: meson install left out $($rocmMissing -join ', ') under $resolvedInstallDir" }
        log 'ROCm lane: gsthip (+ gsthip-0.dll), amfcodec, d3d11 and d3d12 are installed.'
    }
    # The gate scans plugins the way the image loads them, so it gets TheRock's bin back (last, as in the image).
    Restore-GstRocmPath -Scrub $rocmScrub

    Switch-BuildPhase '8b. gst-plugins-rs (cargo)'
    # The tag and plain cargo build the Linux lane uses; see docs/windows-builds.md § gst-plugins-rs on Windows.
    $rsSrcDir = Join-Path $resolvedSrcDir 'gst-plugins-rs'
    $rsPluginDir = Join-Path $resolvedInstallDir 'lib\gstreamer-1.0'
    $rsPlan = Get-GstRustCargoPlan -Plugin $requiredPlugins -Arch $script:GstTargetArch -Jobs $gstJobs `
        -TargetDir (Join-Path $resolvedBuildDir 'gst-plugins-rs-target') -PkgConfigDir (Join-Path $resolvedInstallDir 'lib\pkgconfig')
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
    # Only caches this run creates, so the cleanup never whites out a lower layer's bytes.
    $rsCargoScratch = @(@('registry', 'git') | ForEach-Object { Join-Path $cargoHome $_ } | Where-Object { -not (Test-Path $_) })
    # TLS stays verified for this fetch and cargo's: the no-verify above exists for meson's wrap fetches alone.
    $rsEnv = [ordered]@{ GIT_SSL_NO_VERIFY = $null }
    foreach ($k in $rsPlan.Env.Keys) { $rsEnv[$k] = $rsPlan.Env[$k] }
    $rsSaved = @{}
    foreach ($k in $rsEnv.Keys) {
        $rsSaved[$k] = [Environment]::GetEnvironmentVariable($k)
        if ($null -eq $rsEnv[$k]) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, $rsEnv[$k]) }
    }
    try {
        [void](Invoke-GitClone -RepoUrl 'https://github.com/GStreamer/gst-plugins-rs.git' -Tag "gstreamer-$GstVersion" -SourceDir $rsSrcDir)
        $rsSources = Join-Path $resolvedBuildDir 'gst-plugins-rs-sources.toml'
        New-Item -ItemType Directory -Force -Path $resolvedBuildDir | Out-Null
        Set-Content -Path $rsSources -Encoding ASCII -Value (Get-GstRustSourceMirrorConfig -CargoLock ([System.IO.File]::ReadAllText((Join-Path $rsSrcDir 'Cargo.lock'))))
        $rsArgs = @($rsPlan.Args) + @('--config', $rsSources)
        log "cargo $($rsArgs -join ' ')  (env: $(@($rsPlan.Env.Keys | ForEach-Object { "$_=$($rsPlan.Env[$_])" }) -join ' '))"
        Get-Content $rsSources | ForEach-Object { if ($_) { log "  sources| $_" } }
        Push-Location $rsSrcDir
        try {
            $global:LASTEXITCODE = 0
            & cargo @rsArgs 2>&1 | ForEach-Object { if ($_) { log "  cargo| $_" } }
            $cargoExit = $LASTEXITCODE
        } finally { Pop-Location }
    } finally {
        # A $null restore must remove: see docs/windows-build-invariants.md § Four more pwsh traps (d).
        foreach ($k in $rsSaved.Keys) {
            if ($null -eq $rsSaved[$k]) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, $rsSaved[$k]) }
        }
    }
    $rsMissing = @()
    if ($cargoExit -ne 0) {
        $rsMissing += "cargo exited $cargoExit"
    } else {
        $rsWant = Get-PeMachineType -Arch $script:GstTargetArch
        foreach ($dll in $rsPlan.Dlls) {
            if (-not (Test-Path $dll.Path)) { $rsMissing += "$($dll.File) not built at $($dll.Path)"; continue }
            $rsMachine = Get-PeFileMachine -Path $dll.Path
            if ($rsMachine -ne $rsWant) { $rsMissing += ('{0} is machine 0x{1:X4}, expected 0x{2:X4}' -f $dll.File, $rsMachine, $rsWant); continue }
            Copy-Item -Path $dll.Path -Destination (Join-Path $rsPluginDir $dll.File) -Force
            log "gst-plugins-rs: installed $($dll.File) ($([math]::Round((Get-Item $dll.Path).Length / 1MB, 1)) MB) into $rsPluginDir"
        }
    }
    if ($rsMissing.Count -gt 0) {
        $rsWhy = "gst-plugins-rs ($(@($rsPlan.Dlls | ForEach-Object { $_.Name }) -join ', ')): $($rsMissing -join '; ')"
        if ($SkipPluginGate) { log "WARNING: $rsWhy -- -SkipPluginGate was passed, so the image is NOT shippable" }
        else { throw "$rsWhy. These are mandatory contract plugins; the cargo output above names the failing crate." }
    }

    Switch-BuildPhase '9. verify (plugin + pc gates)'
    $gstLaunch = Join-Path $resolvedInstallDir 'bin\gst-launch-1.0.exe'
    if (Test-Path $gstLaunch) {
        log "Verification OK: $gstLaunch"
    } else {
        log "WARNING: gst-launch-1.0.exe not found at expected path: $gstLaunch"
        log 'Build may have completed but binaries may be elsewhere. Check logs.'
    }

    # A static read, so it holds on the cross lane too, where nothing that uses libffi can run.
    $ffiDll = @(Get-ChildItem -Path (Join-Path $resolvedInstallDir 'bin') -Filter 'ffi-*.dll' -File -ErrorAction SilentlyContinue)
    if ($ffiDll.Count -ne 1) { throw "expected exactly one ffi-*.dll in $resolvedInstallDir\bin (gobject imports it), found $($ffiDll.Count)" }
    log (Assert-LibffiTypeExport -Path $ffiDll[0].FullName)

    # Mandatory plugin gate, fatal: `enabled` proves configure found a dependency, gst-inspect that the plugin loads.
    $gstInspect = Join-Path $resolvedInstallDir 'bin\gst-inspect-1.0.exe'
    if (-not (Test-Path $gstInspect)) {
        throw "gst-inspect-1.0.exe missing at $gstInspect — cannot verify the mandatory plugin set."
    }
    $missingPlugins = @()
    # Every media DLL home on PATH, mirroring the image, so the load probe sees what the image sees.
    foreach ($d in @('C:\runtime\cuda-runtime\bin', "$env:ONNX_ROOT\bin", "$env:ONNX_GENAI_ROOT\bin", $env:FFMPEG_BIN,
            $env:OPENCV_BIN, $env:LITERT_BIN, $env:GSTREAMER_BIN, "$env:TVM_ROOT\bin", $env:IREE_BIN)) {
        if ($d -and (Test-Path $d) -and (($env:PATH -split ';') -notcontains $d)) { $env:PATH = "$d;$env:PATH" }
    }
    # A fresh registry scan, so a stale blacklist from a partial-PATH scan cannot mask a fix.
    $gstPluginDir = Join-Path $resolvedInstallDir 'lib\gstreamer-1.0'
    $prevGstDebug = $env:GST_DEBUG
    $prevGstReg = $env:GST_REGISTRY
    $env:GST_REGISTRY = Join-Path $env:TEMP_DIR 'gst-registry-verify.bin'
    Remove-Item $env:GST_REGISTRY -Force -ErrorAction SilentlyContinue
    $env:GST_DEBUG = 'GST_REGISTRY:4,GST_PLUGIN_LOADING:4'
    # The host dumpbin, not Get-MsvcTargetBinDir: it only reads the DLLs and must run here.
    $dumpbin = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    $dllSearchDirs = @($gstPluginDir) + @($env:PATH -split ';' | Where-Object { $_ }) + @("$env:SystemRoot\System32")
    # The names in a DLL's dependency tree that resolve nowhere.
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
            # Not into OS DLLs: their OneCore deps are absent on Server Core but loader-tolerated.
            elseif ($hit -notmatch '[\\/](System32|SysWOW64|WinSxS)([\\/]|$)') {
                foreach ($m in (Get-UnresolvedDeps (Join-Path $hit $dep) $Dumpbin $SearchDirs $Seen)) { $missing.Add($m) }
            }
        }
        return $missing
    }
    # Cross cannot run gst-inspect, so check statically: dependency tree walk and export marker (machine: Test-TargetArch.ps1).
    if ($script:GstCross) {
        foreach ($plugin in @(Get-RequiredGstPlugin -Arch $script:GstTargetArch)) {
            # The exact file name: a gst*webrtc*.dll wildcard also matches gstrswebrtc.dll and gstwebrtcdsp.dll.
            $pluginDll = Get-Item -LiteralPath (Join-Path $gstPluginDir "gst$($plugin.Name).dll") -ErrorAction SilentlyContinue
            if (-not $pluginDll) {
                log "  [FAIL] mandatory GStreamer plugin '$($plugin.Name)' produced NO DLL in $gstPluginDir — $($plugin.Why)"
                $missingPlugins += $plugin
                continue
            }
            $staticProblems = @()
            if ($dumpbin) {
                $unresolved = @(Get-UnresolvedDeps $pluginDll.FullName $dumpbin $dllSearchDirs ([System.Collections.Generic.HashSet[string]]::new())) | Select-Object -Unique
                if ($unresolved) { $staticProblems += ($unresolved | ForEach-Object { "unresolved dependency: $_" }) }
                # GStreamer >= 1.14 exports gst_plugin_<name>_get_desc, not the legacy gst_plugin_desc.
                $exports = @(& $dumpbin /exports $pluginDll.FullName 2>&1)
                $marker = "gst_plugin_$($plugin.Name)_get_desc"
                if (-not ($exports -match [regex]::Escape($marker))) {
                    $exportNames = @($exports | Select-String '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)' |
                        ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 6)
                    $staticProblems += "$marker export missing (exports seen: $($exportNames -join ', '))"
                }
            } else {
                # A gate that verified nothing must not pass: on cross, dumpbin is the whole plugin proof.
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
            $pluginDll = Get-Item -LiteralPath (Join-Path $gstPluginDir "gst$($plugin.Name).dll") -ErrorAction SilentlyContinue
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
                log "    (no gst$($plugin.Name).dll in $gstPluginDir)"
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

    # G2: the onnx plugin's trees, build.ninja, meson's dependency record and log hold the chain ORT only; a pass stamps it.
    Assert-ChainOrtOnly -Consumer 'gstreamer' -OrtRoot $(if ($env:ONNX_ROOT) { $env:ONNX_ROOT } else { Join-Path $resolvedInstallDir 'lib\onnxruntime-source' }) `
        -TreeRoot $gstSrcDir, $resolvedBuildDir -Log (Join-Path $resolvedBuildDir 'meson-logs\meson-log.txt') `
        -Record (Join-Path $resolvedBuildDir 'build.ninja'), (Join-Path $resolvedBuildDir 'meson-info\intro-dependencies.json')

    Switch-BuildPhase '10. cleanup'
    if (-not $KeepBuildArtifacts.IsPresent -and $env:KEEP_BUILD_ARTIFACTS -ne '1') {
        log 'Cleaning up source and build directories...'
        Remove-SourceBuildTree -Path (@($gstSrcDir, $resolvedBuildDir, $rsSrcDir) + $rsCargoScratch)
    }

    # Not chain-run, so dump the sccache counters here; they die with the container otherwise.
    Write-SccacheStats -Label 'gstreamer'
    # The error-log dump only means something after a clean server stop.
    Complete-SccacheServerSession

    Complete-CurrentBuildPhase
    Write-BuildPhaseSummary -Label 'gstreamer'

    log 'END - GStreamer source build completed successfully.'

} catch {
    # Name the failing phase before the stack.
    Complete-CurrentBuildPhase -ErrorRecord $_
    Write-BuildPhaseSummary -Label 'gstreamer'
    # Stop the server on failure too: the failing run is the one whose error log you want.
    try { Complete-SccacheServerSession } catch { Write-Warning "sccache session flush failed in catch: $($_.Exception.Message)" }
    log "FATAL ERROR: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        log "Inner: $($_.Exception.InnerException.Message)"
    }
    # Position and stack, or an hour-long run dies with a bare message.
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
