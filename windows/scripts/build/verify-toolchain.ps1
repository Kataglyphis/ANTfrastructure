# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

Assert-ContainerCommandAvailable -Name 'flutter' | Out-Null
Assert-ContainerCommandAvailable -Name 'wix' | Out-Null
Assert-ContainerCommandAvailable -Name 'clang-cl' | Out-Null
Assert-ContainerCommandAvailable -Name 'lld-link' | Out-Null
Assert-ContainerCommandAvailable -Name 'cmake' | Out-Null

# LLVM is PINNED on Windows since 2026-08-07 (versions.env LLVM_WINDOWS_VERSION,
# forwarded through Dockerfile.base -> setup-scoop-tools.ps1). Assert it HERE, in
# the base build: a silent scoop fallback to a different clang-cl otherwise
# surfaces ~2 h into media-core as a patch that no longer applies. Same shape as
# the cmake assert below. versions.env's LLVM_RELEASE pins the LINUX lane only.
$clangOut = & clang-cl --version
if ($LASTEXITCODE -ne 0) { throw "clang-cl --version failed (exit code $LASTEXITCODE)" }
$clangBanner = $clangOut | Select-Object -First 1
Write-Host ("clang-cl (provenance): {0}" -f $clangBanner)
$expectedLlvm = Resolve-ContainerImageValue -EnvironmentVariable 'LLVM_WINDOWS_VERSION' -DefaultValue ''
if ($expectedLlvm -and $clangBanner -notmatch [regex]::Escape($expectedLlvm)) {
    throw ("clang-cl version mismatch: expected $expectedLlvm (versions.env LLVM_WINDOWS_VERSION), got '$clangBanner'. " +
        'Either scoop could not serve the pinned manifest, or the pin was bumped without rebuilding this layer. ' +
        'A version change here invalidates the clang-cl-shaped patches under windows/scripts/patches/ — ' +
        're-run windows/scripts/tests/Test-PatchesApplyClean.ps1 after a deliberate bump.')
}

# ninja + nasm are pinned for the same reason (build-graph executor and FFmpeg's
# SIMD assembler both shape what ships). Cheap asserts, same failure economics.
#
# sccache is here for a DIFFERENT reason and it is the important one to keep:
# it shapes nothing that ships, but multi-tier caching
# (SCCACHE_MULTILEVEL_CHAIN=disk,webdav, wired in Dockerfile.media-builder)
# needs >= v0.16.0, and an older sccache ignores that variable SILENTLY. Without
# this assert the local L0 tier could simply not exist -- every compile back to
# a WebDAV round-trip, no error, nothing slower than "a bit slower than we
# remember". That is unfalsifiable in a log, so it is asserted here instead.
foreach ($pinned in @(
        @{ Tool = 'ninja';   Args = @('--version'); EnvVar = 'NINJA_WINDOWS_VERSION' },
        @{ Tool = 'nasm';    Args = @('-v');        EnvVar = 'NASM_WINDOWS_VERSION' },
        @{ Tool = 'sccache'; Args = @('--version'); EnvVar = 'SCCACHE_WINDOWS_VERSION' })) {
    $expected = Resolve-ContainerImageValue -EnvironmentVariable $pinned.EnvVar -DefaultValue ''
    if (-not $expected) { continue }
    # Real splatting (@<var>), not an array subexpression: the latter only works
    # for native commands by accident of PS argument flattening.
    $toolArgs = $pinned.Args
    $banner = (& $pinned.Tool @toolArgs 2>&1 | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0) { throw "$($pinned.Tool) $($toolArgs -join ' ') failed (exit code $LASTEXITCODE)" }
    if ($banner -notmatch [regex]::Escape($expected)) {
        throw "$($pinned.Tool) version mismatch: expected $expected (versions.env $($pinned.EnvVar)), got '$banner'"
    }
    Write-Host "$($pinned.Tool) OK: $banner"
}

# sccache must resolve to the CARGO-BUILT binary, not scoop's.
#
# This cannot be a version assert: sccache's main branch still reports package
# version 0.17.0, so `--version` is IDENTICAL for the released build and the
# source build carrying mozilla/sccache#2722. The only observable difference is
# WHERE the binary comes from — CARGO_BIN precedes the scoop shims on PATH, so
# a successful source build wins and a failed/skipped one silently does not.
#
# What is at stake: without #2722, wrapping nvcc on CUDA 13.3 does not merely
# miss the cache, it FAILS the build (`fatbinary fatal: Could not open input
# file '<tu>.compute_80.cubin'`) — an hour into the media stage. Catch it here,
# in the base, in milliseconds.
$sccacheResolved = (Get-Command sccache -ErrorAction SilentlyContinue)
if (-not $sccacheResolved) {
    throw 'sccache not found on PATH after the base build.'
}
$cargoBinDir = [string]$env:CARGO_BIN
if ([string]::IsNullOrWhiteSpace($cargoBinDir)) { $cargoBinDir = Join-Path $env:USERPROFILE '.cargo\bin' }
if ($sccacheResolved.Source -notlike (Join-Path $cargoBinDir '*')) {
    throw ("sccache resolves to '$($sccacheResolved.Source)', not the cargo-built one under '$cargoBinDir'. " +
        'The source build (setup-rust-toolchain.ps1, SCCACHE_GIT_REV) did not take, so nvcc caching would ' +
        'fail the media stage with a fatbinary error ~1h in. Released sccache cannot wrap nvcc on CUDA 13.3 ' +
        '(mozilla/sccache#2722, merged after v0.17.0 shipped).')
}
Write-Host "sccache source-build OK: $($sccacheResolved.Source)"

# CMake is pinned (scoop main/cmake@CMAKE_VERSION from versions.env, baked by
# load-versions.ps1) -- fail the base build here on a pin mismatch instead of
# surfacing it hours later in a media build or the smoke test.
$expectedCmake = Resolve-ContainerImageValue -EnvironmentVariable 'CMAKE_VERSION' -DefaultValue ''
if ($expectedCmake) {
    $cmakeOut = & cmake --version
    if ($LASTEXITCODE -ne 0) { throw "cmake --version failed (exit code $LASTEXITCODE)" }
    $cmakeBanner = $cmakeOut | Select-Object -First 1
    if ($cmakeBanner -notmatch [regex]::Escape($expectedCmake)) {
        throw "cmake version mismatch: expected $expectedCmake (versions.env), got '$cmakeBanner'"
    }
    Write-Host "cmake OK: $cmakeBanner"
}

# Resolve wix.exe via Get-Command (single source of truth, survives WiX install relocations
# instead of hardcoding C:\WiX\wix.exe). Capture-then-read keeps the .Source deref
# StrictMode-safe on the miss path.
$wixCommandInfo = Get-Command wix -ErrorAction SilentlyContinue
if (-not $wixCommandInfo) { throw 'wix.exe not found on PATH (Assert-ContainerCommandAvailable failed)' }
$wixCmd = $wixCommandInfo.Source

& $wixCmd --version | Out-Host
if ($LASTEXITCODE -ne 0) { throw "wix --version failed (exit code $LASTEXITCODE)" }
$wixExtensions = & $wixCmd extension list --global 2>&1
$wixExtensions | Out-Host
# Gate BEFORE the extension assert: a broken wix would otherwise masquerade as
# "extension not installed" and send the operator chasing the wrong problem.
if ($LASTEXITCODE -ne 0) { throw "wix extension list --global failed (exit code $LASTEXITCODE): $wixExtensions" }
# Assert against the same versions.env value the install used (no hand-synced literal).
$wixUiExtVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_UI_EXT_VERSION' -DefaultValue '4.0.4'
if (-not ($wixExtensions | Select-String -SimpleMatch "WixToolset.UI.wixext $wixUiExtVersion")) {
    throw "Required WiX extension not installed: WixToolset.UI.wixext $wixUiExtVersion"
}

