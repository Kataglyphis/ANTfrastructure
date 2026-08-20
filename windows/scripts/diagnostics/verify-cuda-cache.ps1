#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# CUDA-cache verification probe: proves the sccache -> nvcc(decomposed) ->
# WebDAV L2 path END TO END, including the cache HIT on recompile - the
# property the chain relies on for the ~45 min of ONNX CUDA kernels
# (owner requirement 2026-08-10: "ich muss cuda cachen").
#
# Runs a tiny buildctl solve FROM the local toolchain image: compile ONE .cu
# twice through sccache against the live WebDAV endpoint, then assert from
# `sccache --show-stats` that the second compile HIT (>=1 hit, >=1 write).
# Non-admin, ~2-4 min, safe to run alongside a live chain build (own sccache
# server instance inside a throwaway container).
#
#   pwsh -File windows\scripts\diagnostics\verify-cuda-cache.ps1
#   pwsh -File windows\scripts\diagnostics\verify-cuda-cache.ps1 -Endpoint http://<host>:5000
#
# Exit codes: 0 = CACHE VERIFIED (hit on recompile), 1 = broken/unprovable.

[CmdletBinding()]
param(
    [string]$Endpoint = [Environment]::GetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT', 'Machine'),
    [string]$BaseImage = 'docker.io/local/kataglyphis:bk-windows-toolchain',
    # Empty = resolve from the supported install layouts (backlog item #2).
    [string]$BuildCtl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'windows\scripts\modules\WindowsScripts.Shared.psm1')

if (-not $Endpoint) { throw 'no WebDAV endpoint: pass -Endpoint or set SCCACHE_WEBDAV_ENDPOINT (Machine scope)' }
if (-not $BuildCtl) {
    # Shared candidate-list owner (backlog #2): candidates first, then PATH.
    $BuildCtl = Get-PreferredToolPath -CommandName 'buildctl.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')
}
if (-not $BuildCtl -or -not (Test-Path $BuildCtl)) { throw 'buildctl not found in any supported Stevedore layout' }

$ctx = Join-Path ([System.IO.Path]::GetTempPath()) ("cudacache-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $ctx | Out-Null
try {
    # Dockerfile invariants: pwsh SHELL is inherited from the base image; shell-form
    # RUN lines must not contain DOUBLE quotes (the frontend strips them). The
    # payload is a COPY'd, lintable script (backlog #14) living next to this
    # one; its throw = RUN exit 1 = the probe verdict.
    Copy-Item -Path (Join-Path $PSScriptRoot 'verify-cuda-cache\cachetest.ps1') -Destination (Join-Path $ctx 'cachetest.ps1')
    $runLines = @(
        "ARG SCCACHE_EP",
        "FROM $BaseImage",
        "ARG SCCACHE_EP",
        'ENV SCCACHE_WEBDAV_ENDPOINT=$SCCACHE_EP',
        'COPY cachetest.ps1 C:/cachetest.ps1',
        'RUN & C:\cachetest.ps1'
    )
    Set-Content -Path (Join-Path $ctx 'Dockerfile') -Value ($runLines -join "`n") -Encoding ascii

    Write-Host "== CUDA cache verify: $BaseImage vs $Endpoint ==" -ForegroundColor Cyan
    # Full output persisted (owner directive: never swallow logs); path +
    # retention via the shared convention owner (backlog #8/#30).
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $fullLog = Get-DiagnosticLogPath -RepoRoot $repoRoot -Name 'verify-cuda-cache'
    # No --output: the verdict is the RUN's exit code; an image export would
    # only mint store garbage per run (backlog item #22). Contrast with the
    # finalize probes, which NEED type=image,unpack=true - export IS their test.
    & $BuildCtl --addr npipe:////./pipe/buildkitd build --frontend dockerfile.v0 `
        --local "context=$ctx" --local "dockerfile=$ctx" `
        --opt image-resolve-mode=local --opt "build-arg:SCCACHE_EP=$Endpoint" --no-cache 2>&1 |
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
