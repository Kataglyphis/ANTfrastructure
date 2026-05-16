Set-StrictMode -Version Latest

$containerImagePath = Join-Path $PSScriptRoot 'WindowsContainerImage.Common.psm1'
Import-Module $containerImagePath

function Get-OnnxPackageLayout {
    param(
        [Parameter(Mandatory)]
        [string]$OnnxRoot,

        [Parameter(Mandatory)]
        [string]$OnnxVersion,

        [Parameter(Mandatory)]
        [string]$OnnxGenAiVersion,

        [Parameter(Mandatory)]
        [string]$OnnxDirectMlVersion
    )

    $normalizedRoot = Resolve-ContainerNormalizedPath -Path $OnnxRoot
    $runtimePackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntime.{0}" -f $OnnxVersion)
    $directMlPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntime.DirectML.{0}" -f $OnnxDirectMlVersion)
    $cudaPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntime.Gpu.Windows.{0}" -f $OnnxVersion)
    $genAiPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntimeGenAI.{0}" -f $OnnxGenAiVersion)
    $genAiDirectMlPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntimeGenAI.DirectML.{0}" -f $OnnxGenAiVersion)
    $genAiCudaPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntimeGenAI.Cuda.{0}" -f $OnnxGenAiVersion)

    return [pscustomobject]@{
        Root = $normalizedRoot

        RuntimePackagePath = $runtimePackagePath
        RuntimeIncludeDir = Join-Path $runtimePackagePath 'build\native\include'
        RuntimeHeaderPath = Join-Path $runtimePackagePath 'build\native\include\onnxruntime_cxx_api.h'
        RuntimeNativeDir = Join-Path $runtimePackagePath 'runtimes\win-x64\native'
        RuntimeLibPath = Join-Path $runtimePackagePath 'runtimes\win-x64\native\onnxruntime.lib'
        RuntimeDllPath = Join-Path $runtimePackagePath 'runtimes\win-x64\native\onnxruntime.dll'

        DirectMlPackagePath = $directMlPackagePath
        DirectMlNativeDir = Join-Path $directMlPackagePath 'runtimes\win-x64\native'
        DirectMlDllPath = Join-Path $directMlPackagePath 'runtimes\win-x64\native\onnxruntime.dll'
        DirectMlLibPath = Join-Path $directMlPackagePath 'runtimes\win-x64\native\onnxruntime.lib'
        DirectMlSharedProviderPath = Join-Path $directMlPackagePath 'runtimes\win-x64\native\onnxruntime_providers_shared.dll'

        CudaPackagePath = $cudaPackagePath
        CudaNativeDir = Join-Path $cudaPackagePath 'runtimes\win-x64\native'
        CudaDllPath = Join-Path $cudaPackagePath 'runtimes\win-x64\native\onnxruntime.dll'
        CudaLibPath = Join-Path $cudaPackagePath 'runtimes\win-x64\native\onnxruntime.lib'
        CudaProviderDllPath = Join-Path $cudaPackagePath 'runtimes\win-x64\native\onnxruntime_providers_cuda.dll'
        CudaSharedProviderPath = Join-Path $cudaPackagePath 'runtimes\win-x64\native\onnxruntime_providers_shared.dll'

        GenAiPackagePath = $genAiPackagePath
        GenAiIncludeDir = Join-Path $genAiPackagePath 'build\native\include'
        GenAiHeaderPath = Join-Path $genAiPackagePath 'build\native\include\ort_genai.h'
        GenAiNativeDir = Join-Path $genAiPackagePath 'runtimes\win-x64\native'
        GenAiDllPath = Join-Path $genAiPackagePath 'runtimes\win-x64\native\onnxruntime-genai.dll'
        GenAiLibPath = Join-Path $genAiPackagePath 'runtimes\win-x64\native\onnxruntime-genai.lib'

        GenAiDirectMlPackagePath = $genAiDirectMlPackagePath
        GenAiDirectMlNativeDir = Join-Path $genAiDirectMlPackagePath 'runtimes\win-x64\native'
        GenAiDirectMlDllPath = Join-Path $genAiDirectMlPackagePath 'runtimes\win-x64\native\onnxruntime-genai.dll'
        GenAiDirectMlLibPath = Join-Path $genAiDirectMlPackagePath 'runtimes\win-x64\native\onnxruntime-genai.lib'

        GenAiCudaPackagePath = $genAiCudaPackagePath
        GenAiCudaNativeDir = Join-Path $genAiCudaPackagePath 'runtimes\win-x64\native'
        GenAiCudaDllPath = Join-Path $genAiCudaPackagePath 'runtimes\win-x64\native\onnxruntime-genai.dll'
        GenAiCudaLibPath = Join-Path $genAiCudaPackagePath 'runtimes\win-x64\native\onnxruntime-genai.lib'
        GenAiCudaProviderDllPath = Join-Path $genAiCudaPackagePath 'runtimes\win-x64\native\onnxruntime-genai-cuda.dll'
        GenAiCudaProviderLibPath = Join-Path $genAiCudaPackagePath 'runtimes\win-x64\native\onnxruntime-genai-cuda.lib'
    }
}

function Test-NuGetPackageVersionAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$Version
    )

    $packageList = & nuget list $PackageId -AllVersions -Source https://api.nuget.org/v3/index.json 2>$null
    if (-not $packageList) {
        return $false
    }

    return ($null -ne ($packageList | Select-String -SimpleMatch ("{0} {1}" -f $PackageId, $Version)))
}

function Install-OptionalNuGetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [string]$Version,

        [string]$OutputDirectory = '.',

        [string]$UnavailableMessage = ''
    )

    if (Test-NuGetPackageVersionAvailable -PackageId $PackageId -Version $Version) {
        Write-Host ('Found {0} package on NuGet; installing...' -f $PackageId)
        nuget install $PackageId -Version $Version -OutputDirectory $OutputDirectory
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($UnavailableMessage)) {
        $UnavailableMessage = '{0} not found for this version.' -f $PackageId
    }

    Write-Host $UnavailableMessage
    return $false
}

Export-ModuleMember -Function @(
    'Get-OnnxPackageLayout',
    'Test-NuGetPackageVersionAvailable',
    'Install-OptionalNuGetPackage'
)
