#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Is mozilla/sccache#1105 (--default-stream support) already resolved at
    our pin? Expectation: YES via upstream fb6e671, independent of 0003 -
    the PR-2 draft cites it as precedent, so the claim must be measured.

.DESCRIPTION
    Compiles one CUDA TU with --default-stream per-thread in all four
    spellings (single/double dash x separated/attached) through the
    installed cargo sccache (pin + quote fix, NO 0003) and through scoop
    0.17.0. A form counts as supported when the request executes (>0) and
    no 'multiple input files' rejection appears.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-1105',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache#1105 default-stream check nonce=$Nonce ==="
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
    'release-0.17.0' = 'C:\Users\ContainerAdministrator\scoop\shims\sccache.exe'
    'pin-no-0003'    = "$env:USERPROFILE\.cargo\bin\sccache.exe"
}
$forms = [ordered]@{
    'sep-2dash' = @('--default-stream', 'per-thread')
    'att-2dash' = @('--default-stream=per-thread')
    'sep-1dash' = @('-default-stream', 'per-thread')
    'att-1dash' = @('-default-stream=per-thread')
}
$slot = 0
foreach ($name in $candidates.Keys) {
    $exe = $candidates[$name]
    if (-not (Test-Path $exe)) { Write-Host "cand $name : MISSING at $exe"; continue }
    foreach ($form in $forms.Keys) {
        $slot++
        $env:SCCACHE_MULTILEVEL_CHAIN = ''
        $env:SCCACHE_WEBDAV_ENDPOINT = ''
        $env:SCCACHE_DIR = Join-Path $WorkDir "cache$slot"
        $env:SCCACHE_ERROR_LOG = Join-Path $WorkDir "scc$slot.log"
        $env:SCCACHE_LOG = 'debug'
        $env:SCCACHE_SERVER_PORT = "46$($slot)0"
        & $exe --stop-server 2>&1 | Out-Null
        & $exe --start-server 2>&1 | Out-Null
        # NOT $args - that's PowerShell's automatic variable.
        $nvccArgs = @('-gencode=arch=compute_80,code=sm_80') + $forms[$form] + @('-x', 'cu', '-c', 'vectorAdd.cu', '-o', "out$slot.obj")
        $out = & $exe $nvcc @nvccArgs 2>&1
        $rc = $LASTEXITCODE
        $stats = & $exe --show-stats 2>&1
        $exeCnt = (($stats | Select-String 'requests executed' | Select-Object -First 1).Line -replace '\D+', '')
        $cc = (@($out) + @(Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue) |
            Select-String 'Cannot ?cache\(multiple input files' -CaseSensitive:$false | Select-Object -First 1)
        & $exe --stop-server 2>&1 | Out-Null
        if ($rc -ne 0) { ($out | Where-Object { $_ } | Select-Object -Last 3) | ForEach-Object { Write-Host "  err| $_" } }
        Write-Host ("cand {0,-15} form={1,-9} exit={2} executed={3} multiple-input-files={4}" -f $name, $form, $rc, $exeCnt, [bool]$cc)
    }
}
Write-Host 'probe complete'
