#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Reproduces mozilla/sccache#2470 ("Could not parse shell line", CUDA +
    MSVC + Ninja Multi-Config) and checks whether the #2811 quote fix
    resolves it.

.DESCRIPTION
    #2470's command carries -DCMAKE_INTDIR=\"Release\" (Ninja Multi-Config
    adds it; single-config does not - matching the reporter's "msvc-x64
    preset works"). Hypothesis: same root cause as #2811 - the dryrun
    backslash-flatten destroys the \" escapes; with an ODD resulting quote
    count shlex::split returns None -> the fatal "Could not parse shell
    line" (with an even count it silently mis-groups, which was our
    dropped-instantiation presentation). A/B: the image's scoop sccache
    (0.17.0 release, unpatched) vs the cargo-bin one (patched via #114).
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-2470',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache#2470 repro nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
@'
#include <cuda_runtime.h>
__global__ void vectorAdd(const float* a, const float* b, float* c, int n) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}
int main() { return 0; }
'@ | Set-Content -Path vectorAdd.cu -Encoding ascii

$nvcc = "$env:CUDA_PATH\bin\nvcc.exe"
$candidates = [ordered]@{
    'unpatched-0.17.0' = 'C:\Users\ContainerAdministrator\scoop\shims\sccache.exe'
    'patched-#2811'    = "$env:USERPROFILE\.cargo\bin\sccache.exe"
}
$i = 0
foreach ($name in $candidates.Keys) {
    $i++
    $exe = $candidates[$name]
    if (-not (Test-Path $exe)) { Write-Host "cand $name : MISSING at $exe"; continue }
    $env:SCCACHE_MULTILEVEL_CHAIN = ''
    $env:SCCACHE_WEBDAV_ENDPOINT = ''
    $env:SCCACHE_DIR = Join-Path $WorkDir "cache$i"
    $env:SCCACHE_ERROR_LOG = Join-Path $WorkDir "scc$i.log"
    $env:SCCACHE_LOG = 'debug'
    $env:SCCACHE_SERVER_PORT = "44$($i)0"
    & $exe --stop-server 2>&1 | Out-Null
    & $exe --start-server 2>&1 | Out-Null
    # The #2470 shape: Multi-Config's escaped-quote define + -Xcompiler forms.
    $out = & $exe $nvcc -forward-unknown-to-host-compiler '-DCMAKE_INTDIR=\"Release\"' `
        '-Xcompiler= /EHsc' '-Xcompiler=-MD' `
        '-gencode=arch=compute_80,code=sm_80' -std=c++17 `
        -x cu -c vectorAdd.cu -o "out$i.obj" 2>&1
    $rc = $LASTEXITCODE
    $shellLine = [bool]($out | Select-String 'Could not parse shell line')
    $stats = & $exe --show-stats 2>&1
    $exeCnt = (($stats | Select-String 'requests executed' | Select-Object -First 1).Line -replace '\D+', '')
    & $exe --stop-server 2>&1 | Out-Null
    Write-Host ("cand {0,-18} exit={1} could-not-parse={2} executed={3}" -f $name, $rc, $shellLine, $exeCnt)
    if ($rc -ne 0 -and -not $shellLine) { ($out | Select-Object -Last 3) | ForEach-Object { "  err| $_" } }
}
Write-Host 'probe complete'
