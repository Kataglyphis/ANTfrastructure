#requires -Version 7.0
# This checks the host import binding and cold export; archive, registry and Vulkan behavior have separate gates.

function Assert-LavapipeHostImport {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
    $imports = @(Get-TestAstCommands -Ast $Ast -Name Import-Module)
    $direct = @($imports | Where-Object {
            $_.CommandElements.Count -ge 2 -and
            $_.CommandElements[1] -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $_.CommandElements[1].VariablePath.UserPath -eq 'sharedModulePath'
        })
    Assert-Equal 1 $direct.Count 'the host entry itself must import Shared'
    $parameters = @($direct[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
        ForEach-Object ParameterName)
    Assert-True ($parameters -contains 'ErrorAction') 'a missing required Shared module must fail'
    Assert-False ($parameters -contains 'Force') 'the entry must retain the private-warm module instance'
    $assignments = @($Ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$sharedModulePath'
            }, $true))
    Assert-Equal 1 $assignments.Count 'the imported path must have one owner'
    Assert-Match 'WindowsScripts\.Shared\.psm1' $assignments[0].Right.Extent.Text
}

Describe 'Lavapipe host script module visibility' {
    It 'imports and resolves the shared elevation predicate, and rejects a dropped import' {
        $scriptPath = Join-Path (Get-RepoRoot) 'windows/scripts/host/Install-LavapipeHost.ps1'
        $source = [IO.File]::ReadAllText($scriptPath)
        Assert-LavapipeHostImport -Ast (Get-TestScriptAst -ScriptPath $scriptPath)
        $shared = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1'
        $cold = Test-ColdModuleCommands -ModulePath @($shared) -CommandName @('Test-Elevated')
        Assert-Equal 0 $cold.ExitCode "Shared does not export Test-Elevated: $($cold.Output)"
        $import = 'Import-Module $sharedModulePath -ErrorAction Stop'
        Assert-False ($source -eq $source.Replace($import, '')) 'the mutant must remove the direct import'
        Assert-Throws { Assert-LavapipeHostImport -Ast (ConvertTo-TestScriptAst -Text $source.Replace($import, '')) } `
            -MessagePattern 'the host entry itself must import Shared'
    }
}
