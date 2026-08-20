#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Single-TU forensic probe for the sccache nvcc dropped-instantiation
    miscompile (2026-08-18 verdict; upstream mozilla/sccache#2808 family).

.DESCRIPTION
    Compiles ONE synthetic .cu - a template with arch/macro-guarded EXPLICIT
    instantiations, four -gencode entries, the same shape as the ONNX
    attention TUs that lose symbols - twice:
      1. bare nvcc          -> reference object
      2. sccache-wrapped    -> suspect object (fresh LOCAL cache dir, own
                               server; WebDAV/multilevel env cleared so the
                               probe cannot touch the production cache)
    then diffs the symbol tables (llvm-nm) and compares the sub-commands
    sccache actually executed (SCCACHE_LOG=debug) against nvcc's own
    --dryrun plan. A symbol present bare but missing wrapped = the bug,
    localized to whichever dryrun step sccache skipped or mis-parsed.

    Runs INSIDE a container (Dockerfile.nvcc-instantiation-probe). Compile
    only - no GPU needed.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-nvcc',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache nvcc instantiation probe nonce=$Nonce ==="

# nvcc needs cl.exe as host compiler - same VsDevCmd entry the build scripts
# use (module bind-mounted by the probe Dockerfile).
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir

# ---- synthetic TU: template + guarded explicit instantiations -------------
# Mirrors the failing ONNX shape: host-callable template function whose
# explicit instantiations sit behind arch-list/macro guards, device kernel
# per instantiation, multiple -gencode values.
@'
#include <cuda_runtime.h>

template <typename T>
__global__ void kern(T* p) { p[threadIdx.x] = static_cast<T>(threadIdx.x); }

template <typename T>
int Launch(T* p) { kern<T><<<1, 32>>>(p); return static_cast<int>(sizeof(T)); }

// Unguarded instantiation - the control: must survive everything.
template int Launch<float>(float*);

// Guarded like ONNX's arch-conditional instantiations - the canaries.
// (No arithmetic on __CUDA_ARCH_LIST__: it expands to a comma list, which
// #if cannot evaluate - C1012. Presence alone differentiates: real nvcc
// defines it for the host pass; a decomposed host step that loses nvcc's
// injected defines drops this instantiation.)
#if defined(__CUDA_ARCH_LIST__)
template int Launch<double>(double*);
#endif
#ifndef __CUDA_ARCH__
// Host-side-only guard (the exact pattern sccache's own comment says
// nvcc -E cannot capture).
template int Launch<int>(int*);
#endif

// Command-line-define guard - the response-file canary: ONNX passes its huge
// -D/-I lists to nvcc via @rsp files; if the decomposition loses defines
// while expanding them, this instantiation vanishes from the wrapped object.
#ifdef PROBE_GUARDED_INSTANTIATION
template int Launch<long long>(long long*);
#endif
'@ | Set-Content -Path probe.cu -Encoding ascii

$nvcc = "$env:CUDA_PATH\bin\nvcc.exe"
if (-not (Test-Path $nvcc)) { throw "nvcc not found at $nvcc" }
$sccache = "$env:USERPROFILE\.cargo\bin\sccache.exe"
if (-not (Test-Path $sccache)) { throw "sccache not found at $sccache" }
$gencode = @('-gencode=arch=compute_80,code=sm_80', '-gencode=arch=compute_86,code=sm_86',
             '-gencode=arch=compute_89,code=sm_89', '-gencode=arch=compute_90a,code=sm_90a')
# Iteration log (all measured in this probe's own history):
#   * plain inline args           -> no symbol loss (267=267)
#   * --options-file (rsp)        -> sccache DOES NOT CACHE AT ALL (0 requests,
#     passthrough) - an rsp is a caching GAP, not the miscompile mechanism
# Current suspect: -t4 (nvcc's internal per-arch parallelism interleaves the
# dryrun steps) + the expt flags ORT-class TUs carry, all inline.
$common = @('-c', 'probe.cu', '-std=c++17', '-Xcompiler', '/MD',
            '-DPROBE_GUARDED_INSTANTIATION=1', '-t4',
            '--expt-relaxed-constexpr', '--expt-extended-lambda') + $gencode

# ---- 1. bare reference -----------------------------------------------------
& $nvcc @common -o bare.obj 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "bare nvcc failed ($LASTEXITCODE)" }

# nvcc's own plan, for the sub-command comparison below.
& $nvcc @common -o plan.obj --dryrun 2>&1 | Set-Content dryrun-plan.txt

# ---- 2. sccache-wrapped, hermetic local cache ------------------------------
# Clear every production backend so this probe runs a private server against
# a plain local dir (plain dirs are safe; the #99 defect is cache-MOUNT
# inheritance, and this is not a mount).
$env:SCCACHE_MULTILEVEL_CHAIN = ''
$env:SCCACHE_WEBDAV_ENDPOINT = ''
$env:SCCACHE_DIR = Join-Path $WorkDir 'cache'
$env:SCCACHE_ERROR_LOG = Join-Path $WorkDir 'sccache-debug.log'
$env:SCCACHE_LOG = 'debug'
$env:SCCACHE_SERVER_PORT = '4235'
& $sccache --stop-server 2>&1 | Out-Null
& $sccache --start-server 2>&1 | ForEach-Object { "$_" }
& $sccache $nvcc @common -o wrapped.obj 2>&1 | ForEach-Object { "$_" }
$wrappedExit = $LASTEXITCODE
& $sccache --show-stats 2>&1 | Select-String 'Compile requests|Cache|error' | ForEach-Object { "$_" }
& $sccache --stop-server 2>&1 | Out-Null
if ($wrappedExit -ne 0) { throw "sccache nvcc failed ($wrappedExit) - see $env:SCCACHE_ERROR_LOG" }

# ---- 3. verdict: symbol diff ------------------------------------------------
$nm = 'llvm-nm'
$bareSyms = (& $nm --defined-only bare.obj 2>$null) -replace '^\S+\s+\S+\s+', '' | Sort-Object -Unique
$wrapSyms = (& $nm --defined-only wrapped.obj 2>$null) -replace '^\S+\s+\S+\s+', '' | Sort-Object -Unique
$missing = @(Compare-Object $bareSyms $wrapSyms | Where-Object SideIndicator -eq '<=' | ForEach-Object InputObject)
$extra   = @(Compare-Object $bareSyms $wrapSyms | Where-Object SideIndicator -eq '=>' | ForEach-Object InputObject)

Write-Host ("bare symbols: {0}  wrapped symbols: {1}" -f $bareSyms.Count, $wrapSyms.Count)
if ($missing.Count -gt 0) {
    Write-Host "[FAIL] wrapped object is MISSING $($missing.Count) symbol(s) present in the bare object:"
    $missing | ForEach-Object { Write-Host "  MISSING: $_" }
} else {
    Write-Host '[ OK ] wrapped object contains every bare-object symbol'
}
if ($extra.Count -gt 0) { Write-Host "note: wrapped has $($extra.Count) extra symbol(s) (informational)" }

# ---- 4. sub-command accounting ----------------------------------------------
$planned = @(Select-String -Path dryrun-plan.txt -Pattern 'cicc|ptxas|fatbinary|cudafe' -AllMatches).Count
$executed = @(Select-String -Path $env:SCCACHE_ERROR_LOG -Pattern 'cicc|ptxas|fatbinary|cudafe' -AllMatches -ErrorAction SilentlyContinue).Count
Write-Host "dryrun plan lines mentioning cicc/ptxas/fatbinary/cudafe: $planned; sccache debug-log mentions: $executed"
Write-Host '(full evidence: dryrun-plan.txt + sccache-debug.log in the workdir; copy them out via the probe runner log)'
Get-Content dryrun-plan.txt | ForEach-Object { "plan| $_" }

Write-Host 'probe complete'
if ($missing.Count -gt 0) { exit 0 }  # a FAIL verdict is a SUCCESSFUL probe run
