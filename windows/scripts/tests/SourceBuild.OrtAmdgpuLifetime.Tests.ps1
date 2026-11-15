#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Pinned text fixtures cover patch application, failure propagation and wiring; native ABI and GPU execution remain separate.

Import-TestRepoModule -Name 'WindowsSourceBuild.Patches'
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.CallAssertions.psm1') -ErrorAction Stop
$script:LifetimeScript = 'windows/scripts/build/Build-OrtAmdgpuEpFromSource.ps1'
$script:LifetimePatchDir = Join-Path (Get-RepoRoot) 'linux/scripts/03-media/build/onnxruntime/build/patches'
$script:LifetimeFixtureDir = Join-Path (Get-RepoRoot) 'linux/scripts/tests/fixtures/migraphx-node-compute-info'
$script:LifetimeNames = @('001-node-compute-info-lifetime.patch', '002-kernel-registry-lifetime.patch')
. (Get-ScriptFunctionDefinition -ScriptPath $script:LifetimeScript -FunctionName 'Invoke-OrtAmdgpuEpSourcePatch')

function New-AmdgpuLifetimeFixture {
    param([string]$Directory)
    $root = New-TestGitRepository -Path $Directory
    $files = @{}
    foreach ($name in @('mgx_ep.h', 'mgx_ep.cc', 'mgx_factory.h', 'mgx_factory.cc')) {
        $files['src/migraphx/' + $name] = [IO.File]::ReadAllText((Join-Path $script:LifetimeFixtureDir ($name + '.txt')))
    }
    Write-TestFileTree -Root $root -Files $files
    return $root
}

function Assert-AmdgpuLifetimeSource {
    param([string]$Directory)
    $header = [IO.File]::ReadAllText((Join-Path $Directory 'src/migraphx/mgx_ep.h'))
    Assert-Match 'virtual ~NodeComputeInfoBase\(\) = default;' $header 'typed cleanup must own both node variants'
    foreach ($name in @('NodeComputeInfo', 'EpContextNodeComputeInfo')) {
        Assert-Equal 3 ([regex]::Matches($header, [regex]::Escape("static_cast<$name*>(this_)"))).Count 'every C callback adjusts its base pointer'
    }
    $source = [IO.File]::ReadAllText((Join-Path $Directory 'src/migraphx/mgx_ep.cc'))
    Assert-True $source.Contains('delete static_cast<NodeComputeInfoBase*>(info);') 'release uses the owning virtual base'
    $factory = [IO.File]::ReadAllText((Join-Path $Directory 'src/migraphx/mgx_factory.h'))
    Assert-True $factory.Contains('mutable Ort::KernelRegistry kernel_registry_{nullptr};') 'the registry has an owning wrapper'
    Assert-True ($factory.IndexOf('data_transfer_;') -lt $factory.IndexOf('kernel_registry_{nullptr};')) 'the registry releases before data transfer'
    $source = [IO.File]::ReadAllText((Join-Path $Directory 'src/migraphx/mgx_factory.cc'))
    Assert-True $source.Contains('const std::lock_guard lock{kernel_registry_mutex_};') 'concurrent creation is serialized'
    Assert-True $source.Contains('kernel_registry_ = Ort::KernelRegistry{created};') 'successful creation transfers ownership'
}

Describe 'Windows AMD EP required lifetime corrections' {
    It 'applies the shared patches to pinned source and remains idempotent' {
        Invoke-InTestDir { param($dir)
            $tree = New-AmdgpuLifetimeFixture -Directory $dir
            Invoke-OrtAmdgpuEpSourcePatch -SourceDir $tree -PatchDir $script:LifetimePatchDir
            Assert-AmdgpuLifetimeSource -Directory $tree
            $before = @(Get-ChildItem -LiteralPath (Join-Path $tree 'src/migraphx') -File | Get-FileHash | ForEach-Object Hash) -join ','
            Invoke-OrtAmdgpuEpSourcePatch -SourceDir $tree -PatchDir $script:LifetimePatchDir
            Assert-Equal $before (@(Get-ChildItem -LiteralPath (Join-Path $tree 'src/migraphx') -File | Get-FileHash | ForEach-Object Hash) -join ',') 'a repeated patch pass does not rewrite the source'
        }
    }

    foreach ($missing in $script:LifetimeNames) {
        It "refuses a missing $missing" {
            Invoke-InTestDir { param($dir)
                $tree = New-AmdgpuLifetimeFixture -Directory (Join-Path $dir 'tree')
                $patches = Join-Path $dir 'patches'
                $null = New-Item -ItemType Directory -Path $patches
                foreach ($name in $script:LifetimeNames) {
                    if ($name -ne $missing) { Copy-Item -LiteralPath (Join-Path $script:LifetimePatchDir $name) -Destination $patches }
                }
                Assert-Throws { Invoke-OrtAmdgpuEpSourcePatch -SourceDir $tree -PatchDir $patches } -MessagePattern ([regex]::Escape($missing))
            }
        }
    }

    foreach ($case in @(
        @{ Name = 'node release'; Source = 'mgx_ep.cc'; Header = 'mgx_ep.h'; Find = 'delete info;'; Replace = 'unexpected_cleanup(info);' },
        @{ Name = 'registry creation'; Source = 'mgx_factory.cc'; Header = 'mgx_factory.h'; Find = 'kernel_registry_));'; Replace = 'changed_registry_));' }
    )) {
        It "refuses stale $($case.Name) before partially changing its header" {
            Invoke-InTestDir { param($dir)
                $tree = New-AmdgpuLifetimeFixture -Directory $dir
                $source = Join-Path $tree ('src/migraphx/' + $case.Source)
                $text = [IO.File]::ReadAllText($source)
                Assert-True $text.Contains($case.Find) 'the stale fixture must alter the intended source anchor'
                [IO.File]::WriteAllText($source, $text.Replace($case.Find, $case.Replace))
                $header = Join-Path $tree ('src/migraphx/' + $case.Header)
                $before = (Get-FileHash -LiteralPath $header).Hash
                Assert-Throws { Invoke-OrtAmdgpuEpSourcePatch -SourceDir $tree -PatchDir $script:LifetimePatchDir } -MessagePattern 'BOTH.*failed'
                Assert-Equal $before (Get-FileHash -LiteralPath $header).Hash 'failed patch preflight keeps its header unchanged'
            }
        }
    }

    It 'preserves selected patch order, source arguments and fatal child failures' {
        Invoke-WithTestNativeCommand -Name 'Invoke-RequiredSourcePatch' -FixtureState @{ Calls = [Collections.Generic.List[object]]::new(); Code = 0 } -Implementation {
            param($recordedState, $fakeArguments)
            if ($recordedState.Calls.Count -eq 2) { throw 'planted required lifetime failure' }
        } -Body {
            param($state)
            Assert-Throws { Invoke-OrtAmdgpuEpSourcePatch -SourceDir 'source with spaces' -PatchDir 'patches with spaces' } -MessagePattern 'planted required lifetime failure'
            Assert-TestRecordedArguments -Calls $state.Calls -Expected $script:LifetimeNames -ArgumentIndex 3 -Project { param($value) Split-Path $value -Leaf } -Reason 'required patch order'
            Assert-TestRecordedArguments -Calls $state.Calls -Expected @('source with spaces', 'source with spaces') -ArgumentIndex 1 -Reason 'source argument boundaries survive'
        }
    }

    It 'patches the actual primary source before resolving or configuring dependencies' {
        Assert-TestScriptCallOrder -ScriptPath $script:LifetimeScript -Name @('Save-MigraphxPrimarySource', 'Invoke-OrtAmdgpuEpSourcePatch', 'Get-MigraphxPinnedSourceSpec') `
            -Text 'Invoke-OrtAmdgpuEpSourcePatch -SourceDir $epRoot -PatchDir $PatchDir' -RequiredIndex 1
        Assert-TestAstCommand -Command @(Get-TestScriptCommands -ScriptPath $script:LifetimeScript -Name 'Initialize-OrtAmdgpuEpSeeds') `
            -Text 'Initialize-OrtAmdgpuEpSeeds -WorkDir $WorkDir -PatchDir $PatchDir' -Assignment '$seeds' -Unconditional
    }

    It 'mounts each shared patch only in the EP RUN and passes that exact directory' {
        $docker = Get-TestDockerfileStagesFromPath -Path (Join-Path (Get-RepoRoot) 'windows/Dockerfile.rocm-migraphx') -JoinContinuations -IgnoreComments -TrimLines -StrictFromHeader
        $runs = @($docker.ByName.built.Lines | Where-Object { $_ -match '^RUN ' })
        $ep = @($runs | Where-Object { $_ -match 'Build-OrtAmdgpuEpFromSource.ps1' })
        Assert-Equal 1 $ep.Count 'one EP RUN consumes the corrections'
        foreach ($name in $script:LifetimeNames) {
            $mount = "source=linux/scripts/03-media/build/onnxruntime/build/patches/$name,target=C:\bkmnt\ort-amdgpu-patches\$name,readonly"
            Assert-True $ep[0].Contains($mount) 'each canonical shared patch is mounted read-only'
            Assert-Equal 1 @($runs | Where-Object { $_.Contains($name) }).Count 'patch changes invalidate only the EP RUN'
        }
        Assert-True $ep[0].Contains("-PatchDir 'C:\bkmnt\ort-amdgpu-patches'") 'the build uses the mounted patch directory'
    }
}
