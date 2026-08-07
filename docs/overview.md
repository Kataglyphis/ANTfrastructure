# Project Overview

## About The Project

This project ships ready-to-build Dockerfiles for multiple targets in a single repo — plus the reusable tooling consumer projects build on: PowerShell modules (`windows/scripts/modules/`), bash libraries (`linux/scripts/lib/`: agentic-loop, app-runner), cross-platform shared data (`shared/agentic-loop/prompts/`), and CI composite actions (`.github/actions/`, see its README). The AGENTS.md Repo Map is the authoritative index of that half of the repo.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/pkgs/container/kataglyphis_beschleuniger) — published multi-arch images (Linux base, Torch add-on, webserver) and Windows build image.

## Published Images and Tag Hints

| Image | Platforms | Tag examples | Description |
| --- | --- | --- | --- |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest-cross` | Current cross-lane release. Built via digest-pinned stage chain (`base → compiler → sdk → media → android → package → torch → wrapper → manifest`). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest` | Legacy QEMU/binfmt multi-arch image built with `--platform linux/amd64,linux/arm64,linux/riscv64`. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64 | `cross-compiler-amd64`, `cross-sdk-<arch>`, `cross-media-<arch>`, `cross-android-<arch>` | Cross-lane intermediate images (amd64-hosted, cross-compiled for target arches). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | per-arch native | `latest-cross-base-<arch>`, `latest-cross-package-<arch>`, `latest-cross-<arch>` | Runtime lane per-arch images assembled into the `latest-cross` manifest. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | linux/amd64, linux/arm64 (as pushed) | `webserver`, `webserver-<git-sha>` | Minimal nginx static webserver image. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 | windows/amd64 | `winamd64` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX. |

## Images in This Repository

- 🔥 `linux/Dockerfile.torch`: Final Linux wrapper image — Torch/Python layer + runtime scripts + entrypoint.
- 🌐 `linux/webserver/Dockerfile`: Minimal nginx static webserver (config at `linux/webserver/nginx.conf`).
- 🪟 `windows/Dockerfile.base`, `windows/Dockerfile.nvidia` (optional GPU layer), `windows/Dockerfile.toolchain`, `windows/Dockerfile.media-merge-builder` (+ per-branch media builders), `windows/Dockerfile` (driven by `windows/build.ps1`): Windows Server Core 2025 build image with MSVC Build Tools, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX.

## Linux Image Chain

Linux image chain (built as separate images for caching):

- `linux/Dockerfile.base`: Ubuntu base + stable apt dependencies (no project scripts copied).
- `linux/Dockerfile.toolchain`: GCC + LLVM/Clang compiler toolchain.
- `linux/Dockerfile.sdk`: Vulkan SDK layer on top of compiler; also reused for amd64-hosted cross SDK artifact builds with `BUILD_MODE=cross`.
- `linux/Dockerfile.media`: ONNX Runtime + GStreamer + Libcamera builds.
- `linux/Dockerfile.android`: Android SDK/NDK setup.
- `linux/Dockerfile.package`: runtime compatibility layer that rebuilds the developer-facing target image surface from a clean base image in both sequential/native and cross artifact flows.
- `linux/Dockerfile.torch`: Final wrapper — Torch/Python application layer + runtime scripts + entrypoint built on top of the Android or packaged runtime image.

## What You Get

- ✅ Multi-arch builds via buildx/nerdctl.
- 🎮 Vulkan + toolchains ready for GPU passthrough.
- 🧠 Torch/Python runtime included in the final Linux image chain.
- 📡 Ready-to-serve static web content with nginx.

## Key Features

| Category | Feature | Status |
| --- | --- | :---: |
| Cross-build | Multi-arch cross toolchain (amd64, arm64, riscv64) | ✔️ |
| Cross-build | Digest-pinned stage handoff | ✔️ |
| Cross-build | Runtime packaging via QEMU/binfmt | ✔️ |
| GPU acceleration | NVIDIA CUDA <!-- generated:cuda -->13.3<!-- /generated:cuda -->, cuDNN, TensorRT | ✔️ |
| GPU acceleration | DirectML (Windows, vendor-agnostic — ONNX Runtime + GenAI DML EP) | ✔️ |
| GPU acceleration | AMD MIGraphX | ✔️ |
| GPU acceleration | Vulkan SDK <!-- generated:vulkan -->1.4.357.0<!-- /generated:vulkan --> | ✔️ |
| Media | ONNX Runtime <!-- generated:onnx -->1.28.0<!-- /generated:onnx --> | ✔️ |
| Media | GStreamer <!-- generated:gstreamer -->1.29.2<!-- /generated:gstreamer -->, OpenCV <!-- generated:opencv -->5.x<!-- /generated:opencv -->, LiteRT | ✔️ |
| Media | libcamera, FFmpeg | ✔️ |
| Compiler | GCC <!-- generated:gcc -->16.2.0<!-- /generated:gcc -->, LLVM/Clang <!-- generated:llvm -->22.1.8<!-- /generated:llvm --> | ✔️ |
| Language runtime | Python <!-- generated:python -->3.14.6<!-- /generated:python -->, Node.js <!-- generated:node -->26.5.1<!-- /generated:node --> | ✔️ |
| Android | SDK <!-- generated:android_sdk -->14742923<!-- /generated:android_sdk -->, NDK <!-- generated:android_ndk -->29.0.14206865<!-- /generated:android_ndk --> | ✔️ |
| Windows | MSVC Build Tools, CUDA <!-- generated:cuda -->13.3<!-- /generated:cuda -->, GStreamer <!-- generated:gstreamer -->1.29.2<!-- /generated:gstreamer --> | ✔️ |
| Windows | Vulkan SDK <!-- generated:vulkan -->1.4.357.0<!-- /generated:vulkan -->, ONNX Runtime <!-- generated:onnx -->1.28.0<!-- /generated:onnx --> | ✔️ |

**Legend:** ✔️ completed · 🔶 in progress · ❌ not started

See [Third-Party Licenses](third-party-licenses.md) for license information on bundled software.


