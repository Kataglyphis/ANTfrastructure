# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#
# Windows mirror of linux/scripts/03-media/runtime/assemble-torch-app.sh:
# clone OrchestrANT at $AppRef, `uv sync` its environment on the
# source-built CPython, then RECONCILE so the wheels built by this lane
# (onnxruntime / onnxruntime-genai / tvm, staged at C:\runtime\wheels) always win
# over anything PyPI resolved -- remaining dependencies come from PyPI/pytorch
# index. The source-built cv2 (no wheel by design) plus the sitecustomize shim
# (platform tag + native DLL dirs) are staged into the venv, mirroring the
# linux staged-OpenCV5 handling. GUI extra (wxPython) excluded, like linux.
param(

    [string]$AppRef = '',
    [string]$AppDir = 'C:\opt\OrchestrANT',
    [string]$WheelDir = 'C:\runtime\wheels',
    [ValidateSet('install', 'verify', 'all')][string]$Mode = 'all',
    # Torch BACKEND extra (torch is declared ONLY inside these extras in the
    # app's pyproject -- see the linux script's 2026-07-12 lesson): pytorch-cpu
    # (default), pytorch-cu130, ... 'none' disables.
    [string]$PytorchExtra = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Canonical stderr-shielded native runner (this script's local Invoke-TorchAppNative
# was the prototype; it is now promoted to WindowsNative.Common.psm1 and consumed
# from there). This script runs in the torch stage, where the whole modules dir
# is COPY'd.
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$nativeModulePath = Join-Path $scriptAssetRoot 'modules\WindowsNative.Common.psm1'
if (-not (Test-Path $nativeModulePath)) { throw "Required module not found: $nativeModulePath" }
Import-Module $nativeModulePath -Force

# The else-literal must equal versions.env APP_REF; SourceBuild.PinParity gates
# exactly that, and it had drifted a patch behind (v0.0.27 vs v0.0.28), which
# means an unattended run with no APP_REF in the environment built the wrong tag.
if ([string]::IsNullOrWhiteSpace($AppRef)) { $AppRef = if ($env:APP_REF) { $env:APP_REF } else { 'v0.0.28' } }
if ([string]::IsNullOrWhiteSpace($PytorchExtra)) { $PytorchExtra = if ($env:PYTORCH_EXTRA) { $env:PYTORCH_EXTRA } else { 'pytorch-cpu' } }

$cpythonExe = 'C:\temp\cpython\PCbuild\amd64\python.exe'
$baseSite = 'C:\temp\cpython\Lib\site-packages'
$venvDir = Join-Path $AppDir '.venv'
$venvPython = Join-Path $venvDir 'Scripts\python.exe'
$venvSite = Join-Path $venvDir 'Lib\site-packages'

function Install-TorchAppEnvironment {
    Write-Host "=== torch app: clone $AppRef + uv sync (extras: ml-ai docs $PytorchExtra test) ==="
    if (Test-Path $AppDir) { Remove-Item $AppDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Split-Path $AppDir -Parent) | Out-Null
    [void](Invoke-ShieldedNative -Label 'git clone (app)' -CommandLine "git clone --branch $AppRef --depth 1 https://github.com/Kataglyphis/OrchestrANT.git ""$AppDir""")

    # Venv on the SOURCE-built CPython (matches our cp314 wheels; see the
    # media-merge UV_PYTHON seeding fix). copy link mode: hardlinks don't
    # survive docker layer boundaries.
    $env:UV_PYTHON = $cpythonExe
    $env:UV_LINK_MODE = 'copy'
    # No uv wheel cache: everything resolved here is installed exactly once into
    # the venv, and uv's cache (multiple GB of torch/onnxruntime wheels) would
    # otherwise be committed into the torch layer.
    $env:UV_NO_CACHE = '1'

    Push-Location $AppDir
    try {
        $extraArgs = '--extra ml-ai --extra docs'
        if ($PytorchExtra -and $PytorchExtra -ne 'none') { $extraArgs += " --extra $PytorchExtra" }
        if ($env:SKIP_TORCH_TEST_EXTRAS -ne 'true') { $extraArgs += ' --extra test' }
        # ai-edge-litert: ml-ai pins 2.1.3, which ships NO cp314 wheel (cp311-313
        # only) and is the one family this lane cannot build (LiteRT python is
        # bazel-only on Windows; linux serves it from a locally-built wheel via
        # the same --no-install-package mechanism). The app's LiteRT code path is
        # therefore unavailable in this venv -- documented limitation.
        $syncArgs = "--find-links ""$WheelDir"" $extraArgs --no-install-package ai-edge-litert"

        # Frozen first when the repo ships a lock; regenerate on failure
        # (this Python/platform may not be covered by the upstream lock).
        $haveLock = Test-Path (Join-Path $AppDir 'uv.lock')
        $frozenOk = $false
        if ($haveLock) {
            try { [void](Invoke-ShieldedNative -Label 'uv sync --frozen' -CommandLine "uv sync $syncArgs --frozen"); $frozenOk = $true }
            catch { Write-Warning "frozen upstream uv.lock failed for this Python/platform -- regenerating a local lock ($($_.Exception.Message))" }
        }
        if (-not $frozenOk) {
            [void](Invoke-ShieldedNative -Label 'uv lock' -CommandLine "uv lock --find-links ""$WheelDir""")
            [void](Invoke-ShieldedNative -Label 'uv sync' -CommandLine "uv sync $syncArgs")
        }

        # -- Reconcile (linux reconcile_local_wheels): our source builds WIN. --
        # Uninstall any PyPI build of a family we ship locally BEFORE
        # force-reinstalling, so a transitively-pulled upstream (onnxruntime-gpu,
        # opencv-python 4.x) cannot shadow the custom build.
        [void](Invoke-ShieldedNative -Optional -Label 'uninstall pypi onnx/genai/opencv families' `
                -CommandLine "uv pip uninstall --python ""$venvPython"" onnxruntime onnxruntime-gpu onnxruntime-directml onnxruntime-genai onnxruntime-genai-cuda onnxruntime-genai-directml opencv-python opencv-python-headless opencv-contrib-python opencv-contrib-python-headless")
        $localWheels = @(Get-ChildItem -Path $WheelDir -Filter '*.whl' -ErrorAction SilentlyContinue | ForEach-Object { '"{0}"' -f $_.FullName })
        if ($localWheels.Count -eq 0) { throw "no local wheels found in $WheelDir -- the media build should have staged onnxruntime/genai/tvm" }
        # --no-deps is REQUIRED: onnxruntime_genai_cuda declares its dependency as
        # `onnxruntime-gpu`, but this lane ships the combined `onnxruntime` wheel
        # (CUDA+TRT+DML in one) -- letting uv resolve that metadata is unsatisfiable
        # on cp314 and would shadow our build even if it resolved. (linux dodges
        # this by PRUNING genai wheels on plain-onnxruntime lanes; we want genai.)
        [void](Invoke-ShieldedNative -Label 'force-reinstall local wheels (no-deps)' `
                -CommandLine "uv pip install --python ""$venvPython"" --force-reinstall --no-deps $($localWheels -join ' ')")
        # Stage from the base interpreter's site-packages (venvs do not see it):
        # - cv2: no wheel exists by design (opencv-python is a separate project)
        # - tvm_ffi: tvm 0.25's FFI split makes it a hard top-level import, and
        #   the version our tvm build installed (0.1.12 final) has NO usable
        #   PyPI wheel (only 0.1.12rc0 sdist/rc) -- copy the working one
        # - sitecustomize.py: win-amd64 tag + add_dll_directory for the image's
        #   native DLL homes (everything else is lazy/optional or rides the app
        #   lock; force-adding e.g. ml_dtypes drags a cp314-less sdist build in)
        # ml_dtypes: iree.runtime hard-imports it; our wheels install --no-deps
        # here and the app lock does not carry it, so stage the base copy (pip
        # resolution risks a cp314-less sdist -- same reason as tvm_ffi).
        foreach ($staged in @('cv2', 'tvm_ffi', 'ml_dtypes', 'sitecustomize.py')) {
            $src = Join-Path $baseSite $staged
            if (Test-Path $src) {
                Copy-Item $src -Destination $venvSite -Recurse -Force
                Write-Host "Staged $staged into venv site-packages"
            } elseif ($staged -eq 'sitecustomize.py') {
                # HARD fail (2026-08-21): unlike cv2/tvm_ffi/ml_dtypes, nothing
                # downstream ever imports sitecustomize explicitly — a missing
                # copy silently drops the win-amd64 platform tag AND the
                # add_dll_directory calls for the image's native DLL homes,
                # and Test-TorchAppEnvironment cannot catch it.
                throw "$src not found -- the venv would silently lose the platform tag + DLL-dir wiring"
            } else {
                Write-Warning "$src not found -- venv will miss $staged"
            }
        }
        # abi3 wheels (IREE's cp312-abi3 pyds) link python3.dll, which uv venvs
        # do NOT stage next to their python.exe -- the import then dies with
        # STATUS_DLL_NOT_FOUND (same trap PyAV hit in the pip-route spikes).
        # Copy it from the source CPython beside the venv interpreter.
        $venvScripts = Split-Path $venvPython -Parent
        $py3Dll = Join-Path $venvScripts 'python3.dll'
        if (-not (Test-Path $py3Dll)) {
            $srcPy3 = 'C:\temp\cpython\PCbuild\amd64\python3.dll'
            if (Test-Path $srcPy3) {
                Copy-Item $srcPy3 $py3Dll -Force
                Write-Host 'Staged python3.dll into venv Scripts (abi3 wheel support)'
            } else {
                Write-Warning "python3.dll not found at $srcPy3 -- abi3 wheels (iree) may fail to import"
            }
        }
    } finally { Pop-Location }
    Write-Host '=== torch app: install complete ==='
}

function Test-TorchAppEnvironment {
    Write-Host '=== torch app: verify ==='
    if (-not (Test-Path $venvPython)) { throw "venv python missing at $venvPython (run -Mode install first)" }
    $verifyPy = Join-Path $env:TEMP 'verify-torch-app.py'
    $gpuLane = ($env:GPU_TYPE -eq 'nvidia')
    # try/finally: the staged verify script must not survive this function on the
    # FAILURE path either (it would otherwise ride into the layer/debug image).
    try {
        Set-Content -Path $verifyPy -Encoding ASCII -Value @'
import os
import sys
os.environ.setdefault('OPENCV_LOG_LEVEL', 'ERROR')
import numpy
print('numpy', numpy.__version__)
import cv2
print('cv2', cv2.__version__)
import torch
print('torch', torch.__version__)
import onnxruntime
providers = onnxruntime.get_available_providers()
print('onnxruntime', onnxruntime.__version__, providers)
import onnxruntime_genai
print('onnxruntime-genai', getattr(onnxruntime_genai, '__version__', 'n/a'))
import tvm
print('tvm', tvm.__version__)
import av
print('pyav', av.__version__)
import iree.compiler
import iree.runtime
print('iree-compiler', getattr(iree.compiler, '__version__', 'n/a'))
if '--require-cuda-ep' in sys.argv:
    assert 'CUDAExecutionProvider' in providers, 'ERROR: local onnxruntime wheel lost its CUDAExecutionProvider!'
    print('CUDAExecutionProvider present (build check, no device required)')
print('torch-app-env OK')
'@
        $cudaFlag = if ($gpuLane) { ' --require-cuda-ep' } else { '' }
        [void](Invoke-ShieldedNative -Label 'venv import verification' -CommandLine """$venvPython"" ""$verifyPy""$cudaFlag")
    } finally {
        Remove-Item $verifyPy -Force -ErrorAction SilentlyContinue
    }
    # The app's OWN wheel-smoke suite ("exercise the installed ML wheels with
    # real work"; exits non-zero on any required failure -- upstream designed it
    # to gate container builds). Expected report on this lane: 10/11 ok on app
    # v0.0.24/v0.0.25 (pyav check on top of v0.0.23's genai + tvm), 11/12 ok
    # once a tag ships the iree check -- always with ONE WARN (ai-edge-litert,
    # skipped by design: no cp314 wheel exists).
    [void](Invoke-ShieldedNative -Label 'app smoke suite (python -m orchestrant.smoke)' `
            -CommandLine """$venvPython"" -m orchestrant.smoke")
    [void](Invoke-ShieldedNative -Optional -Label 'uv pip list' -CommandLine "uv pip list --python ""$venvPython""")
    Write-Host '=== torch app: verify complete ==='
}

if ($Mode -in @('install', 'all')) { Install-TorchAppEnvironment }
if ($Mode -in @('verify', 'all')) { Test-TorchAppEnvironment }

# Explicit success: pwsh -File (and docker RUN) propagate the LAST native exit
# code otherwise. Real failures throw above; reaching EOF IS success.
exit 0