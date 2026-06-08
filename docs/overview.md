# Project Overview

## About The Project

This project ships ready-to-build Dockerfiles for multiple targets in a single repo.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/pkgs/container/kataglyphis_beschleuniger) — published multi-arch images (Linux base, Torch add-on, webserver) and Windows build image.

## Published Images and Tag Hints

| Image | Platforms | Tag examples | Description |
| --- | --- | --- | --- |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest` | Final Linux runtime wrapper image built on top of the staged base/toolchain/sdk/media/android/torch chain. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | linux/amd64, linux/arm64 (as pushed) | `webserver`, `webserver-<git-sha>` | Minimal nginx static webserver image. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 | windows/amd64 | `winamd64` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX. |

## Images in This Repository

- 📦 `linux/Dockerfile.torch`: Final Linux wrapper image with runtime scripts and entrypoint (includes Torch/Python layer).
- 🔥 `linux/Dockerfile.torch`: Torch/Python layer + runtime scripts + entrypoint on top of the staged Android or packaged runtime image.
- 🌐 `linux/webserver/Dockerfile`: Minimal nginx static webserver (config at `linux/webserver/nginx.conf`).
- 🪟 `windows/Dockerfile`: Windows Server Core 2025 build image with MSVC Build Tools, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX.

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

<!-- generated:version-snapshot:start -->
## Source-Controlled Version Snapshot

This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.

| Target | Source-controlled defaults |
| --- | --- |
| Linux base image | Ubuntu 26.04, LLVM/Clang 22.1.6, GCC 16, CMake 4.3.2, Vulkan SDK 1.4.341.1 |
| Android layer | Android SDK 14742923, NDK 29.0.14206865, CMake 4.1.2 |
| Webserver image | Ubuntu 24.04 |
| Windows build image | Windows Server Core LTSC 2025, Visual Studio Build Tools 18, Vulkan SDK 1.4.341.1, GStreamer 1.28.2, CUDA 12.9.0, ONNX Runtime 1.26.0 |
<!-- generated:version-snapshot:end -->

## Key Features

| Category | Feature | Status |
| --- | --- | :---: |
| Packaging agnostic | Binary-only deployment | ✔️ |
| Packaging agnostic | Lore ipsum | ✔️ |
| Lore ipsum agnostic | LORE IPSUM | ✔️ |
| Lore ipsum agnostic | Advanced unit testing | 🔶 |
| Lore ipsum agnostic | Advanced performance testing | 🔶 |
| Lore ipsum agnostic | Advanced fuzz testing | 🔶 |

**Legend:** ✔️ completed · 🔶 in progress · ❌ not started

## Dependencies

This enumeration also includes submodules.

## Useful Tools

Handy extras that pair well with the images.
