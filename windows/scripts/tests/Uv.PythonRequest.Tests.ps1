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

Describe 'Test-UvVenvHealthy' {

    # Whether a venv whose interpreter reports -Actual counts as healthy for -Version.
    function script:Test-FakeVenv {
        param([string]$Version, [string]$Actual)
        $reader = { param($python) $Actual }.GetNewClosure()
        return Invoke-InTestDir { param($d)
            $null = New-Item -ItemType File -Force -Path (Join-Path $d 'Scripts\python.exe')
            Test-UvVenvHealthy -VenvPath $d -PythonVersion $Version -VersionReader $reader
        }
    }

    It 'keeps a venv on the requested X.Y or X.Yt' {
        Assert-True (Test-FakeVenv -Version '3.15' -Actual '3.15') 'X.Y'
        Assert-True (Test-FakeVenv -Version '3.15.0' -Actual '3.15') 'X.Y.Z compares its X.Y'
        Assert-True (Test-FakeVenv -Version '3.15t' -Actual '3.15t') 'X.Yt'
        Assert-True (Test-FakeVenv -Version 'C:\py\python.exe' -Actual '3.12') 'a path checks only that it runs'
    }

    It 'recreates a venv on another interpreter, so a pin bump reaches a reused workspace' {
        Assert-False (Test-FakeVenv -Version '3.15' -Actual '3.12') 'the old default'
        Assert-False (Test-FakeVenv -Version '3.15' -Actual '3.15t') 'the free-threaded twin is not the GIL leg'
        Assert-False (Test-FakeVenv -Version '3.15t' -Actual '3.15') 'nor the other way round'
        Assert-False (Test-FakeVenv -Version '3.15' -Actual '') 'an interpreter that does not run'
    }
}

Describe 'Initialize-UvVenv and Install-UvRequirements' {

    # Every call either function hands its -CommandRunner, as "<exe> <args>".
    $calls = [System.Collections.Generic.List[string]]::new()
    $runner = { param($exe, $argv) $calls.Add("$exe $argv") }.GetNewClosure()

    It 'Initialize-UvVenv creates the venv on the pin when no version is named, never a version literal' {
        $calls.Clear()
        Invoke-WithEnv @{ PYTHON_VERSION = '9.87.6'; UV_PROJECT_ENVIRONMENT = $null } {
            Invoke-InTestDir { param($d) $null = Initialize-UvVenv -Workspace $d -CommandRunner $runner }
        }
        Assert-Equal 'uv python install 9.87' $calls[0] 'uv finds no 9.87, so the pin is installed'
        Assert-Match '^uv venv --python 9\.87\+gil --clear ' $calls[1] 'then the venv on its GIL build'
    }

    It 'Install-UvRequirements installs, then runs the cmake-format lexer fix for Python 3.15 on the same venv' {
        $calls.Clear()
        Install-UvRequirements -VenvPython 'C:\v\Scripts\python.exe' -RequirementsPath 'r.txt' -CommandRunner $runner
        Assert-Equal 2 $calls.Count 'the install and the fix'
        Assert-Equal 'uv pip install --python C:\v\Scripts\python.exe -r r.txt' $calls[0] 'the install'
        Assert-Match '^C:\\v\\Scripts\\python\.exe -I .+\\linux\\scripts\\lib\\cmakelang-py315\.py$' $calls[1] 'the hub''s helper, isolated, on the venv'
    }
}

Describe 'Test-ExperimentalPython (CON91)' {

    It 'defaults to the pin''s X.Yt like python_uv.sh, and EXPERIMENTAL_PYTHON_VERSIONS replaces it' {
        Invoke-WithEnv @{ EXPERIMENTAL_PYTHON_VERSIONS = $null; PYTHON_VERSION = '9.87.6' } {
            Assert-True (Test-ExperimentalPython -Version '9.87t') 'the free-threaded twin of the pin'
            Assert-False (Test-ExperimentalPython -Version '9.87') 'the GIL leg gates'
        }
        Invoke-WithEnv @{ EXPERIMENTAL_PYTHON_VERSIONS = $null; PYTHON_VERSION = $null } {
            $pin = (ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'))['PYTHON_VERSION']
            Assert-True (Test-ExperimentalPython -Version "$(($pin -split '\.')[0..1] -join '.')t") 'versions.env without the image ENV'
        }
        Invoke-WithEnv @{ EXPERIMENTAL_PYTHON_VERSIONS = '3.13, 9.87t'; PYTHON_VERSION = '9.87.6' } {
            Assert-True (Test-ExperimentalPython -Version '3.13') 'the list wins'
        }
    }
}
