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
        $dir = New-TestDir
        try {
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } { Assert-Null (Resolve-TensorRtRoot) }
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'returns the versioned TensorRT-* subdirectory when present' {
        $dir = New-TestDir
        try {
            $sub = Join-Path $dir 'TensorRT-10.5.0.18'
            New-Item -ItemType Directory -Force -Path $sub | Out-Null
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } {
                Assert-Equal $sub (Resolve-TensorRtRoot)
            }
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'returns the root itself for a flat layout (no TensorRT-* subdir)' {
        $dir = New-TestDir
        try {
            Set-Content -Path (Join-Path $dir 'nvinfer.lib') -Value '' -NoNewline
            Invoke-WithEnv @{ TENSORRT_ROOT = $dir } {
                Assert-Equal $dir (Resolve-TensorRtRoot)
            }
        } finally { Remove-Item $dir -Recurse -Force }
    }
}
