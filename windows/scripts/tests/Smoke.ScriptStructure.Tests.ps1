#requires -Version 7.0
# Parses Test-Container.ps1 only; it does not run a section or check calls into imported modules.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsLint.Common.psm1') -Force

$script:SmokeScript = 'windows\scripts\build\Test-Container.ps1'
$script:FunctionAst = [System.Management.Automation.Language.FunctionDefinitionAst]

Describe 'Smoke script structure (Test-Container.ps1)' {
    It 'defines every function at script level, so a section never calls one that exists only inside another (mutation)' {
        $ast = Get-TestScriptAst -ScriptPath $script:SmokeScript
        $nested = @($ast.FindAll({ param($node) $node -is $script:FunctionAst }, $true) | Where-Object {
                $parent = $_.Parent
                while ($parent -and $parent -isnot $script:FunctionAst) { $parent = $parent.Parent }
                [bool]$parent
            } | ForEach-Object { "$($_.Name) at line $($_.Extent.StartLineNumber)" })
        Assert-Equal '' ($nested -join ', ') 'no function definition sits inside another'
        Assert-True (@($ast.FindAll({ param($node) $node -is $script:FunctionAst -and $node.Name -eq 'Invoke-OpenCvLinkSmoke' }, $false)).Count -eq 1) 'the OpenCV link smoke is a script-level function'
    }

    It 'calls each script function only with parameter names it declares (mutation)' {
        $ast = Get-TestScriptAst -ScriptPath $script:SmokeScript
        Assert-Equal '' (@(Get-UndeclaredParameterViolation -Ast $ast -Label 'Test-Container.ps1') -join ', ') 'every named argument binds'
        Assert-Equal 1 @(Get-TestScriptCommands -ScriptPath $script:SmokeScript -Name 'Assert-CmakeSmokeBuild').Count 'the CMake smoke has its one call'
    }

    It 'the undeclared-parameter detector accepts prefixes and rejects unknown names' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            "function F { param(`$Directory, `$Name) }`nF -Dir x -Name y`nF -Path z`nG -Anything 1", [ref]$null, [ref]$null)
        $found = @(Get-UndeclaredParameterViolation -Ast $ast -Label 'fixture')
        Assert-Equal 1 $found.Count 'only the undeclared -Path'
        Assert-Match '^fixture:3: -Path \(no such parameter on F\)$' $found[0] 'names the line, the argument and the function'
    }
}
