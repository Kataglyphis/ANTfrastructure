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

# Runtime DLL resolution: onnxruntime.dll lives in the install's bin\ (the media
# PATH only carried lib\, which holds the provider DLLs) — without this, anything
# linking ORT (e.g. ffmpeg) dies with STATUS_DLL_NOT_FOUND.
ENV PATH=C:\runtime\lib\onnxruntime-source\bin;$PATH

# OPENCV_BIN/OPENCV_LIB as baked by the media merge point at <root>\bin|lib,
# which OpenCV's per-module install layout never creates — the real dirs are
# x64\vc18\{bin,lib}. Re-point here (cheapest layer; smoke §19 asserts them);
# fix at the source with the next media-merge rebuild.
ENV OPENCV_BIN=C:\runtime\lib\opencv5\x64\vc18\bin `
    OPENCV_LIB=C:\runtime\lib\opencv5\x64\vc18\lib

# Rust note: FIXED in setup-rust-toolchain.ps1 (scoop-provisioned rust, DELIBERATELY
# unpinned -- the Windows lane tracks scoop's latest; versions.env's RUST_VERSION pins
# only the Linux lane. No rustup at all: a toolchain-less rustup used to shadow the
# real cargo/rustc with proxy shims). Ships with the next base rebuild; images from
# older bases may still need `rustup default stable` at runtime.

COPY windows\scripts\healthcheck.ps1 C:\temp\scripts\healthcheck.ps1
# Smoke test is documented to run from inside the container (docs/windows-builds.md)
COPY windows\scripts\smoke-test-container.ps1 C:\temp\scripts\smoke-test-container.ps1
# Full module set for in-container CI tooling (WindowsBuild/WindowsUv/... are
# imported from this path by downstream Invoke-Ci* / rust build scripts).
# Copied here — the cheapest, last stage — so module edits never invalidate
# the base or media layers.
COPY windows\scripts\modules C:\temp\scripts\modules

WORKDIR C:\workspace
VOLUME ["C:\\workspace"]

# Dev image: a relaxed interval keeps the healthcheck from burning cycles every 30s.
HEALTHCHECK --interval=5m --timeout=15s --start-period=60s --retries=3 `
  CMD powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\scripts\healthcheck.ps1

LABEL org.opencontainers.image.title="kataglyphis_beschleuniger" `
      org.opencontainers.image.description="Windows developer image with ONNX Runtime, OpenCV, LiteRT, LiteRT-LM, TVM, GStreamer, FFmpeg" `
      org.opencontainers.image.version="latest" `
      org.opencontainers.image.revision="${VCS_REF}" `
      org.opencontainers.image.created="${BUILD_DATE}" `
      org.opencontainers.image.authors="Jonas Heinle <jonasheinle@googlemail.com>" `
      org.opencontainers.image.url="https://github.com/Kataglyphis/Kataglyphis-ContainerHub" `
      org.opencontainers.image.source="https://github.com/Kataglyphis/Kataglyphis-ContainerHub" `
      org.opencontainers.image.licenses="Apache-2.0"

# Launcher script instead of inline cmd: exec-form re-quoting mangles embedded
# quotes around the spaces-in-path VsDevCmd.bat (literal \" reaches cmd.exe).
# entrypoint.cmd loads VsDevCmd then runs the container command (or interactive
# PowerShell when none is given).
COPY windows\scripts\entrypoint.cmd C:\temp\scripts\entrypoint.cmd
ENTRYPOINT ["cmd","/S","/C","C:\\temp\\scripts\\entrypoint.cmd"]
