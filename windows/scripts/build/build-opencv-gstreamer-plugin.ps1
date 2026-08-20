#requires -Version 7.0
<#
.SYNOPSIS
    Build OpenCV's STANDALONE GStreamer videoio plugin against the already
    installed OpenCV + the merge stage's GStreamer (backlog #93).

.DESCRIPTION
    Breaks the #93 circularity without a second OpenCV pass:

      * OpenCV configures in media-core, BEFORE GStreamer exists, so its
        videoio ships with `GStreamer: NO` compiled in — cv::VideoCapture(...,
        CAP_GSTREAMER) has no backend.
      * GStreamer builds in the MERGE stage and needs OpenCV for its own
        gst-plugins-bad opencv elements (the other direction, which works).

    OpenCV 5.0.0 ships modules/videoio/misc/plugin_gstreamer — a self-contained
    CMake project that builds `opencv_videoio_gstreamer` as a RUNTIME-LOADED
    DLL against an INSTALLED OpenCV, out of tree, from one source file
    (cap_gstreamer.cpp). videoio's plugin loader (VIDEOIO_ENABLE_PLUGINS is ON
    by default) picks it up from the directory of opencv_videoio*.dll.

    CONSEQUENCE FOR VERIFICATION, do not "fix" this back: with the plugin
    route, `cv2.getBuildInformation()` KEEPS saying `GStreamer: NO` — that
    string reflects videoio's COMPILE-TIME configuration and this plugin is
    loaded at runtime. The authoritative runtime check is
    `cv2.videoio_registry.hasBackend(cv2.CAP_GSTREAMER)` (it attempts the
    plugin load). The #95 smoke assertions were updated accordingly.

    GStreamer detection on WIN32 uses find_path/find_library against
    GSTREAMER_DIR — OpenCV's detect_gstreamer.cmake does NOT use pkg-config on
    Windows, so the merge prefix (C:\runtime: include\gstreamer-1.0,
    include\glib-2.0, lib\*.lib) is handed over directly. No pkgconfig shim
    needed here, unlike the #94 FFmpeg route.

.PARAMETER InstallDir
    Runtime prefix (default C:\runtime) — must already contain lib\opencv5 and
    the GStreamer install.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = '',
    [string]$SourceDir = 'C:\temp\opencv-plugin-src',
    [string]$OpenCvVersion = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
Import-Module $modulePath -Force
$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

if (-not $OpenCvVersion) { $OpenCvVersion = $env:OPENCV_SOURCE_VERSION }
if (-not $OpenCvVersion) { $OpenCvVersion = $env:OPENCV_VERSION }
if (-not $OpenCvVersion) {
    throw 'build-opencv-gstreamer-plugin: no OpenCV version (OPENCV_SOURCE_VERSION/OPENCV_VERSION unset) - refusing to build an unpinned plugin.'
}

# --- preconditions, checked BEFORE the clone so a broken image fails in seconds
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

# --- OpenCV source at the SAME pin the installed OpenCV was built from --------
New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null
$mainSrc = Join-Path $SourceDir 'opencv'
Invoke-GitClone -RepoUrl 'https://github.com/opencv/opencv.git' -Branch $OpenCvVersion -SourceDir $mainSrc | Out-Null

$pluginSrc = Join-Path $mainSrc 'modules\videoio\misc\plugin_gstreamer'
if (-not (Test-Path (Join-Path $pluginSrc 'CMakeLists.txt'))) {
    throw "build-opencv-gstreamer-plugin: $pluginSrc missing in the $OpenCvVersion tag - upstream moved the standalone plugin project; re-check backlog #93."
}

# find_package(OpenCV) needs the installed cmake config; its location varies
# with generator/platform, so search rather than hard-code.
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
Invoke-CmakeConfigure -SourceDir $pluginSrc -BuildDir $buildDir -InstallPrefix $ocvInstallDir -ExtraArgs $cmakeExtra | Out-Null

# GATE (the #94 lesson, applied on day one here): a configure that quietly
# misses GStreamer still builds SOMETHING - fail before the compile, loudly.
# The plugin's own CMakeLists prints `Using GStreamer: <version>` on success.
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

# Install NEXT TO opencv_videoio*.dll: that directory is the first place
# videoio's plugin loader probes, for both the native DLL consumers and the
# cv2 python module (which links the per-module DLLs from the same bin dir).
$dest = Join-Path $videoioDll.DirectoryName $pluginDll.Name
Copy-Item -Path $pluginDll.FullName -Destination $dest -Force
if (-not (Test-Path $dest)) { throw "build-opencv-gstreamer-plugin: install copy to $dest failed." }
Write-Host "Installed GStreamer videoio plugin: $dest ($([math]::Round($pluginDll.Length / 1KB)) KB, OpenCV $OpenCvVersion)"

# Scrub the clone: ~500 MB of source that must not fatten the layer.
Remove-Item -Path $SourceDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'build-opencv-gstreamer-plugin: done.'
exit 0
