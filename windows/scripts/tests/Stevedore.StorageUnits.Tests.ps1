#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Unit arithmetic, AST wiring and fake native argv only; host capacity, privilege delegation and real daemon effects need receipts.

Describe 'Stevedore cleanup unit boundary without Pester' {
    It 'converts GiB to rounded-up decimal MB without int32 overflow (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Clear-DiskSpace.ps1' -FunctionName 'Get-BuildkitFreeTargetMB')
        foreach ($case in @(@(0, 0), @(1, 1074), @(100, 107375), @(240, 257699), @(2097151, 2251798740))) {
            $actual = Get-BuildkitFreeTargetMB -GiB $case[0]
            Assert-Equal $case[1] $actual
            Assert-True ($actual -is [long])
            Assert-True ([decimal]$actual * 1000000 -ge [decimal]$case[0] * 1GB)
            Assert-True (([decimal]$actual * 1000000 - [decimal]$case[0] * 1GB) -lt 1000000)
        }
    }

    It 'uses the shared conversion in advice and both daemon paths (mutation)' {
        $commands = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/host/Clear-DiskSpace.ps1' -Name 'Get-BuildkitFreeTargetMB')
        Assert-Equal 3 $commands.Count
        Assert-Equal 'Get-BuildkitFreeTargetMB -GiB $KeepGB|Get-BuildkitFreeTargetMB -GiB $KeepGB|Get-BuildkitFreeTargetMB -GiB $TargetGB' (($commands | ForEach-Object { $_.Extent.Text }) -join '|')
    }

    It 'passes exact decimal MB and retains a native prune failure (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Clear-DiskSpace.ps1' -FunctionName 'Get-BuildkitFreeTargetMB','Invoke-StevedoreRegularPrune')
        $state=New-TestCallState @{Code=0}
        Invoke-WithTestNativeCommand -Name Invoke-UnitBoundaryDaemon -FixtureState $state -Implementation { } -Body {
            param($record)
            Invoke-StevedoreRegularPrune -Buildctl Invoke-UnitBoundaryDaemon -Address 'npipe://fixture with space' -TargetGB 100
            Assert-Equal '--addr|npipe://fixture with space|prune|--filter|type==regular|--free-storage|107375' ($record.Calls[0] -join '|')
            $record.Code=7
            Assert-Throws { Invoke-StevedoreRegularPrune -Buildctl Invoke-UnitBoundaryDaemon -Address 'npipe://fixture with space' -TargetGB 100 } -MessagePattern 'prune failed'
            Assert-Equal 2 $record.Calls.Count
        }
    }
}
