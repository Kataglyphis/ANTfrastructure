# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\ffmpeg-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$FfmpegVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through SourceBuild.Common's re-export.
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$FfmpegVersion = Get-SourceBuildVersion -Value $FfmpegVersion -EnvironmentVariables @('FFMPEG_VERSION') -DefaultValue 'n9.0'
$prefix = Join-Path $InstallDir 'ffmpeg'
$ffmpegDir = Join-Path $prefix 'bin'

# Windows -> MSYS path (C:\x\y -> /c/x/y). Every bash-facing path MUST go through
# this: a half-converted path once collapsed to /cruntimeffmpeg and make install
# silently delivered the whole tree into <git-root>\cruntimeffmpeg.
function ConvertTo-MsysPath([string]$Path) {
    return '/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

# FFmpeg-only Makefile fixup (moved here from WindowsSourceBuild.Common.psm1 on
# 2026-08-03 — this script was its only consumer, ever, and hosting it in the
# shared module rebuilt all three media branches whenever it changed): strips
# MSVC's -showIncludes + the awk dep-file pipelines from configure-generated
# *.mak files (clang-cl emits GNU-style deps; the awk pass both breaks and
# is superseded).
function Assert-FfmpegPkgConfig {
    # Gate on the .pc files `make install` produced. Both defects it guards were
    # silent for MONTHS because the files were PRESENT and looked fine:
    #
    #   Version: ..          configure found neither a VERSION file nor git tags
    #                        (GitHub auto-tarballs ship no VERSION, and the
    #                        git-init done after extraction carries no tags), so
    #                        its version substitutions expanded to nothing. No
    #                        consumer version constraint can match that, and
    #                        gst-libav is skipped without a word.
    #   prefix=/c/runtime    configure MUST get an MSYS --prefix or `make install`
    #                        lands in the wrong place, and FFmpeg copies that
    #                        string into every .pc. clang-cl and lld-link cannot
    #                        resolve /c/... , so the -I/-L flags are unusable.
    #
    # Lives in this script, not WindowsSourceBuild.Common.psm1: that module is in
    # the compile closure of all three media branches, so an FFmpeg-only helper
    # there rebuilds all of them on every edit. Same reasoning that moved
    # Remove-MakefileShowIncludes down here. Tests reach it by AST extraction
    # (SourceBuild.Artifact.Tests.ps1) rather than by importing a module.
    param(
        [Parameter(Mandatory)][string]$PkgConfigDir,
        # gst-libav's own floors: libavcodec >= 58.18.100, libavformat >=
        # 58.12.100, libavutil >= 56.14.100, libavfilter >= 7.16.100. Presence
        # and well-formedness are checked here; the floors themselves are
        # enforced where gst-libav is configured (Assert-PkgConfigModule).
        [string[]]$RequiredModule = @('libavcodec', 'libavformat', 'libavutil', 'libavfilter')
    )
    if (-not (Test-Path $PkgConfigDir -PathType Container)) {
        throw ("FFmpeg install produced no pkgconfig directory at $PkgConfigDir. " +
            'Every pkg-config consumer (gst-libav above all) resolves FFmpeg through these files; ' +
            'without them the merge stage silently drops the plugin. Did `make install` run?')
    }
    $versions = [ordered]@{}
    foreach ($required in $RequiredModule) {
        $pcPath = Join-Path $PkgConfigDir "$required.pc"
        if (-not (Test-Path $pcPath)) {
            throw "FFmpeg install produced no $required.pc — consumers resolving it via pkg-config (gst-libav) cannot build."
        }
        $pcText = Get-Content $pcPath -Raw
        $version = ([regex]::Match($pcText, '(?m)^Version:\s*(.+)$')).Groups[1].Value.Trim()
        if ($version -notmatch '^\d+(\.\d+)+$') {
            throw ("$required.pc declares an unusable version '$version'. FFmpeg's configure found neither a VERSION " +
                'file nor git tags, so its version substitutions expanded to nothing. No consumer version constraint ' +
                "can match this — gst-libav would be silently skipped. Check the VERSION file written after extraction.")
        }
        if ($pcText -match '(?m)^prefix=/[a-z]/') {
            throw "$required.pc still carries an MSYS prefix; native Windows consumers cannot use its -I/-L flags."
        }
        $versions[$required] = $version
    }
    $summary = ($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    Write-Host "FFmpeg .pc gate OK: $summary (real versions, Windows prefixes)"
    return $versions
}

function Remove-MakefileShowIncludes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$StripWildcardInclude
    )
    if (-not (Test-Path $Path)) { return }
    $c = [System.IO.File]::ReadAllText($Path)
    $c = $c -replace '-showIncludes', ''
    # -options:strict is cl.exe's strict-options flag; clang-cl does NOT
    # implement it and parses the prefix as the deprecated -o (output file!).
    # Bare builds survived only by argument ORDER (the later -Fo wins);
    # sccache rebuilds the command with -Fo FIRST, the hijack wins, and the
    # object lands invisibly in an NTFS alternate data stream
    # (ptions:strict.obj) at exit 0 -> "failed to zip up compiler outputs".
    # Stripping it is a correctness fix either way (probe-sccache-options-
    # strict.ps1 rounds 1-5, 2026-08-20) and unblocks the #100 launcher.
    $c = $c -replace '-options:strict\s*', ''
    $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
    $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
    $c = $c -replace '\s*\|\s*awk.*', ''
    if ($StripWildcardInclude) { $c = $c -replace '-include\s+\$\(wildcard\s+\*\.d\).*', '' }
    [System.IO.File]::WriteAllText($Path, $c)
}

Write-Host "=== FFmpeg source build ($FfmpegVersion, clang-cl+lld-link default; FFMPEG_TOOLCHAIN=msvc to override) ==="

if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    # #68: trust but VERIFY on re-entry. A -ResumeFrom after a failed run
    # used to take this return and inherit whatever the failure left -
    # incl. a prebuilt-fallback MIX (foreign exes/dlls over our import
    # libs/.pc) - with every gate below skipped. Run the .pc gate before
    # trusting; it throws on the mixed/broken shapes.
    $null = Assert-FfmpegPkgConfig -PkgConfigDir (Join-Path $prefix 'lib\pkgconfig')
    Write-Host "FFmpeg already installed at $prefix - .pc gate passed, skipping"; return
}

# Download and extract
$tarballPath = "$SourceDir\ffmpeg.tar.gz"
if (Test-Path $SourceDir) { Remove-Item $SourceDir -Recurse -Force }
New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null

Write-Host "Downloading FFmpeg $FfmpegVersion..."
if ($FfmpegVersion -in @('main', 'master', 'develop')) {
    try {
        Invoke-DownloadWithRetry -Url "https://github.com/FFmpeg/FFmpeg/archive/refs/heads/$FfmpegVersion.tar.gz" -DestinationPath $tarballPath -Description "FFmpeg $FfmpegVersion tarball"
    } catch {
        # FFmpeg GitHub mirror uses 'master' as default branch; fall back if branch not found
        Write-Warning "FFmpeg branch '$FfmpegVersion' not found, trying 'master'..."
        Invoke-DownloadWithRetry -Url 'https://github.com/FFmpeg/FFmpeg/archive/refs/heads/master.tar.gz' -DestinationPath $tarballPath -Description 'FFmpeg master tarball'
        $FfmpegVersion = 'master'
    }
} else {
    Invoke-DownloadWithRetry -Url "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FfmpegVersion.tar.gz" -DestinationPath $tarballPath -Description "FFmpeg $FfmpegVersion tarball"
}
Write-Host "Extracting tarball..."
$srcDir = Expand-SourceTarball -Archive $tarballPath -Destination $SourceDir
Write-Host "Source at: $srcDir"

# git-init the extracted tarball so Invoke-SourcePatch takes its .git fast-path (git
# apply). Without this its git-repo probe writes to stderr, which PS 5.1 under EAP=Stop
# turns into a terminating NativeCommandError; the helper shields git output via cmd.exe.
Initialize-ExtractedGitRepo -Path $srcDir

# ── VERSION file: without it every generated .pc says "Version: .." ───────────
# FFmpeg's configure derives its version from $source_path/VERSION, falling back
# to `git describe`. NEITHER exists here: GitHub's auto-generated
# archive/refs/tags tarballs carry no VERSION file (only ffmpeg.org release
# tarballs do), and the git-init above creates a repo with no tags for describe
# to find. Both probes come up empty, the major/minor/micro substitutions expand
# to nothing, and every installed .pc ends up with a literal
#
#     Version: ..
#
# which no version constraint can satisfy. Measured 2026-08-07 by probing the
# built image: that ALONE keeps gst-libav out of the final image, because it
# demands libavcodec >= 58.18.100 and three siblings — a second, independent
# cause on top of the FFmpeg.wrap trap. The files existed and looked plausible,
# so nothing ever flagged it.
#
# FFMPEG_VERSION is a pinned release tag ('n9.0'), so the value is already at
# hand; strip the tag's leading 'n' to get FFmpeg's own version string.
$ffmpegVersionNumber = ([string]$FfmpegVersion) -replace '^n', ''
if ($ffmpegVersionNumber -match '^\d+(\.\d+)*$') {
    Set-Content -Path (Join-Path $srcDir 'VERSION') -Value $ffmpegVersionNumber -Encoding ascii -NoNewline
    Write-Host "Wrote VERSION=$ffmpegVersionNumber (GitHub tarballs ship none; configure would emit 'Version: ..' in every .pc)"
} else {
    # A branch build ('master') has no meaningful release number — leave it to
    # configure rather than inventing one, and say so.
    Write-Warning "FFMPEG_VERSION '$FfmpegVersion' is not a release number; .pc Version fields may come out empty."
}

# ── lib*.version files (n9.0 mechanics): since n9.0 every .pc gets its
# Version from a GENERATED libX/libX.version file (library.mak rule ->
# ffbuild/libversion.sh awk/eval chain), and under this Git-Bash port that
# chain produced empty MAJOR/MINOR/MICRO (run 14, 2026-08-11: every
# installed .pc said 'Version: ..' and the guard below refused - correctly).
# The values are static facts of the pinned source, so write the files
# ourselves: LF + no BOM (make -includes them for LIBVERSION/LIBMAJOR = DLL
# naming!), mtime newer than the headers so library.mak never re-runs the
# fragile generator. Format mirrors libversion.sh's output exactly.
$ffLibs = 'avutil', 'avcodec', 'avformat', 'avdevice', 'avfilter', 'swscale', 'swresample', 'postproc'
foreach ($ffLib in $ffLibs) {
    $ffLibDir = Join-Path $srcDir "lib$ffLib"
    if (-not (Test-Path $ffLibDir)) { continue }
    $ffLibText = ''
    foreach ($h in @((Join-Path $ffLibDir 'version_major.h'), (Join-Path $ffLibDir 'version.h'))) {
        if (Test-Path $h) { $ffLibText += [System.IO.File]::ReadAllText($h) + "`n" }
    }
    $ffLibUc = "LIB$($ffLib.ToUpper())"
    $ffMaj = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MAJOR\s+(\d+)") { $Matches[1] } else { '' }
    $ffMin = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MINOR\s+(\d+)") { $Matches[1] } else { '' }
    $ffMic = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MICRO\s+(\d+)") { $Matches[1] } else { '' }
    if (-not ($ffMaj -and $ffMin -and $ffMic)) {
        throw "lib$ffLib version macros not found in version(.major).h (upstream layout changed?) - refusing to write a broken .version file"
    }
    $ffVerContent = "lib${ffLib}_VERSION=$ffMaj.$ffMin.$ffMic`nlib${ffLib}_VERSION_MAJOR=$ffMaj`nlib${ffLib}_VERSION_MINOR=$ffMin`n"
    [System.IO.File]::WriteAllText((Join-Path $ffLibDir "lib$ffLib.version"), $ffVerContent)
    Write-Host "Wrote lib$ffLib.version = $ffMaj.$ffMin.$ffMic (bypasses the libversion.sh awk chain)"
}

# Set up environment: VsDevCmd (MSVC tools) + Git Bash + Scoop make/gawk
Enter-VsDevCmdEnvironment
$scoopShims = "$env:USERPROFILE\scoop\shims"
# #76 insurance: this provisioning region once sat SILENT for exactly
# 7200.9 s (a network timeout inside a scoop fetch; normal is 11-18 s,
# 14 clean runs since - latent, not active). Bound it: the step runs as a
# job with a heartbeat every minute and a hard 10-min ceiling, so a
# recurrence costs minutes and names itself instead of eating 2 h mute.
function Invoke-BoundedProvisionStep {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Step,
        [int]$TimeoutMinutes = 10
    )
    $stepStart = Get-Date
    $job = Start-Job -ScriptBlock $Step
    try {
        while ($job.State -eq 'Running' -and (Get-Date) -lt $stepStart.AddMinutes($TimeoutMinutes)) {
            $null = Wait-Job -Job $job -Timeout 60
            if ($job.State -eq 'Running') {
                Write-Host ("  [{0}] still running ({1:N0}s) - heartbeat (#76 guard)" -f $Label, ((Get-Date) - $stepStart).TotalSeconds)
            }
        }
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job
            throw "$Label exceeded $TimeoutMinutes min - the #76 stall class (2h-mute network timeout); rerun or check egress."
        }
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}
# Ensure make is available
if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
    Write-Host "Installing make via scoop..."
    Invoke-BoundedProvisionStep -Label 'scoop install make' -Step { & scoop install main/make 2>&1 }
}
# Install gawk and replace MSYS2's broken awk
if (-not (Get-Command gawk -ErrorAction SilentlyContinue)) {
    Write-Host "Installing gawk via scoop..."
    Invoke-BoundedProvisionStep -Label 'scoop install gawk' -Step { & scoop install main/gawk 2>&1 }
}
# Replace MSYS2 awk with gawk for FFmpeg dep file processing
$gitAwk = 'C:\Program Files\Git\usr\bin\awk.exe'
$gawkExe = Join-Path $scoopShims 'gawk.exe'
if ((Test-Path $gitAwk) -and (Test-Path $gawkExe)) {
    Copy-Item $gawkExe $gitAwk -Force
    Write-Host "Replaced MSYS2 awk with gawk"
}
$gitUsrBin = 'C:\Program Files\Git\usr\bin'
$env:PATH = "$scoopShims;$gitUsrBin;$env:PATH"
$bashExe = Join-Path $gitUsrBin 'bash.exe'

# ── NVIDIA hardware video (NVENC / NVDEC / CUVID) ────────────────────────────
# nv-codec-headers ships the ffnvcodec headers + ffnvcodec.pc that FFmpeg's configure requires.
# These paths are header-only: FFmpeg dlopen()s the encoder/decoder from the NVIDIA driver at
# runtime, so NO nvcc and NO CUDA libs are needed -- they build under the existing --toolchain=msvc.
# Guarded on an actual nvidia CUDA toolkit so the CPU-only lane is untouched. --enable-cuda-nvcc
# (which COMPILES CUDA *filters* and would need nvcc under the msvc toolchain) is deliberately left off.
$nvencFlags = @()
$ffGpu = Get-GpuEnvironment
if ($ffGpu.GpuType -eq 'nvidia' -and $ffGpu.CudaRoot -and (Test-Path (Join-Path $ffGpu.CudaRoot 'include\cuda.h'))) {
    Write-Host 'NVIDIA CUDA detected -> enabling FFmpeg NVENC/NVDEC/CUVID via nv-codec-headers'
    # pkg-config is required by configure to locate ffnvcodec and is not present in the media build
    # image, so install it the same scoop way make/gawk are installed above.
    if (-not (Get-Command pkg-config -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing pkg-config via scoop...'
        & scoop install main/pkg-config 2>&1 | Out-Null
    }
    # Clone the pinned nv-codec-headers ref and `make install` into a private prefix. PREFIX is a
    # forward-slash *Windows* path (C:/...), NOT an MSYS /c/... path, so the generated ffnvcodec.pc
    # emits `-IC:/.../include` cflags that cl.exe consumes directly (verified in an isolated lab).
    $nvHdrRef       = if ($env:NV_CODEC_HEADERS_REF) { $env:NV_CODEC_HEADERS_REF } else { 'n13.1.15.0' }
    $nvHdrSrc       = 'C:\temp\nv-codec-headers'
    $nvHdrPrefix    = 'C:\temp\nv-codec-headers-install'
    $nvHdrPrefixFwd = $nvHdrPrefix -replace '\\', '/'
    if (Test-Path $nvHdrSrc)    { Remove-Item $nvHdrSrc -Recurse -Force }
    if (Test-Path $nvHdrPrefix) { Remove-Item $nvHdrPrefix -Recurse -Force }
    # Canonical stderr-shield (Invoke-ShieldedNative): git writes "Cloning into..." to stderr,
    # which under the in-container PS 5.1 EAP=Stop would otherwise surface as a terminating
    # NativeCommandError (2>&1 alone does NOT prevent it in 5.1).
    [void](Invoke-ShieldedNative -Label 'nv-codec-headers clone' -CommandLine "git clone --branch $nvHdrRef --depth 1 https://github.com/FFmpeg/nv-codec-headers.git `"$nvHdrSrc`"")
    $nvHdrSrcCyg = ConvertTo-MsysPath $nvHdrSrc
    [void](Invoke-ShieldedNative -Label 'nv-codec-headers make install' -CommandLine "`"$bashExe`" -c `"cd $nvHdrSrcCyg && make install PREFIX=$nvHdrPrefixFwd`"")
    $nvPc = Join-Path $nvHdrPrefix 'lib\pkgconfig\ffnvcodec.pc'
    if (Test-Path $nvPc) {
        # Native (scoop) pkg-config reads a Windows-path PKG_CONFIG_PATH; the bash configure wrapper
        # inherits this process env, so no wrapper change is needed.
        $nvPcDir = Join-Path $nvHdrPrefix 'lib\pkgconfig'
        $env:PKG_CONFIG_PATH = $nvPcDir + $(if ($env:PKG_CONFIG_PATH) { ";$env:PKG_CONFIG_PATH" } else { '' })
        $nvencFlags = @('--enable-ffnvcodec', '--enable-nvenc', '--enable-nvdec', '--enable-cuvid')
        Write-Host "ffnvcodec $nvHdrRef installed -> $nvPc"
    } else {
        Write-Warning 'nv-codec-headers install produced no ffnvcodec.pc -- FFmpeg will build without NVIDIA video accel.'
    }
} else {
    Write-Host 'FFmpeg: no nvidia CUDA toolkit -> building without NVENC/NVDEC (CPU-only lane)'
}

$cygPrefix = ConvertTo-MsysPath $prefix
$cygSrc = ConvertTo-MsysPath $srcDir

# Ensure ONNX Runtime is discoverable for --enable-libonnxruntime.
# Copy the ONNX header into FFmpeg's include/compat directory so configure's
# test_cc probes can find it without --extra-cflags (which doesn't get passed
# to test compilations when using the msvc-preset flag conventions).
$onnxRuntimeDir = Join-Path $InstallDir 'lib\onnxruntime-source'
$onnxHeaderCopied = $false
if (Test-Path $onnxRuntimeDir) {
    $header = Get-ChildItem "$onnxRuntimeDir" -Recurse -Filter 'onnxruntime_c_api.h' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($header) {
        $ffCompatInc = Join-Path $srcDir 'compat\onnx'
        New-Item -Path $ffCompatInc -ItemType Directory -Force | Out-Null
        # Mirror the WHOLE staged include dir, not a hand-picked header list:
        # ORT 1.28 split the C API across new siblings (onnxruntime_error_code.h)
        # and the old c/cxx/ep cherry-pick made configure's probe fail with
        # 'file not found'. Copying everything is drift-proof.
        $ortHeaders = @(Get-ChildItem $header.Directory -File)
        $ortHeaders | Copy-Item -Destination $ffCompatInc -Force
        Write-Host "Copied $($ortHeaders.Count) ONNX header(s) to: $ffCompatInc"
        $onnxHeaderCopied = $true
    } else {
        Write-Warning "ONNX Runtime header onnxruntime_c_api.h not found under $onnxRuntimeDir"
    }
}

$confFlags = @()
$confFlags += "--prefix=$cygPrefix"
$confFlags += '--enable-shared', '--disable-static'
$confFlags += '--disable-debug', '--disable-doc'
# No --enable-nonfree: nothing in this build needs it, and nonfree builds are
# not redistributable (the images are published). GPL+version3 covers x264 etc.
$confFlags += '--enable-gpl', '--enable-version3'
$confFlags += '--enable-ffmpeg', '--enable-ffprobe'
if ($onnxHeaderCopied) {
    $confFlags += '--enable-libonnxruntime'
    $confFlags += "--extra-cflags=-I$cygSrc/compat/onnx"
    $confFlags += "--extra-ldflags=-libpath:$($onnxRuntimeDir -replace '\\', '/')/lib"
}
# Toolchain: clang-cl + lld-link by default, so FFmpeg's C sources are LLVM-compiled like every other
# library in the container (set FFMPEG_TOOLCHAIN=msvc to fall back to the MSVC preset). FFmpeg has no
# clang-cl toolchain preset, so we keep the msvc preset (MSVC-style flag conventions + the inherited
# VsDevCmd SDK env, both of which clang-cl mimics) and override only the compiler/linker. x86asm is
# disabled either way, so nasm/inline-asm is not in play. Proven: full clang-cl build links ffmpeg.exe
# + 7 DLLs with --enable-libonnxruntime + NVENC, 0 errors (validated in windows-media-core).
$ffToolchain = if ($env:FFMPEG_TOOLCHAIN) { $env:FFMPEG_TOOLCHAIN } else { 'clang-cl' }
if ($ffToolchain -eq 'clang-cl') {
    # #100: FFmpeg does not use CMake, so the module's CMAKE_*_COMPILER_LAUNCHER
    # wiring never reached it - the stage reported `Compile requests 0` (not "0
    # hits": ZERO requests) in every build. The launcher must NOT go into
    # configure's --cc: configure's own compiler tests (MSYS relative paths,
    # -P/-EP preprocess modes) produce objects lld-link rejects as "unknown
    # file type" through sccache (measured 2026-08-19, ride 4). configure runs
    # BARE; the launcher is injected at MAKE time instead (make CC=... beats
    # config.mak). Opt out: FFMPEG_SCCACHE=0. Acceptance criterion is `Compile
    # requests` > 0 in the stage stats, NOT the hit rate (uncached components
    # are invisible in aggregate hit rates).
    $ffSccache = Get-Command sccache.exe -ErrorAction SilentlyContinue
    $ffUseLauncher = [bool]($ffSccache -and $env:FFMPEG_SCCACHE -ne '0')
    Write-Host "FFmpeg toolchain: clang-cl + lld-link (overriding the msvc preset's cc/ld; make-time sccache launcher: $ffUseLauncher)"
    $confFlags += '--toolchain=msvc', '--cc=clang-cl', '--ld=lld-link'
} else {
    Write-Host 'FFmpeg toolchain: msvc (cl.exe + link.exe)'
    $confFlags += '--toolchain=msvc'
}
$confFlags += '--disable-x86asm'
# vfwcap links vfw32.lib -> imports AVICAP32.dll, which does NOT exist in
# Windows Server Core containers: every process loading avdevice would die
# with STATUS_DLL_NOT_FOUND. DirectShow capture (dshow) remains available.
$confFlags += '--disable-indev=vfwcap'
# NVIDIA hardware video accel: empty on the CPU-only lane, populated above when CUDA is present.
$confFlags += $nvencFlags

# Shell-quote flags carrying spaces (--cc='sccache clang-cl') - the wrapper
# line is parsed by bash, and an unquoted space would split the flag in two.
$confStr = ($confFlags | ForEach-Object { if ($_ -match ' ') { "'$_'" } else { $_ } }) -join ' '

# Patch configure to allow MSYS2 builds (official docs say MSYS is discouraged)
Invoke-SourcePatch -PatchFile (Join-Path $scriptAssetRoot 'patches\ffmpeg\001-allow-msys-builds.patch') -SourceDir $srcDir -IgnoreWhitespace

# Write configure wrapper. VsDevCmd INCLUDE/LIB env vars are inherited from PowerShell,
# so MSVC SDK paths are available. --extra-cflags adds our ONNX include path.
$wrapperLines = @()
$wrapperLines += '#!/usr/bin/env bash'
$wrapperLines += "cd $cygSrc"
$wrapperLines += 'export MSYS=winsymlinks:lnk'
$wrapperLines += 'export TMPDIR=tmpdir'
$wrapperLines += 'rm -rf tmpdir; mkdir -p tmpdir'
$wrapperLines += "./configure $confStr"

$wrapperPath = Join-Path $srcDir 'ffmpeg-configure-wrapper.sh'
[System.IO.File]::WriteAllLines($wrapperPath, $wrapperLines)

Write-Host "Configuring FFmpeg (toolchain: $ffToolchain)..."
& $bashExe $wrapperPath 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    $logFile = Join-Path $srcDir 'ffbuild\config.log'
    if (Test-Path $logFile) { Write-Host "=== config.log (last 50 lines) ==="; Get-Content $logFile -Tail 50 }
    throw "FFmpeg configure failed (exit $LASTEXITCODE)"
}
# #100: CC in config.mak is the BARE compiler by design (see the toolchain
# note above); the launcher rides in as a make-time override. Echo it for the
# log so a cache regression is diagnosable from the build output alone.
$configMak = Join-Path $srcDir 'ffbuild\config.mak'
if (Test-Path $configMak) {
    $ccLine = (Select-String -Path $configMak -Pattern '^CC=' | Select-Object -First 1).Line
    Write-Host "config.mak: $ccLine (make-time sccache launcher: $ffUseLauncher)"
}

Write-Host 'Building FFmpeg (this may take 30-60 minutes)...'
# Inline patches (kept inline, NOT .patch files): the targets below are *generated*
# by FFmpeg's `./configure` (ffbuild/*.mak, library.mak, subdir.mak, Makefile,
# ffbuild/config.mak). Generated content differs per configure invocation
# (probe results, lib list, OS detection), so a static .patch cannot match
# reliably across builds. The `-replace` form targets invariant sub-sequences
# (`-showIncludes`, `EXTRALIBS-lib*=`) that configure writes the same way for
# the msvc toolchain. See docs/windows-builds.md "Source Patch Policy".
$ffbuildDir = Join-Path $srcDir 'ffbuild'
Get-ChildItem -Path $ffbuildDir -Filter '*.mak' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-MakefileShowIncludes -Path $_.FullName
}
foreach ($fn in @('library.mak', 'subdir.mak', 'Makefile')) {
    Remove-MakefileShowIncludes -Path (Join-Path $srcDir $fn) -StripWildcardInclude
}
# Inter-library import-lib deps for the linker (configure may not generate
# EXTRALIBS at all under the msvc preset). ONE map drives both the in-place
# replace and the append fallback -- the previous twin lists had to be kept
# byte-identical by hand.
$configMakPath = Join-Path $srcDir 'ffbuild/config.mak'
if (Test-Path $configMakPath) {
    $extraLibs = [ordered]@{
        'libswresample' = 'avutil.lib'
        'libswscale'    = 'avutil.lib'
        'libavcodec'    = 'avutil.lib'
        'libavfilter'   = 'avutil.lib'
        'libavformat'   = 'avutil.lib avcodec.lib'
        'libavdevice'   = 'avformat.lib avcodec.lib avutil.lib'
    }
    $cm = [System.IO.File]::ReadAllText($configMakPath)
    foreach ($lib in $extraLibs.Keys) {
        $line = "EXTRALIBS-$lib=$($extraLibs[$lib])"
        if ($cm -match "(?m)^EXTRALIBS-$lib\s*=") {
            $cm = $cm -replace "(?m)^EXTRALIBS-$lib\s*=.*", $line
        } else {
            $cm += "`n$line"
        }
    }
    [System.IO.File]::WriteAllText($configMakPath, $cm)
}

# Replace makedef wholesale (full-file overwrite, deliberately NOT a .patch:
# the file is completely rewritten, so a context diff adds only fragility —
# it broke twice on upstream drift / git-apply quirks). The replacement expands
# version-script globs against per-object llvm-nm symbol dumps via xargs,
# avoiding the upstream script's single lib.exe call that exceeds the Windows
# command-line length limit for libavcodec.
$makedefSrc = Join-Path $scriptAssetRoot 'patches\ffmpeg\makedef'
$makedefDst = Join-Path $srcDir 'compat\windows\makedef'
Copy-Item $makedefSrc $makedefDst -Force
Write-Host "Replaced compat/windows/makedef (glob-expanding, response-file-aware)"

# Parallel compile first; make is incremental, so the -j1 retry below only redoes
# what failed. Parallel -jN can hit spurious LNK1120 link races with MSVC when
# library dependencies (libavutil -> libswscale) aren't fully linked before
# consumers — the serial retry resolves those deterministically.
$makeJobs = Get-BuildJobCount -MemGBPerJob 2
# #100 RE-ENABLED 2026-08-20: the "failed to zip up compiler outputs" crash
# was ROOT-CAUSED to -options:strict (clang-cl parses its prefix as the
# deprecated -o; sccache's arg reorder let that hijack the output into an
# NTFS alternate data stream - see Remove-MakefileShowIncludes). With the
# flag stripped from the generated maks the launcher is safe at make time;
# configure stays bare (its own compiler tests still break through sccache,
# "unknown file type" - measured 2026-08-19).
$makeCc = if ($ffUseLauncher) { " CC='sccache clang-cl'" } else { '' }
# All three make calls are -Optional by design: a parallel-link race falls
# through to the -j1 retry, and an incomplete build/install falls through to
# the artifact verification + prebuilt fallback below (never throw here).
[void](Invoke-ShieldedNative -Optional -Label "ffmpeg make -j$makeJobs" -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make -j$makeJobs$makeCc`"")
$builtFfmpeg = Join-Path $srcDir 'ffmpeg.exe'
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Retrying with single job (resolves MSVC link races)...'
    [void](Invoke-ShieldedNative -Optional -Label 'ffmpeg make -j1' -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make -j1$makeCc`"")
}
# Source build may fail at link stage (EXTRALIBS config issue with MSVC/MSYS2).
# Fall through to download a pre-built MSVC FFmpeg binary.
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Source build of FFmpeg did not produce ffmpeg.exe (link stage incomplete).'
}
Write-Host 'Attempting install from source if built...'
[void](Invoke-ShieldedNative -Optional -Label 'ffmpeg make install (verify below)' -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make install`"")

# A --enable-shared build is only usable if the av*.dll runtime libraries were
# installed next to the exes; exes alone die with STATUS_DLL_NOT_FOUND. Treat an
# incomplete install as a failed source build so the fallback (or a loud error)
# kicks in instead of shipping a broken ffmpeg.
$installedDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
if ((Test-Path "$ffmpegDir\ffmpeg.exe") -and $installedDlls.Count -eq 0) {
    Write-Warning 'Source install produced exes but no av*.dll runtime libraries - discarding as incomplete.'
    Remove-Item "$ffmpegDir\ffmpeg.exe", "$ffmpegDir\ffplay.exe", "$ffmpegDir\ffprobe.exe" -Force -ErrorAction SilentlyContinue
}

# Prebuilt fallback: FAIL-CLOSED by default since #68 (2026-08-20). The
# chain promise is OUR FFmpeg (avcodec 63, --enable-libonnxruntime, the one
# OpenCV links against since OPENCV_LINK_CHAIN_FFMPEG defaulted on) - a
# silent BtbN substitute violates that AND used to land as a MIX: foreign
# exes/dlls copied over whatever a partial `make install` left, while our
# import libs and .pc files stayed, so gst-libav linked a version mismatch
# announced by one Write-Warning. Opt in explicitly for experiments with
# FFMPEG_ALLOW_PREBUILT=1; the opt-in path now SCRUBS the whole prefix
# first so the result is at least self-consistent.
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) {
    if ($env:FFMPEG_ALLOW_PREBUILT -ne '1') {
        throw ('FFmpeg source build did not produce ffmpeg.exe and the prebuilt fallback is fail-closed (#68) - ' +
            'fix the source build (see the make output above) or opt in explicitly with FFMPEG_ALLOW_PREBUILT=1.')
    }
    Write-Warning 'FFmpeg source build failed -- falling back to pre-built BtbN MSVC FFmpeg (FFMPEG_ALLOW_PREBUILT=1). DNN/ONNX integration will NOT be available in the fallback binary.'
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '0', 'Process')
    # No MIXED installs: wipe every artifact of the partial source install
    # (import libs, headers, .pc) before the foreign binaries land.
    Reset-SourceBuildDirectory -Path $prefix
    if (-not (Test-Path $prefix)) { New-Item -Path $prefix -ItemType Directory -Force | Out-Null }
    $dlUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    $zipPath = "$env:TEMP\ffmpeg.zip"
    Invoke-DownloadWithRetry -Url $dlUrl -DestinationPath $zipPath -Description 'BtbN prebuilt FFmpeg'
    & 7z x "$zipPath" -o"$env:TEMP\ffmpeg-extract" -y -bd 2>&1 | Out-Null
    $binDir = Get-ChildItem -Path "$env:TEMP\ffmpeg-extract" -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DirectoryName
    if ($binDir) {
        if (-not (Test-Path $ffmpegDir)) { New-Item -Path $ffmpegDir -ItemType Directory -Force | Out-Null }
        Copy-Item "$binDir\*.exe" "$ffmpegDir\" -Force
        Copy-Item "$binDir\*.dll" "$ffmpegDir\" -Force
    }
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\ffmpeg-extract" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '1', 'Process')
}

# ── Make the installed .pc files usable by NATIVE Windows consumers ───────────
# configure is run under MSYS bash and MUST get an MSYS --prefix (see
# ConvertTo-MsysPath above) or `make install` lands in the wrong place. FFmpeg
# then writes that same MSYS path into every generated .pc:
#
#     prefix=/c/runtime/ffmpeg
#
# pkg-config hands those through verbatim, and the consumers here are NATIVE
# Windows tools — clang-cl and lld-link cannot resolve /c/... , so the emitted
# -I/-L flags are unusable. (The nv-codec-headers block above already dodges
# this by installing with a Windows-shaped prefix; FFmpeg's own install cannot,
# hence this rewrite afterwards.) Same class of defect as the empty Version
# field: the files exist and look fine, so nothing flags them.
$ffPkgConfigDir = Join-Path $prefix 'lib\pkgconfig'
if (Test-Path $ffPkgConfigDir) {
    $winPrefix = ($prefix -replace '\\', '/')   # C:/runtime/ffmpeg
    # Reuse the exact string configure was given ($cygPrefix, line ~183) rather
    # than re-deriving it — a second conversion could drift from the first and
    # then silently match nothing.
    $msysPrefix = $cygPrefix -replace '\\', '/' # /c/runtime/ffmpeg
    $rewritten = 0
    foreach ($pc in Get-ChildItem -Path $ffPkgConfigDir -Filter '*.pc' -File) {
        $text = Get-Content $pc.FullName -Raw
        if ($text -notmatch [regex]::Escape($msysPrefix)) { continue }
        Set-Content -Path $pc.FullName -Value ($text -replace [regex]::Escape($msysPrefix), $winPrefix) -Encoding ascii -NoNewline
        $rewritten++
    }
    Write-Host "Rewrote MSYS prefixes to Windows form in $rewritten .pc file(s) under $ffPkgConfigDir"
}

# Called OUTSIDE the Test-Path guard above on purpose: until 2026-08-08 the gate
# sat inside it, so a missing lib\pkgconfig directory — the most complete failure
# of all — skipped every assertion and reported nothing. Assert-FfmpegPkgConfig
# treats an absent directory as the hard failure it is. The explicitly opted-in
# prebuilt fallback (#68) ships NO .pc files BY DESIGN (the prefix is scrubbed,
# nothing links against it) — that is the one legitimate skip.
if ($env:FFMPEG_SOURCE_BUILD -eq '0') {
    Write-Warning 'Prebuilt fallback active (FFMPEG_ALLOW_PREBUILT=1): no .pc files exist by design; downstream consumers (gst-libav, OpenCV chain-link, PyAV) will not find FFmpeg.'
} else {
    $null = Assert-FfmpegPkgConfig -PkgConfigDir $ffPkgConfigDir
}

# ── Import-lib normalization (PyAV and other MSVC-style consumers link these) ──
# `make install` places avformat.lib / avformat-63.def per configure's SHLIBDIR/
# LIBDIR split, and ffmpeg master (a live branch) has already moved that layout
# once (2026-07-13: lib\ suddenly had no .lib at all -> PyAV LNK1181). Instead of
# chasing upstream, normalize: harvest every .lib/.def from the whole install
# prefix AND the build tree into lib\, then regenerate any still-missing import
# lib from its .def (lib.exe is in the VsDevCmd env). Each step logs what it
# found so the next drift is visible in the build log, not a linker error.
if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    $ffLibDir = Join-Path $prefix 'lib'
    New-Item -Path $ffLibDir -ItemType Directory -Force | Out-Null
    foreach ($pattern in @('*.lib', '*.def')) {
        $harvest = @(Get-ChildItem $prefix -Recurse -Filter $pattern -ErrorAction SilentlyContinue) +
                   @(Get-ChildItem $srcDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '^(av|sw)' })
        foreach ($f in $harvest) {
            if ($f.DirectoryName -ne $ffLibDir) {
                Write-Host "harvesting $($f.Name) from $($f.DirectoryName)"
                Copy-Item $f.FullName $ffLibDir -Force
                # inside the install prefix this is a relocation, not a copy:
                # bin\ must ship only runtime DLLs + exes
                if ($f.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item $f.FullName -Force
                }
            }
        }
    }
    foreach ($defFile in @(Get-ChildItem $ffLibDir -Filter '*.def' -ErrorAction SilentlyContinue)) {
        # avformat-63.def -> avformat.lib (unversioned, what PyAV's -lavformat resolves)
        $libName = ($defFile.BaseName -replace '-\d+$', '') + '.lib'
        $libPath = Join-Path $ffLibDir $libName
        if (-not (Test-Path $libPath)) {
            Write-Host "regenerating $libName from $($defFile.Name)"
            # /name pins the DLL the import lib binds to (our makedef emits EXPORTS only)
            [void](Invoke-ShieldedNative -Label "lib.exe /def $($defFile.Name)" -CommandLine "lib.exe /nologo /machine:x64 /def:`"$($defFile.FullName)`" /name:$($defFile.BaseName).dll /out:`"$libPath`"")
        }
    }
    # Single authoritative inventory + assertion: the PyAV step (and any other
    # MSVC-style consumer) links these; fail HERE with data instead of a bare
    # LNK1181 deep inside a setup.py (bit us 2026-07-13). The BtbN prebuilt
    # fallback legitimately ships no import libs, so only a SOURCE build
    # asserts (the fallback already warned and skips PyAV below).
    $ffImportLibs = @(Get-ChildItem $ffLibDir -Filter '*.lib' -ErrorAction SilentlyContinue | ForEach-Object Name)
    Write-Host ("import libs in ${ffLibDir}: " + (($ffImportLibs | Sort-Object) -join ', '))
    if (([Environment]::GetEnvironmentVariable('FFMPEG_SOURCE_BUILD', 'Process') -eq '1') -and
        ($ffImportLibs -notcontains 'avformat.lib')) {
        Write-Host ("lib dir inventory: " + ((Get-ChildItem $ffLibDir -Name -ErrorAction SilentlyContinue) -join ', '))
        throw "ffmpeg install has no avformat.lib in $ffLibDir -- master drift broke import-lib generation"
    }
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host "=== FFmpeg build completed ==="
Write-Host "Artifacts at: $prefix"
if (Test-Path "$ffmpegDir\ffmpeg.exe") { Write-Host "ffmpeg.exe installed" }
if (Test-Path "$ffmpegDir\ffprobe.exe") { Write-Host "ffprobe.exe installed" }
$finalDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
Write-Host "runtime DLLs installed: $($finalDlls.Count)"
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) { throw 'FFmpeg install incomplete: no ffmpeg.exe (source build and fallback both failed)' }

# ── PyAV wheel built against THIS FFmpeg ─────────────────────────────────────
# The PyPI av wheel is structurally unloadable on Server Core (its bundled
# avdevice hard-imports AVICAP32.dll, a desktop-only VfW DLL), so build PyAV
# from sdist against OUR install: setup.py's --ffmpeg-dir argv flag supplies
# include/lib directly (its pkg-config path never engages on this lane), and
# python314.lib lives in PCbuild\amd64, reachable only via the LIB env var.
# Compiles clean against ffmpeg master (verified 2026-07-13); OUR avdevice
# imports only Server-Core-present system DLLs. The wheel's av* DLL deps
# resolve at runtime via the sitecustomize dll-dir shim (ffmpeg\bin is listed).
if ([Environment]::GetEnvironmentVariable('FFMPEG_SOURCE_BUILD', 'Process') -ne '1') {
    Write-Warning 'FFmpeg came from the prebuilt fallback (no headers/import libs) -- skipping the PyAV wheel build.'
    return
}
$pyavVersion = Get-SourceBuildVersion -EnvironmentVariables @('PYAV_VERSION') -DefaultValue '18.1.0'
Write-Host "=== PyAV $pyavVersion wheel build (against $prefix) ==="
# Import libs already inventoried + asserted by the normalization block above
# (source-built path is guaranteed here by the FFMPEG_SOURCE_BUILD gate).
$py = Get-SourceBuildPython
Install-CpythonPip -Python $py
Initialize-PythonPlatformTag | Out-Null
Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'cython', 'setuptools', 'wheel')
$pyavSrcRoot = 'C:\temp\pyav-src'
New-Item -Path $pyavSrcRoot -ItemType Directory -Force | Out-Null
Invoke-CpythonPip -Python $py -Arguments @('download', "av==$pyavVersion", '--no-binary', ':all:', '--no-deps', '--no-build-isolation', '-d', $pyavSrcRoot)
$pyavSdist = Get-ChildItem $pyavSrcRoot -Filter 'av-*.tar.gz' | Select-Object -First 1
if (-not $pyavSdist) { throw "PyAV sdist not downloaded to $pyavSrcRoot" }
[void](Invoke-ShieldedNative -Label 'PyAV sdist extract' -CommandLine """$($py.Exe)"" -m tarfile -e ""$($pyavSdist.FullName)"" ""$pyavSrcRoot""")
$pyavDir = (Get-ChildItem $pyavSrcRoot -Directory | Select-Object -First 1).FullName
$env:LIB = "$($py.LibDir);$env:LIB"
Push-Location $pyavDir
try {
    [void](Invoke-ShieldedNative -Label 'PyAV setup.py bdist_wheel' -CommandLine """$($py.Exe)"" setup.py --ffmpeg-dir=""$prefix"" bdist_wheel")
} finally { Pop-Location }
Install-StagedPythonWheel -Python $py -SourceDir (Join-Path $pyavDir 'dist') -ModuleName 'av' -NoDeps | Out-Null
Remove-SourceBuildTree -Path $pyavSrcRoot
Write-Host '=== PyAV wheel build completed ==='

# Explicit success: pwsh -File (and docker run) propagate the LAST native exit
# code otherwise -- a best-effort cleanup once failed a fully green stage with
# exit 145. Real failures throw above (EAP=Stop + gates); reaching EOF IS success.
exit 0