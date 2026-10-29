#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: other noisy native calls, and values consumed through a variable that holds the function itself.
using namespace System.Management.Automation.Language

Describe 'Ninja output never leaks into a used return value' {
    function Test-VoidCast { param([Ast]$Node) $Node -is [ConvertExpressionAst] -and $Node.Type.TypeName.Name -eq 'void' }

    # $true when an ancestor below $Stop pipes, assigns or voids the node's output.
    function Test-OutputCaptured {
        param([Ast]$Node, [Ast]$Stop)
        [bool](Get-TestAstAncestor -Node $Node -Stop $Stop -First -Predicate {
                param($p) ($p -is [PipelineAst] -and $p.PipelineElements.Count -gt 1) -or $p -is [AssignmentStatementAst] -or (Test-VoidCast $p) })
    }

    # $true when a call site keeps the returned value: assigned, returned, or used as an expression that is not voided.
    function Test-ReturnKept {
        param([CommandAst]$Call)
        $outer = $Call.Parent.Parent
        if ($outer -is [ParenExpressionAst] -or $outer -is [SubExpressionAst]) { return -not (Test-VoidCast $outer.Parent) }
        return $outer -is [AssignmentStatementAst] -or $outer -is [ReturnStatementAst]
    }

    # Starts from the ninja call sites and indexes callers by name once: a scan per function timed out the CI shard.
    function Get-NinjaReturnLeak {
        param([hashtable]$Trees)
        $callers = @{}
        foreach ($call in @($Trees.Values | ForEach-Object { $_.FindAll({ param($n) $n -is [CommandAst] }, $true) })) {
            $name = $call.GetCommandName()
            if ($name) { if (-not $callers.ContainsKey($name)) { $callers[$name] = [System.Collections.Generic.List[object]]::new() }; $callers[$name].Add($call) }
        }
        foreach ($label in ($Trees.Keys | Sort-Object)) {
            foreach ($site in @(Get-TestAstCommands -Ast $Trees[$label] -Name 'Invoke-NinjaBuildWithRetry')) {
                $fn = Get-TestAstAncestor -Node $site -Type ([FunctionDefinitionAst]) -First
                if (-not $fn -or (Test-OutputCaptured -Node $site -Stop $fn)) { continue }
                if (-not $fn.Body.Find({ param($n) $n -is [ReturnStatementAst] -and $n.Pipeline }, $true)) { continue }
                if (@($callers[$fn.Name] | Where-Object { $_ -and (Test-ReturnKept -Call $_) })) { "${label}:$($site.Extent.StartLineNumber): $($fn.Name)" }
            }
        }
    }

    It 'keeps ninja output off every return value a caller uses, and catches a planted leak (mutation)' {
        $trees = @{}
        foreach ($file in (Get-ChildItem (Join-Path (Get-RepoRoot) 'windows\scripts') -Recurse -Include *.ps1, *.psm1 -File | Where-Object FullName -NotMatch '\\tests\\')) {
            $trees[$file.Name] = Get-TestScriptAst -ScriptPath $file.FullName
        }
        $ninjaSites = @($trees.Values | ForEach-Object { Get-TestAstCommands -Ast $_ -Name 'Invoke-NinjaBuildWithRetry' })
        Assert-True ($ninjaSites.Count -ge 10) "graded $($ninjaSites.Count) ninja call sites"
        $found = @(Get-NinjaReturnLeak -Trees $trees)
        Assert-Equal 0 $found.Count "leaks: $($found -join '; ')"

        $planted = ConvertTo-TestScriptAst -Text @'
function Get-Leaky { Invoke-NinjaBuildWithRetry -BuildDir b; return 'C:\x' }
function Get-Piped { Invoke-NinjaBuildWithRetry -BuildDir b | Out-Host; return 'C:\x' }
function Get-Voided { Invoke-NinjaBuildWithRetry -BuildDir b; return 'C:\x' }
function Get-Chooser { return Get-Leaky }
$a = Get-Piped
[void](Get-Voided)
'@
        Assert-Equal 'planted:1: Get-Leaky' "$(Get-NinjaReturnLeak -Trees @{ planted = $planted })" 'only the leak a caller keeps through return'
    }
}
