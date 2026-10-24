#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'Find-LsmEventHolder wait-handle discovery' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/diagnostics/Find-LsmEventHolder.ps1' -FunctionName 'Find-LsmWaitHandle')
    Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSiloProbe.Common.psm1') -ErrorAction Stop -DisableNameChecking
    $script:lsmSilo = [pscustomobject]@{ ProcessId = 200 }
    $script:lsmStackCaptures = 0
    function Get-CdbPath { 'cdb.exe' }
    function Get-SiloWininitId { 100 }
    function Wait-ForNewSilo { $script:lsmSilo }
    function Get-SiloSvchost { [pscustomobject]@{ ProcessId = 300 } }
    function Invoke-SiloDebugger {
        param([string]$LogPath, [string]$Command)
        if ($Command -match 'r r10') { Set-Content -LiteralPath $LogPath -Value 'r10=0000000000000338' }
        else { throw "unexpected debugger command: $Command" }
    }
    function Invoke-SiloStackCapture {
        param([string]$LogPath)
        $script:lsmStackCaptures++
        Set-Content -LiteralPath $LogPath -Value @('1 Id: 0001', 'lsm!CService::Start')
    }

    It 'resolves the stack capture from the production module' {
        $module = Get-Module WindowsSiloProbe.Common
        Assert-NotNull $module
        Assert-True $module.ExportedCommands.ContainsKey('Invoke-SiloStackCapture')
    }

    It 'binds the LSM stack to its thread and reads the waited handle from R10' {
        Invoke-InTestDir {
            param($dir)
            $script:lsmSilo = [pscustomobject]@{ ProcessId = 200 }
            $script:lsmStackCaptures = 0
            $result = Find-LsmWaitHandle -OutDir $dir -WaitForSiloSec 1 -NoBait:$true 6>$null
            Assert-Equal 300 $result.Pid
            Assert-Equal 824 $result.Handle
            Assert-Equal 'cdb.exe' $result.Cdb
            Assert-Equal 1 $script:lsmStackCaptures 'one shared stack capture before reading R10'
        }
    }

    It 'fails when no new silo appeared' {
        Invoke-InTestDir {
            param($dir)
            $script:lsmSilo = $null
            Assert-Throws { Find-LsmWaitHandle -OutDir $dir -WaitForSiloSec 1 -NoBait:$true 6>$null } -MessagePattern 'No new silo appeared'
        }
    }
}
