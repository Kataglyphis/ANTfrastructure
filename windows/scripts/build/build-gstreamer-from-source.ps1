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
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedPath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedPath)) { throw "Required module not found: $sharedPath" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($sharedPath)))) { Import-Module $sharedPath }

$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

# The mandatory-plugin contract + pkg-config emitter. A separate module ON
# PURPOSE: it is mounted by the merge builder only, so editing the plugin
# contract cannot invalidate the six media compile RUNs that mount the other
# five modules (see Dockerfile.media-merge-builder's buildmods comment).
$gstPluginModule = Join-Path $scriptAssetRoot 'modules\WindowsGstPlugins.Common.psm1'
if (-not (Test-Path $gstPluginModule)) { throw "Required module not found: $gstPluginModule" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($gstPluginModule)))) { Import-Module $gstPluginModule }

$sourceBuildModule = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Test-Path $sourceBuildModule)) { throw "Required module not found: $sourceBuildModule" }
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($sourceBuildModule)))) { Import-Module $sourceBuildModule }

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
function Invoke-WrapDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$Description = ''
    )
    # freedesktop/videolan GitLab sit behind the Anubis anti-scraper: browser
    # User-Agents without JS get an HTML challenge page, plain curl UAs pass.
    # The shared Invoke-DownloadWithRetry sends a browser UA (right for the
    # CDNs it serves) - on verify10 it "downloaded" 7 challenge pages and the
    # #88 gate refused them all (correctly, but for the wrong-looking reason:
    # "extraction failed"). Verified 2026-08-17: same URL, browser UA = 7.5 KB
    # HTML, curl UA = 400 KB BZh. So wraps go through curl.exe with its native
    # UA + a magic-byte check. Deliberately NOT a Shared.psm1 change: the
    # module is frozen mid-chain (an edit there busts every media stage cache).
    $label = if ($Description) { $Description } else { $Url }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        # --fail: 4xx/5xx exit non-zero instead of saving the error body.
        $curlOut = & curl.exe --fail --location --silent --show-error --connect-timeout 30 -o $DestinationPath $Url 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $DestinationPath) -and (Get-Item $DestinationPath).Length -ge 3) {
            $head = [byte[]](Get-Content -Path $DestinationPath -AsByteStream -TotalCount 3)
            $isGzip  = ($head[0] -eq 0x1f -and $head[1] -eq 0x8b)
            $isBzip2 = ($head[0] -eq 0x42 -and $head[1] -eq 0x5a -and $head[2] -eq 0x68)  # 'BZh'
            if ($isGzip -or $isBzip2) { return }
            log "attempt ${attempt}: $label returned non-archive bytes ($($head -join ' ')) - likely an HTML challenge/error page"
        } else {
            log "attempt ${attempt}: curl exit $LASTEXITCODE for $label - $curlOut"
        }
        Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
        if ($attempt -lt 4) { Start-Sleep -Seconds (3 * $attempt) }
    }
    throw "download failed after 4 attempts: $label"
}

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

    Switch-BuildPhase '1. resolve directories'
    # ---- 1. resolve directories ----
    $resolvedInstallDir = Resolve-DirectoryPath -Path $InstallDir
    $resolvedSrcDir     = Resolve-DirectoryPath -Path $SourceDir
    $resolvedBuildDir   = Resolve-DirectoryPath -Path $BuildDir
    $resolvedLogDir     = Resolve-DirectoryPath -Path $LogDir

    Switch-BuildPhase '2. Meson via source CPython'
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

    # sccache: meson honors a space-separated launcher in CC/CXX (unlike the
    # cmake builders, which use CMAKE_*_COMPILER_LAUNCHER). Until 2026-08-04
    # this build ran completely uncached (~30 min hot) — the merge builder
    # simply never wired the endpoint through. Same gate as everywhere else:
    # remote backend only; a container-local cache would die with the layer.
    # #128 (2026-08-21): this script runs OUTSIDE Invoke-SourceBuildChain (the
    # merge stage invokes it directly), so it never got the chain prologue's
    # fresh-server guarantee — without it the implicitly-started server may
    # not have read SCCACHE_ERROR_LOG (#97) and the epilogue flush means
    # nothing. Same call the chain makes, safe no-op without sccache.
    Start-SccacheServerSession
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
    # meson downloads [wrap-file] subprojects (pango, theora, libgudev, ...) with
    # Python's urllib, which verifies TLS against a CA store the source-built
    # CPython in this image does not ship -> "CERTIFICATE_VERIFY_FAILED: unable to
    # get local issuer certificate", so every wrap fetch burns its full retry/delay
    # budget before falling back. PYTHONHTTPSVERIFY=0 disables that verification for
    # this ephemeral build container's wrap fetches only (same trust-boundary
    # reasoning as GIT_SSL_NO_VERIFY above); it both unblocks the downloads and cuts
    # the multi-minute retry stalls out of `meson setup`.
    $env:PYTHONHTTPSVERIFY = '0'

    # ---- 3b. EARLY fan-in fast-fail (backlog #66) ----------------------------
    # The full "must resolve NOW" pre-flight further down authors .pc files and
    # computes meson args, so it stays where its outputs are consumed — but its
    # own comment promised "NOW, not after an hour" while it ran AFTER the
    # tarball, ~20 wrap downloads and five patch loops. These existence checks
    # mirror the artifacts that gate actually requires and depend on NOTHING
    # downloaded here: a missing media fan-in now fails in seconds, not after
    # the whole provisioning phase. Deliberately presence-only — version floors
    # and .pc semantics remain the full gate's job.
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

    Switch-BuildPhase '5. wrap prefetch + meson fixups'
    # ---- 5. pre-extract all wrap-git subprojects via tarball ----
    # Failures are COLLECTED and become fatal after the loop (backlog #88): the
    # 2026-08-14 chain logged 22 failed wrap downloads as warnings and went
    # GREEN — gst-plugins-base ×15, theora ×5, pango ×2 — shipping a
    # feature-reduced image nobody noticed. Only the four mandatory plugins were
    # gated; every other codec was silently "optional". The fetch also ran as
    # `curl ... 2>nul`, discarding the one line that distinguishes a moved wrap
    # revision (404) from a DNS/TLS problem. Now: Invoke-WrapDownload (curl-UA
    # + magic-byte check — NOT the shared helper, whose browser UA gets Anubis
    # challenge pages) + visible errors + fail-closed summary.
    $wrapFailures = @()
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
            # Build tarball URL. Strip .git in BOTH branches: GitLab answers
            # .git-in-path /-/archive/ URLs with an HTML page instead of the
            # tarball (verify11: libdv.git = 17 KB HTML, libdv = 421 KB BZh) -
            # only the GitHub branch ever stripped it.
            $base = $url -replace '\.git$', ''
            if ($url -match 'github\.com') {
                $tarballUrl = "$base/archive/$rev.tar.gz"
            } else {
                $tarballUrl = "$base/-/archive/$rev/$dir-$rev.tar.bz2"
            }
            $tmp = Join-Path $resolvedLogDir "$dir-$rev.tar"
            $tmpFile = "$tmp.gz"; if ($tarballUrl -match '\.bz2$') { $tmpFile = "$tmp.bz2" }
            log "Pre-extracting $fname..."
            try {
                Invoke-WrapDownload -Url $tarballUrl -DestinationPath $tmpFile -Description "gst wrap $fname ($rev)"
                if (Expand-SubprojectArchive -Archive $tmpFile -Target $target) {
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    log "Pre-extracted $fname to $target"
                } else {
                    $script:wrapFailures += "$fname (downloaded but extraction into $dir failed)"
                }
            } catch {
                # Real error text KEPT (was `2>nul`): a 404 on a moved revision
                # and a TLS failure need different fixes.
                $script:wrapFailures += "$fname : $($_.Exception.Message)"
                log "ERROR: wrap download failed: $fname - $($_.Exception.Message)"
            }
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
    # libffi through the same helper + failure collection (#88). It is glib's
    # hard dependency — a miss here never was "optional", it just looked so.
    $libffiTarget = Join-Path $subprojDir 'libffi'
    if (-not (Test-Path $libffiTarget)) {
        log 'Force-downloading libffi...'
        $libffiVer = if ($env:LIBFFI_MESON_VERSION) { $env:LIBFFI_MESON_VERSION } else { '3.2.9999.4' }
        $libffiUrl = "https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/meson-$libffiVer/libffi-meson-$libffiVer.tar.bz2"
        $libffiTmp = Join-Path $resolvedLogDir 'libffi.tar.bz2'
        try {
            Invoke-WrapDownload -Url $libffiUrl -DestinationPath $libffiTmp -Description "libffi meson port $libffiVer"
            if (Expand-SubprojectArchive -Archive $libffiTmp -Target $libffiTarget) {
                log 'Force-pre-extracted libffi'
            } else {
                $script:wrapFailures += 'libffi (downloaded but extraction failed)'
            }
        } catch {
            $script:wrapFailures += "libffi : $($_.Exception.Message)"
            log "ERROR: libffi download failed - $($_.Exception.Message)"
        }
        Remove-Item -Path $libffiTmp -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $subprojDir 'libffi.wrap') -Force -ErrorAction SilentlyContinue
    }

    # FAIL CLOSED on any wrap loss (#88): a build that continues here ships
    # with silently narrowed codec coverage — the exact green-but-crippled
    # shape this repo's gates exist to prevent. Transient blips are already
    # absorbed by the helper's retry/backoff; what reaches this point is
    # persistent (moved revision, dead mirror, broken TLS) and needs a human.
    if ($script:wrapFailures.Count -gt 0) {
        throw ("GStreamer subproject provisioning failed for $($script:wrapFailures.Count) wrap(s): " +
            ($script:wrapFailures -join ' | ') +
            ' — refusing to build a feature-reduced GStreamer (backlog #88).')
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
    if ($gpuEnv.HasCuda) {
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
    # Cross lane: resolved HERE because both the link args below and the meson
    # cross file in phase 6 need it. The clang-cl driver defaults to the HOST
    # triple, and meson passes c_link_args THROUGH the compiler driver -- so
    # without --target on the link line lld-link is handed /machine:x64 and
    # refuses the aarch64 objects. Empty string on amd64, dropped by the
    # Where-Object below, so the emitted array is byte-identical on that lane.
    $gstTargetArch = Get-WindowsTargetArch
    $gstCrossArg = if (Test-WindowsCrossTarget -Arch $gstTargetArch) { "--target=$(Get-ClangTargetTriple -Arch $gstTargetArch)" } else { '' }
    $linkArgElems = ((@('/FORCE:MULTIPLE', $gstCrossArg, $rtFullPath) + $guidLibs) |
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

    # ---- 5g. bump cpp_std=c++11 pins to c++17 for the VS 18 MSVC STL ----
    # Several gst-plugins-bad C++ libs pin `override_options: ['cpp_std=c++11']`
    # (dxva, d3d11/12, ...). VS 18's MSVC STL (14.51+) uses C++14+ constructs
    # unconditionally (deduced return types, `auto` returns without a trailing
    # type, ...), which clang-cl REJECTS in C++11 mode -- the dxva decoders fail
    # with "'auto' return without trailing return type is a C++14 extension".
    # Older MSVC STLs tolerated a c++11 language mode; 14.51 does not. Bump every
    # c++11 pin in the gst source tree to c++17 (what the rest of this image
    # compiles with); C++17 is backward-compatible with this C++11 code and is
    # above the minimum the new STL needs. Wrap subprojects are pure C and carry
    # no such pin, so only gst's own C++ libs are touched.
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
    # gstreamer 1.29.2's opencv plugin is written for OpenCV 4; OpenCV 5
    # RELOCATED the APIs it uses out of their 4.x headers (verified against the
    # opencv/opencv_contrib 5.0.0 tags this image builds):
    #   cv::CascadeClassifier + CASCADE_* : moved to opencv_contrib xobjdetect
    #                                       (opencv2/xobjdetect.hpp) -- built here.
    #   contourArea/approxPolyDP/convexHull : moved to the new geometry module
    #                                         (opencv2/geometry.hpp).
    #   findChessboardCorners/findCirclesGrid/CALIB_CB_* : moved to the new calib
    #                                         module + objdetect (opencv2/calib.hpp,
    #                                         opencv2/objdetect.hpp).
    # The plugin still includes only the OpenCV-4 headers, so add the new header
    # to each file that uses a relocated symbol (inserted after the file's first
    # opencv2 include). NOT a behavioural change -- same classic APIs, new homes.
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
    # gst hardcodes the UNVERSIONED '-lopencv_tracking' (Linux naming) for the
    # cvtracker element, but OpenCV's Windows libs are versioned
    # (opencv_tracking500.lib) and already arrive via the opencv4.pc dependency
    # with their real names -- so lld-link fails to open the bare
    # 'opencv_tracking.lib'. Drop the redundant hardcoded flag; the pkg-config
    # dependency supplies the correctly-named versioned lib.
    $ocvMeson = Join-Path $ocvExtDir 'meson.build'
    if (Test-Path $ocvMeson) {
        $mc = [System.IO.File]::ReadAllText($ocvMeson)
        $mc2 = $mc -replace "\s*,\s*'-lopencv_tracking'", '' -replace "'-lopencv_tracking'\s*,\s*", '' -replace "'-lopencv_tracking'", ''
        if ($mc2 -ne $mc) { [System.IO.File]::WriteAllText($ocvMeson, $mc2); log 'Removed hardcoded -lopencv_tracking from ext/opencv/meson.build (opencv4.pc provides the versioned lib)' }
    }

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
    # Declared before the branch so the meson args below can interpolate it
    # unconditionally: with -SkipPluginGate no LiteRT include is added, and
    # StrictMode would otherwise fault on an undefined variable.
    $script:TfliteIncludeArg = ''
    if ($SkipPluginGate) {
        log 'WARNING: -SkipPluginGate — the mandatory GStreamer plugin contract is DISABLED for this build.'
        log "WARNING: the resulting image is NOT shippable. Required set: $(($requiredPlugins | ForEach-Object { $_.Name }) -join ', ')"
    } else {
        log '--- mandatory plugin pre-flight ---'

        # opencv4.pc — describes the OpenCV 5 install under $OPENCV_ROOT.
        $ocvRoot = if ($env:OPENCV_ROOT) { $env:OPENCV_ROOT } else { Join-Path $resolvedInstallDir 'lib\opencv5' }
        # OpenCV's Windows install layout is <root>\<arch>\vc18\{bin,lib}; the arch
        # component is the one token that moves with the target, so it comes from
        # the arch table ('x64' | 'arm64') instead of a literal.
        $ocvLib = if ($env:OPENCV_LIB) { $env:OPENCV_LIB } else { Join-Path $ocvRoot "$(Get-OpenCvArchDir)\vc18\lib" }
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
        # gst-plugins-bad opencv/meson.build derives its cascade-data dir as
        # opencv_dep.get_variable('prefix') + /share/{opencv,OpenCV,opencv4} and
        # errors hard when none is a directory. Two OpenCV-5 mismatches bite here:
        #  1. gst never looks for share/opencv5, and OpenCV 5 on Windows drops its
        #     xml under <root>\etc anyway (not share/ at all).
        #  2. pkgconf RELOCATES the prefix from the .pc file LOCATION
        #     (<...>/x64/vc18/lib/pkgconfig -> strips lib/pkgconfig -> <...>/x64/vc18),
        #     ignoring the explicit prefix= line, so the prefix meson computes is
        #     NOT $ocvRoot. Rather than guess which relocation wins, create
        #     share\opencv4 under every plausible prefix root (install root, the
        #     relocated lib-parent, and the lib dir itself) and fill each from
        #     <root>\etc so both meson's is_dir probe AND facedetect's runtime
        #     cascade lookup resolve wherever the prefix lands.
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
        # Same env-name order as build-onnx-from-source.ps1: ONNXRUNTIME_VERSION
        # is what the BK lane sets; ONNX_VERSION only exists in the merge image.
        # Reading only the latter wrote a 1.28.0 .pc against a 1.29.0 install in
        # standalone runs — and passed the >= 1.16.1 constraint silently.
        $ortVersion = Get-SourceBuildVersion -Value '' -EnvironmentVariables @('ONNXRUNTIME_VERSION', 'ONNX_VERSION') -DefaultValue '1.29.0' -StripVPrefix
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

        # ── tflite: the one integration that does NOT use pkg-config ──────────
        # gst-plugins-bad ext/tflite probes the compiler directly:
        #   cc.find_library('tensorflowlite_c') / fallback 'tensorflow-lite'
        #   cc.has_header('tensorflow/lite/c/c_api.h')
        # That header path is the PRE-RENAME TensorFlow one. Google renamed
        # TFLite to LiteRT, and build-litert-from-source.ps1 stages the headers
        # the way LiteRT ships them — under include\tflite\ — so upstream's
        # probe cannot find them no matter what PKG_CONFIG_PATH says. This is a
        # namespace mismatch, not a missing dependency, which is why it never
        # looked like the opencv/onnx problem.
        #
        # Fix: mirror the header tree under the name upstream probes for. The
        # copies' own #includes stay `tflite/...`, which still resolve because
        # the SAME include root is on the path.
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

        # The link name upstream asks for, in preference order. If LiteRT's build
        # produced neither, say exactly what IS there — a bare "not found" here
        # would send someone hunting PKG_CONFIG_PATH for a plugin that never
        # consults it.
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

        # cc.find_library / cc.has_header consult the COMPILER's search paths,
        # not meson options, so INCLUDE/LIB is the mechanism that actually works
        # here. lld-link (invoked by clang-cl) reads LIB for its default library
        # search path, so setting it below is sufficient for the tflite plugin's
        # find_library AND its link. Do NOT also push the dir as a `/LIBPATH:`
        # c_link_arg: clang-cl does not recognise `/LIBPATH:` as a driver flag
        # and treats the whole token as an input filename ("no such file or
        # directory: '/LIBPATH:...'"), which fails meson's compile+link sanity
        # check before any plugin is even configured (regression fixed 2026-08-13,
        # first surfaced once all three media branches fanned into the merge).
        $env:INCLUDE = (@($litertInclude) + @($env:INCLUDE -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
        $env:LIB = (@($litertLib) + @($env:LIB -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
        # Forward slashes inside the meson array literal: meson parses those
        # strings with escape sequences, so a native C:\... path would mangle
        # (\r, \t, ...). Same reason $rtFullPath above is converted.
        $script:TfliteIncludeArg = '-I' + ($litertInclude -replace '\\', '/')
        log "INCLUDE += $litertInclude ; LIB += $litertLib"

        # Everything the required set needs must resolve NOW, not after an hour.
        $pcModules = @($requiredPlugins | Where-Object { $_.Detection -eq 'pkg-config' } |
                ForEach-Object { $_.NeedsPc } | Select-Object -Unique)
        # The version floors upstream actually applies. Presence alone is not
        # enough: FFmpeg shipped .pc files declaring `Version: ..`, which passes
        # --exists and fails every constraint, so gst-libav was skipped while the
        # pre-flight reported everything fine (measured 2026-08-07).
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

    Switch-BuildPhase '6. meson setup'
    # ---- 6. meson setup (retry with wrap cleanup) ----
    # Meson cross file. Meson has NO per-target compiler property the way CMake
    # has CMAKE_<LANG>_COMPILER_TARGET: --cross-file is the ONLY way to tell it
    # host_machine != build_machine. Without one it probes clang-cl, gets x86_64
    # back, and every `host_machine.cpu_family()` branch across the gst meson.build
    # tree takes the x86 path -- a green configure producing an x86-shaped build.
    #
    # Written to the LOG dir, not the build dir: the retry below deletes the build
    # dir wholesale, and a log-dir copy survives a failed solve.
    #
    # DELIBERATELY carries NO [built-in options] c_args/cpp_args: meson gives the
    # command line HIGHER precedence than a machine file, so a --target placed
    # here would be silently dropped. It rides in the -Dc_args/-Dcpp_args strings
    # and in $linkArgElems instead.
    $mesonCrossArgs = @()
    if (Test-WindowsCrossTarget -Arch $gstTargetArch) {
        $gstTriple = Get-ClangTargetTriple -Arch $gstTargetArch
        # meson's own vocabulary, NOT this repo's arch names. A missing mapping
        # THROWS: a cross file with the wrong cpu_family configures green and
        # yields an x86-shaped build, which is the failure this exists to stop.
        $gstCpuFamily = switch ($gstTargetArch) {
            'arm64' { 'aarch64' }
            default { throw "build-gstreamer: no meson cpu_family mapping for target arch '$gstTargetArch' - add one before building it." }
        }
        # CC/CXX may carry the sccache launcher ('sccache clang-cl'); meson's
        # [binaries] entries take a LIST, so split rather than quote as one word.
        $ccList = ((($env:CC -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        $cxxList = ((($env:CXX -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
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
        $mesonCrossArgs = @('--cross-file', $crossFile)
        log "Meson cross file for $gstTargetArch ($gstTriple): $crossFile"
        Get-Content $crossFile | ForEach-Object { log "  cross| $_" }
    }
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
        # $script:TfliteIncludeArg carries the LiteRT include root (empty when the
        # plugin gate is skipped). It rides in c_args AND cpp_args because the
        # tflite plugin's has_header probe runs against the C compiler while the
        # plugin sources themselves are C++.
        # -Wno-incompatible-pointer-types: clang 16+ promoted -Wincompatible-pointer-types
        # to a DEFAULT error; gst-plugins-bad ext/onnx (gstonnxinference.c) passes a
        # gchar* where a differently-typed pointer is expected, which older clang let
        # through as a warning. Demote it to match the function-pointer variant already
        # here, so the version bump to a newer clang-cl does not fail the onnx plugin.
        # -Wno-undef: graphene 1.10.8 (building for the FIRST time now that #88
        # delivers every wrap - it used to drop out silently) tests bare
        # `__GNUC__` in #if under a -Werror it brings along; clang-cl defines
        # no __GNUC__ in MSVC personality. Disabling the diagnostic beats
        # chasing where the -Werror comes from (verify13).
        # $gstCrossArg is '--target=<triple>' on the cross lane and '' on amd64. It
        # MUST live in these command-line -D options rather than in the cross
        # file's [built-in options]: meson gives the command line higher
        # precedence, so a c_args set in both places keeps only this one.
        # The `if` guards the SEPARATOR too -- appending " $gstCrossArg"
        # unguarded would leave a trailing space in the amd64 option value, which
        # is a byte difference in the emitted configure command line.
        "-Dc_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg -FIio.h -Disatty=_isatty -Dfileno=_fileno -Dclose=_close -Dwrite=_write -DSTDOUT_FILENO=1 -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types -Wno-undef$(if ($gstCrossArg) { " $gstCrossArg" })",
        "-Dcpp_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg -FIio.h -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types$(if ($gstCrossArg) { " $gstCrossArg" })",
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
        # graphene: its MSVC code path calls SSE4.1 intrinsics (dpps) with no
        # target-feature guard - MSVC tolerates that, clang-cl refuses
        # ("__builtin_ia32_dpps needs target feature sse4.1", verify13). The
        # scalar path is correct and this is geometry math for GL mixers, not
        # a hot loop worth a global -msse4.1 baseline change.
        '-Dgraphene:sse2=false',
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
                '-Dgst-plugins-bad:onnx=enabled',
                '-Dgst-plugins-bad:tflite=enabled'
            )
        }
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
        # the actual compiler command line + its stderr live in meson-log.txt.
        # Dump it here, BEFORE the attempt-1 cleanup below wipes $resolvedBuildDir.
        $mesonLog = Join-Path $resolvedBuildDir 'meson-logs\meson-log.txt'
        $mesonLogLines = @()
        if (Test-Path $mesonLog) {
            $mesonLogLines = @(Get-Content $mesonLog)
            log "---- meson-log.txt (attempt $attempt, exit $mesonExitCode) ----"
            $mesonLogLines | ForEach-Object { if ($_) { log $_ } }
            log '---- end meson-log.txt ----'
        } else {
            log "meson-log.txt not found at $mesonLog"
        }

        # A deterministic meson configure error (a plugin's meson.build erroring on
        # a missing dependency/function/data dir) fails IDENTICALLY on retry, so the
        # attempt-2 cleanup + full wrap re-download (~hours when the wrapdb fetches
        # hit SSL retry backoff) is pure waste. Retry ONLY transient failures;
        # short-circuit on a hard `meson.build:LINE:COL: ERROR/Exception`.
        $hardError = @($mesonOut + $mesonLogLines) -match 'meson\.build:\d+:\d+: (ERROR|Exception)'
        if ($hardError) {
            log "meson setup hit a deterministic configure error; NOT retrying (a retry repeats it identically after a full wrap re-download): $($hardError[-1].Trim())"
            break
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

    # graphene (first-ever build here since #88 delivers every wrap): its
    # meson.build appends -Werror=undef AFTER our c_args, so the -Wno-undef we
    # pass is overridden (last flag wins) and its bare `#if __GNUC__` tests die
    # under clang-cl, which defines no __GNUC__ (verify14). Drop that ONE flag
    # from its test_cflags at the source; ninja regenerates on meson.build
    # changes, so patching between setup and compile is safe.
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
    # Job budget + stall guard (backlog #65): this was the ONE compile stage
    # running sccache with neither. `meson compile` without -j lets ninja
    # default to cores+2, ignoring MEMORY_LIMIT_GB entirely — the OOM shape
    # MemGBPerJob exists to prevent — and without the stall guard a wedged
    # sccache server (the documented deadlock family) hangs the merge stage
    # indefinitely with no kill/resume. 2 GB/job: GStreamer TUs are C-sized,
    # not ONNX-CUDA-sized.
    $gstJobs = Get-BuildJobCount -MemGBPerJob 2
    log "meson compile with -j $gstJobs (MEMORY_LIMIT_GB='$env:MEMORY_LIMIT_GB', cores=$([Environment]::ProcessorCount))"
    $compileSucceeded = $false
    for ($cAttempt = 1; $cAttempt -le 2; $cAttempt++) {
        log "Compiling GStreamer (attempt $cAttempt/2, may take 30-60 min)..."
        $gstStallGuard = Start-SccacheStallGuard -MarkerPath (Join-Path $resolvedLogDir 'gstreamer-stall-guard.marker')
        try {
            & $mesonExe compile -C $resolvedBuildDir -j $gstJobs 2>&1 | ForEach-Object { if ($_) { log $_ } }
        } finally {
            Stop-SccacheStallGuard -Guard $gstStallGuard
        }
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
    & $mesonExe install -C $resolvedBuildDir 2>&1 | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'meson install failed' }
    log 'Installation complete.'

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
    # Make every media DLL home searchable for the load probe. The image's runtime
    # PATH (Dockerfile ENV) lists ONNX under \lib, but onnxruntime.dll + DirectML.dll
    # ship in \bin -- so onnx failed to load. Mirror the full set here (the
    # Dockerfile PATH is corrected to match) so the gate reflects the shipped image.
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
    # HOST tool -- deliberately NOT Get-MsvcTargetBinDir. dumpbin only READS the
    # built DLLs here (/dependents is machine-type agnostic, so it inspects an
    # arm64 DLL fine) and must itself RUN on the amd64 build host. Retargeting
    # this glob would buy nothing and could resolve to NOTHING: the VC.Tools.ARM64
    # component is only warn-gated in the shared base, and a $null $dumpbin blows
    # up inside the dependency scan below.
    $dumpbin = (Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    $dllSearchDirs = @($gstPluginDir) + @($env:PATH -split ';' | Where-Object { $_ }) + @("$env:SystemRoot\System32")
    # Recursively resolve a DLL's dependency tree and return the names that resolve
    # nowhere. api-ms-win-* / ext-ms-win-* are virtual API sets (loader resolves
    # them via the API-set schema, never real files), so they are never "missing".
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
            # Do NOT recurse into OS DLLs (System32/WinSxS): their deep OneCore
            # deps are absent on Server Core but loader-tolerated (delay-loaded) --
            # recursing there floods the report with noise. Only walk OUR DLLs.
            elseif ($hit -notmatch '[\\/](System32|SysWOW64|WinSxS)([\\/]|$)') {
                foreach ($m in (Get-UnresolvedDeps (Join-Path $hit $dep) $Dumpbin $SearchDirs $Seen)) { $missing.Add($m) }
            }
        }
        return $missing
    }
    foreach ($plugin in @(Get-RequiredGstPlugin)) {
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
        log "All $(@(Get-RequiredGstPlugin).Count) mandatory GStreamer plugins verified present."
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
    # Flush/stop the #128 session server on the FAILURE path too — the
    # error-log dump only means something after a clean server stop, and the
    # failing run is exactly the one whose log you want (audit 2026-08-21).
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