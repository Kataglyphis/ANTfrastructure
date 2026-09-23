# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Installs the Khronos Vulkan loader (vulkan-1.dll) from LunarG's Runtime Components zip.
.DESCRIPTION
    Server Core ships no vulkan-1.dll, so every Vulkan-linked binary in the image fails to load.
    This puts LunarG's signed x64 loader into System32, where VulkanRT.exe puts it on a real host and
    the only place FFmpeg's dlopen and Python's DLL search look besides the app dir (neither reads PATH),
    and the verified copy plus its licence into InstallDir. The zip is the base SDK's VULKAN_VERSION,
    verified against the pinned SHA256. No ICD in the container: the loader reports zero devices.
    amd64 only. docs/windows-rocm.md § The ROCm layer.
#>
param(
    [string]$TempDir = 'C:\temp',
    [string]$VulkanVersion = '',
    [string]$ZipSha256 = '',
    [string]$InstallDir = 'C:\vulkan-loader',
    [string]$TargetArch = '',
    [string]$SystemDir = [System.Environment]::SystemDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}
Import-Module $sharedModulePath -Force

<#
.SYNOPSIS
    LunarG's Runtime Components zip URL, refusing anything that is not a four-part SDK version.
#>
function Get-VulkanRuntimeZipUrl {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Version,
        [string]$BaseUrl = 'https://sdk.lunarg.com/sdk/download'
    )
    if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        throw "Install-VulkanLoader: VULKAN_VERSION must be a four-part LunarG SDK version like 1.4.357.0; got '$Version'"
    }
    return ('{0}/{1}/windows/VulkanRT-X64-{1}-Components.zip' -f $BaseUrl.TrimEnd('/'), $Version)
}

<#
.SYNOPSIS
    Extracts x64\vulkan-1.dll and VulkanRT-License.txt from the zip, flat into Destination.
#>
function Expand-VulkanLoaderZip {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$Destination
    )
    $wanted = [ordered]@{ 'vulkan-1.dll' = '(^|/)x64/vulkan-1\.dll$'; 'VulkanRT-License.txt' = '(^|/)VulkanRT-License\.txt$' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $plan = @(foreach ($name in $wanted.Keys) {
                $hits = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -match $wanted[$name] })
                if ($hits.Count -ne 1) {
                    throw "Install-VulkanLoader: $ZipPath holds $($hits.Count) entries matching $($wanted[$name]), expected exactly 1"
                }
                @{ Entry = $hits[0]; Name = $name }
            })
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
        foreach ($p in $plan) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($p.Entry, (Join-Path $Destination $p.Name), $true)
        }
    } finally { $zip.Dispose() }
}

<#
.SYNOPSIS
    The numeric file version of a PE (major.minor.build.private), '' when it carries none.
#>
function Get-PeFileVersionNumber {
    param([Parameter(Mandatory)][string]$Path)
    $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($null -eq $v.FileVersion) { return '' }
    return ('{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart)
}

<#
.SYNOPSIS
    Copies the verified loader into SystemDir; a byte-identical copy is kept, any other copy is refused.
#>
function Install-VulkanLoaderSystemCopy {
    param(
        [Parameter(Mandatory)][string]$Loader,
        [Parameter(Mandatory)][string]$SystemDir
    )
    $target = Join-Path $SystemDir 'vulkan-1.dll'
    if ([System.IO.File]::Exists($target)) {
        if ((Get-FileHash -LiteralPath $target).Hash -eq (Get-FileHash -LiteralPath $Loader).Hash) { return $target }
        throw "Install-VulkanLoader: $target already exists with other bytes; the base image now ships a Vulkan loader, so choose one instead of overwriting it"
    }
    Copy-Item -LiteralPath $Loader -Destination $target
    return $target
}

<#
.SYNOPSIS
    Downloads, verifies and unpacks the loader; refuses a non-amd64 target or a malformed pin first.
#>
function Install-VulkanLoader {
    param(
        [Parameter(Mandatory)][string]$TempDir,
        [AllowEmptyString()][string]$VulkanVersion = '',
        [AllowEmptyString()][string]$ZipSha256 = '',
        [Parameter(Mandatory)][string]$InstallDir,
        [AllowEmptyString()][string]$TargetArch = '',
        [string]$SystemDir = [System.Environment]::SystemDirectory,
        [string]$BaseUrl = 'https://sdk.lunarg.com/sdk/download'
    )
    $VulkanVersion = Resolve-ContainerImageValue -Value $VulkanVersion -EnvironmentVariable 'VULKAN_VERSION'
    $ZipSha256 = Resolve-ContainerImageValue -Value $ZipSha256 -EnvironmentVariable 'VULKAN_RT_WINDOWS_ZIP_SHA256'
    $TargetArch = Resolve-ContainerImageValue -Value $TargetArch -EnvironmentVariable 'WINDOWS_TARGET_ARCH' -DefaultValue 'amd64'
    if ($TargetArch -ne 'amd64') {
        throw "Install-VulkanLoader: the pinned zip carries the x64 loader only; got -TargetArch '$TargetArch'"
    }
    if ($ZipSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Install-VulkanLoader: VULKAN_RT_WINDOWS_ZIP_SHA256 must be a 64-hex SHA256 (see versions.env); got '$ZipSha256'"
    }
    $url = Get-VulkanRuntimeZipUrl -Version $VulkanVersion -BaseUrl $BaseUrl

    $TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir
    $zipPath = Join-Path $TempDir ([System.IO.Path]::GetFileName($url))
    Write-Host "Downloading the Vulkan loader ${VulkanVersion}: $url"
    Invoke-DownloadWithRetry -Url $url -DestinationPath $zipPath -Description "Vulkan Runtime Components $VulkanVersion" `
        -ExpectSignature 'PK' -ExpectedSha256 $ZipSha256
    Expand-VulkanLoaderZip -ZipPath $zipPath -Destination $InstallDir
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    $loader = Join-Path $InstallDir 'vulkan-1.dll'
    $shipped = Get-PeFileVersionNumber -Path $loader
    if ($shipped -ne $VulkanVersion) {
        throw "Install-VulkanLoader: $loader reports version '$shipped', expected VULKAN_VERSION '$VulkanVersion'"
    }
    $system = Install-VulkanLoaderSystemCopy -Loader $loader -SystemDir $SystemDir
    Write-Host "Vulkan loader $VulkanVersion installed at $system (verified copy and licence in $InstallDir)"
    Clear-PendingFileHandle
}

Install-VulkanLoader -TempDir $TempDir -VulkanVersion $VulkanVersion -ZipSha256 $ZipSha256 -InstallDir $InstallDir -TargetArch $TargetArch -SystemDir $SystemDir
