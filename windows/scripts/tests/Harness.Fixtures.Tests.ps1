#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local filesystem and exception fixtures cover harness contracts, not Windows tools or image builds.

function Assert-FixtureTreeContent {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][Collections.IDictionary]$Expected)
    if ($Expected.Count -eq 0) { throw 'Expected must contain at least one file' }
    foreach ($entry in (Get-TestFileTreeEntry -Root $Root -Files $Expected)) {
        Assert-Equal $entry.Text ([IO.File]::ReadAllText($entry.Path)) "exact fixture bytes: $($entry.Path)"
    }
}

function Assert-MutationFactoryRefused {
    param([Parameter(Mandatory)][scriptblock]$Factory, [Parameter(Mandatory)][string]$MessagePattern,
        [string]$Expected = 'recipe failure')
    Assert-Throws {
        Invoke-TestFunctionMutations -ModuleArgumentsFactory $Factory -Find old -Replace new -Expected $Expected -Body { throw 'body must not execute' }
    } -MessagePattern $MessagePattern
}

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

    It 'preserves a suite prefix and literal file paths while accepting an empty file map' {
        $dir = New-TestDir -Prefix 'fixture space-' -Files ([ordered]@{ 'nested [parent]/exact.txt' = "fixture`nbytes"; 'empty.txt' = '' })
        try {
            Assert-True (Test-Path -LiteralPath $dir -PathType Container)
            Assert-Match '^fixture space-[a-f0-9]{32}$' (Split-Path $dir -Leaf)
            Assert-Equal "fixture`nbytes" ([IO.File]::ReadAllText((Join-Path $dir 'nested [parent]/exact.txt')))
            Assert-FixtureTreeContent -Root $dir -Expected @{ 'nested [parent]/exact.txt' = "fixture`nbytes"; 'empty.txt' = '' }
            $empty = New-TestDir -Files @{}
            try { Assert-True (Test-Path -LiteralPath $empty -PathType Container) }
            finally { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue }
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'removes the allocated directory when file initialization fails and propagates that failure' {
        Invoke-DirectoryCleanupProbe { param($state)
            Invoke-WithFunctionModule -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName New-TestDir -Prefix Init -FixtureState $state `
                -Prelude 'function Write-TestFileTree { param($Root, $Files); $State.Path = $Root; throw "file initialization sentinel" }' -Body {
                    param($record)
                    Assert-Throws { New-InitTestDir -Files @{ 'requested.txt' = 'content' } } -MessagePattern 'file initialization sentinel'
                    Assert-NotNull $record.Path
                    Assert-False (Test-Path -LiteralPath $record.Path) 'failed initialization must not leak its root'
                }
        }
    }

    It 'propagates a directory allocation error before file initialization or a body can report success' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/tests/TestHarness.psm1' -FunctionName New-TestDir -Prefix Allocation `
            -Prelude 'function New-Item { param($ItemType, [switch]$Force, $Path, $ErrorAction); Write-Error "directory allocation sentinel" -ErrorAction $ErrorAction }' -Body {
                Assert-Throws { New-AllocationTestDir } -MessagePattern 'directory allocation sentinel'
            }
    }

    It 'cleans up after a failing body and clears a previous native exit code' {
        Invoke-DirectoryCleanupProbe { param($state)
            $global:LASTEXITCODE = 17
            Assert-Throws {
                Invoke-InTestDir -Prefix 'failing fixture-' -Files @{ 'nested/file.txt' = 'fixture bytes' } -Body { param($dir)
                    $state.Path = $dir
                    Assert-Match '^failing fixture-' (Split-Path $dir -Leaf)
                    $state.Exit = $global:LASTEXITCODE
                    Assert-Equal 'fixture bytes' ([IO.File]::ReadAllText((Join-Path $dir 'nested/file.txt')))
                    throw 'fixture body failed'
                }
            } -MessagePattern 'fixture body failed'
            Assert-Equal 0 $state.Exit
            Assert-False (Test-Path -LiteralPath $state.Path)
        }
    }
}

Describe 'Harness text trees' {
    It 'projects ordered literal paths and string values without creating files' {
        Invoke-InTestDir { param($dir)
            $root = Join-Path $dir 'uncreated tree'
            $entries = @(Get-TestFileTreeEntry -Root $root -Files ([ordered]@{ 'first [leaf]/a.txt' = 'MiXeD'; 'empty.txt' = $null; 'number.txt' = 42 }))
            Assert-Equal 3 $entries.Count
            Assert-Equal (Join-Path $root 'first [leaf]/a.txt') $entries[0].Path
            Assert-Equal (Join-Path $root empty.txt) $entries[1].Path
            Assert-Equal (Join-Path $root number.txt) $entries[2].Path
            Assert-Equal 'MiXeD||42' (($entries | ForEach-Object { $_.Text }) -join '|')
            Assert-Equal 0 @(Get-TestFileTreeEntry -Root $root -Files @{}).Count
            Assert-False (Test-Path -LiteralPath $root)
        }
    }

    It 'creates nested parents, preserves exact contents and overwrites existing files without output' {
        Invoke-InTestDir { param($dir)
            $root = Join-Path $dir 'absent tree'
            $content = "first line`nsecond line"
            $result = @(Write-TestFileTree -Root $root -Files ([ordered]@{ 'nested [folder]\file.txt' = $content; 'empty.txt' = '' }))
            Assert-Equal 0 $result.Count
            Assert-Equal $content ([IO.File]::ReadAllText((Join-Path $root 'nested [folder]\file.txt')))
            Assert-FixtureTreeContent -Root $root -Expected @{ 'nested [folder]/file.txt' = $content; 'empty.txt' = '' }
            Write-TestFileTree -Root $root -Files @{ 'nested [folder]\file.txt' = 'replacement' }
            Assert-FixtureTreeContent -Root $root -Expected @{ 'nested [folder]/file.txt' = 'replacement' }
        }
    }
}

Describe 'Exact fixture content verdicts' {
    It 'refuses empty expectations, absent files and wrong bytes despite unrelated valid files' {
        Invoke-InTestDir -Files @{ 'present.txt' = 'fixture content' } -Body { param($dir)
            Assert-FixtureTreeContent -Root $dir -Expected @{ 'present.txt' = 'fixture content' }
            Assert-Throws { Assert-FixtureTreeContent -Root $dir -Expected @{} } -MessagePattern 'at least one file'
            Assert-Throws { Assert-FixtureTreeContent -Root $dir -Expected @{ 'missing.txt' = '' } } -MessagePattern 'missing.txt'
            Assert-Throws { Assert-FixtureTreeContent -Root $dir -Expected @{ 'present.txt' = 'wrong content' } } -MessagePattern 'exact fixture bytes'
        }
    }
}

Describe 'Batch fixture bytes' {
    It 'writes exact ASCII CRLF bytes and retains caller branches before the requested final exit' {
        Invoke-InTestDir { param($dir)
            $null = New-TestBatchFixture -Directory $dir
            $early = New-TestBatchTool -Directory $dir -Name early.cmd -Line 'exit /b 3' -ExitCode 7
            $expectedEarly = "@echo off`r`nexit /b 3`r`nexit /b 7`r`n"
            Assert-TestBatchFile -Path $early -Expected $expectedEarly
        }
    }

    Invoke-TestBatchToolMutationCases -Body {
        param($path)
        Assert-TestBatchFile -Path $path -Expected "@echo off`r`necho caller-marker`r`nexit /b 7`r`n"
    }
}

Describe 'Copied module fixture closures' {
    It 'copies the exact transitive sibling set from a literal path without unrelated modules or output' {
        Invoke-InTestDir { param($dir)
            $source = Join-Path $dir 'source [modules]'
            $target = Join-Path $dir 'destination [modules]'
            $rootText = "Import-Module (Join-Path `$PSScriptRoot 'Fixture.Leaf.psm1')"
            Write-TestFileTree -Root $source -Files @{ 'Fixture.Root.psm1' = $rootText; 'Fixture.Leaf.psm1' = 'leaf bytes'; 'Unrelated.psm1' = 'not in closure' }
            Assert-Equal 0 @(Copy-TestModuleClosure -Seed Fixture.Root -Destination $target -ModuleRoot $source).Count
            Assert-Equal 'Fixture.Leaf.psm1,Fixture.Root.psm1' ((Get-ChildItem -LiteralPath $target -File | Sort-Object Name | ForEach-Object Name) -join ',')
            Assert-Equal $rootText ([IO.File]::ReadAllText((Join-Path $target Fixture.Root.psm1)))
            Assert-Equal 'leaf bytes' ([IO.File]::ReadAllText((Join-Path $target Fixture.Leaf.psm1)))
        }
    }

    It 'refuses missing seeds or companions before creating a partial destination' {
        Invoke-InTestDir -Files @{ 'source/Fixture.Root.psm1' = "Import-Module (Join-Path `$PSScriptRoot 'Missing.Leaf.psm1')" } -Body { param($dir)
            $source = Join-Path $dir source
            $target = Join-Path $dir destination
            Assert-Throws { Copy-TestModuleClosure -Seed Missing.Seed -Destination $target -ModuleRoot $source } -MessagePattern 'Required test module missing:.*Missing.Seed'
            Assert-Throws { Copy-TestModuleClosure -Seed Fixture.Root -Destination $target -ModuleRoot $source } -MessagePattern 'Required test module missing:.*Missing.Leaf'
            Assert-False (Test-Path -LiteralPath $target)
        }
    }
}

Describe 'Deferred batch tool setup' {
    It 'retains independent tool policies after their private construction scope exits' {
        $factory = New-Module -ScriptBlock {
            param($path)
            Import-Module $path -DisableNameChecking
            $lines = [string[]]@('echo DEFERRED [%~1]')
            $first = New-TestBatchToolSetup -Name 'one [tool].cmd' -Line $lines -ExitCode 7
            $lines[0] = 'echo caller array changed'
            [pscustomobject]@{ First = $first; Second = (New-TestBatchToolSetup -Name two.cmd -Line 'exit /b 3' -ExitCode 9) }
        } -ArgumentList (Join-Path $PSScriptRoot TestHarness.psm1) -ReturnResult
        Invoke-InTestDir { param($dir)
            $firstPath = & $factory.First $dir
            $secondPath = & $factory.Second $dir
            Assert-Equal (Join-Path $dir 'one [tool].cmd') $firstPath
            Assert-Equal (Join-Path $dir two.cmd) $secondPath
            Assert-TestBatchFile -Path $firstPath -Expected "@echo off`r`necho DEFERRED [%~1]`r`nexit /b 7`r`n"
            Assert-TestBatchFile -Path $secondPath -Expected "@echo off`r`nexit /b 3`r`nexit /b 9`r`n"
            if ($IsWindows) {
                Assert-Equal 'DEFERRED [a b]' ((& $firstPath 'a b') | Out-String).Trim()
                Assert-Equal 7 $global:LASTEXITCODE
                & $secondPath
                Assert-Equal 3 $global:LASTEXITCODE
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
        Invoke-TestFunctionMutations -IncludeControl -ModuleArguments $arguments -Case @(
            @{ Find = '{ 1 }'; Replace = '{ 2 }'; Expected = 'value verdict' },
            @{ Find = '{ 1 }'; Replace = '{ 3 }'; Expected = 'value verdict' }
        ) -Body {
            param($record, $argument)
            Assert-Equal 'body argument' $argument
            $record.Calls.Add((Get-Command Get-MutTableFixture).Module.Path)
            Assert-Equal 1 (Get-MutTableFixture) 'value verdict'
        }
        Assert-Equal 3 $state.Calls.Count
        foreach ($path in $state.Calls) { Assert-False (Test-Path -LiteralPath $path) }
        Assert-Null (Get-Command Get-MutTableFixture -ErrorAction SilentlyContinue)
    }

    It 'fails a broken control before running mutants and validates required control exceptions' {
        $state = New-TestCallState
        Assert-Throws {
            Invoke-TestFunctionMutations -IncludeControl -Find '{ 1 }' -Replace '{ 2 }' -Expected 'control verdict' `
                -ModuleArguments @{ Text = 'function Get-ControlFixture { 1 }'; FixtureState = $state } -Body {
                    param($record)
                    $record.Calls.Add((Get-MutControlFixture))
                    Assert-Equal 2 (Get-MutControlFixture) 'control verdict'
                }
        } -MessagePattern 'control verdict'
        Assert-Equal '1' ($state.Calls -join ',') 'a failed baseline cannot count as a killed mutation'
        Invoke-TestFunctionMutations -IncludeControl -ModuleArguments @{ Text = 'function Invoke-ControlException { throw "required sentinel" }' } `
            -Find 'throw "required sentinel"' -Replace '$null' -Throws '^required sentinel$' -Body { Invoke-MutControlException }
    }

    It 'owns the factory workspace across controls and mutants and rejects ambiguous or invalid recipes' {
        $factoryRecord = New-TestCallState -Properties @{ Root = '' }
        $factory = {
            param($dir)
            $factoryRecord.Root = $dir
            @{ Text = 'function Get-FactoryFixture { 1 }'; BodyArgumentList = @($factoryRecord, $dir) }
        }.GetNewClosure()
        Invoke-TestFunctionMutations -ModuleArgumentsFactory $factory -IncludeControl -Find '{ 1 }' -Replace '{ 2 }' -Expected 'factory value verdict' -Body {
            param($record, $directory)
            Assert-True (Test-Path -LiteralPath $directory -PathType Container)
            $record.Calls.Add((Get-MutFactoryFixture))
            Assert-Equal 1 (Get-MutFactoryFixture) 'factory value verdict'
        }
        Assert-Equal '1,2' ($factoryRecord.Calls -join ',')
        Assert-False (Test-Path -LiteralPath $factoryRecord.Root)
        foreach ($mixed in @(@{ ModuleArguments = @{} }, @{ ScriptPath = 'source.ps1' }, @{ FunctionName = 'Get-FactoryFixture' }, @{ BodyArgumentList = @() })) {
            Assert-Throws { Invoke-TestFunctionMutations -ModuleArgumentsFactory {} @mixed -Body {} } -MessagePattern 'cannot be mixed'
        }
        foreach ($invalid in @({ }, { 1; 2 })) {
            Assert-MutationFactoryRefused -Factory $invalid -MessagePattern 'return exactly one dictionary'
        }
    }

    It 'cleans the workspace when the recipe factory fails before any mutation verdict' {
        $factoryRecord = [pscustomobject]@{ Root = '' }
        $factory = { param($dir) $factoryRecord.Root = $dir; throw 'factory failure sentinel' }.GetNewClosure()
        Assert-MutationFactoryRefused -Factory $factory -Expected 'factory failure sentinel' -MessagePattern '^factory failure sentinel$'
        Assert-False (Test-Path -LiteralPath $factoryRecord.Root)
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
        Invoke-WithFunctionModule -Text $source -FunctionName New-TestDir -Find '$null = New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop' -Replace '' -Body {
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
