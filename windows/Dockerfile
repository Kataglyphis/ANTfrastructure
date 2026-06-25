# escape=`
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Final Windows developer image built on top of the cached media image.
# Contains: VS Build Tools, LLVM/clang-cl, CUDA/cuDNN, CPython 3.14,
# ONNX Runtime + GenAI, OpenCV 5, LiteRT, LiteRT-LM, TVM, FFmpeg, GStreamer.

ARG BASE_IMAGE=local/kataglyphis:windows-media
FROM ${BASE_IMAGE}

ARG BUILD_DATE=""
ARG VCS_REF=""

COPY windows\scripts\healthcheck.ps1 C:\temp\scripts\healthcheck.ps1

WORKDIR C:\workspace
VOLUME ["C:\\workspace"]

HEALTHCHECK --interval=30s --timeout=15s --start-period=60s --retries=3 `
  CMD powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\scripts\healthcheck.ps1

LABEL org.opencontainers.image.title="kataglyphis_beschleuniger" `
      org.opencontainers.image.description="Windows developer image with ONNX Runtime, OpenCV, LiteRT, LiteRT-LM, TVM, GStreamer, FFmpeg" `
      org.opencontainers.image.version="latest" `
      org.opencontainers.image.revision="${VCS_REF}" `
      org.opencontainers.image.created="${BUILD_DATE}" `
      org.opencontainers.image.authors="Jonas Heinle <jonasheinle@googlemail.com>" `
      org.opencontainers.image.url="https://github.com/Kataglyphis/Kataglyphis-DockerHub" `
      org.opencontainers.image.source="https://github.com/Kataglyphis/Kataglyphis-DockerHub" `
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools\\Common7\\Tools\\VsDevCmd.bat","-arch=amd64","&&","powershell.exe","-NoLogo","-ExecutionPolicy","Bypass"]
