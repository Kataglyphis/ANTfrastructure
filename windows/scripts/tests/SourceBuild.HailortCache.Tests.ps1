#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Wiring and cold imports only; real compiler counts, uploads and Hailo device execution require a chain run.
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.CallAssertions.psm1') -ErrorAction Stop -DisableNameChecking
$script:HailortCacheScript = 'windows/scripts/build/Build-HailortFromSource.ps1'

Describe 'Standalone HailoRT compiler-cache lifecycle' {
    It 'owns a fresh session, advanced stderr counters and the shared completion unconditionally (mutation)' {
        foreach ($text in @('Start-SccacheServerSession', 'Write-SccacheStatsToStderr -Advanced -RequireRemote', 'Complete-SccacheServerSession')) {
            $name = ($text -split ' ')[0]
            $commands = @(Get-TestScriptCommands -ScriptPath $script:HailortCacheScript -Name $name)
            Assert-TestAstCommand -Command $commands -Text $text -Unconditional
        }
    }

    It 'includes configure compiles and prints counters before draining and exiting (mutation)' {
        Assert-TestScriptCallOrder -ScriptPath $script:HailortCacheScript `
            -Name @('Start-SccacheServerSession', 'Invoke-CmakeConfigure', 'Invoke-NinjaBuildWithRetry', 'Write-SccacheStatsToStderr', 'Complete-SccacheServerSession', 'Complete-SourceBuild') `
            -Text 'Write-SccacheStatsToStderr -Advanced -RequireRemote' -RequiredIndex 3 -Unconditional
    }

    It 'finds all lifecycle APIs through the existing source-build module in a cold process' {
        $path = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Common.psm1'
        $probe = Test-ColdModuleCommands -ModulePath $path -CommandName @('Start-SccacheServerSession', 'Write-SccacheStatsToStderr', 'Complete-SccacheServerSession')
        Assert-Equal 0 $probe.ExitCode $probe.Output
    }
}
