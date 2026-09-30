#requires -Version 7.0
<#
.SYNOPSIS
    Prints OpenCV's video backends inside a media image and cross-checks them against the chain's FFmpeg.
.DESCRIPTION
    getBackends() lists GSTREAMER whether or not it is compiled in, so it is printed only to show the disagreement.
    Always exits 0; the output is the product.
#>
[CmdletBinding()]
param([string]$Nonce = '')

$ErrorActionPreference = 'Continue'

function Write-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $tag = if ($Ok) { '[ OK ]' } else { '[FAIL]' }
    Write-Host ("{0} {1}{2}" -f $tag, $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}

Write-Host "=== opencv video-backend probe (nonce=$Nonce) ==="

$info = & python -c "import cv2; print(cv2.getBuildInformation())" 2>&1 | Out-String
if (-not $info -or $info -notmatch 'Video I/O') {
    Write-Host "python/cv2 unavailable in this image; nothing to report:"
    Write-Host $info
    return
}

Write-Host "`n--- Video I/O block as the ARTIFACT reports it ---"
$inBlock = $false
foreach ($line in ($info -split "`r?`n")) {
    if ($line -match '^\s*Video I/O:') { $inBlock = $true }
    elseif ($inBlock -and $line -match '^\s{0,2}\S' -and $line -notmatch '^\s*(FFMPEG|avcodec|avformat|avutil|swscale|avresample|avdevice|GStreamer|DirectShow|DC1394|v4l|Media|MSMF|XIMEA|Aravis|gPhoto)') { break }
    if ($inBlock) { Write-Host "  $line" }
}

Write-Host "`n--- the three #95 assertions, run here ---"
# GStreamer is a runtime plugin, so build info says NO even on a correct image; hasBackend() attempts the load.
$gstInfo = $info -match '(?m)^\s*GStreamer:\s+YES'
$gstReg = (& python -c "import cv2; print(cv2.videoio_registry.hasBackend(cv2.CAP_GSTREAMER))" 2>&1 | Out-String) -match 'True'
$gst = $gstInfo -or $gstReg
Write-Result 'GStreamer backend available (built-in OR plugin, #93)' $gst "build-info=$gstInfo plugin=$gstReg"

$ffOwn = $info -match '(?m)^\s*FFMPEG:\s+YES(?![^\r\n]*prebuilt)'
Write-Result "FFmpeg is the chain's, not a prebuilt download (#94)" $ffOwn

$ffDir = if ($env:FFMPEG_BIN) { $env:FFMPEG_BIN } else { 'C:\runtime\ffmpeg\bin' }
$ffExe = Join-Path $ffDir 'ffmpeg.exe'
$chainMajor = ''
$cvMajor = ''
if (Test-Path $ffExe) {
    $chain = & $ffExe -version 2>&1 | Out-String
    if ($chain -match '(?m)^\s*libavcodec\s+(\d+)\.') { $chainMajor = $Matches[1] }
}
if ($info -match '(?m)^\s*avcodec:\s+(?:YES\s*\()?(\d+)\.') { $cvMajor = $Matches[1] }
Write-Result 'OpenCV avcodec major == chain avcodec major (#94)' ($chainMajor -and $cvMajor -and $chainMajor -eq $cvMajor) `
    "chain=$(if ($chainMajor) { $chainMajor } else { '?' }) opencv=$(if ($cvMajor) { $cvMajor } else { '?' })"

# The misleading check, shown side by side on purpose.
Write-Host "`n--- why getBackends() must NOT be used for this ---"
$reg = & python -c "import cv2; print([str(b) for b in cv2.videoio_registry.getBackends()])" 2>&1 | Out-String
Write-Host ("  registry lists GSTREAMER: {0}" -f ($reg -match 'GSTREAMER'))
Write-Host ("  actually compiled in    : {0}" -f $gst)

# Can OpenCV find the chain's FFmpeg at all? With the download skipped it falls back to pkg-config.
Write-Host "`n--- prerequisite check for the #94 swap: is the chain's FFmpeg discoverable? ---"

$ffRoots = @($env:FFMPEG_BIN, 'C:\runtime\ffmpeg\bin', 'C:\runtime\bin') | Where-Object { $_ }
foreach ($r in $ffRoots) {
    Write-Host ("  {0,-28} exists={1}  ffmpeg.exe={2}" -f $r, (Test-Path $r), (Test-Path (Join-Path $r 'ffmpeg.exe')))
}

$pcDirs = @('C:\runtime\ffmpeg\lib\pkgconfig', 'C:\runtime\lib\pkgconfig')
foreach ($d in $pcDirs) {
    $n = @(Get-ChildItem $d -Filter '*.pc' -File -ErrorAction SilentlyContinue).Count
    Write-Host ("  {0,-34} {1} .pc file(s)" -f $d, $n)
    if ($n -gt 0) {
        Get-ChildItem $d -Filter 'libav*.pc' -File -ErrorAction SilentlyContinue | Select-Object -First 4 | ForEach-Object { Write-Host "      $($_.Name)" }
    }
}

$pkgConfig = Get-Command pkg-config -ErrorAction SilentlyContinue
if (-not $pkgConfig) {
    Write-Result 'pkg-config on PATH' $false 'cannot verify FFmpeg discoverability'
} else {
    $existing = @($pcDirs | Where-Object { Test-Path $_ })
    $env:PKG_CONFIG_PATH = (@($existing + ($env:PKG_CONFIG_PATH -split ';' | Where-Object { $_ })) | Select-Object -Unique) -join ';'
    Write-Host "  PKG_CONFIG_PATH = $env:PKG_CONFIG_PATH"
    foreach ($mod in 'libavcodec', 'libavformat', 'libavutil', 'libswscale') {
        $v = & $pkgConfig.Source --modversion $mod 2>&1 | Out-String
        $ok = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0
        Write-Result "pkg-config resolves $mod" $ok $v.Trim()
    }
}

# Ask CMake, not shell pkg-config, which can say yes while OpenCV configures without FFmpeg; see docs/windows-builds.md § OpenCV 5.x.
Write-Host "`n--- does CMake's pkg_check_modules resolve FFmpeg here? (#94 route test) ---"

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) {
    Write-Result 'cmake on PATH' $false 'cannot test the CMake detection route'
} else {
    $cmWork = Join-Path $env:TEMP ('cmffmpeg-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path $cmWork
    @'
cmake_minimum_required(VERSION 3.20)
project(ffmpeg_detect_probe NONE)
find_package(PkgConfig)
message(STATUS "PROBE PKG_CONFIG_FOUND=${PKG_CONFIG_FOUND}")
message(STATUS "PROBE PKG_CONFIG_EXECUTABLE=${PKG_CONFIG_EXECUTABLE}")
if(PKG_CONFIG_FOUND)
  pkg_check_modules(FFMPEG libavcodec libavformat libavutil libswscale)
  message(STATUS "PROBE FFMPEG_FOUND=${FFMPEG_FOUND}")
  message(STATUS "PROBE FFMPEG_VERSION=${FFMPEG_libavcodec_VERSION}")
  message(STATUS "PROBE FFMPEG_INCLUDE_DIRS=${FFMPEG_INCLUDE_DIRS}")
  message(STATUS "PROBE FFMPEG_LIBRARY_DIRS=${FFMPEG_LIBRARY_DIRS}")
  message(STATUS "PROBE FFMPEG_LIBRARIES=${FFMPEG_LIBRARIES}")
endif()
'@ | Set-Content -Path (Join-Path $cmWork 'CMakeLists.txt') -Encoding ascii

    Push-Location $cmWork
    try {
        $out = & $cmake.Source -S . -B build -G Ninja 2>&1 | Out-String
    } finally { Pop-Location }
    $global:LASTEXITCODE = 0

    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match 'PROBE ') { Write-Host "  $($line.Trim())" }
    }
    Write-Result 'CMake pkg_check_modules finds FFmpeg' ($out -match 'PROBE FFMPEG_FOUND=1') `
        'if true, a CMAKE_PROJECT_INCLUDE shim that calls find_package(PkgConfig) unblocks OpenCV''s existing route'
    Remove-Item $cmWork -Recurse -Force -ErrorAction SilentlyContinue
}

# The persistent configure log outlives the solve; the shim's STATUS line repeats per project() call, so it is filtered.
Write-Host "`n--- last OpenCV configure: FFmpeg decision ---"
$cfgLog = 'C:\sccache-logs\opencv-configure.log'
if (Test-Path $cfgLog) {
    $lines = @(Get-Content $cfgLog -ErrorAction SilentlyContinue)
    Write-Host "  $($lines.Count) line(s) in $cfgLog"
    $interesting = @($lines | Where-Object {
            $_ -match 'FFMPEG|ffmpeg|avcodec|libav' -and $_ -notmatch 'pkgconfig-shim'
        })
    if ($interesting) {
        $interesting | Select-Object -First 30 | ForEach-Object { Write-Host "  cfg| $($_.Trim())" }
    } else {
        Write-Host '  no FFmpeg-related lines at all — OpenCV never even reported a decision'
    }
} else {
    Write-Host "  no configure log at $cfgLog (run a media build first)"
}

Write-Host "`n=== probe complete ==="
