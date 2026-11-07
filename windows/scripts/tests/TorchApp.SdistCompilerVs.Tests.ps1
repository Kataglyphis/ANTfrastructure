#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Runs a real VsDevCmd stand-in through cmd.exe, so it holds only on Windows; the portable cases are TorchApp.SdistCompiler's.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSdistCompiler.Common.psm1') -Force -DisableNameChecking

Describe 'Get-ClangClSdistVsLib through cmd.exe' {
    It 'reads LIB from VsDevCmd, whose own output it ignores' {
        Invoke-InTestDir { param($d)
            $bat = Join-Path $d 'VsDevCmd.bat'
            Set-Content -LiteralPath $bat -Value @('@echo banner', '@set "LIB=C:\vs\lib;C:\sdk\lib"')
            Invoke-WithEnv @{ LIB = $null } {
                Assert-Equal 'C:\vs\lib;C:\sdk\lib' (Get-ClangClSdistVsLib -VsDevCmdPattern $bat)
            }
        }
    }

    It 'throws without VS, and when VsDevCmd sets no LIB' {
        Invoke-InTestDir { param($d)
            $bat = Join-Path $d 'VsDevCmd.bat'
            Set-Content -LiteralPath $bat -Value '@echo banner'
            Invoke-WithEnv @{ LIB = $null } {
                Assert-Throws { Get-ClangClSdistVsLib -VsDevCmdPattern (Join-Path $d 'none.bat') } -MessagePattern 'needs LIB or a VsDevCmd'
                Assert-Throws { Get-ClangClSdistVsLib -VsDevCmdPattern $bat } -MessagePattern 'set no LIB'
            }
        }
    }
}
