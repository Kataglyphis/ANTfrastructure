param(
    [string]$TempDir = 'C:\temp',
    [string]$GitInstallerUrl = 'https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/Git-2.54.0-64-bit.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

$gitInstaller = Join-Path $TempDir 'Git-64-bit.exe'
Invoke-WebRequest -Uri $GitInstallerUrl -OutFile $gitInstaller
Start-Process -FilePath $gitInstaller -ArgumentList '/SILENT', '/NORESTART' -Wait
Remove-Item $gitInstaller -Force

dotnet tool install --tool-path C:\WiX wix --version 4.0.6
& 'C:\WiX\wix.exe' extension add --global WixToolset.UI.wixext/4.0.4
