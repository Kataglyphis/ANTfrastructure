#requires -Version 7.0
<#
.SYNOPSIS
    Build OpenCV's standalone GStreamer videoio plugin against the installed OpenCV and GStreamer.

.DESCRIPTION
    See docs/windows-builds.md § Build-OpencvGstreamerPlugin.ps1.

.PARAMETER InstallDir
    Runtime prefix (default C:\runtime); must already hold lib\opencv5 and the GStreamer install.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [string]$SourceDir = 'C:\temp\opencv-plugin-src',
    [string]$OpenCvVersion = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

if (-not $OpenCvVersion) { $OpenCvVersion = $env:OPENCV_SOURCE_VERSION }
if (-not $OpenCvVersion) { $OpenCvVersion = $env:OPENCV_VERSION }
if (-not $OpenCvVersion) {
    throw 'build-opencv-gstreamer-plugin: no OpenCV version (OPENCV_SOURCE_VERSION/OPENCV_VERSION unset) - refusing to build an unpinned plugin.'
}

# Preconditions, checked before the clone so a broken image fails in seconds
$ocvInstallDir = Join-Path $InstallDir 'lib\opencv5'
$videoioDll = Get-ChildItem -Path $ocvInstallDir -Recurse -Filter 'opencv_videoio*.dll' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'gstreamer|ffmpeg|msmf|intel_mfx' } | Select-Object -First 1
if (-not $videoioDll) {
    throw "build-opencv-gstreamer-plugin: no opencv_videoio*.dll under $ocvInstallDir - OpenCV install missing or moved; the plugin would have no loader."
}
$gstHeader = Join-Path $InstallDir 'include\gstreamer-1.0\gst\gst.h'
if (-not (Test-Path $gstHeader)) {
    throw "build-opencv-gstreamer-plugin: $gstHeader missing - GStreamer must be built and installed into $InstallDir BEFORE this plugin (merge-stage order)."
}

# OpenCV source at the same pin the installed OpenCV was built from
New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null
$mainSrc = Join-Path $SourceDir 'opencv'
Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv.git' -Branch $OpenCvVersion -SourceDir $mainSrc | Out-Null

$pluginSrc = Join-Path $mainSrc 'modules\videoio\misc\plugin_gstreamer'
if (-not (Test-Path (Join-Path $pluginSrc 'CMakeLists.txt'))) {
    throw "build-opencv-gstreamer-plugin: $pluginSrc missing in the $OpenCvVersion tag - upstream moved the standalone plugin project; re-check backlog #93."
}

# OpenCVConfig.cmake's location varies with generator and platform, so search for it.
$ocvConfig = Get-ChildItem -Path $ocvInstallDir -Recurse -Filter 'OpenCVConfig.cmake' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ocvConfig) {
    throw "build-opencv-gstreamer-plugin: no OpenCVConfig.cmake under $ocvInstallDir - cannot point find_package(OpenCV) at the installed build."
}

$buildDir = Join-Path $SourceDir 'build'
$cmakeExtra = @(
    "-DOpenCV_DIR=$($ocvConfig.DirectoryName -replace '\\', '/')",
    # WIN32 GStreamer detection walks GSTREAMER_DIR with find_path/find_library.
    "-DGSTREAMER_DIR=$($InstallDir -replace '\\', '/')"
)

# Cross: unless BOTH OpenCV_ARCH and OpenCV_RUNTIME are set, OpenCVConfig probes the build machine's x64 dir and reports OpenCV_FOUND FALSE.
$plugTargetArch = Get-WindowsTargetArch
if (Test-WindowsCrossTarget -Arch $plugTargetArch) {
    $cmakeExtra += "-DOpenCV_ARCH=$(Get-OpenCvArchDir -Arch $plugTargetArch)", '-DOpenCV_RUNTIME=vc18'
    Write-Host "OpenCV plugin cross ($plugTargetArch): find_package pinned to $(Get-OpenCvArchDir -Arch $plugTargetArch)\vc18 (OpenCVConfig would otherwise detect the build machine)"
}
Invoke-CmakeConfigure -SourceDir $pluginSrc -BuildDir $buildDir -InstallPrefix $ocvInstallDir -ExtraArgs $cmakeExtra | Out-Null

# A configure that quietly misses GStreamer still builds something, so fail before the compile.
$cmakeCache = Join-Path $buildDir 'CMakeCache.txt'
$cacheText = if (Test-Path $cmakeCache) { Get-Content $cmakeCache -Raw } else { '' }
if ($cacheText -notmatch '(?m)^GSTREAMER_gstreamer_LIBRARY:FILEPATH=(?!.*NOTFOUND)') {
    throw ("build-opencv-gstreamer-plugin: CMake did not resolve the GStreamer libraries " +
        "(GSTREAMER_gstreamer_LIBRARY is NOTFOUND/absent in $cmakeCache). GSTREAMER_DIR was '$InstallDir'. " +
        "The plugin would configure into a no-op - backlog #93.")
}

$buildLog = Get-PersistentBuildLogPath -Name 'opencv-gstreamer-plugin-build.log' -FallbackDir $buildDir
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog

$pluginDll = Get-ChildItem -Path $buildDir -Recurse -Filter 'opencv_videoio_gstreamer*.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pluginDll) {
    throw "build-opencv-gstreamer-plugin: build produced no opencv_videoio_gstreamer*.dll under $buildDir."
}

# Next to opencv_videoio*.dll is where videoio's plugin loader probes first, for native and cv2 consumers alike.
$dest = Join-Path $videoioDll.DirectoryName $pluginDll.Name
Copy-Item -Path $pluginDll.FullName -Destination $dest -Force
if (-not (Test-Path $dest)) { throw "build-opencv-gstreamer-plugin: install copy to $dest failed." }
Write-Host "Installed GStreamer videoio plugin: $dest ($([math]::Round($pluginDll.Length / 1KB)) KB, OpenCV $OpenCvVersion)"

# Scrub the clone: ~500 MB of source that must not fatten the layer.
Remove-Item -Path $SourceDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'build-opencv-gstreamer-plugin: done.'
exit 0
