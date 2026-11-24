#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Structural cache lifecycle checks do not prove compiler hits, upload completion or flushed log bytes.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.CallAssertions.psm1') -ErrorAction Stop

Describe 'OpenCV GStreamer plugin cache lifecycle' {
    $script:pluginScript = 'windows/scripts/build/Build-OpencvGstreamerPlugin.ps1'

    It 'reports component counters and completes the server unconditionally before source removal' {
        $sequence = @('Write-SccacheStats', 'Complete-SccacheServerSession', 'Remove-Item')
        $expected = @("Write-SccacheStats -Label 'opencv-gstreamer-plugin'", 'Complete-SccacheServerSession')
        foreach ($required in 0..1) {
            Assert-TestScriptCallOrder -ScriptPath $script:pluginScript -Name $sequence `
                -Text $expected[$required] -RequiredIndex $required -Unconditional
        }
    }

    It 'preserves the preceding GStreamer log instead of starting a truncating session' {
        $ast = Get-TestScriptAst -ScriptPath $script:pluginScript
        Assert-Equal 0 @(Get-TestAstCommands -Ast $ast -Name 'Start-SccacheServerSession').Count 'no truncating session start'
    }
}
