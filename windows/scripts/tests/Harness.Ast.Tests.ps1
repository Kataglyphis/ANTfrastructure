#requires -Version 7.0
# AST fixtures check path/error handling and declaration parsing; no script or native build is executed.

Describe 'Get-TestScriptAst' {
    It 'parses declarations without executing the script' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'declarations.ps1'
            [IO.File]::WriteAllText($path, "throw 'must not run'`nfunction Get-FixtureValue { return 42 }")
            $ast = Get-TestScriptAst -ScriptPath $path
            $functions = @($ast.FindAll({ param($node)
                        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            Assert-Equal 1 $functions.Count
            Assert-Equal 'Get-FixtureValue' $functions[0].Name
            Assert-Equal $path $ast.Extent.File
        }
    }

    It 'refuses missing and malformed scripts with the requested diagnostic label' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'missing.ps1'
            Assert-Throws { Get-TestScriptAst -ScriptPath $path -ErrorLabel fixture } -MessagePattern 'fixture: script not found'
            [IO.File]::WriteAllText($path, 'function Broken {')
            Assert-Throws { Get-TestScriptAst -ScriptPath $path -ErrorLabel fixture } -MessagePattern 'fixture: parse errors'
            Assert-Throws { Get-ScriptFunctionDefinition -ScriptPath $path -FunctionName Broken } -MessagePattern 'Get-ScriptFunctionDefinition: parse errors'
        }
    }
}

Describe 'ConvertTo-TestScriptAst' {
    It 'parses snippets and reports malformed snippets without running them' {
        $ast = ConvertTo-TestScriptAst -Text "throw 'must not run'"
        Assert-NotNull $ast
        Assert-Throws { ConvertTo-TestScriptAst -Text 'function Broken {' -ErrorLabel fixture } -MessagePattern 'fixture snippet failed to parse'
        Assert-NotNull (ConvertTo-TestScriptAst -Text '')
    }
}
