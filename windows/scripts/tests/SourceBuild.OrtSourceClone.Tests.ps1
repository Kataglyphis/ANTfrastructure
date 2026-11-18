#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
# Real disposable Git repositories cover identity, fallback, shallow recursion and failures; no network, compiler, GPU or image acceptance is covered.

Import-TestRepoModule -Name 'WindowsScripts.Shared', 'WindowsSourceBuild.Common', 'WindowsBuildDriver.Common'
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop

function New-OrtSourceFixture {
    param([string]$Directory, [string]$ActualVersion, [string]$Payload = 'pinned payload', [switch]$SingleCommit)
    $repo = New-TestGitRepository -Path (Join-Path $Directory 'origin with spaces')
    if (-not $SingleCommit) { Add-TestGitCommit -Path $repo -Files @{ VERSION_NUMBER = $ActualVersion; 'payload.txt' = 'first' } }
    Add-TestGitCommit -Path $repo -Files @{ VERSION_NUMBER = $ActualVersion; 'payload.txt' = $Payload } -Message 'release'
    $null = Invoke-TestGitCommand -Path $repo -ArgumentList @('tag', 'v1.31.1')
    $commit = @(Invoke-TestGitCommand -Path $repo -ArgumentList @('rev-parse', 'HEAD'))[-1]
    return [pscustomobject]@{
        Directory = $Directory; Repo = $repo; Commit = $commit
        Options = @{ SourceDir = Join-Path $Directory 'checkout with spaces'; Version = '1.31.1'; ExpectedCommit = $commit
            RepoUrl = $repo; FallbackRepoUrl = $repo; MaxAttempts = 1; InitialDelaySeconds = 0 }
    }
}

function Invoke-OrtSourceFixture {
    param([Parameter(Mandatory)][scriptblock]$Exercise, [string]$ActualVersion = '1.31.1')
    $fixtureExercise = $Exercise
    Invoke-InTestDir {
        param($dir)
        Invoke-WithEnv @{ GIT_ALLOW_PROTOCOL = 'file'; GIT_TERMINAL_PROMPT = '0' } {
            $fixture = New-OrtSourceFixture -Directory $dir -ActualVersion $ActualVersion
            & $fixtureExercise $fixture
        }
    }.GetNewClosure()
}

function Add-OrtSourceFixtureSubmodule {
    param($Fixture, [switch]$Missing)
    $child = (New-OrtSourceFixture -Directory (Join-Path $Fixture.Directory 'child') -ActualVersion '1.31.1' -Payload 'pinned child' -SingleCommit).Repo
    $commit = @(Invoke-TestGitCommand -Path $child -ArgumentList @('rev-parse', 'HEAD'))[-1]
    $childPath = if ($Missing) { Join-Path $Fixture.Directory 'missing child' } else { $child }
    $url = [uri]::new($childPath).AbsoluteUri
    Write-TestFileTree -Root $Fixture.Repo -Files @{ '.gitmodules' = "[submodule `"dependency`"]`npath = dependency`nurl = $url`n" }
    $null = Invoke-TestGitCommand -Path $Fixture.Repo -ArgumentList @('add', '.gitmodules')
    $null = Invoke-TestGitCommand -Path $Fixture.Repo -ArgumentList @('update-index', '--add', '--cacheinfo', "160000,$commit,dependency")
    $null = Invoke-TestGitCommand -Path $Fixture.Repo -ArgumentList @('commit', '--quiet', '-m', 'pinned submodule')
    $Fixture.Options.ExpectedCommit = @(Invoke-TestGitCommand -Path $Fixture.Repo -ArgumentList @('rev-parse', 'HEAD'))[-1]
    $Fixture.Options.RepoUrl = Join-Path $Fixture.Directory 'missing primary'
}

function Invoke-OrtFixtureClone {
    param($Fixture)
    $cloneArguments = $Fixture.Options
    Invoke-OrtSourceClone @cloneArguments 3>$null
}
Describe 'Pinned ONNX source clone' {
    It 'binds the configured 1.31.1 release to the independently recorded original commit' {
        $versions = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux/scripts/01-core/versions.env')
        Assert-Equal 'v1.31.1' $versions.ONNXRUNTIME_VERSION 'release reviewed with the source-object receipt'
        Assert-Equal '6af1a932e2286d5c58166085d24c68783033edee' $versions.ONNXRUNTIME_WINDOWS_SOURCE_COMMIT 'full historical upstream release identity'
    }

    It 'uses the primary release and never needs the invalid fallback' {
        Invoke-OrtSourceFixture {
            param($fixture)
            $fixture.Options.FallbackRepoUrl = Join-Path $fixture.Directory 'must not be used'
            Assert-Equal $true (Invoke-OrtFixtureClone -Fixture $fixture) 'primary source accepted'
            Assert-Equal 'pinned payload' (Get-Content -LiteralPath (Join-Path $fixture.Options.SourceDir 'payload.txt') -Raw) 'original content'
        }
    }
    It 'recovers the exact commit without requiring a mirror tag or full history' {
        Invoke-OrtSourceFixture {
            param($fixture)
            $fixture.Options.RepoUrl = Join-Path $fixture.Directory 'missing primary'
            $null = Invoke-TestGitCommand -Path $fixture.Repo -ArgumentList @('tag', '-d', 'v1.31.1')
            Assert-Equal $true (Invoke-OrtFixtureClone -Fixture $fixture) 'fallback source accepted'
            $actual = @(Invoke-TestGitCommand -Path $fixture.Options.SourceDir -ArgumentList @('rev-parse', 'HEAD'))[-1]
            Assert-Equal $fixture.Commit $actual 'full original commit'
            Assert-Equal 'true' (@(Invoke-TestGitCommand -Path $fixture.Options.SourceDir -ArgumentList @('rev-parse', '--is-shallow-repository'))[-1]) 'bounded history'
        }
    }
    It 'retains three primary attempts before using the pinned fallback' {
        Invoke-OrtSourceFixture {
            param($fixture)
            $cloneArguments = $fixture.Options
            $cloneArguments.Remove('MaxAttempts')
            $cloneArguments.RepoUrl = Join-Path $fixture.Directory 'missing primary'
            $warnings = @()
            $null = Invoke-OrtSourceClone @cloneArguments -WarningVariable warnings 3>$null
            Assert-Equal 3 $warnings.Count 'two retry diagnostics and the final bounded-fallback diagnostic'
            Assert-Match 'after 3 attempts' $warnings[-1].ToString() 'original primary failure retained'
        }
    }
    It 'refuses malformed pins before changing an existing destination' {
        Invoke-OrtSourceFixture {
            param($fixture)
            Write-TestFileTree -Root $fixture.Options.SourceDir -Files @{ 'keep.txt' = 'unchanged' }
            foreach ($bad in @('', '6af1a93', ('F' * 40))) {
                $fixture.Options.ExpectedCommit = $bad
                Assert-FileUnchanged -Path (Join-Path $fixture.Options.SourceDir 'keep.txt') -Action {
                    Assert-Throws { Invoke-OrtFixtureClone -Fixture $fixture } -MessagePattern 'full lowercase Git commit'
                }
            }
        }
    }
    It 'refuses malformed release names before changing an existing destination' {
        Invoke-OrtSourceFixture {
            param($fixture)
            Write-TestFileTree -Root $fixture.Options.SourceDir -Files @{ 'keep.txt' = 'unchanged' }
            $fixture.Options.Version = 'v1.31.1'
            Assert-FileUnchanged -Path (Join-Path $fixture.Options.SourceDir 'keep.txt') -Action {
                Assert-Throws { Invoke-OrtFixtureClone -Fixture $fixture } -MessagePattern 'must be a release version'
            }
        }
    }
    It 'refuses a primary tag whose commit differs from the pin' {
        Invoke-OrtSourceFixture {
            param($fixture)
            $fixture.Options.ExpectedCommit = '0' * 40
            Assert-Throws { Invoke-OrtFixtureClone -Fixture $fixture } -MessagePattern 'ONNX source commit mismatch'
        }
    }
    It 'retains a failed fallback fetch instead of reporting a clone' {
        Invoke-OrtSourceFixture {
            param($fixture)
            $fixture.Options.RepoUrl = Join-Path $fixture.Directory 'missing primary'
            $fixture.Options.ExpectedCommit = '0' * 40
            Assert-Throws { Invoke-OrtFixtureClone -Fixture $fixture } -MessagePattern 'Pinned ONNX fallback failed'
        }
    }
    It 'refuses a matching commit with the wrong release version' {
        Invoke-OrtSourceFixture -ActualVersion '1.31.0' -Exercise {
            param($fixture)
            Assert-Throws { Invoke-OrtFixtureClone -Fixture $fixture } -MessagePattern 'ONNX source version mismatch'
        }
    }
    It 'stages the actual pinned submodule through the fallback' {
        Invoke-OrtSourceFixture {
            param($fixture)
            Add-OrtSourceFixtureSubmodule -Fixture $fixture
            Assert-Equal $true (Invoke-OrtFixtureClone -Fixture $fixture) 'recursive source accepted'
            Assert-Equal 'pinned child' (Get-Content -LiteralPath (Join-Path $fixture.Options.SourceDir 'dependency/payload.txt') -Raw) 'submodule payload present'
        }
    }
    It 'refuses a submodule fetch failure even when the root commit matches' {
        Invoke-OrtSourceFixture {
            param($fixture)
            Add-OrtSourceFixtureSubmodule -Fixture $fixture -Missing
            Assert-Throws { Invoke-OrtFixtureClone -Fixture $fixture } -MessagePattern 'Pinned ONNX fallback failed'
        }
    }
    It 'checks the source unconditionally before applying any patch' {
        $null = Get-TestScriptCommandMap -ScriptPath 'windows/scripts/build/Build-OnnxFromSource.ps1' `
            -Name @('Invoke-OrtSourceClone', 'Invoke-OrtSourcePatches') -Order @('Invoke-OrtSourceClone', 'Invoke-OrtSourcePatches') `
            -UnconditionalText @{ 'Invoke-OrtSourceClone' = 'Invoke-OrtSourceClone -SourceDir $SourceDir -Version $OnnxVersion -ExpectedCommit $env:ONNXRUNTIME_WINDOWS_SOURCE_COMMIT' }
    }
}
