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
function Get-PeImportClosure {
    # The DLLs -Path pulls in from -SearchDirectory (first hit wins), transitively; a name found nowhere there is the OS's.
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string[]]$SearchDirectory,
        [ValidateSet('amd64', 'arm64')][string]$Arch = 'arm64'
    )
    $index = @{}
    foreach ($dir in $SearchDirectory) {
        foreach ($dll in @(Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
            $key = $dll.Name.ToLowerInvariant()
            if (-not $index.ContainsKey($key)) { $index[$key] = $dll.FullName }
        }
    }
    $taken = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$Path)
    $found = [System.Collections.Generic.List[string]]::new()
    while ($queue.Count -gt 0) {
        foreach ($name in @(Get-PeImportNames -Path $queue.Dequeue() -IncludeDelayLoad)) {
            $source = $index[$name.ToLowerInvariant()]
            if (-not $source -or -not $taken.Add($name)) { continue }
            $null = Assert-PeTargetMachine -Path $source -Arch $Arch -Context "closure DLL imported as $name, which the device could not load"
            $found.Add($source)
            $queue.Enqueue($source)
        }
    }
    # Unrolled, so @(Get-PeImportClosure ...) is the flat list -- and empty when nothing was found.
    return $found.ToArray()
}

function Copy-PeImportClosure {
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string[]]$SearchDirectory,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateSet('amd64', 'arm64')][string]$Arch = 'arm64'
    )
    $null = New-Item -ItemType Directory -Force -Path $Destination
    $copied = foreach ($source in @(Get-PeImportClosure -Path $Path -SearchDirectory $SearchDirectory -Arch $Arch)) {
        $target = Join-Path $Destination (Split-Path $source -Leaf)
        Copy-Item -LiteralPath $source -Destination $target -Force
        $target
    }
    return @($copied)
}

<#
.SYNOPSIS
    <DistDir>\bundle, the -BuildDir install tree plus the DLLs its binaries import, and <DistDir>\packages, the build's installers.
.DESCRIPTION
    The bundle runs on a clean machine. The installers are the build dir's .msi and .zip, and the .exe NSIS names like one of them;
    its other .exe files are tests. With -RequireCompleteInstall a DLL the closure has to add throws: the installers pack the
    install tree, so every one of them would lack it.
.PARAMETER Runner
    Runs cmake as { param($File, [string[]]$Arguments) }; the default throws on a non-zero exit. A build passes its logged runner.
.OUTPUTS
    [pscustomobject] Bundle, Packages, Added (the DLL names the closure copied in) and Installers.
#>
function New-PortableBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$DistDir,
        [string]$Configuration = 'Release',
        [string]$Arch = '',
        [string[]]$SearchDirectory = @(),
        [switch]$RequireCompleteInstall,
        [scriptblock]$Runner = { param($File, [string[]]$Arguments) & $File @Arguments; if ($LASTEXITCODE) { throw "$File $($Arguments -join ' ') exited $LASTEXITCODE" } }
    )

    $target = Get-WindowsTargetArch -Arch $Arch
    if ($SearchDirectory.Count -eq 0) { $SearchDirectory = @(Get-ProductDllSearchPath -Arch $target) }
    $bundle = Join-Path $DistDir 'bundle'
    $packages = Join-Path $DistDir 'packages'
    foreach ($dir in $bundle, $packages) { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force } }
    # Out-Host: cmake's install lines must not join this function's result.
    & $Runner 'cmake' @('--install', $BuildDir, '--prefix', $bundle, '--config', $Configuration) | Out-Host

    $bin = Join-Path $bundle 'bin'
    $installed = @(Get-ChildItem -LiteralPath $bin -File | ForEach-Object Name)
    $seeds = @(Get-ChildItem -LiteralPath $bin -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object FullName)
    $added = @(Copy-PeImportClosure -Path $seeds -SearchDirectory $SearchDirectory -Destination $bin -Arch $target |
            ForEach-Object { Split-Path $_ -Leaf } | Where-Object { $_ -notin $installed })
    if ($RequireCompleteInstall -and $added.Count -gt 0) {
        throw "The install tree lacks $($added -join ', '), which its binaries import, so every installer would ship without it: seed the package DLL closure with the binary that imports it."
    }

    $null = New-Item -ItemType Directory -Force -Path $packages
    $installers = @(Get-ChildItem -LiteralPath $BuildDir -File | Where-Object { $_.Extension -in '.msi', '.zip' })
    $installers += @($installers | ForEach-Object { Join-Path $BuildDir "$($_.BaseName).exe" } | Select-Object -Unique |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Get-Item)
    $installers | Copy-Item -Destination $packages
    return [pscustomobject]@{ Bundle = $bundle; Packages = $packages; Added = $added; Installers = @($installers | ForEach-Object Name) }
}

Export-ModuleMember -Function Get-CrossConfigureArgs, Get-WindowsPackageArch, Get-ProductDllSearchPath, Get-PeImportClosure, Copy-PeImportClosure,
    New-PortableBundle
