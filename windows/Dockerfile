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

# "Max" (latest stable) versions for ONNX Runtime and GenAI CPU workloads
ARG ONNX_VERSION=1.24.3
ARG ONNX_GENAI_VERSION=0.12.1

ENV TEMP_DIR="C:\temp"
LABEL maintainer="contact@jonasheinle.de"

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Create temp dir and copy script into image
RUN New-Item -Path $env:TEMP_DIR -ItemType Directory -Force | Out-Null

# Copy the install script into the image
COPY windows\scripts\setup-vs.ps1 C:\temp\setup-vs.ps1

# Run the installer script. Use -ExecutionPolicy Bypass so the script runs during build.
RUN powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\setup-vs.ps1 `
    -TempDir "$env:TEMP_DIR"

# scoop needs GIT :)))
RUN `
    Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/Git-2.52.0-64-bit.exe" -OutFile "Git-64-bit.exe"; `
    Start-Process -FilePath "Git-64-bit.exe" -ArgumentList "/SILENT", "/NORESTART" -Wait; `
    Remove-Item "Git-64-bit.exe" -Force

# making the WiX packaging tool available for cmake
RUN dotnet tool install --tool-path C:\WiX wix --version 4.0.6

COPY windows\scripts\setup-gstreamer.ps1 C:\temp\setup-gstreamer.ps1
COPY windows\scripts\modules C:\temp\modules

# -----------------------------------------------------------------------------
# Install GStreamer
# -----------------------------------------------------------------------------
RUN `
    $base = 'https://gstreamer.freedesktop.org/data/pkg/windows/{0}/{1}/' -f $env:GST_VERSION, $env:FLAVOR; `
    $exeInstaller = 'gstreamer-1.0-{0}-{1}-{2}.exe' -f $env:FLAVOR, $env:ARCH, $env:GST_VERSION; `
    $url = $base + $exeInstaller; `
    Write-Host "Installing GStreamer from $url ..."; `
    C:\temp\setup-gstreamer.ps1 -Url $url -InstallDir 'C:\gstreamer' -LogDir 'C:\temp\logs' -SkipPathUpdate -AutoRemoveInstaller; `
    Write-Host 'GStreamer installation script finished.'

ENV GSTREAMER_BIN="C:\Program Files\gstreamer\1.0\msvc_x86_64\bin"

# -----------------------------------------------------------------------------
# Install Scoop & Packages (Added nuget for ONNX)
# -----------------------------------------------------------------------------
RUN `
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 ; `
    irm get.scoop.sh -outfile 'install.ps1' ; `
    .\install.ps1 -RunAsAdmin ;  `
    scoop bucket add main; `
    scoop bucket add extras; `
    scoop install main/7zip; `
    scoop config use_external_7zip true; `
    scoop install main/rustup; `
    scoop install main/vulkan@$env:VULKAN_VERSION; `
    scoop install --global extras/flutter; `
    scoop install llvm nano cmake cppcheck sccache main/ninja extras/nsis main/uv main/nuget

# -----------------------------------------------------------------------------
# Install ONNX Runtime & GenAI (CPU Workloads)
# -----------------------------------------------------------------------------
ENV ONNX_ROOT="C:\onnx"

RUN Write-Host "Downloading ONNX Runtime and GenAI packages..." ; `
    New-Item -Path $env:ONNX_ROOT -ItemType Directory -Force | Out-Null ; `
    cd $env:ONNX_ROOT ; `
    nuget install Microsoft.ML.OnnxRuntime -Version $env:ONNX_VERSION -OutputDirectory . ; `
    nuget install Microsoft.ML.OnnxRuntimeGenAI -Version $env:ONNX_GENAI_VERSION -OutputDirectory .

# Define specific INCLUDE and LIB paths so CMake or MSBuild can easily map them
ENV ONNX_INCLUDE="C:\onnx\Microsoft.ML.OnnxRuntime.${ONNX_VERSION}\build\native\include"
ENV ONNX_LIB="C:\onnx\Microsoft.ML.OnnxRuntime.${ONNX_VERSION}\runtimes\win-x64\native"
ENV ONNX_GENAI_INCLUDE="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.${ONNX_GENAI_VERSION}\build\native\include"
ENV ONNX_GENAI_LIB="C:\onnx\Microsoft.ML.OnnxRuntimeGenAI.${ONNX_GENAI_VERSION}\runtimes\win-x64\native"

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
ENV WIN_BASE_PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32\OpenSSH

ENV USERPROFILE=C:\Users\ContainerAdministrator
ENV CARGO_HOME=C:\Users\ContainerAdministrator\scoop\persist\rustup\.cargo
ENV CARGO_BIN=C:\Users\ContainerAdministrator\scoop\persist\rustup\.cargo\bin

# Add ONNX_LIB and ONNX_GENAI_LIB to PATH so the DLLs are found at runtime
ENV PATH=$CARGO_BIN;$FLUTTER_BIN;$LLVM_USER_BIN;$LLVM_GLOBAL_BIN;$WIX;$SCOOP_HOME;$SCOOP_GLOBAL;$GSTREAMER_BIN;$VULKAN_SDK\Bin;$GIT_CMD;$GIT_BIN;$GIT_USRBIN;$ONNX_LIB;$ONNX_GENAI_LIB;$SCOOP_GLOBAL_SHIMS;$SCOOP_USER_SHIMS;$WIN_BASE_PATH

# -----------------------------------------------------------------------------
# Tool Verification & Configuration
# -----------------------------------------------------------------------------
RUN where.exe flutter
RUN where.exe wix.exe
RUN where clang-cl.exe 
RUN where lld-link.exe
RUN C:\WiX\wix.exe extension add --global WixToolset.UI.wixext/4.0.4

RUN $ErrorActionPreference = 'Stop'; `
    rustup self update; `
    rustup toolchain install stable-x86_64-pc-windows-msvc --no-self-update; `
    rustup default stable-x86_64-pc-windows-msvc; `
    rustup component add rust-src clippy rustfmt llvm-tools-preview; `
    rustup target add x86_64-pc-windows-msvc;

RUN where.exe cargo; `
    where.exe rustc; `
    cargo --version; `
    rustc --version

RUN $ErrorActionPreference='Stop'; `
    foreach ($c in 'gst-launch-1.0.exe','powershell','git','cmake','rustc','cargo','ninja','uv', 'vulkaninfoSDK', 'glslc') { `
        & where.exe $c | Out-Host; `
    }

# -----------------------------------------------------------------------------
# ONNX Validation (Headers, Libs, DLLs)
# -----------------------------------------------------------------------------
RUN $ErrorActionPreference='Stop'; `
    Write-Host 'Verifying ONNX Runtime and GenAI C++ resources...' ; `
    $onnxHeaders = Get-ChildItem -Path $env:ONNX_ROOT -Filter 'onnxruntime_cxx_api.h' -Recurse ; `
    $onnxLibs    = Get-ChildItem -Path $env:ONNX_ROOT -Filter 'onnxruntime.lib' -Recurse ; `
    $onnxDlls    = Get-ChildItem -Path $env:ONNX_ROOT -Filter 'onnxruntime.dll' -Recurse ; `
    `
    if (-not $onnxHeaders) { throw 'ONNX headers missing!' } `
    if (-not $onnxLibs) { throw 'ONNX import libs missing!' } `
    if (-not $onnxDlls) { throw 'ONNX dlls missing!' } `
    `
    Write-Host ('Found ONNX Header: {0}' -f $onnxHeaders[0].FullName) ; `
    Write-Host ('Found ONNX Lib: {0}' -f $onnxLibs[0].FullName) ; `
    Write-Host ('Found ONNX DLL: {0}' -f $onnxDlls[0].FullName) ; `
    Write-Host 'ONNX verification passed! :)))'

# avoids problems with shared ownership when shared volume 
RUN git config --global --add safe.directory '*'

ENTRYPOINT ["C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools\\Common7\\Tools\\VsDevCmd.bat","-arch=amd64" , "&&", "powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass"]
