#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# AST detectors shared by Invoke-Lint.ps1 and their tests: see docs/windows-build-invariants.md § Four more pwsh traps

Set-StrictMode -Version Latest

function Get-BarewordCommaAttrViolation {
    # A bareword `key=$var,...` native argument reaches the exe as unexpanded source text; flags each one.
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
    # No comma-wrap: callers @()-wrap, and a wrapped empty array would count as 1.
    return $out
}

function Get-SwitchShadowViolation {
    # Names are case-insensitive, so `$docker = '...'` beside `[switch]$Docker` throws at runtime; same scope only.
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
            # A nested function gets its own local on assignment, so only the declaring scope counts.
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

# Decides which commands Get-GluedParameterViolation treats as PowerShell.
$script:ApprovedVerbs = @((Get-Verb).Verb) + @('Assert')

function Get-GluedParameterViolation {
    # `-Path$x` and `-Path(...)` parse but misbind; `-Name:$v` passes, and native commands are exempt, as gluing is their syntax.
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$Label = '<text>')
    $out = @()
    $cmds = $Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $cmds) {
        $name = $cmd.GetCommandName()
        if (-not $name -or $name -notmatch '^([A-Za-z]+)-[A-Za-z][A-Za-z0-9]*$') { continue }
        if ($script:ApprovedVerbs -notcontains $Matches[1]) { continue }
        $els = @($cmd.CommandElements)
        for ($i = 0; $i -lt $els.Count; $i++) {
            $el = $els[$i]
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($el.ParameterName -match '\$') {
                $out += "${Label}:$($el.Extent.StartLineNumber): $($el.Extent.Text) (parameter name swallowed a variable -- add the space)"
                continue
            }
            if ($null -eq $el.Argument -and ($i + 1) -lt $els.Count -and $els[$i + 1].Extent.StartOffset -eq $el.Extent.EndOffset) {
                $out += "${Label}:$($el.Extent.StartLineNumber): $($el.Extent.Text)$($els[$i + 1].Extent.Text) (argument glued to the parameter -- add the space)"
            }
        }
    }
    return $out
}

Export-ModuleMember -Function @(
    'Get-BarewordCommaAttrViolation',
    'Get-SwitchShadowViolation',
    'Get-GluedParameterViolation'
)
