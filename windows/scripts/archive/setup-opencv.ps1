# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

param(
    [string]$TempDir = 'C:\temp',
    [string]$OpenCvVersion = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$OpenCvVersion = Resolve-ContainerImageValue -Value $OpenCvVersion -EnvironmentVariable 'OPENCV_VERSION'
$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

Write-Host 'Downloading OpenCV...'
$opencvUrl = 'https://github.com/opencv/opencv/releases/download/{0}/opencv-{0}-windows.exe' -f $OpenCvVersion
$opencvInstaller = Join-Path $TempDir 'opencv.exe'
Invoke-WebRequest -Uri $opencvUrl -OutFile $opencvInstaller
Write-Host 'Extracting OpenCV using 7-Zip (bypassing GUI hang)...'
7z.exe x $opencvInstaller -oC:\ -y -bsp1
Remove-Item $opencvInstaller -Force
Write-Host 'OpenCV extracted successfully.'
