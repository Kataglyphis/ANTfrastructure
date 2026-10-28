#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Reads Test-Container.ps1 by AST only; nothing here runs the smoke gate.

# The section-21 branch that runs once the venv and its verifier exist; every statement in it is unconditional.
function Get-TorchAppVenvBranch {
    $ast = Get-TestScriptAst -ScriptPath 'windows\scripts\build\Test-Container.ps1'
    return , @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
                "$($n.Clauses[0].Item1.Extent.Text)" -match '^\$torchAppDir -and \(Test-Path \$torchAppDir\) -and \$torchAppScript$' }, $true))
}

Export-ModuleMember -Function Get-TorchAppVenvBranch
