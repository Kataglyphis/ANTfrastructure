#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# What a consumer's Windows product needs from the hub (docs/windows-cross-builds.md § Consumer
# cross lanes). To BUILD a cross target: the CMake arguments that name it (Get-CrossConfigureArgs).
# To RUN on a clean machine, x64 or arm64: every DLL its binaries import, transitively, beside
# them -- the VC++ runtime included, because a clean device has no redist (Copy-PeImportClosure,
# searching Get-ProductDllSearchPath). Test-TargetArch.ps1 -ImportWalk then grades an arm64
# folder, and container-ci-windows.yml's windows-11-arm job runs it.
#
# A NEW module on purpose: WindowsTargetArch.Common, where the PE readers live, is mounted into
# every media stage, so growing it would re-key the whole image chain.

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
    1. ONNX_ROOT\bin, first so an ORT-family import resolves to the chain build.
    2. The image's runtime bin, the media stack (GStreamer, GLib, OpenCV, FFmpeg).
    3. VCToolsRedistDir\<x64|arm64>\Microsoft.VC*.CRT, the VC++ runtime of the toolset that
       built the product, Microsoft's supported app-local deployment.
    Only directories that exist are returned, so a missing variable narrows the search instead
    of failing it; the closure's own machine check and the arch gate stay the verdict.
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
    Get-CMakeCrossArgs (the triple, CMAKE_SYSTEM_NAME/PROCESSOR, so try_run is never attempted),
    plus two a consumer names when it has them, because both otherwise follow the HOST's pointer
    size: -Corrosion adds Rust_CARGO_TARGET, and -Vulkan adds Vulkan_LIBRARY from the SDK's
    per-arch Lib directory (Lib-ARM64 comes with the optional com.lunarg.vulkan.arm64 component).
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
    What a Windows package calls the target: x64 or arm64, the spelling of an AppxManifest's
    ProcessorArchitecture, `wix build -arch` and the VC++ redist directory alike.
#>
function Get-WindowsPackageArch {
    param([string]$Arch = '')
    return @{ amd64 = 'x64'; arm64 = 'arm64' }[(Get-WindowsTargetArch -Arch $Arch)]
}

<#
.SYNOPSIS
    Copies the DLLs -Path imports, transitively, from -SearchDirectory into -Destination; returns the copies.
.DESCRIPTION
    Static and delay-load imports, the set Test-TargetArch.ps1 -ImportWalk grades. A DLL loaded by name
    at run time (ONNX Runtime under ort's load-dynamic, a GStreamer plugin) is in neither table, so it
    enters the walk by being passed in -Path. A name found in no search directory is left to the
    device -- an API set, an OS DLL, or a gap that Test-TargetArch.ps1 -ImportWalk reports -- so this
    never guesses. The first search directory holding a name wins. Every copied DLL must be -Arch's
    machine: a host-arch DLL in the closure throws, because the device could never load it.
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
