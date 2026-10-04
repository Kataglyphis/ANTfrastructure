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

<#
.SYNOPSIS
    The mmozeiko/build-mesa release asset for an arch.
#>
function Get-LavapipeWindowsUrl {
    param([AllowEmptyString()][string]$Version, [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch)
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "Get-LavapipeWindowsUrl: LAVAPIPE_VERSION must be an x.y.z release like 26.2.3; got '$Version'"
    }
    $suffix = if ($Arch -eq 'amd64') { 'x64' } else { 'arm64' }
    return "https://github.com/mmozeiko/build-mesa/releases/download/$Version/mesa-lavapipe-$suffix-$Version.7z"
}

<#
.SYNOPSIS
    LunarG's Runtime Components zip for an arch: x64 under `windows`, arm64 under `warm`.
#>
function Get-VulkanRuntimeComponentsUrl {
    param([AllowEmptyString()][string]$Version, [Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch)
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Get-VulkanRuntimeComponentsUrl: VULKAN_VERSION must be a four-part LunarG SDK version like 1.4.357.0; got '$Version'"
    }
    if ($Arch -eq 'amd64') { return "https://sdk.lunarg.com/sdk/download/$Version/windows/VulkanRT-X64-$Version-Components.zip" }
    return "https://sdk.lunarg.com/sdk/download/$Version/warm/VulkanRT-ARM64-$Version-Components.zip"
}

<#
.SYNOPSIS
    The versions.env key holding a download's SHA256 for an arch.
#>
function Get-LavapipePinName {
    param([Parameter(Mandatory)][ValidateSet('amd64', 'arm64')][string]$Arch, [Parameter(Mandatory)][ValidateSet('mesa', 'loader')][string]$Kind)
    if ($Kind -eq 'mesa') {
        # X64, not AMD64: the pin follows the release asset's spelling (mesa-lavapipe-x64-...).
        $suffix = if ($Arch -eq 'amd64') { 'X64' } else { 'ARM64' }
        return "LAVAPIPE_WINDOWS_${suffix}_SHA256"
    }
    if ($Arch -eq 'amd64') { return 'VULKAN_RT_WINDOWS_ZIP_SHA256' }
    return 'VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256'
}

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

$mesaVersion = "$([Environment]::GetEnvironmentVariable('LAVAPIPE_VERSION'))".Trim()
$vulkanVersion = "$([Environment]::GetEnvironmentVariable('VULKAN_VERSION'))".Trim()
foreach ($pin in @(@{ n = 'LAVAPIPE_VERSION'; v = $mesaVersion }, @{ n = 'VULKAN_VERSION'; v = $vulkanVersion })) {
    if ([string]::IsNullOrWhiteSpace($pin.v)) { throw "Install-Lavapipe: $($pin.n) is unset -- versions.env was not loaded (pass -ScriptDir)" }
}
$mesaPinName = Get-LavapipePinName -Arch $arch -Kind 'mesa'
$loaderPinName = Get-LavapipePinName -Arch $arch -Kind 'loader'
$mesaSha = "$([Environment]::GetEnvironmentVariable($mesaPinName))".Trim()
$loaderSha = "$([Environment]::GetEnvironmentVariable($loaderPinName))".Trim()
foreach ($pin in @(@{ n = $mesaPinName; v = $mesaSha }, @{ n = $loaderPinName; v = $loaderSha })) {
    if ($pin.v -notmatch '^[0-9a-fA-F]{64}$') { throw "Install-Lavapipe: $($pin.n) must be a 64-hex SHA256 (see versions.env); got '$($pin.v)'" }
}

$mesaUrl = Get-LavapipeWindowsUrl -Version $mesaVersion -Arch $arch
$loaderUrl = Get-VulkanRuntimeComponentsUrl -Version $vulkanVersion -Arch $arch
$mesaArchive = Join-Path $TempDir ([IO.Path]::GetFileName($mesaUrl))
$loaderZip = Join-Path $TempDir ([IO.Path]::GetFileName($loaderUrl))

Write-Host "Downloading lavapipe $mesaVersion ($arch): $mesaUrl"
Invoke-DownloadWithRetry -Url $mesaUrl -DestinationPath $mesaArchive -Description "lavapipe $mesaVersion" -ExpectedSha256 $mesaSha
$sevenZip = @((Get-Command 7z -ErrorAction SilentlyContinue | ForEach-Object Source), "$env:ProgramFiles\7-Zip\7z.exe") |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $sevenZip) { throw 'Install-Lavapipe: 7-Zip is needed to unpack lavapipe, and neither 7z on PATH nor Program Files\7-Zip has it' }
& $sevenZip x -y "-o$InstallDir" $mesaArchive | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Install-Lavapipe: 7-Zip exited $LASTEXITCODE unpacking $mesaArchive" }

Write-Host "Downloading the Vulkan loader ${vulkanVersion}: $loaderUrl"
Invoke-DownloadWithRetry -Url $loaderUrl -DestinationPath $loaderZip -Description "Vulkan Runtime Components $vulkanVersion" -ExpectSignature PK -ExpectedSha256 $loaderSha
$binPrefix = if ($arch -eq 'amd64') { 'x64/' } else { '' }
Expand-VulkanRuntimeComponents -ZipPath $loaderZip -Destination $InstallDir -BinPrefix $binPrefix -BinNames @('vulkan-1.dll', 'vulkaninfo.exe')

Remove-Item -LiteralPath $mesaArchive, $loaderZip -Force -ErrorAction SilentlyContinue

$icdName = if ($arch -eq 'amd64') { 'lvp_icd.x86_64.json' } else { 'lvp_icd.aarch64.json' }
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
        $mesaVersion, $arch, $vulkanVersion, $InstallDir, $(if ($arch -eq 'amd64') { ', ICD registered in HKLM' } else { '' }))
