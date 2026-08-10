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
#   pwsh -File windows\diagnostics\verify-cuda-cache.ps1
#   pwsh -File windows\diagnostics\verify-cuda-cache.ps1 -Endpoint http://<host>:5000
#
# Exit codes: 0 = CACHE VERIFIED (hit on recompile), 1 = broken/unprovable.

#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Endpoint = [Environment]::GetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT', 'Machine'),
    [string]$BaseImage = 'docker.io/local/kataglyphis:bk-windows-toolchain',
    [string]$BuildCtl = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Endpoint) { throw 'no WebDAV endpoint: pass -Endpoint or set SCCACHE_WEBDAV_ENDPOINT (Machine scope)' }
if (-not (Test-Path $BuildCtl)) { throw "buildctl not found at $BuildCtl" }

$ctx = Join-Path ([System.IO.Path]::GetTempPath()) ("cudacache-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $ctx | Out-Null
try {
    # Dockerfile invariants: pwsh SHELL is inherited from the base image; shell-form
    # RUN lines must not contain DOUBLE quotes (the frontend strips them). The RUN
    # relies on the Machine-scope VS/CUDA env the base image bakes (INCLUDE/LIB).
    $runLines = @(
        "ARG SCCACHE_EP",
        "FROM $BaseImage",
        "ARG SCCACHE_EP",
        'ENV SCCACHE_WEBDAV_ENDPOINT=$SCCACHE_EP',
        ('RUN $ErrorActionPreference = ''Stop''; ' +
         '$scc = ''C:\Users\ContainerAdministrator\.cargo\bin\sccache.exe''; ' +
         '$nvcc = (Get-ChildItem ''C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v*\bin\nvcc.exe'' | Select-Object -First 1).FullName; ' +
         '$cl = (Get-ChildItem ''C:\Program Files (x86)\Microsoft Visual Studio\*\BuildTools\VC\Tools\MSVC\*\bin\HostX64\x64\cl.exe'' | Select-Object -First 1).FullName; ' +
         'if (-not $nvcc -or -not $cl) { throw ''nvcc or cl not found in image'' }; ' +
         '$env:Path = (Split-Path $cl) + '';'' + $env:Path; ' +
         '$msvcRoot = Split-Path (Split-Path (Split-Path (Split-Path $cl))); ' +
         '$sdkInc = (Get-ChildItem ''C:\Program Files (x86)\Windows Kits\10\Include\10.*'' | Sort-Object Name | Select-Object -Last 1).FullName; ' +
         '$env:INCLUDE = $msvcRoot + ''\include;'' + $sdkInc + ''\ucrt;'' + $sdkInc + ''\shared;'' + $sdkInc + ''\um''; ' +
         '& $scc --stop-server 2>$null; & $scc --start-server; & $scc -z | Out-Null; ' +
         'Set-Content -Path C:\cachetest.cu -Value ''__global__ void k(float* p){ p[threadIdx.x] *= 2.0f; }''; ' +
         '& $scc $nvcc (''-ccbin='' + $cl) -arch=sm_80 -c C:\cachetest.cu -o C:\t1.obj; ' +
         'if ($LASTEXITCODE -ne 0) { throw (''first compile failed: '' + $LASTEXITCODE) }; ' +
         '& $scc $nvcc (''-ccbin='' + $cl) -arch=sm_80 -c C:\cachetest.cu -o C:\t2.obj; ' +
         'if ($LASTEXITCODE -ne 0) { throw (''second compile failed: '' + $LASTEXITCODE) }; ' +
         '$stats = & $scc --show-stats | Out-String; Write-Host $stats; ' +
         '$hits = 0; if ($stats -match ''Cache hits\s+(\d+)'') { $hits = [int]$Matches[1] }; ' +
         '$writes = 0; if ($stats -match ''Cache writes\s+(\d+)'') { $writes = [int]$Matches[1] }; ' +
         'Write-Host (''CUDA-CACHE-VERIFY hits='' + $hits + '' writes='' + $writes); ' +
         'if ($hits -lt 1) { throw ''NO CACHE HIT on identical recompile - CUDA caching is broken'' }; ' +
         'if ($writes -lt 1) { throw ''NO CACHE WRITE - objects never reached the WebDAV L2'' }')
    )
    Set-Content -Path (Join-Path $ctx 'Dockerfile') -Value ($runLines -join "`n") -Encoding ascii

    Write-Host "== CUDA cache verify: $BaseImage vs $Endpoint ==" -ForegroundColor Cyan
    & $BuildCtl --addr npipe:////./pipe/buildkitd build --frontend dockerfile.v0 `
        --local "context=$ctx" --local "dockerfile=$ctx" `
        --opt image-resolve-mode=local --opt "build-arg:SCCACHE_EP=$Endpoint" --no-cache `
        --output 'type=image,name=docker.io/local/kataglyphis:verify-cuda-cache' 2>&1 |
        ForEach-Object { Write-Host $_ }
    $code = $LASTEXITCODE
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
