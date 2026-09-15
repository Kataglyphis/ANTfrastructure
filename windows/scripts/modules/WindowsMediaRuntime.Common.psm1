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
# directory plus the ONNX Runtime NuGet native directories, and neither has a
# stable file list: GStreamer's core DLLs pull glib/gobject/orc/ffi by name that
# changes with the build, and the ONNX packages differ per execution provider.
# A curated name list is a list that goes stale silently, one missing DLL at a
# time, and the failure is a DLL-load error at app start with no clue in it.
#
# WHAT IS DELIBERATELY NOT HERE. Nothing throws when there is no payload. A
# configuration with no GStreamer and no ONNX_ROOT is a legitimate build (the
# media features are opt-in); the run warns, names the target, and carries on.

Set-StrictMode -Version Latest

# Write-BuildLog / Write-BuildLogWarning. Plain, unforced import: an entry
# script's -Force -Global copy must not be displaced (WindowsCMake.Common's
# header records what happens when it is).
Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
# Get-OnnxPackageLayout. Same terms.
Import-Module (Join-Path $PSScriptRoot 'WindowsOnnx.Common.psm1')
# Get-WindowsRuntimeIdentifier. Imported DIRECTLY rather than borrowed through
# WindowsOnnx.Common's own import: a transitive import is a dependency nothing
# declares, and this module names the rid itself in the recursive probe below.
Import-Module (Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1')

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

<#
.SYNOPSIS
    The directories whose DLLs make up the media runtime closure, in load order.
.DESCRIPTION
    GStreamer first (its bin directory carries the core plus the glib/gobject
    dependency set), then the ONNX Runtime NuGet native directories.

    Every source is PROBED, never assumed: a machine without GStreamer, or a
    build with no ONNX_ROOT, returns fewer directories rather than failing.
.PARAMETER GStreamerRoot
    Extra GStreamer bin directories to probe BEFORE the well-known ones.
.PARAMETER OnnxRoot
    NuGet package root. Defaults to $env:ONNX_ROOT.
.PARAMETER OnnxVersion
.PARAMETER OnnxGenAiVersion
.PARAMETER OnnxDirectMlVersion
    The three package versions Get-OnnxPackageLayout needs. Each defaults to its
    environment variable. If any is missing the NuGet layout is skipped -- the
    recursive probe below still finds a hand-laid-out tree.
.PARAMETER Context
    Build context for logging. Optional: the resolver is usable from a probe.
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
        [object]$Context = $null
    )

    $directories = [System.Collections.Generic.List[string]]::new()

    foreach ($candidate in (@($GStreamerRoot) + @(
                'C:\gstreamer\bin',
                'C:\gstreamer\1.0\msvc_x86_64\bin',
                'C:\Program Files\gstreamer\1.0\msvc_x86_64\bin'))) {
        Add-MediaRuntimeDirectory -Directories $directories -Candidate $candidate
    }

    # All four are required, and not because Get-OnnxPackageLayout is fussy: the
    # three versions are part of the PATH it builds, so a missing one resolves to
    # a package directory that cannot exist and every probe below it is wasted.
    if (-not [string]::IsNullOrWhiteSpace($OnnxRoot) -and
        -not [string]::IsNullOrWhiteSpace($OnnxVersion) -and
        -not [string]::IsNullOrWhiteSpace($OnnxGenAiVersion) -and
        -not [string]::IsNullOrWhiteSpace($OnnxDirectMlVersion)) {
        try {
            $layout = Get-OnnxPackageLayout -OnnxRoot $OnnxRoot -OnnxVersion $OnnxVersion `
                -OnnxGenAiVersion $OnnxGenAiVersion -OnnxDirectMlVersion $OnnxDirectMlVersion

            foreach ($candidate in @(
                    $layout.RuntimeNativeDir,
                    $layout.DirectMlNativeDir,
                    $layout.CudaNativeDir,
                    $layout.GenAiNativeDir,
                    $layout.GenAiDirectMlNativeDir,
                    $layout.GenAiCudaNativeDir)) {
                Add-MediaRuntimeDirectory -Directories $directories -Candidate $candidate
            }
        } catch {
            # A layout this build cannot describe is not a reason to abandon the
            # staging: the recursive probe below still finds the payload.
            if ($null -ne $Context) {
                Write-BuildLogWarning -Context $Context -Message "Failed to resolve ONNX runtime layout: $($_.Exception.Message)"
            }
        }
    }

    # The catch-all: any runtimes\<rid>\native under the root, including packages
    # this module does not name and trees laid out by hand. The rid is PINNED to
    # the target arch, never widened to runtimes\win-*: a win-arm64 payload
    # staged next to an x64 exe loads as a wrong-machine DLL at app start, which
    # is the least readable failure in this whole file.
    if (-not [string]::IsNullOrWhiteSpace($OnnxRoot) -and (Test-Path -LiteralPath $OnnxRoot)) {
        $nativeSuffix = '*\runtimes\{0}\native' -f (Get-WindowsRuntimeIdentifier)
        Get-ChildItem -LiteralPath $OnnxRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like $nativeSuffix } |
            ForEach-Object { Add-MediaRuntimeDirectory -Directories $directories -Candidate $_.FullName }
    }

    return @($directories)
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
    payload is a legitimate build.
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
        [string]$OnnxDirectMlVersion = $env:ONNX_DIRECTML_VERSION
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
    $runtimeDirs = @(Get-MediaRuntimeDirectory -GStreamerRoot $GStreamerRoot -OnnxRoot $OnnxRoot `
            -OnnxVersion $OnnxVersion -OnnxGenAiVersion $OnnxGenAiVersion `
            -OnnxDirectMlVersion $OnnxDirectMlVersion -Context $Context)

    if ($runtimeDirs.Count -eq 0) {
        Write-BuildLogWarning -Context $Context -Message "No external runtime dependency directories found to stage into $TargetDir"
        return 0
    }

    $staged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($runtimeDir in $runtimeDirs) {
        Write-BuildLog -Context $Context -Message "Staging runtime DLLs from: $runtimeDir"
        Get-ChildItem -LiteralPath $runtimeDir -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetDir $_.Name) -Force
            $null = $staged.Add($_.Name)
        }
    }

    Write-BuildLog -Context $Context -Message "Staged $($staged.Count) runtime DLLs into $TargetDir"
    return $staged.Count
}

Export-ModuleMember -Function Get-MediaRuntimeDirectory, Copy-MediaRuntimeBundle
