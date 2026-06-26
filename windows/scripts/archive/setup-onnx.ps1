# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$TempDir = 'C:\temp',
    [string]$OnnxRoot = '',
    [string]$OnnxVersion = '',
    [string]$OnnxGenAiVersion = '',
    [string]$OnnxDirectMlVersion = ''
)

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

$OnnxRoot = Resolve-ContainerImageValue -Value $OnnxRoot -EnvironmentVariable 'ONNX_ROOT' -DefaultValue 'C:\onnx'
# Support both ONNX_VERSION (canonical versions.env) and the shorter aliases
$OnnxVersion = Resolve-ContainerImageValue -Value $OnnxVersion -EnvironmentVariable 'ONNXRUNTIME_VERSION'
if ([string]::IsNullOrWhiteSpace($OnnxVersion)) {
    $OnnxVersion = Resolve-ContainerImageValue -Value '' -EnvironmentVariable 'ONNX_VERSION'
}
$OnnxGenAiVersion = Resolve-ContainerImageValue -Value $OnnxGenAiVersion -EnvironmentVariable 'ONNXRUNTIME_GENAI_VERSION'
if ([string]::IsNullOrWhiteSpace($OnnxGenAiVersion)) {
    $OnnxGenAiVersion = Resolve-ContainerImageValue -Value '' -EnvironmentVariable 'ONNX_GENAI_VERSION'
}
$OnnxDirectMlVersion = Resolve-ContainerImageValue -Value $OnnxDirectMlVersion -EnvironmentVariable 'ONNX_DIRECTML_VERSION'

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Users\ContainerAdministrator\scoop\shims',
    'C:\ProgramData\scoop\shims'
) | Out-Null
Assert-ContainerCommandAvailable -Name 'nuget' | Out-Null

Write-Host 'Downloading ONNX Runtime and GenAI packages...'
$OnnxRoot = Resolve-ContainerDirectoryPath -Path $OnnxRoot

Push-Location $OnnxRoot
try {
    nuget install Microsoft.ML.OnnxRuntime -Version $OnnxVersion -OutputDirectory .
    nuget install Microsoft.ML.OnnxRuntimeGenAI -Version $OnnxGenAiVersion -OutputDirectory .
    Write-Host 'Installing ONNX Runtime DirectML GPU package...'
    nuget install Microsoft.ML.OnnxRuntime.DirectML -Version $OnnxDirectMlVersion -OutputDirectory .
    Write-Host 'Installing ONNX Runtime CUDA GPU package...'
    nuget install Microsoft.ML.OnnxRuntime.Gpu -Version $OnnxVersion -OutputDirectory .
    Write-Host 'Attempting to install Microsoft.ML.OnnxRuntimeGenAI.DirectML (if available)...'
    Install-OptionalNuGetPackage -PackageId 'Microsoft.ML.OnnxRuntimeGenAI.DirectML' -Version $OnnxGenAiVersion -OutputDirectory . -UnavailableMessage 'Microsoft.ML.OnnxRuntimeGenAI.DirectML not found for this version.' | Out-Null

    Write-Host 'Attempting to install Microsoft.ML.OnnxRuntimeGenAI.Cuda (if available)...'
    Install-OptionalNuGetPackage -PackageId 'Microsoft.ML.OnnxRuntimeGenAI.Cuda' -Version $OnnxGenAiVersion -OutputDirectory . -UnavailableMessage 'Microsoft.ML.OnnxRuntimeGenAI.Cuda not found for this version.' | Out-Null
} finally {
    Pop-Location
}

$layout = Get-OnnxPackageLayout -OnnxRoot $OnnxRoot -OnnxVersion $OnnxVersion -OnnxGenAiVersion $OnnxGenAiVersion -OnnxDirectMlVersion $OnnxDirectMlVersion
Write-Host ('Resolved ONNX x64 runtime directory: {0}' -f $layout.RuntimeNativeDir)
Write-Host ('Resolved ONNX CUDA provider directory: {0}' -f $layout.CudaNativeDir)
Write-Host ('Resolved ONNX DirectML directory: {0}' -f $layout.DirectMlNativeDir)
