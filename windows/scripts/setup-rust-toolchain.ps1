# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

Write-Host 'Installing Rust via scoop (more reliable than rustup downloads)...'
scoop install main/rust -ErrorAction SilentlyContinue 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host 'Rust installed via scoop successfully'
} else {
    Write-Host 'Scoop rust install failed, falling back to rustup...'
    rustup self update -ErrorAction SilentlyContinue
    rustup toolchain install stable-x86_64-pc-windows-msvc --no-self-update -ErrorAction SilentlyContinue
    rustup default stable-x86_64-pc-windows-msvc -ErrorAction SilentlyContinue
    rustup component add rust-src clippy rustfmt llvm-tools-preview -ErrorAction SilentlyContinue
}

Assert-ContainerCommandAvailable -Name 'cargo' | Out-Null
Assert-ContainerCommandAvailable -Name 'rustc' | Out-Null
cargo --version 2>&1 | Out-Host
rustc --version 2>&1 | Out-Host

foreach ($c in 'powershell','git','cmake','rustc','cargo','ninja','uv', 'vulkaninfoSDK', 'glslc') {
    Assert-ContainerCommandAvailable -Name $c | Out-Null
    & $c --version 2>&1 | Select-Object -First 1 | Out-Host
}
