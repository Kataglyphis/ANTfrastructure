#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
# Disposable release repositories share source and sparse-patch fixtures; they do not prove upstream network, compilation or hardware acceptance.
Set-StrictMode -Version Latest
foreach ($fixtureImport in 'TestHarness.psm1', 'WindowsHarness.GitFixtures.psm1') {
    Import-Module (Join-Path $PSScriptRoot $fixtureImport) -DisableNameChecking -ErrorAction Stop
}
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/WindowsSourceBuild.Common.psm1') -ErrorAction Stop

function New-OrtSourceFixture {
    param([string]$Directory, [string]$ActualVersion, [string]$Payload = 'pinned payload', [switch]$SingleCommit, [string]$PayloadPath = 'payload.txt',
        [string]$VersionFile = 'VERSION_NUMBER', [string]$Version = '1.31.1')
    $repo = New-TestGitRepository -Path (Join-Path $Directory 'origin with spaces')
    if (-not $SingleCommit) { Add-TestGitCommit -Path $repo -Files @{ $VersionFile = $ActualVersion; $PayloadPath = 'first' } }
    $commit = Add-TestGitCommit -Path $repo -Files @{ $VersionFile = $ActualVersion; $PayloadPath = $Payload } -Message 'release' -PassThru
    $null = Invoke-TestGitCommand -Path $repo -ArgumentList @('tag', "v$Version")
    return [pscustomobject]@{
        Directory = $Directory; Repo = $repo; Commit = $commit
        Options = @{ SourceDir = Join-Path $Directory 'checkout with spaces'; Version = $Version; VersionFile = $VersionFile; ExpectedCommit = $commit
            RepoUrl = $repo; FallbackRepoUrl = $repo; MaxAttempts = 1; InitialDelaySeconds = 0 }
    }
}

function Invoke-OrtSourceFixture {
    param([Parameter(Mandatory)][scriptblock]$Exercise, [string]$ActualVersion = '1.31.1',
        [string]$Payload = 'pinned payload', [string]$PayloadPath = 'payload.txt',
        [string]$VersionFile = 'VERSION_NUMBER', [string]$Version = '1.31.1')
    $factory = Get-Command New-OrtSourceFixture -CommandType Function
    Invoke-InTestDir -FixtureArgumentList @($factory, $Exercise, $ActualVersion, $Payload, $PayloadPath, $VersionFile, $Version) -Body {
        param($dir, $createFixture, $fixtureExercise, $fixtureVersion, $fixturePayload, $fixturePayloadPath, $fixtureVersionFile, $fixtureRelease)
        Invoke-WithEnv @{ GIT_ALLOW_PROTOCOL = 'file'; GIT_TERMINAL_PROMPT = '0' } {
            $fixture = & $createFixture -Directory $dir -ActualVersion $fixtureVersion -Payload $fixturePayload -PayloadPath $fixturePayloadPath -VersionFile $fixtureVersionFile -Version $fixtureRelease
            & $fixtureExercise $fixture
        }.GetNewClosure()
    }
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

function Get-OrtSourceFixtureRelease {
    return @(
        @{ Version = '1.31.1'; VersionFile = 'VERSION_NUMBER'; VersionKey = 'ONNXRUNTIME_VERSION'
            Pin = 'ONNXRUNTIME_WINDOWS_SOURCE_COMMIT'; Commit = '6af1a932e2286d5c58166085d24c68783033edee'; Stage = 'media-core-built-onnx' },
        @{ Version = '0.19.0'; VersionFile = 'VERSION_INFO'; VersionKey = 'ONNXRUNTIME_GENAI_VERSION'
            Pin = 'ONNXRUNTIME_GENAI_WINDOWS_SOURCE_COMMIT'; Commit = 'd01b2441a72d4e3223415b9b08474c6e65fbc028'; Stage = 'media-core-built' }
    )
}

function Invoke-OrtSourceVariantFixture {
    param([Parameter(Mandatory)][scriptblock]$Exercise, [switch]$WrongVersion)
    foreach ($release in Get-OrtSourceFixtureRelease) {
        $actualVersion = if ($WrongVersion) { '0.0.0' } else { $release.Version }
        Invoke-OrtSourceFixture -VersionFile $release.VersionFile -Version $release.Version -ActualVersion $actualVersion -Exercise $Exercise
    }
}

Export-ModuleMember -Function Get-OrtSourceFixtureRelease, Invoke-OrtSourceVariantFixture, New-OrtSourceFixture, Invoke-OrtSourceFixture, Add-OrtSourceFixtureSubmodule, Invoke-OrtFixtureClone
