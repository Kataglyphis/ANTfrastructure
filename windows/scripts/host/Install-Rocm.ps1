# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Installs AMD ROCm (TheRock distribution) for Windows from AMD's tarball.
.DESCRIPTION
    The Windows twin of linux/scripts/01-core/setup-rocm-repo.sh: the same TheRock
    release, from the same stable.repo.amd.com host, as AMD documents it under
    install -> Windows -> tar. amd64 only. AMD publishes no checksum, so the
    tarball is verified against the self-measured SHA256 pinned in versions.env.
    It runs in the sdk slot, FROM the plain base; why there, and what it does NOT put
    on PATH: docs/windows-builds.md § ROCm layer. It also registers TheRock's
    amdocl64.dll as an OpenCL ICD for TheRock's Khronos loader (docs/windows-rocm.md).
#>
param(
    [string]$TempDir = 'C:\temp',
    [string]$RocmRelease = '',
    [string]$GfxFamily = '',
    [string]$TarballSha256 = '',
    [string]$InstallDir = 'C:\TheRock\build',
    [string]$TargetArch = ''
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
    Refuses every target but amd64: AMD ships no Windows arm64 ROCm.
#>
function Assert-RocmTargetArch {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$TargetArch)
    if ($TargetArch -ne 'amd64') {
        throw "Install-Rocm: ROCm on Windows is amd64-only (AMD publishes no arm64 tarball); got -TargetArch '$TargetArch'"
    }
}

<#
.SYNOPSIS
    Refuses a base from a CUDA chain: the rocm sdk builds FROM the plain base.
#>
function Assert-RocmForkBase {
    param(
        [AllowEmptyString()][string]$GpuType,
        [AllowEmptyString()][string]$CudaRoot,
        [AllowEmptyString()][string]$CudaPath
    )
    $leaked = @(@{ GPU_TYPE = $GpuType; CUDA_ROOT = $CudaRoot; CUDA_PATH = $CudaPath }.GetEnumerator() |
        Where-Object { $_.Value -and -not ($_.Key -eq 'GPU_TYPE' -and $_.Value -eq 'cpu') } |
        Sort-Object Key | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value })
    if ($leaked.Count -gt 0) {
        throw (("Install-Rocm: the base image is not the plain base ({0}). The rocm sdk builds FROM the plain " +
                "base (bk-windows-base), never FROM an nvidia sdk -- check the BASE_IMAGE this stage was given.") -f ($leaked -join ', '))
    }
}

<#
.SYNOPSIS
    Builds the tarball URL, refusing anything that is not a release and a GPU family name.
#>
function Get-RocmWindowsTarballUrl {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Release,
        [Parameter(Mandatory)][AllowEmptyString()][string]$GfxFamily,
        [string]$BaseUrl = 'https://stable.repo.amd.com/rocm/core/tarball'
    )
    if ($Release -notmatch '^\d+\.\d+\.\d+$') {
        throw "Install-Rocm: ROCM_WINDOWS_RELEASE must be a full release like 10.0.0; got '$Release'"
    }
    # AMD's family names: multiarch, gfx120X-all, gfx1151, gfx101X-dgpu, ...
    if ($GfxFamily -cnotmatch '^(multiarch|gfx[0-9A-Za-z]+(-[a-z]+)?)$') {
        throw "Install-Rocm: ROCM_WINDOWS_GFX_FAMILY '$GfxFamily' is not an AMD GPU family name (e.g. gfx120X-all, multiarch)"
    }
    return ('{0}/therock-dist-windows-{1}-{2}.tar.gz' -f $BaseUrl.TrimEnd('/'), $GfxFamily, $Release)
}

<#
.SYNOPSIS
    Fails with every missing piece listed when the extracted tree is not a usable HIP SDK.
#>
function Assert-RocmWindowsLayout {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Release
    )
    $files = 'bin\hipcc.exe', 'bin\hipconfig.exe', 'bin\hipInfo.exe', 'bin\OpenCL.dll', 'bin\amdocl64.dll',
        'include\hip\hip_runtime.h', 'lib\llvm\bin\clang.exe'
    $missing = @($files | Where-Object { -not [System.IO.File]::Exists([System.IO.Path]::Combine($Root, $_)) })
    # Globs, because the file names carry versions (amdhip64_7.dll) or vary by family.
    $globs = [ordered]@{ 'bin\amdhip64_*.dll (HIP runtime)' = 'bin|amdhip64_*.dll'; 'lib\llvm\amdgcn\bitcode\*.bc (HIP_DEVICE_LIB_PATH)' = 'lib\llvm\amdgcn\bitcode|*.bc' }
    foreach ($label in $globs.Keys) {
        $dir, $filter = $globs[$label] -split '\|'
        if (-not @(Get-ChildItem -Path ([System.IO.Path]::Combine($Root, $dir)) -Filter $filter -File -ErrorAction SilentlyContinue)) { $missing += $label }
    }
    $versionFile = [System.IO.Path]::Combine($Root, '.info', 'version')
    $shipped = if ([System.IO.File]::Exists($versionFile)) { [System.IO.File]::ReadAllText($versionFile).Trim() } else { $null }
    if ($null -eq $shipped) { $missing += '.info\version' }
    elseif ($shipped -ne $Release) { $missing += ".info\version says '$shipped', expected '$Release'" }
    if ($missing.Count -gt 0) {
        throw ("Install-Rocm: the ROCm tree under {0} is incomplete:`n  {1}" -f $Root, ($missing -join "`n  "))
    }
}

<#
.SYNOPSIS
    Registers an OpenCL ICD as the Khronos loader reads it: value name = the DLL's full path, REG_DWORD 0.
.DESCRIPTION
    64-bit registry view only: amdocl64.dll is a 64-bit ICD, and a 32-bit loader reads WOW6432Node.
    OCL_ICD_FILENAMES is no substitute: the loader ignores it in a high-integrity (elevated admin) process.
#>
function Register-OpenClIcd {
    param(
        [Parameter(Mandatory)][string]$IcdPath,
        [Microsoft.Win32.RegistryKey]$BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64'),
        [string]$SubKey = 'SOFTWARE\Khronos\OpenCL\Vendors'
    )
    if (-not [System.IO.Path]::IsPathFullyQualified($IcdPath) -or -not [System.IO.File]::Exists($IcdPath)) {
        throw "Install-Rocm: OpenCL ICD '$IcdPath' is not an existing absolute path; the loader LoadLibrary's the value name as is"
    }
    $key = $BaseKey.CreateSubKey($SubKey, $true)
    try { $key.SetValue($IcdPath, 0, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $key.Dispose() }
}

$RocmRelease = Resolve-ContainerImageValue -Value $RocmRelease -EnvironmentVariable 'ROCM_WINDOWS_RELEASE'
$GfxFamily = Resolve-ContainerImageValue -Value $GfxFamily -EnvironmentVariable 'ROCM_WINDOWS_GFX_FAMILY'
$TarballSha256 = Resolve-ContainerImageValue -Value $TarballSha256 -EnvironmentVariable 'ROCM_WINDOWS_TARBALL_SHA256'
$TargetArch = Resolve-ContainerImageValue -Value $TargetArch -EnvironmentVariable 'WINDOWS_TARGET_ARCH' -DefaultValue 'amd64'

Assert-RocmTargetArch -TargetArch $TargetArch
Assert-RocmForkBase -GpuType $env:GPU_TYPE -CudaRoot $env:CUDA_ROOT -CudaPath $env:CUDA_PATH
# The pin is the only integrity check AMD's tarball has, so an empty one fails closed.
if ($TarballSha256 -notmatch '^[0-9a-fA-F]{64}$') {
    throw "Install-Rocm: ROCM_WINDOWS_TARBALL_SHA256 must be a 64-hex SHA256 (AMD publishes none; see versions.env); got '$TarballSha256'"
}
$url = Get-RocmWindowsTarballUrl -Release $RocmRelease -GfxFamily $GfxFamily

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir
$tarball = Join-Path $TempDir ([System.IO.Path]::GetFileName($url))
Write-Host "Downloading ROCm $RocmRelease ($GfxFamily) for Windows: $url"
Invoke-DownloadWithRetry -Url $url -DestinationPath $tarball -Description "ROCm $RocmRelease ($GfxFamily) Windows tarball" -ExpectedSha256 $TarballSha256

# Windows' own bsdtar by full path: Git's GNU tar is also on PATH and misreads `C:\` paths.
$tar = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'tar.exe')
if (-not [System.IO.File]::Exists($tar)) { throw "Install-Rocm: $tar not found" }
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Write-Host "Extracting into $InstallDir ..."
& $tar -xzf $tarball -C $InstallDir --strip-components=1
if ($LASTEXITCODE -ne 0) {
    throw "Install-Rocm: tar exited $LASTEXITCODE extracting $tarball (left in place for analysis)"
}
Remove-Item -LiteralPath $tarball -Force -ErrorAction SilentlyContinue
Clear-PendingFileHandle

Assert-RocmWindowsLayout -Root $InstallDir -Release $RocmRelease
$icd = Join-Path $InstallDir 'bin\amdocl64.dll'
Register-OpenClIcd -IcdPath $icd
Write-Host "Registered $icd as an OpenCL ICD (HKLM\SOFTWARE\Khronos\OpenCL\Vendors)"

# The one thing only this container can prove: AMD's hipcc runs on Server Core.
$env:HIP_PATH = $InstallDir
& (Join-Path $InstallDir 'bin\hipcc.exe') --version
if ($LASTEXITCODE -ne 0) { throw "Install-Rocm: hipcc --version exited $LASTEXITCODE inside the container" }

Write-Host "ROCm $RocmRelease ($GfxFamily) installed at $InstallDir"
Clear-PendingFileHandle
