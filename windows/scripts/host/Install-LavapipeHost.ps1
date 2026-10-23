# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Provisions Mesa's lavapipe and the Khronos loader on a Windows host, for tests that run outside the image.
.DESCRIPTION
    The pins and the URL shapes come from the hub - versions.env plus WindowsContainerImage.Common - so the
    in-image installer and this host provisioner cannot disagree. Registers the ICD in HKLM when elevated
    (the loader ignores VK_DRIVER_FILES there) and sets LP_NATIVE_VECTOR_WIDTH=256, because Mesa 26.2's BVH
    sort needs 8-lane subgroups. Returns @{ Icd; LoaderDir; VulkanInfo }.
    See docs/windows-cross-builds.md - Vulkan on lavapipe.
#>
param(
    [string]$ToolDir = (Join-Path ($env:RUNNER_TEMP ?? [IO.Path]::GetTempPath()) 'lavapipe'),
    [ValidateSet('', 'amd64', 'arm64')][string]$Arch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$containerModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $containerModulePath)) { throw "Required module not found: $containerModulePath" }
Import-Module $containerModulePath -Force
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if ((Test-Path $sharedModulePath) -and -not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedModulePath }

if (-not $Arch) {
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'amd64' }
        'ARM64' { 'arm64' }
        default { throw "Install-LavapipeHost: no lavapipe pin for $env:PROCESSOR_ARCHITECTURE" }
    }
}

$hubRoot = Split-Path (Split-Path $scriptAssetRoot -Parent) -Parent
$versionsPath = Join-Path $hubRoot 'linux\scripts\01-core\versions.env'
if (-not (Test-Path -LiteralPath $versionsPath)) { throw "Install-LavapipeHost: no versions.env at $versionsPath" }
$pins = ConvertFrom-VersionsEnv -Path $versionsPath

$lavapipeDir = Join-Path $ToolDir 'lavapipe'
New-Item -ItemType Directory -Force -Path $lavapipeDir | Out-Null
$runtime = Install-LavapipeRuntime -Arch $Arch -Lookup { param([string]$name) $pins[$name] } -ArchiveDirectory $ToolDir -Destination $lavapipeDir
$icdName = $runtime.IcdName
$icd = Join-Path $lavapipeDir $icdName
$vulkanInfo = Join-Path $lavapipeDir 'vulkaninfo.exe'
foreach ($f in $icd, $vulkanInfo, (Join-Path $lavapipeDir 'vulkan-1.dll')) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Install-LavapipeHost: $f is missing after the unpack" }
}

$env:VK_DRIVER_FILES = $icd
$env:VK_LOADER_DRIVERS_SELECT = '*lvp_icd*'
if (Test-Elevated) {
    Register-LavapipeIcd -IcdPath $icd
}
$env:LP_NATIVE_VECTOR_WIDTH = $env:LP_NATIVE_VECTOR_WIDTH ?? '256'

Write-Host "lavapipe $($runtime.MesaVersion) ($Arch) + Vulkan loader $($runtime.VulkanVersion) provisioned in $lavapipeDir"
return @{ Icd = $icd; LoaderDir = $lavapipeDir; VulkanInfo = $vulkanInfo }
