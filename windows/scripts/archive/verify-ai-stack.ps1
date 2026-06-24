# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

Write-Host 'Verifying ONNX Runtime and GenAI C++ resources (source-built layout)...'

Write-Host ('ONNX_ROOT            = {0}' -f $env:ONNX_ROOT)
Write-Host ('ONNX_GENAI_ROOT      = {0}' -f $env:ONNX_GENAI_ROOT)
Write-Host ('ONNX_GPU_VARIANT     = {0}' -f $env:ONNX_GPU_VARIANT)

if (-not $env:ONNX_ROOT -or -not (Test-Path $env:ONNX_ROOT)) {
    throw "ONNX_ROOT ($env:ONNX_ROOT) not found."
}
if (-not $env:ONNX_GENAI_ROOT -or -not (Test-Path $env:ONNX_GENAI_ROOT)) {
    throw "ONNX_GENAI_ROOT ($env:ONNX_GENAI_ROOT) not found."
}

$onnxInclude = Join-Path $env:ONNX_ROOT 'include'
$onnxLib = Join-Path $env:ONNX_ROOT 'lib'
$onnxBin = Join-Path $env:ONNX_ROOT 'bin'
$genaiInclude = Join-Path $env:ONNX_GENAI_ROOT 'include'
$genaiLib = Join-Path $env:ONNX_GENAI_ROOT 'lib'
$genaiBin = Join-Path $env:ONNX_GENAI_ROOT 'bin'

Assert-FilePresent -Path (Join-Path $onnxInclude 'onnxruntime_c_api.h') -Description 'ONNX runtime C API header'
Assert-FilePresent -Path (Join-Path $onnxLib 'onnxruntime.lib') -Description 'ONNX runtime import lib'
Assert-FilePresent -Path (Join-Path $onnxBin 'onnxruntime.dll') -Description 'ONNX runtime DLL'

Assert-FilePresent -Path (Join-Path $genaiInclude 'onnxruntime_genai.h') -Description 'ONNX GenAI header'
Assert-FilePresent -Path (Join-Path $genaiLib 'OnnxRuntimeGenAI.lib') -Description 'ONNX GenAI import lib'
Assert-FilePresent -Path (Join-Path $genaiBin 'OnnxRuntimeGenAI.dll') -Description 'ONNX GenAI DLL'

$variant = ''
if ($env:ONNX_GPU_VARIANT) {
    $variant = $env:ONNX_GPU_VARIANT.ToLower()
}

if ($variant -eq 'cuda' -or $variant -eq 'nvidia') {
    if (Test-Path (Join-Path $onnxBin 'onnxruntime_providers_cuda.dll')) {
        Assert-FilePresent -Path (Join-Path $onnxBin 'onnxruntime_providers_cuda.dll') -Description 'ONNX CUDA provider DLL'
    } else {
        Write-Host 'ONNX CUDA provider DLL not found — GPU provider may be unavailable'
    }
    if (Test-Path (Join-Path $onnxBin 'onnxruntime_providers_tensorrt.dll')) {
        Assert-FilePresent -Path (Join-Path $onnxBin 'onnxruntime_providers_tensorrt.dll') -Description 'ONNX TensorRT provider DLL'
    }
    if (Test-Path (Join-Path $genaiBin 'OnnxRuntimeGenAI_cuda.dll')) {
        Assert-FilePresent -Path (Join-Path $genaiBin 'OnnxRuntimeGenAI_cuda.dll') -Description 'ONNX GenAI CUDA provider DLL'
    }
}

Write-Host 'ONNX verification passed!'

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
