param(
    [string]$TempDir = 'C:\temp',
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

$CMakeNightlyUrl = Resolve-ContainerImageValue -Value $CMakeNightlyUrl -EnvironmentVariable 'CMAKE_NIGHTLY_URL' -DefaultValue 'https://cmake.org/files/dev/cmake-4.3.20260425-gedeedd9-windows-x86_64.msi'
$VulkanVersion = Resolve-ContainerImageValue -Value $VulkanVersion -EnvironmentVariable 'VULKAN_VERSION'

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$scoopInstallScript = Join-Path $TempDir 'install-scoop.ps1'
irm get.scoop.sh -outfile $scoopInstallScript
& $scoopInstallScript -RunAsAdmin
scoop bucket add main
scoop bucket add extras
scoop bucket add versions
scoop install main/7zip
scoop config use_external_7zip true
scoop install main/rustup

if ([string]::IsNullOrWhiteSpace($VulkanVersion)) {
    scoop install main/vulkan
} else {
    scoop install "main/vulkan@$VulkanVersion"
}

scoop install --global extras/flutter
scoop install llvm nano cppcheck sccache main/ninja extras/nsis main/uv main/nuget

Write-Host ('Downloading CMake nightly from {0}...' -f $CMakeNightlyUrl)
$cmakeInstaller = Join-Path $TempDir 'cmake-nightly.msi'
Invoke-WebRequest -Uri $CMakeNightlyUrl -OutFile $cmakeInstaller
Write-Host 'Installing CMake nightly...'
Start-Process msiexec.exe -ArgumentList '/i', $cmakeInstaller, '/quiet', '/norestart', 'ADD_CMAKE_TO_PATH=System' -Wait -NoNewWindow
Remove-Item $cmakeInstaller -Force
Write-Host 'CMake nightly installation complete.'
