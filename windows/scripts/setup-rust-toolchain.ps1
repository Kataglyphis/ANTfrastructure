# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

Write-Host 'Installing Rust via scoop...'
try { scoop install main/rust 2>&1 | Out-Null } catch {}
if ($LASTEXITCODE -eq 0) {
    Write-Host 'Rust installed via scoop successfully'
} else {
    Write-Host 'Scoop rust install failed, falling back to rustup...'
    try { rustup default stable } catch {}
}

# Prepend scoop's Rust bin dir to PATH so cargo/rustc resolve to the actual
# binaries (not the rustup proxy shims which need a default toolchain).
$scoopRustBin = "C:\Users\ContainerAdministrator\scoop\apps\rust\current\bin"
if (Test-Path "$scoopRustBin\rustc.exe") {
    $env:PATH = "$scoopRustBin;$env:PATH"
    Write-Host "Using scoop Rust binaries at $scoopRustBin"
}

Assert-ContainerCommandAvailable -Name 'cargo' | Out-Null
Assert-ContainerCommandAvailable -Name 'rustc' | Out-Null
cargo --version 2>&1 | Out-Host
rustc --version 2>&1 | Out-Host
