#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Proves sccache's nvcc path end to end against the WebDAV endpoint: one .cu compiled twice must write, then hit.

[CmdletBinding()]
param(
    [string]$Endpoint = [Environment]::GetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT', 'Machine'),
    [string]$BaseImage = 'docker.io/local/kataglyphis:bk-windows-toolchain-nvidia',
    # Empty = resolve from the supported install layouts.
    [string]$BuildCtl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'windows\scripts\modules\WindowsScripts.Shared.psm1')

if (-not $Endpoint) { throw 'no WebDAV endpoint: pass -Endpoint or set SCCACHE_WEBDAV_ENDPOINT (Machine scope)' }
$BuildCtl = Resolve-BuildCtlPath -BuildCtl $BuildCtl

$ctx = Join-Path ([System.IO.Path]::GetTempPath()) ("cudacache-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $ctx | Out-Null
try {
    # A COPY'd payload script, since the frontend strips double quotes from shell-form RUN lines.
    Copy-Item -Path (Join-Path $PSScriptRoot 'verify-cuda-cache\Test-Cache.ps1') -Destination (Join-Path $ctx 'Test-Cache.ps1')
    # A secret, as in the image chain, so neither the build record nor a history names the endpoint.
    $runLines = @(
        "FROM $BaseImage",
        'COPY Test-Cache.ps1 C:/Test-Cache.ps1',
        'RUN --mount=type=secret,id=sccache_webdav_endpoint,env=SCCACHE_WEBDAV_ENDPOINT & C:\Test-Cache.ps1'
    )
    $env:KATAGLYPHIS_BK_SCCACHE_WEBDAV_ENDPOINT = $Endpoint
    Set-Content -Path (Join-Path $ctx 'Dockerfile') -Value ($runLines -join "`n") -Encoding ascii

    Write-Host "== CUDA cache verify: $BaseImage vs $Endpoint ==" -ForegroundColor Cyan
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $fullLog = Get-DiagnosticLogPath -RepoRoot $repoRoot -Name 'verify-cuda-cache'
    # No --output: the verdict is the RUN's exit code, and an export would only litter the store.
    & $BuildCtl --addr npipe:////./pipe/buildkitd build --frontend dockerfile.v0 `
        --local "context=$ctx" --local "dockerfile=$ctx" `
        --opt image-resolve-mode=local --secret id=sccache_webdav_endpoint,env=KATAGLYPHIS_BK_SCCACHE_WEBDAV_ENDPOINT --no-cache 2>&1 |
        Tee-Object -FilePath $fullLog | ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
    Write-Host "[full log: $fullLog]"
} finally {
    Remove-Item -Path $ctx -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($code -eq 0) {
    Write-Host 'CUDA CACHE VERIFIED: recompile hit the WebDAV L2 through the sccache nvcc launcher.' -ForegroundColor Green
    exit 0
}
Write-Host 'CUDA CACHE VERIFY FAILED - see the RUN output above (compile error, no hit, or no write).' -ForegroundColor Red
exit 1
