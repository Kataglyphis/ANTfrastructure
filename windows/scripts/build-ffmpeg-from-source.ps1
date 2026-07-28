# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\ffmpeg-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$FfmpegVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through SourceBuild.Common's re-export.
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$FfmpegVersion = Get-SourceBuildVersion -Value $FfmpegVersion -EnvironmentVariables @('FFMPEG_VERSION') -DefaultValue 'master'
$prefix = Join-Path $InstallDir 'ffmpeg'
$ffmpegDir = Join-Path $prefix 'bin'

# Windows -> MSYS path (C:\x\y -> /c/x/y). Every bash-facing path MUST go through
# this: a half-converted path once collapsed to /cruntimeffmpeg and make install
# silently delivered the whole tree into <git-root>\cruntimeffmpeg.
function ConvertTo-MsysPath([string]$Path) {
    return '/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

Write-Host "=== FFmpeg source build ($FfmpegVersion, clang-cl+lld-link default; FFMPEG_TOOLCHAIN=msvc to override) ==="

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
    $nvHdrRef       = if ($env:NV_CODEC_HEADERS_REF) { $env:NV_CODEC_HEADERS_REF } else { 'n13.0.19.0' }
    $nvHdrSrc       = 'C:\temp\nv-codec-headers'
    $nvHdrPrefix    = 'C:\temp\nv-codec-headers-install'
    $nvHdrPrefixFwd = $nvHdrPrefix -replace '\\', '/'
    if (Test-Path $nvHdrSrc)    { Remove-Item $nvHdrSrc -Recurse -Force }
    if (Test-Path $nvHdrPrefix) { Remove-Item $nvHdrPrefix -Recurse -Force }
    # Shield via cmd.exe /c: git writes "Cloning into..." to stderr, which under the in-container
    # PS 5.1 EAP=Stop would otherwise surface as a terminating NativeCommandError (2>&1 alone does
    # NOT prevent it in 5.1). cmd merges the streams so PS sees plain stdout. Same pattern as the
    # `make install` line below.
    & cmd /c "git clone --branch $nvHdrRef --depth 1 https://github.com/FFmpeg/nv-codec-headers.git `"$nvHdrSrc`" 2>&1" | ForEach-Object { Write-Host $_ }
    $nvHdrSrcCyg = ConvertTo-MsysPath $nvHdrSrc
    & cmd /c "`"$bashExe`" -c `"cd $nvHdrSrcCyg && make install PREFIX=$nvHdrPrefixFwd`" 2>&1" | ForEach-Object { Write-Host $_ }
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
# Toolchain: clang-cl + lld-link by default, so FFmpeg's C sources are LLVM-compiled like every other
# library in the container (set FFMPEG_TOOLCHAIN=msvc to fall back to the MSVC preset). FFmpeg has no
# clang-cl toolchain preset, so we keep the msvc preset (MSVC-style flag conventions + the inherited
# VsDevCmd SDK env, both of which clang-cl mimics) and override only the compiler/linker. x86asm is
# disabled either way, so nasm/inline-asm is not in play. Proven: full clang-cl build links ffmpeg.exe
# + 7 DLLs with --enable-libonnxruntime + NVENC, 0 errors (validated in windows-media-core).
$ffToolchain = if ($env:FFMPEG_TOOLCHAIN) { $env:FFMPEG_TOOLCHAIN } else { 'clang-cl' }
if ($ffToolchain -eq 'clang-cl') {
    Write-Host 'FFmpeg toolchain: clang-cl + lld-link (overriding the msvc preset''s cc/ld)'
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

Write-Host "Configuring FFmpeg (toolchain: $ffToolchain)..."
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
            & cmd /c "lib.exe /nologo /machine:x64 /def:`"$($defFile.FullName)`" /name:$($defFile.BaseName).dll /out:`"$libPath`" 2>&1" | ForEach-Object { Write-Host $_ }
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
$pyavVersion = Get-SourceBuildVersion -EnvironmentVariables @('PYAV_VERSION') -DefaultValue '18.0.0'
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
cmd.exe /c """$($py.Exe)"" -m tarfile -e ""$($pyavSdist.FullName)"" ""$pyavSrcRoot"" 2>&1"
if ($LASTEXITCODE -ne 0) { throw 'PyAV sdist extraction failed' }
$pyavDir = (Get-ChildItem $pyavSrcRoot -Directory | Select-Object -First 1).FullName
$env:LIB = "$($py.LibDir);$env:LIB"
Push-Location $pyavDir
try {
    cmd.exe /c """$($py.Exe)"" setup.py --ffmpeg-dir=""$prefix"" bdist_wheel 2>&1"
    if ($LASTEXITCODE -ne 0) { throw "PyAV setup.py bdist_wheel failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }
Install-StagedPythonWheel -Python $py -SourceDir (Join-Path $pyavDir 'dist') -ModuleName 'av' -NoDeps | Out-Null
Remove-SourceBuildTree -Path $pyavSrcRoot
Write-Host '=== PyAV wheel build completed ==='




