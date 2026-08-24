#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# FindPython variable PREFIX parity (#120 step 2, 2026-08-24).
#
# ONNX Runtime and onnxruntime-genai both call CMake's find_package(Python ...)
# with the UNVERSIONED prefix, so the hints they honour are Python_EXECUTABLE /
# Python_INCLUDE_DIR / Python_LIBRARY (and Python_NumPy_INCLUDE_DIR for ORT).
# For months the build scripts passed Python3_* (ORT) and the pybind11-legacy
# PYTHON_* names (GenAI) instead. CMake said so on every run -- "Manually-
# specified variables were not used by the project" -- and nobody read it,
# because amd64 auto-detected the host interpreter and got the right answer by
# luck. The first cross configure (arm64, run 1 of the bindings work) had no
# luck to fall back on: FindPython found no NumPy for a target it could not
# introspect and died with `Target "onnxruntime_pybind11_state" links to
# Python::NumPy but the target was not found`.
#
# This suite pins the prefix so a refactor cannot quietly reintroduce the
# ignored spelling, and pins the host-exe / TARGET-lib split that makes the
# cross lane correct: the interpreter that RUNS is the host one, the import
# lib that is LINKED is the target one (Get-TargetBuildPython encodes it).
# OpenCV is deliberately NOT covered: its own OpenCVDetectPython.cmake reads
# PYTHON3_* -- a different, correct contract.

Describe 'FindPython prefix: ORT and GenAI pass the names their CMake actually reads' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:ort   = Get-Content -Raw (Join-Path $root 'scripts\build\build-onnx-from-source.ps1')
        $script:genai = Get-Content -Raw (Join-Path $root 'scripts\build\build-onnx-genai-from-source.ps1')
        $script:ffmpeg = Get-Content -Raw (Join-Path $root 'scripts\build\build-ffmpeg-from-source.ps1')
    }

    It 'ORT passes Python_EXECUTABLE / Python_INCLUDE_DIR / Python_LIBRARY (unversioned prefix)' {
        foreach ($name in @('Python_EXECUTABLE', 'Python_INCLUDE_DIR', 'Python_LIBRARY', 'Python_NumPy_INCLUDE_DIR')) {
            Assert-True ($script:ort -cmatch [regex]::Escape("-D$name=")) "build-onnx-from-source.ps1 must pass -D$name= (ORT's CMake calls find_package(Python ...))"
        }
    }

    It 'ORT no longer passes the ignored Python3_* spelling' {
        # -cnotmatch: PowerShell's -match is case-INSENSITIVE, and the whole point here is the
        # exact spelling (Python_ vs PYTHON_ vs Python3_ are three different CMake variables).
        Assert-True ($script:ort -cnotmatch '-DPython3_') 'a -DPython3_* argument is silently ignored by ORT''s find_package(Python ...) -- use Python_*'
    }

    It 'ORT links the TARGET import lib and runs the HOST interpreter (Get-TargetBuildPython split)' {
        Assert-True ($script:ort -match '-DPython_LIBRARY=\$\(\$tpy\.Lib\)') 'Python_LIBRARY must come from Get-TargetBuildPython (.Lib is the target import lib)'
        Assert-True ($script:ort -match '-DPython_EXECUTABLE=\$\(\$tpy\.Exe\)') 'Python_EXECUTABLE must be the host interpreter (Get-TargetBuildPython .Exe)'
        Assert-True ($script:ort -match '\$tpy = Get-TargetBuildPython') 'the accessor must be called by name so its .Available guard is in play'
    }

    It 'GenAI passes BOTH spellings -- Python_* for its own find_package(Python) and PYTHON_* for vendored pybind11 (classic mode) -- all from the target build' {
        # Two finders read two spellings (arm64 run 2, 2026-08-24: dropping the
        # legacy trio broke pybind11's FindPythonLibsNew with "Python libraries
        # not found"). Both must name the TARGET import lib.
        foreach ($name in @('Python_EXECUTABLE', 'Python_INCLUDE_DIR', 'Python_LIBRARY', 'PYTHON_EXECUTABLE', 'PYTHON_INCLUDE_DIR', 'PYTHON_LIBRARY')) {
            Assert-True ($script:genai -cmatch [regex]::Escape("-D$name=")) "build-onnx-genai-from-source.ps1 must pass -D$name="
        }
        Assert-True ($script:genai -cnotmatch '-DPython3_') 'Python3_* is read by neither of genai''s finders'
        Assert-True ($script:genai -cmatch '-DPython_LIBRARY=\$\(\$tpy\.Lib\)') 'GenAI''s Python_LIBRARY must be the TARGET import lib (Get-TargetBuildPython .Lib)'
        Assert-True ($script:genai -cmatch '-DPYTHON_LIBRARY=\$\(\$tpy\.Lib\)') 'pybind11''s PYTHON_LIBRARY must be the same TARGET import lib'
        Assert-True ($script:genai -cnotmatch '-DPYTHON_LIBRARY=\$\(\$py\.Lib\)') 'the legacy PYTHON_LIBRARY must not point at the HOST import lib'
    }

    It 'cross-lane wheels are BUILT for the target and STAGED, never installed/imported here' {
        # ORT + GenAI: Invoke-PythonWheelBuild -StageOnly with an explicit target platform tag.
        foreach ($pair in @(@{ Name = 'ORT'; Text = $script:ort }, @{ Name = 'GenAI'; Text = $script:genai })) {
            Assert-True ($pair.Text -match 'bdist_wheel --plat-name \$\(Get-PythonWheelTag\)') "$($pair.Name): the cross wheel must be tagged via --plat-name (Get-PythonWheelTag); the host-pinned shim stamps win_amd64 otherwise"
            Assert-True ($pair.Text -match '-StageOnly') "$($pair.Name): the cross wheel path must use Invoke-PythonWheelBuild -StageOnly (PE-checks every native member instead of importing)"
        }
        # PyAV (setuptools, no Invoke-PythonWheelBuild): explicit build_ext plat + Assert-WheelTargetArch.
        Assert-True ($script:ffmpeg -match 'build_ext --plat-name \$distutilsPlat bdist_wheel --plat-name \$\(Get-PythonWheelTag\)') 'PyAV cross: build_ext must be told the target platform (setuptools picks the x86_arm64 cross tools from it)'
        Assert-True ($script:ffmpeg -match 'Assert-WheelTargetArch -WheelPath') 'PyAV cross: the staged wheel must go through Assert-WheelTargetArch'
    }
}
