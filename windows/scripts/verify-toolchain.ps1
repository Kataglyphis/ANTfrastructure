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

& 'C:\WiX\wix.exe' --version | Out-Host
$wixExtensions = & 'C:\WiX\wix.exe' extension list --global 2>&1
$wixExtensions | Out-Host
if (-not ($wixExtensions | Select-String -SimpleMatch 'WixToolset.UI.wixext 4.0.4')) {
    throw 'Required WiX extension not installed: WixToolset.UI.wixext 4.0.4'
}
