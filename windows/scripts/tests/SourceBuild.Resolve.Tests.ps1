#requires -Version 7.0
# Tests for the pure resolver/version helpers: version precedence, CUDA arch decoration,
# and TensorRT root resolution (unset / empty / versioned-subdir / flat layouts).

Describe 'Get-SourceBuildVersion' {

    It 'an explicit value wins over env and default' {
        Invoke-WithEnv @{ MY_VER = 'from-env' } {
            Assert-Equal 'explicit' (Get-SourceBuildVersion -Value 'explicit' -EnvironmentVariables @('MY_VER') -DefaultValue 'def')
        }
    }

    It 'falls back to the first non-empty environment variable' {
        Invoke-WithEnv @{ FIRST = ''; SECOND = 'v9' } {
            Assert-Equal 'v9' (Get-SourceBuildVersion -EnvironmentVariables @('FIRST', 'SECOND') -DefaultValue 'def')
        }
    }

    It 'uses the default when value and env are empty' {
        Invoke-WithEnv @{ MISSING = '' } {
            Assert-Equal 'def' (Get-SourceBuildVersion -EnvironmentVariables @('MISSING') -DefaultValue 'def')
        }
    }

    It 'treats a whitespace-only value as empty' {
        Assert-Equal 'def' (Get-SourceBuildVersion -Value '   ' -DefaultValue 'def')
    }
}

Describe 'Get-CudaArchitectureList' {

    It 'returns the canonical default when CUDA_ARCHITECTURES is unset' {
        Invoke-WithEnv @{ CUDA_ARCHITECTURES = '' } {
            Assert-Equal '86;87;89;120' (Get-CudaArchitectureList)
        }
    }

    It 'honours the CUDA_ARCHITECTURES override' {
        Invoke-WithEnv @{ CUDA_ARCHITECTURES = '75;89' } {
            Assert-Equal '75;89' (Get-CudaArchitectureList)
        }
    }

    It 'decorates each architecture with the suffix' {
        Invoke-WithEnv @{ CUDA_ARCHITECTURES = '80;86' } {
            Assert-Equal '80-real;86-real' (Get-CudaArchitectureList -Decoration '-real')
        }
    }
}

Describe 'Resolve-TensorRtRoot' {

    It 'returns $null when TENSORRT_ROOT is unset' {
        Invoke-WithEnv @{ TENSORRT_ROOT = '' } {
            Assert-Null (Resolve-TensorRtRoot)
        }
    }

    It 'returns $null when the root does not exist' {
        Invoke-WithEnv @{ TENSORRT_ROOT = 'X:\does\not\exist\trt' } {
            Assert-Null (Resolve-TensorRtRoot)
        }
    }

    It 'returns $null for an empty root directory (graceful no-TensorRT skip)' {
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } { Assert-Null (Resolve-TensorRtRoot) }
        }
    }

    It 'returns the versioned TensorRT-* subdirectory when present' {
        Invoke-InTestDir { param($dir)
            $sub = Join-Path $dir 'TensorRT-10.5.0.18'
            New-Item -ItemType Directory -Force -Path $sub | Out-Null
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } {
                Assert-Equal $sub (Resolve-TensorRtRoot)
            }
        }
    }

    It 'returns the root itself for a flat layout (no TensorRT-* subdir)' {
        Invoke-InTestDir { param($dir)
            Set-Content -Path (Join-Path $dir 'nvinfer.lib') -Value '' -NoNewline
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } {
                Assert-Equal $dir (Resolve-TensorRtRoot)
            }
        }
    }

    # Backlog #38: Set-TensorrtTree.ps1 renames the extracted tree to a
    # stable 'current' so Dockerfile.nvidia's runtime PATH never spells the pin
    # (deriving it from TENSORRT_VERSION put a nonexistent dir on PATH and
    # silently killed the ORT TensorRT EP). The resolver must agree with that
    # PATH, and must still handle pre-normalization trees.
    It "prefers the stable 'current' directory (backlog #38)" {
        Invoke-InTestDir { param($dir)
            $stable = Join-Path $dir 'current'
            New-Item -ItemType Directory -Force -Path $stable | Out-Null
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } {
                Assert-Equal $stable (Resolve-TensorRtRoot)
            }
        }
    }

    It "prefers 'current' OVER a leftover versioned dir (both present)" {
        Invoke-InTestDir { param($dir)
            $stable = Join-Path $dir 'current'
            New-Item -ItemType Directory -Force -Path $stable | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'TensorRT-10.5.0.18') | Out-Null
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } {
                Assert-Equal $stable (Resolve-TensorRtRoot)
            }
        }
    }
}

Describe 'Get-CudnnLibrary' {

    # Helper: build <root>\lib\x64 and drop the named empty .lib files into it.
    function Initialize-CudnnRoot {
        param([string]$Root, [string[]]$Libs)
        $x64 = Join-Path $Root 'lib\x64'
        New-Item -ItemType Directory -Force -Path $x64 | Out-Null
        foreach ($l in $Libs) { Set-Content -Path (Join-Path $x64 $l) -Value '' -NoNewline }
    }

    It 'returns $null for an empty/whitespace root' {
        Assert-Null (Get-CudnnLibrary -CudnnRoot '')
        Assert-Null (Get-CudnnLibrary -CudnnRoot '   ')
    }

    It 'returns $null when the root does not exist' {
        Assert-Null (Get-CudnnLibrary -CudnnRoot 'X:\does\not\exist\cudnn')
    }

    It 'returns $null when lib\x64 holds no cudnn*.lib' {
        Invoke-InTestDir { param($dir)
            Initialize-CudnnRoot -Root $dir -Libs @('somethingelse.lib')
            Assert-Null (Get-CudnnLibrary -CudnnRoot $dir)
        }
    }

    It 'prefers cudnn.lib over the 9.x split sub-libs' {
        Invoke-InTestDir { param($dir)
            Initialize-CudnnRoot -Root $dir -Libs @('cudnn_adv.lib', 'cudnn.lib', 'cudnn_graph.lib')
            Assert-Equal 'cudnn.lib' (Split-Path (Get-CudnnLibrary -CudnnRoot $dir) -Leaf)
        }
    }

    It 'falls back to a sub-lib when cudnn.lib is absent' {
        Invoke-InTestDir { param($dir)
            Initialize-CudnnRoot -Root $dir -Libs @('cudnn_graph.lib')
            Assert-Equal 'cudnn_graph.lib' (Split-Path (Get-CudnnLibrary -CudnnRoot $dir) -Leaf)
        }
    }

    It 'picks lib\x64 natively and lib\arm64 for the cross target (#176)' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'lib\x64') | Out-Null
            Set-Content -Path (Join-Path $dir 'lib\x64\cudnn.lib') -Value '' -NoNewline
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'lib\arm64') | Out-Null
            Set-Content -Path (Join-Path $dir 'lib\arm64\cudnn.lib') -Value '' -NoNewline
            Assert-Equal (Join-Path $dir 'lib\x64') (Get-CudnnLibraryDir -CudnnRoot $dir -Arch 'amd64')
            Assert-Equal (Join-Path $dir 'lib\arm64') (Get-CudnnLibraryDir -CudnnRoot $dir -Arch 'arm64')
            Assert-Equal (Join-Path $dir 'lib\arm64\cudnn.lib') (Get-CudnnLibrary -CudnnRoot $dir -Arch 'arm64')
        }
    }

    It 'returns $null when only the OTHER arch dir exists -- no silent x64 fallback on cross' {
        Invoke-InTestDir { param($dir)
            Initialize-CudnnRoot -Root $dir -Libs @('cudnn.lib')
            Assert-Null (Get-CudnnLibrary -CudnnRoot $dir -Arch 'arm64')
        }
    }
}

Describe 'Get-NvccHostCompilerPath' {

    It 'returns the x64-hosted arm64 cl for the cross target when VCToolsInstallDir has it' {
        Invoke-InTestDir { param($dir)
            $cl = Join-Path $dir 'bin\Hostx64\arm64\cl.exe'
            New-Item -ItemType Directory -Force -Path (Split-Path $cl -Parent) | Out-Null
            Set-Content -Path $cl -Value '' -NoNewline
            Invoke-WithEnv @{ VCToolsInstallDir = $dir } {
                Assert-Equal $cl (Get-NvccHostCompilerPath -Arch 'arm64')
            }
        }
    }
}

Describe 'Test-CudaWindowsArm64Payload' {

    It 'is false for a missing root and for a root without the full payload' {
        Assert-False (Test-CudaWindowsArm64Payload -CudaRoot 'X:\no-such-cuda-root-xyzzy')
        Invoke-InTestDir { param($dir)
            Assert-False (Test-CudaWindowsArm64Payload -CudaRoot $dir)
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'lib\arm64') | Out-Null
            Set-Content -Path (Join-Path $dir 'lib\arm64\cudart.lib') -Value '' -NoNewline
            Assert-False (Test-CudaWindowsArm64Payload -CudaRoot $dir)  # cudadevrt.lib still missing
        }
    }

    It 'is true when cudart.lib AND cudadevrt.lib are staged' {
        Invoke-InTestDir { param($dir)
            $arm = Join-Path $dir 'lib\arm64'
            New-Item -ItemType Directory -Force -Path $arm | Out-Null
            Set-Content -Path (Join-Path $arm 'cudart.lib') -Value '' -NoNewline
            Set-Content -Path (Join-Path $arm 'cudadevrt.lib') -Value '' -NoNewline
            Assert-True (Test-CudaWindowsArm64Payload -CudaRoot $dir)
        }
    }
}

Describe 'Get-GpuEnvironment -ForceCpuEnvVar' {

    It 'short-circuits to a CPU-only environment when the named var is 1 (all GPU paths null)' {
        Invoke-WithEnv @{ ONNX_FORCE_CPU = '1'; GPU_TYPE = 'nvidia' } {
            $r = Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU'
            Assert-Equal 'cpu' $r.GpuType
            Assert-Null $r.CudaRoot
            Assert-Null $r.CudnnRoot
            Assert-Null $r.TensorRtRoot
            Assert-Null $r.CudaBin
        }
    }

    It 'returns all five contract keys in the forced-CPU hashtable (CudaBin included)' {
        Invoke-WithEnv @{ GENAI_FORCE_CPU = '1' } {
            $r = Get-GpuEnvironment -ForceCpuEnvVar 'GENAI_FORCE_CPU'
            foreach ($k in 'GpuType', 'CudaRoot', 'CudnnRoot', 'TensorRtRoot', 'CudaBin') {
                Assert-True ($r.ContainsKey($k)) "missing key $k"
            }
        }
    }

    It 'the force override wins over GPU_TYPE=nvidia' {
        Invoke-WithEnv @{ ONNX_FORCE_CPU = '1'; GPU_TYPE = 'nvidia' } {
            Assert-Equal 'cpu' (Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU').GpuType
        }
    }

    It 'does NOT short-circuit when the named var is not 1 (normal detection runs)' {
        # var present but '0' -> the guard must not fire; GPU_TYPE=amd flows through untouched
        # (the nvidia-only PATH/CUDA_PATH side effects never run for a non-nvidia type).
        Invoke-WithEnv @{ ONNX_FORCE_CPU = '0'; GPU_TYPE = 'amd'; TENSORRT_ROOT = '' } {
            Assert-Equal 'amd' (Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU').GpuType
        }
    }

    It 'defaults to cpu detection when neither ForceCpuEnvVar nor GPU_TYPE is set' {
        Invoke-WithEnv @{ GPU_TYPE = ''; TENSORRT_ROOT = '' } {
            Assert-Equal 'cpu' (Get-GpuEnvironment).GpuType
        }
    }

    It 'THROWS on GPU_TYPE=nvidia with no resolvable CUDA root (#45 fail-closed gate)' {
        # The nvidia lane bakes GPU_TYPE=nvidia into the image, so "nvidia but
        # no CUDA" is always a mis-plumbed path - every consumer would take
        # its quiet CPU-only else-branch for ~2.5 h of green-and-useless work.
        Invoke-WithEnv @{ GPU_TYPE = 'nvidia'; CUDA_ROOT = ''; CUDA_PATH = 'C:\does\not\exist-45'; TENSORRT_ROOT = '' } {
            Assert-Throws { Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU' } `
                -MessagePattern 'mis-plumbed CUDA path' `
                'nvidia without CUDA must fail closed, not degrade to CPU'
        }
    }

    It 'the FORCE_CPU opt-out still beats the #45 gate (deliberate CPU builds stay legal)' {
        Invoke-WithEnv @{ GPU_TYPE = 'nvidia'; CUDA_ROOT = ''; CUDA_PATH = 'C:\does\not\exist-45'; ONNX_FORCE_CPU = '1' } {
            Assert-Equal 'cpu' (Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU').GpuType
        }
    }

    It 'GPU_TYPE=rocm with a HIP tree: HasRocm, RocmRoot set, HasCuda false' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'lib\cmake\hip') | Out-Null
            Invoke-WithEnv @{ GPU_TYPE = 'rocm'; HIP_PATH = $dir; ROCM_PATH = $null; TENSORRT_ROOT = '' } {
                $r = Get-GpuEnvironment
                Assert-True $r.HasRocm 'HasRocm'
                Assert-Equal $dir $r.RocmRoot 'RocmRoot'
                Assert-False $r.HasCuda 'HasCuda'
            }
        }
    }

    It 'THROWS on GPU_TYPE=rocm without a HIP tree (the rocm twin of #45)' {
        Invoke-WithEnv @{ GPU_TYPE = 'rocm'; HIP_PATH = 'C:\does\not\exist-rocm'; ROCM_PATH = $null; TENSORRT_ROOT = '' } {
            Assert-Throws { Get-GpuEnvironment } -MessagePattern 'GPU_TYPE=rocm but no ROCm tree' 'rocm without HIP must fail closed'
        }
    }

    It 'HasRocm is false on the cpu and nvidia lanes and under FORCE_CPU' {
        Invoke-WithEnv @{ GPU_TYPE = ''; TENSORRT_ROOT = '' } { Assert-False (Get-GpuEnvironment).HasRocm 'cpu lane' }
        Invoke-WithEnv @{ GPU_TYPE = 'rocm'; HIP_PATH = 'C:\does\not\exist-rocm'; ONNX_FORCE_CPU = '1' } {
            $r = Get-GpuEnvironment -ForceCpuEnvVar 'ONNX_FORCE_CPU'
            Assert-False $r.HasRocm 'FORCE_CPU beats the rocm gate'
            Assert-Null $r.RocmRoot 'no RocmRoot under FORCE_CPU'
        }
    }
}

Describe 'Get-CMakeRocmIsolationArgs (rocm lane keeps TheRock out of package search)' {

    It 'is empty on the cpu and nvidia lanes, whatever ROCM_PATH says' {
        Invoke-InTestDir { param($dir)
            foreach ($t in '', 'cpu', 'nvidia') {
                Invoke-WithEnv @{ GPU_TYPE = $t; ROCM_PATH = $dir; HIP_PATH = $dir } {
                    Assert-Equal 0 @(Get-CMakeRocmIsolationArgs).Count "GPU_TYPE='$t'"
                }
            }
        }
    }

    It 'ignores the ROCm prefix on the rocm lane, with forward slashes' {
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ GPU_TYPE = 'rocm'; ROCM_PATH = $dir; HIP_PATH = $null } {
                $got = @(Get-CMakeRocmIsolationArgs)
                Assert-Equal 1 $got.Count 'one arg'
                Assert-Equal "-DCMAKE_IGNORE_PREFIX_PATH=$($dir -replace '\\', '/')" $got[0] 'the ignore arg'
            }
        }
    }

    It 'is empty on the rocm lane when no ROCm tree exists (nothing to hide)' {
        Invoke-WithEnv @{ GPU_TYPE = 'rocm'; ROCM_PATH = 'C:\does\not\exist-rocm'; HIP_PATH = $null } {
            Assert-Equal 0 @(Get-CMakeRocmIsolationArgs).Count 'no tree'
        }
    }
}

Describe 'Test-SccacheRemoteConfigured' {

    It 'is false when no backend env var is set' {
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = ''; SCCACHE_BUCKET = ''; SCCACHE_REDIS_ENDPOINT = '' } {
            Assert-False (Test-SccacheRemoteConfigured)
        }
    }

    It 'is true when any single backend is set' {
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = 'http://cache:8080'; SCCACHE_BUCKET = ''; SCCACHE_REDIS_ENDPOINT = '' } {
            Assert-True (Test-SccacheRemoteConfigured) 'WebDAV endpoint alone should count'
        }
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = ''; SCCACHE_BUCKET = 'bucket'; SCCACHE_REDIS_ENDPOINT = '' } {
            Assert-True (Test-SccacheRemoteConfigured) 'S3 bucket alone should count'
        }
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = ''; SCCACHE_BUCKET = ''; SCCACHE_REDIS_ENDPOINT = 'redis://cache' } {
            Assert-True (Test-SccacheRemoteConfigured) 'redis endpoint alone should count'
        }
    }

    It 'Write-SccacheStats is a silent no-op without a remote backend (never spawns a server)' {
        Invoke-WithEnv @{ SCCACHE_WEBDAV_ENDPOINT = ''; SCCACHE_BUCKET = ''; SCCACHE_REDIS_ENDPOINT = '' } {
            Write-SccacheStats -Label 'unit'
            Assert-True $true 'returned without throwing'
        }
    }
}
