#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# The ORT free-threaded define's source patch and gate wiring; a configured arm64 tree and the twin's import are not covered.

Describe 'ORT pybind free-threaded define' {
    It 'scopes the define to the pybind target inside upstream''s detection branch' {
        $patch = Get-TestRepoText 'windows\scripts\patches\onnxruntime\007-pybind-free-threaded-define.patch'
        Assert-Match '(?m)^\+\s*target_compile_definitions\(onnxruntime_pybind11_state PRIVATE Py_GIL_DISABLED=1\)' $patch 'only the pybind target gets it'
        Assert-Match '(?s)Enabling free-threaded support.*?\+\s*target_compile_definitions' $patch 'inside the branch a GIL configure never takes'
        Assert-False ($patch -match '(?m)^\+.*CMAKE_C(XX)?_FLAGS') 'a global flag would recompile MLAS and relink onnxruntime.dll'
    }

    It 'applies fatally before configure, and the twin still gates on the define' {
        $build = Get-TestRepoText 'windows\scripts\build\Build-OnnxFromSource.ps1'
        Assert-Match 'Invoke-RequiredSourcePatch [^\r\n]*007-pybind-free-threaded-define\.patch' $build 'a patch that stops applying fails the build'
        Assert-Match 'Assert-NinjaFreeThreadedDefine -BuildDir \$BuildDir' $build 'the twin keeps its gate'
    }
}
