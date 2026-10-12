#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Hub #180: a clang-cl relinked without /Brepro changes its bytes, and sccache then misses every media compile.

Describe 'Build-LlvmFromSource: a reproducible clang-cl (hub #180)' {

    BeforeAll {
        $script:scriptPath = Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-LlvmFromSource.ps1'
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-LlvmFromSource.ps1' -FunctionName 'Get-PeTimeDateStamp', 'Assert-ReproducibleLink')
        $script:scriptText = [IO.File]::ReadAllText($script:scriptPath)
        # The harness's minimal PE puts 'PE' at 0x40, so its six tag bytes end where the COFF stamp sits (0x48).
        function New-StampedPe([string]$Path, [uint32]$Stamp) {
            New-TestPeFile -Path $Path -Tag 'stamp!'
            $bytes = [IO.File]::ReadAllBytes($Path)
            [BitConverter]::GetBytes($Stamp).CopyTo($bytes, 0x48)
            [IO.File]::WriteAllBytes($Path, $bytes)
        }
    }

    It 'reads the COFF TimeDateStamp and refuses a file that is no PE' {
        Invoke-InTestDir { param($d)
            New-StampedPe -Path "$d\a.exe" -Stamp 0x6ACBBE2C
            Assert-Equal ([uint32]0x6ACBBE2C) (Get-PeTimeDateStamp -Path "$d\a.exe") 'the stamp bytes'
            Set-Content -LiteralPath "$d\b.exe" -Value 'not a PE'
            Assert-Throws { Get-PeTimeDateStamp -Path "$d\b.exe" } -MessagePattern 'is not a PE file'
        }
    }

    It 'fails a link-time stamp and passes a /Brepro content hash (mutation)' {
        Invoke-InTestDir { param($d)
            $now = [DateTimeOffset]::FromUnixTimeSeconds(0x6ACBC000)
            # bk-20261011-184301's clang-cl: linked 16:49:48Z, checked minutes later.
            New-StampedPe -Path "$d\linked.exe" -Stamp 0x6ACBBE2C
            Assert-Throws { Assert-ReproducibleLink -Path "$d\linked.exe" -Now $now } -MessagePattern 'link-time PE stamp \(0x6ACBBE2C\).*hub #180'
            New-StampedPe -Path "$d\brepro.exe" -Stamp 0x1F3A9C47
            Assert-ReproducibleLink -Path "$d\brepro.exe" -Now $now
        }
    }

    It 'builds LLVM with the base image''s pinned clang-cl, never CMake''s default cl, and checks the result' {
        Assert-Match "\`$bootstrapClangCl = Join-Path `"\`$env:LLVM_USER_BIN`" 'clang-cl\.exe'" $script:scriptText 'the pinned scoop LLVM'
        Assert-Match "refusing CMake's default MSVC cl" $script:scriptText 'no silent fallback to cl'
        Assert-Match "`"-DCMAKE_C_COMPILER=\`$bootstrapClangCl`",\s*\r?\n\s*`"-DCMAKE_CXX_COMPILER=\`$bootstrapClangCl`"" $script:scriptText 'both languages'
        Assert-Match "Assert-ReproducibleLink -Path \`$clangCl" $script:scriptText 'the installed clang-cl is checked'
        Assert-False ($script:scriptText -match '-DLLVM_ENABLE_LTO') 'LLVM drops /Brepro under LTO'
    }
}
