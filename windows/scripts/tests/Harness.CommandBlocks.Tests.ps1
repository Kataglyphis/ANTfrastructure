#requires -Version 7.0
# Parsed commands exercise source wiring in caller fixtures; they do not execute the surrounding build script.

function Invoke-CommandBlockVerdictFixture {
    param([string]$Find, [Collections.IDictionary]$Files, [scriptblock]$Body)
    $assertBody = $Body
    Invoke-InTestDir -Files $Files -Body { param($dir)
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName Get-TestScriptCommandBlock `
            -Find $Find -Replace '' -Expected 'expected an exception but none was thrown' -IncludeControl -Body $assertBody -BodyArgumentList @($dir)
    }.GetNewClosure()
}

Describe 'Harness executable command projection' {
    It 'selects exact commands in source order without running the script and keeps caller variable lookup' {
        Invoke-InTestDir -Files @{ 'source [calls].ps1' = 'throw "top level must not execute"; Write-Output $callerValue; Write-Output "literal [tail]"' } -Body { param($dir)
            $blocks = @(Get-TestScriptCommandBlock -ScriptPath (Join-Path $dir 'source [calls].ps1') -Name Write-Output -ExpectedCount 2)
            Assert-Equal 2 $blocks.Count
            $callerValue = 'caller scope'
            Assert-Equal 'caller scope' $callerValue 'caller locals are populated before executing the projection'
            Assert-Equal 'caller scope' (& $blocks[0]) 'projected commands resolve the invocation scope'
            Assert-Equal 'literal [tail]' (& $blocks[1]) 'source order and command arguments are retained'
        }
    }

    It 'rejects both absent and excess commands before an empty or partial projection can pass' {
        Invoke-CommandBlockVerdictFixture -Find 'Assert-Equal $ExpectedCount $calls.Count "Expected $ExpectedCount $Name call(s) in $ScriptPath; found $($calls.Count)"' `
            -Files @{ 'single.ps1' = 'Write-Output 7'; 'double.ps1' = 'Write-Output 1; Write-Output 2' } -Body { param($dir)
                Assert-Throws { Get-MutTestScriptCommandBlock -ScriptPath (Join-Path $dir single.ps1) -Name Write-Warning } -MessagePattern 'Expected 1 Write-Warning call.*found 0'
                Assert-Throws { Get-MutTestScriptCommandBlock -ScriptPath (Join-Path $dir double.ps1) -Name Write-Output } -MessagePattern 'Expected 1 Write-Output call.*found 2'
                Assert-Equal 1 @(Get-MutTestScriptCommandBlock -ScriptPath (Join-Path $dir single.ps1) -Name Write-Output).Count 'the default expects exactly one call'
            }
    }

    It 'refuses zero and negative expectations so an empty projection cannot pass vacuously' {
        Invoke-CommandBlockVerdictFixture -Find "Assert-True (`$ExpectedCount -gt 0) 'ExpectedCount must be positive'" `
            -Files @{ 'valid.ps1' = 'Write-Output 9' } -Body { param($dir)
                foreach ($count in @(0, -1)) {
                    Assert-Throws { Get-MutTestScriptCommandBlock -ScriptPath (Join-Path $dir valid.ps1) -Name Write-Warning -ExpectedCount $count } -MessagePattern 'ExpectedCount must be positive'
                }
            }
    }

    It 'rejects missing input and parser errors before command selection' {
        Invoke-InTestDir -Files @{ 'broken.ps1' = 'Write-Output "unterminated' } -Body { param($dir)
            Assert-Throws { Get-TestScriptCommandBlock -ScriptPath (Join-Path $dir missing.ps1) -Name Write-Output } -MessagePattern 'script not found'
            Assert-Throws { Get-TestScriptCommandBlock -ScriptPath (Join-Path $dir broken.ps1) -Name Write-Output } -MessagePattern 'parse errors'
        }
    }
}
