# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Staging the media runtime DLL closure next to a built executable.
#
# THE THREE CALL SITES. AccelerANTgine's scripts/windows/Build-Windows.ps1 ran
# `Copy-RuntimeDependencies -TargetDir (Join-Path $dir 'bin')` after each of its
# three builds -- ClangCL debug, ClangCL profile, ClangCL release -- against a
# local Get-RuntimeDependencyDirectories. Its own comment said the pair stayed
# there "under the two-consumer rule"; the rule is met now, so the resolver and
# the copy live here and the three call sites are one exported function.
#
# WHY THE COPY IS BY DIRECTORY AND NOT BY NAME. The payload is GStreamer's bin
# directory plus the chain ONNX Runtime / GenAI install directories, and neither has a
# stable file list: GStreamer's core DLLs pull glib/gobject/orc/ffi by name that
# changes with the build, and the ONNX install differs per execution provider.
# A curated name list is a list that goes stale silently, one missing DLL at a
# time, and the failure is a DLL-load error at app start with no clue in it.
#
# WHAT IS DELIBERATELY NOT HERE. Nothing throws when there is no payload. A
# configuration with no GStreamer and no ONNX_ROOT is a legitimate build (the
# media features are opt-in); the run warns, names the target, and carries on.
#
# ORT is the chain's only: a non-chain ONNX_ROOT, or an ORT DLL from any other directory, throws.
# NOT covered: ORT linked into another DLL, or byte provenance of ONNX_ROOT (the ORT census).

Set-StrictMode -Version Latest

# Write-BuildLog / Write-BuildLogWarning. Plain, unforced import: an entry
# script's -Force -Global copy must not be displaced (WindowsCMake.Common's
# header records what happens when it is).
Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
# Get-OnnxChainLayout / Get-OnnxRuntimeFile. Same terms.
Import-Module (Join-Path $PSScriptRoot 'WindowsOnnx.Common.psm1')

# Appends a directory when it exists and is not already listed, resolved so two
# spellings of one directory cannot both be walked.
function Add-MediaRuntimeDirectory {
    [CmdletBinding()]
    param(
        # AllowEmptyCollection, and it is load-bearing: a Mandatory collection
        # parameter REFUSES an empty list, so the first call - when the list is
        # still empty, which is every call - failed with "cannot be bound ...
        # because it is an empty collection".
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

    $directories = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in (@($GStreamerRoot) + @(
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
    GStreamer first (its bin directory carries the core plus the glib/gobject
    dependency set), then the chain ONNX Runtime GenAI and ONNX Runtime install
    directories, the chain ORT last so it wins a name collision.

    Every source is PROBED, never assumed: a machine without GStreamer, or a
    build with no ONNX_ROOT, returns fewer directories rather than failing.
    What DOES throw: an ONNX_ROOT/ONNX_GENAI_ROOT that is not the chain install
    (see Get-OnnxChainLayout), and an ONNX Runtime DLL in any other directory.
.PARAMETER GStreamerRoot
    Extra GStreamer bin directories to probe BEFORE the well-known ones.
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
    Copies every *.dll from each directory Get-MediaRuntimeDirectory found into
    -TargetDir, and reports how many distinct names were staged. Later
    directories win on a name collision, which is why the order the resolver
    returns is load order and not alphabetical.

    Returns the number of distinct DLL names staged, so a caller can gate on it;
    zero is returned rather than thrown, because a configuration with no media
    payload is a legitimate build. Throws when an ONNX Runtime DLL left in
    -TargetDir is not byte-identical to the chain's, staged or not.
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

    # @(...) AT THE CALL SITE, not only inside the resolver. PowerShell unrolls a
    # returned array into the pipeline, so an empty one yields zero objects and
    # the assignment lands $null. Under Set-StrictMode -Version Latest -- which
    # every entry script in this family sets -- $null.Count then throws "The
    # property 'Count' cannot be found on this object" and kills a Critical build
    # step AFTER a fully successful compile, which is exactly the case this guard
    # was written to handle gracefully.
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
