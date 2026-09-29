#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Build-TorchRocmFromSource.ps1's pure parts: the wheel versions and names, the version.txt check,
# torch/_rocm_init.py, the torch and torchvision build env, the libomp lookup and the runtime pins.
# NOT covered: the compile itself, which only a real rocm-lane build of Dockerfile.torch runs.

$script:TorchRocmBuilder = 'windows\scripts\build\Build-TorchRocmFromSource.ps1'

Describe 'Build-TorchRocmFromSource: versions and wheel names' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmBuilder -FunctionName 'Get-TorchRocmBuildVersion', 'Assert-TorchRocmTreeVersion', 'Get-TorchRocmWheelName')

    It 'a version pin and ROCM_WINDOWS_RELEASE make AMD''s local-version shape' {
        Assert-Equal '2.14.0+rocm10.0.0' (Get-TorchRocmBuildVersion -Version 'v2.14.0' -Release '10.0.0') 'tag with v'
        Assert-Equal '0.29.0+rocm10.0.0' (Get-TorchRocmBuildVersion -Version '0.29.0' -Release '10.0.0') 'bare version'
        foreach ($c in @(@{ V = 'v2.14'; R = '10.0.0'; P = 'x\.y\.z' }, @{ V = 'v2.14.0'; R = '10.0'; P = 'ROCM_WINDOWS_RELEASE' }, @{ V = 'nightly'; R = '10.0.0'; P = 'x\.y\.z' })) {
            Assert-Throws { Get-TorchRocmBuildVersion -Version $c.V -Release $c.R } "$($c.V) / $($c.R)" -MessagePattern $c.P
        }
    }

    It 'the commit''s version.txt must carry the pinned x.y.z, whatever suffix upstream leaves on it' {
        Assert-TorchRocmTreeVersion -Name 'PYTORCH' -VersionText "2.14.0a0`n" -Version 'v2.14.0'
        Assert-TorchRocmTreeVersion -Name 'VISION' -VersionText '0.29.0' -Version '0.29.0'
        Assert-Throws { Assert-TorchRocmTreeVersion -Name 'PYTORCH' -VersionText '2.13.0a0' -Version 'v2.14.0' } 'another release' -MessagePattern 'commit is 2\.13\.0.*pin is 2\.14\.0'
        Assert-Throws { Assert-TorchRocmTreeVersion -Name 'PYTORCH' -VersionText 'garbage' -Version 'v2.14.0' } 'unreadable' -MessagePattern 'not x\.y\.z'
    }

    It 'names the exact wheel each build must leave' {
        Assert-Equal 'torch-2.14.0+rocm10.0.0-cp314-cp314-win_amd64.whl' (Get-TorchRocmWheelName -Distribution 'torch' -BuildVersion '2.14.0+rocm10.0.0' -PythonTag 'cp314') 'torch'
    }
}

Describe 'Build-TorchRocmFromSource: the ROCm loader and the build env' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmBuilder -FunctionName 'Get-TorchRocmInitSource', 'Get-TorchRocmCommonEnv', 'Get-TorchRocmTorchEnv', 'Get-TorchRocmVisionEnv')

    It '_rocm_init.py preloads ROCm through rocm_sdk at the release, as AMD''s wheels do' {
        $src = Get-TorchRocmInitSource -Release '10.0.0'
        Assert-Match '(?m)^def initialize\(\):$' $src 'the entry torch/__init__.py calls'
        Assert-Match 'import rocm_sdk' $src 'rocm_sdk'
        Assert-Match "check_version='10\.0\.0'" $src 'held to the release'
        foreach ($lib in 'amdhip64', 'hipblaslt', 'miopen', 'rocm-openblas') { Assert-Match "'$lib'" $src "preloads $lib" }
    }

    It 'the common env points every ROCm lookup at the SDK root, with TheRock''s clang-cl and the GPU list' {
        Invoke-InTestDir { param($dir)
            [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'lib\host-math'))
            $e = Get-TorchRocmCommonEnv -RocmRoot $dir -GpuTargets 'gfx1200;gfx1201'
            foreach ($k in 'ROCM_HOME', 'ROCM_PATH') { Assert-Equal $dir $e[$k] $k }
            Assert-Equal (Join-Path $dir 'lib\cmake') $e['CMAKE_PREFIX_PATH'] 'CMAKE_PREFIX_PATH'
            Assert-Equal 'gfx1200;gfx1201' $e['PYTORCH_ROCM_ARCH'] 'PYTORCH_ROCM_ARCH'
            Assert-Equal (Join-Path $dir 'lib\llvm\bin\clang-cl.exe') $e['CXX'] 'CXX'
            Assert-Equal 'rocm-openblas' $e['OpenBLAS_LIB_NAME'] 'OpenBLAS from the SDK''s host-math'
            Assert-False $e.Contains('HIP_DEVICE_LIB_PATH') 'no bitcode dir, no HIP_DEVICE_LIB_PATH'
        }
    }

    It 'torch: HIP on, CUDA off, AOTriton and torch.distributed off, AMD''s version and runtime requirement' {
        $common = [ordered]@{ ROCM_PATH = 'C:\TheRock\build' }
        $e = Get-TorchRocmTorchEnv -Common $common -BuildVersion '2.14.0+rocm10.0.0' -Release '10.0.0' -Jobs 7
        $want = [ordered]@{ ROCM_PATH = 'C:\TheRock\build'; USE_ROCM = 'ON'; USE_CUDA = 'OFF'; USE_FLASH_ATTENTION = 'OFF'; USE_MEM_EFF_ATTENTION = 'OFF'
            USE_DISTRIBUTED = '0'; USE_GLOO = 'OFF'; BUILD_TEST = '0'; PYTORCH_BUILD_VERSION = '2.14.0+rocm10.0.0'; PYTORCH_BUILD_NUMBER = '1'
            PYTORCH_EXTRA_INSTALL_REQUIREMENTS = 'rocm[libraries]==10.0.0'; MAX_JOBS = '7' }
        foreach ($k in $want.Keys) { Assert-Equal $want[$k] $e[$k] $k }
        Assert-False $e.Contains('CMAKE_CXX_COMPILER_LAUNCHER') 'no sccache unless configured'
        $s = Get-TorchRocmTorchEnv -Common $common -BuildVersion 'x' -Release '10.0.0' -Jobs 1 -Sccache
        Assert-Equal 'sccache' $s['CMAKE_CXX_COMPILER_LAUNCHER'] 'sccache when configured'
        Assert-Equal 1 $common.Count 'the common env is copied, never changed'
    }

    It 'torchvision: HIP forced on a GPU-less host, its own version, no torch-only switches' {
        $e = Get-TorchRocmVisionEnv -Common ([ordered]@{ ROCM_HOME = 'C:\r' }) -BuildVersion '0.29.0+rocm10.0.0' -Jobs 3
        Assert-Equal '0.29.0+rocm10.0.0' $e['BUILD_VERSION'] 'BUILD_VERSION'
        Assert-Equal '1' $e['FORCE_CUDA'] 'FORCE_CUDA'
        Assert-Equal '0' $e['TORCHVISION_USE_NVJPEG'] 'nvjpeg off'
        Assert-False $e.Contains('USE_ROCM') 'no torch-only switch'
    }
}

Describe 'Build-TorchRocmFromSource: libomp and the runtime pins' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmBuilder -FunctionName 'Find-TorchRocmLibomp', 'Get-TorchRocmRuntimePin')

    It 'takes libomp140.x86_64.dll from the x64 OpenMP.LLVM redist, never debug_nonredist' {
        Invoke-InTestDir { param($dir)
            foreach ($d in 'x64\Microsoft.VC145.OpenMP.LLVM', 'debug_nonredist\x64\Microsoft.VC145.DebugOpenMP.LLVM') {
                $p = Join-Path $dir $d
                [void][System.IO.Directory]::CreateDirectory($p)
                [System.IO.File]::WriteAllText((Join-Path $p 'libomp140.x86_64.dll'), 'x')
            }
            Assert-Equal (Join-Path $dir 'x64\Microsoft.VC145.OpenMP.LLVM\libomp140.x86_64.dll') (Find-TorchRocmLibomp -RedistDir $dir) 'the redist copy'
            Assert-Throws { Find-TorchRocmLibomp -RedistDir '' } 'no VS env' -MessagePattern 'VCToolsRedistDir'
            Assert-Throws { Find-TorchRocmLibomp -RedistDir (Join-Path $dir 'debug_nonredist') } 'no x64 redist' -MessagePattern 'OpenMP\.LLVM'
        }
    }

    It 'the build venv''s runtime is versions.env''s rocm sdist + core + libraries, AMD-hosted and hash-pinned' {
        $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $p = @(Get-TorchRocmRuntimePin -Pins $pins)
        Assert-Equal 'rocm,rocm-sdk-core,rocm-sdk-libraries' (($p | ForEach-Object Distribution) -join ',') 'the three'
        foreach ($x in $p) { Assert-Match '^[0-9a-f]{64}$' $x.Sha256 $x.Distribution; Assert-True $x.Url.StartsWith('https://stable.repo.amd.com/rocm/') $x.Url }
        $bad = @{}; foreach ($k in $pins.Keys) { $bad[$k] = $pins[$k] }
        $bad['TORCH_ROCM_WINDOWS_SDK_CORE_URL'] = 'https://pypi.org/x.whl'
        Assert-Throws { @(Get-TorchRocmRuntimePin -Pins $bad) } 'off AMD' -MessagePattern 'SDK_CORE_URL must be an AMD'
        $bad = @{}; foreach ($k in $pins.Keys) { $bad[$k] = $pins[$k] }
        $bad['TORCH_ROCM_WINDOWS_ROCM_SHA256'] = 'nope'
        Assert-Throws { @(Get-TorchRocmRuntimePin -Pins $bad) } 'bad hash' -MessagePattern 'ROCM_SHA256'
    }
}
