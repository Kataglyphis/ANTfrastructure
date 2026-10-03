# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# A device has no VS: the cross bundle must carry the VS-toolset runtimes it links - ASan and the OpenMP runtime torch's DLLs import.

param(
    [string]$InstallDir = 'C:\runtime',
    # Stage beside the given directory's files instead of its bin\: a staged test tree runs its exes from its root.
    [switch]$Flat,
    [string]$ScriptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -ScriptDir is accepted only for parity with the other merge-stage scripts; the resolver needs no hint.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -ErrorAction Stop

# amd64's host runs stage the x64 DLLs themselves; only the cross bundle needs the aarch64 ones shipped.
$arch = if ([string]::IsNullOrWhiteSpace($env:WINDOWS_TARGET_ARCH)) { 'amd64' } else { $env:WINDOWS_TARGET_ARCH }
if ($arch -eq 'amd64') {
    Write-Host 'Copy-Arm64VsRuntime: amd64 lane - the x64 runtimes come from the host VS install, nothing to stage.'
    exit 0
}

$toolsRoots = @(Get-MsvcToolsRoots -AllowMissing)
$destDir = if ($Flat) { $InstallDir } else { Join-Path $InstallDir 'bin' }
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$staged = @()

# The release ASan DLL is what clang-cl links by default; the dbg twin serves /MDd-instrumented exes.
$asanNames = @('clang_rt.asan_dynamic-aarch64.dll', 'clang_rt.asan_dbg_dynamic-aarch64.dll')
$asanDir = $null
foreach ($toolsRoot in $toolsRoots) {
    # HostArm64 is where VS 2026 puts the aarch64 toolset; Hostx64\arm64 is the cross-tools spelling to keep working.
    foreach ($hostDir in @('bin\HostArm64\arm64', 'bin\Hostx64\arm64')) {
        $candidate = Join-Path $toolsRoot $hostDir
        if (Test-Path (Join-Path $candidate $asanNames[0])) { $asanDir = $candidate; break }
    }
    if ($asanDir) { break }
}
if (-not $asanDir) {
    throw "no aarch64 ASan runtime under any MSVC toolset (looked for $($asanNames[0]) in bin\HostArm64\arm64 and bin\Hostx64\arm64) - the VS ASAN component is missing or moved"
}
foreach ($n in $asanNames) {
    if (Test-Path (Join-Path $asanDir $n)) { Copy-Item (Join-Path $asanDir $n) $destDir -Force; $staged += $n }
}

# torch's DLLs import the MSVC OpenMP runtime; a clean device has no redist, so it ships from wherever the VS tree keeps the aarch64 copy.
$vcomp = $null
$searched = @()
foreach ($toolsRoot in $toolsRoots) {
    $redist = Join-Path (Split-Path (Split-Path $toolsRoot -Parent) -Parent) 'Redist\MSVC'
    $searched += $redist
    if (Test-Path $redist) {
        $vcomp = Get-ChildItem $redist -Recurse -Filter 'vcomp140.dll' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\arm64\\' } | Select-Object -First 1
    }
    if ($vcomp) { break }
    foreach ($hostDir in @('bin\HostArm64\arm64', 'bin\Hostx64\arm64')) {
        $candidate = Join-Path $toolsRoot $hostDir
        $searched += $candidate
        if (Test-Path (Join-Path $candidate 'vcomp140.dll')) { $vcomp = Get-Item (Join-Path $candidate 'vcomp140.dll'); break }
    }
    if ($vcomp) { break }
    # Last resort: the whole VS root, filtered to an arm64 path (the redist layout moved between VS versions).
    $vsRoot = Split-Path (Split-Path (Split-Path (Split-Path $toolsRoot -Parent) -Parent) -Parent) -Parent
    $searched += $vsRoot
    if (Test-Path $vsRoot) {
        $vcomp = Get-ChildItem $vsRoot -Recurse -Filter 'vcomp140.dll' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'arm64' } | Select-Object -First 1
    }
    if ($vcomp) { break }
}
if (-not $vcomp) {
    throw "no aarch64 vcomp140.dll under the VS trees (searched: $($searched -join '; ')) - torch_cpu.dll imports it and a clean device has no redist"
}
Copy-Item $vcomp.FullName $destDir -Force
$staged += $vcomp.Name

Write-Host ("Copy-Arm64VsRuntime: staged {0} file(s) into {1}: {2}" -f $staged.Count, $destDir, ($staged -join ', '))
