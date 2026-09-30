#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
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

Describe 'Build-TorchRocmFromSource: the steps both RUNs share' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmBuilder -FunctionName 'Save-TorchRocmTree', 'Assert-TorchRocmTreeVersion',
        'Get-TorchRocmPythonTag', 'Install-TorchRocmBuiltWheel', 'Get-TorchRocmWheelName')

    It 'fetches the commit its key pins and holds the tree''s version.txt to the version key' {
        Invoke-InTestDir { param($dir)
            function git { }
            function Save-GitCommitSource { param($Name, $Repository, $Commit, $WorkDir)
                $src = Join-Path $WorkDir $Name; [void][System.IO.Directory]::CreateDirectory($src)
                [System.IO.File]::WriteAllText((Join-Path $src 'version.txt'), "0.29.0a0`n"); [System.IO.File]::WriteAllText((Join-Path $src 'commit'), $Commit)
                return $src
            }
            $src = Invoke-WithEnv @{ T_COMMIT = ' abc123 '; T_VERSION = '0.29.0' } { Save-TorchRocmTree -Name 'vision' -Repository 'r' -CommitKey 'T_COMMIT' -VersionKey 'T_VERSION' -WorkDir $dir }
            Assert-Equal 'abc123' ([System.IO.File]::ReadAllText((Join-Path $src 'commit'))) 'the trimmed commit pin'
            Assert-Throws { Invoke-WithEnv @{ T_COMMIT = 'abc'; T_VERSION = '0.30.0' } { Save-TorchRocmTree -Name 'vision' -Repository 'r' -CommitKey 'T_COMMIT' -VersionKey 'T_VERSION' -WorkDir $dir } } `
                'another release' -MessagePattern 'T_COMMIT commit is 0\.29\.0.*pin is 0\.30\.0'
        }
    }

    It 'reads the venv''s cpXY tag and refuses anything else' {
        function fakepy { $script:FakeTag }
        $script:FakeTag = 'cp314'
        Assert-Equal 'cp314' (Get-TorchRocmPythonTag -Python 'fakepy') 'the tag'
        $script:FakeTag = 'Traceback'
        Assert-Throws { Get-TorchRocmPythonTag -Python 'fakepy' } 'no tag' -MessagePattern "reports tag 'Traceback'"
    }

    It 'installs and imports the exact wheel the build left, and refuses a build that left none' {
        Invoke-InTestDir { param($dir)
            $script:Logged = [System.Collections.Generic.List[string]]::new()
            function Invoke-TorchRocmLogged { param($CommandLine, $WorkingDir, $LogName) $script:Logged.Add("$LogName :: $CommandLine") }
            $name = 'torchvision-0.29.0+rocm10.0.0-cp314-cp314-win_amd64.whl'
            $arg = @{ Python = 'py'; SourceDir = $dir; Distribution = 'torchvision'; BuildVersion = '0.29.0+rocm10.0.0'; PythonTag = 'cp314'; WorkDir = $dir; LogPrefix = 'tv'; ImportCode = 'import torchvision' }
            Assert-Throws { Install-TorchRocmBuiltWheel @arg } 'no wheel' -MessagePattern 'torchvision build left no'
            Assert-Equal 0 $script:Logged.Count 'nothing installed without the wheel'
            [void][System.IO.Directory]::CreateDirectory((Join-Path $dir 'dist'))
            [System.IO.File]::WriteAllText((Join-Path $dir "dist\$name"), 'x')
            Assert-Equal (Join-Path $dir "dist\$name") (Install-TorchRocmBuiltWheel @arg) 'returns the wheel'
            Assert-Match "^tv-install\.log :: uv pip install --python ""py"" --no-deps "".*$([regex]::Escape($name))""$" $script:Logged[0] 'install'
            Assert-Equal 'tv-import.log :: "py" -c "import torchvision"' $script:Logged[1] 'import in the build venv'
        }
    }
}

Describe 'Build-TorchRocmFromSource: the ROCm loader and the build env' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmBuilder -FunctionName 'Get-TorchRocmInitSource', 'Get-TorchRocmCommonEnv', 'Get-TorchRocmTorchEnv', 'Get-TorchRocmVisionEnv', 'Copy-TorchRocmEnv')

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

Describe 'Build-TorchRocmFromSource: libomp, the venv shim and the runtime pins' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmBuilder -FunctionName 'Assert-TorchRocmSystemLibomp', 'Copy-TorchRocmVenvShim', 'Get-TorchRocmRuntimePin')

    It 'the build venv gets the base sitecustomize.py (win-amd64 tag) and python3.dll, and refuses without the shim' {
        Invoke-InTestDir { param($dir)
            $site = Join-Path $dir 'cpython\Lib\site-packages'; $pyDir = Join-Path $dir 'cpython\PCbuild\amd64'; $venv = Join-Path $dir 'venv'
            foreach ($d in $site, $pyDir, (Join-Path $venv 'Lib\site-packages'), (Join-Path $venv 'Scripts')) { [void][System.IO.Directory]::CreateDirectory($d) }
            [System.IO.File]::WriteAllText((Join-Path $pyDir 'python3.dll'), 'x')
            Assert-Throws { Copy-TorchRocmVenvShim -BaseSitePackages $site -BasePythonDir $pyDir -Venv $venv } 'no shim' -MessagePattern 'win32'
            [System.IO.File]::WriteAllText((Join-Path $site 'sitecustomize.py'), 'shim')
            Copy-TorchRocmVenvShim -BaseSitePackages $site -BasePythonDir $pyDir -Venv $venv
            Assert-Equal 'shim' ([System.IO.File]::ReadAllText((Join-Path $venv 'Lib\site-packages\sitecustomize.py'))) 'sitecustomize.py'
            Assert-True (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python3.dll')) 'python3.dll'
        }
    }

    It 'requires the OpenMP runtime torch_cpu.dll imports in System32, where the image''s VS install puts it' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Assert-TorchRocmSystemLibomp -System32 $dir } 'missing' -MessagePattern 'libomp140\.x86_64\.dll is missing.*import torch'
            [System.IO.File]::WriteAllText((Join-Path $dir 'libomp140.x86_64.dll'), 'x')
            Assert-Equal (Join-Path $dir 'libomp140.x86_64.dll') (Assert-TorchRocmSystemLibomp -System32 $dir) 'found'
        }
    }

    It 'each RUN leaves exactly the wheels it owns in the output: torch, then torch and torchvision' {
        . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmBuilder -FunctionName 'Assert-TorchRocmStagedWheel')
        Invoke-InTestDir { param($dir)
            $t = 'torch-2.14.0+rocm10.0.0-cp314-cp314-win_amd64.whl'; $v = 'torchvision-0.29.0+rocm10.0.0-cp314-cp314-win_amd64.whl'
            [System.IO.File]::WriteAllText((Join-Path $dir $t), 'x')
            Assert-TorchRocmStagedWheel -OutputDir $dir -Name $t
            Assert-Throws { Assert-TorchRocmStagedWheel -OutputDir $dir -Name $t, $v } 'torchvision missing' -MessagePattern 'expected exactly'
            [System.IO.File]::WriteAllText((Join-Path $dir $v), 'x')
            Assert-TorchRocmStagedWheel -OutputDir $dir -Name $v, $t
            [System.IO.File]::WriteAllText((Join-Path $dir 'torch-2.13.0-cp314-cp314-win_amd64.whl'), 'x')
            Assert-Throws { Assert-TorchRocmStagedWheel -OutputDir $dir -Name $t, $v } 'a stray wheel' -MessagePattern 'torch-2\.13\.0'
        }
    }

    It 'the torchvision RUN keeps the torch RUN''s venv and brings the PIL that import torchvision needs' {
        $src = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TorchvisionRocmFromSource.ps1'))
        Assert-False ($src -match '(?m)^\s*\$\w+\s*=\s*Start-MigraphxBuildSession') 'no Start-MigraphxBuildSession: it resets -WorkDir, where the venv is'
        Assert-Match "Build-TorchRocmFromSource\.ps1'\) -OutputDir \`$OutputDir -WorkDir \`$WorkDir" $src 'dot-sources the torch builder with its own parameters'
        Assert-Match 'uv pip install --python ""\$venvPy"" pillow' $src 'pillow into the build venv'
        $torch = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:TorchRocmBuilder))
        Assert-Match "Complete-MigraphxBuildSession [^\r\n]*-WorkDir \`$torchSrc" $torch 'the torch RUN removes only its tree, not the venv'
    }

    It 'the torch wheel carries no MSVC OpenMP DLL (VS 18 lists it only under debug_nonredist)' {
        $src = [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:TorchRocmBuilder))
        Assert-False ($src -match 'force-include\.torch/lib/libomp') 'no force-include of libomp140'
        Assert-False ($src -match 'Copy-Item[^\r\n]*libomp') 'no copy of libomp140 into torch\lib'
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
