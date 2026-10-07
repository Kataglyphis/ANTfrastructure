#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Packs the arm64 runtime bundle (C:\runtime) into a zip for the device gate on windows-11-arm.
.DESCRIPTION
    Runs inside the :winarm64 image, whose C:\runtime is the bundle. The zip, Test-Arm64Bundle.ps1 and
    free-threaded-wheel.py land in -OutDir, become a workflow artifact, and the arm64 job extracts and runs them.
    See docs/windows-cross-builds.md - Verification.
#>
[CmdletBinding()]
param(
    [string]$BundleRoot = 'C:\runtime',
    [Parameter(Mandatory)][string]$OutDir,
    [string]$ZipName = 'bundle.zip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The two markers the gate itself needs, checked before 800 MB move.
if (-not (Test-Path (Join-Path $BundleRoot 'BUNDLE-ENV.ps1'))) { throw "no bundle at $BundleRoot (BUNDLE-ENV.ps1 missing)" }
if (-not (Test-Path (Join-Path $BundleRoot 'python\python.exe'))) { throw "no bundle python under $BundleRoot" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir $ZipName
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }

# The system bsdtar by full path: a Git-on-PATH tar is GNU tar, which reads C:\ as a remote host.
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $tar)) { throw "no bsdtar at $tar; needed to pack $BundleRoot" }
& $tar -a -c -f $zip -C $BundleRoot .
if ($LASTEXITCODE -ne 0) { throw "tar exited $LASTEXITCODE packing $BundleRoot" }
if (-not (Test-Path $zip)) { throw "no $zip after packing" }

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-Arm64Bundle.ps1') -Destination $OutDir
# The gate proves the cp3XYt twins with the helper the build lanes run; the bundle itself does not carry it.
$helper = Join-Path $PSScriptRoot '..\..\..\linux\scripts\02-toolchain\python\free-threaded-wheel.py'
if (-not (Test-Path -LiteralPath $helper)) { throw "no free-threaded-wheel.py at $helper; the device gate needs it to prove the cp3XYt twins" }
Copy-Item -LiteralPath $helper -Destination $OutDir
Write-Host ("bundle zip: {0} ({1:N2} GB), gate script and free-threaded-wheel.py beside it" -f $zip, ((Get-Item $zip).Length / 1GB))
