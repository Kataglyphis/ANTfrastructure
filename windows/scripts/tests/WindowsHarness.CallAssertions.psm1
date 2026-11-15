#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Shared call assertions preserve argument boundaries and source order without claiming runtime execution.

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

function Assert-TestSequence {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected,
        [string]$CountReason = 'sequence item count', [string]$EntryReason = 'sequence entry')
    Assert-Equal $Expected.Count $Actual.Count $CountReason
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Expected[$index] $Actual[$index] "$EntryReason $index"
    }
}

function Assert-TestRecordedArguments {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Calls,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Expected, [int]$ArgumentIndex = 0,
        [scriptblock]$Project = { param($value) $value }, [string]$Reason = 'recorded argument sequence')
    $observed = @(foreach ($call in $Calls) { & $Project $call[$ArgumentIndex] })
    Assert-TestSequence -Actual $observed -Expected $Expected -CountReason "$Reason count" -EntryReason "$Reason at"
}

function Assert-TestScriptCallOrder {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][string]$Text, [int]$RequiredIndex = 0, [switch]$Unconditional)
    if ($RequiredIndex -lt 0 -or $RequiredIndex -ge $Name.Count) { throw 'Required call index is outside the selected sequence.' }
    $ast = Get-TestScriptAst -ScriptPath $ScriptPath
    $commands = @(foreach ($commandName in $Name) {
        $selected = @(Get-TestAstCommands -Ast $ast -Name $commandName)
        Assert-Equal 1 $selected.Count "one selected call to $commandName"
        $selected[0]
    })
    for ($index = 1; $index -lt $commands.Count; $index++) {
        Assert-TestAstOrder -Before $commands[$index - 1] -After $commands[$index]
    }
    Assert-TestAstCommand -Command @($commands[$RequiredIndex]) -Text $Text -Unconditional:$Unconditional
}

Export-ModuleMember -Function Assert-TestSequence, Assert-TestRecordedArguments, Assert-TestScriptCallOrder
