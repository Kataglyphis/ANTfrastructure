#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Which nvcc --options-file SHAPES does sccache cache today? (#115)

.DESCRIPTION
    Matrix over the two shapes build systems emit:
      A) everything in the rsp (incl. -c/-o)     - our synthetic probe's shape
      B) defines/includes in the rsp, -c/-o inline - CMake/ninja's usual shape
    For each: compile the synthetic TU wrapped (fresh local cache), print
    Compile requests / executed / CUDA misses. requests=0 => sccache never
    classified it as a compilation (the suspected OpenCV failure mode).
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-rsp',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache rsp-shape matrix nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
@'
#include <cuda_runtime.h>
template <typename T> __global__ void kern(T* p) { p[threadIdx.x] = static_cast<T>(threadIdx.x); }
template <typename T> int Launch(T* p) { kern<T><<<1, 32>>>(p); return static_cast<int>(sizeof(T)); }
template int Launch<float>(float*);
#ifdef PROBE_GUARDED
template int Launch<double>(double*);
#endif
'@ | Set-Content -Path probe.cu -Encoding ascii

$nvcc = "$env:CUDA_PATH\bin\nvcc.exe"
$sccache = "$env:USERPROFILE\.cargo\bin\sccache.exe"
$gencode = '-gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_86,code=sm_86'

# Shape A: EVERYTHING in the rsp
"-c probe.cu -std=c++17 -Xcompiler /MD -DPROBE_GUARDED=1 $gencode -o shapeA.obj" -replace ' ', "`n" | Set-Content shapeA.rsp -Encoding ascii
# Shape B: flags in the rsp, -c/-o inline (CMake/ninja shape)
"-std=c++17 -Xcompiler /MD -DPROBE_GUARDED=1 $gencode" -replace ' ', "`n" | Set-Content shapeB.rsp -Encoding ascii

# Shapes C/D (probe7's OpenCV anatomy: commands are INLINE and short - the
# 155 uncached requests must come from a flag, not the rsp):
#   C) inline + -Xcompiler=-Fd<pdb>,-FS   (PDB - the classic CannotCache)
#   D) inline + -MD -MT out -MF dep       (CMake's gcc-style depfile flags)
# E/F (probe15's full arg echo): opencv passes `--diag-suppress 1394,1388`
# SEPARATED - the flag is absent from sccache's nvcc ARGS table, so the
# value becomes a bare token = phantom first input file =>
# CannotCache(multiple input files). F = attached form as control.
foreach ($shape in @('A', 'B', 'C', 'D', 'E', 'F')) {
    $env:SCCACHE_MULTILEVEL_CHAIN = ''
    $env:SCCACHE_WEBDAV_ENDPOINT = ''
    $env:SCCACHE_DIR = Join-Path $WorkDir "cache$shape"
    $env:SCCACHE_ERROR_LOG = Join-Path $WorkDir "scc$shape.log"
    $env:SCCACHE_LOG = 'debug'
    $env:SCCACHE_SERVER_PORT = "424$([int][char]$shape)"
    & $sccache --stop-server 2>&1 | Out-Null
    & $sccache --start-server 2>&1 | Out-Null
    switch ($shape) {
        'A' { & $sccache $nvcc --options-file shapeA.rsp 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" } }
        'B' { & $sccache $nvcc --options-file shapeB.rsp -c probe.cu -o shapeB.obj 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" } }
        'C' { & $sccache $nvcc -forward-unknown-to-host-compiler -std=c++17 -DPROBE_GUARDED=1 '-gencode=arch=compute_80,code=sm_80' '-Xcompiler=-FdshapeC.pdb,-FS' -x cu -c probe.cu -o shapeC.obj 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" } }
        'D' { & $sccache $nvcc -forward-unknown-to-host-compiler -std=c++17 -DPROBE_GUARDED=1 '-gencode=arch=compute_80,code=sm_80' -MD -MT shapeD.obj -MF shapeD.obj.d -x cu -c probe.cu -o shapeD.obj 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" } }
        'E' { & $sccache $nvcc -std=c++17 -DPROBE_GUARDED=1 '-gencode=arch=compute_80,code=sm_80' -Xcudafe --display_error_number --diag-suppress '1394,1388' -x cu -c probe.cu -o shapeE.obj 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" } }
        'F' { & $sccache $nvcc -std=c++17 -DPROBE_GUARDED=1 '-gencode=arch=compute_80,code=sm_80' '--diag-suppress=1394,1388' -x cu -c probe.cu -o shapeF.obj 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" } }
    }
    $rc = $LASTEXITCODE
    $stats = & $sccache --show-stats 2>&1
    $req  = ($stats | Select-String '^Compile requests\s' | Select-Object -First 1).Line -replace '\D+', ''
    $exe  = ($stats | Select-String 'requests executed' | Select-Object -First 1).Line -replace '\D+', ''
    $cuda = ($stats | Select-String 'Cache misses \(CUDA\)' | Select-Object -First 1)
    & $sccache --stop-server 2>&1 | Out-Null
    Write-Host ("shape {0}: exit={1} requests={2} executed={3} cudaMissLine='{4}'" -f $shape, $rc, $req, $exe, $cuda)
}
Write-Host 'probe complete'
