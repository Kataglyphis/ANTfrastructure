#requires -Version 7.0
# Pester-style companion to Testing.Asan.Tests.ps1, covering the one part of
# WindowsTesting.Common that needs the process-launcher stubbed out:
# Invoke-ManualTestExecutable's three-way outcome.
#
# Ported from BeschleunigerBallett's scripts/windows/tests copy when
# the module was upstreamed (2026-08-11). The original stubbed the launcher with
# `function global:Invoke-BuildExternal`, which worked only because the vendored
# module declared no imports and picked the command up from the caller's global
# scope. The upstream module imports WindowsBuild.Common like every other module
# here, so the command now resolves in the module's OWN scope and a global
# function cannot shadow it — hence `Mock -ModuleName`, which is the supported
# way to intercept a call as seen from inside a module.
#
# What is being pinned: the caller-side guard in a build script is
# `if (-not (Invoke-ManualTestExecutable ...)) { ... }`, so the return value must
# be exactly ONE boolean. It has leaked extra pipeline objects before, which
# makes the guard test an array and silently take the wrong branch.

BeforeAll {
    $modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
    Import-Module (Join-Path $modDir 'WindowsTesting.Common.psm1') -Force -DisableNameChecking

    function New-FakeBuildRoot {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("wtc-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'x.exe') -Value 'x'
        return $dir
    }
}

Describe 'Invoke-ManualTestExecutable' {

    Context 'when the process cannot start (Windows loader/runtime mismatch)' {
        It 'returns exactly one $false instead of throwing' {
            # -1073741515 is STATUS_DLL_NOT_FOUND: an environment problem, not a
            # test failure. Failing the pipeline on it would bury the results of
            # every test that DID run.
            Mock -ModuleName 'WindowsTesting.Common' Invoke-BuildExternal { throw 'Process exited with exit code -1073741515' }
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            $root = New-FakeBuildRoot
            try {
                $result = @(Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName 'x.exe')
                $result.Count | Should -Be 1
                $result[0] | Should -Be $false
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'also tolerates STATUS_ENTRYPOINT_NOT_FOUND' {
            Mock -ModuleName 'WindowsTesting.Common' Invoke-BuildExternal { throw 'Process exited with exit code -1073741511' }
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            $root = New-FakeBuildRoot
            try {
                $result = @(Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName 'x.exe')
                $result.Count | Should -Be 1
                $result[0] | Should -Be $false
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'when the process runs' {
        It 'returns exactly one $true' {
            Mock -ModuleName 'WindowsTesting.Common' Invoke-BuildExternal { }
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            $root = New-FakeBuildRoot
            try {
                $result = @(Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName 'x.exe')
                $result.Count | Should -Be 1
                $result[0] | Should -Be $true
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'when the test itself fails' {
        It 'rethrows anything that is not the loader/runtime mismatch' {
            # A real test failure MUST reach the caller. Swallowing every
            # exception is the obvious over-generalisation of the guard above,
            # and it would turn a red suite green.
            Mock -ModuleName 'WindowsTesting.Common' Invoke-BuildExternal { throw 'Process exited with exit code 1' }
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            $root = New-FakeBuildRoot
            try {
                { Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName 'x.exe' } |
                    Should -Throw
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'when the executable does not exist' {
        It 'warns and returns $false rather than searching forever' {
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            $root = New-FakeBuildRoot
            try {
                $result = @(Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName 'absent.exe')
                $result.Count | Should -Be 1
                $result[0] | Should -Be $false
            } finally {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
