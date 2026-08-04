# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

Assert-ContainerCommandAvailable -Name 'flutter' | Out-Null
Assert-ContainerCommandAvailable -Name 'wix' | Out-Null
Assert-ContainerCommandAvailable -Name 'clang-cl' | Out-Null
Assert-ContainerCommandAvailable -Name 'lld-link' | Out-Null
Assert-ContainerCommandAvailable -Name 'cmake' | Out-Null

# LLVM is DELIBERATELY unpinned on Windows (scoop latest; versions.env's
# LLVM_RELEASE pins only the Linux lane) — log the resolved version into the
# build output as provenance so a "worked last rebuild" regression is
# attributable to a concrete clang-cl version instead of a guess.
$clangOut = & clang-cl --version
if ($LASTEXITCODE -ne 0) { throw "clang-cl --version failed (exit code $LASTEXITCODE)" }
Write-Host ("clang-cl (provenance): {0}" -f ($clangOut | Select-Object -First 1))

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

