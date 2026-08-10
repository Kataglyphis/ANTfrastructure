# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# AST detectors for pwsh traps that each silently broke a lane of
# probe-build-copy.ps1 until 2026-08-10. Hosted as a module (backlog #21) so
# Invoke-Lint.ps1 runs them inside its existing parse loop (one parse per
# file, \archive\ excluded) and Native.ArgQuoting.Tests.ps1 keeps its
# positive controls against the same implementations.

Set-StrictMode -Version Latest
#requires -Version 7.0

function Get-BarewordCommaAttrViolation {
    # BAREWORD COMMA-ATTRIBUTE NATIVE ARGS: `buildctl --output
    # type=local,dest=$outDir` parses as an ArrayLiteralAst and pwsh hands the
    # native exe the VERBATIM SOURCE TEXT - no variable expansion (measured on
    # pwsh 7.6.4). Fix: double-quote the whole attribute string.
    # Returns "label:line: text" for every ArrayLiteralAst command argument
    # that references a variable (the `key=$var` shape). Plain cmdlet comma
    # lists (`Get-Service *a*,*b*`) contain no `=$` and pass.
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

function Get-SwitchShadowViolation {
    # SWITCH-PARAMETER VARIABLE SHADOWING: variable names are case-insensitive,
    # so `$docker = "...\docker.exe"` inside a script declaring
    # `[switch]$Docker` assigns to the type-constrained parameter variable and
    # throws "Cannot convert ... String to ... SwitchParameter" at runtime.
    # Returns "label:line: text" for every assignment of a (statically)
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
            # -notcontains compares case-insensitively by default - the whole check.
            if ($switchNames -notcontains $name) { continue }
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
    # Plain return (no comma-wrap): see above.
    return $out
}

Export-ModuleMember -Function @(
    'Get-BarewordCommaAttrViolation',
    'Get-SwitchShadowViolation'
)
