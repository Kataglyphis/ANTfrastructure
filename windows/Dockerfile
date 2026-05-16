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
ARG GST_VERSION=1.28.2
ARG ARCH=x86_64
ARG FLAVOR=msvc
ARG CUDA_VERSION=12.9.0
ARG CUDA_VERSION_MAJOR_MINOR=12.9
ARG CUDNN_VERSION=9.10.1.4
ARG TENSORRT_VERSION=10.12.0.2

# "Max" (latest stable) versions for ONNX Runtime and GenAI workloads
ARG ONNX_VERSION=1.26.0
ARG ONNX_GENAI_VERSION=0.13.2
# Some ONNX provider packages (DirectML) may lag the core runtime on NuGet.
# Provide a separate build arg so we can pin the DirectML provider to a compatible
# version (defaults to 1.24.4 to avoid missing-package errors for 1.25.0).
ARG ONNX_DIRECTML_VERSION=1.24.4
ARG CMAKE_NIGHTLY_URL=https://cmake.org/files/dev/cmake-4.3.20260425-gedeedd9-windows-x86_64.msi
# We install both GPU providers (DirectML and CUDA) by default so the image supports both.
ARG ONNX_GPU_VARIANT=both

ENV TEMP_DIR="C:\temp"
LABEL maintainer="contact@jonasheinle.de"

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Create temp dir and copy script into image
RUN New-Item -Path $env:TEMP_DIR -ItemType Directory -Force | Out-Null

# Copy Windows helper scripts into the image
COPY windows\scripts C:\temp\scripts

# Run the installer script. Use -ExecutionPolicy Bypass so the script runs during build.
RUN & 'C:\temp\scripts\setup-vs.ps1' -TempDir $env:TEMP_DIR

# -----------------------------------------------------------------------------
# Install GStreamer
# -----------------------------------------------------------------------------
RUN & 'C:\temp\scripts\setup-bootstrap-tools.ps1' -TempDir $env:TEMP_DIR
RUN & 'C:\temp\scripts\setup-gstreamer.ps1' -Version $env:GST_VERSION -Arch $env:ARCH -Flavor $env:FLAVOR -InstallDir 'C:\gstreamer' -LogDir 'C:\temp\logs' -SkipPathUpdate -AutoRemoveInstaller
RUN & 'C:\temp\scripts\setup-scoop-tools.ps1' -TempDir $env:TEMP_DIR -CMakeNightlyUrl $env:CMAKE_NIGHTLY_URL -VulkanVersion $env:VULKAN_VERSION

ENV GSTREAMER_BIN="C:\Program Files\gstreamer\1.0\msvc_x86_64\bin"

# -----------------------------------------------------------------------------
# Install NVIDIA CUDA Toolkit (Official Silent Install)
# -----------------------------------------------------------------------------
ENV CUDA_ROOT="C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v${CUDA_VERSION_MAJOR_MINOR}"
ENV CUDNN_ROOT="C:\Program Files\NVIDIA\CUDNN\v${CUDNN_VERSION}"

RUN & 'C:\temp\scripts\setup-cuda.ps1' -TempDir $env:TEMP_DIR -CudaVersion $env:CUDA_VERSION -CudaVersionMajorMinor $env:CUDA_VERSION_MAJOR_MINOR -CudnnVersion $env:CUDNN_VERSION -CudnnRoot $env:CUDNN_ROOT

# -----------------------------------------------------------------------------
# Install NVIDIA TensorRT (SKIPPED - requires NVIDIA Developer login for ZIP download)
# -----------------------------------------------------------------------------
# To install TensorRT manually:
# 1. Download ZIP from https://developer.nvidia.com/tensorrt (requires login)
# 2. Extract to C:\TensorRT
# 3. Add C:\TensorRT\lib to PATH
# ENV TENSORRT_ROOT="C:\TensorRT"

# -----------------------------------------------------------------------------
# Install ONNX Runtime & GenAI
# -----------------------------------------------------------------------------
ENV ONNX_ROOT="C:\onnx"
ENV ONNX_GPU_VARIANT="${ONNX_GPU_VARIANT}"
ENV ONNX_INCLUDE="C:\onnx\Microsoft.ML.OnnxRuntime.${ONNX_VERSION}\build\native\include"
ENV ONNX_LIB="C:\onnx\Microsoft.ML.OnnxRuntime.${ONNX_VERSION}\runtimes\win-x64\native"
ENV ONNX_GENAI_INCLUDE="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.${ONNX_GENAI_VERSION}\build\native\include"
ENV ONNX_GENAI_LIB="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.${ONNX_GENAI_VERSION}\runtimes\win-x64\native"
ENV ONNX_DIRECTML_LIB="C:\onnx\Microsoft.ML.OnnxRuntime.DirectML.${ONNX_DIRECTML_VERSION}\runtimes\win-x64\native"
ENV ONNX_CUDA_LIB="C:\onnx\Microsoft.ML.OnnxRuntime.Gpu.Windows.${ONNX_VERSION}\runtimes\win-x64\native"
ENV ONNX_GENAI_DIRECTML_LIB="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.DirectML.${ONNX_GENAI_VERSION}\runtimes\win-x64\native"
ENV ONNX_GENAI_CUDA_LIB="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.Cuda.${ONNX_GENAI_VERSION}\runtimes\win-x64\native"
RUN & 'C:\temp\scripts\setup-onnx.ps1' -TempDir $env:TEMP_DIR -OnnxRoot $env:ONNX_ROOT -OnnxVersion $env:ONNX_VERSION -OnnxGenAiVersion $env:ONNX_GENAI_VERSION -OnnxDirectMlVersion $env:ONNX_DIRECTML_VERSION

ENV OPENCV_VERSION="4.13.0"
ENV OPENCV_ROOT="C:\opencv"
ENV OPENCV_DIR="C:\opencv\build"
ENV OPENCV_BIN="C:\opencv\build\x64\vc16\bin"
ENV OPENCV_LIB="C:\opencv\build\x64\vc16\lib"
ENV OPENCV_INCLUDE="C:\opencv\build\include"

# -----------------------------------------------------------------------------
# Install OpenCV
# -----------------------------------------------------------------------------
RUN & 'C:\temp\scripts\setup-opencv.ps1' -TempDir $env:TEMP_DIR -OpenCvVersion $env:OPENCV_VERSION

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
ENV CMAKE_BIN="C:\Program Files\CMake\bin"
ENV WIN_BASE_PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32\OpenSSH

ENV USERPROFILE=C:\Users\ContainerAdministrator
ENV CARGO_HOME=C:\Users\ContainerAdministrator\scoop\persist\rustup\.cargo
ENV CARGO_BIN=C:\Users\ContainerAdministrator\scoop\persist\rustup\.cargo\bin

ENV PATH=$CMAKE_BIN;$CARGO_BIN;$FLUTTER_BIN;$LLVM_USER_BIN;$LLVM_GLOBAL_BIN;$WIX;$SCOOP_HOME;$SCOOP_GLOBAL;$GSTREAMER_BIN;$VULKAN_SDK\Bin;$GIT_CMD;$GIT_BIN;$GIT_USRBIN;$ONNX_LIB;$ONNX_GENAI_LIB;$ONNX_DIRECTML_LIB;$ONNX_CUDA_LIB;$OPENCV_BIN;$SCOOP_GLOBAL_SHIMS;$SCOOP_USER_SHIMS;$WIN_BASE_PATH
ENV PATH=$CUDA_ROOT\bin;$CUDNN_ROOT\bin;$TENSORRT_ROOT\lib;$PATH

# -----------------------------------------------------------------------------
# Tool Verification & Configuration
# -----------------------------------------------------------------------------
RUN & 'C:\temp\scripts\verify-toolchain.ps1'
RUN & 'C:\temp\scripts\setup-rust-toolchain.ps1'

# -----------------------------------------------------------------------------
# CUDA, cuDNN, and TensorRT Verification
# -----------------------------------------------------------------------------
RUN & 'C:\temp\scripts\verify-ai-stack.ps1'

# Enable Win32 long paths (>260 chars) at OS level 
RUN Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' ` 
 -Name 'LongPathsEnabled' -Value 1 -Type DWord 

# avoids problems with shared ownership when shared volume 
RUN git config --global --add safe.directory '*'; ` 
 git config --global core.longpaths true

ENTRYPOINT ["C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools\\Common7\\Tools\\VsDevCmd.bat","-arch=amd64" , "&&", "powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass"]

