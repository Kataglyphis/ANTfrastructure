#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# What a consumer's shipped Windows tree needs to carry the image's chain ONNX Runtime and no other
# (owner rule 2026-09-23, docs/onnxruntime-single-source.md): the ORT family's names, the chain's
# DLLs staged beside an exe, and the proof -- G6 (WindowsOrtProvenance.Common) over the tree plus
# what G6 does not grade: onnxruntime.dll missing where the exe looks for it (a client host then
# loads System32's Windows ML copy), an ORT-family name the chain has not got, another DirectML.dll.
#
# Three consumers each carried this glue under their own names until 2026-09-25: OxidANT's
# WindowsOrtPayload.Common, OmniAccelerANT's WindowsOrtRunner.Common and AccelerANTgine's
# WindowsOrtBundle.Common. What stays with them is their layout: OmniAccelerANT's runner stamp,
# AccelerANTgine's install tree and Python package. A consumer-side module: no image stage loads it.
#
# NOT covered: which copy a process loads beyond G6's modelled loader order.

Set-StrictMode -Version Latest

# Guarded, never -Force: a forced nested import unloads the caller's top-level copy.
foreach ($sibling in 'WindowsOrtProvenance.Common', 'WindowsOnnx.Common') {
    if (-not (Get-Module -Name $sibling)) { Import-Module (Join-Path $PSScriptRoot "$sibling.psm1") -DisableNameChecking }
}

# What Copy-ChainOrtBeside stages without -All: the core, its provider bridge, DirectML's redist.
$script:OrtRuntimeFiles = @('onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'DirectML.dll')
$script:OrtFamily = @('onnxruntime*.dll', 'DirectML.dll')

function Test-OrtFamilyName {
    <#
    .SYNOPSIS
        True for a DLL name of the ONNX Runtime family: onnxruntime*.dll, providers and GenAI included, and DirectML.dll.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    return @($script:OrtFamily | Where-Object { $Name -like $_ }).Count -gt 0
}

function Get-OrtFamilyFile {
    <#
    .SYNOPSIS
        The ORT-family files in -Directory, below it too with -Recurse; none for a directory that does not exist.
    #>
    [OutputType([System.IO.FileInfo[]])]
    param([Parameter(Mandatory)][string]$Directory, [switch]$Recurse)
    return @(Get-ChildItem -LiteralPath $Directory -File -Recurse:$Recurse -ErrorAction SilentlyContinue | Where-Object { Test-OrtFamilyName -Name $_.Name })
}

function Copy-ChainOrtBeside {
    <#
    .SYNOPSIS
        Replaces every ORT-family DLL at the top of -Destination with the chain install's; returns the copies.
    .DESCRIPTION
        The chain install is Get-OnnxChainLayout's, which throws for an unset ONNX_ROOT, a NuGet tree, a
        release zip and another arch's onnxruntime.dll. Staged are the core, the provider bridge and
        DirectML.dll, each when the chain has it; -All stages every DLL of the chain's runtime directories,
        EP sidecars (QNN's backends, WebGPU's DXC) included. bin wins a name both directories hold.
        Provenance is judged afterwards, by Assert-ChainOrtTree (G6).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OnnxRoot,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$All
    )

    $layout = Get-OnnxChainLayout -OnnxRoot $OnnxRoot -OnnxGenAiRoot ''
    $source = [ordered]@{}
    foreach ($dir in @($layout.LibDir, $layout.BinDir)) {
        foreach ($dll in @(Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
            if ($All -or $script:OrtRuntimeFiles -contains $dll.Name) { $source[$dll.Name] = $dll.FullName }
        }
    }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'stage the chain ONNX Runtime')) { return }
    $null = New-Item -ItemType Directory -Force -Path $Destination
    Get-OrtFamilyFile -Directory $Destination | Remove-Item -Force
    return [string[]]@(foreach ($name in $source.Keys) {
            Copy-Item -LiteralPath $source[$name] -Destination $Destination -Force
            Join-Path $Destination $name
        })
}

function Get-OrtPayloadFinding {
    <#
    .SYNOPSIS
        What G6 does not grade, one line per finding: onnxruntime.dll missing from -OrtDirectory (MISSING),
        an ORT-family DLL there that the chain install has not got (STRAY), and one that is no ORT instance,
        DirectML.dll, with other bytes than the chain's (CHANGED).
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$OrtDirectory)

    $prefix = Get-OrtChainPrefix
    $chain = @{}
    foreach ($dir in "$prefix\lib", "$prefix\bin") {
        foreach ($f in (Get-OrtFamilyFile -Directory $dir)) { $chain[$f.Name] = $f.FullName }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath (Join-Path $OrtDirectory 'onnxruntime.dll') -PathType Leaf)) {
        $lines.Add("MISSING $OrtDirectory\onnxruntime.dll: without it a client host loads System32's Windows ML copy")
    }
    foreach ($file in (Get-OrtFamilyFile -Directory $OrtDirectory)) {
        if (-not $chain.ContainsKey($file.Name)) { $lines.Add("STRAY $($file.FullName) is not a file of the chain install ($prefix)"); continue }
        # An ORT instance G6 grades byte for byte; DirectML.dll it does not.
        if (Test-OrtInstanceName -Name $file.Name) { continue }
        $same = (Get-FileHash -LiteralPath $chain[$file.Name] -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if (-not $same) { $lines.Add("CHANGED $($file.FullName) is not the chain's $($chain[$file.Name])") }
    }
    return $lines.ToArray()
}

function Stop-OrtPayloadProof {
    # The one refusal every proof here ends in, a finding per line; nothing to refuse, it returns.
    param([Parameter(Mandatory)][string]$Root, [AllowEmptyCollection()][string[]]$Finding = @())
    if (@($Finding).Count -eq 0) { return }
    $lines = @("ONNX Runtime in $Root is not exactly the image's chain build (G6):") + @($Finding | ForEach-Object { "  $_" })
    throw ($lines -join [Environment]::NewLine)
}

function Assert-ChainOrtTree {
    <#
    .SYNOPSIS
        Proves -Root carries exactly the image's chain ONNX Runtime: throws with every fatal finding, else
        returns G6's census.
    .DESCRIPTION
        G6 (Test-OrtProvenanceTree) over all of -Root, plus Get-OrtPayloadFinding for -OrtDirectory, the
        directory the exe loads ORT from (default: -Root).
    .PARAMETER WaiveUnresolved
        For a Python package whose __init__ registers -OrtDirectory with os.add_dll_directory, which Windows
        searches before System32. G6 models an exe's loader, not that call, so its UNRESOLVED verdicts are
        reported and not fatal; every byte verdict still is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$OrtDirectory = '',
        [switch]$WaiveUnresolved
    )

    if (-not $OrtDirectory) { $OrtDirectory = $Root }
    $census = Test-OrtProvenanceTree -Root $Root -PassThru
    $waived = @($census.Findings | Where-Object { $WaiveUnresolved -and $_.Fatal -and $_.Verdict -eq 'UNRESOLVED' })
    $findings = @(Get-OrtPayloadFinding -OrtDirectory $OrtDirectory) +
        @($census.Findings | Where-Object { $_.Fatal -and $waived -notcontains $_ } | ForEach-Object { "$($_.Verdict) $($_.Path) -- $($_.Detail)" })
    Stop-OrtPayloadProof -Root $Root -Finding $findings
    if ($waived.Count -gt 0) {
        Write-Host "  UNRESOLVED above ($($waived.Count)) is not fatal: the package registers $OrtDirectory with os.add_dll_directory, searched before System32, and it holds the chain onnxruntime.dll."
    }
    return $census
}

function Test-ExeLoadsOrt {
    <#
    .SYNOPSIS
        True when G6 counts the binary as an ORT consumer: it names the ORT ABI (OrtGetApiBase, which a
        load-dynamic binding resolves) or imports an ORT DLL.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)

    $fact = Get-OrtBinaryFact -Path $Path
    if ($fact.Error) { throw "Cannot read $Path to decide whether it loads ONNX Runtime: $($fact.Error)" }
    return (@($fact.Abi).Count -gt 0) -or (@($fact.Imports | Where-Object { Test-OrtInstanceName -Name $_ }).Count -gt 0)
}

function Test-PayloadLoadsOrt {
    <#
    .SYNOPSIS
        True when the exe, or any non-ORT DLL a payload ships (beside it, or under an -IncludeDirectory
        tree), is an ORT consumer (Test-ExeLoadsOrt): a consumer DLL beside a plain exe still loads ORT,
        System32's if none ships.
    #>
    param([Parameter(Mandatory)][string]$ExePath, [string[]]$IncludeDirectory = @())

    if (Test-ExeLoadsOrt -Path $ExePath) { return $true }
    $exeDir = Split-Path $ExePath -Parent
    $dlls = @(Get-ChildItem -LiteralPath $exeDir -Filter '*.dll' -File) +
        @($IncludeDirectory | ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $exeDir $_) -Filter '*.dll' -File -Recurse -ErrorAction SilentlyContinue })
    return @($dlls | Where-Object { -not (Test-OrtFamilyName -Name $_.Name) -and (Test-ExeLoadsOrt -Path $_.FullName) }).Count -gt 0
}

function New-OrtProvenPayload {
    <#
    .SYNOPSIS
        Copies the exe and the DLLs beside it into a fresh -Destination and proves that payload: when it
        loads ONNX Runtime (Test-PayloadLoadsOrt), Assert-ChainOrtTree must pass; otherwise it carries no
        ORT at all. A package ships from -Destination, so the bytes proved are the bytes shipped.
    .PARAMETER IncludeDirectory
        Subdirectories beside the exe that ship whole with it (lib, for its GStreamer plugins). Copied
        before the proof, so G6 grades them with everything else; a missing one is skipped.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$IncludeDirectory = @()
    )

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { throw "Expected executable not found: $ExePath" }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'build and prove the release payload')) { return }
    $loadsOrt = Test-PayloadLoadsOrt -ExePath $ExePath -IncludeDirectory $IncludeDirectory
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $Destination
    Copy-Item -LiteralPath $ExePath -Destination $Destination
    $exeDir = Split-Path $ExePath -Parent
    Get-ChildItem -LiteralPath $exeDir -Filter '*.dll' -File |
        Where-Object { $loadsOrt -or -not (Test-OrtFamilyName -Name $_.Name) } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    $included = [string[]]@(foreach ($name in @($IncludeDirectory | Select-Object -Unique)) {
            $source = Join-Path $exeDir $name
            if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
            $target = Join-Path $Destination $name
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent)
            Copy-Item -LiteralPath $source -Destination $target -Recurse
            $target
        })

    if ($loadsOrt) {
        $null = Assert-ChainOrtTree -Root $Destination
    } else {
        Stop-OrtPayloadProof -Root $Destination -Finding @(Get-OrtTreeFact -ContentRoot @($Destination) | Where-Object IsInstance |
                ForEach-Object { "UNEXPECTED $($_.Path) is an ONNX Runtime binary beside an exe that does not load one" })
    }
    return [pscustomobject]@{
        Directory = $Destination
        Exe       = Join-Path $Destination (Split-Path $ExePath -Leaf)
        Dlls      = [string[]]@(Get-ChildItem -LiteralPath $Destination -Filter '*.dll' -File | ForEach-Object FullName)
        Included  = $included
        OrtDlls   = [string[]]@(Get-OrtFamilyFile -Directory $Destination | ForEach-Object FullName)
        LoadsOrt  = $loadsOrt
    }
}

Export-ModuleMember -Function Test-OrtFamilyName, Get-OrtFamilyFile, Copy-ChainOrtBeside, Get-OrtPayloadFinding,
    Assert-ChainOrtTree, Test-ExeLoadsOrt, Test-PayloadLoadsOrt, New-OrtProvenPayload
