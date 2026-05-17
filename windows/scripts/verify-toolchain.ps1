$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

where.exe flutter
where.exe wix.exe
where.exe clang-cl.exe
where.exe lld-link.exe

& 'C:\WiX\wix.exe' --version | Out-Host
$wixExtensions = & 'C:\WiX\wix.exe' extension list --global 2>&1
$wixExtensions | Out-Host
if (-not ($wixExtensions | Select-String -SimpleMatch 'WixToolset.UI.wixext 4.0.4')) {
    throw 'Required WiX extension not installed: WixToolset.UI.wixext 4.0.4'
}
