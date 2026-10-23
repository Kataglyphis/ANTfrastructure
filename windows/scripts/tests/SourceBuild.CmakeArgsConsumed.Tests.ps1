#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# CMake exits 0 on an undeclared -D, so the gate reads CMakeCache.txt: undeclared is UNINITIALIZED, declared is typed.

Describe 'Assert-CmakeArgsConsumed' {

    BeforeAll {
        function script:Get-CmakeFixtureWarning {
            param([string[]]$Lines, [string[]]$PassedArgs)
            Invoke-InTestDir {
                param($directory)
                Write-TestFileTree -Root $directory -Files @{ 'CMakeCache.txt' = $Lines -join "`n" }
                $warnings = @()
                Assert-CmakeArgsConsumed -BuildDir $directory -PassedArgs $PassedArgs -WarningVariable warnings -WarningAction SilentlyContinue
                $warnings
            }.GetNewClosure()
        }
    }

    It 'warns when a passed -D came back UNINITIALIZED' {
        $warnings = @(Get-CmakeFixtureWarning -Lines 'USE_QNN:UNINITIALIZED=ON', 'CMAKE_BUILD_TYPE:STRING=Release' -PassedArgs '-DUSE_QNN=ON')
        $warnings.Count | Should -BeGreaterThan 0
        ($warnings -join ' ') | Should -Match 'USE_QNN'
    }

    It 'stays SILENT when the project actually declared the option' {
        # A real flag must not warn, or the warning gets tuned out.
        @(Get-CmakeFixtureWarning -Lines 'USE_QNN:BOOL=ON' -PassedArgs '-DUSE_QNN=ON').Count | Should -Be 0
    }

    It 'parses the typed -DNAME:TYPE=value form too' {
        $warnings = @(Get-CmakeFixtureWarning -Lines 'SOME_PATH:UNINITIALIZED=C:/x' -PassedArgs '-DSOME_PATH:FILEPATH=C:/x')
        ($warnings -join ' ') | Should -Match 'SOME_PATH'
    }

    It 'does not match a name that merely PREFIXES an uninitialised one' {
        @(Get-CmakeFixtureWarning -Lines 'USE_QNN_EXTRA:UNINITIALIZED=ON', 'USE_QNN:BOOL=ON' -PassedArgs '-DUSE_QNN=ON').Count |
            Should -Be 0 -Because 'USE_QNN is declared; USE_QNN_EXTRA was never passed'
    }

    It 'is a no-op when there is no cache to read' {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("cmc-none-" + [Guid]::NewGuid().ToString('N'))
        { Assert-CmakeArgsConsumed -BuildDir $d -PassedArgs @('-DX=1') } | Should -Not -Throw
    }
}
