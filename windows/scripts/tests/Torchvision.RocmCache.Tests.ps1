#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Tests cache wiring and fatal patch drift, not actual compilation, HIP kernels or wheel contents.
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.CallAssertions.psm1') -ErrorAction Stop -DisableNameChecking
$script:VisionCacheBuilder = 'windows/scripts/build/Build-TorchvisionRocmFromSource.ps1'

Describe 'Torchvision ROCm host compiler cache' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:VisionCacheBuilder -FunctionName 'Enable-TorchvisionRocmCompilerCache')

    It 'patches only the build venv and preserves the compiler path used by ABI probes' {
        function Invoke-RequiredSourcePatch { param($PatchFile, $SourceDir) $script:VisionPatchArgs = @($PatchFile, $SourceDir) }
        $buildEnv = @{ CC = 'sdk compiler'; CXX = 'sdk compiler'; MAX_JOBS = '7' }
        $script:VisionPatchArgs = @()
        Enable-TorchvisionRocmCompilerCache -WorkDir 'work with spaces' -BuildEnv $buildEnv -SccachePath 'cache with spaces/sccache.exe' -PatchRoot 'assets/patches'
        Assert-Equal (Join-Path 'assets/patches' 'pytorch/001-torchvision-host-sccache.patch') $script:VisionPatchArgs[0] 'reviewed patch'
        Assert-Equal (Join-Path 'work with spaces' 'venv/Lib/site-packages') $script:VisionPatchArgs[1] 'only build venv'
        Assert-Equal 'cache with spaces/sccache.exe' $buildEnv['TORCHVISION_CXX_COMPILER_LAUNCHER'] 'one launcher executable'
        Assert-Equal 'sdk compiler' $buildEnv['CC'] 'CC untouched'
        Assert-Equal 'sdk compiler' $buildEnv['CXX'] 'CXX remains a real compiler'
        Assert-Equal '7' $buildEnv['MAX_JOBS'] 'parallelism retained'
        Assert-False $buildEnv.ContainsKey('PYTORCH_NVCC') 'no HIP compiler wrapper'
    }

    It 'keeps the existing no-sccache path without patching or adding a launcher' {
        function Invoke-RequiredSourcePatch { throw 'must not patch without sccache' }
        $buildEnv = @{ CXX = 'compiler' }
        Enable-TorchvisionRocmCompilerCache -WorkDir 'work' -BuildEnv $buildEnv -SccachePath '' -PatchRoot 'patches'
        Assert-Equal 1 $buildEnv.Count 'environment unchanged'
        Assert-Equal 'compiler' $buildEnv['CXX'] 'compiler retained'
    }

    It 'retains patch failure and cannot wire a launcher after upstream drift' {
        function Invoke-RequiredSourcePatch { throw 'upstream patch drift' }
        $buildEnv = @{ CXX = 'compiler' }
        Assert-Throws { Enable-TorchvisionRocmCompilerCache -WorkDir 'work' -BuildEnv $buildEnv -SccachePath 'sccache' -PatchRoot 'patches' } 'patch failure' -MessagePattern 'upstream patch drift'
        Assert-False $buildEnv.ContainsKey('TORCHVISION_CXX_COMPILER_LAUNCHER') 'failed patch is not accepted'
    }

    It 'wires the helper before publishing the process environment and building the wheel' {
        $wire = @(Get-TestScriptCommands -ScriptPath $script:VisionCacheBuilder -Name 'Enable-TorchvisionRocmCompilerCache')
        Assert-TestAstCommand -Command $wire -Text "Enable-TorchvisionRocmCompilerCache -WorkDir `$WorkDir -BuildEnv `$visionEnv -SccachePath `$sccachePath -PatchRoot (Join-Path `$scriptAssetRoot 'patches')" -Unconditional
        $publish = @(Get-TestScriptCommands -ScriptPath $script:VisionCacheBuilder -Name 'Set-TorchRocmProcessEnv')
        $wheel = @(Get-TestScriptCommands -ScriptPath $script:VisionCacheBuilder -Name 'Invoke-TorchRocmLogged' | Where-Object { $_.Extent.Text.Contains('setup.py bdist_wheel') })
        Assert-Equal 1 $publish.Count 'one environment publication'
        Assert-Equal 1 $wheel.Count 'one wheel build'
        Assert-TestAstOrder -Before $wire[0] -After $publish[0]
        Assert-TestAstOrder -Before $publish[0] -After $wheel[0]
    }
}
