#requires -Version 7.0
<#
.SYNOPSIS
    Thin wrapper: OpenCV video-backend probe (backlog #93/#94/#95).
    Machinery lives in Invoke-DiagnosticProbe.ps1 (#102) — edit THERE.

.DESCRIPTION
    Point -BaseImage at the image the question is ABOUT (media-core carries
    OpenCV + the python bindings; the ffmpeg intermediate has no cv2 yet).
#>
[CmdletBinding()]
param(
    [string]$BaseImage = 'local/kataglyphis:bk-windows-media-core-ffmpeg',
    [string]$BuildCtl = ''
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Invoke-DiagnosticProbe.ps1') `
    -Dockerfile 'Dockerfile.opencv-video-probe' `
    -BaseImage $BaseImage `
    -VerdictPattern '\[ OK \]|\[FAIL\]|GStreamer:|FFMPEG:|avcodec:|registry lists|actually compiled' `
    -LogName 'opencv-video-probe.log' `
    -BuildCtl $BuildCtl
