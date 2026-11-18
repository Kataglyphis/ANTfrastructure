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
    $commands = Get-TestScriptCommandMap -ScriptPath $ScriptPath -Name $Name -Order $Name -CountReason 'one selected call to {0}'
    Assert-TestAstCommand -Command @($commands[$Name[$RequiredIndex]]) -Text $Text -Unconditional:$Unconditional
}

function Assert-TestScriptParameterDefault {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Message = '')
    $parameter = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
    Assert-Equal 1 $parameter.Count "one $Name parameter"
    Assert-NotNull $parameter[0].DefaultValue "$Name has a default expression"
    $reason = if ($Message) { $Message } else { "$Name default expression" }
    Assert-Equal $Text $parameter[0].DefaultValue.Extent.Text $reason
}

Export-ModuleMember -Function Assert-TestSequence, Assert-TestRecordedArguments, Assert-TestScriptCallOrder, Assert-TestScriptParameterDefault
