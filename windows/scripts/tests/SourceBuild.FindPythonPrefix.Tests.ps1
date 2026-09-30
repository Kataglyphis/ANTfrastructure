#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# ORT and GenAI honour the unversioned Python_* hints, never Python3_*; OpenCV's PYTHON3_* is a different, correct contract.

Describe 'FindPython prefix: ORT and GenAI ask the helper for the names their CMake actually reads' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:ort    = Get-Content -Raw (Join-Path $root 'scripts\build\Build-OnnxFromSource.ps1')
        $script:genai  = Get-Content -Raw (Join-Path $root 'scripts\build\Build-OnnxGenaiFromSource.ps1')
        $script:ffmpeg = Get-Content -Raw (Join-Path $root 'scripts\build\Build-FfmpegFromSource.ps1')
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
        # PyAV's build_ext needs the target platform too, or the x86_arm64 cross tools are not picked.
        Assert-True ($script:ffmpeg -cmatch 'build_ext --plat-name \$distutilsPlat bdist_wheel --plat-name \$\(Get-PythonWheelTag\)') 'PyAV cross: build_ext plat + bdist_wheel tag'
        Assert-True ($script:ffmpeg -cnotmatch 'Assert-WheelTargetArch -WheelPath') 'PyAV no longer hand-rolls the stage+assert the helper owns'
    }
}
