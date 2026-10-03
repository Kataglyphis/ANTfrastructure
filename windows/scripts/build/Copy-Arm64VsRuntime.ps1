# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# A device has no VS: the cross bundle must carry Microsoft's aarch64 ASan runtime, or an instrumented exe dies (docs/windows-cross-builds.md § Verification).

param(
    [string]$InstallDir = 'C:\runtime',
    [string]$ScriptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -ScriptDir is accepted only for parity with the other merge-stage scripts; the resolver needs no hint.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -ErrorAction Stop

# amd64's host runs stage the x64 DLL themselves; only the cross bundle needs the aarch64 one shipped.
$arch = if ([string]::IsNullOrWhiteSpace($env:WINDOWS_TARGET_ARCH)) { 'amd64' } else { $env:WINDOWS_TARGET_ARCH }
if ($arch -eq 'amd64') {
    Write-Host 'Copy-Arm64AsanRuntime: amd64 lane - the x64 ASan runtime comes from the host VS install, nothing to stage.'
    exit 0
}

# The release DLL is what clang-cl links by default; the dbg twin serves /MDd-instrumented exes.
$names = @('clang_rt.asan_dynamic-aarch64.dll', 'clang_rt.asan_dbg_dynamic-aarch64.dll')
$srcDir = $null
foreach ($toolsRoot in @(Get-MsvcToolsRoots -AllowMissing)) {
    # HostArm64 is where VS 2026 puts the aarch64 toolset; Hostx64\arm64 is the cross-tools spelling to keep working.
    foreach ($hostDir in @('bin\HostArm64\arm64', 'bin\Hostx64\arm64')) {
        $candidate = Join-Path $toolsRoot $hostDir
        if (Test-Path (Join-Path $candidate $names[0])) { $srcDir = $candidate; break }
    }
    if ($srcDir) { break }
}
if (-not $srcDir) {
    throw "no aarch64 ASan runtime under any MSVC toolset (looked for $($names[0]) in bin\HostArm64\arm64 and bin\Hostx64\arm64) - the VS ASAN component is missing or moved"
}

$destDir = Join-Path $InstallDir 'bin'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$copied = 0
foreach ($n in $names) {
    $src = Join-Path $srcDir $n
    if (Test-Path $src) { Copy-Item $src $destDir -Force; $copied++ }
}
Write-Host ("Copy-Arm64AsanRuntime: staged {0} file(s) from {1} into {2}" -f $copied, $srcDir, $destDir)
