# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Cross lanes: the cp3XYt wheels PyPI ships no target build of, built with clang-cl from SHA-pinned sdists into the free-threaded store's deps\.
.DESCRIPTION
    A consumer's free-threaded device leg resolves its lock against this store (docs/windows-builds.md § The arm64 cross twins).
#>
param(
    [string]$Store = '',
    [string]$ScriptDir = '',
    [string]$LlvmBin = 'C:\llvm-patched\bin'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The merge mounts modules\ beside this script; the repo keeps it one level up.
$modules = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { Join-Path $PSScriptRoot 'modules' } else { Join-Path $PSScriptRoot '..\modules' }
Import-Module (Join-Path $modules 'WindowsSourceBuild.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $modules 'WindowsTargetArch.Common.psm1') -DisableNameChecking

# Each distribution to build, and the versions.env prefix of its <PREFIX>_VERSION and <PREFIX>_SDIST_SHA256.
function Get-TargetSdistTable {
    [ordered]@{ psutil = 'PY_PSUTIL' }
}

# The PE members of -WheelPath that MSVC's link.exe, not lld-link, produced.
function Get-WheelMsvcLinkedMember([string]$WheelPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = [IO.Directory]::CreateTempSubdirectory('wheel-rich-').FullName
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($WheelPath, $tmp)
        Get-ChildItem -LiteralPath $tmp -Recurse -File -Include '*.pyd', '*.dll' | Where-Object { Test-PeRichHeader -Path $_.FullName } | ForEach-Object Name
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not (Test-WindowsCrossTarget)) {
    Write-Host 'Target sdist wheels: native lane -- a free-threaded venv builds these from source itself; nothing to stage'
    exit 0
}
& (Join-Path $(if ($ScriptDir) { $ScriptDir } else { $PSScriptRoot }) 'Import-Versions.ps1')

$abi = Get-FreeThreadedAbiTag
$deps = Join-Path $(if ($Store) { $Store } else { Get-FreeThreadedWheelStore }) 'deps'
$target = Get-TargetBuildPython -FreeThreaded
if (-not $target.Available) { throw "Target sdist wheels: no free-threaded target tree to link ($($target.Lib))" }

# setuptools' MSVC compiler runs cl, link and lib from PATH under DISTUTILS_USE_SDK; these are clang-cl and lld-link (CON93).
$work = [IO.Directory]::CreateTempSubdirectory('target-sdist-').FullName
$shim = Join-Path $work 'clang-cl-shim'
$null = New-Item -ItemType Directory -Force -Path $shim
Copy-Item -LiteralPath (Join-Path $LlvmBin 'clang-cl.exe') -Destination (Join-Path $shim 'cl.exe')
Copy-Item -LiteralPath (Join-Path $LlvmBin 'lld-link.exe') -Destination (Join-Path $shim 'link.exe')
Copy-Item -LiteralPath (Join-Path $LlvmBin 'llvm-lib.exe') -Destination (Join-Path $shim 'lib.exe')
Enter-VsDevCmdEnvironment -Arch (Get-WindowsTargetArch)
$env:PATH = "$shim;$env:PATH"
$env:DISTUTILS_USE_SDK = '1'
$env:MSSdk = '1'
# clang-cl reads CL like cl.exe does: the target, and cl's common tentative definitions, which psutil's headers rely on.
$env:CL = "--target=$((Get-WindowsTargetArchInfo).ClangTriple) /clang:-fcommon"

try {
    $table = Get-TargetSdistTable
    foreach ($name in $table.Keys) {
        $version, $sha = foreach ($key in "$($table[$name])_VERSION", "$($table[$name])_SDIST_SHA256") { "$([Environment]::GetEnvironmentVariable($key))".Trim() }
        if (-not $version -or $sha -notmatch '^[0-9a-f]{64}$') { throw "$name needs $($table[$name])_VERSION and a 64-hex $($table[$name])_SDIST_SHA256, got '$version' and '$sha'" }
        $archive = Join-Path $work "$name-$version.tar.gz"
        Invoke-DownloadWithRetry -Url "https://files.pythonhosted.org/packages/source/$($name[0])/$name/$name-$version.tar.gz" `
            -DestinationPath $archive -Description "$name $version sdist" -ExpectedSha256 $sha
        & "$env:SystemRoot\System32\tar.exe" -x -f $archive -C $work
        if ($LASTEXITCODE -ne 0) { throw "tar could not unpack $archive (exit $LASTEXITCODE)" }
        # Bare setuptools takes the GIL build interpreter's pinned version, not the sdist's open range.
        $build = Join-Path $work "build-$name"
        $null = New-Item -ItemType Directory -Force -Path $build
        $venv = New-FreeThreadedBuildPython -GilPython (Get-SourceBuildPython) -VenvDir (Join-Path $build 'venv') -Package @('setuptools')
        $wheel = Invoke-CrossWheelBuild -Python $venv.Exe -Source (Join-Path $work "$name-$version") -LibDir $target.LibDir -AbiTag $abi -WorkDir $build
        if (-not $wheel) { throw "$name $version built a pure wheel, so PyPI's would have served $abi" }
        $msvc = @(Get-WheelMsvcLinkedMember -WheelPath $wheel.FullName)
        if ($msvc.Count -gt 0) { throw "$($wheel.Name): $($msvc -join ', ') carry MSVC's Rich header, so the clang-cl shim was bypassed" }
        $null = New-Item -ItemType Directory -Force -Path $deps
        Copy-Item -LiteralPath $wheel.FullName -Destination $deps -Force
        Write-Host "Target sdist wheels: $($wheel.Name) built with clang-cl from the pinned sdist into $deps"
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
