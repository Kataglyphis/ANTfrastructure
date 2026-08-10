# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# In-container payload for verify-cuda-cache.ps1 (backlog #14): COPY'd into
# the toolchain image and executed as the single RUN layer - lintable and
# diffable instead of the former 21-statement concatenated shell-form line.
# Compiles the same .cu twice through sccache's nvcc launcher and asserts a
# cache hit AND a backend write; the verdict is the exit code. Relies on the
# Machine-scope VS/CUDA env the base image bakes (INCLUDE/LIB assembled here).
#requires -Version 7.0
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

Set-Content -Path C:\cachetest.cu -Value '__global__ void k(float* p){ p[threadIdx.x] *= 2.0f; }'
& $scc $nvcc ('-ccbin=' + $cl) -arch=sm_80 -c C:\cachetest.cu -o C:\t1.obj
if ($LASTEXITCODE -ne 0) { throw ('first compile failed: ' + $LASTEXITCODE) }
& $scc $nvcc ('-ccbin=' + $cl) -arch=sm_80 -c C:\cachetest.cu -o C:\t2.obj
if ($LASTEXITCODE -ne 0) { throw ('second compile failed: ' + $LASTEXITCODE) }

$stats = & $scc --show-stats | Out-String
Write-Host $stats
$hits = 0; if ($stats -match 'Cache hits\s+(\d+)') { $hits = [int]$Matches[1] }
$writes = 0; if ($stats -match 'Cache writes\s+(\d+)') { $writes = [int]$Matches[1] }
Write-Host ('CUDA-CACHE-VERIFY hits=' + $hits + ' writes=' + $writes)
if ($hits -lt 1) { throw 'NO CACHE HIT on identical recompile - CUDA caching is broken' }
if ($writes -lt 1) { throw 'NO CACHE WRITE - objects never reached the WebDAV L2' }
