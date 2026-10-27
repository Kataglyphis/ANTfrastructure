#requires -Version 7.0
# Checks static formatting call wiring; it does not execute the consumer build.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][ValidateSet('Invoke-CmakeFormatStep', 'Initialize-UvVenvPython')][string]$CommandName,
    [ValidateRange(1, 100)][int]$ExpectedCount = 1,
    [string]$ExpectedProjectPath = 'third_party/ANTfrastructure/quality/cmake-format'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hub = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
Import-Module (Join-Path $hub 'windows/scripts/tests/TestHarness.psm1') -ErrorAction Stop -DisableNameChecking

function Assert-CmakeProjectAssignment {
    param($Ast, $Call, $Arguments)
    if (-not $Arguments.ContainsKey('UvProjectPath') -or $Arguments.ContainsKey('RequirementsPath')) {
        throw 'The formatting call must use UvProjectPath without RequirementsPath.'
    }
    $project = $Arguments['UvProjectPath']
    $workspace = $Arguments['WorkspacePath']
    if ($project -isnot [Management.Automation.Language.VariableExpressionAst] -or
        $workspace -isnot [Management.Automation.Language.VariableExpressionAst]) {
        throw 'UvProjectPath and WorkspacePath must be variables.'
    }
    $assignments = @($Ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ieq $project.VariablePath.UserPath
    }, $true))
    if ($assignments.Count -ne 1 -or $assignments[0].Extent.StartOffset -ge $Call.Extent.StartOffset) {
        throw 'UvProjectPath must have one preceding assignment.'
    }
    $right = $assignments[0].Right
    if ($right -isnot [Management.Automation.Language.PipelineAst] -or $right.PipelineElements.Count -ne 1 -or
        $right.PipelineElements[0] -isnot [Management.Automation.Language.CommandAst]) {
        throw 'UvProjectPath must be assigned by one Join-Path command.'
    }
    $joins = @(Get-TestAstCommands -Ast $right -Name 'Join-Path')
    if ($joins.Count -ne 1) { throw 'UvProjectPath must be assigned by one Join-Path command.' }
    $bound = Get-TestCommandArguments -Command $joins[0] -AsAst
    $base = if ($bound.ContainsKey('Path')) { $bound['Path'] } else { $bound['0'] }
    $child = if ($bound.ContainsKey('ChildPath')) { $bound['ChildPath'] } else { $bound['1'] }
    if ($bound.Count -ne 2 -or $base -isnot [Management.Automation.Language.VariableExpressionAst] -or
        $child -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
        $base.VariablePath.UserPath -ine $workspace.VariablePath.UserPath -or
        $child.Value.Replace('\', '/') -cne $ExpectedProjectPath.Replace('\', '/')) {
        throw 'UvProjectPath must join WorkspacePath with the hub cmake-format project.'
    }
}

$ast = Get-TestScriptAst -ScriptPath $ScriptPath -ErrorLabel 'Consumer formatting script'
$calls = @(Get-TestAstCommands -Ast $ast -Name $CommandName)
if ($calls.Count -ne $ExpectedCount) { throw "Expected $ExpectedCount $CommandName call(s), got $($calls.Count)." }
foreach ($call in $calls) { Assert-CmakeProjectAssignment -Ast $ast -Call $call -Arguments (Get-TestCommandArguments -Command $call -AsAst) }
Write-Host "CMake uv project wiring OK: $ScriptPath"
