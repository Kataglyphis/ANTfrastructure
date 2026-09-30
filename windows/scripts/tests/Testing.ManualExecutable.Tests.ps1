#requires -Version 7.0
# Callers guard with `if (-not (Invoke-ManualTestExecutable ...))`, so it must return exactly one boolean.

BeforeAll {
    $modDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
    Import-Module (Join-Path $modDir 'WindowsTesting.Common.psm1') -Force -DisableNameChecking

    function New-FakeBuildRoot {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("wtc-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'x.exe') -Value 'x'
        return $dir
    }

    function Assert-ManualTestOutcome {
        param(
            [Parameter(Mandatory)][bool]$Expected,
            [string]$ExecutableName = 'x.exe'
        )
        $root = New-FakeBuildRoot
        try {
            $result = @(Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName $ExecutableName)
            $result.Count | Should -Be 1
            $result[0] | Should -Be $Expected
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# The module resolves Invoke-BuildExternal in its own scope, so only Mock -ModuleName can intercept it.
Describe 'Invoke-ManualTestExecutable' {

    Context 'when the process cannot start (Windows loader/runtime mismatch)' {
        It 'returns exactly one $false instead of throwing' {
            # -1073741515 is STATUS_DLL_NOT_FOUND: an environment problem, not a test failure.
            Mock -ModuleName 'WindowsTesting.Common' Invoke-BuildExternal { throw 'Process exited with exit code -1073741515' }
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            Assert-ManualTestOutcome -Expected $false
        }

        It 'also tolerates STATUS_ENTRYPOINT_NOT_FOUND' {
            Mock -ModuleName 'WindowsTesting.Common' Invoke-BuildExternal { throw 'Process exited with exit code -1073741511' }
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            Assert-ManualTestOutcome -Expected $false
        }
    }

    Context 'when the process runs' {
        It 'returns exactly one $true' {
            Mock -ModuleName 'WindowsTesting.Common' Invoke-BuildExternal { }
            Mock -ModuleName 'WindowsTesting.Common' Write-BuildLogWarning { }

            Assert-ManualTestOutcome -Expected $true
        }
    }

    Context 'when the test itself fails' {
        It 'rethrows anything that is not the loader/runtime mismatch' {
            # A real test failure must reach the caller, or a red suite turns green.
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

            Assert-ManualTestOutcome -Expected $false -ExecutableName 'absent.exe'
        }
    }
}
