# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

# rustup WITH a default toolchain -- NOT scoop rust, NOT toolchain-less rustup.
# Flutter's Cargokit (flutter_rust_bridge-style plugins, e.g. rust_builder/cargokit
# in Kataglyphis-Inference-Engine) hard-requires rustup: its build_tool enumerates
# toolchains/targets via rustup and aborts with "rustup not found in PATH."
# otherwise, so scoop-only Rust broke every Flutter+Rust consumer build.
# The old "never rustup" rule targeted a NARROWER failure than the rule: a
# toolchain-less rustup (--default-toolchain none) leaves proxy shims in CARGO_BIN
# that resolve no toolchain. Installed WITH a default toolchain the proxies resolve
# a real one, and because CARGO_BIN sits ahead of scoop's shims on PATH they now
# correctly win. See docs/windows-builds.md, "Rust toolchain".
#
# DELIBERATELY UNPINNED: `stable` resolves to the latest stable at build time
# (versions.env's RUST_VERSION pins only the Linux lane). The smoke test asserts a
# well-formed rustc version + a compile/link/run probe, NOT the versions.env value
# -- keep it that way, or the install fails its own smoke test on the next release.

# PS 5.1 trap: rustup-init and cargo write progress to STDERR; with 2>&1 under
# EAP=Stop the first stderr line would throw. Run native rust steps under
# EAP=Continue and gate on $LASTEXITCODE explicitly instead.
function Invoke-NativeRustStep {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Command
    )
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { "$_" } | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit $LASTEXITCODE)" }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

Write-Host 'Installing Rust via rustup (stable default toolchain; single provider)...'
$rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
Invoke-DownloadWithRetry -Url 'https://win.rustup.rs/x86_64' -DestinationPath $rustupInit `
    -Description 'rustup-init' -ExpectSignature MZ
Invoke-NativeRustStep -Description 'rustup-init' -Command {
    & $rustupInit -y --default-toolchain stable --profile minimal
}
Remove-Item $rustupInit -Force -ErrorAction SilentlyContinue

# CARGO_HOME (Dockerfile.base) already points at C:\Users\ContainerAdministrator\.cargo,
# so the rustup proxies land in CARGO_BIN, which the persistent PATH already carries
# for later build stages. Prepend it to THIS process's PATH so the asserts below
# resolve immediately.
$cargoBin = if ($env:CARGO_BIN) { $env:CARGO_BIN } else { Join-Path $env:USERPROFILE '.cargo\bin' }
if (Test-Path (Join-Path $cargoBin 'cargo.exe')) {
    $env:PATH = "$cargoBin;$env:PATH"
    Write-Host "Using rustup-managed Rust binaries at $cargoBin"
}

Assert-ContainerCommandAvailable -Name 'rustup' | Out-Null
Assert-ContainerCommandAvailable -Name 'cargo' | Out-Null
Assert-ContainerCommandAvailable -Name 'rustc' | Out-Null
Invoke-NativeRustStep -Description 'cargo --version' -Command { cargo --version }
Invoke-NativeRustStep -Description 'rustc --version' -Command { rustc --version }

# Cargokit-shaped asserts: these two calls are exactly what flutter_rust_bridge's
# build_tool runs; failing here is cheaper than failing in every consumer build.
Invoke-NativeRustStep -Description 'rustup show active-toolchain' -Command { rustup show active-toolchain }
Invoke-NativeRustStep -Description 'rustup which cargo' -Command { rustup which cargo }

# Bake flutter_rust_bridge_codegen: consumer builds otherwise cargo-install it on
# first run, costing minutes of cold cargo time per fresh container.
Write-Host 'Baking flutter_rust_bridge_codegen (cargo install)...'
Invoke-NativeRustStep -Description 'cargo install flutter_rust_bridge_codegen' -Command {
    cargo install flutter_rust_bridge_codegen --locked
}
Invoke-NativeRustStep -Description 'flutter_rust_bridge_codegen --version' -Command {
    flutter_rust_bridge_codegen --version
}

# Drop the registry/build intermediates -- only CARGO_BIN needs to ship in the layer.
foreach ($cacheDir in @('registry', 'git')) {
    $p = Join-Path $env:USERPROFILE ".cargo\$cacheDir"
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}
