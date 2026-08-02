# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

param(
    [string]$TempDir = 'C:\temp',
    # Default derived below from versions.env's GIT_VERSION (baked by load-versions.ps1);
    # pass an explicit URL only for a git-for-windows respin (…windows.2 tag).
    [string]$GitInstallerUrl = '',
    [string]$CMakeVersion = '',
    [string]$VulkanVersion = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$installerModulePath = Join-Path $PSScriptRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force

# Shared helpers (Invoke-DownloadWithRetry, etc.) come through the Common modules' re-export.

# CMake stable pin comes from versions.env's CMAKE_VERSION (baked in by
# load-versions.ps1 / passed as -CMakeVersion from the Dockerfile ARG); empty
# falls through to scoop's current stable manifest.
$CMakeVersion = Resolve-ContainerImageValue -Value $CMakeVersion -EnvironmentVariable 'CMAKE_VERSION'
$VulkanVersion = Resolve-ContainerImageValue -Value $VulkanVersion -EnvironmentVariable 'VULKAN_VERSION'

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

# Derive the Git installer URL from GIT_VERSION (versions.env) so the pin cannot drift
# invisibly in a param default -- same pattern as the CMake/Vulkan pins above. The
# ".windows.1" tag suffix covers normal releases; a respun release needs -GitInstallerUrl.
$gitVer = Resolve-ContainerImageValue -EnvironmentVariable 'GIT_VERSION' -DefaultValue '2.54.0'
$GitInstallerUrl = Resolve-ContainerImageValue -Value $GitInstallerUrl -EnvironmentVariable 'GIT_INSTALLER_URL' `
    -DefaultValue "https://github.com/git-for-windows/git/releases/download/v$gitVer.windows.1/Git-$gitVer-64-bit.exe"

$gitInstaller = Join-Path $TempDir 'Git-64-bit.exe'
# SHA256 pin from versions.env (GIT_WINDOWS_INSTALLER_SHA256, baked env). Empty
# (e.g. a -GitInstallerUrl override for a respun release) skips the hash check.
$gitSha = Resolve-ContainerImageValue -EnvironmentVariable 'GIT_WINDOWS_INSTALLER_SHA256' -DefaultValue ''
Invoke-DownloadWithRetry -Url $GitInstallerUrl -DestinationPath $gitInstaller -Description 'Git for Windows installer' -ExpectSignature MZ -ExpectedSha256 $gitSha
Start-Process -FilePath $gitInstaller -ArgumentList '/SILENT', '/NORESTART' -Wait
Remove-Item $gitInstaller -Force
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Git\bin',
    'C:\Program Files\Git\usr\bin'
) | Out-Null

# WiX versions come from versions.env (single source of truth shared with the
# verify-toolchain.ps1 assert); defaults keep the script runnable standalone.
$WixVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_VERSION' -DefaultValue '4.0.6'
$WixUiExtVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_UI_EXT_VERSION' -DefaultValue '4.0.4'
dotnet tool install --tool-path C:\WiX wix --version $WixVersion
& 'C:\WiX\wix.exe' extension add --global "WixToolset.UI.wixext/$WixUiExtVersion"

Enable-Tls12ForDownloads
$scoopInstallScript = Join-Path $TempDir 'install-scoop.ps1'
# Hardened fetch (retry + TLS) instead of a bare one-shot irm -- a transient blip here
# killed the whole base build. Hash-pinned (SCOOP_INSTALLER_SHA256): this script is
# EXECUTED, so we only run the exact bytes that were reviewed when the pin was set.
# Scoop revving the installer surfaces as a mismatch -- re-review and bump the pin.
$scoopSha = Resolve-ContainerImageValue -EnvironmentVariable 'SCOOP_INSTALLER_SHA256' -DefaultValue ''
Invoke-DownloadWithRetry -Url 'https://get.scoop.sh' -DestinationPath $scoopInstallScript -Description 'scoop installer script' -ExpectedSha256 $scoopSha
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

# Rust is provisioned by setup-rust-toolchain.ps1 via rustup WITH a default
# toolchain (single provider; Flutter's Cargokit hard-requires rustup). We
# deliberately install NO rust here: scoop rust would compete with the rustup
# proxies in CARGO_BIN, and a toolchain-LESS rustup would drop proxy shims that
# resolve no toolchain (the failure the old "never rustup" rule guarded against).

if ([string]::IsNullOrWhiteSpace($VulkanVersion)) {
    scoop install main/vulkan
} else {
    scoop install "main/vulkan@$VulkanVersion"
}

scoop install --global extras/flutter
# llvm DELIBERATELY UNPINNED (Windows tracks scoop's latest; versions.env's LLVM_RELEASE
# pins only the Linux lane -- the smoke test asserts a well-formed clang-cl version, not
# that value).
# pkg-config: consumers' CMake `find_package(PkgConfig)` + `pkg_check_modules(...)` need
# the BINARY -- the image bakes PKG_CONFIG_PATH and the .pc files, but the source-built
# GStreamer (unlike the old MSI) ships no pkg-config tool. NOTE: scoop main has no
# `pkgconf` manifest; the package name is `pkg-config`.
scoop install llvm nano cppcheck sccache main/ninja extras/nsis main/uv main/nuget extras/zlib main/nasm main/openssl main/pkg-config

# CMake stable release via scoop (replaces the old cmake.org MSI download); the
# shim lands on the scoop user-shims PATH like every other tool installed here.
if ([string]::IsNullOrWhiteSpace($CMakeVersion)) {
    scoop install main/cmake
} else {
    Write-Host ('Installing CMake {0} (stable) via scoop...' -f $CMakeVersion)
    scoop install "main/cmake@$CMakeVersion"
}

# Drop scoop's download cache — the installers (LLVM, Flutter, Vulkan SDK, ...) are
# already unpacked into the apps dir and only bloat this (large) layer otherwise.
Write-Host 'Clearing scoop download cache...'
scoop cache rm * 2>&1 | Out-Null

# Same-layer cleanup for the other caches this script fills: the WiX dotnet-tool
# install leaves its nupkgs in the NuGet cache (the tool is fully materialized at
# C:\WiX) and installers drop temp files. Must happen HERE, not in a later stage:
# the classic builder cannot shrink an already-committed layer from a later one.
foreach ($d in @("$env:USERPROFILE\.nuget\packages", "$env:LOCALAPPDATA\Temp")) {
    if (Test-Path $d) {
        Write-Host "Clearing $d ..."
        Remove-Item "$d\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

