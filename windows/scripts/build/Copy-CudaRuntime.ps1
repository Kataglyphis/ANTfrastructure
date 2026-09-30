# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# A script, not a COPY: spaces in Program Files and cuDNN 9's CUDA-major bin subdir; see docs/windows-builds.md § Copy-CudaRuntime.ps1.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dest = 'C:\cuda-rt'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Guarded: Join-Path on an unset root throws an opaque binding error; a cross GPU lane must read bin\arm64, not the x64 bin\.
$targetArch = if ([string]::IsNullOrWhiteSpace($env:WINDOWS_TARGET_ARCH)) { 'amd64' } else { $env:WINDOWS_TARGET_ARCH }
$binSubdir = if ($targetArch -eq 'amd64') { 'bin' } else { 'bin\arm64' }
$cudaBin = if ($env:CUDA_ROOT) { Join-Path $env:CUDA_ROOT $binSubdir } else { $null }
$cudnnBin = if ($env:CUDNN_ROOT) { Join-Path $env:CUDNN_ROOT $binSubdir } else { $null }
# The outer @() matters: zero or one root makes $roots.Count throw under StrictMode.
$roots = @(@(
    $cudaBin,                             # cudart64_*, cublas64_*, cufft64_*, ...
    $cudnnBin                             # cudnn64_9.dll + cudnn_*64_9 engines (under bin\<cuda-major>\)
) | Where-Object { $_ -and (Test-Path $_) })

# No root set is a CPU lane, whose empty dir still feeds the merge's unconditional COPY; a set root that does not resolve is a broken nvidia base.
$cudaConfigured = [bool]$env:CUDA_ROOT -or [bool]$env:CUDNN_ROOT
if ($roots.Count -eq 0) {
    if ($cudaConfigured) {
        throw "Neither CUDA_ROOT\bin nor CUDNN_ROOT resolves (CUDA_ROOT='$env:CUDA_ROOT', CUDNN_ROOT='$env:CUDNN_ROOT'). Is this stage derived from the nvidia base?"
    }
    Write-Host "No CUDA/cuDNN on this lane (CUDA_ROOT and CUDNN_ROOT are both unset) - staged an EMPTY $dest so the merge fan-in's unconditional COPY still succeeds."
    exit 0
}

# Imported by nothing and in no dlopen family; cudnn_*, the nvrtc/nvjitlink JIT chain and curand stay, as only static imports were checked.
$trimmed = @('cusparse64_*.dll', 'cusolver64_*.dll', 'cusolvermg64_*.dll', 'nvjpeg64_*.dll', 'npps64_*.dll')
$count = 0
$skipped = 0
foreach ($root in $roots) {
    Get-ChildItem -Path $root -Filter '*.dll' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($trimmed | Where-Object { $name -like $_ }) { $skipped++; return }
        # Last writer wins on duplicate basenames, which is fine for a single-CUDA image.
        Copy-Item -Path $_.FullName -Destination (Join-Path $dest $name) -Force
        $count++
    }
}
Write-Host "Trimmed $skipped unreferenced DLLs (closure-verified; see #54)"

# Hard gate: the whole point is cudnn64_9.dll. Fail loud if the layout moved.
if (-not (Test-Path (Join-Path $dest 'cudnn64_9.dll'))) {
    $present = @(Get-ChildItem -Path $dest -Filter 'cudnn*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    throw "cudnn64_9.dll was not staged into $dest. cudnn*.dll present: $($present -join ', '). Check the cuDNN version/layout under $env:CUDNN_ROOT."
}

Write-Host "Staged $count CUDA/cuDNN runtime DLLs into $dest (incl. cudnn64_9.dll)"
exit 0
