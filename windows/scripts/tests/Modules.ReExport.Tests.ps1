#requires -Version 7.0
# Export-ModuleMember skips absent names silently, so a fresh child pwsh imports only this module and every export must resolve.

Describe 'WindowsSourceBuild.Common re-export integrity (fresh session)' {

    It 'every exported name resolves after a cold import' {
        $modPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSourceBuild.Common.psm1'
        Assert-True (Test-Path $modPath) "module not found at $modPath"

        $ast = Get-TestScriptAst -ScriptPath $modPath
        $exports = @(Get-TestAstCommands -Ast $ast -Name Export-ModuleMember)
        $names = @($exports | ForEach-Object {
            $argument = (Get-TestCommandArguments -Command $_ -AsAst).Function
            $argument.FindAll({ param($node)
                $node -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Value }
        } | Sort-Object -Unique)
        Assert-True ($names.Count -ge 40) "parsed only $($names.Count) export names — the Export-ModuleMember layout changed; update this parser"

        $result = Test-ColdModuleCommands -ModulePath $modPath -CommandName $names -Force
        Assert-Equal 0 $result.ExitCode ("exported names missing after cold import (the silent re-export no-op class): " + $result.Output)

    }
}
