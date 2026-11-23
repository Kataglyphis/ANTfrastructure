#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Real pinned source fixtures prove patch application and wiring, not Windows compilation or GPU inference.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.CallAssertions.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSourceBuild.Patches.psm1') -ErrorAction Stop

$script:PadPatchRelative = 'shared/upstream/migraphx/patches/0001-preserve-zero-pad-maxpool.patch'
$script:PadPatch = Join-Path (Get-RepoRoot) $script:PadPatchRelative
$script:PadBuilder = 'windows/scripts/build/Build-MigraphxFromSource.ps1'
$script:PadFixture = Join-Path $PSScriptRoot 'fixtures/migraphx-95672916-source.zip'
$script:PadManifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/migraphx-95672916-source.json') -Raw | ConvertFrom-Json -AsHashtable
$script:PadExpected = @{
    'src/eliminate_pad.cpp' = 'dbd4862fd03e28e04daa13b30490d7b6e1c29191bc8153201e97d44a34c879b6'
    'test/eliminate_pad_test.cpp' = 'bc392ecec9c465d6de2af610a8162debcddf99c6f15135a155bcc09fc2b964d7'
}

function Invoke-MigraphxPadFixture {
    param([Parameter(Mandatory)][scriptblock]$Body)
    Invoke-InTestDir -Prefix 'migraphx-pad-' -Body {
        param($root)
        [IO.Compression.ZipFile]::ExtractToDirectory($script:PadFixture, $root)
        $null = New-TestGitRepository -Path $root
        $null = Invoke-TestGitCommand -Path $root -ArgumentList @('config', '--local', 'core.autocrlf', 'false')
        & $Body $root
    }
}

function Assert-MigraphxPadFiles {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Expected)
    foreach ($file in $Expected.Keys) {
        Assert-Equal $Expected[$file] (Get-FileHash -LiteralPath (Join-Path $Root $file) -Algorithm SHA256).Hash.ToLowerInvariant() "exact $file bytes"
    }
}

Describe 'MIGraphX explicit zero padding before pooling' {
    It 'binds the immutable original specimens to the actual Windows source pin and original license' {
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux/scripts/01-core/versions.env')
        Assert-Equal $pins.MIGRAPHX_WINDOWS_COMMIT $script:PadManifest.Commit 'fixture matches selected upstream commit'
        Assert-Equal $script:PadManifest.ArchiveSha256 (Get-FileHash -LiteralPath $script:PadFixture -Algorithm SHA256).Hash.ToLowerInvariant() 'immutable archive bytes'
        Invoke-MigraphxPadFixture {
            param($root)
            Assert-MigraphxPadFiles -Root $root -Expected $script:PadManifest.Files
        }
    }

    It 'applies the required production patch to both real upstream files and reapplies idempotently' {
        Invoke-MigraphxPadFixture {
            param($root)
            foreach ($attempt in 1..2) {
                Invoke-RequiredSourcePatch -PatchFile $script:PadPatch -SourceDir $root
                Assert-MigraphxPadFiles -Root $root -Expected $script:PadExpected
            }
        }
    }

    It 'refuses a missing required patch' {
        Invoke-MigraphxPadFixture {
            param($root)
            Assert-Throws { Invoke-RequiredSourcePatch -PatchFile (Join-Path $root 'absent.patch') -SourceDir $root } -MessagePattern 'BOTH the .patch and the inline fallback failed'
        }
    }

    It 'refuses upstream drift rather than silently building the old optimization' {
        Invoke-MigraphxPadFixture {
            param($root)
            [IO.File]::WriteAllText((Join-Path $root 'src/eliminate_pad.cpp'), 'deliberate incompatible source')
            Assert-Throws { Invoke-RequiredSourcePatch -PatchFile $script:PadPatch -SourceDir $root } -MessagePattern 'BOTH the .patch and the inline fallback failed'
        }
    }

    It 'refuses a partial patch application when the upstream regression target is absent' {
        Invoke-MigraphxPadFixture {
            param($root)
            Remove-Item -LiteralPath (Join-Path $root 'test/eliminate_pad_test.cpp')
            Assert-Throws { Invoke-RequiredSourcePatch -PatchFile $script:PadPatch -SourceDir $root } -MessagePattern 'BOTH the .patch and the inline fallback failed'
            Assert-Equal $script:PadManifest.Files['src/eliminate_pad.cpp'] (Get-FileHash -LiteralPath (Join-Path $root 'src/eliminate_pad.cpp') -Algorithm SHA256).Hash.ToLowerInvariant() 'failed patch leaves source unchanged'
        }
    }

    It 'patches the primary tree unconditionally after version reading and before dependency builds' {
        Assert-TestScriptCallOrder -ScriptPath $script:PadBuilder -Name @('Save-MigraphxPrimarySource', 'Get-MigraphxTreeFact', 'Invoke-RequiredSourcePatch', 'Save-GitCommitSource') `
            -Text 'Invoke-RequiredSourcePatch -PatchFile $PadPoolingPatchFile -SourceDir $sourceRoot' -RequiredIndex 2 -Unconditional
        $call = @(Get-TestScriptCommands -ScriptPath $script:PadBuilder -Name 'Invoke-RequiredSourcePatch')[0]
        $bound = Get-TestCommandArguments -Command $call
        Assert-Equal '$PadPoolingPatchFile' $bound.PatchFile 'selected patch argument'
        Assert-Equal '$sourceRoot' $bound.SourceDir 'actual downloaded source argument'
    }

    It 'resolves the same shared patch for a direct repository invocation' {
        $ast = Get-TestScriptAst -ScriptPath $script:PadBuilder
        Assert-TestScriptParameterDefault -Ast $ast -Name 'PadPoolingPatchFile' `
            -Text "(Join-Path `$PSScriptRoot '..\..\..\shared\upstream\migraphx\patches\0001-preserve-zero-pad-maxpool.patch')"
    }

    It 'mounts the exact patch only in the MIGraphX RUN and passes its mounted path' {
        $contract = @{
            Path = 'windows/Dockerfile.rocm-migraphx'; ScriptLeaf = 'Build-MigraphxFromSource.ps1'
            Mount = @(@{ Text = "source=$script:PadPatchRelative,target=C:\bkmnt\migraphx-pad-pool.patch,readonly"; Exclusive = $script:PadPatchRelative })
            ArgumentText = @("-PadPoolingPatchFile 'C:\bkmnt\migraphx-pad-pool.patch'")
        }
        Assert-TestDockerfileBuildMounts @contract
    }
}
