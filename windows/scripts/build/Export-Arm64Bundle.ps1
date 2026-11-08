#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Packs the arm64 runtime bundle (C:\runtime) into a zip for the device gate on windows-11-arm.
.DESCRIPTION
    Runs inside the :winarm64 image, whose C:\runtime is the bundle. The zip, Test-Arm64Bundle.ps1, free-threaded-wheel.py
    and the two GStreamer test modules land in -OutDir, become a workflow artifact, and the arm64 job extracts and runs them.
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

foreach ($sibling in 'WindowsScripts.Shared.psm1', 'WindowsOrtPayload.Common.psm1') {
    Import-Module (Join-Path $PSScriptRoot "../modules/$sibling") -DisableNameChecking -ErrorAction Stop
}

function Get-Arm64BundleOrtOverlay {
    # A client searches System32 before PATH; keep the chain DLLs beside the exported executables.
    param([string]$BundleRoot, [string]$StageRoot)
    $chain = Join-Path $BundleRoot 'lib/onnxruntime-source'
    $files = @(Copy-ChainOrtBeside -OnnxRoot $chain -Destination (Join-Path $StageRoot 'bin'))
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($StageRoot, $file).Replace('\', '/')
        if (Test-Path -LiteralPath (Join-Path $BundleRoot $relative)) {
            throw "bundle already contains $relative; refusing a duplicate archive member"
        }
        $relative
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir $ZipName
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }

# The system bsdtar by full path: a Git-on-PATH tar is GNU tar, which reads C:\ as a remote host.
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path $tar)) { throw "no bsdtar at $tar; needed to pack $BundleRoot" }
$overlay = New-TemporaryDirectory -Prefix 'arm64-export-ort-'
try {
    $entries = @(Get-Arm64BundleOrtOverlay -BundleRoot $BundleRoot -StageRoot $overlay)
    & $tar -a -c -f $zip -C $BundleRoot . -C $overlay @entries
    if ($LASTEXITCODE -ne 0) { throw "tar exited $LASTEXITCODE packing $BundleRoot" }
} finally {
    Remove-Item -LiteralPath $overlay -Recurse -Force -ErrorAction Stop
}
if (-not (Test-Path $zip)) { throw "no $zip after packing" }

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Test-Arm64Bundle.ps1') -Destination $OutDir
# The gate proves the cp3XYt twins with the helper the build lanes run; the bundle itself does not carry it.
$helper = Join-Path $PSScriptRoot '..\..\..\linux\scripts\02-toolchain\python\free-threaded-wheel.py'
if (-not (Test-Path -LiteralPath $helper)) { throw "no free-threaded-wheel.py at $helper; the device gate needs it to prove the cp3XYt twins" }
Copy-Item -LiteralPath $helper -Destination $OutDir
# The gate's modules import their required siblings from beside themselves.
foreach ($module in 'WindowsGstPlugins.Common.psm1', 'WindowsTargetArch.Common.psm1',
    'WindowsScripts.Shared.psm1', 'WindowsArm64Acceptance.Common.psm1', 'WindowsPythonWheel.Common.psm1', 'WindowsOrtDmlCheck.Common.psm1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\modules\$module") -Destination $OutDir
}
Write-Host ("bundle zip: {0} ({1:N2} GB), gate script, free-threaded-wheel.py and the GStreamer test modules beside it" -f $zip, ((Get-Item $zip).Length / 1GB))
