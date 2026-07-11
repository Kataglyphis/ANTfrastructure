# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$TempDir = 'C:\temp',
    # Default derived below from versions.env's GIT_VERSION (baked by load-versions.ps1);
    # pass an explicit URL only for a git-for-windows respin (…windows.2 tag).
    [string]$GitInstallerUrl = '',
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

$installerModulePath = Join-Path $PSScriptRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force

# Shared helpers (Invoke-DownloadWithRetry, etc.) come through the Common modules' re-export.

# Derive the fallback CMake URL from CMAKE_VERSION (baked in by load-versions.ps1)
# rather than a hardcoded literal that silently drifts from versions.env. The
# primary value still comes from the CMAKE_NIGHTLY_URL build-arg / env when set.
$cmakeVer = $env:CMAKE_VERSION
$cmakeDefaultUrl = if ($cmakeVer) { "https://cmake.org/files/v$(($cmakeVer -split '\.')[0..1] -join '.')/cmake-$cmakeVer-windows-x86_64.msi" } else { '' }
$CMakeNightlyUrl = Resolve-ContainerImageValue -Value $CMakeNightlyUrl -EnvironmentVariable 'CMAKE_NIGHTLY_URL' -DefaultValue $cmakeDefaultUrl
$VulkanVersion = Resolve-ContainerImageValue -Value $VulkanVersion -EnvironmentVariable 'VULKAN_VERSION'

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

# Derive the Git installer URL from GIT_VERSION (versions.env) so the pin cannot drift
# invisibly in a param default -- same pattern as the CMake fallback above. The
# ".windows.1" tag suffix covers normal releases; a respun release needs -GitInstallerUrl.
$gitVer = $env:GIT_VERSION
$gitDefaultUrl = if ($gitVer) { "https://github.com/git-for-windows/git/releases/download/v$gitVer.windows.1/Git-$gitVer-64-bit.exe" }
                 else { 'https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/Git-2.54.0-64-bit.exe' }
$GitInstallerUrl = Resolve-ContainerImageValue -Value $GitInstallerUrl -EnvironmentVariable 'GIT_INSTALLER_URL' -DefaultValue $gitDefaultUrl

$gitInstaller = Join-Path $TempDir 'Git-64-bit.exe'
Invoke-DownloadWithRetry -Url $GitInstallerUrl -DestinationPath $gitInstaller -Description 'Git for Windows installer' -ExpectSignature MZ
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
# killed the whole base build.
Invoke-DownloadWithRetry -Url 'https://get.scoop.sh' -DestinationPath $scoopInstallScript -Description 'scoop installer script'
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
# llvm DELIBERATELY UNPINNED (Windows tracks scoop's latest; versions.env's LLVM_RELEASE
# pins only the Linux lane -- the smoke test asserts a well-formed clang-cl version, not
# that value).
scoop install llvm nano cppcheck sccache main/ninja extras/nsis main/uv main/nuget extras/zlib main/nasm main/openssl

Write-Host ('Downloading CMake nightly from {0}...' -f $CMakeNightlyUrl)
$cmakeInstaller = Join-Path $TempDir 'cmake-nightly.msi'
Invoke-DownloadWithRetry -Url $CMakeNightlyUrl -DestinationPath $cmakeInstaller -Description 'CMake nightly MSI'
Write-Host 'Installing CMake nightly...'
Start-Process msiexec.exe -ArgumentList '/i', $cmakeInstaller, '/quiet', '/norestart', 'ADD_CMAKE_TO_PATH=System' -Wait -NoNewWindow
Remove-Item $cmakeInstaller -Force
Write-Host 'CMake nightly installation complete.'

# Drop scoop's download cache — the installers (LLVM, Flutter, Vulkan SDK, ...) are
# already unpacked into the apps dir and only bloat this (large) layer otherwise.
Write-Host 'Clearing scoop download cache...'
scoop cache rm * 2>&1 | Out-Null
