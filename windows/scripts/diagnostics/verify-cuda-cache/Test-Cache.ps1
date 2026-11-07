#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Test-CudaCache.ps1's in-container payload: the same .cu twice through sccache must write, then hit.
$ErrorActionPreference = 'Stop'

$scc = 'C:\Users\ContainerAdministrator\.cargo\bin\sccache.exe'
$nvcc = (Get-ChildItem 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v*\bin\nvcc.exe' | Select-Object -First 1).FullName
$cl = (Get-ChildItem 'C:\Program Files (x86)\Microsoft Visual Studio\*\BuildTools\VC\Tools\MSVC\*\bin\HostX64\x64\cl.exe' | Select-Object -First 1).FullName
if (-not $nvcc -or -not $cl) { throw 'nvcc or cl not found in image' }
$env:Path = (Split-Path $cl) + ';' + $env:Path
$msvcRoot = Split-Path (Split-Path (Split-Path (Split-Path $cl)))
$sdkInc = (Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include\10.*' | Sort-Object Name | Select-Object -Last 1).FullName
$env:INCLUDE = $msvcRoot + '\include;' + $sdkInc + '\ucrt;' + $sdkInc + '\shared;' + $sdkInc + '\um'

& $scc --stop-server 2>$null
& $scc --start-server
& $scc -z | Out-Null

# A per-run nonce in code, not a comment, which preprocessing strips from the cache key; it makes compile 1 a guaranteed miss.
$nonce = [guid]::NewGuid().ToString('N')
Set-Content -Path C:\cachetest.cu -Value ("__device__ const char cachetest_nonce[] = `"$nonce`";`n" + '__global__ void k(float* p){ p[threadIdx.x] *= 2.0f; }')
& $scc $nvcc ('-ccbin=' + $cl) -arch=sm_80 -c C:\cachetest.cu -o C:\t1.obj
if ($LASTEXITCODE -ne 0) { throw ('first compile failed: ' + $LASTEXITCODE) }
& $scc $nvcc ('-ccbin=' + $cl) -arch=sm_80 -c C:\cachetest.cu -o C:\t2.obj
if ($LASTEXITCODE -ne 0) { throw ('second compile failed: ' + $LASTEXITCODE) }

$stats = & $scc --show-stats | Out-String
Write-Host $stats
$hits = 0; if ($stats -match 'Cache hits\s+(\d+)') { $hits = [int]$Matches[1] }
$misses = 0; if ($stats -match 'Cache misses\s+(\d+)') { $misses = [int]$Matches[1] }
Write-Host ('CUDA-CACHE-VERIFY hits=' + $hits + ' misses=' + $misses)
# sccache 0.19 prints no write count; the nonce makes compile 1 a miss, so a later hit can only come from what it wrote to the L2.
if ($misses -lt 1) { throw 'NO CACHE MISS on the nonce compile - the probe did not reach sccache' }
if ($hits -lt 1) { throw 'NO CACHE HIT on identical recompile - CUDA caching is broken' }
