#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# A dependency-free leaf with one consumer: see docs/windows-build-resources.md § The Windows cache, tier by tier

Set-StrictMode -Version Latest

# The submodule's nearest v* tag, else TVM's apache-tvm-ffi>= bound: the version both assembled wheels resolve against.
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

# Writes the dist-info for a hand-assembled wheel; `python -m wheel pack` then adds RECORD and the archive.
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

# Read from the source tree at build time, never hardcoded.
function Get-PyprojectDependencies {
    param([Parameter(Mandatory)][string]$PyprojectText)
    # Two regexes since `classifiers = [` may precede the list; `\r?` because multiline `$` misses CRLF.
    $tbl = [regex]::Match($PyprojectText, '(?ms)^\[project\][ \t]*(?:#[^\r\n]*)?\r?$(.*?)(?=^\[|\z)')
    if (-not $tbl.Success) { return @() }
    $m = [regex]::Match($tbl.Groups[1].Value, '(?ms)^dependencies\s*=\s*\[(.*?)\][ \t]*(?:#[^\r\n]*)?\r?$')
    if (-not $m.Success) { return @() }
    return @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
}

Export-ModuleMember -Function Get-VendoredTvmFfiVersion, Write-AssembledWheelDistInfo, Get-PyprojectDependencies
