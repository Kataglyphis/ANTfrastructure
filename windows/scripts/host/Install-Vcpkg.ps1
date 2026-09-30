#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT


param(
    [string]$VcpkgDir = 'C:\vcpkg',
    [string]$VcpkgRef = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$installerModulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force

# The fallback mirrors versions.env and must stay >= 2026.06: older vcpkg-tool cannot see VS 18's v145 toolset.
if ([string]::IsNullOrWhiteSpace($VcpkgRef)) {
    $VcpkgRef = if ($env:VCPKG_REF) { $env:VCPKG_REF } else { '2026.07.29' }
}

Write-Host "Setting up vcpkg ($VcpkgRef) at $VcpkgDir..."

if (-not (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe'))) {
    Write-Host 'Downloading vcpkg (DNS workaround: HTTP download with retries instead of git clone)...'
    $vcpkgZip = Join-Path $env:TEMP 'vcpkg.zip'
    # No SHA: GitHub tag archives are not bit-stable; the PK magic check still rejects an HTML error page.
    Invoke-DownloadWithRetry -Url "https://github.com/microsoft/vcpkg/archive/refs/tags/$VcpkgRef.zip" -DestinationPath $vcpkgZip -Description "vcpkg (pinned tag $VcpkgRef)" -ExpectSignature PK
    $extracted = Expand-ArchiveSubdirectory -ArchivePath $vcpkgZip -DestinationPath $env:TEMP -Filter 'vcpkg-*'
    if (-not $extracted) { throw 'Failed to locate extracted vcpkg directory' }
    # A half-finished earlier run leaves $VcpkgDir behind, and Move-Item would nest into it instead of replacing it.
    if (Test-Path $VcpkgDir) { Remove-Item -Recurse -Force $VcpkgDir -ErrorAction SilentlyContinue }
    Move-Item -Path $extracted -Destination $VcpkgDir -Force
    Remove-Item $vcpkgZip -Force -ErrorAction SilentlyContinue

    Push-Location $VcpkgDir
    try {
        Write-Host 'Bootstrapping vcpkg...'
        # Captured, not discarded: on failure it is the only diagnostic.
        $bootstrapOut = .\bootstrap-vcpkg.bat 2>&1
        if ($LASTEXITCODE -ne 0) {
            $bootstrapOut | ForEach-Object { Write-Host $_ }
            throw "vcpkg bootstrap failed (exit $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
    Write-Host 'vcpkg installed successfully'
}

Write-Host 'Installing dependencies via vcpkg...'
# zlib feeds LiteRT-LM's protobuf; both triplets because one base image serves both target lanes.
foreach ($triplet in @('x64-windows', 'arm64-windows')) {
    $pkg = "zlib:$triplet"
    Write-Host "  Installing $pkg..."
    $installOut = & "$VcpkgDir\vcpkg.exe" install $pkg --triplet $triplet 2>&1
    # A missing zlib otherwise surfaces much later as an opaque link error in a media build.
    if ($LASTEXITCODE -ne 0) {
        $installOut | ForEach-Object { Write-Host $_ }
        throw "vcpkg install $pkg failed (exit $LASTEXITCODE)"
    }
    Write-Host "  $pkg installed successfully"
}

# Only installed\ is consumed downstream; the rest is multi-GB layer bloat.
Write-Host 'Pruning vcpkg intermediates (buildtrees, packages, downloads)...'
foreach ($sub in @('buildtrees', 'packages', 'downloads')) {
    $path = Join-Path $VcpkgDir $sub
    if (Test-Path $path) { Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue }
}
Write-Host 'vcpkg setup complete.'

