#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The parsed copy loop proves module transport, not Windows archive creation or ARM64 execution.

Describe 'ARM64 exported module transport' {
    It 'imports the modules copied by the real export loop in a cold session' {
        Invoke-InTestDir { param($dir)
            $export = Join-Path (Get-RepoRoot) 'windows/scripts/build/Export-Arm64Bundle.ps1'
            $loop = Get-TestSourceCopyLoopText -ScriptPath $export -LoopVariable module
            Copy-TestModuleClosure -Seed WindowsGstPlugins.Common, WindowsPythonWheel.Common, WindowsOrtDmlCheck.Common, WindowsArm64Acceptance.Common -Destination (Join-Path $dir 'modules')
            $stage = Invoke-TestSourceCopyLoop -Loop $loop -Root $dir -Files @{ 'fixture.txt' = 'isolated source root' } -SourceVariableName PSScriptRoot -DestinationVariableName OutDir
            $result = Test-ColdModuleCommands -ModulePath (Join-Path $stage 'WindowsGstPlugins.Common.psm1') -CommandName Assert-GstOnnxInferenceRun, Assert-GstWebRtcLoopback
            Assert-Equal 0 $result.ExitCode $result.Output
            $acceptance = Test-ColdModuleCommands -ModulePath (Join-Path $stage 'WindowsArm64Acceptance.Common.psm1') -CommandName Read-Arm64AcceptanceBundle, Invoke-Arm64AcceptanceGate
            Assert-Equal 0 $acceptance.ExitCode $acceptance.Output
        }
    }
}
