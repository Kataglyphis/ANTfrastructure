#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# TVM-specific facts that no other component shares.
#
# WHY THIS IS ITS OWN MODULE — CACHE BOUNDARY, NOT TASTE, AND IT IS THE POINT
# OF THE #134 WAVE.
# Before #134 there were exactly six module homes on the media lane: the
# `buildmods` stage's .psm1 set, which is the import closure of
# WindowsSourceBuild.Common and is mounted into ALL media/merge RUNs. Anything
# put there re-keyed the ~75 min ONNX branch, the OpenCV branch and the FFmpeg
# branch to change a TVM constant. So TVM-only helpers had no choice but to live
# inside Build-TvmFromSource.ps1, where they were stage-local and cheap but
# reachable by tests only through the script's AST.
#
# Dockerfile.media-builder now derives `FROM buildmods AS tvmmods` and adds this
# file, and ONLY the `media-tvm-built` RUN mounts that stage. media-tvm runs
# parallel to media-core, so a TVM-private module costs nothing on the long
# pole. Editing this file re-runs the TVM branch and nothing else — that is the
# property BuildKit.ModuleClosure.Tests.ps1 exists to keep.
#
# Therefore: do NOT add this module to `buildmods` itself, and do not mount
# `tvmmods` into any RUN other than media-tvm-built. Adding a second consumer
# means the code belongs in buildmods and the cache win is gone.
#
# DELIBERATELY DEPENDENCY-FREE: no Import-Module. It is mounted alongside the
# buildmods six, so Shared is available if a future function needs it — but
# taking that dependency here would be the first step back toward the closure
# this module exists to escape.

Set-StrictMode -Version Latest

# The vendored tvm-ffi's own version: the nearest v* tag of the submodule
# checkout (PEP 440-normalised: v0.1.13-post3 -> 0.1.13.post3), else the lower
# bound TVM's pyproject demands (apache-tvm-ffi>=X) -- the version that makes
# the two assembled wheels resolve against each other.
# Pure function (fixture test SourceBuild.TvmAssembledWheel.Tests.ps1).
function Get-VendoredTvmFfiVersion {
    param(
        [string]$DescribeOutput = '',
        [string]$TvmPyprojectText = ''
    )
    $d = "$DescribeOutput".Trim()
    if ($d -match '^v?(\d+(?:\.\d+)*)(?:[-.]?(post\d+|rc\d+|a\d+|b\d+))?$') {
        $v = $Matches[1]
        if ($Matches[2]) { $v += '.' + $Matches[2] }
        return $v
    }
    $m = [regex]::Match($TvmPyprojectText, 'apache-tvm-ffi\s*>=\s*([0-9][0-9A-Za-z.+!-]*)')
    if ($m.Success) { return $m.Groups[1].Value }
    throw 'Get-VendoredTvmFfiVersion: neither a v* tag on the tvm-ffi submodule nor an apache-tvm-ffi>= bound in TVM''s pyproject.toml'
}

# Writes the dist-info a binary wheel needs (METADATA, WHEEL, top_level.txt) into
# an already-laid-out package tree; `python -m wheel pack` then produces RECORD +
# the archive. Generic in every parameter (#134) -- assembling a wheel by hand is
# what every cross consumer scikit-build-core cannot build has to do.
# Fixture test: SourceBuild.TvmAssembledWheel.Tests.ps1.
function Write-AssembledWheelDistInfo {
    param(
        [Parameter(Mandatory)][string]$Name,        # distribution name, e.g. apache-tvm-ffi
        [Parameter(Mandatory)][string]$Version,     # PEP 440
        [Parameter(Mandatory)][string]$PackageRoot, # dir whose child dirs are the top-level packages
        [string]$PythonTag = 'cp314',
        [string]$AbiTag = 'cp314',
        [string]$PlatformTag = 'win_arm64',
        [string[]]$RequiresDist = @(),
        [string]$RequiresPython = '',
        [string]$Summary = '',
        [string]$Generator = 'kataglyphis-assembled-wheel'
    )
    if (-not (Test-Path $PackageRoot -PathType Container)) { throw "Write-AssembledWheelDistInfo: package root $PackageRoot does not exist" }
    $distName = ($Name -replace '[-_.]+', '_')
    $distInfo = Join-Path $PackageRoot "$distName-$Version.dist-info"
    New-Item -Path $distInfo -ItemType Directory -Force | Out-Null
    $meta = @('Metadata-Version: 2.1', "Name: $Name", "Version: $Version")
    if ($Summary) { $meta += "Summary: $Summary" }
    if ($RequiresPython) { $meta += "Requires-Python: $RequiresPython" }
    foreach ($r in $RequiresDist) { if ($r) { $meta += "Requires-Dist: $r" } }
    [System.IO.File]::WriteAllText((Join-Path $distInfo 'METADATA'), (($meta -join "`n") + "`n"))
    $wheelMeta = @('Wheel-Version: 1.0', "Generator: $Generator", 'Root-Is-Purelib: false', "Tag: $PythonTag-$AbiTag-$PlatformTag")
    [System.IO.File]::WriteAllText((Join-Path $distInfo 'WHEEL'), (($wheelMeta -join "`n") + "`n"))
    $top = @(Get-ChildItem -Path $PackageRoot -Directory | Where-Object { $_.Name -notlike '*.dist-info' } | ForEach-Object { $_.Name })
    if ($top.Count -eq 0) { throw "Write-AssembledWheelDistInfo: no top-level package directory under $PackageRoot" }
    [System.IO.File]::WriteAllText((Join-Path $distInfo 'top_level.txt'), (($top -join "`n") + "`n"))
    return $distInfo
}

# A pyproject's [project] dependencies = [...] block, read from the source
# tree at build time (never hardcoded here).
function Get-PyprojectDependencies {
    param([Parameter(Mandatory)][string]$PyprojectText)
    # Two steps -- the [project] table body, then the list inside it: one regex
    # forbidding any `[` between them matched nothing once `classifiers = [`
    # preceded the list, and the assembled wheels shipped with NO requirements.
    # `\r?` before every `$`: .NET multiline `$` matches only immediately before
    # `\n`, so a CRLF checkout silently yields an empty list.
    $tbl = [regex]::Match($PyprojectText, '(?ms)^\[project\][ \t]*(?:#[^\r\n]*)?\r?$(.*?)(?=^\[|\z)')
    if (-not $tbl.Success) { return @() }
    $m = [regex]::Match($tbl.Groups[1].Value, '(?ms)^dependencies\s*=\s*\[(.*?)\][ \t]*(?:#[^\r\n]*)?\r?$')
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}

Export-ModuleMember -Function Get-VendoredTvmFfiVersion, Write-AssembledWheelDistInfo, Get-PyprojectDependencies
