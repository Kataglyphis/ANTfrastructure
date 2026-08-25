#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# FindPython variable PREFIX parity (#120 step 2, 2026-08-24; helper-based
# since #131, 2026-08-25).
#
# ONNX Runtime and onnxruntime-genai both call CMake's find_package(Python ...)
# with the UNVERSIONED prefix, so the hints they honour are Python_EXECUTABLE /
# Python_INCLUDE_DIR / Python_LIBRARY (and Python_NumPy_INCLUDE_DIR for ORT);
# genai's vendored pybind11 (classic mode) additionally reads the legacy
# PYTHON_* trio. For months the build scripts passed Python3_* (ORT) and only
# the legacy names (GenAI). CMake said so on every run -- "Manually-specified
# variables were not used by the project" -- and amd64 only worked by
# auto-detection; the first cross configure died on `Python::NumPy`.
#
# Both scripts now compose the hints through Get-PythonCMakeHintArgs from the
# Get-TargetBuildPython object (host exe RUNS, target lib LINKS). This suite
# pins (a) which prefixes each script asks for, (b) that no Python3_ spelling
# creeps back, (c) the cross wheel path (-CrossStage) on ORT, GenAI and PyAV.
# OpenCV is deliberately NOT covered: its own OpenCVDetectPython.cmake reads
# PYTHON3_* -- a different, correct contract.

Describe 'FindPython prefix: ORT and GenAI ask the helper for the names their CMake actually reads' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:ort    = Get-Content -Raw (Join-Path $root 'scripts\build\build-onnx-from-source.ps1')
        $script:genai  = Get-Content -Raw (Join-Path $root 'scripts\build\build-onnx-genai-from-source.ps1')
        $script:ffmpeg = Get-Content -Raw (Join-Path $root 'scripts\build\build-ffmpeg-from-source.ps1')
    }

    It 'ORT asks for the Python prefix with the NumPy include hint, from the target-build object' {
        Assert-True ($script:ort -cmatch "Get-PythonCMakeHintArgs -Python \`$tpy -Prefix 'Python' -NumPyIncludeDir \`$numpyInc") 'ORT: Python prefix + NumPy hint from $tpy'
        Assert-True ($script:ort -cmatch '\$tpy = Get-TargetBuildPython') 'the accessor is called by name so its .Available guard is in play'
    }

    It 'GenAI asks for BOTH spellings -- Python_* for its find_package and PYTHON_* for vendored pybind11' {
        Assert-True ($script:genai -cmatch "Get-PythonCMakeHintArgs -Python \`$tpy -Prefix @\('Python', 'PYTHON'\)") 'GenAI: both prefixes from $tpy'
    }

    It 'neither script spells a hint by hand any more, and the ignored Python3_ name never returns' {
        foreach ($pair in @(@{ Name = 'ORT'; Text = $script:ort }, @{ Name = 'GenAI'; Text = $script:genai })) {
            Assert-True ($pair.Text -cnotmatch '-DPython3_') "$($pair.Name): -DPython3_* is read by no finder"
            Assert-True ($pair.Text -cnotmatch '"-D(Python|PYTHON)_(EXECUTABLE|LIBRARY|INCLUDE_DIR)=') "$($pair.Name): the trio is composed by the helper, not by hand"
        }
    }

    It 'cross-lane wheels go through Invoke-PythonWheelBuild -CrossStage (built + staged, never imported here)' {
        foreach ($pair in @(@{ Name = 'ORT'; Text = $script:ort }, @{ Name = 'GenAI'; Text = $script:genai }, @{ Name = 'PyAV'; Text = $script:ffmpeg })) {
            Assert-True ($pair.Text -cmatch '-CrossStage') "$($pair.Name): the wheel call carries -CrossStage"
        }
        # PyAV (setuptools) must additionally tell build_ext the target platform so the
        # x86_arm64 cross tools are picked; the wheel tag rides on the same command line.
        Assert-True ($script:ffmpeg -cmatch 'build_ext --plat-name \$distutilsPlat bdist_wheel --plat-name \$\(Get-PythonWheelTag\)') 'PyAV cross: build_ext plat + bdist_wheel tag'
        Assert-True ($script:ffmpeg -cnotmatch 'Assert-WheelTargetArch -WheelPath') 'PyAV no longer hand-rolls the stage+assert the helper owns'
    }
}
