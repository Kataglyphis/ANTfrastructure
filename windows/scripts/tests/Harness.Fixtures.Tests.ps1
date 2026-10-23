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
                Invoke-InTestDir { param($dir)
                    $state.Path = $dir
                    $state.Exit = $global:LASTEXITCODE
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
}

Describe 'Harness exception assertions' {
    It 'requires an exception and matches its message without accepting a different error' {
        Assert-Throws { throw 'expected failure' } -MessagePattern '^expected failure$'
        Assert-Throws { Assert-Throws { } } -MessagePattern 'expected an exception but none was thrown'
        Assert-Throws { Assert-Throws { throw 'other failure' } -MessagePattern '^expected failure$' } -MessagePattern 'does not match'
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
