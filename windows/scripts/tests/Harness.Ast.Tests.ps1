#requires -Version 7.0
# AST fixtures check path/error handling and declaration parsing; no script or native build is executed.

function Get-AstFixtureCommand {
    param([string]$Text, [string]$Name)
    $tree = ConvertTo-TestScriptAst -Text $Text
    $commands = @(Get-TestAstCommands -Ast $tree -Name $Name)
    Assert-Equal 1 $commands.Count 'one command in the fixture'
    return $commands[0]
}

Describe 'AST ancestry and command wiring' {
    It 'walks nearest ancestors first and respects an exclusive stop node' {
        $ast = ConvertTo-TestScriptAst -Text 'if ($enabled) { try { $value = Get-Item -LiteralPath example } finally { } }'
        $call = @(Get-TestAstCommands -Ast $ast -Name Get-Item)[0]
        $assignment = Get-TestAstAncestor -Node $call -Type ([Management.Automation.Language.AssignmentStatementAst]) -First
        Assert-Equal '$value' $assignment.Left.Extent.Text
        $branch = Get-TestAstAncestor -Node $call -Type ([Management.Automation.Language.IfStatementAst]) -First
        Assert-NotNull $branch
        Assert-Equal 0 @(Get-TestAstAncestor -Node $call -Type ([Management.Automation.Language.IfStatementAst]) -Stop $branch).Count
        Assert-Equal 0 @(Get-TestAstAncestor -Node $ast).Count
        Assert-TestAstCommand -Command @($call) -Text 'Get-Item -LiteralPath example' -Assignment '$value'
    }

    It 'filters ancestors before choosing the nearest match and keeps the stop exclusive' {
        $call = Get-AstFixtureCommand -Text 'if ($outer) { if ($inner) { Get-Date } }' -Name Get-Date
        $predicate = { param($branch) $branch.Clauses[0].Item1.Extent.Text -eq '$outer' }
        $outer = Get-TestAstAncestor -Node $call -Type ([Management.Automation.Language.IfStatementAst]) -Predicate $predicate -First
        Assert-Equal '$outer' $outer.Clauses[0].Item1.Extent.Text
        Assert-Equal 0 @(Get-TestAstAncestor -Node $call -Predicate { $false }).Count
        Assert-Equal 0 @(Get-TestAstAncestor -Node $call -Type ([Management.Automation.Language.IfStatementAst]) -Predicate $predicate -Stop $outer).Count
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName Get-TestAstAncestor `
            -Find '(-not $Predicate -or (& $Predicate $parent))' -Replace '$true' -Body {
                Assert-Throws {
                    Assert-Equal 0 @(Get-MutTestAstAncestor -Node $call -Predicate { $false }).Count
                } -MessagePattern 'expected \[0\] but got'
            }
    }

    It 'rejects absent, repeated, altered and unassigned command sites' {
        $ast = ConvertTo-TestScriptAst -Text 'Get-Item -LiteralPath example; Get-Item -LiteralPath example'
        $calls = @(Get-TestAstCommands -Ast $ast -Name Get-Item)
        Assert-Throws { Assert-TestAstCommand -Command @() -Text 'Get-Item' } -MessagePattern 'one call matching'
        Assert-Throws { Assert-TestAstCommand -Command $calls -Text 'Get-Item -LiteralPath example' } -MessagePattern 'one call matching'
        Assert-Throws { Assert-TestAstCommand -Command @($calls[0]) -Text 'Get-Item -Path altered' } -MessagePattern 'literal command wiring'
        Assert-Throws { Assert-TestAstCommand -Command @($calls[0]) -Text 'Get-Item -LiteralPath example' -Assignment '$value' } -MessagePattern 'must be assigned'
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'TestHarness.psm1'))
        Invoke-WithFunctionModule -Text $source -FunctionName Assert-TestAstCommand `
            -Find 'Assert-Equal 1 $Command.Count "one call matching $Text"' -Replace '' -Body {
                Assert-Throws { Assert-Throws { Assert-MutTestAstCommand -Command $calls -Text 'Get-Item -LiteralPath example' } } -MessagePattern 'none was thrown'
            }
    }
}

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
            Assert-Equal 'Get-FixtureValue' ((Get-TestFunctionNames -Ast $ast) -join ',')
            Assert-Equal $path $ast.Extent.File
            [IO.File]::WriteAllText($path, "throw 'must not run'`nGet-Item -LiteralPath missing")
            $calls = @(Get-TestScriptCommands -ScriptPath $path -Name Get-Item)
            Assert-Equal 1 $calls.Count
            Assert-Equal 'Get-Item -LiteralPath missing' $calls[0].Extent.Text
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

Describe 'Static command queries' {
    It 'finds exact command names in nested scopes without executing the input' {
        $ast = ConvertTo-TestScriptAst -Text @'
throw 'must not execute'
Get-Item -LiteralPath 'a b' -ErrorAction Stop
function Nested { get-item -LiteralPath $target }
Get-ItemProperty -LiteralPath ignored
'@
        $calls = @(Get-TestAstCommands -Ast $ast -Name 'Get-Item')
        Assert-Equal 2 $calls.Count
        Assert-Equal 0 @(Get-TestAstCommands -Ast $ast -Name 'Missing-Command').Count
        $bound = Get-TestCommandArguments -Command $calls[0]
        Assert-Equal "'a b'" $bound['LiteralPath']
        Assert-Equal 'Stop' $bound['ErrorAction']
        Assert-Equal '$target' (Get-TestCommandArguments -Command $calls[1])['LiteralPath']
    }

    It 'returns an empty argument map for an unparameterized command' {
        $call = Get-AstFixtureCommand -Text 'Get-Date' -Name Get-Date
        $bound = Get-TestCommandArguments -Command $call
        Assert-True ($bound -is [hashtable])
        Assert-Equal 0 $bound.Count
    }
}

Describe 'Typed command arguments' {
    It 'retains literal and callback AST nodes for source fixtures without executing the input' {
        $command = Get-AstFixtureCommand -Text "Edit-SourceFile -Path 'fixture' -Guard 'anchor' -Transform { param(`$text) `$text + ' suffix' }" -Name Edit-SourceFile
        $arguments = Get-TestCommandArguments -Command $command -AsAst
        Assert-True ($arguments.Guard -is [Management.Automation.Language.StringConstantExpressionAst])
        Assert-Equal anchor $arguments.Guard.Value
        Assert-True ($arguments.Transform -is [Management.Automation.Language.ScriptBlockExpressionAst])
        Assert-Equal 'fixture suffix' (& ($arguments.Transform.ScriptBlock.GetScriptBlock()) fixture)
        Assert-Equal "'anchor'" (Get-TestCommandArguments -Command $command)['Guard']
    }
}
