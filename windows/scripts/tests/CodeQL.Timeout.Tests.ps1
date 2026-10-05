#requires -Version 7.0
# The watchdog that bounds every CodeQL phase: a hung extractor once cost a night with 8 s of CPU (2026-10-05).
Describe 'Invoke-CodeQLProcess' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsCodeQL.Common.psm1') -Force
    }

    It 'returns the exit code of a process that finishes in time' {
        Invoke-CodeQLProcess -CodeQLExe 'cmd' -Arguments @('/c', 'exit', '7') -Phase 'test' -TimeoutMinutes 1 | Should -Be 7
    }

    It 'kills the process tree and throws when the budget runs out' {
        { Invoke-CodeQLProcess -CodeQLExe 'pwsh' -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -Phase 'test' -TimeoutMinutes 0 } |
            Should -Throw '*did not finish within 0 min*'
    }
}
