#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Byte and lifecycle probes run on every host; native batch quoting and exit semantics require Windows.

Describe 'Harness fixture lifecycle' {
    It 'creates unique directories with the existing default prefix' {
        $first = New-TestDir
        $second = New-TestDir
        try {
            Assert-True (Test-Path -LiteralPath $first -PathType Container)
            Assert-True (Test-Path -LiteralPath $second -PathType Container)
            Assert-False ($first -eq $second)
            Assert-Match '^wbt-[a-f0-9]{32}$' (Split-Path $first -Leaf)
        } finally {
            Remove-Item -LiteralPath $first, $second -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'preserves a suite prefix containing spaces' {
        $dir = New-TestDir -Prefix 'fixture space-'
        try {
            Assert-True (Test-Path -LiteralPath $dir -PathType Container)
            Assert-Match '^fixture space-[a-f0-9]{32}$' (Split-Path $dir -Leaf)
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'cleans up after a failing body and clears a previous native exit code' {
        $state = [pscustomobject]@{ Path = ''; Exit = -1 }
        $savedExit = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        try {
            $global:LASTEXITCODE = 17
            Assert-Throws {
                Invoke-InTestDir -Files @{ 'nested/file.txt' = 'fixture bytes' } -Body { param($dir)
                    $state.Path = $dir
                    $state.Exit = $global:LASTEXITCODE
                    Assert-Equal 'fixture bytes' ([IO.File]::ReadAllText((Join-Path $dir 'nested/file.txt')))
                    throw 'fixture body failed'
                }
            } -MessagePattern 'fixture body failed'
            Assert-Equal 0 $state.Exit
            Assert-False (Test-Path -LiteralPath $state.Path)
        } finally {
            if ($savedExit) { $global:LASTEXITCODE = $savedExit.Value } else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
            if ($state.Path) { Remove-Item -LiteralPath $state.Path -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Harness text trees' {
    It 'creates nested parents, preserves exact contents and overwrites existing files without output' {
        Invoke-InTestDir { param($dir)
            $root = Join-Path $dir 'absent tree'
            $content = "first line`nsecond line"
            $result = @(Write-TestFileTree -Root $root -Files ([ordered]@{ 'nested [folder]\file.txt' = $content; 'empty.txt' = '' }))
            Assert-Equal 0 $result.Count
            Assert-Equal $content ([IO.File]::ReadAllText((Join-Path $root 'nested [folder]\file.txt')))
            Assert-Equal '' ([IO.File]::ReadAllText((Join-Path $root 'empty.txt')))
            Write-TestFileTree -Root $root -Files @{ 'nested [folder]\file.txt' = 'replacement' }
            Assert-Equal 'replacement' ([IO.File]::ReadAllText((Join-Path $root 'nested [folder]\file.txt')))
        }
    }
}

Describe 'Native batch fixtures' {
    It 'writes exact ASCII CRLF bytes, forwards quoted arguments and applies the requested final exit' {
        Invoke-InTestDir { param($dir)
            $lines = @('echo ARG1=[%~1] ARG2=[%~2]')
            $path = New-TestBatchTool -Directory (Join-Path $dir 'missing parent') -Name 'fixture tool.cmd' -Line $lines -ExitCode 7
            $expected = "@echo off`r`necho ARG1=[%~1] ARG2=[%~2]`r`nexit /b 7`r`n"
            Assert-Equal ([Convert]::ToHexString([Text.Encoding]::ASCII.GetBytes($expected))) ([Convert]::ToHexString([IO.File]::ReadAllBytes($path)))
            if ($IsWindows) {
                Assert-Match 'ARG1=\[a b\] ARG2=\[second value\]' ((& $path 'a b' 'second value') | Out-String)
                Assert-Equal 7 $global:LASTEXITCODE
            }
            $early = New-TestBatchTool -Directory $dir -Name early.cmd -Line 'exit /b 3' -ExitCode 7
            Assert-Equal "@echo off`r`nexit /b 3`r`nexit /b 7`r`n" ([IO.File]::ReadAllText($early))
            if ($IsWindows) {
                & $early
                Assert-Equal 3 $global:LASTEXITCODE 'caller branches can override the appended fallback'
            }
        }
    }

    foreach ($fault in @(
            @{ Name = 'detects a batch writer that ignores the requested final exit'; Find = '"exit /b $ExitCode"'; Replace = '"exit /b 0"'; Expected = 'Assert-Equal' },
            @{ Name = 'detects a batch writer that drops caller behavior'; Find = ' + $Line + '; Replace = ' + '; Expected = 'does not match' }
        )) {
        It $fault.Name {
            Invoke-TestFunctionMutations -ModuleArguments @{ ScriptPath = 'windows/scripts/tests/TestHarness.psm1'; FunctionName = @('New-TestBatchTool') } `
                -Case $fault -Body {
                    Invoke-InTestDir { param($dir)
                        $path = New-MutTestBatchTool -Directory $dir -Name fail.cmd -Line 'echo caller-marker' -ExitCode 7
                        Assert-Match '(?m)^echo caller-marker\r?$' ([IO.File]::ReadAllText($path))
                        Assert-Equal 'exit /b 7' ([IO.File]::ReadAllLines($path)[-1])
                        if ($IsWindows) {
                            $output = (& $path) | Out-String
                            $code = $global:LASTEXITCODE
                            Assert-Match caller-marker $output
                            Assert-Equal 7 $code
                        }
                    }
                }
        }
    }
}

Describe 'Child PowerShell fixture transport' {
    It 'requires both a failed status and the expected child diagnostic' {
        Assert-TestPwshFailure -Probe ([pscustomobject]@{ ExitCode = 7; Output = 'expected marker' }) -Pattern '^expected marker$'
        Assert-Throws { Assert-TestPwshFailure -Probe ([pscustomobject]@{ ExitCode = 0; Output = 'expected marker' }) -Pattern marker } -MessagePattern 'child PowerShell must fail'
        Assert-Throws { Assert-TestPwshFailure -Probe ([pscustomobject]@{ ExitCode = 7; Output = 'different' }) -Pattern marker } -MessagePattern 'does not match'
    }
    It 'captures success, merged failure output and native status without executing source in the parent' {
        Set-Variable -Name WbtChildProbeIsolation -Scope Global -Value parent
        try {
            $success = Invoke-TestPwshProbe -Source "Write-Output 'success-marker'; exit 0"
            Assert-Equal 0 $success.ExitCode
            Assert-Equal success-marker $success.Output
            $failure = Invoke-TestPwshProbe -Source '$global:WbtChildProbeIsolation = "child"; Write-Output "stdout-marker"; Write-Error "stderr-marker"; exit 7'
            Assert-Equal 7 $failure.ExitCode
            Assert-Match stdout-marker $failure.Output
            Assert-Match stderr-marker $failure.Output
            Assert-Equal parent (Get-Variable -Name WbtChildProbeIsolation -Scope Global -ValueOnly)
        } finally { Remove-Variable WbtChildProbeIsolation -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'detects child failures being replaced by a successful exit code' {
        Invoke-TestFunctionMutations -Find '$code = $LASTEXITCODE' -Replace '$code = 0' -Expected 'Assert-Equal' -Body {
                $probe = Invoke-MutTestPwshProbe -Source 'exit 7'
                Assert-Equal 7 $probe.ExitCode
            } -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName @('Invoke-TestPwshProbe')
    }
}

Describe 'Required literal script assertions' {
    It 'keeps literal case, rejects vacuous inputs and refuses a missing source' {
        Invoke-InTestDir -Files @{ 'source.ps1' = 'alpha BETA' } -Body { param($dir)
            $path = Join-Path $dir source.ps1
            Assert-TestScriptContains -ScriptPath $path -Literal alpha, BETA
            Assert-Throws { Assert-TestScriptContains -ScriptPath $path -Literal beta } -MessagePattern 'required script literal: beta'
            foreach ($invalid in @(@{ Literal = @() }, @{ Literal = @('') }, @{ Literal = @($null) })) {
                Assert-Throws { Assert-TestScriptContains -ScriptPath $path @invalid } -MessagePattern 'nonempty string'
            }
            Assert-Throws { Assert-TestScriptContains -ScriptPath (Join-Path $dir missing.ps1) -Literal alpha } -MessagePattern 'missing.ps1'
        }
    }

    It 'detects a literal assertion that accepts missing source content' {
        Invoke-TestFunctionMutations -Find '$text.Contains($needle)' -Replace '$true' -Expected 'expected an exception but none was thrown' -Body {
                $absent = 'missing-literal-' + [guid]::NewGuid().ToString('N')
                Assert-Throws { Assert-MutTestScriptContains -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -Literal $absent }
            } -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName @('Assert-TestScriptContains')
    }
}

Describe 'Lifted module fixture arguments' {
    It 'forwards module initialization and body arguments and removes the module after failure' {
        $state = [pscustomobject]@{ ModulePath = ''; Seen = '' }
        Assert-Throws {
            Invoke-WithFunctionModule -Text 'function Get-FixtureValue { $script:Value }' -Prelude 'param($Initial); $script:Value = $Initial' -Prefix Fixture -ArgumentList @('initialized') -BodyArgumentList @($state, 'body argument') -Body {
                param($record, $argument)
                $record.ModulePath = (Get-Command Get-FixtureFixtureValue).Module.Path
                $record.Seen = "$(Get-FixtureFixtureValue)|$argument"
                throw 'lifted fixture failed'
            }
        } -MessagePattern 'lifted fixture failed'
        Assert-Equal 'initialized|body argument' $state.Seen
        Assert-False (Test-Path -LiteralPath $state.ModulePath)
        Assert-Null (Get-Command Get-FixtureFixtureValue -ErrorAction SilentlyContinue)
    }

    It 'shares one state object between module initialization and the body' {
        $state = [pscustomobject]@{ Value = 'before'; ModulePath = '' }
        Invoke-WithFunctionModule -Text 'function Get-FixtureState { $script:State }' -FixtureState $state -Body {
            param($record)
            $record.ModulePath = (Get-Command Get-MutFixtureState).Module.Path
            Assert-True ([object]::ReferenceEquals($record, (Get-MutFixtureState))) 'constructor and body receive the same object'
            $record.Value = 'after'
        }
        Assert-Equal 'after' $state.Value
        Assert-False (Test-Path -LiteralPath $state.ModulePath)
        foreach ($arguments in @(@{ ArgumentList = @('conflict') }, @{ BodyArgumentList = @('conflict') })) {
            Assert-Throws { Invoke-WithFunctionModule -Text 'function Get-Value { 1 }' -FixtureState $state @arguments -Body { } } -MessagePattern 'cannot be mixed'
        }
    }

    It 'loads source from a path without executing unselected script code' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'source with spaces.ps1'
            [IO.File]::WriteAllText($path, "throw 'must not execute'`nfunction Get-FixtureValue { 42 }")
            Invoke-WithFunctionModule -ScriptPath $path -FunctionName Get-FixtureValue -Body {
                Assert-Equal 42 (Get-MutFixtureValue)
            }
            Assert-Throws { Invoke-WithFunctionModule -ScriptPath $path -Text 'conflict' -Body { } } -MessagePattern 'exactly one'
            Assert-Throws { Invoke-WithFunctionModule -Body { } } -MessagePattern 'exactly one'
            Assert-Throws { Invoke-WithFunctionModule -Text '' -Body { } } -MessagePattern 'must not be empty'
            Assert-Throws { Invoke-WithFunctionModule -ScriptPath (Join-Path $dir 'missing.ps1') -Body { } } -MessagePattern 'missing.ps1'
        }
    }

    It 'preserves empty and populated enumerable state as one shared argument' {
        foreach ($count in 0, 2) {
            $state = [Collections.Generic.List[object]]::new()
            for ($index = 0; $index -lt $count; $index++) { $state.Add($index) }
            Invoke-WithFunctionModule -Text 'function Get-FixtureState { ,$script:State }' -FixtureState $state -Body {
                param($received)
                Assert-True ([object]::ReferenceEquals($state, $received)) 'body argument identity'
                Assert-True ([object]::ReferenceEquals($state, (Get-MutFixtureState))) 'constructor argument identity'
                Assert-Equal $count $received.Count
            }
            Invoke-TestFunctionMutations -Find '{ 1 }' -Replace '{ 2 }' -Expected 'value verdict' -Body {
                    param($record)
                    Assert-True ([object]::ReferenceEquals($state, $record)) 'mutation body state identity'
                    Assert-Equal 1 (Get-MutTableFixture) 'value verdict'
                } -ModuleArguments @{ Text = 'function Get-TableFixture { 1 }'; FixtureState = $state }
            Invoke-WithTestFunction -Name Invoke-StateBoundFixture -FixtureState $state -Definition {
                $State.Add(@($args))
            } -Body { param($received)
                Assert-True ([object]::ReferenceEquals($state, $received)) 'fake body argument identity'
                Invoke-StateBoundFixture 'a b' 'c;d'
                Assert-Equal ($count + 1) $received.Count
                Assert-Equal 'a b|c;d' ($received[-1] -join '|')
            }
            Assert-Null (Get-Command Invoke-StateBoundFixture -ErrorAction SilentlyContinue)
            Assert-Throws {
                Invoke-WithTestFunction -Name Invoke-StateBoundFixture -FixtureState $state -BodyArgumentList 1 -Definition {} -Body {}
            } -MessagePattern 'cannot be combined'
        }
    }
}

Describe 'Isolated function mutation tables' {
    It 'forwards explicit body arguments and removes every mutant module after its assertion fails' {
        $state = New-TestCallState
        $arguments = @{ Text = 'function Get-TableFixture { 1 }'; BodyArgumentList = @($state, 'body argument') }
        Invoke-WithFunctionModule @arguments -Body {
            param($record, $argument)
            Assert-Equal 'body argument' $argument
            Assert-Equal 1 (Get-MutTableFixture)
        }
        Invoke-TestFunctionMutations -ModuleArguments $arguments -Case @(
            @{ Find = '{ 1 }'; Replace = '{ 2 }'; Expected = 'value verdict' },
            @{ Find = '{ 1 }'; Replace = '{ 3 }'; Expected = 'value verdict' }
        ) -Body {
            param($record, $argument)
            Assert-Equal 'body argument' $argument
            $record.Calls.Add((Get-Command Get-MutTableFixture).Module.Path)
            Assert-Equal 1 (Get-MutTableFixture) 'value verdict'
        }
        Assert-Equal 2 $state.Calls.Count
        foreach ($path in $state.Calls) { Assert-False (Test-Path -LiteralPath $path) }
        Assert-Null (Get-Command Get-MutTableFixture -ErrorAction SilentlyContinue)
    }

    It 'rejects empty or incomplete cases and surviving mutants while keeping parse failures outside the expected assertion' {
        $module = @{ Text = 'function Get-TableFixture { 1 }' }
        foreach ($cases in @(@{ Case = @() }, @{ Case = @(@{ Find = ''; Replace = ''; Expected = 'assertion' }) },
                @{ Case = @(@{ Find = '1'; Expected = 'assertion' }) }, @{ Case = @(@{ Find = '1'; Replace = ''; Expected = '' }) })) {
            Assert-Throws { Invoke-TestFunctionMutations -ModuleArguments $module @cases -Body {} } -MessagePattern 'at least one|requires Replace|must be nonempty'
        }
        Assert-Throws {
            Invoke-TestFunctionMutations -Find '{ 1 }' -Replace '{ 2 }' -Expected 'value verdict' -Body {
                Assert-Equal 2 (Get-MutTableFixture)
            } -ModuleArguments $module
        } -MessagePattern 'expected an exception but none was thrown'
        Assert-Throws {
            Invoke-TestFunctionMutations -Find 'BrokenFixture' -Replace 'OtherFixture' -Expected 'parse' -Body { throw 'test body must not execute' } -ModuleArguments @{ Text = 'function Get-BrokenFixture {'; FunctionName = @('Get-BrokenFixture') }
        } -MessagePattern 'parse'
        Assert-Throws {
            Invoke-TestFunctionMutations -Find '{ 1 }' -Replace '{ 2 }' -Expected 'fixture import failed' -Body { throw 'test body must not execute' } -ModuleArguments @{ Text = 'function Get-TableFixture { 1 }'; Prelude = "throw 'fixture import failed'" }
        } -MessagePattern 'fixture import failed'
    }
}

Describe 'Direct mutation inputs and required exceptions' {
    It 'shares direct source inputs, rejects mixed recipes and detects a lost exception' {
        Assert-Throws { Invoke-TestFunctionMutations -ScriptPath any -ModuleArguments @{ Text = 'function Get-A { 1 }' } -Find old -Replace new -Expected failure -Body {} } -MessagePattern 'cannot be mixed'
        Assert-Throws { Invoke-TestFunctionMutations -ModuleArguments @{ Text = 'function Get-A { 1 }' } -Case @() -Find old -Body {} } -MessagePattern 'cannot be mixed'
        Invoke-TestFunctionMutations -ModuleArguments @{ Text = "function Invoke-RequiredFixture { throw 'required fixture error' }" } `
            -Find "throw 'required fixture error'" -Replace '$null' -Throws '^required fixture error$' -Body { Invoke-MutRequiredFixture }
    }
}

Describe 'Harness exception assertions' {
    It 'requires an exception and matches its message without accepting a different error' {
        Assert-Throws { throw 'expected failure' } -MessagePattern '^expected failure$'
        Assert-Throws { Assert-Throws { } } -MessagePattern 'expected an exception but none was thrown'
        Assert-Throws { Assert-Throws { throw 'other failure' } -MessagePattern '^expected failure$' } -MessagePattern 'does not match'
    }
}

Describe 'Scoped fake function lifetime' {
    It 'forwards body arguments and removes a newly installed function after a failure' {
        Assert-Throws {
            Invoke-WithTestFunction -Name Get-WbtFixtureStub -Definition { 'stub result' } -BodyArgumentList @('body value') -Body {
                param($argument)
                Assert-Equal 'body value' $argument
                Assert-Equal 'stub result' (Get-WbtFixtureStub)
                throw 'fixture body failed'
            }
        } -MessagePattern '^fixture body failed$'
        Assert-Null (Get-Command Get-WbtFixtureStub -ErrorAction SilentlyContinue)
    }

    It 'restores the original function through nested replacements' {
        function global:Get-WbtFixtureStub { 'original' }
        try {
            Invoke-WithTestFunction -Name Get-WbtFixtureStub -Definition { 'outer' } -Body {
                Invoke-WithTestFunction -Name Get-WbtFixtureStub -Definition { 'inner' } -Body {
                    Assert-Equal 'inner' (Get-WbtFixtureStub)
                }
                Assert-Equal 'outer' (Get-WbtFixtureStub)
            }
            Assert-Equal 'original' (Get-WbtFixtureStub)
        } finally { Remove-Item Function:Get-WbtFixtureStub -ErrorAction SilentlyContinue }
    }

    It 'rejects a cleanup mutant that leaks the installed function' {
        $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'TestHarness.psm1'))
        Invoke-WithFunctionModule -Text $text -FunctionName Invoke-WithTestFunction `
            -Find 'else { Remove-Item -LiteralPath "Function:$Name" -ErrorAction SilentlyContinue }' -Replace 'else { }' -Body {
                try {
                    Invoke-MutWithTestFunction -Name Get-WbtFixtureStub -Definition { 'leak' } -Body { }
                    Assert-Throws { Assert-Null (Get-Command Get-WbtFixtureStub -ErrorAction SilentlyContinue) } -MessagePattern 'Assert-Null'
                } finally { Remove-Item Function:Get-WbtFixtureStub -ErrorAction SilentlyContinue }
            }
    }
}

Describe 'Recorded fixture state' {
    It 'allocates isolated call lists and retains caller properties without mutating their dictionary' {
        $properties = @{ Code = 7; Empty = $null }
        $first = New-TestCallState -Properties $properties
        $second = New-TestCallState
        $first.Calls.Add(@('one', 'two'))
        Assert-Equal 1 $first.Calls.Count
        Assert-Equal 'one|two' ($first.Calls[0] -join '|')
        Assert-Equal 0 $second.Calls.Count
        Assert-Equal 7 $first.Code
        Assert-Null $first.Empty
        Assert-False $properties.ContainsKey('Calls')
        Assert-Throws { New-TestCallState -Properties @{ Calls = 'overridden' } } -MessagePattern 'Calls is reserved'
    }
}

Describe 'Harness fixture mutation proofs' {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'TestHarness.psm1'))
    It 'detects a directory allocator that ignores a suite prefix' {
        Invoke-WithFunctionModule -Text $source -FunctionName New-TestDir -Find '($Prefix +' -Replace "('wbt-' +" -Body {
            $dir = New-MutTestDir -Prefix 'fixture mutation-'
            try { Assert-Throws { Assert-Match '^fixture mutation-' (Split-Path $dir -Leaf) } -MessagePattern 'does not match' }
            finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'detects a directory allocator that returns an uncreated path' {
        Invoke-WithFunctionModule -Text $source -FunctionName New-TestDir -Find 'New-Item -ItemType Directory -Force -Path $d | Out-Null' -Replace '' -Body {
            $dir = New-MutTestDir
            Assert-Throws { Assert-True (Test-Path -LiteralPath $dir -PathType Container) } -MessagePattern 'Assert-True failed'
        }
    }
}

Describe 'Checkout parent creation' {
    It 'clones into absent parents without caller-side directory setup' {
        Invoke-InTestDir { param($dir)
            $repo = Join-Path $dir 'local repository'
            & git init --quiet --initial-branch=main $repo
            Assert-Equal 0 $LASTEXITCODE
            Set-Content -LiteralPath (Join-Path $repo 'source.txt') 'fixture source'
            & git -C $repo add source.txt
            & git -C $repo -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
            Assert-Equal 0 $LASTEXITCODE
            $destination = Join-Path $dir 'missing parents/work/opencv'
            Invoke-WithEnv @{ GIT_TERMINAL_PROMPT = $null } {
                Assert-True (Invoke-GitClone -RepoUrl $repo -SourceDir $destination -Branch main -MaxAttempts 1 -InitialDelaySeconds 0)
            }
            Assert-Equal 'fixture source' (Get-Content -LiteralPath (Join-Path $destination 'source.txt'))
        }
    }
}

Describe 'Recorded native command fixtures' {
    It 'records native arguments, forwards fixture output and restores parent exit state on failure' {
        $originalExit = Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $state = New-TestCallState @{ Code = [int]$originalExit + 1 }
        Assert-Throws {
            Invoke-WithTestNativeCommand -Name Invoke-RecordedNativeFixture -FixtureState $state -Implementation {
                param($record, $argv)
                Assert-True ([object]::ReferenceEquals($state, $record))
                $argv -join '|'
            } -Body { param($record)
                Assert-Equal 'a b|c;d' (Invoke-RecordedNativeFixture 'a b' 'c;d')
                Assert-Equal $record.Code $global:LASTEXITCODE
                Assert-Equal 'a b|c;d' ($record.Calls[0] -join '|')
                throw 'native fixture failed'
            }
        } -MessagePattern 'native fixture failed'
        Assert-Equal $originalExit (Get-Variable LASTEXITCODE -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
        Assert-Null (Get-Command Invoke-RecordedNativeFixture -ErrorAction SilentlyContinue)
    }
}
