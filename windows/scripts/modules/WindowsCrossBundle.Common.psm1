#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# What a cross lane's product needs to RUN on a clean device: every DLL its binaries import,
# transitively, beside them -- the CRT included, because an arm64 device ships no VC++ redist.
# Test-TargetArch.ps1 -ImportWalk then grades the folder, and container-ci-windows.yml's
# windows-11-arm job runs it (docs/windows-cross-builds.md § Consumer cross lanes).
#
# A NEW module on purpose: WindowsTargetArch.Common, where the PE readers live, is mounted into
# every media stage, so growing it would re-key the whole image chain.

Set-StrictMode -Version Latest

# Guarded, never -Force: a forced nested import unloads the caller's top-level copy.
$targetArchPath = Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1'
if (-not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $targetArchPath -DisableNameChecking }

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

Export-ModuleMember -Function Copy-PeImportClosure
