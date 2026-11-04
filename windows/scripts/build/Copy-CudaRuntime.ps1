# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# A script, not a COPY: spaces in Program Files and cuDNN 9's CUDA-major bin subdir; see docs/windows-builds.md § Copy-CudaRuntime.ps1.

param([string]$StageRoot = 'C:\cuda-rt')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'WindowsNativeProvenance.Common.psm1')

$root = $StageRoot
$dest = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Guarded: Join-Path on an unset root throws an opaque binding error; a cross GPU lane must read bin\arm64, not the x64 bin\.
$targetArch = if ([string]::IsNullOrWhiteSpace($env:WINDOWS_TARGET_ARCH)) { 'amd64' } else { $env:WINDOWS_TARGET_ARCH }
$binSubdir = if ($targetArch -eq 'amd64') { 'bin' } else { 'bin\arm64' }
$sdks = @(
    @{ Name = 'cuda'; Root = $env:CUDA_ROOT; Source = @{ Name = 'NVIDIA CUDA Toolkit'; Url = 'https://developer.nvidia.com/cuda-downloads'; Sha256 = $env:CUDA_INSTALLER_SHA256 } }
    @{ Name = 'cudnn'; Root = $env:CUDNN_ROOT; Source = @{ Name = 'NVIDIA cuDNN'; Url = 'https://developer.nvidia.com/cudnn' } }
) | Where-Object { $_.Root -and (Test-Path (Join-Path $_.Root $binSubdir)) }

# No root set is a CPU lane, whose empty dir still feeds the merge's unconditional COPY; a set root that does not resolve is a broken nvidia base.
$cudaConfigured = [bool]$env:CUDA_ROOT -or [bool]$env:CUDNN_ROOT
if (@($sdks).Count -eq 0) {
    if ($cudaConfigured) {
        throw "Neither CUDA_ROOT\bin nor CUDNN_ROOT resolves (CUDA_ROOT='$env:CUDA_ROOT', CUDNN_ROOT='$env:CUDNN_ROOT'). Is this stage derived from the nvidia base?"
    }
    Write-Host "No CUDA/cuDNN on this lane (CUDA_ROOT and CUDNN_ROOT are both unset) - staged an EMPTY $dest so the merge fan-in's unconditional COPY still succeeds."
    exit 0
}

# Imported by nothing and in no dlopen family; cudnn_*, the nvrtc/nvjitlink JIT chain and curand stay, as only static imports were checked.
$trimmed = @('cusparse64_*.dll', 'cusolver64_*.dll', 'cusolvermg64_*.dll', 'nvjpeg64_*.dll', 'npps64_*.dll')
# Attachment A of the CUDA EULA and cuDNN's supplement; nvfatbin is absent there, so a new name fails until someone reads the terms.
$distributable = @('cublas64_*.dll', 'cublasLt64_*.dll', 'cudart64_*.dll', 'cufft64_*.dll', 'cufftw64_*.dll', 'curand64_*.dll', 'cupti*.dll',
    'npp*64_*.dll', 'nvblas64_*.dll', 'nvJitLink_*.dll', 'nvrtc64_*.dll', 'nvrtc-builtins64_*.dll', 'cudnn*64_*.dll')
$notDistributable = @('nvfatbin_*.dll')
$inList = { param($name, $patterns) [bool]($patterns | Where-Object { $name -like $_ }) }

$count = 0
$skipped = 0
$entries = [System.Collections.Generic.List[object]]::new()
$origin = @{}
foreach ($sdk in $sdks) {
    Get-ChildItem -Path (Join-Path $sdk.Root $binSubdir) -Filter '*.dll' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        if ((& $inList $name $trimmed) -or (& $inList $name $notDistributable)) { $skipped++; return }
        if (-not (& $inList $name $distributable)) {
            throw "$($_.FullName) is not on the distributable list. Read the EULA's Attachment A, then add it to `$distributable or `$notDistributable."
        }
        # Last writer wins on duplicate basenames, which is fine for a single-CUDA image.
        Copy-Item -Path $_.FullName -Destination (Join-Path $dest $name) -Force
        $origin[$name] = $sdk
        $count++
    }
}
Write-Host "Left out $skipped DLLs: unreferenced (closure-verified; see #54) or not distributable"

# Hard gate: the whole point is cudnn64_9.dll. Fail loud if the layout moved.
if (-not (Test-Path (Join-Path $dest 'cudnn64_9.dll'))) {
    $present = @(Get-ChildItem -Path $dest -Filter 'cudnn*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    throw "cudnn64_9.dll was not staged into $dest. cudnn*.dll present: $($present -join ', '). Check the cuDNN version/layout under $env:CUDNN_ROOT."
}

$notice = @{}
foreach ($sdk in $sdks) {
    $texts = @(Get-ChildItem -LiteralPath $sdk.Root -File -Filter 'LICENSE*')
    if ($texts.Count -eq 0) { throw "$($sdk.Source.Name) has no LICENSE file under $($sdk.Root)" }
    $notice[$sdk.Name] = Copy-NativeNotice -Root $root -NoticeDir 'notices' -Name $sdk.Name -File @($texts.FullName)
}
foreach ($name in @($origin.Keys | Sort-Object)) {
    $sdk = $origin[$name]
    $entries.Add((New-NativeProvenanceEntry -Root $root -File "bin\$name" -Source ($sdk.Source + @{ Version = (Split-Path -Leaf $sdk.Root) }) -Notice $notice[$sdk.Name]))
}
$manifest = Join-Path $root 'provenance.json'
Write-NativeProvenanceManifest -Path $manifest -Owner 'cuda-runtime' -Entry @($entries) -Root $root -RequiredFile 'bin\cudnn64_9.dll'

Write-Host "Staged $count CUDA/cuDNN runtime DLLs into $dest (incl. cudnn64_9.dll) with their licenses and $manifest"
exit 0
