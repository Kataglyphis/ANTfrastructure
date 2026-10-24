#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Structural AST metrics do not cover runtime-generated code, call graphs, or duplication.

[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$Strict,
    [switch]$PassThru,
    [string]$JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules/WindowsAst.Common.psm1') -ErrorAction Stop

$limits = [ordered]@{ Cyclomatic = 15; Nesting = 5; CodeLines = 80 }
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Get-GitTrackedPaths {
    param([Parameter(Mandatory)][string]$Root)
    $start = [Diagnostics.ProcessStartInfo]::new('git')
    $start.WorkingDirectory = $Root
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('ls-files', '--cached', '-z', '--', 'windows', 'shared/windows', '.github/actions')) {
        [void]$start.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'git ls-files did not start' }
    try {
        $raw = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git ls-files failed: $stderr" }
        $raw.Split([char]0) | Where-Object { $_ }
    } finally {
        $process.Dispose()
    }
}

function Get-TrackedPowerShellFiles {
    param([Parameter(Mandatory)][string]$Root)
    $relativePaths = @(Get-GitTrackedPaths -Root $Root | Where-Object {
            $_ -match '(?i)\.(ps1|psm1)$' -and $_ -notmatch '(?i)(^|[\\/])archive[\\/]'
        })
    $relativePaths | ForEach-Object { Get-Item -LiteralPath (Join-Path $Root $_) -ErrorAction Stop }
}

function Get-SelectedPowerShellFiles {
    param([string[]]$Selection)
    $files = if ($null -eq $Selection -or $Selection.Count -eq 0) {
        @(Get-TrackedPowerShellFiles -Root $repoRoot)
    } else {
        foreach ($item in $Selection) {
            $resolved = Get-Item -LiteralPath $item -ErrorAction Stop
            if ($resolved.PSIsContainer) {
                Get-ChildItem -LiteralPath $resolved.FullName -Recurse -File -Include '*.ps1', '*.psm1'
            } else {
                $resolved
            }
        }
    }
    $selected = @($files | Where-Object {
            $_.FullName -match '(?i)\.(ps1|psm1)$' -and $_.FullName -notmatch '(?i)[\\/]archive[\\/]'
        } | ForEach-Object { $_.FullName } | Sort-Object -Unique)
    if ($selected.Count -eq 0) { throw 'No PowerShell files selected for complexity analysis' }
    return $selected
}

function Get-ReportPath {
    param([Parameter(Mandatory)][string]$File)
    $prefix = $repoRoot.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar
    if ($File.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $File.Substring($prefix.Length).Replace('\', '/')
    }
    return $File
}

function Get-NamedUnitKind {
    param([Parameter(Mandatory)]$Node)
    if ($Node -is [System.Management.Automation.Language.FunctionMemberAst]) { return 'Method' }
    if ($Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Parent -isnot [System.Management.Automation.Language.FunctionMemberAst]) { return 'Function' }
    return $null
}

function Get-NamedAncestors {
    param([Parameter(Mandatory)]$Node, [switch]$IncludeClass)
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ((Get-NamedUnitKind -Node $parent) -or ($IncludeClass -and $parent -is [System.Management.Automation.Language.TypeDefinitionAst])) { $parent }
        $parent = $parent.Parent
    }
}

function Get-OwnerUnit {
    param([Parameter(Mandatory)]$Node)
    foreach ($ancestor in (Get-NamedAncestors -Node $Node)) { return $ancestor }
    return $null
}

function Get-UnitName {
    param([Parameter(Mandatory)]$Node)
    if ($Node -is [System.Management.Automation.Language.ScriptBlockAst]) { return '<script>' }
    $names = @([string]$Node.Name)
    foreach ($ancestor in (Get-NamedAncestors -Node $Node -IncludeClass)) {
        $names = @([string]$ancestor.Name) + $names
    }
    return $names -join '.'
}

function Get-DecisionPoints {
    param([Parameter(Mandatory)]$Node)
    $kind = $Node.GetType().Name
    if ($kind -eq 'IfStatementAst' -or $kind -eq 'SwitchStatementAst') { return @($Node.Clauses).Count }
    if ($kind -in @('ForStatementAst', 'ForEachStatementAst', 'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst', 'CatchClauseAst', 'TrapStatementAst', 'TernaryExpressionAst', 'PipelineChainAst')) { return 1 }
    if ($kind -eq 'BinaryExpressionAst' -and $Node.Operator.ToString() -in @('And', 'Or', 'QuestionQuestion')) { return 1 }
    if ($kind -eq 'AssignmentStatementAst' -and $Node.Operator.ToString() -eq 'QuestionQuestionEquals') { return 1 }
    return 0
}

function Test-NestingNode {
    param([Parameter(Mandatory)]$Node)
    return $Node.GetType().Name -in @(
        'IfStatementAst', 'SwitchStatementAst', 'ForStatementAst', 'ForEachStatementAst',
        'WhileStatementAst', 'DoWhileStatementAst', 'DoUntilStatementAst',
        'TryStatementAst', 'TrapStatementAst', 'TernaryExpressionAst'
    )
}

function Get-NestingDepth {
    param([Parameter(Mandatory)]$Node, $Owner)
    $depth = 0
    $current = $Node
    while ($null -ne $current -and -not [object]::ReferenceEquals($current, $Owner)) {
        if (Test-NestingNode -Node $current) { $depth++ }
        $current = $current.Parent
    }
    return $depth
}

function Get-CodeLineCount {
    param([Parameter(Mandatory)]$Unit, [Parameter(Mandatory)][object[]]$Tokens, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Excluded)
    $lines = [Collections.Generic.HashSet[int]]::new()
    foreach ($token in $Tokens) {
        if ($token.Kind.ToString() -in @('Comment', 'EndOfInput', 'NewLine', 'LineContinuation')) { continue }
        $start = $token.Extent.StartOffset
        if ($start -lt $Unit.Extent.StartOffset -or $start -ge $Unit.Extent.EndOffset) { continue }
        $insideChild = $false
        foreach ($child in $Excluded) {
            if ($start -ge $child.Extent.StartOffset -and $start -lt $child.Extent.EndOffset) {
                $insideChild = $true
                break
            }
        }
        if ($insideChild) { continue }
        $lastLine = $token.Extent.EndLineNumber
        if ($token.Extent.EndColumnNumber -eq 1 -and $lastLine -gt $token.Extent.StartLineNumber) { $lastLine-- }
        for ($line = $token.Extent.StartLineNumber; $line -le $lastLine; $line++) { [void]$lines.Add($line) }
    }
    return $lines.Count
}

function Get-UnitMetrics {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][object[]]$Tokens, [Parameter(Mandatory)][string]$File)
    $named = @($Ast.FindAll({ param($node) [bool](Get-NamedUnitKind -Node $node) }, $true))
    $decisions = @($Ast.FindAll({ param($node) (Get-DecisionPoints -Node $node) -gt 0 }, $true))
    $structures = @($Ast.FindAll({ param($node) Test-NestingNode -Node $node }, $true))
    foreach ($unit in @($Ast) + $named) {
        $isScript = [object]::ReferenceEquals($unit, $Ast)
        $ownedDecisions = @($decisions | Where-Object { [object]::ReferenceEquals((Get-OwnerUnit -Node $_), $(if ($isScript) { $null } else { $unit })) })
        $ownedStructures = @($structures | Where-Object { [object]::ReferenceEquals((Get-OwnerUnit -Node $_), $(if ($isScript) { $null } else { $unit })) })
        $children = @($named | Where-Object {
                -not [object]::ReferenceEquals($_, $unit) -and
                $_.Extent.StartOffset -ge $unit.Extent.StartOffset -and $_.Extent.EndOffset -le $unit.Extent.EndOffset
            })
        $cyclomatic = 1
        foreach ($node in $ownedDecisions) { $cyclomatic += Get-DecisionPoints -Node $node }
        $nesting = 0
        foreach ($node in $ownedStructures) {
            $depth = Get-NestingDepth -Node $node -Owner $(if ($isScript) { $null } else { $unit })
            if ($depth -gt $nesting) { $nesting = $depth }
        }
        [pscustomobject]@{
            File = $File
            Name = Get-UnitName -Node $unit
            Kind = if ($isScript) { 'Script' } else { Get-NamedUnitKind -Node $unit }
            Line = $unit.Extent.StartLineNumber
            Cyclomatic = $cyclomatic
            Nesting = $nesting
            CodeLines = Get-CodeLineCount -Unit $unit -Tokens $Tokens -Excluded $children
        }
    }
}

function Get-FileMetrics {
    param([Parameter(Mandatory)][string]$File)
    $parsed = Get-WindowsAstParseResult -File $File -ErrorLabel 'PowerShell parse error in'
    Get-UnitMetrics -Ast $parsed.Ast -Tokens @($parsed.Tokens) -File (Get-ReportPath -File $File)
}

function Get-MetricFindings {
    param([Parameter(Mandatory)][object[]]$Units)
    foreach ($unit in $Units) {
        foreach ($metric in @('Cyclomatic', 'Nesting', 'CodeLines')) {
            if ($metric -eq 'CodeLines' -and $unit.Kind -eq 'Script') { continue }
            if ($unit.$metric -le $limits[$metric]) { continue }
            [pscustomobject]@{
                File = $unit.File
                Line = $unit.Line
                Name = $unit.Name
                Metric = $metric
                Actual = $unit.$metric
                Limit = $limits[$metric]
            }
        }
    }
}

$files = @(Get-SelectedPowerShellFiles -Selection $Path)
$units = @(foreach ($file in $files) { Get-FileMetrics -File $file })
if ($units.Count -lt $files.Count) { throw 'Complexity analysis produced fewer script units than files' }
$findings = @(Get-MetricFindings -Units $units)
$report = [pscustomobject]@{
    SchemaVersion = 1
    Limits = $limits
    FileCount = $files.Count
    UnitCount = $units.Count
    FindingCount = $findings.Count
    Units = $units
    Findings = $findings
}

if ($JsonPath) {
    $json = ConvertTo-Json -InputObject $report -Depth 8
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($JsonPath), $json)
}
if (-not $PassThru) {
    Write-Host "PowerShell complexity: $($files.Count) files, $($units.Count) units, $($findings.Count) findings"
    foreach ($finding in $findings) {
        Write-Host ("  {0}:{1} {2} {3}={4} (limit {5})" -f $finding.File, $finding.Line, $finding.Name, $finding.Metric, $finding.Actual, $finding.Limit)
    }
}
if ($Strict -and $findings.Count -gt 0) { throw "PowerShell complexity gate failed: $($findings.Count) finding(s)" }
if ($PassThru) { $report }
