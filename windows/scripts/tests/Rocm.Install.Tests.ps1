#requires -Version 7.0
# Windows ROCm (Install-Rocm.ps1, Dockerfile.rocm, Test-RocmImage.ps1): URL guard, amd64 and
# fork-base refusals, layout gate, env contract, toolchain shadowing, PATH rule. NOT covered:
# the download, the extraction, hipcc itself and the driver wiring (Driver.Variant.Tests.ps1).

Describe 'Install-Rocm: tarball URL' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Get-RocmWindowsTarballUrl')

    It 'builds AMD''s documented tarball URL for a family and release' {
        Assert-Equal 'https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx120X-all-10.0.0.tar.gz' `
            (Get-RocmWindowsTarballUrl -Release '10.0.0' -GfxFamily 'gfx120X-all') 'gfx120X-all URL'
        Assert-Equal 'https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-multiarch-10.0.0.tar.gz' `
            (Get-RocmWindowsTarballUrl -Release '10.0.0' -GfxFamily 'multiarch') 'multiarch URL'
    }

    It 'refuses a release that is not a full x.y.z (versions.env ROCM_VERSION is only x.y)' {
        foreach ($bad in @('', '10.0', 'v10.0.0', '10.0.0-rc1')) {
            Assert-Throws { Get-RocmWindowsTarballUrl -Release $bad -GfxFamily 'gfx120X-all' } "release '$bad'" -MessagePattern 'ROCM_WINDOWS_RELEASE'
        }
    }

    It 'refuses anything that is not a GPU family name, including path tricks' {
        foreach ($bad in @('', 'amd', 'rocm', 'GFX120X-ALL', 'gfx120X-all/../x', 'gfx120X-all.tar.gz?', 'gfx 120X')) {
            Assert-Throws { Get-RocmWindowsTarballUrl -Release '10.0.0' -GfxFamily $bad } "family '$bad'" -MessagePattern 'ROCM_WINDOWS_GFX_FAMILY'
        }
    }
}

Describe 'Install-Rocm: target arch' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Assert-RocmTargetArch')

    It 'accepts amd64' {
        Assert-RocmTargetArch -TargetArch 'amd64'
        Assert-True $true 'amd64 passed'
    }

    It 'refuses arm64 and anything else: AMD ships no Windows arm64 ROCm' {
        foreach ($bad in @('arm64', 'x64', '')) {
            Assert-Throws { Assert-RocmTargetArch -TargetArch $bad } "arch '$bad'" -MessagePattern 'amd64-only'
        }
    }
}

Describe 'Install-Rocm: layout gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Assert-RocmWindowsLayout')

    # What the gate requires, as the 10.0.0 gfx120X-all tarball ships it.
    $script:RocmRequired = @('bin\hipcc.exe', 'bin\hipconfig.exe', 'bin\hipInfo.exe', 'bin\amdhip64_7.dll',
        'include\hip\hip_runtime.h', 'lib\llvm\bin\clang.exe', 'lib\llvm\amdgcn\bitcode\ocml.bc', '.info\version')
    # The gate reports these two by their glob; every other piece by its own path.
    $script:RocmGlobMessage = @{ 'bin\amdhip64_7.dll' = 'amdhip64_\*\.dll'; 'lib\llvm\amdgcn\bitcode\ocml.bc' = 'bitcode\\\*\.bc' }
    function New-FakeRocmTree {
        param([string]$Root, [string[]]$Skip = @(), [string]$Version = '10.0.0')
        foreach ($rel in @($script:RocmRequired | Where-Object { $_ -ne '.info\version' })) {
            if ($Skip -contains $rel) { continue }
            $p = Join-Path $Root $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
            Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
        }
        if ($Skip -notcontains '.info\version') {
            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.info') | Out-Null
            Set-Content -LiteralPath (Join-Path $Root '.info\version') -Value $Version -Encoding ASCII
        }
    }

    It 'passes a complete tree' {
        Invoke-InTestDir { param($dir)
            New-FakeRocmTree -Root $dir
            Assert-RocmWindowsLayout -Root $dir -Release '10.0.0'
            Assert-True $true 'complete tree passed'
        }
    }

    It 'fails, naming the piece, when any one required piece is missing' {
        foreach ($rel in $script:RocmRequired) {
            $pattern = @($script:RocmGlobMessage[$rel], [regex]::Escape($rel)) | Where-Object { $_ } | Select-Object -First 1
            Invoke-InTestDir { param($dir)
                New-FakeRocmTree -Root $dir -Skip @($rel)
                Assert-Throws { Assert-RocmWindowsLayout -Root $dir -Release '10.0.0' } "missing $rel" -MessagePattern $pattern
            }
        }
    }

    It 'fails when the tree is a different release than the pin' {
        Invoke-InTestDir { param($dir)
            New-FakeRocmTree -Root $dir -Version '9.9.9'
            Assert-Throws { Assert-RocmWindowsLayout -Root $dir -Release '10.0.0' } 'version mismatch' -MessagePattern "says '9\.9\.9'"
        }
    }
}

Describe 'Install-Rocm: fork base (rocm forks from the DEFAULT media only)' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Assert-RocmForkBase')

    It 'accepts a default-media base (no GPU_TYPE, or GPU_TYPE=cpu, and no CUDA env)' {
        Assert-RocmForkBase -GpuType '' -CudaRoot '' -CudaPath ''
        Assert-RocmForkBase -GpuType 'cpu' -CudaRoot '' -CudaPath ''
        Assert-True $true 'default bases passed'
    }

    It 'refuses a CUDA-lineage base, naming every leaked variable' {
        Assert-Throws { Assert-RocmForkBase -GpuType 'nvidia' -CudaRoot '' -CudaPath '' } 'GPU_TYPE=nvidia' -MessagePattern 'GPU_TYPE=nvidia'
        Assert-Throws { Assert-RocmForkBase -GpuType '' -CudaRoot 'C:\cuda' -CudaPath '' } 'CUDA_ROOT' -MessagePattern 'CUDA_ROOT=C:\\cuda'
        Assert-Throws { Assert-RocmForkBase -GpuType 'nvidia' -CudaRoot 'C:\a' -CudaPath 'C:\b' } 'all three' -MessagePattern 'CUDA_PATH=C:\\b, CUDA_ROOT=C:\\a, GPU_TYPE=nvidia'
    }
}

Describe 'Test-RocmImage: env contract' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-RocmImage.ps1' -FunctionName 'Get-RocmImageEnvFinding')
    function New-RocmGoodEnv {
        return @{ HIP_PATH = 'C:\TheRock\build'; ROCM_PATH = 'C:\TheRock\build'; HIP_PLATFORM = 'amd'; GPU_TYPE = 'rocm'
            HIP_DEVICE_LIB_PATH = 'C:\TheRock\build\lib\llvm\amdgcn\bitcode'; ROCM_WINDOWS_RELEASE = '10.0.0' }
    }

    It 'has no finding for the env Dockerfile.rocm sets' {
        Assert-Equal 0 @(Get-RocmImageEnvFinding -Environment (New-RocmGoodEnv)).Count 'good env'
    }

    It 'reports each broken piece of the contract' {
        $cases = @(
            @{ Key = 'HIP_PATH'; Value = $null; Pattern = 'HIP_PATH is not set' },
            @{ Key = 'ROCM_WINDOWS_RELEASE'; Value = ''; Pattern = 'ROCM_WINDOWS_RELEASE is not set' },
            @{ Key = 'GPU_TYPE'; Value = 'nvidia'; Pattern = "GPU_TYPE is 'nvidia'" },
            @{ Key = 'HIP_PLATFORM'; Value = 'nvidia'; Pattern = "HIP_PLATFORM is 'nvidia'" },
            @{ Key = 'ROCM_PATH'; Value = 'C:\elsewhere'; Pattern = 'differ' },
            @{ Key = 'CUDA_PATH'; Value = 'C:\cuda'; Pattern = 'CUDA lineage leaked' }
        )
        foreach ($c in $cases) {
            $e = New-RocmGoodEnv
            $e[$c.Key] = $c.Value
            $got = @(Get-RocmImageEnvFinding -Environment $e)
            Assert-Equal 1 $got.Count "exactly one finding for $($c.Key)"
            Assert-Match $c.Pattern $got[0] "finding for $($c.Key)"
        }
    }
}

Describe 'Test-RocmImage: AMD''s LLVM must not shadow the image toolchain' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-RocmImage.ps1' -FunctionName 'Get-RocmShadowFinding')

    It 'passes when every tool resolves outside ROCm (or not at all)' {
        $resolved = @{ 'clang-cl' = 'C:\Users\x\scoop\apps\llvm\current\bin\clang-cl.exe'; 'lld-link' = $null
            'clang' = 'C:\TheRock\buildx\bin\clang.exe' }   # a sibling dir sharing the prefix is NOT inside
        Assert-Equal 0 @(Get-RocmShadowFinding -Resolved $resolved -RocmRoot 'C:\TheRock\build').Count 'no shadow'
    }

    It 'flags a tool that resolves into ROCm''s tree, case-insensitively' {
        $got = @(Get-RocmShadowFinding -Resolved @{ 'clang-cl' = 'c:\therock\BUILD\lib\llvm\bin\clang-cl.exe' } -RocmRoot 'C:\TheRock\build\')
        Assert-Equal 1 $got.Count 'one shadowed tool'
        Assert-Match 'clang-cl resolves into ROCm' $got[0] 'names the tool'
    }
}

Describe 'Dockerfile.rocm: PATH and pins' {
    $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.rocm')
    $pathValue = [regex]::Match($df, '(?m)\bPATH="([^"]*)"').Groups[1].Value

    It 'appends ROCm''s bin AFTER the inherited PATH (its flatc.exe / OpenCL.dll must not shadow the image''s)' {
        Assert-Match '^\$\{PATH\};' $pathValue 'inherited PATH first'
        Assert-Match 'C:\\TheRock\\build\\bin$' $pathValue 'ROCm bin last'
    }

    It 'never puts AMD''s LLVM on PATH (lib\llvm\bin holds its own clang-cl.exe)' {
        # Instructions only: the header comment names lib\llvm\bin on purpose.
        $code = ($df -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        Assert-False ($code -match '(?i)llvm\\bin') 'lib\llvm\bin must not appear in any Dockerfile.rocm instruction'
    }

    It 'fails closed on the SHA256: the script refuses an empty or malformed pin' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\host\Install-Rocm.ps1')
        Assert-Match '\$TarballSha256 -notmatch ''\^\[0-9a-fA-F\]\{64\}\$''' $src 'SHA256 shape guard present'
        Assert-Match '-ExpectedSha256 \$TarballSha256' $src 'download verified against the pin'
    }
}
