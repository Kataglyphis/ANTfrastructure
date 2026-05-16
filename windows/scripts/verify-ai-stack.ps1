$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$containerModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
$onnxModulePath = Join-Path $PSScriptRoot 'modules\WindowsOnnx.Common.psm1'
foreach ($modulePath in @($containerModulePath, $onnxModulePath)) {
    if (-not (Test-Path $modulePath)) {
        throw "Required module not found: $modulePath"
    }
}

Import-Module $onnxModulePath -Force
Import-Module $containerModulePath -Force

function Assert-EnvironmentPathMatches {
    param(
        [Parameter(Mandatory)]
        [string]$VariableName,

        [Parameter(Mandatory)]
        [string]$ExpectedValue
    )

    $actualValue = [Environment]::GetEnvironmentVariable($VariableName)
    if ([string]::IsNullOrWhiteSpace($actualValue)) {
        throw "Environment variable $VariableName is not set."
    }

    $normalizedActual = Resolve-ContainerNormalizedPath -Path $actualValue
    $normalizedExpected = Resolve-ContainerNormalizedPath -Path $ExpectedValue
    if (-not [string]::Equals($normalizedActual, $normalizedExpected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Environment variable $VariableName expected '$normalizedExpected' but found '$normalizedActual'."
    }

    Write-Host ('{0,-20} = {1}' -f $VariableName, $actualValue)
}

function Assert-FilePresent {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Description
    )

    Assert-ContainerPathExists -Path $Path -Description $Description -PathType Leaf | Out-Null
    Write-Host ('Found {0}: {1}' -f $Description, $Path)
}

Write-Host 'Verifying CUDA Toolkit installation...'
Write-Host ('CUDA_ROOT = {0}' -f $env:CUDA_ROOT)
if (-not (Get-Command nvcc -ErrorAction SilentlyContinue)) {
    Write-Host 'nvcc not found on PATH; attempting to probe common CUDA locations...'
}

if (Get-Command nvcc -ErrorAction SilentlyContinue) {
    nvcc --version | Out-Host
    & where.exe nvcc
} else {
    throw 'nvcc not found; CUDA compiler not available.'
}

$cudaBins = @(
    $env:CUDA_ROOT,
    (Join-Path $env:CUDA_ROOT 'bin'),
    (Join-Path $env:CUDA_ROOT 'lib\x64')
) | Where-Object { Test-Path $_ }

$found = $false
foreach ($p in $cudaBins) {
    $dlls = Get-ChildItem -Path $p -Filter 'cudart*.dll' -Recurse -ErrorAction SilentlyContinue
    if ($dlls) {
        Write-Host ('Found CUDA runtime DLL: {0}' -f $dlls[0].FullName)
        $found = $true
        break
    }
}

if (-not $found) {
    throw ('CUDA runtime DLLs (cudart*.dll) not found under ' + $env:CUDA_ROOT + '; CUDA installation failed.')
}

Write-Host 'CUDA Toolkit verification passed!'

Write-Host 'Verifying cuDNN installation...'
Write-Host ('CUDNN_ROOT = {0}' -f $env:CUDNN_ROOT)
if (-not (Test-Path $env:CUDNN_ROOT)) {
    throw ('cuDNN directory not found at {0}' -f $env:CUDNN_ROOT)
}

$cudnnHeaders = Get-ChildItem -Path $env:CUDNN_ROOT -Filter 'cudnn.h' -Recurse -ErrorAction SilentlyContinue
$cudnnLibs = Get-ChildItem -Path $env:CUDNN_ROOT -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue
$cudnnDlls = Get-ChildItem -Path $env:CUDNN_ROOT -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue
if (-not $cudnnHeaders) {
    throw 'cuDNN headers (cudnn.h) not found!'
}

if (-not $cudnnLibs) {
    throw 'cuDNN import libs (cudnn*.lib) not found!'
}

if (-not $cudnnDlls) {
    throw 'cuDNN DLLs (cudnn*.dll) not found!'
}

Write-Host ('Found cuDNN Header: {0}' -f $cudnnHeaders[0].FullName)
Write-Host ('Found cuDNN Lib: {0}' -f $cudnnLibs[0].FullName)
Write-Host ('Found cuDNN DLL: {0}' -f $cudnnDlls[0].FullName)
Write-Host ('cuDNN DLL count: {0}' -f ($cudnnDlls | Measure-Object).Count)
Write-Host 'cuDNN verification passed!'

Write-Host 'Verifying ONNX Runtime and GenAI C++ resources (strict, x64-specific)...'
$layout = Get-OnnxPackageLayout -OnnxRoot $env:ONNX_ROOT -OnnxVersion $env:ONNX_VERSION -OnnxGenAiVersion $env:ONNX_GENAI_VERSION -OnnxDirectMlVersion $env:ONNX_DIRECTML_VERSION

Write-Host ('ONNX_ROOT            = {0}' -f $env:ONNX_ROOT)
Write-Host ('ONNX_GPU_VARIANT     = {0}' -f $env:ONNX_GPU_VARIANT)
Assert-EnvironmentPathMatches -VariableName 'ONNX_INCLUDE' -ExpectedValue $layout.RuntimeIncludeDir
Assert-EnvironmentPathMatches -VariableName 'ONNX_LIB' -ExpectedValue $layout.RuntimeNativeDir
Assert-EnvironmentPathMatches -VariableName 'ONNX_GENAI_INCLUDE' -ExpectedValue $layout.GenAiIncludeDir
Assert-EnvironmentPathMatches -VariableName 'ONNX_GENAI_LIB' -ExpectedValue $layout.GenAiNativeDir
Assert-EnvironmentPathMatches -VariableName 'ONNX_DIRECTML_LIB' -ExpectedValue $layout.DirectMlNativeDir
Assert-EnvironmentPathMatches -VariableName 'ONNX_CUDA_LIB' -ExpectedValue $layout.CudaNativeDir
Assert-EnvironmentPathMatches -VariableName 'ONNX_GENAI_DIRECTML_LIB' -ExpectedValue $layout.GenAiDirectMlNativeDir
Assert-EnvironmentPathMatches -VariableName 'ONNX_GENAI_CUDA_LIB' -ExpectedValue $layout.GenAiCudaNativeDir

Assert-FilePresent -Path $layout.RuntimeHeaderPath -Description 'ONNX runtime header'
Assert-FilePresent -Path $layout.RuntimeLibPath -Description 'ONNX runtime import lib'
Assert-FilePresent -Path $layout.RuntimeDllPath -Description 'ONNX runtime DLL'
Assert-FilePresent -Path $layout.GenAiHeaderPath -Description 'ONNX GenAI header'
Assert-FilePresent -Path $layout.GenAiLibPath -Description 'ONNX GenAI import lib'
Assert-FilePresent -Path $layout.GenAiDllPath -Description 'ONNX GenAI DLL'

$variant = ''
if ($env:ONNX_GPU_VARIANT) {
    $variant = $env:ONNX_GPU_VARIANT.ToLower()
}

if ($variant -match 'directml' -or $variant -match 'both') {
    if (Test-Path $layout.DirectMlDllPath) {
        Assert-FilePresent -Path $layout.DirectMlDllPath -Description 'ONNX DirectML runtime DLL'
    } else {
        Write-Host ('ERROR: DirectML onnxruntime.dll required but not found at {0}.' -f $layout.DirectMlDllPath)
        throw 'ONNX DirectML DLL missing but required by ONNX_GPU_VARIANT.'
    }
}

if ($variant -match 'cuda' -or $variant -match 'both') {
    Assert-FilePresent -Path $layout.CudaDllPath -Description 'ONNX CUDA runtime DLL'
    if (Test-Path $layout.CudaProviderDllPath) {
        Assert-FilePresent -Path $layout.CudaProviderDllPath -Description 'ONNX CUDA provider DLL'
    } else {
        Write-Host ('ERROR: {0} required but not found.' -f $layout.CudaProviderDllPath)
        throw 'ONNX CUDA provider DLL missing but required by ONNX_GPU_VARIANT.'
    }
}

if (Test-Path $layout.GenAiDirectMlNativeDir) {
    Assert-FilePresent -Path $layout.GenAiDirectMlDllPath -Description 'ONNX GenAI DirectML DLL'
} else {
    Write-Host 'ONNX GenAI DirectML package directory not present; optional provider remains unavailable.'
}

if (Test-Path $layout.GenAiCudaNativeDir) {
    Assert-FilePresent -Path $layout.GenAiCudaDllPath -Description 'ONNX GenAI CUDA base DLL'
    Assert-FilePresent -Path $layout.GenAiCudaProviderDllPath -Description 'ONNX GenAI CUDA provider DLL'
} else {
    Write-Host 'ONNX GenAI CUDA package directory not present; optional provider remains unavailable.'
}

Write-Host 'ONNX verification passed! :)))'

Write-Host 'Verifying OpenCV C++ resources...'
$cvHeaders = Get-ChildItem -Path $env:OPENCV_INCLUDE -Filter 'opencv.hpp' -Recurse
$cvLibs = Get-ChildItem -Path $env:OPENCV_LIB -Filter 'opencv_world*.lib'
$cvDlls = Get-ChildItem -Path $env:OPENCV_BIN -Filter 'opencv_world*.dll'
if (-not $cvHeaders) {
    throw 'OpenCV headers missing!'
}

if (-not $cvLibs) {
    throw 'OpenCV import libs missing!'
}

if (-not $cvDlls) {
    throw 'OpenCV dlls missing!'
}

Write-Host ('Found OpenCV Header: {0}' -f $cvHeaders[0].FullName)
Write-Host ('Found OpenCV Lib: {0}' -f $cvLibs[0].FullName)
Write-Host ('Found OpenCV DLL: {0}' -f $cvDlls[0].FullName)
Write-Host 'OpenCV verification passed! :)))'
