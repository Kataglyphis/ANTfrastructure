# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Static repo sweep for two pwsh traps that each silently broke a lane of
# probe-build-copy.ps1 until 2026-08-10 (found while diagnosing a "broken"
# Windows container build on a healthy host):
#
# 1. BAREWORD COMMA-ATTRIBUTE NATIVE ARGS. `buildctl --output
#    type=local,dest=$outDir` parses as an ArrayLiteralAst, and pwsh hands the
#    native exe the VERBATIM SOURCE TEXT - no variable expansion (measured on
#    pwsh 7.6.4: the exe received the literal string `type=local,dest=$outDir`
#    and buildctl exported into a directory named '$outDir'). The fix is to
#    double-quote the whole attribute string.
#
# 2. SWITCH-PARAMETER VARIABLE SHADOWING. Variable names are case-insensitive,
#    so `$docker = "...\docker.exe"` inside a script declaring
#    `[switch]$Docker` assigns to the type-constrained parameter variable and
#    throws "Cannot convert ... String to ... SwitchParameter" at runtime -
#    the probe's docker-classic lane had never executed.
#
# Both sweeps run over every windows/ *.ps1|*.psm1; parse-broken files are the
# lint gate's job and are skipped here.

function script:Get-BarewordCommaAttrViolation {
    # Returns "file:line: text" for every ArrayLiteralAst command argument that
    # references a variable (the `key=$var` shape). Plain cmdlet comma lists
    # (`Get-Service *a*,*b*`) contain no `=$` and pass.
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$Label = '<text>')
    $out = @()
    $cmds = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        foreach ($el in $cmd.CommandElements) {
            if ($el -is [System.Management.Automation.Language.ArrayLiteralAst] -and $el.Extent.Text -match '=\$') {
                $out += "${Label}:$($el.Extent.StartLineNumber): $($el.Extent.Text)"
            }
        }
    }
    # Plain return (no comma-wrap): callers @()-wrap, and a comma-wrapped
    # EMPTY array would arrive as one element containing @() - phantom count 1.
    return $out
}

function script:Get-SwitchShadowViolation {
    # Returns "file:line: text" for every assignment of a (statically)
    # non-boolean value to a variable that is a [switch] parameter of the SAME
    # scope (script top level or the same function - nested functions get
    # their own local on assignment and are exempt).
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$Label = '<text>')
    $out = @()
    $scopes = @($Ast) + @($Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($scope in $scopes) {
        $isFn = $scope -is [System.Management.Automation.Language.FunctionDefinitionAst]
        $paramBlock = if ($isFn) { $scope.Body.ParamBlock } else { $scope.ParamBlock }
        if (-not $paramBlock) { continue }
        $switchNames = @($paramBlock.Parameters |
                Where-Object { $_.StaticType -eq [System.Management.Automation.SwitchParameter] } |
                ForEach-Object { $_.Name.VariablePath.UserPath })
        if ($switchNames.Count -eq 0) { continue }

        foreach ($as in $scope.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if ($as.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $name = $as.Left.VariablePath.UserPath
            $isSwitch = $false
            foreach ($n in $switchNames) {
                if ([string]::Equals($n, $name, [System.StringComparison]::OrdinalIgnoreCase)) { $isSwitch = $true }
            }
            if (-not $isSwitch) { continue }
            # Same-scope only: the nearest enclosing function of the assignment
            # must be the scope that declared the switch.
            $p = $as.Parent; $encl = $null
            while ($null -ne $p) {
                if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $encl = $p; break }
                $p = $p.Parent
            }
            if ($isFn) { if ($encl -ne $scope) { continue } } elseif ($null -ne $encl) { continue }
            # Boolean literals are a legal toggle of a switch variable.
            if ($as.Right.Extent.Text -match '^\$(true|false)$') { continue }
            $out += "${Label}:$($as.Extent.StartLineNumber): $($as.Extent.Text)"
        }
    }
    # Plain return (no comma-wrap): callers @()-wrap, and a comma-wrapped
    # EMPTY array would arrive as one element containing @() - phantom count 1.
    return $out
}

function script:Get-ArgQuotingAstFromText {
    param([Parameter(Mandatory)][string]$Text)
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { throw "positive-control snippet failed to parse: $($parseErrors[0].Message)" }
    return $ast
}

# --- repo sweep, computed once at dot-source time --------------------------
$script:argQuotingRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent  # windows/
$script:argQuotingCommaViolations = @()
$script:argQuotingShadowViolations = @()
foreach ($argQuotingFile in @(Get-ChildItem -Path $script:argQuotingRoot -Recurse -Include '*.ps1', '*.psm1' -File)) {
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($argQuotingFile.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) { continue } # lint gate owns parse failures
    $rel = $argQuotingFile.FullName.Substring($script:argQuotingRoot.Length).TrimStart('\', '/')
    $script:argQuotingCommaViolations += @(Get-BarewordCommaAttrViolation -Ast $ast -Label $rel)
    $script:argQuotingShadowViolations += @(Get-SwitchShadowViolation -Ast $ast -Label $rel)
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

Describe 'Native.ArgQuoting repo sweep (windows/ *.ps1, *.psm1)' {

    It 'no bareword comma-attribute native argument references a variable' {
        Assert-Equal 0 $script:argQuotingCommaViolations.Count `
            ("quote the whole attribute string: " + ($script:argQuotingCommaViolations -join ' | '))
    }

    It 'no [switch] parameter variable is assigned a non-boolean value in its own scope' {
        Assert-Equal 0 $script:argQuotingShadowViolations.Count `
            ("rename the local variable: " + ($script:argQuotingShadowViolations -join ' | '))
    }
}
