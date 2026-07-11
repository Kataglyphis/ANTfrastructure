# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

# DELIBERATELY UNPINNED: the Windows lane tracks scoop's latest rust (versions.env's
# RUST_VERSION pins only the Linux lane). The smoke test therefore asserts a well-formed
# rustc version + a compile/link/run probe, NOT the versions.env value -- keep it that
# way, or an unpinned install fails its own smoke test on the next scoop bump.
Write-Host 'Installing Rust via scoop (latest; single provider; no rustup)...'
scoop install main/rust
if ($LASTEXITCODE -ne 0) { throw 'scoop install main/rust failed' }

# scoop drops cargo/rustc shims into its shim dir, which the persistent PATH
# (Dockerfile.base) already carries for later build stages. Prepend the app's
# bin dir to THIS process's PATH so the asserts below resolve immediately.
$scoopRustBin = Join-Path $env:USERPROFILE 'scoop\apps\rust\current\bin'
if (Test-Path "$scoopRustBin\rustc.exe") {
    $env:PATH = "$scoopRustBin;$env:PATH"
    Write-Host "Using scoop Rust binaries at $scoopRustBin"
}

Assert-ContainerCommandAvailable -Name 'cargo' | Out-Null
Assert-ContainerCommandAvailable -Name 'rustc' | Out-Null
cargo --version 2>&1 | Out-Host
rustc --version 2>&1 | Out-Host
