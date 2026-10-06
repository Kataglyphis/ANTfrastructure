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
    [string]$ScriptDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$containerModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $containerModulePath)) { throw "Required module not found: $containerModulePath" }
Import-Module $containerModulePath -Force
$targetArchModulePath = Join-Path $scriptAssetRoot 'modules\WindowsTargetArch.Common.psm1'
if ((Test-Path $targetArchModulePath) -and -not (Get-Module -Name 'WindowsTargetArch.Common')) { Import-Module $targetArchModulePath }

# Import-Versions fills the process env from versions.env unless a build-arg already set it.
if ($ScriptDir) { & (Join-Path $ScriptDir 'Import-Versions.ps1') }

# The URL builders and pin names have one owner: WindowsContainerImage.Common, which the host provisioner calls too.

<#
.SYNOPSIS
    Registers an ICD under HKLM\SOFTWARE\Khronos\Vulkan\Drivers.
#>
function Register-LavapipeIcd {
    param([Parameter(Mandatory)][string]$IcdPath)
    $key = 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers'
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name $IcdPath -Value 0 -PropertyType DWord -Force | Out-Null
}

$arch = if ([string]::IsNullOrWhiteSpace($TargetArch)) { Get-WindowsTargetArch } else { $TargetArch }
if ($arch -notin 'amd64', 'arm64') { throw "Install-Lavapipe: -TargetArch must be amd64 or arm64; got '$arch'" }

$pinValues = Get-LavapipePinValues -Arch $arch -Lookup { param([string]$name) [Environment]::GetEnvironmentVariable($name) }
$assets = Resolve-LavapipeAssets -Arch $arch -MesaVersion $pinValues.MesaVersion -VulkanVersion $pinValues.VulkanVersion -MesaSha256 $pinValues.MesaSha256 -LoaderSha256 $pinValues.LoaderSha256
$mesaUrl = $assets.MesaUrl
$loaderUrl = $assets.LoaderUrl
$mesaArchive = Join-Path $TempDir ([IO.Path]::GetFileName($mesaUrl))
$loaderZip = Join-Path $TempDir ([IO.Path]::GetFileName($loaderUrl))

Write-Host "Downloading lavapipe $($pinValues.MesaVersion) ($arch): $mesaUrl"
Invoke-DownloadWithRetry -Url $mesaUrl -DestinationPath $mesaArchive -Description "lavapipe $($pinValues.MesaVersion)" -ExpectedSha256 $pinValues.MesaSha256
Expand-LavapipeArchive -ArchivePath $mesaArchive -Destination $InstallDir

Write-Host "Downloading the Vulkan loader $($pinValues.VulkanVersion): $loaderUrl"
Invoke-DownloadWithRetry -Url $loaderUrl -DestinationPath $loaderZip -Description "Vulkan Runtime Components $($pinValues.VulkanVersion)" -ExpectSignature PK -ExpectedSha256 $pinValues.LoaderSha256
$binPrefix = $assets.BinPrefix
Expand-VulkanRuntimeComponents -ZipPath $loaderZip -Destination $InstallDir -BinPrefix $binPrefix -BinNames @('vulkan-1.dll', 'vulkaninfo.exe')

Remove-Item -LiteralPath $mesaArchive, $loaderZip -Force -ErrorAction SilentlyContinue

$icdName = $assets.IcdName
$icd = Join-Path $InstallDir $icdName
$driver = Join-Path $InstallDir 'vulkan_lvp.dll'
$loader = Join-Path $InstallDir 'vulkan-1.dll'
foreach ($f in $icd, $driver, $loader, (Join-Path $InstallDir 'vulkaninfo.exe')) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Install-Lavapipe: $f is missing after the unpack" }
}
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
        $pinValues.MesaVersion, $arch, $pinValues.VulkanVersion, $InstallDir, $(if ($arch -eq 'amd64') { ', ICD registered in HKLM' } else { '' }))
