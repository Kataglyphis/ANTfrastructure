# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# ONNX Runtime NuGet layout + optional-package installation.
#
# RESTORED 2026-08-11. Deleted in f0d12ff (2026-06-24) as part of a wider
# cleanup, but AccelerANTgine's Build-Windows.ps1 still imports this
# module and calls Get-OnnxPackageLayout - the same "zero callers in THIS repo"
# blind spot that lost Sync-BuildArtifacts, and for the same reason: consumers
# pin a submodule commit, so they neither break at delete time nor show up in
# the sweep. Worse here, the call site sits inside a try/catch, so the loss
# degraded SILENTLY: the ONNX include/lib wiring was skipped rather than
# failing loudly.
#
# One substitution against the deleted original: it called
# Resolve-ContainerNormalizedPath (WindowsContainerImage.Common), which was a
# pure pass-through to Resolve-NormalizedPath and has since been removed too.
# This calls Resolve-NormalizedPath from WindowsScripts.Shared directly - same
# behaviour, one fewer hop.

Set-StrictMode -Version Latest

# Resolve-NormalizedPath. Plain, unforced import: an entry script's
# -Force -Global copy must not be displaced (see WindowsCMake.Common's header).
Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1')

# Get-WindowsRuntimeIdentifier, on the same unforced terms. This module is NOT
# reached through WindowsSourceBuild.Common (which re-exports the arch
# accessors) -- it is imported directly by the external AccelerANTgine
# Build-Windows.ps1, so it cannot borrow that re-export and must import the arch
# table itself. Both files live in windows\scripts\modules, which windows\Dockerfile
# COPYs as a whole directory, so co-location is guaranteed.
Import-Module (Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1')

function Get-OnnxPackageLayout {
    param(
        [Parameter(Mandatory)]
        [string]$OnnxRoot,

        [Parameter(Mandatory)]
        [string]$OnnxVersion,

        [Parameter(Mandatory)]
        [string]$OnnxGenAiVersion,

        [Parameter(Mandatory)]
        [string]$OnnxDirectMlVersion,

        # Target arch. '' delegates to Get-WindowsTargetArch's own precedence:
        # explicit -Arch, then $env:WINDOWS_TARGET_ARCH, then 'amd64'. Appended
        # LAST and optional so every existing caller -- including the external
        # AccelerANTgine Build-Windows.ps1, named or positional --
        # binds exactly as it does today and lands on win-x64.
        [string]$Arch = ''
    )

    $normalizedRoot = Resolve-NormalizedPath -Path $OnnxRoot
    $runtimePackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntime.{0}" -f $OnnxVersion)
    $directMlPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntime.DirectML.{0}" -f $OnnxDirectMlVersion)
    $cudaPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntime.Gpu.Windows.{0}" -f $OnnxVersion)
    $genAiPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntimeGenAI.{0}" -f $OnnxGenAiVersion)
    $genAiDirectMlPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntimeGenAI.DirectML.{0}" -f $OnnxGenAiVersion)
    $genAiCudaPackagePath = Join-Path $normalizedRoot ("Microsoft.ML.OnnxRuntimeGenAI.Cuda.{0}" -f $OnnxGenAiVersion)

    # ONE derivation for all 23 native-payload paths. Every package here uses the
    # standard NuGet native layout runtimes\<rid>\native, and the rid is the only
    # arch-varying token in any of them -- so the 23 inline 'runtimes\win-x64\native'
    # literals collapse to this single string instead of 23 separate arch calls.
    # amd64 -> 'runtimes\win-x64\native', byte-for-byte what was spelled inline.
    $rid = Get-WindowsRuntimeIdentifier -Arch $Arch
    $nativeRelDir = 'runtimes\{0}\native' -f $rid

    return [pscustomobject]@{
        Root = $normalizedRoot
        # Which lane this layout describes. Additive member; the caller has no
        # other way to tell a win-x64 layout from a win-arm64 one.
        RuntimeIdentifier = $rid

        RuntimePackagePath = $runtimePackagePath
        RuntimeIncludeDir = Join-Path $runtimePackagePath 'build\native\include'
        RuntimeHeaderPath = Join-Path $runtimePackagePath 'build\native\include\onnxruntime_cxx_api.h'
        RuntimeNativeDir = Join-Path $runtimePackagePath $nativeRelDir
        RuntimeLibPath = Join-Path $runtimePackagePath (Join-Path $nativeRelDir 'onnxruntime.lib')
        RuntimeDllPath = Join-Path $runtimePackagePath (Join-Path $nativeRelDir 'onnxruntime.dll')

        DirectMlPackagePath = $directMlPackagePath
        DirectMlNativeDir = Join-Path $directMlPackagePath $nativeRelDir
        DirectMlDllPath = Join-Path $directMlPackagePath (Join-Path $nativeRelDir 'onnxruntime.dll')
        DirectMlLibPath = Join-Path $directMlPackagePath (Join-Path $nativeRelDir 'onnxruntime.lib')
        DirectMlSharedProviderPath = Join-Path $directMlPackagePath (Join-Path $nativeRelDir 'onnxruntime_providers_shared.dll')

        CudaPackagePath = $cudaPackagePath
        CudaNativeDir = Join-Path $cudaPackagePath $nativeRelDir
        CudaDllPath = Join-Path $cudaPackagePath (Join-Path $nativeRelDir 'onnxruntime.dll')
        CudaLibPath = Join-Path $cudaPackagePath (Join-Path $nativeRelDir 'onnxruntime.lib')
        CudaProviderDllPath = Join-Path $cudaPackagePath (Join-Path $nativeRelDir 'onnxruntime_providers_cuda.dll')
        CudaSharedProviderPath = Join-Path $cudaPackagePath (Join-Path $nativeRelDir 'onnxruntime_providers_shared.dll')

        GenAiPackagePath = $genAiPackagePath
        GenAiIncludeDir = Join-Path $genAiPackagePath 'build\native\include'
        GenAiHeaderPath = Join-Path $genAiPackagePath 'build\native\include\ort_genai.h'
        GenAiNativeDir = Join-Path $genAiPackagePath $nativeRelDir
        GenAiDllPath = Join-Path $genAiPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai.dll')
        GenAiLibPath = Join-Path $genAiPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai.lib')

        GenAiDirectMlPackagePath = $genAiDirectMlPackagePath
        GenAiDirectMlNativeDir = Join-Path $genAiDirectMlPackagePath $nativeRelDir
        GenAiDirectMlDllPath = Join-Path $genAiDirectMlPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai.dll')
        GenAiDirectMlLibPath = Join-Path $genAiDirectMlPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai.lib')

        GenAiCudaPackagePath = $genAiCudaPackagePath
        GenAiCudaNativeDir = Join-Path $genAiCudaPackagePath $nativeRelDir
        GenAiCudaDllPath = Join-Path $genAiCudaPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai.dll')
        GenAiCudaLibPath = Join-Path $genAiCudaPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai.lib')
        GenAiCudaProviderDllPath = Join-Path $genAiCudaPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai-cuda.dll')
        GenAiCudaProviderLibPath = Join-Path $genAiCudaPackagePath (Join-Path $nativeRelDir 'onnxruntime-genai-cuda.lib')
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
