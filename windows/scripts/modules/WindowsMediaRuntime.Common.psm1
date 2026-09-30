# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Copied by directory, not name list, which would go stale one silent DLL-load failure at a time; ORT must be the chain's.

Set-StrictMode -Version Latest

# Unforced: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
Import-Module (Join-Path $PSScriptRoot 'WindowsOnnx.Common.psm1')

# Resolved first, so two spellings of one directory cannot both be walked.
function Add-MediaRuntimeDirectory {
    [CmdletBinding()]
    param(
        # A Mandatory collection refuses an empty list, which the first call always passes.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Directories,
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
    if (-not (Test-Path -LiteralPath $Candidate)) { return }
    $resolved = (Resolve-Path -LiteralPath $Candidate).Path
    if (-not $Directories.Contains($resolved)) { $Directories.Add($resolved) }
}

# The chain directories are resolved FIRST (a bad root throws before anything is listed) and staged LAST.
function Resolve-MediaRuntimeClosure {
    param(
        [string[]]$GStreamerRoot = @(),
        [string]$OnnxRoot = '',
        [string]$OnnxGenAiRoot = ''
    )

    $chain = [System.Collections.Generic.List[string]]::new()
    if ("$OnnxRoot$OnnxGenAiRoot".Trim()) {
        foreach ($candidate in @((Get-OnnxChainLayout -OnnxRoot $OnnxRoot -OnnxGenAiRoot $OnnxGenAiRoot).RuntimeDirectories)) {
            Add-MediaRuntimeDirectory -Directories $chain -Candidate $candidate
        }
    }

    # GSTREAMER_BIN is the image's C:\runtime\bin, without which an image build stages no GStreamer; the rest are the SDK's.
    $directories = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in (@($GStreamerRoot) + @(
                $env:GSTREAMER_BIN,
                'C:\gstreamer\bin',
                'C:\gstreamer\1.0\msvc_x86_64\bin',
                'C:\Program Files\gstreamer\1.0\msvc_x86_64\bin'))) {
        Add-MediaRuntimeDirectory -Directories $directories -Candidate $candidate
    }
    foreach ($dir in @($directories)) {
        if ($chain -contains $dir) { [void]$directories.Remove($dir); continue }
        $foreign = @(Get-OnnxRuntimeFile -Path $dir | Where-Object { $_.Extension -eq '.dll' })
        if ($foreign.Count -gt 0) {
            throw ("ONNX Runtime DLLs outside the chain install would be staged from {0}: {1}. Only ONNX_ROOT and " +
                "ONNX_GENAI_ROOT may supply them (owner rule 2026-09-23).") -f $dir, (($foreign | ForEach-Object { $_.Name }) -join ', ')
        }
    }
    foreach ($dir in $chain) { $directories.Add($dir) }

    return [pscustomobject]@{ Directories = [string[]]@($directories); Chain = [string[]]@($chain) }
}

# Every ORT DLL left in TargetDir (top level only) must be byte-identical to the chain file of that name.
function Assert-MediaRuntimeOnnxFromChain {
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [string[]]$ChainDirectory = @()
    )

    $chainHash = @{}
    foreach ($dir in $ChainDirectory) {
        foreach ($file in @(Get-OnnxRuntimeFile -Path $dir | Where-Object { $_.Extension -eq '.dll' })) {
            $chainHash[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    $offenders = @(foreach ($file in @(Get-OnnxRuntimeFile -Path $TargetDir | Where-Object { $_.Extension -eq '.dll' })) {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            if (-not $chainHash.ContainsKey($file.Name) -or $chainHash[$file.Name] -ne $hash) { $file.Name }
        })
    if ($offenders.Count -gt 0) {
        throw ("{0} holds ONNX Runtime DLLs that are not the chain's bytes: {1}. Remove them, or point ONNX_ROOT " +
            "(and ONNX_GENAI_ROOT) at the chain install (owner rule 2026-09-23).") -f $TargetDir, ($offenders -join ', ')
    }
}

<#
.SYNOPSIS
    The directories whose DLLs make up the media runtime closure, in load order.
.DESCRIPTION
    GStreamer, then GenAI, then ORT last so it wins a collision; absent sources are skipped, non-chain ORT throws.
.PARAMETER GStreamerRoot
    Extra GStreamer bin directories probed before $env:GSTREAMER_BIN and the SDK installer's locations.
.PARAMETER OnnxRoot
    The chain ONNX Runtime install. Defaults to $env:ONNX_ROOT.
.PARAMETER OnnxVersion
.PARAMETER OnnxGenAiVersion
.PARAMETER OnnxDirectMlVersion
    Accepted and ignored: the NuGet layout they built paths for is gone.
.PARAMETER Context
    Build context for logging. Optional: the resolver is usable from a probe.
.PARAMETER OnnxGenAiRoot
    The chain GenAI install. Defaults to $env:ONNX_GENAI_ROOT.
#>
function Get-MediaRuntimeDirectory {
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [string[]]$GStreamerRoot = @(),
        [string]$OnnxRoot = $env:ONNX_ROOT,
        [string]$OnnxVersion = $env:ONNX_VERSION,
        [string]$OnnxGenAiVersion = $env:ONNX_GENAI_VERSION,
        [string]$OnnxDirectMlVersion = $env:ONNX_DIRECTML_VERSION,
        [object]$Context = $null,
        [string]$OnnxGenAiRoot = $env:ONNX_GENAI_ROOT
    )

    $closure = Resolve-MediaRuntimeClosure -GStreamerRoot $GStreamerRoot -OnnxRoot $OnnxRoot -OnnxGenAiRoot $OnnxGenAiRoot
    if ($null -ne $Context -and $closure.Chain.Count -gt 0) {
        Write-BuildLog -Context $Context -Message "ONNX Runtime from the chain install: $($closure.Chain -join ', ')"
    }
    return @($closure.Directories)
}

<#
.SYNOPSIS
    Stages the media runtime DLL closure into a directory beside a built exe.
.DESCRIPTION
    Returns the distinct DLL count, 0 for a legitimate no-media build; later dirs win; a non-chain ORT DLL throws.
.PARAMETER Context
    Build context for logging.
.PARAMETER TargetDir
    Where the DLLs go. Created when missing.
#>
function Copy-MediaRuntimeBundle {
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Context,
        [Parameter(Mandatory)][string]$TargetDir,
        [string[]]$GStreamerRoot = @(),
        [string]$OnnxRoot = $env:ONNX_ROOT,
        [string]$OnnxVersion = $env:ONNX_VERSION,
        [string]$OnnxGenAiVersion = $env:ONNX_GENAI_VERSION,
        [string]$OnnxDirectMlVersion = $env:ONNX_DIRECTML_VERSION,
        [string]$OnnxGenAiRoot = $env:ONNX_GENAI_ROOT
    )

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    # @() at the call site: an empty returned array unrolls to $null, whose .Count throws under StrictMode.
    $closure = Resolve-MediaRuntimeClosure -GStreamerRoot $GStreamerRoot -OnnxRoot $OnnxRoot -OnnxGenAiRoot $OnnxGenAiRoot
    $runtimeDirs = @($closure.Directories)

    $staged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($runtimeDir in $runtimeDirs) {
        Write-BuildLog -Context $Context -Message "Staging runtime DLLs from: $runtimeDir"
        Get-ChildItem -LiteralPath $runtimeDir -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetDir $_.Name) -Force
            $null = $staged.Add($_.Name)
        }
    }
    Assert-MediaRuntimeOnnxFromChain -TargetDir $TargetDir -ChainDirectory @($closure.Chain)

    if ($runtimeDirs.Count -eq 0) {
        Write-BuildLogWarning -Context $Context -Message "No external runtime dependency directories found to stage into $TargetDir"
        return 0
    }

    Write-BuildLog -Context $Context -Message "Staged $($staged.Count) runtime DLLs into $TargetDir"
    return $staged.Count
}

Export-ModuleMember -Function Get-MediaRuntimeDirectory, Copy-MediaRuntimeBundle
