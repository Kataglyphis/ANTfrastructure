#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Real Git/ZIP fixtures cover committed bytes and transport refusals; no network, upstream patches, compilation or hardware acceptance is covered.

Import-TestRepoModule -Name 'WindowsScripts.Shared', 'WindowsSourceBuild.Common', 'WindowsBuildDriver.Common'
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop
$script:QnnSourceScript = 'windows/scripts/build/Build-OrtQnnEpFromSource.ps1'
. (Get-ScriptFunctionDefinition -ScriptPath $script:QnnSourceScript -FunctionName @('Save-OrtQnnEpCoreArchive', 'Set-OrtQnnEpCoreArchive'))

$script:QnnArchiveFiles = @{
    'fork/cmake/deps.txt' = "other;https://example.invalid/source.zip;123`nort_core;https://github.com/microsoft/onnxruntime/archive/refs/tags/v1.29.0.zip;$('a' * 40)`n"
    'archives/refs/tags/v1.29.0.zip' = 'archive bytes'
    'fork/cmake/external/onnxruntime_external_deps.cmake' = 'URL_HASH SHA1=${DEP_SHA1_ort_core}; original patch commands'
}

function Get-QnnCoreArchiveFixture {
    param([Parameter(Mandatory)][string]$Root)
    return [pscustomobject]@{ Fork = (Join-Path $Root 'fork'); Archive = (Join-Path $Root 'archives/refs/tags/v1.29.0.zip') }
}

Describe 'QNN separate ONNX header archive' {
    It 'retains the original1.29.0 commit separately from the chain1.31.1 core' {
        $versions = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux/scripts/01-core/versions.env')
        Assert-Equal '2e2543fbe9fae542f921d47a72d21d5a4ef0b710' $versions.ORT_QNN_EP_CORE_COMMIT 'historical original header release commit'
        Assert-False ($versions.ORT_QNN_EP_CORE_COMMIT -ceq $versions.ONNXRUNTIME_WINDOWS_SOURCE_COMMIT) 'separate header and runtime releases'
    }
    It 'archives only the requested committed bytes under the release directory, including paths with spaces' {
        Invoke-InTestDir {
            param($dir)
            $repo = New-TestGitRepository -Path (Join-Path $dir 'source with spaces')
            $commit = Add-TestGitCommit -Path $repo -Files @{ VERSION_NUMBER = '1.29.0'; 'include/header.h' = "original header`n" } -PassThru
            Add-TestGitCommit -Path $repo -Files @{ 'include/header.h' = 'newer release header' } -Message 'later unrelated commit'
            $null = Invoke-TestGitCommand -Path $repo -ArgumentList @('config', '--local', 'core.autocrlf', 'true')
            Write-TestFileTree -Root $repo -Files @{ 'include/header.h' = 'uncommitted change'; 'untracked.h' = 'foreign' }
            $archive = Save-OrtQnnEpCoreArchive -SourceDir $repo -Root (Join-Path $dir 'archive with spaces') -Version '1.29.0' -Commit $commit
            Assert-Match 'refs[\\/]tags[\\/]v1\.29\.0\.zip$' $archive 'the upstream version parser still recognizes the archive'
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                $entry = $zip.GetEntry('onnxruntime-1.29.0/include/header.h')
                Assert-True ($null -ne $entry) 'release root preserved'
                $reader = [IO.StreamReader]::new($entry.Open())
                try { Assert-Equal "original header`n" $reader.ReadToEnd() 'exact committed LF bytes win over mutable checkout and host autocrlf' } finally { $reader.Dispose() }
                Assert-False ([bool]($zip.Entries.FullName -match '\.git|untracked\.h')) 'no checkout metadata or foreign files'
            } finally { $zip.Dispose() }
        }
    }
    It 'fails a native archive error instead of returning a success path' {
        Invoke-InTestDir {
            param($dir)
            $repo = New-TestGitRepository -Path (Join-Path $dir 'empty source')
            Assert-Throws { Save-OrtQnnEpCoreArchive -SourceDir $repo -Root $dir -Version '1.29.0' -Commit ('0' * 40) } -MessagePattern 'QNN ort_core archive failed'
        }
    }
    It 'changes one dependency URL and its exact archive hash while preserving patch commands and other dependencies' {
        Invoke-InTestDir -Files $script:QnnArchiveFiles -Body {
            param($dir)
            $fixture = Get-QnnCoreArchiveFixture -Root $dir
            Set-OrtQnnEpCoreArchive -ForkRoot $fixture.Fork -Archive $fixture.Archive -Version '1.29.0'
            Assert-Equal 'URL_HASH SHA256=${DEP_SHA1_ort_core}; original patch commands' ([IO.File]::ReadAllText((Join-Path $fixture.Fork 'cmake/external/onnxruntime_external_deps.cmake'))) 'only the archive hash algorithm changes'
            $text = [IO.File]::ReadAllText((Join-Path $fixture.Fork 'cmake/deps.txt'))
            $digest = (Get-FileHash -LiteralPath $fixture.Archive -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-TestScriptContains -ScriptPath (Join-Path $fixture.Fork 'cmake/deps.txt') -Literal @(
                "ort_core;$($fixture.Archive -replace '\\', '/');$digest", 'other;https://example.invalid/source.zip;123') -ReasonPrefix 'retain local archive metadata and unrelated dependencies'
            Assert-MatchCount 1 '(?m)^ort_core;' $text 'exactly one core entry'
        }
    }
    It 'refuses missing, duplicate, changed-release and unverified dependency declarations before writing' {
        Invoke-InTestDir -Files $script:QnnArchiveFiles -Body {
            param($dir)
            $fixture = Get-QnnCoreArchiveFixture -Root $dir
            $path = Join-Path $fixture.Fork 'cmake/deps.txt'
            $entry = "ort_core;https://github.com/microsoft/onnxruntime/archive/refs/tags/v1.29.0.zip;$('a' * 40)"
            foreach ($invalid in @('other;x;1', "$entry`n$entry", $entry.Replace('1.29.0', '1.31.1'), $entry.Replace(('a' * 40), ('a' * 8)))) {
                [IO.File]::WriteAllText($path, $invalid)
                Assert-FileUnchanged -Path $path -Action {
                    Assert-Throws { Set-OrtQnnEpCoreArchive -ForkRoot $fixture.Fork -Archive $fixture.Archive -Version '1.29.0' } -MessagePattern 'dependency identity changed'
                }
            }
        }
    }
    It 'refuses a missing archive before changing the dependency file' {
        Invoke-InTestDir -Files $script:QnnArchiveFiles -Body {
            param($dir)
            $fixture = Get-QnnCoreArchiveFixture -Root $dir
            Remove-Item -LiteralPath $fixture.Archive
            Assert-FileUnchanged -Path (Join-Path $fixture.Fork 'cmake/deps.txt') -Action {
                Assert-Throws { Set-OrtQnnEpCoreArchive -ForkRoot $fixture.Fork -Archive $fixture.Archive -Version '1.29.0' }
            }
        }
    }
    It 'refuses a missing or duplicated core hash declaration without changing that CMake file' {
        Invoke-InTestDir -Files $script:QnnArchiveFiles -Body {
            param($dir)
            $fixture = Get-QnnCoreArchiveFixture -Root $dir
            $path = Join-Path $fixture.Fork 'cmake/external/onnxruntime_external_deps.cmake'
            foreach ($invalid in @('other hash declaration', 'URL_HASH SHA1=${DEP_SHA1_ort_core}; URL_HASH SHA1=${DEP_SHA1_ort_core}')) {
                [IO.File]::WriteAllText($path, $invalid)
                [IO.File]::WriteAllText((Join-Path $fixture.Fork 'cmake/deps.txt'), "ort_core;https://github.com/microsoft/onnxruntime/archive/refs/tags/v1.29.0.zip;$('a' * 40)")
                Assert-FileUnchanged -Path $path -Action {
                    Assert-Throws { Set-OrtQnnEpCoreArchive -ForkRoot $fixture.Fork -Archive $fixture.Archive -Version '1.29.0' } -MessagePattern 'dependency identity changed'
                }
            }
        }
    }
    It 'refuses a patch helper that returns without persisting the substitution' {
        Invoke-InTestDir -Files $script:QnnArchiveFiles -Body {
            param($dir)
            $fixture = Get-QnnCoreArchiveFixture -Root $dir
            Invoke-WithTestFunction -Name 'Edit-SourceFile' -Definition { param($Path, [switch]$Require, $Transform) $false } -Body {
                Assert-Throws { Set-OrtQnnEpCoreArchive -ForkRoot $fixture.Fork -Archive $fixture.Archive -Version '1.29.0' } -MessagePattern 'substitution did not persist'
            }
        }
    }
    It 'clones, archives and substitutes unconditionally before configure, using the separate header pin' {
        $names = @('Get-OrtQnnEpCoreVersion', 'Invoke-OrtSourceClone', 'Save-OrtQnnEpCoreArchive', 'Set-OrtQnnEpCoreArchive', 'Invoke-CmakeConfigureLogged')
        $map = Get-TestScriptCommandMap -ScriptPath $script:QnnSourceScript -Name $names -Order $names -UnconditionalText @{
            'Get-OrtQnnEpCoreVersion' = 'Get-OrtQnnEpCoreVersion -ForkRoot $forkRoot'
            'Invoke-OrtSourceClone' = 'Invoke-OrtSourceClone -SourceDir $coreSource -Version $coreVersion -ExpectedCommit $env:ORT_QNN_EP_CORE_COMMIT'
            'Save-OrtQnnEpCoreArchive' = 'Save-OrtQnnEpCoreArchive -SourceDir $coreSource -Root $SourceDir -Version $coreVersion -Commit $env:ORT_QNN_EP_CORE_COMMIT'
            'Set-OrtQnnEpCoreArchive' = 'Set-OrtQnnEpCoreArchive -ForkRoot $forkRoot -Archive $coreArchive -Version $coreVersion'
        }
        $clone = Get-TestCommandArguments -Command $map['Invoke-OrtSourceClone']
        $archive = Get-TestCommandArguments -Command $map['Save-OrtQnnEpCoreArchive']
        Assert-Equal '$coreVersion' $clone['Version'] 'the fork-declared release'
        Assert-Equal '$env:ORT_QNN_EP_CORE_COMMIT' $clone['ExpectedCommit'] 'full separate pin before checkout'
        Assert-Equal '$env:ORT_QNN_EP_CORE_COMMIT' $archive['Commit'] 'archive that same commit'
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:QnnSourceScript))
        Assert-False ($text.Contains('FETCHCONTENT_SOURCE_DIR_ORT_CORE')) 'retain CMake patch population'
    }
}

Describe 'ONNX source identity pins in the compiling stage' {
    It 'declares and exports both separate source commits in the ONNX stage' {
        $facts = Get-TestDockerfileStageFacts -Path (Join-Path (Get-RepoRoot) 'windows/Dockerfile.media-builder')
        $stage = $facts['media-core-built-onnx']
        foreach ($pin in @('ONNXRUNTIME_WINDOWS_SOURCE_COMMIT', 'ORT_QNN_EP_CORE_COMMIT')) {
            Assert-True ($stage.Args -ccontains $pin) "ONNX compile stage must declare $pin"
            Assert-True ($stage.EnvMirrored -ccontains $pin) "ONNX compile stage must export $pin"
        }
    }
}

Describe 'ONNX source identity pin routing' {
    It 'forwards both exact configured commits only to the compiling branch' {
        $core = Get-TestMediaPinContext -Branch 'media-core'
        $litert = Get-TestMediaPinContext -Branch 'media-litert'
        foreach ($pin in @('ONNXRUNTIME_WINDOWS_SOURCE_COMMIT', 'ORT_QNN_EP_CORE_COMMIT')) {
            Assert-Equal $core.Versions[$pin] $core.Branch[$pin] "the compiling branch forwards $pin"
            Assert-False ($core.Merge.Contains($pin)) "the merge excludes compile-only $pin"
            Assert-False ($litert.Branch.Contains($pin)) "unrelated branches exclude compile-only $pin"
        }
    }
}
