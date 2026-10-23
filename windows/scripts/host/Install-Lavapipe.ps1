# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Installs Mesa's lavapipe (the CPU Vulkan ICD) and the target arch's Khronos loader into the runtime tree.
.DESCRIPTION
    mmozeiko/build-mesa is the only lavapipe built for arm64 Windows; the loader is LunarG's Runtime
    Components zip for the target arch. Both are SHA256-pinned in versions.env. On amd64 the ICD is
    registered in HKLM, because the loader ignores VK_DRIVER_FILES in an elevated process.
    See docs/windows-cross-builds.md § Vulkan on lavapipe.
#>
param(
    [string]$TempDir = 'C:\temp',
    [string]$InstallDir = 'C:\runtime\lavapipe',
    [string]$TargetArch = '',
    [string]$ScriptDir = '',
    [string]$ModuleRoot = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$bootstrapModulePath = Join-Path $ModuleRoot 'modules\WindowsContainerImage.Bootstrap.psm1'
Import-Module $bootstrapModulePath -Force
$containerModulePath = Resolve-ContainerImageModulePath -ModuleRoot $ModuleRoot -Name 'WindowsContainerImage.Common.psm1'
Import-Module $containerModulePath -Force
$targetArchModulePath = Resolve-ContainerImageModulePath -ModuleRoot $ModuleRoot -Name 'WindowsTargetArch.Common.psm1' -Optional
if ($targetArchModulePath -and -not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $targetArchModulePath }

# Import-Versions fills the process env from versions.env unless a build-arg already set it.
if ($ScriptDir) { & (Join-Path $ScriptDir 'Import-Versions.ps1') }

# The URL builders and pin names have one owner: WindowsContainerImage.Common, which the host provisioner calls too.

$arch = if ([string]::IsNullOrWhiteSpace($TargetArch)) { Get-WindowsTargetArch } else { $TargetArch }
if ($arch -notin 'amd64', 'arm64') { throw "Install-Lavapipe: -TargetArch must be amd64 or arm64; got '$arch'" }

$runtime = Install-LavapipeRuntime -Arch $arch -Lookup { param([string]$name) [Environment]::GetEnvironmentVariable($name) } `
    -ArchiveDirectory $TempDir -Destination $InstallDir `
    -RequiredFile @('vulkan_lvp.dll', 'vulkan-1.dll', 'vulkaninfo.exe')
$icdName = $runtime.IcdName
$icd = Join-Path $InstallDir $icdName
$driver = Join-Path $InstallDir 'vulkan_lvp.dll'
$loader = Join-Path $InstallDir 'vulkan-1.dll'
$machine = if ($arch -eq 'amd64') { 0x8664 } else { 0xAA64 }
foreach ($f in $driver, $loader) {
    $actual = Get-PeFileMachine -Path $f
    if ($actual -ne $machine) { throw ('Install-Lavapipe: {0} is machine 0x{1:X4}, expected 0x{2:X4}' -f $f, $actual, $machine) }
}
# The ICD resolves its driver relative to the JSON, so both must stay in the same directory.
$icdJson = Get-Content -LiteralPath $icd -Raw | ConvertFrom-Json
if ($icdJson.ICD.library_path -notmatch 'vulkan_lvp\.dll$') {
    throw "Install-Lavapipe: $icd does not name vulkan_lvp.dll (library_path '$($icdJson.ICD.library_path)')"
}

if ($arch -eq 'amd64') { Register-LavapipeIcd -IcdPath $icd }
Write-Host ("lavapipe {0} ({1}) + Vulkan loader {2} staged in {3}{4}" -f `
        $runtime.MesaVersion, $arch, $runtime.VulkanVersion, $InstallDir, $(if ($arch -eq 'amd64') { ', ICD registered in HKLM' } else { '' }))
