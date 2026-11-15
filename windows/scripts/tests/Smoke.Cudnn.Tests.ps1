#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Fake compilation proves discovery, required inputs and native/cross dispatch, not SDK linkage or GPU inference.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1') -Global -ErrorAction Stop

function New-CudnnSmokeFixture {
    param([string]$Directory, [bool]$Cross = $false)
    $state = @{ Root = $Directory; Cross = $Cross; Fail = $false; Probes = [Collections.ArrayList]::new(); Skips = [Collections.ArrayList]::new() }
    $prelude = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$smokeCross = $State.Cross
function Assert-EnvVarSet { param($Name) }
function Assert-DirectoryExists { param($Path, $Description) }
function Assert-ArtifactPresent { param($Root, $Filter, $Description) }
function Assert-Test { param($Name, $Condition, $FailMessage) }
function Skip-Test { param($Name) $null = $State.Skips.Add($Name) }
function Assert-NativeLinkRun {
    param($WorkName, $Source, $IncludeDirs, $LibDir, $LibName, $DllDir, [switch]$CrossLinkOnly, $Name, $ExpectMatch, $FailMessage)
    $null = $State.Probes.Add(@{} + $PSBoundParameters)
    if ($State.Fail) { throw 'fixture native link failure' }
}
'@
    @{ ScriptPath = 'windows/scripts/build/Test-Container.ps1'; FunctionName = 'Invoke-CudnnSmoke'
        FixtureState = $state; Prelude = $prelude }
}

$script:cudnnFiles = @{
    'include/cudnn.h' = 'fixture'; 'include/cudnn_aux.h' = 'fixture'
    'lib/x64/cudnn.lib' = 'fixture'; 'lib/x64/cudnn_aux.lib' = 'fixture'
    'bin/x64/cudnn64_9.dll' = 'fixture'; 'bin/x64/cudnn_helper.dll' = 'fixture'
}

function Assert-CudnnSmokeInputRefusal {
    param([hashtable]$State, [AllowNull()][object]$CudaRoot)
    Invoke-WithEnv @{ CUDNN_ROOT = $State.Root; CUDA_ROOT = $CudaRoot } {
        Assert-Throws { Invoke-MutCudnnSmoke } -MessagePattern 'cuDNN link\+run requires'
    }
    Assert-Equal 0 $State.Probes.Count
    Assert-Equal 0 $State.Skips.Count
}

function Invoke-WithCudnnSmokeFixture {
    param([scriptblock]$Exercise, [bool]$Cross = $false)
    Invoke-InTestDir -Prefix 'wbt-cudnn [sdk] ' -Files $script:cudnnFiles -Body { param($dir)
        $fixture = New-CudnnSmokeFixture $dir $Cross
        Invoke-WithFunctionModule @fixture -Body $Exercise
    }
}

Describe 'Required cuDNN smoke probe' {
    foreach ($cross in $false, $true) {
        It "discovers nested exact files and retains link/run policy (cross=$cross)" {
            Invoke-WithCudnnSmokeFixture -Cross $cross -Exercise { param($state)
                    Invoke-WithEnv @{ CUDNN_ROOT = $state.Root; CUDA_ROOT = $state.Root; VCToolsInstallDir = $null } { Invoke-MutCudnnSmoke }
                    Assert-Equal 1 $state.Probes.Count 'cuDNN probe did not run'
                    Assert-Equal 0 $state.Skips.Count 'required cuDNN probe cannot skip'
                    $probe = $state.Probes[0]
                    Assert-Equal 'cudnn.lib' $probe.LibName
                    Assert-Equal (Join-Path $state.Root 'lib/x64') $probe.LibDir
                    Assert-Equal (Join-Path $state.Root 'bin/x64') $probe.DllDir
                    Assert-Equal ((Join-Path $state.Root include) + '|' + (Join-Path $state.Root include)) ($probe.IncludeDirs -join '|')
                    Assert-Match 'cudnnGetVersion\(\)' $probe.Source
                    Assert-Equal $state.Cross $probe.ContainsKey('CrossLinkOnly') 'native execution and cross link/PE policies must remain distinct'
                    if ($state.Cross) { Assert-True $probe.CrossLinkOnly }
                    Assert-Equal 'cudnn' $probe.ExpectMatch
            }
        }
    }

    It 'refuses each missing main artifact despite similarly named SDK siblings' {
        Invoke-WithCudnnSmokeFixture -Exercise { param($state)
            foreach ($relative in 'include/cudnn.h', 'lib/x64/cudnn.lib', 'bin/x64/cudnn64_9.dll') {
                $path = Join-Path $state.Root $relative
                Remove-Item -LiteralPath $path
                try {
                    Assert-CudnnSmokeInputRefusal -State $state -CudaRoot $state.Root
                } finally { Set-Content -LiteralPath $path -Value fixture }
            }
        }
    }

    It 'refuses a missing CUDA root and propagates link failure' {
        Invoke-WithCudnnSmokeFixture -Exercise { param($state)
                Assert-CudnnSmokeInputRefusal -State $state -CudaRoot $null
                $state.Fail = $true
                Invoke-WithEnv @{ CUDNN_ROOT = $state.Root; CUDA_ROOT = $state.Root } {
                    Assert-Throws { Invoke-MutCudnnSmoke } -MessagePattern 'fixture native link failure'
                }
        }
    }
}
