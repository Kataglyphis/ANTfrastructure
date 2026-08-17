#requires -Version 7.0
<#
.SYNOPSIS
    Thin wrapper: sccache write-failure probe (backlog #99).
    Machinery lives in run-diagnostic-probe.ps1 (#102) — edit THERE.

.DESCRIPTION
    NOTE: --no-cache is deliberately never passed — on this lane it EMPTIES the
    cache mounts (backlog #96). The shared runner busts the layer with
    PROBE_NONCE instead and fails closed on a CACHED (never-executed) probe.

.PARAMETER SccacheEndpoint
    WebDAV L1 endpoint; defaults to SCCACHE_WEBDAV_ENDPOINT so it matches what
    real builds use. Without it only the L0/disk verdicts are meaningful.
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
if (-not $SccacheEndpoint) {
    Write-Warning 'No SCCACHE_WEBDAV_ENDPOINT: L1 will be unconfigured, so only the L0 verdict is meaningful.'
}

$extraArgs = @("SCCACHE_LOG=$SccacheLog")
if ($SccacheEndpoint) { $extraArgs += "SCCACHE_WEBDAV_ENDPOINT=$SccacheEndpoint" }

& (Join-Path $PSScriptRoot 'run-diagnostic-probe.ps1') `
    -Dockerfile 'Dockerfile.sccache-write-probe' `
    -BaseImage $BaseImage `
    -BuildArg $extraArgs `
    -VerdictPattern '\[ OK \]|\[FAIL\]|write errors|write failures|Cache misses|os error' `
    -LogName 'sccache-write-probe.log' `
    -BuildCtl $BuildCtl
