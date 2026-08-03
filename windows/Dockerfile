# escape=`
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Final Windows developer image built on top of the torch app image
# (media -> torch -> final; the Orchestr-ANT-ion app env is assembled by
# windows/Dockerfile.torch, this stage adds only the cheap dev trimmings).
# Contains: VS Build Tools, LLVM/clang-cl, CUDA/cuDNN, CPython 3.14,
# ONNX Runtime + GenAI, OpenCV 5, LiteRT, LiteRT-LM, TVM, FFmpeg, GStreamer,
# plus the app env at C:\opt\Kataglyphis-Orchestr-ANT-ion.

ARG BASE_IMAGE=local/kataglyphis:windows-torch
FROM ${BASE_IMAGE}

ARG BUILD_DATE=""
ARG VCS_REF=""

# Runtime DLL resolution: onnxruntime.dll lives in the install's bin\ (the media
# PATH only carried lib\, which holds the provider DLLs) — without this, anything
# linking ORT (e.g. ffmpeg) dies with STATUS_DLL_NOT_FOUND.
ENV PATH=C:\runtime\lib\onnxruntime-source\bin;$PATH

# Rust note: provisioned by setup-rust-toolchain.ps1 via rustup WITH a stable default
# toolchain (DELIBERATELY unpinned -- versions.env's RUST_VERSION pins only the Linux
# lane). rustup is REQUIRED by Flutter's Cargokit (flutter_rust_bridge consumers);
# only a toolchain-LESS rustup is forbidden (its proxy shims shadow cargo/rustc and
# resolve no toolchain). flutter_rust_bridge_codegen is baked alongside. Ships with
# the next base rebuild; images from older (scoop-rust) bases lack rustup entirely.

# One COPY for the flat scripts (healthcheck; the in-container smoke test, see
# docs/windows-builds.md; the entrypoint launcher used by ENTRYPOINT below) — the
# classic builder pays a LAYER per instruction and the chain runs close to
# Docker's 125-layer cap (hit 2026-08-03). Modules dir COPY stays separate
# (different dest). Copied here — the cheapest, last stage — so script edits
# never invalidate the base or media layers.
COPY windows\scripts\healthcheck.ps1 windows\scripts\smoke-test-container.ps1 windows\scripts\entrypoint.cmd C:\temp\scripts\
# Full module set for in-container CI tooling (WindowsBuild/WindowsUv/... are
# imported from this path by downstream Invoke-Ci* / rust build scripts).
COPY windows\scripts\modules C:\temp\scripts\modules

# The Orchestr-ANT-ion app environment (the Windows "torch step") is INHERITED
# from the base: windows/Dockerfile.torch assembles it at APP_REF and sets
# TORCH_APP_DIR. Keeping the assembly out of this stage means an app bump
# rebuilds torch + this cheap tail only, and the logic exists in one place.

WORKDIR C:\workspace
VOLUME ["C:\\workspace"]

# Dev image: a relaxed interval keeps the healthcheck from burning cycles every 30s.
HEALTHCHECK --interval=5m --timeout=15s --start-period=60s --retries=3 `
  CMD pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\scripts\healthcheck.ps1

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
# entrypoint.cmd (copied with the flat scripts above) loads VsDevCmd then runs
# the container command (or interactive pwsh (PowerShell 7) when none is given).
ENTRYPOINT ["cmd","/S","/C","C:\\temp\\scripts\\entrypoint.cmd"]
