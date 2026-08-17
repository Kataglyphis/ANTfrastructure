#requires -Version 7.0
<#
.SYNOPSIS
    Host-side runner for the OpenCV video-backend probe (backlog #93/#94/#95).

.DESCRIPTION
    Solves windows/Dockerfile.opencv-video-probe via buildctl and Tees the full
    output to out\windows-build-logs\. ~2 minutes against a media image, versus
    a full chain rebuild, so the #95 assertions can be watched failing on the
    real artifact.

    NOTE: --no-cache is deliberately NOT passed - on this lane it EMPTIES the
    cache mounts (backlog #96). PROBE_NONCE busts the layer instead.
#>
[CmdletBinding()]
param(
    [string]$BaseImage = 'local/kataglyphis:bk-windows-media-core-ffmpeg',
    [string]$BuildCtl = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $BuildCtl) {
    foreach ($c in @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')) {
        if (Test-Path $c) { $BuildCtl = $c; break }
    }
    if (-not $BuildCtl) { $BuildCtl = (Get-Command buildctl -ErrorAction SilentlyContinue).Source }
}
if (-not $BuildCtl) { throw 'buildctl.exe not found (Stevedore bin or PATH).' }

$logDir = Join-Path $repoRoot 'out\windows-build-logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
$log = Join-Path $logDir 'opencv-video-probe.log'

$bkArgs = @(
    'build',
    '--frontend', 'dockerfile.v0',
    '--local', "context=$repoRoot",
    '--local', "dockerfile=$repoRoot\windows",
    '--opt', 'filename=Dockerfile.opencv-video-probe',
    '--opt', 'image-resolve-mode=local',
    '--opt', "build-arg:BASE_IMAGE=$BaseImage",
    '--opt', "build-arg:PROBE_NONCE=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())",
    '--progress', 'plain'
)

Write-Host "==> buildctl (opencv video-backend probe, base=$BaseImage) -> $log" -ForegroundColor Cyan
& $BuildCtl @bkArgs 2>&1 | Tee-Object -FilePath $log
$code = $LASTEXITCODE

Write-Host "`n--- verdict lines ---" -ForegroundColor Cyan
Select-String -Path $log -Pattern '\[ OK \]|\[FAIL\]|GStreamer:|FFMPEG:|avcodec:|registry lists|actually compiled' |
    ForEach-Object { '  ' + $_.Line.Trim() }

Write-Host "`nfull log: $log"
if ($code -ne 0) { throw "probe solve failed (exit $code) - see $log" }

# Fail closed on a replayed layer: a CACHED probe prints an old verdict with no
# sign that nothing executed.
if (-not (Select-String -Path $log -Pattern 'probe complete' -Quiet)) {
    throw "probe did not execute (no 'probe complete' marker) - the RUN was likely CACHED; see $log"
}
