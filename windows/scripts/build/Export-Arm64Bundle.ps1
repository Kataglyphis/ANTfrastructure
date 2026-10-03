#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Packs the arm64 runtime bundle (C:\runtime) into a zip for the device gate on windows-11-arm.
.DESCRIPTION
    Runs inside the :winarm64 image, whose C:\runtime is the bundle. The zip and Test-Arm64Bundle.ps1
    land in -OutDir, become a workflow artifact, and the arm64 job extracts and runs them.
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
Write-Host ("bundle zip: {0} ({1:N2} GB), gate script beside it" -f $zip, ((Get-Item $zip).Length / 1GB))
