#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Diagnostic scripts run by hand, so a wrong path to the repo root or a module surfaces only on the day they are needed; evaluates only Split-Path/Join-Path expressions over $PSScriptRoot and $repoRoot.

Describe 'Diagnostic scripts resolve their repo root and modules' {
    $script:diagDir = Join-Path (Get-RepoRoot) 'windows/scripts/diagnostics'

    function Test-PathExpressionText {
        param([System.Management.Automation.Language.Ast]$Ast)
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Ast.Extent.Text, [ref]$tokens, [ref]$null)
        $commands = @($tokens | Where-Object { $_.TokenFlags -band [System.Management.Automation.Language.TokenFlags]::CommandName } | ForEach-Object Text)
        $variables = @($tokens | Where-Object Kind -eq 'Variable' | ForEach-Object Name)
        ($commands.Count -gt 0) -and -not ($commands | Where-Object { $_ -notin 'Split-Path', 'Join-Path' }) -and -not ($variables | Where-Object { $_ -notin 'PSScriptRoot', 'repoRoot' })
    }

    function Invoke-PathExpression {
        param([string]$Text, [string]$ScriptDir, [string]$RepoRoot)
        $path = & ([scriptblock]::Create('param($scriptDir, $repoRoot) ' + $Text.Replace('$PSScriptRoot', '$scriptDir'))) $ScriptDir $RepoRoot
        $path -replace '[\\/]', [IO.Path]::DirectorySeparatorChar
    }

    function Get-DiagnosticPathCase {
        foreach ($file in Get-ChildItem -LiteralPath $script:diagDir -Filter '*.ps1' -Recurse -File) {
            $ast = Get-TestScriptAst -ScriptPath $file.FullName
            $rootAssign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$repoRoot' }, $true) |
                    Where-Object { Test-PathExpressionText -Ast $_.Right })
            $repoRoot = if ($rootAssign) { Invoke-PathExpression -Text $rootAssign[0].Right.Extent.Text -ScriptDir $file.DirectoryName } else { $null }
            if ($rootAssign) { [pscustomobject]@{ File = $file.Name; Kind = 'repoRoot'; Path = $repoRoot } }
            foreach ($import in @(Get-TestAstCommands -Ast $ast -Name 'Import-Module')) {
                $arg = $import.CommandElements[1]
                if (-not $arg -or -not (Test-PathExpressionText -Ast $arg)) { continue }
                if ($arg.Extent.Text -match '\$repoRoot\b' -and -not $repoRoot) { continue }
                [pscustomobject]@{ File = $file.Name; Kind = 'module'; Path = (Invoke-PathExpression -Text $arg.Extent.Text -ScriptDir $file.DirectoryName -RepoRoot $repoRoot) }
            }
        }
    }

    It 'points every computed repo root at the repository and every computed module import at a file (mutation)' {
        $cases = @(Get-DiagnosticPathCase)
        foreach ($name in 'Test-CudaCache.ps1', 'Test-Rdna4LayerLock.ps1') {
            Assert-True (@($cases | Where-Object { $_.File -eq $name -and $_.Kind -eq 'repoRoot' }).Count -eq 1) "$name computes its repo root in a checked form"
        }
        Assert-True (@($cases | Where-Object Kind -eq 'module').Count -ge 10) 'the scan reaches the module imports, not none'
        foreach ($case in $cases) {
            if ($case.Kind -eq 'repoRoot') {
                Assert-Equal (Get-RepoRoot).TrimEnd('\', '/') ([IO.Path]::GetFullPath($case.Path).TrimEnd('\', '/')) "$($case.File): `$repoRoot is the repository root"
            } else {
                Assert-True (Test-Path -LiteralPath $case.Path -PathType Leaf) "$($case.File): imports $($case.Path), which exists"
            }
        }
    }
}
