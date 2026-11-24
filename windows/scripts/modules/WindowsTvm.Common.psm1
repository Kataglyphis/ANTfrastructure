#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# TVM wheel metadata and assembly: see docs/windows-build-resources.md § The Windows cache, tier by tier

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsNative.Common.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1') -ErrorAction Stop


# Tagless checkouts need TVM's FFI bound instead of setuptools-scm's development fallback.
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

function Get-TvmFfiSourceVersion {
    param([Parameter(Mandatory)][string]$SourceDir)
    $ffiSource = Join-Path $SourceDir '3rdparty\tvm-ffi'
    $tag = Invoke-NativeProbeProcess -FilePath git -ArgumentList @('-C', $ffiSource, 'describe', '--tags', '--abbrev=0', '--match', 'v*')
    $describe = if ($tag.ExitCode -eq 0) { $tag.Text } else { '' }
    $pyproject = [IO.File]::ReadAllText((Join-Path $SourceDir 'pyproject.toml'))
    return Get-VendoredTvmFfiVersion -DescribeOutput $describe -TvmPyprojectText $pyproject
}

Export-ModuleMember -Function Get-TvmFfiSourceVersion

# Selected-version metadata does not prove dependency resolution, ABI, importability or inference.
function Assert-TvmFfiPackageVersion {
    param([Parameter(Mandatory)][hashtable]$Python, [Parameter(Mandatory)][string]$ExpectedVersion, [string]$WheelPath = '')
    $source = @'
import importlib.metadata as metadata
import json
import re
import sys

expected, wheel = sys.argv[1:]
distributions = list(metadata.distributions(path=[wheel])) if wheel else list(metadata.distributions(name="apache-tvm-ffi"))
if len(distributions) != 1 or re.sub(r"[-_.]+", "-", distributions[0].metadata["Name"]).lower() != "apache-tvm-ffi":
    raise RuntimeError("Expected exactly one apache-tvm-ffi distribution")
version = distributions[0].version
if version != expected:
    raise RuntimeError(f"apache-tvm-ffi metadata {version} differs from selected {expected}")
print(json.dumps({"version": version, "wheel": wheel}))
'@
    $report = Invoke-PythonJsonProbe -Python $Python.Exe -Source $source -Prefix 'tvm-ffi-version' -InterpreterArgument @('-I') `
        -ArgumentList @($ExpectedVersion, $WheelPath) -DiagnosticTail -FailurePrefix 'TVM-FFI metadata'
    Write-Host "TVM-FFI metadata OK ($($report.version); wheel='$WheelPath')"
}

Export-ModuleMember -Function Assert-TvmFfiPackageVersion

function Invoke-TvmFfiPythonBuild {
    param([Parameter(Mandatory)][hashtable]$Python, [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][scriptblock]$Build, [switch]$Wheel)
    $ffiVersion = Get-TvmFfiSourceVersion -SourceDir $SourceDir
    $buildResult = Invoke-WithProcessEnvironment -Environment @{ SETUPTOOLS_SCM_PRETEND_VERSION_FOR_APACHE_TVM_FFI = $ffiVersion } -ScriptBlock $Build
    if (-not $Wheel -or $buildResult) {
        $wheelPath = if ($Wheel) { $buildResult } else { '' }
        Assert-TvmFfiPackageVersion -Python $Python -ExpectedVersion $ffiVersion -WheelPath $wheelPath
    }
    return $buildResult
}

Export-ModuleMember -Function Invoke-TvmFfiPythonBuild

# Writes the dist-info for a hand-assembled wheel; `python -m wheel pack` then adds RECORD and the archive.
function Write-AssembledWheelDistInfo {
    param(
        [Parameter(Mandatory)][string]$Name,        # distribution name, e.g. apache-tvm-ffi
        [Parameter(Mandatory)][string]$Version,     # PEP 440
        [Parameter(Mandatory)][string]$PackageRoot, # dir whose child dirs are the top-level packages
        [Parameter(Mandatory)][string]$PythonTag,
        [Parameter(Mandatory)][string]$AbiTag,
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

function New-AssembledPythonWheel {
    param(
        [Parameter(Mandatory)][hashtable]$Metadata,
        [Parameter(Mandatory)][string]$PackExe,
        [Parameter(Mandatory)][string]$OutDir
    )
    [void](Write-AssembledWheelDistInfo @Metadata)
    $packageRoot = $Metadata.PackageRoot
    $null = New-Item -Path $OutDir -ItemType Directory -Force
    $before = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.whl' -File | ForEach-Object FullName)
    $commandLine = '"{0}" -m wheel pack "{1}" --dest-dir "{2}"' -f $PackExe, $packageRoot, $OutDir
    [void](Invoke-ShieldedNative -Label "wheel pack $(Split-Path $packageRoot -Leaf)" -CommandLine $commandLine)
    $packed = @(Get-ChildItem -LiteralPath $OutDir -Filter '*.whl' -File | Where-Object { $_.FullName -notin $before })
    if ($packed.Count -ne 1) { throw "TVM cross: wheel pack left $($packed.Count) new wheel(s) in $OutDir, not one" }
    return $packed[0].FullName
}

Export-ModuleMember -Function New-AssembledPythonWheel

function Initialize-AssembledPythonPackage {
    param(
        [Parameter(Mandatory)][string]$SourcePackage,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string[]]$Library
    )
    $package = Join-Path $PackageRoot $PackageName
    $libraryRoot = Join-Path $package 'lib'
    $null = New-Item -Path $libraryRoot -ItemType Directory -Force
    Copy-Item -Path (Join-Path $SourcePackage '*') -Destination $package -Recurse -Force
    foreach ($file in $Library) { Copy-Item -LiteralPath $file -Destination $libraryRoot -Force }
}

Export-ModuleMember -Function Initialize-AssembledPythonPackage
