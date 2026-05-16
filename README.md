<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.png" alt="logo" width="200" />
  </a>

  <h1>Kataglyphis-ContainerHub 🚀</h1>

  <h4>Docker templates for GPU-friendly Linux dev stacks, a slim nginx webserver, and a Windows build image. 🐳 </h4>
</div>

> ⚠️ **Important:** add the current user to the docker group
> ```bash
> sudo usermod -aG docker $USER
> ```
> You can only push to ghcr.io without sudo when the user is in the docker group.

[![ghcr-cleanup](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml)
[![Build docs](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ubuntu24.04.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ubuntu24.04.yml)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)
[![Twitter](https://img.shields.io/twitter/follow/Cataglyphis_?style=social)](https://twitter.com/Cataglyphis_)

## Documentation Map

This README now keeps the quick project picture and links to the detailed guides. The original content is preserved in smaller documentation units.

| Topic | What it covers |
| --- | --- |
| [Project overview](docs/overview.md) | Published images, repository image chain, feature snapshot, dependencies, useful tools |
| [Linux build basics](docs/linux-build-basics.md) | Local runs, multi-arch builds, buildx, sequential nerdctl builds, fast Ubuntu mirror usage |
| [Linux cross builds](docs/linux-cross-builds.md) | Additive cross-compiler lane, SDK artifacts, runtime artifacts, manifest publishing |
| [Linux accelerator images](docs/linux-accelerator-images.md) | NVIDIA, AMD, and Torch variants plus required build and run flags |
| [Runtime services and streaming](docs/runtime-services.md) | Webserver, display forwarding, Raspberry Pi camera notes, WebRTC signalling and streaming |
| [Windows build image](docs/windows-builds.md) | Windows container build notes, antivirus exclusion warning, memory guidance |
| [Project information](docs/project-info.md) | Prerequisites, installation, tests, roadmap, troubleshooting, contribution, contact |

## About The Project 🧭

This project ships ready-to-build Dockerfiles for multiple targets in a single repo.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/pkgs/container/kataglyphis_beschleuniger) — published multi-arch images (Linux base, Torch add-on, webserver) and Windows build image.

Published images and tag hints:

| Image | Platforms | Tag examples | Description |
| --- | --- | --- | --- |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest` | Base Linux toolchain image with Clang/GCC, Rust, Vulkan, GStreamer, Android SDK/NDK. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | linux/amd64, linux/arm64 (as pushed) | `webserver`, `webserver-<git-sha>` | Minimal nginx static webserver image. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 | windows/amd64 | `winamd64` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX. |

What you get:

- ✅ Multi-arch builds via buildx/nerdctl.
- 🎮 Vulkan + toolchains ready for GPU passthrough.
- 🧠 Optional Torch layer for Python/ROCm work.
- 📡 Ready-to-serve static web content with nginx.

For the full stage breakdown, repository image inventory, feature snapshot, dependencies, and useful tools, see [Project overview](docs/overview.md).

## Quick Start 🏁

### Linux 🐧

```bash
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
# on Windows you must expose ports one by one
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

Detailed Linux build workflows live in [Linux build basics](docs/linux-build-basics.md), [Linux cross builds](docs/linux-cross-builds.md), and [Linux accelerator images](docs/linux-accelerator-images.md).

### Windows 🪟

```powershell
C:\PATH_TO_NERDCTL\nerdctl.exe build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  -f windows/Dockerfile .
```

Windows-specific build notes are in [Windows build image](docs/windows-builds.md).

### Clone The Repository

```bash
git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
```

Runtime topics such as the webserver, display forwarding, Raspberry Pi camera notes, and WebRTC signalling live in [Runtime services and streaming](docs/runtime-services.md).

## Project Information

Prerequisites, installation, tests, roadmap, troubleshooting, contributing, license, contact, acknowledgements, and literature are documented in [Project information](docs/project-info.md).
