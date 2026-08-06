# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# CACHE-BUST 2026-08-06: this comment block's content change sidesteps
# persistent snapshotter debris (`ImportLayer 0xb7 "already exists"` at
# finalize of the COPY layer for this file — identical chain-IDs across
# retries; see AGENTS.md failure table). New content => new chain-IDs.

#requires -Version 7.0

param(
    [string]$VcpkgDir = 'C:\vcpkg',
    [string]$VcpkgRef = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$installerModulePath = Join-Path $PSScriptRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force
# Shared helpers (Invoke-DownloadWithRetry, etc.) come through Installer.Common's re-export.

# Source canonical version from versions.env (VCPKG_REF). Fallback mirrors that pin;
# must stay >= 2026.06 -- older snapshots pin a vcpkg-tool that cannot see VS 18's
# v145 toolset ("Unable to find a valid Visual Studio instance").
if ([string]::IsNullOrWhiteSpace($VcpkgRef)) {
    $VcpkgRef = if ($env:VCPKG_REF) { $env:VCPKG_REF } else { '2026.07.29' }
}

Write-Host "Setting up vcpkg ($VcpkgRef) at $VcpkgDir..."

if (-not (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe'))) {
    Write-Host 'Downloading vcpkg (DNS workaround: HTTP download with retries instead of git clone)...'
    $vcpkgZip = Join-Path $env:TEMP 'vcpkg.zip'
    Invoke-DownloadWithRetry -Url "https://github.com/microsoft/vcpkg/archive/refs/tags/$VcpkgRef.zip" -DestinationPath $vcpkgZip -Description "vcpkg (pinned tag $VcpkgRef)"
    $extracted = Expand-ArchiveSubdirectory -ArchivePath $vcpkgZip -DestinationPath $env:TEMP -Filter 'vcpkg-*'
    if (-not $extracted) { throw 'Failed to locate extracted vcpkg directory' }
    # If a previous half-finished run left $VcpkgDir behind (dir exists but no
    # vcpkg.exe, or we would not be here), Move-Item would NEST the source under
    # it instead of replacing it — clear the target first.
    if (Test-Path $VcpkgDir) { Remove-Item -Recurse -Force $VcpkgDir -ErrorAction SilentlyContinue }
    Move-Item -Path $extracted -Destination $VcpkgDir -Force
    Remove-Item $vcpkgZip -Force -ErrorAction SilentlyContinue

    Push-Location $VcpkgDir
    try {
        Write-Host 'Bootstrapping vcpkg...'
        # Capture instead of discarding: the transcript is only emitted on failure,
        # where it is the sole diagnostic.
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
# protobuf was removed 2026-08-03: NOTHING consumed it. Every source build brings its
# own protobuf (ONNX _deps, LiteRT-LM's protobuf_external + downloaded version-matched
# protoc), and LiteRT-LM even had to HIDE vcpkg's protobuf headers to avoid version
# skew. It only cost ~15 min of vcpkg compile in the base image. zlib stays: it feeds
# protobuf_external's HAVE_ZLIB via CMAKE_PREFIX_PATH in the LiteRT-LM build.
foreach ($pkg in @('zlib:x64-windows')) {
    Write-Host "  Installing $pkg..."
    $installOut = & "$VcpkgDir\vcpkg.exe" install $pkg --triplet x64-windows 2>&1
    # Fail loudly: a silently-missing zlib surfaces much later as an
    # opaque link error deep in a media build. Emit the captured transcript
    # only on failure (success output is multi-hundred-line noise).
    if ($LASTEXITCODE -ne 0) {
        $installOut | ForEach-Object { Write-Host $_ }
        throw "vcpkg install $pkg failed (exit $LASTEXITCODE)"
    }
    Write-Host "  $pkg installed successfully"
}

# Only installed\ is consumed downstream; buildtrees\, packages\ and downloads\ are
# multi-GB intermediates that would otherwise bloat this layer.
Write-Host 'Pruning vcpkg intermediates (buildtrees, packages, downloads)...'
foreach ($sub in @('buildtrees', 'packages', 'downloads')) {
    $path = Join-Path $VcpkgDir $sub
    if (Test-Path $path) { Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue }
}
Write-Host 'vcpkg setup complete.'

