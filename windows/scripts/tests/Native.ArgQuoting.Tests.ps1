#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Positive controls for the two AST trap detectors in
# modules\WindowsLint.Common.psm1 (bareword comma-attribute native args +
# [switch] parameter shadowing) - each silently broke a lane of
# probe-build-copy.ps1 until 2026-08-10.
#
# The REPO SWEEP lives in Invoke-Lint.ps1 since 2026-08-10 (backlog #21): the
# lint gate already parses every file once and owns the \archive\ exclusion,
# so this suite only proves the detectors themselves still detect.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsLint.Common.psm1')

function script:Get-ArgQuotingAstFromText {
    param([Parameter(Mandatory)][string]$Text)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "positive-control snippet failed to parse: $($parseErrors[0].Message)" }
    return $ast
}

Describe 'Native.ArgQuoting detector positive controls' {

    It 'catches the probe regression shape: --output type=local,dest=$var' {
        $ast = Get-ArgQuotingAstFromText '& $buildctl build --output type=local,dest=$outDir'
        Assert-Equal 1 @(Get-BarewordCommaAttrViolation -Ast $ast).Count
    }

    It 'accepts the double-quoted attribute string' {
        $ast = Get-ArgQuotingAstFromText '& $buildctl build --output "type=local,dest=$outDir"'
        Assert-Equal 0 @(Get-BarewordCommaAttrViolation -Ast $ast).Count
    }

    It 'ignores legitimate cmdlet comma lists without variables' {
        $ast = Get-ArgQuotingAstFromText 'Get-Service *docker*,*containerd* | Format-Table'
        Assert-Equal 0 @(Get-BarewordCommaAttrViolation -Ast $ast).Count
    }

    It 'catches a string assigned to a same-scope [switch] parameter variable' {
        $ast = Get-ArgQuotingAstFromText "param([switch]`$Docker)`nif (`$Docker) { `$docker = 'C:\bin\docker.exe' }"
        Assert-Equal 1 @(Get-SwitchShadowViolation -Ast $ast).Count
    }

    It 'allows boolean literal toggles of a switch variable' {
        $ast = Get-ArgQuotingAstFromText "param([switch]`$Force)`n`$force = `$true"
        Assert-Equal 0 @(Get-SwitchShadowViolation -Ast $ast).Count
    }

    It 'exempts same-named locals in a different (nested) scope' {
        $ast = Get-ArgQuotingAstFromText "param([switch]`$Force)`nfunction Local-Helper { `$force = 'text' }"
        Assert-Equal 0 @(Get-SwitchShadowViolation -Ast $ast).Count
    }
}
