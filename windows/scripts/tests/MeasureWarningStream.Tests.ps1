#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Measure-WarningStream' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Measure-WarningStream.ps1' -FunctionName 'Get-WarningStreamCounts')

    It 'streams clang and MSVC warnings, retaining compact signal evidence' {
        Invoke-InTestDir -Body {
            param($dir)
            $log = Join-Path $dir 'build.log'
            Set-Content -LiteralPath $log -Value @(
                '#1 1.0 src.cpp(1): warning: unused [-Wunused-parameter]'
                '#2 2.0 src.cpp(2): warning C4715: not all paths return'
                '#3 3.0 src.cpp(3): warning: mismatch [-Winconsistent-dllimport]'
                '#4 4.0 finished'
            )
            $counts = Get-WarningStreamCounts -Path $log -SignalClasses @{ C4715 = 'return'; '-Winconsistent-dllimport' = 'link' }
            Assert-Equal 3 $counts.TotalWarnings
            Assert-Equal 3 $counts.Counts.Count
            Assert-Equal 1 $counts.Counts['-Wunused-parameter']
            Assert-Equal 2 $counts.SignalHits.Count
            Assert-Match '^src.cpp\(2\): warning C4715:' $counts.SignalHits[0]
            Assert-Match '^src.cpp\(3\): warning:' $counts.SignalHits[1]
        }
    }

    It 'prints the same counts through the command line' {
        Invoke-InTestDir -Body {
            param($dir)
            $log = Join-Path $dir 'build.log'
            Set-Content -LiteralPath $log -Value @('src.cpp(1): warning C4715: missing return')
            $scriptPath = Join-Path (Get-RepoRoot) 'windows/scripts/diagnostics/Measure-WarningStream.ps1'
            $lines = @(& pwsh -NoProfile -File $scriptPath -LogPath $log | ForEach-Object { "$_" })
            Assert-Equal 0 $LASTEXITCODE
            Assert-Match 'total warnings: 1  distinct classes: 1' ($lines -join "`n")
            Assert-Match 'first signal occurrences' ($lines -join "`n")
        }
    }
}
