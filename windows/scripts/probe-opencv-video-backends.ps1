#requires -Version 5.1
<#
.SYNOPSIS
    Print OpenCV's compiled-in video backends and cross-check them against the
    FFmpeg this chain builds (backlog #93/#94/#95).

.DESCRIPTION
    Runs INSIDE a media image. Exists so the #95 smoke-test assertions can be
    watched FAILING against the real artifact before the #93/#94 fixes land — a
    guard written after the fact proves nothing about the defect it should catch.

    Asks `cv2.getBuildInformation()` and NOTHING else for the backend verdict.
    `cv2.videoio_registry.getBackends()` lists GSTREAMER as a known backend ID
    whether or not it was compiled in, which is precisely how this shipped
    unnoticed; it is printed here only to show the two disagreeing.

    Diagnostic: always exits 0. Its output is the product.
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
$gst = $info -match '(?m)^\s*GStreamer:\s+YES'
Write-Result 'GStreamer backend compiled in (#93)' $gst

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

# --- Can OpenCV actually FIND the chain's FFmpeg? (prerequisite for #94) -----
# The #94 fix is "swap the opencv/ffmpeg stages so OpenCV configures after
# FFmpeg exists", but that only helps if OpenCV can then DETECT it. On Windows
# OpenCV downloads a prebuilt `opencv_videoio_ffmpeg*.dll` unless
# OPENCV_FFMPEG_SKIP_DOWNLOAD=ON, and with the download skipped it falls back to
# pkg-config. So the question that decides whether the swap is worth a 90-minute
# build is simply: does pkg-config resolve libavcodec here?
#
# Answer it BEFORE reordering stages. If detection fails, the swap turns
# `FFMPEG: YES (prebuilt)` into `FFMPEG: NO`, which is WORSE than today.
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

Write-Host "`n=== probe complete ==="
