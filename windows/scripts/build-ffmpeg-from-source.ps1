# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\ffmpeg-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$FfmpegVersion = ''
)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through SourceBuild.Common's re-export.
$InstallDir = Initialize-SourceBuildEnvironment -InstallDir $InstallDir

# Load canonical versions from linux/scripts/01-core/versions.env if available
Import-CanonicalVersions -ScriptRoot $PSScriptRoot

$FfmpegVersion = Get-SourceBuildVersion -Value $FfmpegVersion -EnvironmentVariables @('FFMPEG_VERSION') -DefaultValue 'main'
$prefix = Join-Path $InstallDir 'ffmpeg'
$ffmpegDir = Join-Path $prefix 'bin'

Write-Host "=== FFmpeg source build ($FfmpegVersion, MSVC toolchain) ==="

if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    Write-Host "FFmpeg already installed at $prefix - skipping"; return
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

# Set up environment: VsDevCmd (MSVC tools) + Git Bash + Scoop make/gawk
Enter-VsDevCmdEnvironment
$scoopShims = "$env:USERPROFILE\scoop\shims"
# Ensure make is available
if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
    Write-Host "Installing make via scoop..."
    & scoop install main/make 2>&1 | Out-Null
}
# Install gawk and replace MSYS2's broken awk
if (-not (Get-Command gawk -ErrorAction SilentlyContinue)) {
    Write-Host "Installing gawk via scoop..."
    & scoop install main/gawk 2>&1 | Out-Null
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

# MSYS2 paths. Backslashes MUST become forward slashes: the previous form
# produced /c\runtime\ffmpeg, configure collapsed it to /cruntimeffmpeg, and
# `make install` silently delivered everything into <git-root>\cruntimeffmpeg —
# which is why the image only ever carried the fallback exes.
$cygPrefix = '/' + $prefix.Substring(0,1).ToLower() + ($prefix.Substring(2) -replace '\\', '/')
$cygSrc = $srcDir -replace '\\', '/' -replace '^C:', '/c'

# Configure with --toolchain=msvc (officially supported by FFmpeg on Windows)
# Resulting binaries are ABI-compatible with clang-cl throughout the container.
# Ensure ONNX Runtime is discoverable for --enable-libonnxruntime.
# Copy the ONNX header into FFmpeg's include/compat directory so configure's
# test_cc probes can find it without --extra-cflags (which doesn't get passed
# to test compilations when using --toolchain=msvc).
$onnxRuntimeDir = Join-Path $InstallDir 'lib\onnxruntime-source'
$onnxHeaderCopied = $false
if (Test-Path $onnxRuntimeDir) {
    $header = Get-ChildItem "$onnxRuntimeDir" -Recurse -Filter 'onnxruntime_c_api.h' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($header) {
        $ffCompatInc = Join-Path $srcDir 'compat\onnx'
        New-Item -Path $ffCompatInc -ItemType Directory -Force | Out-Null
        Copy-Item $header.FullName "$ffCompatInc\" -Force
        $cxxHeader = Join-Path $header.Directory 'onnxruntime_cxx_api.h'
        if (Test-Path $cxxHeader) { Copy-Item $cxxHeader "$ffCompatInc\" -Force }
        $epHeader = Join-Path $header.Directory 'onnxruntime_ep_c_api.h'
        if (Test-Path $epHeader) { Copy-Item $epHeader "$ffCompatInc\" -Force }
        Write-Host "Copied ONNX headers to: $ffCompatInc"
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
$confFlags += '--toolchain=msvc'
$confFlags += '--disable-x86asm'
# vfwcap links vfw32.lib -> imports AVICAP32.dll, which does NOT exist in
# Windows Server Core containers: every process loading avdevice would die
# with STATUS_DLL_NOT_FOUND. DirectShow capture (dshow) remains available.
$confFlags += '--disable-indev=vfwcap'

$confStr = $confFlags -join ' '

# Patch configure to allow MSYS2 builds (official docs say MSYS is discouraged)
Invoke-SourcePatch -PatchFile (Join-Path $PSScriptRoot 'patches\ffmpeg\001-allow-msys-builds.patch') -SourceDir $srcDir -IgnoreWhitespace

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

Write-Host 'Configuring FFmpeg with MSVC toolchain...'
& $bashExe $wrapperPath 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    $logFile = Join-Path $srcDir 'ffbuild\config.log'
    if (Test-Path $logFile) { Write-Host "=== config.log (last 50 lines) ==="; Get-Content $logFile -Tail 50 }
    throw "FFmpeg configure failed (exit $LASTEXITCODE)"
}

Write-Host 'Building FFmpeg (this may take 30-60 minutes)...'
# Inline patches (kept inline, NOT .patch files): the targets below are *generated*
# by FFmpeg's `./configure` (ffbuild/*.mak, library.mak, subdir.mak, Makefile,
# ffbuild/config.mak). Generated content differs per configure invocation
# (probe results, lib list, OS detection), so a static .patch cannot match
# reliably across builds. The `-replace` form targets invariant sub-sequences
# (`-showIncludes`, `EXTRALIBS-lib*=`) that configure writes the same way for
# the msvc toolchain. See docs/windows-builds.md ?Patches.
$ffbuildDir = Join-Path $srcDir 'ffbuild'
Get-ChildItem -Path $ffbuildDir -Filter '*.mak' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-MakefileShowIncludes -Path $_.FullName
}
foreach ($fn in @('library.mak', 'subdir.mak', 'Makefile')) {
    Remove-MakefileShowIncludes -Path (Join-Path $srcDir $fn) -StripWildcardInclude
}
# Add avutil.lib to library link paths (configure may not generate EXTRALIBS correctly)
$configMakPath = Join-Path $srcDir 'ffbuild/config.mak'
if (Test-Path $configMakPath) {
    $cm = [System.IO.File]::ReadAllText($configMakPath)
    $cm = $cm -replace '^(EXTRALIBS-libswresample\s*=).*', '$1 avutil.lib'
    $cm = $cm -replace '^(EXTRALIBS-libswscale\s*=).*', '$1 avutil.lib'
    $cm = $cm -replace '^(EXTRALIBS-libavcodec\s*=).*', '$1 avutil.lib'
    $cm = $cm -replace '^(EXTRALIBS-libavfilter\s*=).*', '$1 avutil.lib'
    $cm = $cm -replace '^(EXTRALIBS-libavformat\s*=).*', '$1 avutil.lib avcodec.lib'
    $cm = $cm -replace '^(EXTRALIBS-libavdevice\s*=).*', '$1 avformat.lib avcodec.lib avutil.lib'
    if (-not ($cm -match 'EXTRALIBS-libswresample')) {
        $cm += "`nEXTRALIBS-libswresample=avutil.lib"
        $cm += "`nEXTRALIBS-libswscale=avutil.lib"
        $cm += "`nEXTRALIBS-libavcodec=avutil.lib"
        $cm += "`nEXTRALIBS-libavfilter=avutil.lib"
        $cm += "`nEXTRALIBS-libavformat=avcodec.lib avutil.lib"
        $cm += "`nEXTRALIBS-libavdevice=avformat.lib avcodec.lib avutil.lib"
    }
    [System.IO.File]::WriteAllText($configMakPath, $cm)
}

# Replace makedef wholesale (full-file overwrite, deliberately NOT a .patch:
# the file is completely rewritten, so a context diff adds only fragility —
# it broke twice on upstream drift / git-apply quirks). The replacement expands
# version-script globs against per-object llvm-nm symbol dumps via xargs,
# avoiding the upstream script's single lib.exe call that exceeds the Windows
# command-line length limit for libavcodec.
$makedefSrc = Join-Path $PSScriptRoot 'patches\ffmpeg\makedef'
$makedefDst = Join-Path $srcDir 'compat\windows\makedef'
Copy-Item $makedefSrc $makedefDst -Force
Write-Host "Replaced compat/windows/makedef (glob-expanding, response-file-aware)"

# Parallel compile first; make is incremental, so the -j1 retry below only redoes
# what failed. Parallel -jN can hit spurious LNK1120 link races with MSVC when
# library dependencies (libavutil -> libswscale) aren't fully linked before
# consumers — the serial retry resolves those deterministically.
$makeJobs = Get-BuildJobCount -MemGBPerJob 2
& cmd /c "`"$bashExe`" -c `"cd $cygSrc && make -j$makeJobs`" 2>&1" | ForEach-Object { Write-Host $_ }
$builtFfmpeg = Join-Path $srcDir 'ffmpeg.exe'
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Retrying with single job (resolves MSVC link races)...'
    & cmd /c "`"$bashExe`" -c `"cd $cygSrc && make -j1`" 2>&1" | ForEach-Object { Write-Host $_ }
}
# Source build may fail at link stage (EXTRALIBS config issue with MSVC/MSYS2).
# Fall through to download a pre-built MSVC FFmpeg binary.
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Source build of FFmpeg did not produce ffmpeg.exe (link stage incomplete).'
}
Write-Host 'Attempting install from source if built...'
& cmd /c "`"$bashExe`" -c `"cd $cygSrc && make install`" 2>&1" | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { Write-Warning "make install exited $LASTEXITCODE - verifying what landed..." }

# A --enable-shared build is only usable if the av*.dll runtime libraries were
# installed next to the exes; exes alone die with STATUS_DLL_NOT_FOUND. Treat an
# incomplete install as a failed source build so the fallback (or a loud error)
# kicks in instead of shipping a broken ffmpeg.
$installedDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
if ((Test-Path "$ffmpegDir\ffmpeg.exe") -and $installedDlls.Count -eq 0) {
    Write-Warning 'Source install produced exes but no av*.dll runtime libraries - discarding as incomplete.'
    Remove-Item "$ffmpegDir\ffmpeg.exe", "$ffmpegDir\ffplay.exe", "$ffmpegDir\ffprobe.exe" -Force -ErrorAction SilentlyContinue
}

# Download pre-built MSVC FFmpeg if source build didn't produce ffmpeg.exe
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) {
    Write-Warning 'FFmpeg source build failed -- falling back to pre-built BtbN MSVC FFmpeg. DNN/ONNX integration will NOT be available in the fallback binary.'
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '0', 'Process')
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

Remove-SourceBuildTree -Path $SourceDir

Write-Host "=== FFmpeg build completed ==="
Write-Host "Artifacts at: $prefix"
if (Test-Path "$ffmpegDir\ffmpeg.exe") { Write-Host "ffmpeg.exe installed" }
if (Test-Path "$ffmpegDir\ffprobe.exe") { Write-Host "ffprobe.exe installed" }
$finalDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
Write-Host "runtime DLLs installed: $($finalDlls.Count)"
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) { throw 'FFmpeg install incomplete: no ffmpeg.exe (source build and fallback both failed)' }



