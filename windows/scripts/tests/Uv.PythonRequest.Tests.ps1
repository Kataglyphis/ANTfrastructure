#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# A plain 3.14 took a 3.14t leg's free-threaded download, which has no genai-cuda wheel (OrchestrANT, 2026-09-30).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsUv.Common.psm1') -Force -DisableNameChecking

Describe 'Get-UvPythonRequest' {

    It 'pins a bare version to the GIL build' {
        foreach ($version in '3.14', '3.14.7', '3') { Assert-Equal "$version+gil" (Get-UvPythonRequest -Version $version) $version }
    }

    It 'passes free-threaded requests, paths and explicit variants unchanged' {
        foreach ($request in '3.14t', '3.14+freethreaded', 'C:\temp\cpython\PCbuild\amd64\python.exe', 'cpython-3.14') {
            Assert-Equal $request (Get-UvPythonRequest -Version $request) $request
        }
    }
}
