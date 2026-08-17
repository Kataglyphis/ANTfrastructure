#requires -Version 7.0
<#
.SYNOPSIS
    Host-side runner for the sccache L0 write-failure probe (backlog #99).

.DESCRIPTION
    Solves windows/Dockerfile.sccache-write-probe via buildctl and Tees the full
    output to out\windows-build-logs\. Takes ~2 minutes against a ~90-minute
    media build, which is the whole point: the write failure is reproducible
    with ONE compile, so it must be investigated with one.

    NOTE: --no-cache is NOT passed and must not be. On this lane it EMPTIES the
    cache mounts for that build (backlog #96), so a probe run with it would
    inspect a freshly-wiped C:\sccache and answer a question nobody asked. The
    probe already forces a real miss by generating a unique source file.

.PARAMETER SccacheEndpoint
    WebDAV L1 endpoint; defaults to the SCCACHE_WEBDAV_ENDPOINT env var so it
    matches whatever the real builds are using.
#>
[CmdletBinding()]
param(
    [string]$SccacheEndpoint = $env:SCCACHE_WEBDAV_ENDPOINT,
    [string]$BaseImage = 'local/kataglyphis:bk-windows-toolchain',
    [ValidateSet('error', 'warn', 'info', 'debug', 'trace')]
    [string]$SccacheLog = 'debug',
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
$log = Join-Path $logDir 'sccache-write-probe.log'

$bkArgs = @(
    'build',
    '--frontend', 'dockerfile.v0',
    '--local', "context=$repoRoot",
    '--local', "dockerfile=$repoRoot\windows",
    '--opt', 'filename=Dockerfile.sccache-write-probe',
    '--opt', 'image-resolve-mode=local',
    '--opt', "build-arg:BASE_IMAGE=$BaseImage",
    '--opt', "build-arg:SCCACHE_LOG=$SccacheLog",
    # Unique per invocation so the RUN cannot be served from the layer cache.
    # See the Dockerfile: a CACHED probe silently replays an old verdict.
    '--opt', "build-arg:PROBE_NONCE=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())",
    '--progress', 'plain'
)
if ($SccacheEndpoint) {
    $bkArgs += @('--opt', "build-arg:SCCACHE_WEBDAV_ENDPOINT=$SccacheEndpoint")
} else {
    Write-Warning 'No SCCACHE_WEBDAV_ENDPOINT: L1 will be unconfigured, so only the L0 verdict is meaningful.'
}
# No --output: the probe's product is its stdout, not an image.

Write-Host "==> buildctl (sccache write probe) -> $log" -ForegroundColor Cyan
& $BuildCtl @bkArgs 2>&1 | Tee-Object -FilePath $log
$code = $LASTEXITCODE

Write-Host "`n--- verdict lines ---" -ForegroundColor Cyan
Select-String -Path $log -Pattern '\[ OK \]|\[FAIL\]|write errors|write failures|Cache misses|os error' |
    ForEach-Object { '  ' + $_.Line.Trim() }

Write-Host "`nfull log: $log"
if ($code -ne 0) { throw "probe solve failed (exit $code) - see $log" }

# Fail closed on a replayed layer. A probe whose RUN was CACHED prints the old
# verdict with no indication that nothing executed - the exact fail-open shape
# this repo forbids, and it cost one wasted "the repair ran" report already.
if (-not (Select-String -Path $log -Pattern 'probe complete' -Quiet)) {
    throw "probe did not execute (no 'probe complete' marker) - the RUN was likely CACHED; see $log"
}
