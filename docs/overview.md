# Project Overview

## About The Project

This project ships ready-to-build Dockerfiles for multiple targets in a single repo.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/pkgs/container/kataglyphis_beschleuniger) — published multi-arch images (Linux base, Torch add-on, webserver) and Windows build image.

## Published Images and Tag Hints

| Image | Platforms | Tag examples | Description |
| --- | --- | --- | --- |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest` | Base Linux toolchain image with Clang/GCC, Rust, Vulkan, GStreamer, Android SDK/NDK. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | linux/amd64, linux/arm64 (as pushed) | `webserver`, `webserver-<git-sha>` | Minimal nginx static webserver image. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 | windows/amd64 | `winamd64` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX. |

## Images in This Repository

- 📦 `linux/Dockerfile`: Ubuntu 26.04 toolchain image (Clang/GCC, Rust, Vulkan, GStreamer, Android SDK/NDK).
- 🔥 `linux/torch/Dockerfile`: Torch/Python add-on on top of the base image.
- 🌐 `linux/webserver/Dockerfile`: Minimal nginx static webserver (config at `linux/webserver/nginx.conf`).
- 🪟 `windows/Dockerfile`: Windows Server Core 2025 build image with MSVC Build Tools, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX.

## Linux Image Chain

Linux image chain (built as separate images for caching):

- `linux/Dockerfile.base`: Ubuntu base + stable apt dependencies (no project scripts copied).
- `linux/Dockerfile.toolchain`: GCC + LLVM/Clang compiler toolchain.
- `linux/Dockerfile.sdk`: Vulkan SDK layer on top of compiler; also reused for amd64-hosted cross SDK artifact builds with `BUILD_MODE=cross`.
- `linux/Dockerfile.media`: ONNX Runtime + GStreamer + Libcamera builds.
- `linux/Dockerfile.android`: Android SDK/NDK setup.
- `linux/Dockerfile`: runtime scripts + entrypoint (final image).

## What You Get

- ✅ Multi-arch builds via buildx/nerdctl.
- 🎮 Vulkan + toolchains ready for GPU passthrough.
- 🧠 Optional Torch layer for Python/ROCm work.
- 📡 Ready-to-serve static web content with nginx.

## Key Features

- 🪟 Windows Server 2025 x64 **Clang 21.8.0** and **MSVC Build Tools 2026**.
- 🐧 Ubuntu 26.04 x64 **Clang 21.8.0**.
- 🐧 Ubuntu 26.04 ARM **Clang 21.8.0**.

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