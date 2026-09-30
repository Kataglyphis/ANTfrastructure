#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# CMake exits 0 on an undeclared -D, so the gate reads CMakeCache.txt: undeclared is UNINITIALIZED, declared is typed.

Describe 'Assert-CmakeArgsConsumed' {

    BeforeAll {
        function script:New-FakeCache {
            param([string[]]$Lines)
            $d = Join-Path ([IO.Path]::GetTempPath()) ("cmc-" + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -Path (Join-Path $d 'CMakeCache.txt') -Value $Lines
            $d
        }
    }

    It 'warns when a passed -D came back UNINITIALIZED' {
        $d = New-FakeCache @('USE_QNN:UNINITIALIZED=ON', 'CMAKE_BUILD_TYPE:STRING=Release')
        try {
            $w = @()
            Assert-CmakeArgsConsumed -BuildDir $d -PassedArgs @('-DUSE_QNN=ON') -WarningVariable w -WarningAction SilentlyContinue
            $w.Count | Should -BeGreaterThan 0
            ($w -join ' ') | Should -Match 'USE_QNN'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'stays SILENT when the project actually declared the option' {
        # A real flag must not warn, or the warning gets tuned out.
        $d = New-FakeCache @('USE_QNN:BOOL=ON')
        try {
            $w = @()
            Assert-CmakeArgsConsumed -BuildDir $d -PassedArgs @('-DUSE_QNN=ON') -WarningVariable w -WarningAction SilentlyContinue
            $w.Count | Should -Be 0
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'parses the typed -DNAME:TYPE=value form too' {
        $d = New-FakeCache @('SOME_PATH:UNINITIALIZED=C:/x')
        try {
            $w = @()
            Assert-CmakeArgsConsumed -BuildDir $d -PassedArgs @('-DSOME_PATH:FILEPATH=C:/x') -WarningVariable w -WarningAction SilentlyContinue
            ($w -join ' ') | Should -Match 'SOME_PATH'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not match a name that merely PREFIXES an uninitialised one' {
        $d = New-FakeCache @('USE_QNN_EXTRA:UNINITIALIZED=ON', 'USE_QNN:BOOL=ON')
        try {
            $w = @()
            Assert-CmakeArgsConsumed -BuildDir $d -PassedArgs @('-DUSE_QNN=ON') -WarningVariable w -WarningAction SilentlyContinue
            $w.Count | Should -Be 0 -Because 'USE_QNN is declared; USE_QNN_EXTRA was never passed'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'is a no-op when there is no cache to read' {
        $d = Join-Path ([IO.Path]::GetTempPath()) ("cmc-none-" + [Guid]::NewGuid().ToString('N'))
        { Assert-CmakeArgsConsumed -BuildDir $d -PassedArgs @('-DX=1') } | Should -Not -Throw
    }
}
