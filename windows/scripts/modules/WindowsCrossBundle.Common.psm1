#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Apart from WindowsTargetArch.Common, which every media stage mounts; see docs/windows-cross-builds.md § Consumer cross lanes

Set-StrictMode -Version Latest

# Guarded, never -Force: a forced nested import unloads the caller's top-level copy.
$targetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $targetArchPath -DisableNameChecking }

# Where the family images install the media stack's DLLs, for the target arch of the image.
$script:ImageRuntimeBin = 'C:\runtime\bin'

<#
.SYNOPSIS
    Where a product's DLL closure comes from, in the order Copy-PeImportClosure should search.
.DESCRIPTION
    ONNX_ROOT\bin (the chain's ORT) first, then the image runtime bin, then the toolset's VC++ CRT redist dir.
    Only existing directories are returned, so a missing variable narrows the search instead of failing it.
#>
function Get-ProductDllSearchPath {
    param([string]$Arch = '', [string]$RuntimeBin = $script:ImageRuntimeBin)
    $packageArch = Get-WindowsPackageArch -Arch $Arch
    $ordered = @(
        if ($env:ONNX_ROOT) { Join-Path $env:ONNX_ROOT 'bin' }
        $RuntimeBin
        if ($env:VCToolsRedistDir) {
            Get-ChildItem -LiteralPath (Join-Path $env:VCToolsRedistDir $packageArch) -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
                ForEach-Object FullName
        }
    )
    return @($ordered | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
}

<#
.SYNOPSIS
    The CMake configure arguments that make a consumer's build a cross build; empty on the host.
.DESCRIPTION
    Get-CMakeCrossArgs plus -Corrosion (Rust_CARGO_TARGET) and -Vulkan (per-arch Vulkan_LIBRARY), which follow the host otherwise.
#>
function Get-CrossConfigureArgs {
    param(
        [string]$Arch = '',
        [switch]$Corrosion,
        [switch]$Vulkan
    )
    $resolved = Get-WindowsTargetArch -Arch $Arch
    if (-not (Test-WindowsCrossTarget -Arch $resolved)) { return @() }
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @(Get-CMakeCrossArgs -Arch $resolved)) { $result.Add($a) }
    if ($Corrosion) { $result.Add("-DRust_CARGO_TARGET=$(Get-RustTargetTriple -Arch $resolved)") }
    if ($Vulkan) {
        if ([string]::IsNullOrWhiteSpace($env:VULKAN_SDK)) { throw "-Vulkan needs VULKAN_SDK, and it is unset" }
        $lib = Join-Path $env:VULKAN_SDK (Join-Path (Get-VulkanLibDirName -Arch $resolved) 'vulkan-1.lib')
        if (-not (Test-Path -LiteralPath $lib -PathType Leaf)) {
            throw "No $lib`: the Vulkan SDK carries no $resolved import library (the optional com.lunarg.vulkan.arm64 component)"
        }
        $result.Add("-DVulkan_LIBRARY=$lib")
    }
    return $result.ToArray()
}

<#
.SYNOPSIS
    x64 or arm64: the target as AppxManifest, `wix build -arch` and the VC++ redist directory spell it.
#>
function Get-WindowsPackageArch {
    param([string]$Arch = '')
    return @{ amd64 = 'x64'; arm64 = 'arm64' }[(Get-WindowsTargetArch -Arch $Arch)]
}

<#
.SYNOPSIS
    Copies the DLLs -Path imports, transitively, from -SearchDirectory into -Destination; returns the copies.
.DESCRIPTION
    Static and delay-load imports; pass run-time-loaded DLLs in -Path. Unfound names are left to the device, never guessed.
    First search directory wins; a copied DLL of the wrong machine throws.
#>
function Copy-PeImportClosure {
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string[]]$SearchDirectory,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('amd64', 'arm64')][string]$Arch = 'arm64'
    )
    $index = @{}
    foreach ($dir in $SearchDirectory) {
        foreach ($dll in @(Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
            $key = $dll.Name.ToLowerInvariant()
            if (-not $index.ContainsKey($key)) { $index[$key] = $dll.FullName }
        }
    }
    $null = New-Item -ItemType Directory -Force -Path $Destination
    $taken = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Path)
    $copied = [System.Collections.Generic.List[string]]::new()
    while ($queue.Count -gt 0) {
        foreach ($name in @(Get-PeImportNames -Path $queue.Dequeue() -IncludeDelayLoad)) {
            $source = $index[$name.ToLowerInvariant()]
            if (-not $source -or -not $taken.Add($name)) { continue }
            $null = Assert-PeTargetMachine -Path $source -Arch $Arch -Context "closure DLL imported as $name, which the device could not load"
            $target = Join-Path $Destination (Split-Path $source -Leaf)
            Copy-Item -LiteralPath $source -Destination $target -Force
            $copied.Add($target)
            $queue.Enqueue($source)
        }
    }
    # Unrolled, so @(Copy-PeImportClosure ...) is the flat list -- and empty when nothing was copied.
    return $copied.ToArray()
}

Export-ModuleMember -Function Get-CrossConfigureArgs, Get-WindowsPackageArch, Get-ProductDllSearchPath, Copy-PeImportClosure
