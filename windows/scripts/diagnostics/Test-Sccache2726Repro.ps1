#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Reproduces mozilla/sccache#2726 (-Xcompiler "/openmp:llvm" ->
    CannotCache(multiple input files)) and measures whether the 0003
    diag-family fix changes it.

.DESCRIPTION
    Expectation going in: NO - #2726's mis-split happens in the MSVC
    argument parser (the cl.exe host sub-compile of nvcc's decomposition
    splits /openmp:llvm at the colon), while 0003 only adds entries to
    nvcc's own table. Measured, not assumed: the probe builds the exact
    proposed-PR binary (pin + current patch dir), PROVES the build carries
    0003 first (a separated --diag-suppress compile must cache - sccache
    --version cannot tell builds apart), then replays the #2726 shape in
    both -Xcompiler forms against three candidates: scoop 0.17.0
    (unpatched release), the installed cargo build (quote fix only), and
    the proposed binary.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-2726',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache#2726 repro nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

# --- build the proposed-PR binary: pin + patch dir (same recipe as the
# hygiene probe / Install-RustToolchain.ps1) --------------------------------
# Pin preference: the bind-mounted REPO versions.env first - the image
# predates the ffac4a5 bump, so its baked env/C:\temp copy still points at
# the old pin and would build the wrong "proposed" binary.
$rev = ''
foreach ($src in @('C:\bkmnt\versions.env', 'C:\temp\versions.env')) {
    if ($rev -or -not (Test-Path $src)) { continue }
    $rev = (Select-String -Path $src -Pattern '^SCCACHE_GIT_REV=(.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
}
if (-not $rev) { $rev = $env:SCCACHE_GIT_REV }
if (-not $rev) { throw 'SCCACHE_GIT_REV missing (env AND C:\temp\versions.env)' }
Write-Host "pin: $rev"
$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
& git init -q src; Set-Location src
& git remote add origin https://github.com/mozilla/sccache 2>$null
& git fetch -q --depth 1 origin $rev
& git checkout -q FETCH_HEAD
foreach ($patch in (Get-ChildItem 'C:\bkmnt\patch\*.patch' | Sort-Object Name)) {
    & git apply $patch.FullName
    if ($LASTEXITCODE -ne 0) { throw "patch apply failed: $($patch.Name) ($LASTEXITCODE)" }
    Write-Host "applied: $($patch.Name)"
}
& cargo build --release --locked 2>&1 | Select-Object -Last 2 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "cargo build FAILED ($LASTEXITCODE)" }
$proposed = Join-Path (Get-Location) 'target\release\sccache.exe'
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

function Invoke-Candidate {
    param([string]$Exe, [int]$Slot, [string[]]$NvccArgs)
    $env:SCCACHE_MULTILEVEL_CHAIN = ''
    $env:SCCACHE_WEBDAV_ENDPOINT = ''
    $env:SCCACHE_DIR = Join-Path $WorkDir "cache$Slot"
    $env:SCCACHE_ERROR_LOG = Join-Path $WorkDir "scc$Slot.log"
    $env:SCCACHE_LOG = 'debug'
    $env:SCCACHE_SERVER_PORT = "45$($Slot)0"
    & $Exe --stop-server 2>&1 | Out-Null
    & $Exe --start-server 2>&1 | Out-Null
    $out = & $Exe $nvcc @NvccArgs 2>&1
    $rc = $LASTEXITCODE
    $stats = & $Exe --show-stats 2>&1
    $exeCnt = (($stats | Select-String 'requests executed' | Select-Object -First 1).Line -replace '\D+', '')
    # Client message is `Cannot cache(` (space), server log `CannotCache(`
    # - run 2 grepped only the latter and reported False on true hits.
    $cc = (@($out) + @(Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue) |
        Select-String 'Cannot ?cache\(multiple input files' -CaseSensitive:$false | Select-Object -First 1)
    & $Exe --stop-server 2>&1 | Out-Null
    if ($rc -ne 0) {
        # Write-Host, NOT the pipeline: in a function, pipeline strings
        # become part of the RETURN value and vanish from the log (bitten
        # in run 1 - every exit=1 was blind).
        ($out | Where-Object { $_ } | Select-Object -Last 3) | ForEach-Object { Write-Host "  err| $_" }
        Get-Content $env:SCCACHE_ERROR_LOG -ErrorAction SilentlyContinue |
            Select-String 'CannotCache|parse|failed' | Select-Object -Last 2 |
            ForEach-Object { Write-Host "  srv| $($_.Line.Trim().Substring(0, [Math]::Min(200, $_.Line.Trim().Length)))" }
    }
    [pscustomobject]@{ Exit = $rc; Executed = $exeCnt; MultiInput = [bool]$cc }
}

# 0003-carrier proof: the separated diag-suppress compile ONLY caches with
# the fix (unfixed: value = phantom input, rejected, executed stays 0).
$marker = Invoke-Candidate -Exe $proposed -Slot 1 -NvccArgs @(
    '-gencode=arch=compute_80,code=sm_80', '--diag-suppress', '1394', '-x', 'cu', '-c', 'vectorAdd.cu', '-o', 'marker.obj')
Write-Host ("0003-marker: exit={0} executed={1} (executed>0 proves the proposed binary carries 0003)" -f $marker.Exit, $marker.Executed)
if ($marker.Exit -ne 0 -or [int]$marker.Executed -eq 0) { throw '0003 marker failed - proposed binary does NOT behave fixed, verdicts below would be meaningless' }

$candidates = [ordered]@{
    'unpatched-0.17.0' = 'C:\Users\ContainerAdministrator\scoop\shims\sccache.exe'
    'quote-fix-only'   = "$env:USERPROFILE\.cargo\bin\sccache.exe"
    'proposed-0003'    = $proposed
}
# #2726's exact form (separated) plus the attached spelling CMake also emits.
$forms = [ordered]@{
    'separated' = @('-gencode=arch=compute_80,code=sm_80', '-Xcompiler', '/openmp:llvm', '-x', 'cu', '-c', 'vectorAdd.cu')
    'attached'  = @('-gencode=arch=compute_80,code=sm_80', '-Xcompiler=/openmp:llvm', '-x', 'cu', '-c', 'vectorAdd.cu')
}
# Bare-control first: if plain nvcc rejects the shape, the repro doesn't
# express #2726 in this environment and every sccache verdict is noise.
foreach ($form in $forms.Keys) {
    $bareOut = & $nvcc @($forms[$form]) -o "bare-$form.obj" 2>&1
    Write-Host ("bare-control form={0,-9} exit={1}" -f $form, $LASTEXITCODE)
    if ($LASTEXITCODE -ne 0) { ($bareOut | Select-Object -Last 3) | ForEach-Object { Write-Host "  bare| $_" } }
}

$slot = 1
foreach ($name in $candidates.Keys) {
    $exe = $candidates[$name]
    if (-not (Test-Path $exe)) { Write-Host "cand $name : MISSING at $exe"; continue }
    foreach ($form in $forms.Keys) {
        $slot++
        $r = Invoke-Candidate -Exe $exe -Slot $slot -NvccArgs ($forms[$form] + @('-o', "out$slot.obj"))
        Write-Host ("cand {0,-18} form={1,-9} exit={2} executed={3} multiple-input-files={4}" -f $name, $form, $r.Exit, $r.Executed, $r.MultiInput)
    }
}
Write-Host 'probe complete'
