# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$TempDir = 'C:\temp',
    [string]$GitInstallerUrl = 'https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/Git-2.54.0-64-bit.exe',
    [string]$CMakeNightlyUrl = '',
    [string]$VulkanVersion = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$CMakeNightlyUrl = Resolve-ContainerImageValue -Value $CMakeNightlyUrl -EnvironmentVariable 'CMAKE_NIGHTLY_URL' -DefaultValue 'https://cmake.org/files/v4.3/cmake-4.3.3-windows-x86_64.msi'
$VulkanVersion = Resolve-ContainerImageValue -Value $VulkanVersion -EnvironmentVariable 'VULKAN_VERSION'

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

$gitInstaller = Join-Path $TempDir 'Git-64-bit.exe'
Invoke-WebRequest -Uri $GitInstallerUrl -OutFile $gitInstaller
Start-Process -FilePath $gitInstaller -ArgumentList '/SILENT', '/NORESTART' -Wait
Remove-Item $gitInstaller -Force
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Git\bin',
    'C:\Program Files\Git\usr\bin'
) | Out-Null

dotnet tool install --tool-path C:\WiX wix --version 4.0.6
& 'C:\WiX\wix.exe' extension add --global WixToolset.UI.wixext/4.0.4

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$scoopInstallScript = Join-Path $TempDir 'install-scoop.ps1'
irm get.scoop.sh -outfile $scoopInstallScript
& $scoopInstallScript -RunAsAdmin
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Users\ContainerAdministrator\scoop\shims',
    'C:\ProgramData\scoop\shims'
) | Out-Null
Assert-ContainerCommandAvailable -Name 'git' | Out-Null
Assert-ContainerCommandAvailable -Name 'scoop' | Out-Null
scoop bucket add main
scoop bucket add extras
scoop bucket add versions
scoop install main/7zip
scoop config use_external_7zip true

# Rust is provisioned by setup-rust-toolchain.ps1 via scoop (single provider).
# We deliberately do NOT install rustup here: a toolchain-less rustup drops proxy
# shims into CARGO_BIN that shadow scoop's real cargo/rustc on PATH and fail with
# "no default toolchain". scoop's shims resolve to the actual binaries instead.

if ([string]::IsNullOrWhiteSpace($VulkanVersion)) {
    scoop install main/vulkan
} else {
    scoop install "main/vulkan@$VulkanVersion"
}

scoop install --global extras/flutter
scoop install llvm nano cppcheck sccache main/ninja extras/nsis main/uv main/nuget extras/zlib main/nasm main/openssl

Write-Host ('Downloading CMake nightly from {0}...' -f $CMakeNightlyUrl)
$cmakeInstaller = Join-Path $TempDir 'cmake-nightly.msi'
Invoke-WebRequest -Uri $CMakeNightlyUrl -OutFile $cmakeInstaller
Write-Host 'Installing CMake nightly...'
Start-Process msiexec.exe -ArgumentList '/i', $cmakeInstaller, '/quiet', '/norestart', 'ADD_CMAKE_TO_PATH=System' -Wait -NoNewWindow
Remove-Item $cmakeInstaller -Force
Write-Host 'CMake nightly installation complete.'

# Drop scoop's download cache — the installers (LLVM, Flutter, Vulkan SDK, ...) are
# already unpacked into the apps dir and only bloat this (large) layer otherwise.
Write-Host 'Clearing scoop download cache...'
scoop cache rm * 2>&1 | Out-Null
