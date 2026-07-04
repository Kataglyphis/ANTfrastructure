# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$VcpkgDir = 'C:\vcpkg'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host "Setting up vcpkg at $VcpkgDir..."

if (-not (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe'))) {
    Write-Host 'Downloading vcpkg (DNS workaround: use Invoke-WebRequest instead of git clone)...'
    $vcpkgZip = Join-Path $env:TEMP 'vcpkg.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://github.com/microsoft/vcpkg/archive/refs/heads/master.zip' -OutFile $vcpkgZip -UseBasicParsing
    Expand-Archive -Path $vcpkgZip -DestinationPath $env:TEMP -Force
    $extracted = Get-ChildItem -Path $env:TEMP -Directory -Filter 'vcpkg*' | Select-Object -First 1 -ExpandProperty FullName
    if (-not $extracted) { throw 'Failed to locate extracted vcpkg directory' }
    Move-Item -Path $extracted -Destination $VcpkgDir -Force
    Remove-Item $vcpkgZip -Force -ErrorAction SilentlyContinue

    Push-Location $VcpkgDir
    Write-Host 'Bootstrapping vcpkg...'
    .\bootstrap-vcpkg.bat 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed' }
    Pop-Location
    Write-Host 'vcpkg installed successfully'
}

Write-Host 'Installing dependencies via vcpkg...'
foreach ($pkg in @('zlib:x64-windows', 'protobuf:x64-windows')) {
    Write-Host "  Installing $pkg..."
    & "$VcpkgDir\vcpkg.exe" install $pkg --triplet x64-windows 2>&1 | Out-Null
    # Fail loudly: a silently-missing protobuf/zlib surfaces much later as an
    # opaque link error deep in a media build.
    if ($LASTEXITCODE -ne 0) { throw "vcpkg install $pkg failed (exit $LASTEXITCODE)" }
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
