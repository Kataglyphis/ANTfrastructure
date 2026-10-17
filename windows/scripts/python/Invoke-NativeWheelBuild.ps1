#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Builds a Cython project's binary wheels on the runner's own arch, for python-ci-windows.yml's arm64 job.
<#
.SYNOPSIS
    One binary wheel per -PythonVersions leg, built natively with Visual Studio's clang-cl and loaded alone in a fresh venv.
.DESCRIPTION
    The hub's arm64 container cross-builds no GIL Cython wheel (Invoke-CiPackaging.ps1), so a windows-11-arm runner builds
    both here: VsDevCmd for the host arch, Visual Studio's own LLVM first on PATH (the family's setup.py swaps cl and link
    for clang-cl and lld-link), CYTHONIZE=True, then `uv build --wheel` per leg with the interpreter uv already has. Each
    wheel must be that leg's cpXY or cpXYt wheel for this arch, and installs alone and offline into a venv where every
    compiled module loads (free-threaded-wheel.py load), an X.Yt leg's with the GIL off (prove). The wheels land in
    -OutDir. Legs read as in Invoke-PythonTestLegs.ps1, which runs first and leaves uv on PATH.
#>
[CmdletBinding()]
param(
    [string]$PythonVersions = '',
    [string]$OutDir = 'dist',
    [string]$VersionsEnvPath = (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env')
)
$ErrorActionPreference = 'Stop'
foreach ($module in 'WindowsScripts.Shared', 'WindowsTargetArch.Common', 'WindowsSourceBuild.Common', 'WindowsUv.Common', 'WindowsPythonWheel.Common') {
    Import-Module (Join-Path $PSScriptRoot "..\modules\$module.psm1")
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
Enter-VsDevCmdEnvironment -Arch $arch -HostArch $arch
$llvm = Join-Path $env:VCINSTALLDIR "Tools\Llvm\$(if ($arch -eq 'arm64') { 'ARM64' } else { 'x64' })\bin"
$missing = @('clang-cl.exe', 'lld-link.exe' | Where-Object { -not (Test-Path -LiteralPath "$llvm\$_") })
if ($missing.Count) { throw "Visual Studio lacks its C++ Clang tools: no $($missing -join ', ') in $llvm" }
$env:PATH = "$llvm;$env:PATH"
$env:CYTHONIZE = 'True'
$null = New-Item -ItemType Directory -Force -Path $OutDir

$legs = @(Resolve-PythonLegList -PythonVersions $PythonVersions -VersionsEnvPath $VersionsEnvPath)
foreach ($leg in $legs) {
    $python = Find-UvPython -Request (Get-UvPythonRequest -Version $leg) -Hint 'run Invoke-PythonTestLegs.ps1 for this leg first'
    Add-PythonLibPath -PythonDir (Split-Path -Parent $python)
    $legOut = Join-Path ([IO.Path]::GetTempPath()) "native-wheel-$leg-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Write-Host "=== Python ${leg}: uv build --wheel with $python"
    & uv build --wheel --python $python --out-dir $legOut
    if ($LASTEXITCODE -ne 0) { throw "uv build --wheel for Python $leg exited $LASTEXITCODE" }
    $wheels = @(Get-ChildItem -LiteralPath $legOut -Filter '*.whl' -File)
    if ($wheels.Count -ne 1) { throw "Python $leg built $($wheels.Count) wheels, not one" }
    $check = Get-NativeWheelCheck -Name $wheels[0].Name -Leg $leg -Platform "win_$arch"
    Write-Host (Invoke-FreeThreadedWheelVenvProof -Interpreter $python -Wheel $wheels[0].FullName -Distribution ($wheels[0].Name -split '-')[0] -Check $check)
    Move-Item -LiteralPath $wheels[0].FullName -Destination $OutDir -Force
    Remove-Item -LiteralPath $legOut -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Built and loaded $($legs.Count) win_$arch wheel(s): $((Get-ChildItem -LiteralPath $OutDir -Filter '*.whl' -File).Name -join ', ')"
