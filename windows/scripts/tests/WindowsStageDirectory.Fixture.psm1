#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# This checks reset wiring and filesystem effects; it does not build or run staged payloads.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

function Assert-StageResetBeforeCopy {
    param([Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ResetCommand,
        [Parameter(Mandatory)][string]$PathArgument)
    $resets = @(Get-TestScriptCommands -ScriptPath $ScriptPath -Name $ResetCommand)
    Assert-TestAstCommand -Command $resets -Text "$ResetCommand -Path $PathArgument -Empty"
    $copies = @(Get-TestScriptCommands -ScriptPath $ScriptPath -Name 'Copy-Item' | Sort-Object { $_.Extent.StartOffset })
    Assert-True ($copies.Count -gt 0) "$ScriptPath must copy staged payloads"
    Assert-True ($resets[0].Extent.StartOffset -lt $copies[0].Extent.StartOffset) 'reset must precede the first copy'
}

function Assert-StageDirectoryCleared {
    param([Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][scriptblock]$RunReset)
    $root = Join-Path $TestRoot 'stage'
    $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
    $stale = Join-Path $root 'stale.txt'
    [IO.File]::WriteAllText($stale, 'old')
    $null = & $RunReset $root
    Assert-True (Test-Path -LiteralPath $root -PathType Container) 'reset must leave a directory'
    Assert-False (Test-Path -LiteralPath $stale) 'reset must remove stale bytes'
}

function Assert-StageDirectoryAllocationFailure {
    param([Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][scriptblock]$RunReset)
    $target = Join-Path $TestRoot 'invalid<stage>'
    $message = try { $null = & $RunReset $target; '' } catch { $_.Exception.Message }
    Assert-False ([string]::IsNullOrWhiteSpace($message)) 'failed allocation must throw'
    Assert-False (Test-Path -LiteralPath $target) 'failed allocation must leave no stage root'
}

Export-ModuleMember -Function Assert-StageResetBeforeCopy, Assert-StageDirectoryCleared, Assert-StageDirectoryAllocationFailure
