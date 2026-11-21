#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: a real linker's output; a consumer's Windows lane runs Assert-PeHardening over its own binaries.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPeHardening.Common.psm1') -Force -DisableNameChecking

Describe 'Assert-PeHardening' {

    It 'reads each DllCharacteristics bit, and passes a PE32+ with ASLR, high-entropy ASLR, DEP and CFG' {
        Invoke-InTestDir { param($d)
            $exe = Join-Path $d 'app.exe'
            New-OrtTestPe -Path $exe -DllCharacteristics 0x4160
            $pe = Get-PeHardening -Path $exe
            Assert-Equal 'True|True|True|True|True' "$($pe.Pe32Plus)|$($pe.DynamicBase)|$($pe.HighEntropyVa)|$($pe.NxCompat)|$($pe.GuardCf)"
            Assert-PeHardening -Path $exe
        }
    }

    # BeschleunigerBallett compiled with /guard:cf but linked without it (CON290): the CFG bit is what tells.
    It 'names every file and every bit it lacks, and -NoCfg waives the CFG bit alone' {
        Invoke-InTestDir { param($d)
            $vendor = Join-Path $d 'vendor.dll'
            New-OrtTestPe -Path $vendor -DllCharacteristics 0x0160
            $bare = Join-Path $d 'bare.exe'
            New-OrtTestPe -Path $bare -DllCharacteristics 0
            Assert-Throws { Assert-PeHardening -Path $vendor, $bare } -MessagePattern '^PE hardening: 2 file\(s\) fall short'
            Assert-Throws { Assert-PeHardening -Path $bare } -MessagePattern 'bare\.exe lacks DYNAMIC_BASE, NX_COMPAT, HIGH_ENTROPY_VA, GUARD_CF$'
            Assert-Throws { Assert-PeHardening -Path $vendor } -MessagePattern 'vendor\.dll lacks GUARD_CF$'
            Assert-PeHardening -Path $vendor -NoCfg 'vendor.dll'
            Assert-Throws { Assert-PeHardening -Path $bare -NoCfg 'bare.exe' } -MessagePattern 'bare\.exe lacks DYNAMIC_BASE, NX_COMPAT, HIGH_ENTROPY_VA$'
        }
    }

    It 'refuses a file that is not a PE instead of passing it' {
        Invoke-InTestDir { param($d)
            $text = Join-Path $d 'notes.txt'
            Set-Content -LiteralPath $text -Value ('not a portable executable; ' * 4) -Encoding ascii
            Assert-Throws { Assert-PeHardening -Path $text } -MessagePattern 'Get-PeHardening: .*notes\.txt is not a PE file'
        }
    }
}
