#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# AST detectors shared by Invoke-Lint.ps1 and their tests: see docs/windows-build-invariants.md § Four more pwsh traps

Set-StrictMode -Version Latest

function Format-LintViolation {
    param([System.Management.Automation.Language.Ast]$Node, [string]$Label, [string]$Suffix = '')
    return "${Label}:$($Node.Extent.StartLineNumber): $($Node.Extent.Text)$Suffix"
}

function Invoke-LintCommandElementRule {
    param([System.Management.Automation.Language.Ast]$Ast, [string]$Label, [scriptblock]$Rule, [switch]$PowerShellOnly)
    foreach ($command in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($PowerShellOnly) {
            $name = $command.GetCommandName()
            if (-not $name -or $name -notmatch '^([A-Za-z]+)-[A-Za-z][A-Za-z0-9]*$') { continue }
            if ($script:ApprovedVerbs -notcontains $Matches[1]) { continue }
        }
        $elements = @($command.CommandElements)
        for ($index = 0; $index -lt $elements.Count; $index++) {
            $next = if (($index + 1) -lt $elements.Count) { $elements[$index + 1] } else { $null }
            & $Rule $elements[$index] $next $Label
        }
    }
}

function Get-BarewordCommaAttrViolation {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$Label = '<text>')
    Invoke-LintCommandElementRule -Ast $Ast -Label $Label -Rule {
        param($element, $next, $sourceLabel)
        if ($element -is [System.Management.Automation.Language.ArrayLiteralAst] -and $element.Extent.Text -match '=\$') {
            Format-LintViolation -Node $element -Label $sourceLabel
        }
    }
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
            $out += Format-LintViolation -Node $as -Label $Label
        }
    }
    # Plain return (no comma-wrap): see above.
    return $out
}

# Decides which commands Get-GluedParameterViolation treats as PowerShell.
$script:ApprovedVerbs = @((Get-Verb).Verb) + @('Assert')

function Get-GluedParameterViolation {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$Label = '<text>')
    Invoke-LintCommandElementRule -Ast $Ast -Label $Label -PowerShellOnly -Rule {
        param($element, $next, $sourceLabel)
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { return }
        if ($element.ParameterName -match '\$') {
            Format-LintViolation -Node $element -Label $sourceLabel -Suffix ' (parameter name swallowed a variable -- add the space)'
            return
        }
        if ($null -eq $element.Argument -and $null -ne $next -and $next.Extent.StartOffset -eq $element.Extent.EndOffset) {
            Format-LintViolation -Node $element -Label $sourceLabel -Suffix "$($next.Extent.Text) (argument glued to the parameter -- add the space)"
        }
    }
}

function Get-UndeclaredParameterViolation {
    # Calls into the same file only: an imported command's parameters are not visible to the parser.
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$Label = '<text>')
    $script:DeclaredParameters = @{}
    foreach ($fn in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $block = if ($fn.Body.ParamBlock) { $fn.Body.ParamBlock.Parameters } else { $fn.Parameters }
        $script:DeclaredParameters[$fn.Name] = @($block | Where-Object { $_ } | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    Invoke-LintCommandElementRule -Ast $Ast -Label $Label -Rule {
        param($element, $next, $sourceLabel)
        $owner = if ($element -is [System.Management.Automation.Language.CommandParameterAst]) { $element.Parent.GetCommandName() }
        if ($owner -and $script:DeclaredParameters.ContainsKey($owner) -and
            -not @($script:DeclaredParameters[$owner] | Where-Object { $_ -like "$($element.ParameterName)*" })) {
            Format-LintViolation -Node $element -Label $sourceLabel -Suffix " (no such parameter on $owner)"
        }
    }
}

$script:AutomaticVariables = @('null', 'true', 'false', '_', 'PSItem', 'args', 'Matches', 'LASTEXITCODE', 'input', 'this', 'Error')

function Get-LintEnclosingScope {
    param([System.Management.Automation.Language.Ast]$Node)
    $scope = $Node.Parent
    while ($scope -and $scope -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $scope = $scope.Parent }
    return $scope
}

function Get-ScriptBlockScopeLeakViolation {
    # A scriptblock argument runs in a child scope unless the command dot-sources it, as ForEach-Object and Where-Object do.
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [string]$Label = '<text>')
    $lang = 'System.Management.Automation.Language'
    $dotSourcing = @('ForEach-Object', '%', 'foreach', 'Where-Object', '?', 'where')
    foreach ($command in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($dotSourcing -contains $command.GetCommandName() -or $command.InvocationOperator -eq 'Dot') { continue }
        $blocks = @($command.CommandElements | Where-Object { $_ -is "$lang.ScriptBlockExpressionAst" })
        if (-not $blocks) { continue }
        $scope = Get-LintEnclosingScope $command
        $assignedInScope = @($scope.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                Where-Object { $_.Extent.StartOffset -lt $command.Extent.StartOffset -or $_.Extent.StartOffset -gt $command.Extent.EndOffset } |
                ForEach-Object { $_.Left } | Where-Object { $_ -is "$lang.VariableExpressionAst" } | ForEach-Object { $_.VariablePath.UserPath })
        $leaked = @($blocks | ForEach-Object { $_.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) } |
                ForEach-Object { $_.Left } | Where-Object { $_ -is "$lang.VariableExpressionAst" -and $_.VariablePath.IsUnscopedVariable } |
                ForEach-Object { $_.VariablePath.UserPath } | Where-Object { $assignedInScope -notcontains $_ -and $script:AutomaticVariables -notcontains $_ } | Sort-Object -Unique)
        if (-not $leaked) { continue }
        $scope.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
            Where-Object { $_.Extent.StartOffset -gt $command.Extent.EndOffset -and $leaked -contains $_.VariablePath.UserPath -and
                $_.Parent -isnot "$lang.ParameterAst" -and (Get-LintEnclosingScope $_) -eq $scope } |
            ForEach-Object { Format-LintViolation -Node $_ -Label $Label -Suffix " (assigned only inside the scriptblock passed to $($command.GetCommandName()))" }
    }
}

Export-ModuleMember -Function @(
    'Get-BarewordCommaAttrViolation',
    'Get-SwitchShadowViolation',
    'Get-GluedParameterViolation',
    'Get-UndeclaredParameterViolation',
    'Get-ScriptBlockScopeLeakViolation'
)
