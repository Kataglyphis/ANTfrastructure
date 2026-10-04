# escape=`
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Final dev image: only cheap trimmings on top of the torch stage (media -> torch -> final).

ARG BASE_IMAGE=local/kataglyphis:windows-torch
FROM ${BASE_IMAGE}

ARG BUILD_DATE=""
ARG VCS_REF=""

# Payload arch for VsDevCmd -arch; the image itself stays windows/amd64 (see docs/windows-cross-builds.md).
ARG WINDOWS_TARGET_ARCH=amd64
ENV WINDOWS_TARGET_ARCH=${WINDOWS_TARGET_ARCH} `
    VSDEVCMD_ARCH=${WINDOWS_TARGET_ARCH}

# onnxruntime.dll lives in bin\, not lib\; without it ORT consumers die with STATUS_DLL_NOT_FOUND.
ENV PATH=C:\runtime\lib\onnxruntime-source\bin;$PATH

# The ort crate links the chain ORT, never pyke's download; see docs/consumer-image-contract.md § The ort crate links the chain ONNX Runtime.
ENV ORT_LIB_LOCATION=$ONNX_ROOT\lib `
    ORT_PREFER_DYNAMIC_LINK=1 `
    ORT_SKIP_DOWNLOAD=1 `
    ORT_DYLIB_PATH=$ONNX_ROOT\bin\onnxruntime.dll

# Server Core has no Vulkan loader; rocm already installed one and the zip is x64 only, so both skip.
ARG VULKAN_VERSION=1.4.357.0
ARG VULKAN_RT_WINDOWS_ZIP_SHA256=a14672efed15aafc7f5a16572d35cd3a3416eadf670aeee3cdf50ee32d5fbf83
COPY windows\scripts\host\Install-VulkanLoader.ps1 C:\temp\scripts\
RUN --mount=type=bind,source=windows/scripts/modules/WindowsContainerImage.Common.psm1,target=C:\temp\scripts\modules\WindowsContainerImage.Common.psm1 `
    if ($env:WINDOWS_TARGET_ARCH -eq 'amd64' -and -not $env:VULKAN_LOADER_DIR) { & 'C:\temp\scripts\Install-VulkanLoader.ps1' -TempDir $env:TEMP_DIR -InstallDir 'C:\vulkan-loader' -SystemDir '' }
# lavapipe's loader and vulkaninfo live beside its ICD; the ICD itself is registered in HKLM at install time.
ENV PATH=$PATH;C:\vulkan-loader;C:\runtime\lavapipe

# One COPY (the chain runs near the 125-layer cap), in the last stage so script edits never invalidate earlier layers.
COPY windows\scripts\build\Test-Health.ps1 windows\scripts\build\Test-Container.ps1 windows\scripts\entrypoint.cmd linux\scripts\03-media\runtime\ort-venv-census.py C:\temp\scripts\
# Downstream Invoke-Ci* and rust build scripts import the modules from this path.
COPY windows\scripts\modules C:\temp\scripts\modules

# No WORKDIR/VOLUME: binding over an image-held dir fails at hcs::CreateComputeSystem across OS builds.

# Dev image: a relaxed interval keeps the healthcheck from burning cycles every 30s.
HEALTHCHECK --interval=5m --timeout=15s --start-period=60s --retries=3 `
  CMD pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\scripts\Test-Health.ps1

# One LABEL serves both lanes, so the description must be true on arm64 too.
LABEL org.opencontainers.image.title="kataglyphis_beschleuniger" `
      org.opencontainers.image.description="Windows developer image with ONNX Runtime, OpenCV, GStreamer, FFmpeg, LiteRT and the TVM/IREE runtimes on both lanes; TVM/IREE compilers and LiteRT-LM on amd64 only (named ABSENT inside the arm64 bundle -- see docs/windows-cross-builds.md)" `
      org.opencontainers.image.version="latest" `
      org.opencontainers.image.revision="${VCS_REF}" `
      org.opencontainers.image.created="${BUILD_DATE}" `
      org.opencontainers.image.authors="Jonas Heinle <jonasheinle@googlemail.com>" `
      org.opencontainers.image.url="https://github.com/Kataglyphis/ANTfrastructure" `
      org.opencontainers.image.source="https://github.com/Kataglyphis/ANTfrastructure" `
      org.opencontainers.image.licenses="MIT"

# A launcher script, because exec-form re-quoting mangles the quotes around the spaced VsDevCmd.bat path.
ENTRYPOINT ["cmd","/S","/C","C:\\temp\\scripts\\entrypoint.cmd"]
