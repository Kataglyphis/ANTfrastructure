# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    ROCm checks for the rocm variant image; the smoke gate runs it with EXPECT_ROCM=1.
.DESCRIPTION
    Static only: a Windows container gets no GPU compute, so no HIP kernel RUNS here.
    It proves the SDK sits where the env says, no CUDA lineage leaked in, AMD's LLVM
    does not shadow the image toolchain, and hipcc compiles a kernel for the target.
    Exits 1 on any failure. docs/windows-builds.md § ROCm layer.
#>
param(
    [string]$OffloadArch = 'gfx1201'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    The env contract Dockerfile.rocm sets; returns one message per breach.
#>
function Get-RocmImageEnvFinding {
    param([Parameter(Mandatory)][hashtable]$Environment)
    $findings = @()
    foreach ($key in 'HIP_PATH', 'ROCM_PATH', 'HIP_DEVICE_LIB_PATH', 'ROCM_WINDOWS_RELEASE') {
        if (-not $Environment[$key]) { $findings += "$key is not set" }
    }
    if ($Environment['GPU_TYPE'] -ne 'rocm') { $findings += "GPU_TYPE is '$($Environment['GPU_TYPE'])', expected 'rocm'" }
    if ($Environment['HIP_PLATFORM'] -ne 'amd') { $findings += "HIP_PLATFORM is '$($Environment['HIP_PLATFORM'])', expected 'amd'" }
    if ($Environment['HIP_PATH'] -and $Environment['ROCM_PATH'] -and $Environment['HIP_PATH'] -ne $Environment['ROCM_PATH']) {
        $findings += "HIP_PATH ($($Environment['HIP_PATH'])) and ROCM_PATH ($($Environment['ROCM_PATH'])) differ"
    }
    foreach ($key in 'CUDA_PATH', 'CUDA_ROOT') {
        if ($Environment[$key]) { $findings += "$key is set ($($Environment[$key])): a CUDA lineage leaked into the rocm image" }
    }
    return $findings
}

<#
.SYNOPSIS
    Flags image-toolchain names that resolve into ROCm's tree first (tool -> first path on PATH).
#>
function Get-RocmShadowFinding {
    param(
        [Parameter(Mandatory)][hashtable]$Resolved,
        [Parameter(Mandatory)][string]$RocmRoot
    )
    $prefix = $RocmRoot.TrimEnd('\') + '\'
    $findings = @()
    foreach ($tool in @($Resolved.Keys | Sort-Object)) {
        $first = $Resolved[$tool]
        if ($first -and $first.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $findings += "$tool resolves into ROCm's tree first ($first): AMD's LLVM shadows the image toolchain"
        }
    }
    return $findings
}

<#
.SYNOPSIS
    Compiles a one-line kernel for the target; returns a failure message, or nothing.
#>
function Get-RocmKernelCompileFinding {
    param(
        [Parameter(Mandatory)][string]$Hipcc,
        [Parameter(Mandatory)][string]$OffloadArch
    )
    $scratch = [System.IO.Directory]::CreateTempSubdirectory('rocm-smoke-').FullName
    $kernel = [System.IO.Path]::Combine($scratch, 'scale.hip')
    [System.IO.File]::WriteAllLines($kernel, [string[]]@(
        '#include <hip/hip_runtime.h>',
        '__global__ void scale(float* x, float f) { x[threadIdx.x] *= f; }'))
    $object = [System.IO.Path]::Combine($scratch, 'scale.o')
    & $Hipcc "--offload-arch=$OffloadArch" -c $kernel -o $object
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -or -not [System.IO.File]::Exists($object)) { return "hipcc could not compile a kernel for $OffloadArch (exit $rc)" }
}

$contractKeys = 'HIP_PATH', 'ROCM_PATH', 'HIP_DEVICE_LIB_PATH', 'HIP_PLATFORM', 'GPU_TYPE', 'ROCM_WINDOWS_RELEASE', 'CUDA_PATH', 'CUDA_ROOT'
$envSnapshot = @{}
Get-ChildItem Env: | Where-Object { $_.Name -in $contractKeys } | ForEach-Object { $envSnapshot[$_.Name] = $_.Value }
$failures = @(Get-RocmImageEnvFinding -Environment $envSnapshot)
$rocmRoot = $envSnapshot['HIP_PATH']

if ($rocmRoot) {
    $firstOnPath = @{}
    foreach ($tool in 'clang-cl', 'clang', 'lld-link') {
        $hit = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $firstOnPath[$tool] = if ($hit) { $hit.Source } else { $null }
    }
    $failures += Get-RocmShadowFinding -Resolved $firstOnPath -RocmRoot $rocmRoot

    $shipped = "$(Get-Content -LiteralPath (Join-Path $rocmRoot '.info\version') -Raw -ErrorAction SilentlyContinue)".Trim()
    if ($shipped -ne $envSnapshot['ROCM_WINDOWS_RELEASE']) { $failures += ".info\version is '$shipped', ROCM_WINDOWS_RELEASE is '$($envSnapshot['ROCM_WINDOWS_RELEASE'])'" }

    $bitcode = if ($envSnapshot['HIP_DEVICE_LIB_PATH']) { @(Get-ChildItem -Path $envSnapshot['HIP_DEVICE_LIB_PATH'] -Filter '*.bc' -File -ErrorAction SilentlyContinue) } else { @() }
    if ($bitcode.Count -eq 0) { $failures += "no device bitcode (*.bc) under HIP_DEVICE_LIB_PATH '$($envSnapshot['HIP_DEVICE_LIB_PATH'])'" }

    $hipccCmd = Get-Command hipcc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $hipccCmd) { $failures += 'hipcc is not on PATH' }
    else {
        $hipccPath = $hipccCmd.Source
        & $hipccPath --version
        if ($LASTEXITCODE -ne 0) { $failures += "hipcc --version exited $LASTEXITCODE" }
        # A real device compile: headers, device libs and AMD's clang all have to line up.
        $failures += @(Get-RocmKernelCompileFinding -Hipcc $hipccPath -OffloadArch $OffloadArch)
    }
}

foreach ($f in $failures) { Write-Host "  [FAIL] $f" -ForegroundColor Red }
if ($failures.Count -gt 0) {
    Write-Host "ROCm image checks: $($failures.Count) failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host "ROCm image checks: all passed (root $rocmRoot, kernel compiled for $OffloadArch)" -ForegroundColor Green
exit 0
