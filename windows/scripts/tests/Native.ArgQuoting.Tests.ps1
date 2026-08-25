#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Positive controls for the three AST trap detectors in
# modules\WindowsLint.Common.psm1 (bareword comma-attribute native args +
# [switch] parameter shadowing - each silently broke a lane of
# probe-build-copy.ps1 until 2026-08-10 - and glued parameter tokens, which
# broke the arm64 target-cpython stage on 2026-08-25).
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

    # Glued parameter tokens (2026-08-25): four `-Path$x` calls survived a
    # refactor, the parse gate and the whole suite, then died 90 s into the
    # arm64 regression with "parameter name 'Path$staged'".
    It 'catches a variable glued to a parameter name (-Path$x)' {
        $ast = Get-ArgQuotingAstFromText 'Get-PeFileMachine -Path$staged.FullName'
        Assert-Equal 1 @(Get-GluedParameterViolation -Ast $ast).Count
    }

    It 'catches a paren expression glued to a parameter (-Path(...))' {
        $ast = Get-ArgQuotingAstFromText "Get-PeFileMachine -Path(Join-Path `$dir 'vcruntime140.dll')"
        Assert-Equal 1 @(Get-GluedParameterViolation -Ast $ast).Count
    }

    It 'accepts the spaced and the colon forms' {
        $ast = Get-ArgQuotingAstFromText "Get-PeFileMachine -Path `$staged.FullName; Get-Item -Path:`$p; Get-ChildItem -Filter '*.lib' -File; & git -C `$wt diff"
        Assert-Equal 0 @(Get-GluedParameterViolation -Ast $ast).Count
    }

    It 'exempts native tools, where a glued token is the syntax (-Fo<file>, -I<dir>)' {
        $ast = Get-ArgQuotingAstFromText "clang-cl -nologo -c -Fotiny3.o tiny.c; & `$sccache clang-cl -I`$inc -DFOO=1 x.c; nasm -fwin64 -o`$out x.asm"
        Assert-Equal 0 @(Get-GluedParameterViolation -Ast $ast).Count
    }

    It 'still catches the repo Assert-* family (not an approved verb, allowlisted on purpose)' {
        $ast = Get-ArgQuotingAstFromText 'Assert-PeTargetMachine -Path$dll -Arch arm64'
        Assert-Equal 1 @(Get-GluedParameterViolation -Ast $ast).Count
    }
}
