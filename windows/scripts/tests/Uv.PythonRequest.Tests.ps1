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

Describe 'New-UvProjectEnvironment' {

    # The uv calls New-UvProjectEnvironment makes for -Version when the finder answers -Found.
    function script:Get-UvCalls {
        param([Parameter(Mandatory)][string]$Version, [bool]$Found)
        $state = @{ Asked = 0; Calls = @() }
        $runner = { param($exe, $argv) $state.Calls += "$argv" }.GetNewClosure()
        $finder = { param($request) $state.Asked++; return $Found }.GetNewClosure()
        Invoke-InTestDir { param($d)
            $null = New-UvProjectEnvironment -Workspace $d -PythonVersion $Version -EnvName '.venv' -CommandRunner $runner -PythonFinder $finder
        }
        $env:UV_PROJECT_ENVIRONMENT = $null
        return [pscustomobject]$state
    }

    It 'installs a version uv cannot find before asking for its GIL build, since uv downloads nothing for +gil' {
        $r = Get-UvCalls -Version '3.12' -Found $false
        Assert-Equal 2 $r.Calls.Count 'install, then venv'
        Assert-Equal 'python install 3.12' $r.Calls[0] 'the bare version, which uv can download'
        Assert-Match '^venv --python 3\.12\+gil --clear ' $r.Calls[1] 'then the GIL request'
    }

    It 'installs nothing when uv finds the interpreter, and never asks for a free-threaded request' {
        $found = Get-UvCalls -Version '3.14' -Found $true
        Assert-Equal 1 $found.Calls.Count 'the venv alone'
        $ft = Get-UvCalls -Version '3.14t' -Found $false
        Assert-Equal "0|venv --python 3.14t" "$($ft.Asked)|$(($ft.Calls[0] -split ' --clear')[0])" 'no find, no install, the request unchanged'
    }
}
