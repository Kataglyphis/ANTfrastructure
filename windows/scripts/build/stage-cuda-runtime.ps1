# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Flatten the CUDA + cuDNN RUNTIME DLLs into ONE directory the merge image can put
# on PATH. WHY A SCRIPT (not a COPY in the Dockerfile): the source DLLs live under
# "C:\Program Files\..." (spaces break the shell-form COPY tokenizer) AND cuDNN 9
# stows its DLLs in a CUDA-major SUBDIR under bin\ (so a whole-\bin COPY lands
# cudnn64_9.dll one level too deep to be found on PATH). A recursive copy handles
# both. Runs in a stage derived from media-core, which is built on the nvidia base
# and therefore carries CUDA_ROOT / CUDNN_ROOT in its environment.
#
# The consumer is gst-plugins-bad's opencv plugin: OpenCV builds with
# WITH_CUDA/WITH_CUDNN and HARD-links cudnn64_9.dll, so without it the plugin DLL
# fails to load (Win32 126) in the (non-nvidia) merge image.

$ErrorActionPreference = 'Stop'

$dest = 'C:\cuda-rt'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# The CUDA_ROOT guard is load-bearing, not defensive noise: with the variable
# unset, `Join-Path $env:CUDA_ROOT 'bin'` throws ParameterBindingValidationException
# ("Cannot bind argument to parameter 'Path' because it is null") under
# $ErrorActionPreference='Stop' -- BEFORE the explanatory throw below can run.
# The operator then sees an opaque binding error instead of "Is this stage
# derived from the nvidia base?".
#
# That path is no longer hypothetical: every recorded chain run so far was
# gpu=True, but the arm64 lane REFUSES -Gpu (there is no CUDA for
# Windows-on-ARM), so this stage now has a lane on which CUDA_ROOT is
# legitimately absent and the diagnostic is the whole point.
$cudaBin = if ($env:CUDA_ROOT) { Join-Path $env:CUDA_ROOT 'bin' } else { $null }
$roots = @(
    $cudaBin,                             # cudart64_*, cublas64_*, cufft64_*, ...
    $env:CUDNN_ROOT                       # cudnn64_9.dll + cudnn_*64_9 engines (under bin\<cuda-major>\)
) | Where-Object { $_ -and (Test-Path $_) }

if ($roots.Count -eq 0) {
    throw "Neither CUDA_ROOT\bin nor CUDNN_ROOT resolves (CUDA_ROOT='$env:CUDA_ROOT', CUDNN_ROOT='$env:CUDNN_ROOT'). Is this stage derived from the nvidia base?"
}

# TRIM (#54 re-scoped, 2026-08-20, probe-cuda-runtime-closure): the closure
# walk over every consumer (opencv/gst/onnxruntime/cv2, 76 DLLs) shows these
# are neither statically imported by anything in the merge image nor part of
# a known DYNAMIC-load family - ~436 MB reclaimed. Deliberately NOT trimmed
# despite being static-unreferenced: ALL cudnn_* sub-libraries (cudnn64_9 is
# a stub that dlopens graph/ops/engines at runtime), nvrtc/nvjitlink/
# nvfatbin/nvrtc-builtins (the JIT chain, dlopened by opencv cudev), and
# curand (cheap insurance) - dumpbin sees static imports ONLY, and this host
# cannot runtime-verify GPU loads (no NVIDIA GPU in containers), so every
# dynamic-load family stays fail-safe.
$trimmed = @('cusparse64_*.dll', 'cusolver64_*.dll', 'cusolvermg64_*.dll', 'nvjpeg64_*.dll', 'npps64_*.dll')
$count = 0
$skipped = 0
foreach ($root in $roots) {
    Get-ChildItem -Path $root -Filter '*.dll' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ($trimmed | Where-Object { $name -like $_ }) { $skipped++; return }
        # Flat destination: last writer wins on duplicate basenames (same DLL in
        # multiple CUDA-version subdirs), which is fine for a single-CUDA image.
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
