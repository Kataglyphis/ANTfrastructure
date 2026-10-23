#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local filesystem and exception fixtures cover harness contracts, not Windows tools or image builds.

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
