#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Consumer-side proof a shipped tree carries only the chain ORT, no image stage loads it; see docs/onnxruntime-single-source.md

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
        Core, provider bridge and DirectML.dll when the chain has them; -All adds every runtime DLL, EP sidecars included.
        Get-OnnxChainLayout validates the source; Assert-ChainOrtTree (G6) judges provenance afterwards.
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
        What G6 does not grade, one finding per line: MISSING onnxruntime.dll, STRAY ORT-family DLLs, CHANGED non-ORT bytes.
    .DESCRIPTION
        The chain installs are ORT's prefix plus, when ONNX_GENAI_ROOT names one, the chain GenAI install.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$OrtDirectory)

    $prefix = Get-OrtChainPrefix
    $genAi = @(if ($env:ONNX_GENAI_ROOT) { "$env:ONNX_GENAI_ROOT\lib", "$env:ONNX_GENAI_ROOT\bin" })
    $chain = @{}
    foreach ($dir in @($genAi) + @("$prefix\lib", "$prefix\bin")) {
        foreach ($f in (Get-OrtFamilyFile -Directory $dir)) { $chain[$f.Name] = $f.FullName }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath (Join-Path $OrtDirectory 'onnxruntime.dll') -PathType Leaf)) {
        $lines.Add("MISSING $OrtDirectory\onnxruntime.dll: without it a client host loads System32's Windows ML build")
    }
    foreach ($file in (Get-OrtFamilyFile -Directory $OrtDirectory)) {
        if (-not $chain.ContainsKey($file.Name)) { $lines.Add("STRAY $($file.FullName) is not a file of the chain ORT ($prefix) or GenAI install"); continue }
        # An ORT instance G6 grades byte for byte; DirectML.dll and GenAI's DLL it does not.
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
        Proves -Root carries exactly the chain ONNX Runtime: throws with every fatal finding, else returns G6's census.
    .DESCRIPTION
        G6 over all of -Root plus Get-OrtPayloadFinding for -OrtDirectory, where the exe loads ORT from (default -Root).
    .PARAMETER WaiveUnresolved
        For a Python package using os.add_dll_directory, which G6 does not model: UNRESOLVED only reports, byte verdicts stay fatal.
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
        True when G6 counts the binary as an ORT consumer: it names OrtGetApiBase or imports an ORT DLL.
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
        True when the exe or any shipped non-ORT DLL is an ORT consumer, which loads System32's ORT if none ships.
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
        Copies the exe and its DLLs into a fresh -Destination and proves that copy, so the bytes proved are the bytes shipped.
    .PARAMETER IncludeDirectory
        Subdirectories that ship whole with the exe (lib, for GStreamer plugins), copied before the proof; missing ones skipped.
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
