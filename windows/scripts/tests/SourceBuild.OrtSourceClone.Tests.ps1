#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
# Real disposable Git repositories cover identity, fallback, shallow recursion and failures; no network, compiler, GPU or image acceptance is covered.

Import-TestRepoModule -Name 'WindowsScripts.Shared', 'WindowsSourceBuild.Common', 'WindowsBuildDriver.Common'
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop

Import-Module (Join-Path $PSScriptRoot 'WindowsOrt.SourceFixture.psm1') -ErrorAction Stop

Describe 'Pinned ONNX source clone' {
    It 'binds both unchanged releases to their independently recorded complete original commits' {
        $versions = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux/scripts/01-core/versions.env')
        $releases = @(Get-OrtSourceFixtureRelease)
        Assert-Equal 2 $releases.Count 'both core and GenAI source contracts'
        Assert-Equal 'VERSION_NUMBER,VERSION_INFO' (($releases | ForEach-Object { $_.VersionFile }) -join ',') 'independent version-file contracts'
        foreach ($release in $releases) {
            Assert-Equal ('v' + $release.Version) $versions[$release.VersionKey] 'unchanged reviewed release'
            Assert-Equal $release.Commit $versions[$release.Pin] 'full original release identity'
        }
    }

    It 'executes the shared fixture exercise for both release identities in order' {
        $visited = [Collections.Generic.List[string]]::new()
        Invoke-OrtSourceVariantFixture -Exercise ({
            param($fixture)
            $visited.Add($fixture.Options.Version)
        }.GetNewClosure())
        Assert-Equal '1.31.1,0.19.0' ($visited -join ',') 'both release callbacks execute'
    }

    It 'uses the primary release and never needs the invalid fallback' {
        Invoke-OrtSourceVariantFixture {
            param($fixture)
            $fixture.Options.FallbackRepoUrl = Join-Path $fixture.Directory 'must not be used'
            $expectedFile = if ($fixture.Options.Version -eq '0.19.0') { 'VERSION_INFO' } else { 'VERSION_NUMBER' }
            Assert-Equal $expectedFile $fixture.Options.VersionFile 'release-specific version file reaches the fixture'
            Assert-Equal $true (Invoke-OrtFixtureClone -Fixture $fixture) 'primary source accepted'
            Assert-Equal 'pinned payload' (Get-Content -LiteralPath (Join-Path $fixture.Options.SourceDir 'payload.txt') -Raw) 'original content'
        }
    }
    It 'recovers the exact commit without requiring a mirror tag or full history' {
        Invoke-OrtSourceVariantFixture {
            param($fixture)
            $fixture.Options.RepoUrl = Join-Path $fixture.Directory 'missing primary'
            $null = Invoke-TestGitCommand -Path $fixture.Repo -ArgumentList @('tag', '-d', "v$($fixture.Options.Version)")
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
    It 'refuses invalid commit, release and version-file selectors before changing an existing destination' {
        Invoke-OrtSourceFixture -Payload '1.31.1' -Exercise {
            param($fixture)
            Write-TestFileTree -Root $fixture.Options.SourceDir -Files @{ 'keep.txt' = 'unchanged' }
            $invalid = @(
                @{ Name = 'ExpectedCommit'; Values = @('', '6af1a93', ('F' * 40)) },
                @{ Name = 'Version'; Values = @('v1.31.1') },
                @{ Name = 'VersionFile'; Values = @('payload.txt') }
            )
            foreach ($option in $invalid) {
                $original = $fixture.Options[$option.Name]
                foreach ($value in $option.Values) {
                    $fixture.Options[$option.Name] = $value
                    Assert-FileUnchanged -Path (Join-Path $fixture.Options.SourceDir 'keep.txt') -Action {
                        Assert-Throws { Invoke-OrtFixtureClone -Fixture $fixture }
                    }
                }
                $fixture.Options[$option.Name] = $original
            }
            Assert-Throws {
                Assert-OrtSourceIdentity -SourceDir $fixture.Repo -Version '1.31.1' -ExpectedCommit $fixture.Commit -VersionFile 'payload.txt'
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
        Invoke-OrtSourceVariantFixture -WrongVersion -Exercise {
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
    It 'checks each original source unconditionally before its own patch entry point' {
        $genai = 'Invoke-OrtSourceClone -SourceDir $SourceDir -Version $OnnxGenAiVersion -ExpectedCommit $env:ONNXRUNTIME_GENAI_WINDOWS_SOURCE_COMMIT' +
            ' -RepoUrl ''https://github.com/microsoft/onnxruntime-genai.git'' -FallbackRepoUrl ''https://github.com/CodeLinaro/onnxruntime-genai.git'' -VersionFile ''VERSION_INFO'''
        $scripts = @(
            @{ Path = 'windows/scripts/build/Build-OnnxFromSource.ps1'; Patch = 'Invoke-OrtSourcePatches'
                Clone = 'Invoke-OrtSourceClone -SourceDir $SourceDir -Version $OnnxVersion -ExpectedCommit $env:ONNXRUNTIME_WINDOWS_SOURCE_COMMIT' },
            @{ Path = 'windows/scripts/build/Build-OnnxGenaiFromSource.ps1'; Patch = 'Install-GenaiSourcePatches'; Clone = $genai }
        )
        foreach ($source in $scripts) {
            $commands = @('Invoke-OrtSourceClone', $source.Patch)
            $null = Get-TestScriptCommandMap -ScriptPath $source.Path -Name $commands -Order $commands `
                -UnconditionalText @{ 'Invoke-OrtSourceClone' = $source.Clone }
        }
    }
}
