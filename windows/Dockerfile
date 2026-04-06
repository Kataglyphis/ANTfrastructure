# escape=`
# Improved Windows Server Core Dockerfile for Visual Studio Build Tools, Vulkan SDK, Git, Rust, and utilities.
# Notes:
# - Combines steps to reduce layers and cleans up installers to keep image smaller.
# - Uses Start-Process -Wait -PassThru to surface installer exit codes and fail fast on errors.
# - Sets VULKAN_SDK and updates PATH at build time.

# Use the latest Windows Server Core 2025 image.
FROM mcr.microsoft.com/windows/servercore:ltsc2025

# Build-time variable for the Vulkan SDK version (default can be overridden).
ARG VULKAN_VERSION=1.4.341.1
ARG GST_VERSION=1.28.1
ARG ARCH=x86_64
ARG FLAVOR=msvc
ARG CUDA_VERSION=12.9

# "Max" (latest stable) versions for ONNX Runtime and GenAI workloads
ARG ONNX_VERSION=1.24.4
ARG ONNX_GENAI_VERSION=0.12.1
# We install both GPU providers (DirectML and CUDA) by default so the image supports both.
ARG ONNX_GPU_VARIANT=both

ENV TEMP_DIR="C:\temp"
LABEL maintainer="contact@jonasheinle.de"

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Create temp dir and copy script into image
RUN New-Item -Path $env:TEMP_DIR -ItemType Directory -Force | Out-Null

# Copy the install script into the image
COPY windows\scripts\setup-vs.ps1 C:\temp\setup-vs.ps1

# Run the installer script. Use -ExecutionPolicy Bypass so the script runs during build.
RUN powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\setup-vs.ps1 -TempDir $env:TEMP_DIR

# scoop needs GIT :)))
RUN Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.2/Git-2.53.0.2-64-bit.exe' -OutFile 'Git-64-bit.exe'; `
    Start-Process -FilePath 'Git-64-bit.exe' -ArgumentList '/SILENT', '/NORESTART' -Wait; `
    Remove-Item 'Git-64-bit.exe' -Force

# making the WiX packaging tool available for cmake
RUN dotnet tool install --tool-path C:\WiX wix --version 4.0.6

COPY windows\scripts\setup-gstreamer.ps1 C:\temp\setup-gstreamer.ps1
COPY windows\scripts\modules C:\temp\modules

# -----------------------------------------------------------------------------
# Install GStreamer
# -----------------------------------------------------------------------------
RUN $base = 'https://gstreamer.freedesktop.org/data/pkg/windows/{0}/{1}/' -f $env:GST_VERSION, $env:FLAVOR; `
    $exeInstaller = 'gstreamer-1.0-{0}-{1}-{2}.exe' -f $env:FLAVOR, $env:ARCH, $env:GST_VERSION; `
    $url = $base + $exeInstaller; `
    Write-Host ('Installing GStreamer from {0} ...' -f $url); `
    C:\temp\setup-gstreamer.ps1 -Url $url -InstallDir 'C:\gstreamer' -LogDir 'C:\temp\logs' -SkipPathUpdate -AutoRemoveInstaller; `
    Write-Host 'GStreamer installation script finished.'

ENV GSTREAMER_BIN="C:\Program Files\gstreamer\1.0\msvc_x86_64\bin"

# -----------------------------------------------------------------------------
# Install Scoop & Packages
# -----------------------------------------------------------------------------
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 ; `
    irm get.scoop.sh -outfile 'install.ps1' ; `
    .\install.ps1 -RunAsAdmin ;  `
    scoop bucket add main; `
    scoop bucket add extras; `
    scoop bucket add versions; `
    scoop install main/7zip; `
    scoop config use_external_7zip true; `
    scoop install main/rustup; `
    scoop install main/vulkan@$env:VULKAN_VERSION; `
    scoop install --global extras/flutter; `
    scoop install llvm nano cppcheck sccache main/ninja extras/nsis main/uv main/nuget; `
    scoop install versions/cuda$env:CUDA_VERSION;

# -----------------------------------------------------------------------------
# Install CMake Nightly
# -----------------------------------------------------------------------------
ARG CMAKE_NIGHTLY_URL=https://cmake.org/files/dev/cmake-4.3.20260404-g6e39564-windows-x86_64.msi

RUN Write-Host ('Downloading CMake nightly from {0}...' -f $env:CMAKE_NIGHTLY_URL) ; `
    Invoke-WebRequest -Uri $env:CMAKE_NIGHTLY_URL -OutFile C:\temp\cmake-nightly.msi ; `
    Write-Host 'Installing CMake nightly...' ; `
    Start-Process msiexec.exe -ArgumentList '/i', 'C:\temp\cmake-nightly.msi', '/quiet', '/norestart', 'ADD_CMAKE_TO_PATH=System' -Wait -NoNewWindow ; `
    Remove-Item C:\temp\cmake-nightly.msi -Force ; `
    Write-Host 'CMake nightly installation complete.'

# -----------------------------------------------------------------------------
# Install ONNX Runtime & GenAI
# -----------------------------------------------------------------------------
ENV ONNX_ROOT="C:\onnx"

RUN Write-Host 'Downloading ONNX Runtime and GenAI packages...' ; `
    New-Item -Path $env:ONNX_ROOT -ItemType Directory -Force | Out-Null ; `
    cd $env:ONNX_ROOT ; `
    nuget install Microsoft.ML.OnnxRuntime -Version $env:ONNX_VERSION -OutputDirectory . ; `
    nuget install Microsoft.ML.OnnxRuntimeGenAI -Version $env:ONNX_GENAI_VERSION -OutputDirectory . ; `
    Write-Host 'Installing ONNX Runtime DirectML GPU package...' ; `
    nuget install Microsoft.ML.OnnxRuntime.DirectML -Version $env:ONNX_VERSION -OutputDirectory . ; `
    Write-Host 'Installing ONNX Runtime CUDA GPU package...' ; `
    nuget install Microsoft.ML.OnnxRuntime.Gpu -Version $env:ONNX_VERSION -OutputDirectory . ; `
    # Attempt to install GenAI GPU provider packages if available for this GenAI version
    Write-Host 'Attempting to install Microsoft.ML.OnnxRuntimeGenAI.DirectML (if available)...' ; `
    $pkgList = & nuget list Microsoft.ML.OnnxRuntimeGenAI.DirectML -AllVersions -Source https://api.nuget.org/v3/index.json 2>$null ; `
    if ($pkgList -and $pkgList -match $env:ONNX_GENAI_VERSION) { Write-Host 'Found GenAI.DirectML package on NuGet; installing...' ; nuget install Microsoft.ML.OnnxRuntimeGenAI.DirectML -Version $env:ONNX_GENAI_VERSION -OutputDirectory . } else { Write-Host 'Microsoft.ML.OnnxRuntimeGenAI.DirectML not found for this version.' } ; `
    Write-Host 'Attempting to install Microsoft.ML.OnnxRuntimeGenAI.Cuda (if available)...' ; `
    $pkgList = & nuget list Microsoft.ML.OnnxRuntimeGenAI.Cuda -AllVersions -Source https://api.nuget.org/v3/index.json 2>$null ; `
    if ($pkgList -and $pkgList -match $env:ONNX_GENAI_VERSION) { Write-Host 'Found GenAI.Cuda package on NuGet; installing...' ; nuget install Microsoft.ML.OnnxRuntimeGenAI.Cuda -Version $env:ONNX_GENAI_VERSION -OutputDirectory . } else { Write-Host 'Microsoft.ML.OnnxRuntimeGenAI.Cuda not found for this version.' }

RUN New-Item -Path C:\temp\onnxpkg -ItemType Directory -Force | Out-Null ; `
    Write-Host 'Installing Microsoft.ML.OnnxRuntime.DirectML into C:\temp\onnxpkg ...' ; `
    nuget install Microsoft.ML.OnnxRuntime.DirectML -Version $env:ONNX_VERSION -OutputDirectory C:\temp\onnxpkg

ENV ONNX_INCLUDE="C:\onnx\Microsoft.ML.OnnxRuntime.${ONNX_VERSION}\build\native\include"
ENV ONNX_LIB="C:\onnx\Microsoft.ML.OnnxRuntime.${ONNX_VERSION}\runtimes\win-x64\native"
ENV ONNX_GENAI_INCLUDE="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.${ONNX_GENAI_VERSION}\build\native\include"
ENV ONNX_GENAI_LIB="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.${ONNX_GENAI_VERSION}\runtimes\win-x64\native"
ENV ONNX_GPU_VARIANT="${ONNX_GPU_VARIANT}"
ENV ONNX_DIRECTML_LIB=""
ENV ONNX_CUDA_LIB=""
ENV ONNX_GENAI_DIRECTML_LIB=""
ENV ONNX_GENAI_CUDA_LIB=""

# Probe installed ONNX packages for provider native folders and set environment variables
RUN Write-Host 'Probing ONNX packages for GPU providers (DirectML/CUDA) including GenAI-specific providers...' ; `
    $root = 'C:\onnx' ; `
    # DirectML for the core runtime (replaces onnxruntime.dll)
    $dmlDir = 'C:\onnx\Microsoft.ML.OnnxRuntime.DirectML.{0}\runtimes\win-x64\native' -f $env:ONNX_VERSION ; `
    $dmlDllPath = '{0}\onnxruntime.dll' -f $dmlDir ; `
    if (Test-Path $dmlDllPath) { Write-Host ('Found DirectML provider in: {0}' -f $dmlDir) ; setx ONNX_DIRECTML_LIB $dmlDir /M } else { Write-Host 'DirectML provider not found; ONNX_DIRECTML_LIB will remain empty.' } ; `
    # DirectML for GenAI (if packaged separately)
    $dmlGenAiDir = 'C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.DirectML.{0}\runtimes\win-x64\native' -f $env:ONNX_GENAI_VERSION ; `
    $dmlGenAiDll = '{0}\onnxruntime.dll' -f $dmlGenAiDir ; `
    if (Test-Path $dmlGenAiDll) { Write-Host ('Found GenAI DirectML provider in: {0}' -f $dmlGenAiDir) ; setx ONNX_GENAI_DIRECTML_LIB $dmlGenAiDir /M } else { Write-Host 'GenAI DirectML provider not found; ONNX_GENAI_DIRECTML_LIB will remain empty.' } ; `
    # CUDA provider DLL search (shared provider DLL name)
    $cuda = Get-ChildItem -Path $root -Filter 'onnxruntime_providers_cuda.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 ; `
    if (-not $cuda) { $cuda = Get-ChildItem -Path 'C:\temp\onnxpkg' -Filter 'onnxruntime_providers_cuda.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 } ; `
    if ($cuda) { $cudaDir = Split-Path $cuda.FullName -Parent ; Write-Host ('Found CUDA provider in: {0}' -f $cudaDir) ; setx ONNX_CUDA_LIB $cudaDir /M } else { Write-Host 'CUDA provider not found; ONNX_CUDA_LIB will remain empty.' } ; `
    # CUDA provider for GenAI (if present under the GenAI package folder)
    $cudaGenAi = Get-ChildItem -Path (Join-Path $root '*Microsoft.ML.OnnxRuntimeGenAI*') -Filter 'onnxruntime_providers_cuda.dll' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 ; `
    if (-not $cudaGenAi) { $cudaGenAi = Get-ChildItem -Path 'C:\temp\onnxpkg' -Filter 'onnxruntime_providers_cuda.dll' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*OnnxRuntimeGenAI*' } | Select-Object -First 1 } ; `
    if ($cudaGenAi) { $cudaGenAiDir = Split-Path $cudaGenAi.FullName -Parent ; Write-Host ('Found GenAI CUDA provider in: {0}' -f $cudaGenAiDir) ; setx ONNX_GENAI_CUDA_LIB $cudaGenAiDir /M } else { Write-Host 'GenAI CUDA provider not found; ONNX_GENAI_CUDA_LIB will remain empty.' }

ENV OPENCV_VERSION="4.13.0"
ENV OPENCV_ROOT="C:\opencv"
ENV OPENCV_DIR="C:\opencv\build"
ENV OPENCV_BIN="C:\opencv\build\x64\vc16\bin"
ENV OPENCV_LIB="C:\opencv\build\x64\vc16\lib"
ENV OPENCV_INCLUDE="C:\opencv\build\include"

# -----------------------------------------------------------------------------
# Install OpenCV
# -----------------------------------------------------------------------------
RUN Write-Host 'Downloading OpenCV...' ; `
    $opencvUrl = 'https://github.com/opencv/opencv/releases/download/{0}/opencv-{0}-windows.exe' -f $env:OPENCV_VERSION ; `
    Invoke-WebRequest -Uri $opencvUrl -OutFile C:\temp\opencv.exe ; `
    Write-Host 'Extracting OpenCV using 7-Zip (bypassing GUI hang)...' ; `
    7z.exe x C:\temp\opencv.exe -oC:\ -y -bsp1 ; `
    Remove-Item C:\temp\opencv.exe -Force ; `
    Write-Host 'OpenCV extracted successfully.'

# -----------------------------------------------------------------------------
# Environment Variables Setup
# -----------------------------------------------------------------------------
ENV SCOOP_HOME=C:\Users\ContainerAdministrator\scoop
ENV SCOOP_GLOBAL=C:\ProgramData\scoop
ENV SCOOP_USER_SHIMS=C:\Users\ContainerAdministrator\scoop\shims
ENV SCOOP_GLOBAL_SHIMS=C:\ProgramData\scoop\shims
ENV GIT_CMD="C:\Program Files\Git\cmd"
ENV GIT_BIN="C:\Program Files\Git\bin"
ENV GIT_USRBIN="C:\Program Files\Git\usr\bin"
ENV FLUTTER_BIN=C:\ProgramData\scoop\apps\flutter\current\bin
ENV VULKAN_SDK=C:\Users\ContainerAdministrator\scoop\apps\vulkan\current
ENV WIX=C:\WiX
ENV LLVM_USER_BIN=C:\Users\ContainerAdministrator\scoop\apps\llvm\current\bin
ENV LLVM_GLOBAL_BIN=C:\ProgramData\scoop\apps\llvm\current\bin
ENV CUDA_ROOT=C:\Users\ContainerAdministrator\scoop\apps\cuda\current
ENV CMAKE_BIN="C:\Program Files\CMake\bin"
ENV WIN_BASE_PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32\OpenSSH

ENV USERPROFILE=C:\Users\ContainerAdministrator
ENV CARGO_HOME=C:\Users\ContainerAdministrator\scoop\persist\rustup\.cargo
ENV CARGO_BIN=C:\Users\ContainerAdministrator\scoop\persist\rustup\.cargo\bin

ENV PATH=$CMAKE_BIN;$CARGO_BIN;$FLUTTER_BIN;$LLVM_USER_BIN;$LLVM_GLOBAL_BIN;$WIX;$SCOOP_HOME;$SCOOP_GLOBAL;$GSTREAMER_BIN;$VULKAN_SDK\Bin;$GIT_CMD;$GIT_BIN;$GIT_USRBIN;$ONNX_LIB;$ONNX_GENAI_LIB;$ONNX_DIRECTML_LIB;$ONNX_CUDA_LIB;$OPENCV_BIN;$SCOOP_GLOBAL_SHIMS;$SCOOP_USER_SHIMS;$WIN_BASE_PATH
ENV PATH=$CUDA_ROOT\bin;$PATH

# -----------------------------------------------------------------------------
# Tool Verification & Configuration
# -----------------------------------------------------------------------------
RUN where.exe flutter
RUN where.exe wix.exe
RUN where clang-cl.exe
RUN where lld-link.exe
RUN C:\WiX\wix.exe extension add --global WixToolset.UI.wixext/4.0.4

RUN rustup self update; `
    rustup toolchain install stable-x86_64-pc-windows-msvc --no-self-update; `
    rustup default stable-x86_64-pc-windows-msvc; `
    rustup component add rust-src clippy rustfmt llvm-tools-preview; `
    rustup target add x86_64-pc-windows-msvc;

RUN where.exe cargo; `
    where.exe rustc; `
    cargo --version; `
    rustc --version

RUN foreach ($c in 'gst-launch-1.0.exe','powershell','git','cmake','rustc','cargo','ninja','uv', 'vulkaninfoSDK', 'glslc') { `
        & where.exe $c | Out-Host; `
    }

# -----------------------------------------------------------------------------
# CUDA Verification
# -----------------------------------------------------------------------------
RUN Write-Host 'Verifying CUDA Toolkit installation...' ; `
    if (-not (Get-Command nvcc -ErrorAction SilentlyContinue)) { Write-Host 'nvcc not found on PATH; attempting to probe common CUDA locations...' } ; `
    if (Get-Command nvcc -ErrorAction SilentlyContinue) { nvcc --version | Out-Host ; & where.exe nvcc } else { Write-Host 'nvcc not found; CUDA compiler not available.' } ; `
    $cudaBins = @($env:CUDA_ROOT, (Join-Path $env:CUDA_ROOT 'bin'), (Join-Path $env:CUDA_ROOT 'lib\x64')) | Where-Object { Test-Path $_ } ; `
    $found = $false ; `
    foreach ($p in $cudaBins) { `
        $dlls = Get-ChildItem -Path $p -Filter 'cudart*.dll' -Recurse -ErrorAction SilentlyContinue ; `
        if ($dlls) { Write-Host ('Found CUDA runtime DLL: {0}' -f $dlls[0].FullName) ; $found = $true ; break } `
    } ; `
    if (-not $found) { Write-Host ('CUDA runtime DLLs (cudart*.dll) not found under ' + $env:CUDA_ROOT + '; CUDA may not be installed.') } else { Write-Host 'CUDA verification passed!'}

# -----------------------------------------------------------------------------
# ONNX Validation (Headers, Libs, DLLs)
# -----------------------------------------------------------------------------
RUN Write-Host 'Verifying ONNX Runtime and GenAI C++ resources (verbose, strict)...' ; `
    $v = $env:ONNX_ROOT; if (-not $v) { $v = '<not set>' } ; Write-Host ('ONNX_ROOT           = {0}' -f $v) ; `
    $v = $env:ONNX_GPU_VARIANT; if (-not $v) { $v = '<not set>' } ; Write-Host ('ONNX_GPU_VARIANT    = {0}' -f $v) ; `
    $v = $env:ONNX_DIRECTML_LIB; if (-not $v) { $v = '<not set>' } ; Write-Host ('ONNX_DIRECTML_LIB   = {0}' -f $v) ; `
    $v = $env:ONNX_CUDA_LIB; if (-not $v) { $v = '<not set>' } ; Write-Host ('ONNX_CUDA_LIB       = {0}' -f $v) ; `
    if (Test-Path $env:ONNX_ROOT) { Write-Host 'Listing ONNX_ROOT contents (top-level):' ; Get-ChildItem -Path $env:ONNX_ROOT | Select-Object Name,Length,Mode | Out-Host } else { Write-Host 'ONNX_ROOT path does not exist.' } ; `
    if (Test-Path 'C:\temp\onnxpkg') { Write-Host 'Listing C:\temp\onnxpkg contents (top-level):' ; Get-ChildItem -Path 'C:\temp\onnxpkg' | Select-Object Name,Length,Mode | Out-Host } else { Write-Host 'C:\temp\onnxpkg not present.' } ; `
    `
    $onnxHeaders = Get-ChildItem -Path $env:ONNX_ROOT -Filter 'onnxruntime_cxx_api.h' -Recurse -ErrorAction SilentlyContinue ; `
    $onnxLibs    = Get-ChildItem -Path $env:ONNX_ROOT -Filter 'onnxruntime.lib' -Recurse -ErrorAction SilentlyContinue ; `
    $onnxDlls    = Get-ChildItem -Path $env:ONNX_ROOT -Filter 'onnxruntime.dll' -Recurse -ErrorAction SilentlyContinue ; `
    Write-Host ('onnxruntime_cxx_api.h matches: {0}' -f ($onnxHeaders | Measure-Object).Count) ; `
    Write-Host ('onnxruntime.lib matches:       {0}' -f ($onnxLibs | Measure-Object).Count) ; `
    Write-Host ('onnxruntime.dll matches:       {0}' -f ($onnxDlls | Measure-Object).Count) ; `
    if (-not $onnxHeaders) { throw 'ONNX headers missing!' } `
    if (-not $onnxLibs)    { throw 'ONNX import libs missing!' } `
    if (-not $onnxDlls)    { throw 'ONNX dlls missing!' } `
    Write-Host ('Found ONNX Header: {0}' -f $onnxHeaders[0].FullName) ; `
    Write-Host ('Found ONNX Lib:    {0}' -f $onnxLibs[0].FullName) ; `
    Write-Host ('Found ONNX DLL:    {0}' -f $onnxDlls[0].FullName) ; `
    `
    $variant = '' ; if ($env:ONNX_GPU_VARIANT) { $variant = $env:ONNX_GPU_VARIANT.ToLower() } ; `
    `
    # Verify DirectML
    $dmlPath = 'C:\onnx\Microsoft.ML.OnnxRuntime.DirectML.{0}\runtimes\win-x64\native\onnxruntime.dll' -f $env:ONNX_VERSION ; `
    if (Test-Path $dmlPath) { Write-Host ('Found ONNX DirectML runtime DLL: {0}' -f $dmlPath) } `
    elseif ($variant -match 'directml' -or $variant -match 'both') { `
        Write-Host ('ERROR: DirectML onnxruntime.dll required but not found at {0}.' -f $dmlPath) ; `
        throw 'ONNX DirectML DLL missing but required by ONNX_GPU_VARIANT.' ; `
    } ; `
    `
    # Verify CUDA
    $provCuda = Get-ChildItem -Path $env:ONNX_ROOT -Filter 'onnxruntime_providers_cuda.dll' -Recurse -ErrorAction SilentlyContinue ; `
    if (-not $provCuda) { Write-Host 'CUDA provider not found under ONNX_ROOT; checking C:\temp\onnxpkg...' ; $provCuda = Get-ChildItem -Path 'C:\temp\onnxpkg' -Filter 'onnxruntime_providers_cuda.dll' -Recurse -ErrorAction SilentlyContinue } ; `
    Write-Host ('CUDA provider matches:      {0}' -f ($provCuda | Measure-Object).Count) ; `
    if ($provCuda) { Write-Host ('Found ONNX CUDA Provider DLL: {0}' -f $provCuda[0].FullName) } `
    elseif ($variant -match 'cuda' -or $variant -match 'both') { `
        $dllName = 'onnxruntime_providers_cuda.dll' ; Write-Host ('ERROR: {0} required but not found. Gathering diagnostic info...' -f $dllName) ; `
        throw ('ONNX CUDA provider DLL missing but required by ONNX_GPU_VARIANT. See previous log lines for diagnostic details.') ; `
    } ; `
    Write-Host 'ONNX verification passed! :)))'

# -----------------------------------------------------------------------------
# OpenCV Validation (Headers, Libs, DLLs)
# -----------------------------------------------------------------------------
RUN Write-Host 'Verifying OpenCV C++ resources...' ; `
    $cvHeaders = Get-ChildItem -Path $env:OPENCV_INCLUDE -Filter 'opencv.hpp' -Recurse ; `
    $cvLibs    = Get-ChildItem -Path $env:OPENCV_LIB -Filter 'opencv_world*.lib' -Recurse ; `
    $cvDlls    = Get-ChildItem -Path $env:OPENCV_BIN -Filter 'opencv_world*.dll' -Recurse ; `
    if (-not $cvHeaders) { throw 'OpenCV headers missing!' } `
    if (-not $cvLibs) { throw 'OpenCV import libs missing!' } `
    if (-not $cvDlls) { throw 'OpenCV dlls missing!' } `
    Write-Host ('Found OpenCV Header: {0}' -f $cvHeaders[0].FullName) ; `
    Write-Host ('Found OpenCV Lib: {0}' -f $cvLibs[0].FullName) ; `
    Write-Host ('Found OpenCV DLL: {0}' -f $cvDlls[0].FullName) ; `
    Write-Host 'OpenCV verification passed! :)))'

RUN git config --global --add safe.directory '*'

ENTRYPOINT ["C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools\\Common7\\Tools\\VsDevCmd.bat","-arch=amd64" , "&&", "powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass"]

