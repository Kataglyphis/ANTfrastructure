# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$SourceDir = 'C:\temp\ffmpeg-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$FfmpegVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force

# Load canonical versions from linux/scripts/01-core/versions.env if available
$versionsScript = Join-Path $PSScriptRoot 'load-versions.ps1'
if (Test-Path $versionsScript) { & $versionsScript }

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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$wc = New-Object System.Net.WebClient
if ($FfmpegVersion -in @('main', 'master', 'develop')) {
    try {
        $wc.DownloadFile("https://github.com/FFmpeg/FFmpeg/archive/refs/heads/$FfmpegVersion.tar.gz", $tarballPath)
    } catch {
        # FFmpeg GitHub mirror uses 'master' as default branch; fall back if branch not found
        Write-Warning "FFmpeg branch '$FfmpegVersion' not found, trying 'master'..."
        $wc.DownloadFile("https://github.com/FFmpeg/FFmpeg/archive/refs/heads/master.tar.gz", $tarballPath)
        $FfmpegVersion = 'master'
    }
} else {
    $wc.DownloadFile("https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FfmpegVersion.tar.gz", $tarballPath)
}
Write-Host "Extracting tarball..."
& 7z x "$tarballPath" -o"$SourceDir" -y -bd 2>&1 | Out-Null
$tarFile = Get-ChildItem -Path $SourceDir -Filter '*.tar' | Select-Object -First 1 -ExpandProperty FullName
if ($tarFile) { & 7z x "$tarFile" -o"$SourceDir" -y -bd 2>&1 | Out-Null }
$srcDir = Get-ChildItem -Path $SourceDir -Directory | Select-Object -First 1 -ExpandProperty FullName
if (-not $srcDir) { throw "Failed to locate extracted FFmpeg source directory" }
Write-Host "Source at: $srcDir"

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

# MSYS2 paths
$cygPrefix = "/$($prefix.Substring(0,1).ToLower())$($prefix.Substring(2))"
$cygSrc = $srcDir -replace '\\', '/' -replace '^C:', '/c'

# Configure with --toolchain=msvc (officially supported by FFmpeg on Windows)
# Resulting binaries are ABI-compatible with clang-cl throughout the container.
# Ensure ONNX Runtime is discoverable for --enable-libonnxruntime
# Use MSYS2 paths (/c/...) because FFmpeg configure runs under Git Bash/MSYS2,
# which translates POSIX paths for native Windows tools (cl.exe, link.exe).
$onnxRuntimeDir = Join-Path $InstallDir 'lib\onnxruntime-source'
if (Test-Path $onnxRuntimeDir) {
    $onnxMsysPath = $onnxRuntimeDir -replace '\\', '/' -replace '^C:', '/c'
    # Search for the header in common ONNX Runtime install locations
    $header = $null
    $searchPaths = @(
        "$onnxRuntimeDir\include\onnxruntime_c_api.h",
        "$onnxRuntimeDir\include\onnxruntime\core\session\onnxruntime_c_api.h",
        "$onnxRuntimeDir\include\onnxruntime_c_api.h"
    )
    # Also search recursively if not found at standard paths
    if (-not ($header = Get-ChildItem "$onnxRuntimeDir" -Recurse -Filter 'onnxruntime_c_api.h' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        Write-Warning "ONNX Runtime header onnxruntime_c_api.h not found under $onnxRuntimeDir"
    } else {
        Write-Host "ONNX Runtime header at: $($header.FullName)"
    }
}

$confFlags = @()
$confFlags += "--prefix=$cygPrefix"
$confFlags += '--enable-shared', '--disable-static'
$confFlags += '--disable-debug', '--disable-doc'
$confFlags += '--enable-gpl', '--enable-nonfree', '--enable-version3'
$confFlags += '--enable-ffmpeg', '--enable-ffprobe'
# $confFlags += '--enable-libonnxruntime'  # ONNX DLLs available at runtime via PATH
$confFlags += '--toolchain=msvc'
$confFlags += '--disable-x86asm'

# CUDA auto-detected via CUDA_PATH env var (set by VsDevCmd). Explicit
# --enable-nvenc/--enable-nvdec require ffnvcodec headers not installed here.

$confStr = $confFlags -join ' '

# Patch configure to allow MSYS2 builds (official docs say MSYS is discouraged)
$configurePath = Join-Path $srcDir 'configure'
$configureContent = [System.IO.File]::ReadAllText($configurePath) -replace 'die "Native MSYS builds are discouraged', 'echo "[INFO] MSYS build allowed'
[System.IO.File]::WriteAllText($configurePath, $configureContent)

# Note: --enable-libonnxruntime is skipped for MSVC builds because FFmpeg's configure
# test_cc probes don't pick up --extra-cflags properly. The ONNX Runtime DLLs are
# still available at runtime in the container via PATH.

# Write configure wrapper
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

$nproc = & $bashExe -l -c "nproc" 2>&1
$jobs = if ($nproc -match '\d+') { $Matches[0] } else { 4 }
Write-Host "Building FFmpeg with $jobs parallel jobs..."

Write-Host 'Building FFmpeg (this may take 15-30 minutes)...'
$ffbuildDir = Join-Path $srcDir 'ffbuild'
Get-ChildItem -Path $ffbuildDir -Filter '*.mak' -ErrorAction SilentlyContinue | ForEach-Object {
    $c = [System.IO.File]::ReadAllText($_.FullName)
    $c = $c -replace '-showIncludes', ''
    $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
    $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
    $c = $c -replace '\s*\|\s*awk.*', ''
    [System.IO.File]::WriteAllText($_.FullName, $c)
}
foreach ($fn in @('library.mak', 'subdir.mak', 'Makefile')) {
    $fp = Join-Path $srcDir $fn
    if (Test-Path $fp) {
        $c = [System.IO.File]::ReadAllText($fp)
        $c = $c -replace '-showIncludes', ''
        $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
        $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
        $c = $c -replace '\s*\|\s*awk.*', ''
        $c = $c -replace '-include\s+\$\(wildcard\s+\*\.d\).*', ''
        [System.IO.File]::WriteAllText($fp, $c)
    }
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

# Write a replacement makedef that lists .o files via dir instead of CLI args
$makedefContent = @'
#!/usr/bin/env sh
# Replacement makedef: reads .ver file, generates .def directly, ignoring .o
# args (avoids Windows command-line length limit for avcodec).
ver_file="$1"
echo "EXPORTS"
sed -n "s/^ *\([a-zA-Z][a-zA-Z0-9_]*\);.*/\1/p" "$ver_file"
'@
$makedefPath = Join-Path $srcDir 'compat/windows/makedef'
[System.IO.File]::WriteAllText($makedefPath, $makedefContent, [System.Text.Encoding]::ASCII)
& cmd /c "`"$bashExe`" -c `"cd $cygSrc && make -j$jobs`" 2>&1" | ForEach-Object { Write-Host $_ }
$builtFfmpeg = Join-Path $srcDir 'ffmpeg.exe'
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Retrying with single job...'
    & cmd /c "`"$bashExe`" -c `"cd $cygSrc && make -j1`" 2>&1" | ForEach-Object { Write-Host $_ }
}
# Source build may fail at link stage (EXTRALIBS config issue with MSVC/MSYS2).
# Fall through to download a pre-built MSVC FFmpeg binary.
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Source build of FFmpeg did not produce ffmpeg.exe (link stage incomplete).'
}
Write-Host 'Attempting install from source if built...'
& cmd /c "`"$bashExe`" -c `"cd $cygSrc && make install`" 2>&1" | ForEach-Object { Write-Host $_ }

# Download pre-built MSVC FFmpeg if source build didn't produce ffmpeg.exe
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) {
    Write-Warning 'FFmpeg source build failed — falling back to pre-built BtbN MSVC FFmpeg. DNN/ONNX integration will NOT be available in the fallback binary.'
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '0', 'Process')
    if (-not (Test-Path $prefix)) { New-Item -Path $prefix -ItemType Directory -Force | Out-Null }
    $dlUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    $zipPath = "$env:TEMP\ffmpeg.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($dlUrl, $zipPath)
    & 7z x "$zipPath" -o"$env:TEMP\ffmpeg-extract" -y -bd 2>&1 | Out-Null
    $binDir = Get-ChildItem -Path "$env:TEMP\ffmpeg-extract" -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DirectoryName
    if ($binDir) {
        if (-not (Test-Path $ffmpegDir)) { New-Item -Path $ffmpegDir -ItemType Directory -Force | Out-Null }
        Copy-Item "$binDir\*.exe" "$ffmpegDir\" -Force
        Copy-Item "$binDir\*.dll" "$ffmpegDir\" -Force
    }
} else {
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '1', 'Process')
}

Write-Host "=== FFmpeg build completed ==="
Write-Host "Artifacts at: $prefix"
if (Test-Path "$ffmpegDir\ffmpeg.exe") { Write-Host "ffmpeg.exe installed" }
if (Test-Path "$ffmpegDir\ffprobe.exe") { Write-Host "ffprobe.exe installed" }
