# escape=`
# Improved Windows Server Core Dockerfile for Visual Studio Build Tools, Vulkan SDK, Git, Rust, and utilities.
# Notes:
# - Combines steps to reduce layers and cleans up installers to keep image smaller.
# - Uses Start-Process -Wait -PassThru to surface installer exit codes and fail fast on errors.
# - Sets VULKAN_SDK and updates PATH at build time.

# Use the latest Windows Server Core 2025 image.
FROM mcr.microsoft.com/windows/servercore:ltsc2025

# Build-time variable for the Vulkan SDK version (default can be overridden).
ARG VULKAN_VERSION=1.4.328.1
ARG GST_VERSION=1.26.8
ARG ARCH=x86_64
ARG FLAVOR=msvc

ENV VULKAN_VERSION=$VULKAN_VERSION
# Build-time variable for the Vulkan SDK verison (default can be overridden).
ENV TEMP_DIR="C:\\temp"

LABEL maintainer="contact@jonasheinle.de"

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Create temp dir and copy script into image
RUN New-Item -Path $env:TEMP_DIR -ItemType Directory -Force | Out-Null

# Copy the install script into the image
COPY windows\scripts\setup-vs.ps1 C:\temp\setup-vs.ps1

# Run the installer script. Use -ExecutionPolicy Bypass so the script runs during build.
# You may pass parameters directly to the script; below we pass Docker ARGs as script params.
RUN powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\setup-vs.ps1 `
    -TempDir "$env:TEMP_DIR"

# scoop needs GIT :)))
RUN `
    Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/Git-2.52.0-64-bit.exe" -OutFile "Git-64-bit.exe"; `
    Start-Process -FilePath "Git-64-bit.exe" -ArgumentList "/SILENT", "/NORESTART" -Wait; `
    Remove-Item "Git-64-bit.exe" -Force

RUN `
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 ; `
    irm get.scoop.sh -outfile 'install.ps1' ; `
    .\install.ps1 -RunAsAdmin ;  `
    scoop bucket add main; `
    scoop bucket add extras; `
    scoop install main/rustup; `
    scoop install main/rust; `
    scoop install main/vulkan@$env:VULKAN_VERSION; `
    # install llvm & nano
    scoop install llvm nano cmake cppcheck sccache main/ninja extras/nsis main/uv
# -----------------------------------------------------------------------------

# making the WiX packaging tool available for cmake
RUN dotnet tool install --tool-path C:\WiX wix --version 4.0.4

ENV GST_VERSION=$GST_VERSION
ENV ARCH=$ARCH
ENV FLAVOR=$FLAVOR

RUN $ErrorActionPreference='Stop'; `
    $base = ('https://gstreamer.freedesktop.org/data/pkg/windows/{0}/{1}/' -f $env:GST_VERSION, $env:FLAVOR); `
    $msiRuntime = ('gstreamer-1.0-{0}-{1}-{2}.msi' -f $env:FLAVOR, $env:ARCH, $env:GST_VERSION); `
    $msiDevel   = ('gstreamer-1.0-devel-{0}-{1}-{2}.msi' -f $env:FLAVOR, $env:ARCH, $env:GST_VERSION); `
    Invoke-WebRequest ($base + $msiRuntime) -OutFile (Join-Path $env:TEMP $msiRuntime); `
    Start-Process msiexec -ArgumentList @('/i', (Join-Path $env:TEMP $msiRuntime), '/qn', '/norestart') -Wait; `
    Invoke-WebRequest ($base + $msiDevel) -OutFile (Join-Path $env:TEMP $msiDevel); `
    Start-Process msiexec -ArgumentList @('/i', (Join-Path $env:TEMP $msiDevel), '/qn', '/norestart') -Wait; `
    Remove-Item (Join-Path $env:TEMP $msiRuntime), (Join-Path $env:TEMP $msiDevel) -Force

# Correct GStreamer location
ENV GSTREAMER_BIN C:\Program Files\gstreamer\1.0\msvc_x86_64\bin

# Scoop/Git/Vulkan

ENV SCOOP_HOME=C:\Users\ContainerAdministrator\scoop
ENV SCOOP_GLOBAL=C:\ProgramData\scoop
ENV SCOOP_USER_SHIMS C:\Users\ContainerAdministrator\scoop\shims
ENV SCOOP_GLOBAL_SHIMS C:\ProgramData\scoop\shims
ENV GIT_CMD           C:\Program Files\Git\cmd
ENV GIT_BIN           C:\Program Files\Git\bin
ENV GIT_USRBIN        C:\Program Files\Git\usr\bin
ENV VULKAN_SDK        C:\Users\ContainerAdministrator\scoop\apps\vulkan\current
ENV WIX               C:\WiX
ENV LLVM_USER_BIN     C:\Users\ContainerAdministrator\scoop\apps\llvm\current\bin
ENV LLVM_GLOBAL_BIN   C:\ProgramData\scoop\apps\llvm\current\bin

# Windows-Standardpfade (damit powershell/where.exe gefunden werden)

ENV WIN_BASE_PATH C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Windows\System32\OpenSSH

# Einmal sauber setzen (zwei-Argument-Form, $VAR-Expansion)

ENV PATH $LLVM_USER_BIN;$LLVM_GLOBAL_BIN;$WIX;$SCOOP_HOME;$SCOOP_GLOBAL;$GSTREAMER_BIN;$VULKAN_SDK\Bin;$GIT_CMD;$GIT_BIN;$GIT_USRBIN;$SCOOP_GLOBAL_SHIMS;$SCOOP_USER_SHIMS;$WIN_BASE_PATH

RUN where.exe wix.exe
RUN where clang-cl.exe 
RUN where lld-link.exe
RUN C:\WiX\wix.exe extension add --global WixToolset.UI.wixext/4.0.4

# Existenz prüfen und dann Auflösung über PATH testen
RUN $ErrorActionPreference='Stop'; `
    foreach ($c in 'gst-launch-1.0.exe','powershell','git','cmake','rustc','cargo','ninja','uv', 'vulkaninfoSDK', 'glslc') { `
        & where.exe $c | Out-Host; `
    }

# avoids problems with shared ownership when shared volume 
RUN git config --global --add safe.directory '*'

# Define the entry point for the docker container.
ENTRYPOINT ["C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools\\Common7\\Tools\\VsDevCmd.bat","-arch=amd64" , "&&", "powershell.exe", "-NoLogo", "-ExecutionPolicy", "Bypass"]
