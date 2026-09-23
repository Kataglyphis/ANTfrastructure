# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# ONNX Runtime for consumers: the chain install at ONNX_ROOT, never a NuGet package (owner rule 2026-09-23).
# NOT covered: byte provenance under ONNX_ROOT (the ORT census). docs/windows-build-invariants.md#the-unreferenced-windowsscripts-modules-are-external-consumer-api
#
# RESTORED 2026-09-14, for the SECOND time. Deleted in f0d12ff (2026-06-24),
# restored 2026-08-11, deleted again in 2eaed40e (2026-09-08, "no consumer"),
# while AccelerANTgine's scripts/windows/Build-Windows.ps1 still imports it BY
# NAME through Resolve-BuildModule and calls Get-OnnxPackageLayout -- which is
# exactly the reference shape a path grep cannot see. Its Windows lane was red
# from the pin bump that carried the deletion until this restore. The
# consumer inventory (.github/consumers.json) now records that consumer, and
# the rule in AGENTS.md § Contributing Reusable Work Here is: a hub file may
# be deleted only when the inventory reports it as named by nobody.
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

# Assert-PeTargetMachine, on the same unforced terms. This module is NOT
# reached through WindowsSourceBuild.Common (which re-exports the arch
# accessors) -- it is imported directly by the external AccelerANTgine
# Build-Windows.ps1, so it cannot borrow that re-export and must import the arch
# table itself. Both files live in windows\scripts\modules, which windows\Dockerfile
# COPYs as a whole directory, so co-location is guaranteed.
Import-Module (Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1')

# NuGet ids that carry ORT: every *OnnxRuntime* package (GenAI, EPs, Intel's OpenVINO build) and Windows ML.
$script:OrtNuGetIdPattern = '(?i)onnxruntime|^Microsoft\.(Windows\.)?AI\.MachineLearning(\.|$)'
$script:OrtFilePattern = '(?i)^(onnxruntime(_providers_\w+)?\.(dll|lib)|onnxruntime_c_api\.h|onnxruntime_pybind11_state.*\.pyd|microsoft\.(windows\.)?ai\.machinelearning\.dll)$'
$script:OrtGenAiFilePattern = '(?i)^(onnxruntime-genai(-\w+)?\.(dll|lib)|ort_genai(_c)?\.h|onnxruntime_genai.*\.pyd)$'

function Get-OnnxChainRuleMessage {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$OnnxRoot = $env:ONNX_ROOT
    )
    $current = if ([string]::IsNullOrWhiteSpace($OnnxRoot)) { 'unset' } else { "'$OnnxRoot'" }
    return ('{0}. ONNX Runtime comes from the chain build only (owner rule 2026-09-23): point ONNX_ROOT at its ' +
        'install (C:\runtime\lib\onnxruntime-source in the image, built by Build-OnnxFromSource.ps1) and use ' +
        'Get-OnnxChainLayout. ONNX_ROOT is {1}.') -f $Subject, $current
}

<#
.SYNOPSIS
    ONNX Runtime binaries and headers under a directory, recognised by file name.
.DESCRIPTION
    Kind 'genai' for onnxruntime-genai files, 'ort' for the runtime, its EPs, its C API
    header, its python extension and Windows ML. A missing directory yields nothing.
#>
function Get-OnnxRuntimeFile {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Force -Recurse:$Recurse -ErrorAction Stop)) {
        $kind = if ($file.Name -match $script:OrtGenAiFilePattern) { 'genai' }
                elseif ($file.Name -match $script:OrtFilePattern) { 'ort' }
                else { $null }
        if ($kind) {
            [pscustomobject]@{ Kind = $kind; Name = $file.Name; FullName = $file.FullName; Extension = $file.Extension.ToLowerInvariant() }
        }
    }
}

<#
.SYNOPSIS
    The chain ONNX Runtime install (plus the chain GenAI, when given), validated.
.DESCRIPTION
    ONNX_ROOT must hold bin\onnxruntime.dll for the TARGET machine; a NuGet tree or a
    release zip (lib\onnxruntime.dll) throws. A GenAI root must hold lib\ (or bin\)onnxruntime-genai.dll,
    no NuGet runtimes\ or .nupkg, and no ONNX Runtime file of its own. RuntimeDirectories lists the existing DLL
    directories with the chain ORT LAST, so it wins any name collision when staged.
#>
function Get-OnnxChainLayout {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [string]$OnnxRoot = $env:ONNX_ROOT,
        [string]$OnnxGenAiRoot = $env:ONNX_GENAI_ROOT,
        [string]$Arch = ''
    )

    if ([string]::IsNullOrWhiteSpace($OnnxRoot)) {
        throw (Get-OnnxChainRuleMessage -Subject 'Get-OnnxChainLayout: ONNX_ROOT is not set' -OnnxRoot $OnnxRoot)
    }
    $root = Resolve-NormalizedPath -Path $OnnxRoot
    $dll = Join-Path $root 'bin\onnxruntime.dll'
    if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
        throw (Get-OnnxChainRuleMessage -Subject "Get-OnnxChainLayout: $root is not the chain install (no bin\onnxruntime.dll)" -OnnxRoot $OnnxRoot)
    }
    [void](Assert-PeTargetMachine -Path $dll -Arch $Arch -Context 'chain ONNX Runtime')

    $genAiRoot = $null
    $genAiDll = $null
    $subDirs = @()
    if ($OnnxGenAiRoot.Trim()) {
        $genAiRoot = Resolve-NormalizedPath -Path $OnnxGenAiRoot
        $genAiFiles = @(Get-OnnxRuntimeFile -Path $genAiRoot -Recurse)
        $ownOrt = @($genAiFiles | Where-Object { $_.Kind -eq 'ort' })
        if ($ownOrt.Count -gt 0) {
            throw (Get-OnnxChainRuleMessage -OnnxRoot $OnnxRoot -Subject ("Get-OnnxChainLayout: the GenAI root $genAiRoot carries its own ONNX Runtime: " +
                    (($ownOrt | ForEach-Object { $_.FullName }) -join ', ')))
        }
        # An extracted NuGet GenAI package carries no ORT file; its runtimes\ tree and .nupkg/.nuspec give it away.
        $nugetMarks = @(if (Test-Path -LiteralPath $genAiRoot -PathType Container) {
                Get-ChildItem -LiteralPath $genAiRoot -Force -ErrorAction Stop | Where-Object { $_.Name -match '(?i)^runtimes$|\.(nupkg|nuspec)$' }
            })
        if ($nugetMarks.Count -gt 0) {
            throw (Get-OnnxChainRuleMessage -OnnxRoot $OnnxRoot -Subject ("Get-OnnxChainLayout: ONNX_GENAI_ROOT $genAiRoot is a NuGet package (" +
                    (($nugetMarks | ForEach-Object { $_.Name }) -join ', ') + '), not the chain GenAI install'))
        }
        # Exact paths, like the ORT half: the chain installs lib\onnxruntime-genai.dll (bin\ tolerated), never deeper.
        $genAiDll = @('lib', 'bin') | ForEach-Object { Join-Path $genAiRoot "$_\onnxruntime-genai.dll" } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $genAiDll) {
            throw (Get-OnnxChainRuleMessage -OnnxRoot $OnnxRoot -Subject "Get-OnnxChainLayout: ONNX_GENAI_ROOT $genAiRoot holds no onnxruntime-genai.dll in lib\ or bin\")
        }
        [void](Assert-PeTargetMachine -Path $genAiDll -Arch $Arch -Context 'chain ONNX Runtime GenAI')
        $subDirs += (Join-Path $genAiRoot 'bin'), (Join-Path $genAiRoot 'lib')
    }
    $subDirs += (Join-Path $root 'lib'), (Join-Path $root 'bin')

    return [pscustomobject]@{
        Root               = $root
        BinDir             = Join-Path $root 'bin'
        LibDir             = Join-Path $root 'lib'
        IncludeDir         = Join-Path $root 'include\onnxruntime'
        DllPath            = $dll
        ImportLibPath      = Join-Path $root 'lib\onnxruntime.lib'
        GenAiRoot          = $genAiRoot
        GenAiDllPath       = $genAiDll
        RuntimeDirectories = [string[]]@($subDirs | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    }
}

# Kept, with the NuGet-era parameters, so an old caller gets this refusal and not a binding error.
function Get-OnnxPackageLayout {
    param(
        [string]$OnnxRoot = '',
        [string]$OnnxVersion = '',
        [string]$OnnxGenAiVersion = '',
        [string]$OnnxDirectMlVersion = '',
        [string]$Arch = ''
    )

    throw (Get-OnnxChainRuleMessage -Subject ("Get-OnnxPackageLayout: the NuGet Microsoft.ML.OnnxRuntime layout " +
            "(root '$OnnxRoot', version '$OnnxVersion') is refused"))
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

# Every NuGet package (the top-level entry above a .nupkg, either layout) under $OutputDirectory whose id or content is ORT.
function Get-NuGetOnnxRuntimePayload {
    param([Parameter(Mandatory)][string]$OutputDirectory)

    $base = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return }
    $packages = Get-ChildItem -LiteralPath $base -Filter '*.nupkg' -File -Recurse -Depth 2 -Force -ErrorAction Stop |
        ForEach-Object { Join-Path $base ($_.FullName.Substring($base.Length + 1) -split '\\')[0] } | Sort-Object -Unique
    foreach ($package in @($packages)) {
        if ((Split-Path $package -Leaf) -match $script:OrtNuGetIdPattern) { $package }
        else { Get-OnnxRuntimeFile -Path $package -Recurse | ForEach-Object { $_.FullName } }
    }
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

    if ($PackageId -match $script:OrtNuGetIdPattern) {
        throw (Get-OnnxChainRuleMessage -Subject "Install-OptionalNuGetPackage: $PackageId is an ONNX Runtime package and is refused")
    }

    if (Test-NuGetPackageVersionAvailable -PackageId $PackageId -Version $Version) {
        Write-Host ('Found {0} package on NuGet; installing...' -f $PackageId)
        nuget install $PackageId -Version $Version -OutputDirectory $OutputDirectory | Out-Host
        # A dependency or a bundled copy brings ORT in under another id; a re-run finds it already there.
        $foreign = @(Get-NuGetOnnxRuntimePayload -OutputDirectory $OutputDirectory)
        if ($foreign.Count -gt 0) {
            throw (Get-OnnxChainRuleMessage -Subject ("Install-OptionalNuGetPackage: {0} left ONNX Runtime in {1}: {2}" -f
                    $PackageId, $OutputDirectory, ($foreign -join ', ')))
        }
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
    'Get-OnnxChainLayout',
    'Get-OnnxRuntimeFile',
    'Test-NuGetPackageVersionAvailable',
    'Install-OptionalNuGetPackage'
)
