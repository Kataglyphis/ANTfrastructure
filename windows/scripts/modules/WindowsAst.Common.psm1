#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Parses source without running it; semantic or runtime errors are outside this helper's scope.

Set-StrictMode -Version Latest

function Get-WindowsAstParseResult {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$ErrorLabel)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        $first = $errors[0]
        throw ("{0} {1}:{2}: {3}" -f $ErrorLabel, $File, $first.Extent.StartLineNumber, $first.Message)
    }
    return [pscustomobject]@{ Ast = $ast; Tokens = @($tokens) }
}

Export-ModuleMember -Function Get-WindowsAstParseResult
