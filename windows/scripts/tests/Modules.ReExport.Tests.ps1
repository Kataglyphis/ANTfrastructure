#requires -Version 7.0
# Export-ModuleMember skips absent names silently, so a fresh child pwsh imports only this module and every export must resolve.

Describe 'WindowsSourceBuild.Common re-export integrity (fresh session)' {

    It 'exposes the Rust installer file lookup through ContainerImage and catches an omitted re-export' {
        Invoke-InTestDir { param($dir)
            Copy-TestModuleClosure -Seed WindowsContainerImage.Common -Destination $dir
            $module = Join-Path $dir WindowsContainerImage.Common.psm1
            $control = Test-ColdModuleCommands -ModulePath $module -CommandName Find-FirstTreeFile
            Assert-Equal 0 $control.ExitCode $control.Output
            $text = [IO.File]::ReadAllText($module)
            $changed = $text.Replace("    'Find-FirstTreeFile',", '')
            Assert-False ($changed -ceq $text) 'the missing-export mutant must change the real module'
            [IO.File]::WriteAllText($module, $changed)
            $mutant = Test-ColdModuleCommands -ModulePath $module -CommandName Find-FirstTreeFile
            Assert-TestPwshFailure -Probe $mutant -Pattern Find-FirstTreeFile -Reason 'the Rust installer lookup must remain exported'
        }
    }

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
