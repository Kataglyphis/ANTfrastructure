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
            Assert-Equal '80;86;89;90' (Get-CudaArchitectureList)
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
}
