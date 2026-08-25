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

    CORRECTED 2026-08-24: this used to read "Alternative to the binary BITS
    installer. Clones the GStreamer monorepo." The first half went stale when
    setup-gstreamer.ps1 (the BITS-downloaded MSI path) was deleted
    (f0d12ff2, 2026-06-24) -- no binary GStreamer install path exists under
    windows/ any more. The "clones" half was wrong from day one (2d84dedf,
    2026-06-16): this script has only ever fetched the tarball, never run
    git clone.

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

# Target-arch state, resolved ONCE here rather than at first use. Several
# decisions far apart in this file depend on it -- the compiler-rt builtins
# selection, the mandatory-plugin contract, the tflite pre-flight, the meson
# options and the post-install verification -- and resolving it late meant the
# earliest of those ran arch-blind. Script scope so every phase block sees the
# same answer. Both are inert on amd64: Test-WindowsCrossTarget compares against
# the HOST arch, which is always amd64 here.
$script:GstTargetArch = Get-WindowsTargetArch
$script:GstCross      = Test-WindowsCrossTarget -Arch $script:GstTargetArch

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
    # io.h force-include shim, used INSTEAD of a bare -FIio.h on the cross lane.
    #
    # meson hands `c_args` to .S files as well as to .c files -- assembly goes
    # through the same compiler driver -- so a force-included C header lands in
    # an ASSEMBLY translation unit, where it is parsed as instructions:
    #   vadefs.h:76:9: error: unrecognized instruction mnemonic
    #           typedef char* va_list;
    # (measured 2026-08-23 on openh264's arm64_*_aarch64_neon.S). amd64 never
    # hits it because the aarch64 .S files are only compiled for ARM targets --
    # openh264 uses nasm .asm there.
    #
    # __ASSEMBLER__ is defined by clang for .S translation units and by nothing
    # else, so this shim is a no-op exactly where the header is meaningless and
    # byte-identical to -FIio.h everywhere else. It matters beyond openh264:
    # dav1d, libvpx and x264 all ship aarch64 .S too, so fixing the flag beats
    # disabling one subproject at a time.
    $ioShim = Join-Path $stubDir 'gst-io-shim.h'
    if (-not (Test-Path $ioShim)) {
        '#pragma once
/* See build-gstreamer-from-source.ps1: meson passes c_args to .S files too. */
#ifndef __ASSEMBLER__
#include <io.h>
#endif' | Out-File -FilePath $ioShim -Encoding ASCII
        log "Created io.h force-include shim at $ioShim (assembly-safe)"
    }

    # ---- 5b-bis. pre-place the win-pkgconfig binary (resilience, both lanes) ----
    # win-pkgconfig is the ONE subproject that fetches with no fallback: its
    # download-binary.py has a single MIRROR_URL, one urlopen, and zero retries.
    # When gstreamer.freedesktop.org 503s, everything else survives -- win-flex-bison
    # falls back to GitHub, nasm to nasm.us -- and this alone kills the merge.
    # It cost three separate chain runs on 2026-08-23.
    #
    # download-binary.py opens with:
    #     if os.path.isfile(dest_path) and sha256 matches: sys.exit(0)
    # so pre-placing the archive removes the network from the critical path
    # entirely. Invoke-DownloadWithRetry adds 4 attempts with exponential backoff
    # where meson has none, and the hash is verified against the SAME constant
    # meson checks, so a corrupt or truncated fetch cannot slip through.
    #
    # Deliberately NOT scoped to the cross lane: the outage hits amd64 identically,
    # and this changes no compiler or linker command line -- only how a byte-identical
    # archive arrives. A failure here is a WARNING, not a throw: meson still has its
    # own attempt, and this must never be the thing that breaks a build.
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
                # LAN preseed FIRST, upstream second. Retries do not help against a
                # sustained outage: gstreamer.freedesktop.org 503'd for long enough
                # that four attempts with backoff still failed, and this one file
                # blocked the merge on four separate runs. The same reasoning (and
                # the same webdav) is already used for the Vulkan SDK in
                # build-buildkit.ps1 -- "containers never pull it from the vendor".
                #
                # Self-seeding: whichever source works, the archive is PUT back to
                # the preseed path, so the first successful run immunises the next
                # one. Every step is fail-open; a preseed miss is not an error.
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
    # TARGET-FILTERED ON BOTH LANES (2026-08-24, found by the amd64 regression
    # run): LLVM ships one builtins lib PER TARGET and this path goes straight
    # to lld-link. The previous shape filtered only on the cross branch, on the
    # rationale "keeps the amd64 selection exactly what it is today" -- which
    # was written while clang_rt.builtins-x86_64.lib was the ONLY lib present.
    # The moment setup-scoop-tools.ps1 started installing the aarch64
    # counterpart (the #113 base ride), amd64's arch-blind alphabetical
    # `-First 1` flipped to aarch64 ('a' < 'x') and the FIRST amd64 merge on
    # that base died linking gstreamer-1.0-0.dll:
    #   lld-link: error: clang_rt.builtins-aarch64.lib(udivti3.c.obj):
    #             machine type arm64 conflicts with x64
    # The host-vs-target lesson, one more time: a selection that depends on
    # what happens to be installed is not a selection.
    $rtCandidates = @(Get-ChildItem -Path "$llvmRoot\lib\clang" -Recurse -Filter '*builtins*.lib' -ErrorAction SilentlyContinue)
    $wantRt = (Get-ClangTargetTriple -Arch $script:GstTargetArch) -replace '-.*$', ''   # x86_64/aarch64-pc-windows-msvc -> x86_64/aarch64
    $rtCandidates = @($rtCandidates | Where-Object { $_.Name -match [regex]::Escape($wantRt) })
    if ($script:GstCross) {
        if ($rtCandidates.Count -eq 0) {
            # WARN, do not throw. Absence is already tolerated on amd64 -- if no
            # builtins lib is found there, $rtFullPath simply stays empty and the
            # link proceeds -- so throwing only here would apply a stricter policy
            # to the cross lane than this file applies to itself, and would block
            # a build that may not need these helpers at all.
            #
            # The 2026-08-23 measurement here (probe-arm64-prereqs.ps1 Q5:
            # "the LLVM install ships ONLY clang_rt.builtins-x86_64.lib, there
            # is no aarch64 counterpart") stopped being true once
            # setup-scoop-tools.ps1 (:344-397) started downloading
            # clang_rt.builtins-aarch64.lib into the LLVM lib dir. On a current
            # image the filter finds it and this branch does not run; landing
            # here means that download was skipped or failed. The honest
            # outcome is still to link nothing rather than the host's lib: if
            # aarch64 GStreamer genuinely needs __udivti3 & co, lld-link says
            # so by NAME, which is a precise and actionable error -- unlike the
            # machine-type conflict the unfiltered code would have produced, or
            # a pre-emptive throw here.
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
    # LunarG ships the aarch64 import libraries in a SEPARATE directory of the
    # x64 SDK ($VULKAN_SDK\Lib-ARM64, an optional component that setup-scoop-tools.ps1
    # installs), while $VULKAN_SDK\Lib holds the x64 ones and is what the image's
    # environment already puts on LIB. Nothing pointed lld-link at the arm64 set,
    # so gst-plugins-bad's Vulkan library linked the HOST import lib and died
    # (measured 2026-08-23):
    #   lld-link: error: vulkan-1.lib(vulkan-1.dll): machine type x64 conflicts with arm64
    # Prepending is enough: LIB is searched in order, so the target's directory
    # wins without having to remove the host's. amd64 resolves Get-VulkanLibDirName
    # to 'Lib' and this block does not run at all.
    if ($script:GstCross) {
        if ([string]::IsNullOrWhiteSpace($env:VULKAN_SDK)) {
            throw 'VULKAN_SDK is not set, so the target-arch Vulkan import library cannot be located. gst-plugins-bad would link the host vulkan-1.lib and fail with a machine-type conflict.'
        }
        $vkArchLib = Join-Path $env:VULKAN_SDK (Get-VulkanLibDirName -Arch $script:GstTargetArch)
        if (-not (Test-Path (Join-Path $vkArchLib 'vulkan-1.lib'))) {
            throw ("Vulkan import library for $($script:GstTargetArch) not found at $vkArchLib\vulkan-1.lib. " +
                   'It ships as the OPTIONAL com.lunarg.vulkan.arm64 component of the x64 SDK and is installed by ' +
                   'setup-scoop-tools.ps1 (warn-only there, so a base built before that step will lack it). ' +
                   'Without it lld-link picks the x64 vulkan-1.lib and fails with a machine-type conflict.')
        }
        $env:LIB = (@($vkArchLib) + @($env:LIB -split ';' | Where-Object { $_ }) | Select-Object -Unique) -join ';'
        log "Vulkan: prepended $vkArchLib to LIB (target-arch import library)"
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
    $gstTargetArch = $script:GstTargetArch   # resolved once at the top of this script
    $gstCrossArg = if ($script:GstCross) { "--target=$(Get-ClangTargetTriple -Arch $gstTargetArch)" } else { '' }
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
    # -Arch is what drops 'tflite' on the cross lane, where LiteRT does not exist
    # at all. Done in the CONTRACT, not here, so the smoke test and healthcheck
    # get the same answer -- the three disagreeing is the documented 2026-07-11
    # regression that shipped an image without plugins.
    $requiredPlugins = @(Get-RequiredGstPlugin -Arch $script:GstTargetArch)
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

        # OpenSSL for the TARGET arch (cross lane only).
        # scoop installs one architecture per app -- the host's -- so the image's
        # openssl is x64 only, and pkg-config finds its .pc first. Four targets
        # link OpenSSL and all four died identically (measured 2026-08-23):
        #   ext/hls, ext/dtls, ext/aes, glib-networking's openssl TLS backend
        #   lld-link: error: libcrypto.lib(libcrypto-4-x64.dll): machine type x64 conflicts with arm64
        # setup-scoop-tools.ps1 installs the arm64 build beside it at
        # C:\opt\openssl-arm64; this points pkg-config there FIRST.
        #
        # The lib directory is found by SEARCH rather than assumed: slproweb's
        # layout (lib\VC\<arch>\MD) is upstream's business, not a constant worth
        # hardcoding here. If that tree ships its own .pc files they win; if not,
        # they are authored with the same helper OpenCV and ORT already use --
        # both of those ship no .pc either, so this is the established path.
        $sslPcDirs = @()
        if ($script:GstCross) {
            $sslRoot = 'C:\opt\openssl-arm64'
            $sslLibHit = @(Get-ChildItem -Path $sslRoot -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($sslLibHit.Count -eq 0) {
                throw ("OpenSSL for $($script:GstTargetArch) not found under $sslRoot (no libcrypto.lib). " +
                       'setup-scoop-tools.ps1 installs it warn-only, so a base built before that step will lack it. ' +
                       "Without it gst-plugins-bad's hls/dtls/aes and glib-networking's openssl backend link the x64 " +
                       'import library and fail with a machine-type conflict.')
            }
            $sslLibDir = $sslLibHit[0].Directory.FullName
            # The include dir is FOUND, not composed. innounp extracts InnoSetup
            # payloads under a literal '{app}' directory, so the real layout is
            #   C:\opt\openssl-arm64\{app}\lib\VC\arm64\MD\libcrypto.lib
            #   C:\opt\openssl-arm64\{app}\include\openssl\opensslv.h
            # and `Join-Path $sslRoot 'include'` would silently point at a path
            # that does not exist (measured 2026-08-23 from the base build log).
            # opensslv.h sits at <include>\openssl\opensslv.h, hence two levels up.
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

        # Make the new pkgconfig dirs visible to meson for THIS process. The
        # OpenSSL ones go FIRST so they win over the image's x64 openssl.pc.
        # NB the explicit @(...) + @(...): '+' binds tighter than ',', so
        # @($a + $b, $c) would nest $a+$b as ONE element instead of flattening.
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

        # PRESENCE-DRIVEN since #115 (2026-08-24): the cross lane BUILDS plain
        # LiteRT (media-litert runs on arm64; only its LiteRT-LM stage self-skips,
        # with the Bazel reasons recorded in build-litert-all.ps1 and the
        # exclusion table of docs/windows-cross-builds.md), so "cross implies no
        # LiteRT" stopped being true. The decision input is the artifact itself --
        # tensorflowlite_c.lib in the fanned-in tree -- never the lane: a cross
        # merge from an older media-litert-less core degrades to
        # disabled-with-reason instead of throwing, and amd64 is unchanged (the
        # lib is always present there; a genuinely missing one still hits the
        # block's own hard gates).
        $script:GstTfliteLibDir = if ($env:LITERT_LIB) { $env:LITERT_LIB } else { Join-Path $resolvedInstallDir 'lib\litert\lib' }
        $script:GstTfliteAvailable = (-not $script:GstCross) -or (Test-Path (Join-Path $script:GstTfliteLibDir 'tensorflowlite_c.lib'))
        if (-not $script:GstTfliteAvailable) {
            log ("tflite integration skipped: no tensorflowlite_c.lib in $script:GstTfliteLibDir -- this cross image " +
                 'predates the #115 LiteRT cross build (or media-litert was not fanned in). The meson feature is set ' +
                 'to disabled EXPLICITLY below, never auto.')
        } else {
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
        }

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

    # ── gst-plugins-base x86 SIMD gate (ARM cross only) ──────────────────────
    # Upstream bug. subprojects/gst-plugins-base/meson.build decides whether to
    # build the x86 SSE resampler variants like this:
    #     if cc.get_argument_syntax() == 'msvc'
    #       if host_machine.cpu_family() == 'x86_64'
    #         sse_args = '/arch:SSE2'
    #       else
    #         sse_args = '/arch:SSE'          <-- aarch64 lands HERE
    #       endif
    #       have_sse  = cc.has_argument(sse_args)      <-- NOT arch-guarded
    #       have_sse2 = cc.has_argument(sse2_args)     <-- NOT arch-guarded
    #       have_sse41 = cc.has_argument(sse41_args) and host_machine.cpu_family() == 'x86_64'
    # The msvc branch assumes "not x86_64" means "x86 32-bit" and never considers
    # ARM64. have_sse41 already carries the cpu_family guard; have_sse/have_sse2
    # do not, and clang-cl ACCEPTS /arch:SSE for an aarch64 target completely
    # silently -- no error, no warning. meson already tries to catch exactly this
    # (ClangClCompiler.has_arguments appends -Werror=unknown-argument,
    # -Werror=unknown-warning-option and -Werror=unused-command-line-argument),
    # so there is nothing to fix on the meson side. Result (measured 2026-08-23):
    #   audio-resampler-x86-sse.c -> mmintrin.h(14,2): error: "This header is
    #   only meant to be used on x86 and x64 architecture"
    # The fix simply extends the guard upstream already applies to have_sse41.
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
    # Upstream bug, same class as the SSE gate above: the WRONG MACHINE is asked.
    # subprojects/gst-plugins-bad/gst-libs/gst/vulkan/meson.build does
    #     vulkan_root = os.environ.get("VK_SDK_PATH")
    #     if build_machine.cpu_family() == 'x86_64'
    #       vulkan_lib_dir = join_paths(vulkan_root, 'Lib')
    #     else
    #       vulkan_lib_dir = join_paths(vulkan_root, 'Lib32')
    #     vulkan_lib = cc.find_library('vulkan-1', dirs: vulkan_lib_dir, ...)
    # `build_machine` is the machine doing the compiling, which is x86_64 here no
    # matter what we are targeting -- so an aarch64 build is pointed at the x64
    # import library and dies at link (measured 2026-08-23):
    #   lld-link: error: vulkan-1.lib(vulkan-1.dll): machine type x64 conflicts with arm64
    # Because the directory is passed EXPLICITLY via `dirs:`, no amount of LIB
    # ordering on our side can override it -- that was tried first and had no
    # effect at all.
    #
    # meson itself already gets this right; gst-plugins-bad simply does not use
    # it. mesonbuild/dependencies/ui.py:199-207 (VulkanDependencySystem) maps
    # build x86_64 + host aarch64 -> 'Lib-ARM64', which is exactly the branch
    # added here. LunarG ships those import libraries in that separate directory
    # of the x64 SDK (the optional com.lunarg.vulkan.arm64 component).
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
        #
        # --target BELONGS IN THE EXELIST, not only in c_args. This is meson's
        # designed cross mechanism for clang-cl and the ONLY thing that gives the
        # archiver and linker the right /MACHINE. Verified against meson 1.12.0:
        #   compilers/detect.py:439  match = re.search('^Target: (.*?)-', out, re.MULTILINE)
        # -- meson runs `<exelist> --version` and parses the reported triple, then
        #   compilers/mixins/visualstudio.py:114  elif 'aarch64' in target: self.machine = 'arm64'
        #   compilers/mixins/visualstudio.py:123  self.linker.machine = self.machine
        # and the archiver picks it up via
        #   compilers/detect.py:224  VisualStudioLinker(linker, env, getattr(compiler, 'machine', None))
        # Without it clang-cl reports the HOST triple, meson canonicalises that to
        # 'x64', and every static archive and DLL is built with /MACHINE:x64 while
        # the objects are arm64 (measured 2026-08-23):
        #   libgnulib.a.p/asnprintf.c.obj: file machine type arm64 conflicts with
        #   library machine type x64 (from '/machine:x64' flag)
        # [host_machine] cpu_family does NOT drive /MACHINE -- that was the wrong
        # assumption; it only steers the meson.build tree's own arch branches.
        # The duplicate --target in -Dc_args below is harmless and stays: it keeps
        # the compile flags correct even for subprojects that rebuild the command.
        $ccList = (((($env:CC -split '\s+') | Where-Object { $_ }) + @("--target=$gstTriple")) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        $cxxList = (((($env:CXX -split '\s+') | Where-Object { $_ }) + @("--target=$gstTriple")) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        # Rust for the TARGET (#128): gst-ptp-helper is a Rust program and meson
        # only builds it when the cross file names a rust compiler for the host
        # machine. The image's rustup carries the x64 toolchain only, so the
        # aarch64 std is added here (idempotent, ~30 MB, the container has
        # network) and PROVEN with a one-line staticlib before it is declared:
        # a rust entry in the cross file that fails meson's sanity check fails
        # the whole setup, whereas an absent entry just skips the helper (the
        # option stays auto). Either outcome is logged -- never a silent skip.
        $rustTargetLine = ''
        $rustTriple = Get-RustTargetTriple -Arch $gstTargetArch
        $rustup = (Get-Command rustup -ErrorAction SilentlyContinue).Source
        $rustc = (Get-Command rustc -ErrorAction SilentlyContinue).Source
        if ($rustup -and $rustc) {
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
        # NATIVE file (#128, 2026-08-25): a cross file alone tells meson about
        # the HOST machine only; the BUILD machine had no C compiler at all
        # ("Compiler for language c for the build machine not found", 93x per
        # setup), so the build-machine glib fallback died and libnice's by-name
        # `subprojects/glib` lookup failed -- the webrtc plugin, gstwebrtcnice
        # and libnice were the whole difference between the two lanes' plugin
        # inventories (measured run 11 vs amd64 merge). Same compilers without
        # the --target, i.e. exactly what the amd64 lane runs.
        $nccList = ((($env:CC -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        $ncxxList = ((($env:CXX -split '\s+') | Where-Object { $_ }) | ForEach-Object { "'" + ($_ -replace '\\', '/') + "'" }) -join ', '
        # The build machine's LIBRARY dirs (arm64 runs 23/24): the native compiler
        # was detected, then its sanity check LINKED against the arm64 CRT --
        # "msvcrt.lib(exe_main.obj): machine type arm64 conflicts with x64" --
        # because the RUN's LIB names the target's lib\arm64 / um\arm64 dirs and
        # lld-link reads only LIB. Meson has no per-machine LIB; a native file's
        # [built-in options] link args are the BUILD machine's. BUT meson hands
        # those args to the clang-cl DRIVER also BEFORE `/link` (sanity check,
        # run 24), and clang-cl reads a path-shaped `/LIBPATH:C:/...` there as an
        # input file ("no such file or directory") -- /LIBPATH can never ride
        # c_link_args with clang-cl. `/vctoolsdir:` + `/winsdkdir:` (+
        # `/winsdkversion:`) are understood by BOTH the driver and lld-link, and
        # lld-link adds their lib\<machine> dirs to the search path AHEAD of the
        # LIB entries, selecting the arch from /machine: -- so the build machine
        # links x64 while the host (arm64) compiles of the same meson run keep
        # LIB as it is. Both roots are derived from the RUN's LIB (the entries
        # VsDevCmd wrote), not assumed.
        $vcToolsDir = $null; $winSdkDir = $null; $winSdkVer = $null
        foreach ($entry in @(($env:LIB -split ';') | Where-Object { $_ })) {
            if (-not $vcToolsDir -and $entry -match '^(.*\\VC\\Tools\\MSVC\\[^\\]+)\\+lib\\') { $vcToolsDir = $Matches[1] }
            if (-not $winSdkDir -and $entry -match '^(.*\\Windows Kits\\10)\\+lib\\+([^\\]+)\\+(um|ucrt)\\') { $winSdkDir = $Matches[1]; $winSdkVer = $Matches[2] }
        }
        if (-not $vcToolsDir) { $vcToolsDir = Get-MsvcToolsRoot }
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
        #
        # $ioFI is '-FIio.h' on amd64 (unchanged, byte for byte) and the
        # assembly-safe shim on the cross lane -- see the gst-io-shim.h block in
        # phase 5b for why a force-included C header breaks aarch64 .S files.
        "-Dc_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg $ioFI -Disatty=_isatty -Dfileno=_fileno -Dclose=_close -Dwrite=_write -DSTDOUT_FILENO=1 -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types -Wno-undef$(if ($gstCrossArg) { " $gstCrossArg" })",
        "-Dcpp_args=-I$env:TEMP_DIR\includes $script:TfliteIncludeArg $ioFI -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types$(if ($gstCrossArg) { " $gstCrossArg" })",
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
                # NEVER 'auto' (the repo-wide rule): 'auto' would probe,
                # half-configure against an empty LiteRT tree and fail late
                # instead of cleanly not building the plugin. Since #115 the
                # switch is ARTIFACT presence ($script:GstTfliteAvailable, set
                # where the integration block runs), not the lane: enabled
                # wherever tensorflowlite_c exists -- which now includes the
                # arm64 cross lane -- and explicit disabled otherwise. amd64's
                # meson command line is unchanged (always enabled there).
                $(if ($script:GstTfliteAvailable) { '-Dgst-plugins-bad:tflite=enabled' } else { '-Dgst-plugins-bad:tflite=disabled' })
            ) + @(
                # Meson-native contract entries (#128, 2026-08-25: webrtc + nice
                # -- the one plugin-inventory difference between the lanes).
                # Derived from the contract, `enabled` each, so a lane that
                # cannot build libnice fails meson setup in seconds instead of
                # shipping one plugin short; the arm64 lane did exactly that
                # until the native file above gave meson a build-machine
                # compiler for libnice's glib fallback.
                $requiredPlugins | Where-Object { $_.Detection -eq 'meson' } | ForEach-Object { "-D$($_.MesonOption)=enabled" }
            )
        }
    ) + @(
        # glib's own test suite: 562 test targets on amd64 (measured 2026-08-25)
        # that ship nothing. The top-level -Dtests=disabled covers the GStreamer
        # modules only; glib is a wrap with its own option.
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
        # ... EXCEPT that a failed DOWNLOAD wears exactly that costume. Several
        # subprojects fetch a binary during configure (win-pkgconfig,
        # win-flex-bison, ...), and when the fetch fails meson reports it as
        #   subprojects\win-pkgconfig\meson.build:13:6: ERROR: Command `...
        #   download-binary.py 0.29.2 <sha>` failed
        # which is formally indistinguishable from a real configure error. It is
        # NOT deterministic: measured 2026-08-23, gstreamer.freedesktop.org
        # answered `HTTP Error 503: Backend unavailable, connection timeout` and
        # the very next subproject recovered by falling back to its GitHub
        # mirror. Short-circuiting there cost a whole chain run for an outage on
        # someone else's server, so a network-shaped failure is retried even when
        # it arrives in meson.build:LINE:COL clothing.
        $networkError = @($mesonOut + $mesonLogLines) -match 'HTTP Error \d+|Failed to download|URLError|SSLError|urlopen error|timed out|connection timeout|actively refused|Temporary failure in name resolution'
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
            # HOW THE HOST-ARCH LINK FAILURES WERE ENUMERATED (2026-08-23): ninja
            # stops at the FIRST failing target, so each plugin that links a
            # host-arch third-party library costs a full ~22-minute cycle to
            # discover -- openh264, gstvulkan and gstaes were each found that way,
            # one per run. Adding `--ninja-args=-k,0` keeps going and lists every
            # remaining one in a single pass; that sweep returned exactly four
            # targets, all OpenSSL (hls, dtls, aes, glib-networking's openssl
            # backend), which is what justified fixing OpenSSL once rather than
            # four plugins one at a time. Re-run that sweep after a GStreamer
            # version bump. NB the value needs ONE token with '=': argparse
            # refuses a separate value starting with '-', and meson parses it
            # with listify_array_value, so '-k,0' becomes ['-k','0'].
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
    # CROSS LANE: install with DESTDIR set, to the SAME location.
    #
    # A post-install script that cannot run aborts the whole install:
    #   ERROR: Failed to run install script gio-querymodules: Executable was not found
    #   ERROR: Install scripts failed to run
    # gio-querymodules indexes GIO modules and would have to EXECUTE an aarch64
    # binary on this x64 host. meson already has the escape hatch, and it is
    # keyed on DESTDIR (mesonbuild/minstall.py:709-713 and :729-731):
    #   if not destdir and len(failing_scripts) > 0:  raise 'Install scripts failed to run'
    #   if destdir and (isinstance(i, InstallScriptFailure) or i.skip_if_destdir):
    #       log('Skipping custom install script because DESTDIR is set')
    # i.e. DESTDIR is meson's "this is a staged/packaging install, do not try to
    # run target binaries" signal -- exactly this situation.
    #
    # DESTDIR is 'C:\' ON PURPOSE, so the files land where they always did and no
    # staging tree has to be moved afterwards. From mesonbuild/scripts/__init__.py:
    #   def destdir_join(d1, d2): return str(PurePath(d1, *PurePath(d2).parts[1:]))
    # PureWindowsPath('C:\runtime\bin').parts is ('C:\','runtime','bin'), so
    # parts[1:] drops the drive and PurePath('C:\','runtime','bin') is once again
    # C:\runtime\bin -- byte-identical to the non-DESTDIR path.
    #
    # amd64 keeps the plain invocation: there every install script CAN run, and
    # skipping gio-querymodules there would ship an unindexed GIO module dir.
    $installArgs = @('install', '-C', $resolvedBuildDir)
    if ($script:GstCross) {
        $installArgs += @('--destdir', 'C:\')
        log 'meson install --destdir C:\ (cross lane: makes meson SKIP install scripts that would have to run target binaries; the path is unchanged - see the comment above)'
    }
    & $mesonExe @installArgs 2>&1 | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'meson install failed' }
    log 'Installation complete.'

    # OpenSSL RUNTIME for the target (cross lane only; #127, measured arm64 run 13,
    # 2026-08-25). The link step above resolves libcrypto/libssl from the
    # C:\opt\openssl-arm64 import libs, but nothing installs the matching DLLs:
    # gsthls/gstdtls/gstaes and gio's openssl TLS module shipped importing
    # libcrypto-4-arm64.dll / libssl-4-arm64.dll that existed nowhere in the
    # bundle -- 6 of the 13 unresolved imports of the first whole-tree walk. On
    # amd64 the same plugins resolve scoop's x64 OpenSSL from the image PATH, an
    # image-level fact the artifact bundle cannot rely on: a clean device has
    # no OpenSSL at all. Stage the target DLLs into the bundle's DLL home
    # (C:\runtime\bin), PE-checked, found by NAME PATTERN rather than an assumed
    # slproweb layout ({app}\bin is where 4.0.1 keeps them today).
    if ($script:GstCross) {
        $sslRuntimeRoot = 'C:\opt\openssl-arm64'
        $sslDlls = @(Get-ChildItem -Path $sslRuntimeRoot -Recurse -File -Include 'libcrypto-*.dll', 'libssl-*.dll' -ErrorAction SilentlyContinue)
        if ($sslDlls.Count -eq 0) {
            throw "OpenSSL runtime DLLs (libcrypto-*/libssl-*) not found under $sslRuntimeRoot -- the hls/dtls/aes plugins and gio's TLS module would import a DLL the bundle does not carry (#127)"
        }
        # The package carries each DLL several times (4.0.1: four copies of
        # libcrypto/libssl, measured arm64 run 14) -- one per name is staged,
        # the copy under a \bin directory preferred, so the log and the bundle
        # say the same thing.
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
    # CROSS LANE: gst-inspect-1.0.exe is an aarch64 binary and this is an x64
    # host with no ARM64 emulation, so RUNNING it is not "a check that fails" --
    # it is a check that cannot exist. But "the DLL exists" was weaker than what
    # this host can actually verify (found 2026-08-24: the machinery below was
    # built, said of itself that dumpbin reads arm64 DLLs fine, and was then
    # never called on this branch). Static checks that DO run here:
    #   (a) dependency-tree walk via dumpbin /dependents -- catches the
    #       0xC0000135 class (a plugin whose import can never resolve) that the
    #       old filename glob waved through;
    #   (b) dumpbin /exports must show gst_plugin_desc -- the one export every
    #       real GStreamer plugin carries; its absence means "a DLL with the
    #       right name that is not a plugin".
    # Whether it is the right MACHINE is still verify-target-arch.ps1's job in
    # the merge stage.
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
                # Export marker: MEASURED, then hardened (both 2026-08-24). The
                # first version asserted the legacy `gst_plugin_desc` symbol and
                # failed ALL FOUR plugins including three proven loadable on
                # amd64 -- modern GStreamer (>=1.14 per-plugin registration)
                # exports gst_plugin_<name>_get_desc + gst_plugin_<name>_register
                # instead, confirmed by dumping the real export tables of all
                # four (libav/opencv/onnx/tflite showed exactly this pair). Now a
                # HARD assert again, on the measured, per-plugin marker.
                $exports = @(& $dumpbin /exports $pluginDll.FullName 2>&1)
                $marker = "gst_plugin_$($plugin.Name)_get_desc"
                if (-not ($exports -match [regex]::Escape($marker))) {
                    $exportNames = @($exports | Select-String '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)' |
                        ForEach-Object { $_.Matches.Groups[1].Value } | Select-Object -First 6)
                    $staticProblems += "$marker export missing (exports seen: $($exportNames -join ', '))"
                }
            } else {
                log '    (dumpbin unavailable - dependency/export checks skipped, DLL presence only)'
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