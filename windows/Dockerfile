# escape=`
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Final Windows developer image built on top of the torch app image
# (media -> torch -> final; the OrchestrANT app env is assembled by
# windows/Dockerfile.torch, this stage adds only the cheap dev trimmings).
# Contains: VS Build Tools, LLVM/clang-cl, CUDA/cuDNN, CPython 3.14,
# ONNX Runtime + GenAI, OpenCV 5, FFmpeg, GStreamer and LiteRT on both lanes;
# the TVM and IREE RUNTIMES on both lanes with their compilers amd64-only, and
# LiteRT-LM amd64-only (each absence named inside the arm64 bundle by an
# ABSENT-ON-ARM64 marker -- see docs/windows-cross-builds.md), plus the app env
# at C:\opt\OrchestrANT (amd64 only: uv sync must run the
# target interpreter).

ARG BASE_IMAGE=local/kataglyphis:windows-torch
FROM ${BASE_IMAGE}

ARG BUILD_DATE=""
ARG VCS_REF=""

# Compile TARGET architecture of this image's payload. VSDEVCMD_ARCH is what
# entrypoint.cmd feeds to `VsDevCmd.bat -arch=`, so a container started from an
# arm64 bundle image enters an arm64-TARGETING developer environment while the
# host tools stay x64 (-host_arch=amd64 is fixed in entrypoint.cmd).
#
# NB for arm64 this image is still a windows/amd64 image carrying an aarch64
# payload -- there is no arm64 Windows base image. Never publish it with
# --platform windows/arm64: that produces a manifest nothing can run.
ARG WINDOWS_TARGET_ARCH=amd64
ENV WINDOWS_TARGET_ARCH=${WINDOWS_TARGET_ARCH} `
    VSDEVCMD_ARCH=${WINDOWS_TARGET_ARCH}

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
COPY windows\scripts\build\healthcheck.ps1 windows\scripts\build\smoke-test-container.ps1 windows\scripts\entrypoint.cmd C:\temp\scripts\
# Full module set for in-container CI tooling (WindowsBuild/WindowsUv/... are
# imported from this path by downstream Invoke-Ci* / rust build scripts).
COPY windows\scripts\modules C:\temp\scripts\modules

# The OrchestrANT app environment (the Windows "torch step") is INHERITED
# from the base: windows/Dockerfile.torch assembles it at APP_REF and sets
# TORCH_APP_DIR. Keeping the assembly out of this stage means an app bump
# rebuilds torch + this cheap tail only, and the logic exists in one place.

WORKDIR C:\workspace
VOLUME ["C:\\workspace"]

# Dev image: a relaxed interval keeps the healthcheck from burning cycles every 30s.
HEALTHCHECK --interval=5m --timeout=15s --start-period=60s --retries=3 `
  CMD pwsh -NoProfile -ExecutionPolicy Bypass -File C:\temp\scripts\healthcheck.ps1

# Description corrected 2026-08-24: it named LiteRT/LiteRT-LM/TVM
# unconditionally -- empty marker stubs in :winarm64 for as long as the cross
# lane has existed -- and omitted IREE, which the amd64 lane ships. One LABEL
# serves both lanes (no ARG branching), so it must be worded to be true on both.
LABEL org.opencontainers.image.title="kataglyphis_beschleuniger" `
      org.opencontainers.image.description="Windows developer image with ONNX Runtime, OpenCV, GStreamer, FFmpeg, LiteRT and the TVM/IREE runtimes on both lanes; TVM/IREE compilers and LiteRT-LM on amd64 only (named ABSENT inside the arm64 bundle -- see docs/windows-cross-builds.md)" `
      org.opencontainers.image.version="latest" `
      org.opencontainers.image.revision="${VCS_REF}" `
      org.opencontainers.image.created="${BUILD_DATE}" `
      org.opencontainers.image.authors="Jonas Heinle <jonasheinle@googlemail.com>" `
      org.opencontainers.image.url="https://github.com/Kataglyphis/ContainerHub" `
      org.opencontainers.image.source="https://github.com/Kataglyphis/ContainerHub" `
      org.opencontainers.image.licenses="MIT"

# Launcher script instead of inline cmd: exec-form re-quoting mangles embedded
# quotes around the spaces-in-path VsDevCmd.bat (literal \" reaches cmd.exe).
# entrypoint.cmd (copied with the flat scripts above) loads VsDevCmd then runs
# the container command (or interactive pwsh (PowerShell 7) when none is given).
ENTRYPOINT ["cmd","/S","/C","C:\\temp\\scripts\\entrypoint.cmd"]
