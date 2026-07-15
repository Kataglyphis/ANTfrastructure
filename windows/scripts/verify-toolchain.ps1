# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
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

# CMake is pinned (scoop main/cmake@CMAKE_VERSION from versions.env, baked by
# load-versions.ps1) -- fail the base build here on a pin mismatch instead of
# surfacing it hours later in a media build or the smoke test.
$expectedCmake = Resolve-ContainerImageValue -EnvironmentVariable 'CMAKE_VERSION' -DefaultValue ''
if ($expectedCmake) {
    $cmakeBanner = (& cmake --version | Select-Object -First 1)
    if ($cmakeBanner -notmatch [regex]::Escape($expectedCmake)) {
        throw "cmake version mismatch: expected $expectedCmake (versions.env), got '$cmakeBanner'"
    }
    Write-Host "cmake OK: $cmakeBanner"
}

# Resolve wix.exe via Get-Command (single source of truth, survives WiX install relocations
# instead of hardcoding C:\WiX\wix.exe).
$wixCmd = (Get-Command wix -ErrorAction SilentlyContinue).Source
if (-not $wixCmd) { throw 'wix.exe not found on PATH (Assert-ContainerCommandAvailable failed)' }

& $wixCmd --version | Out-Host
$wixExtensions = & $wixCmd extension list --global 2>&1
$wixExtensions | Out-Host
# Assert against the same versions.env value the install used (no hand-synced literal).
$wixUiExtVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_UI_EXT_VERSION' -DefaultValue '4.0.4'
if (-not ($wixExtensions | Select-String -SimpleMatch "WixToolset.UI.wixext $wixUiExtVersion")) {
    throw "Required WiX extension not installed: WixToolset.UI.wixext $wixUiExtVersion"
}
