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
| [Project Overview](docs/overview.md) | Published images, repository image chain, feature snapshot, dependencies, useful tools |
| [Linux Build Basics](docs/linux-build-basics.md) | Local runs, multi-arch builds, buildx, sequential nerdctl builds, fast Ubuntu mirror usage |
| [Linux Cross Builds](docs/linux-cross-builds.md) | Additive cross-compiler lane, SDK artifacts, runtime artifacts, manifest publishing, single-stage rebuilds |
| [Linux Accelerator Images](docs/linux-accelerator-images.md) | NVIDIA, AMD, and Torch variants plus required build and run flags |
| [Runtime Services and Streaming](docs/runtime-services.md) | Webserver, display forwarding, Raspberry Pi camera notes, WebRTC signalling and streaming |
| [Windows Build Image](docs/windows-builds.md) | Windows container build notes, antivirus exclusion warning, memory guidance |
| [Project Information](docs/project-info.md) | Prerequisites, installation, tests, roadmap, troubleshooting, contributing, contact |

## Project at a Glance 🧭

Kataglyphis-ContainerHub keeps the main container entry points for Linux GPU development, runtime-facing web delivery, and Windows builds in one repository.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/pkgs/container/kataglyphis_beschleuniger)

- Main Linux image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest`
- Webserver image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver`
- Windows build image: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`
- Detailed image inventory, tags, stage breakdown, dependencies, and tooling notes live in [Project Overview](docs/overview.md).

<!-- generated:version-snapshot:start -->
## Source-Controlled Version Snapshot

This block is generated from the Dockerfiles and setup scripts by `python3 docs/scripts/sync_versions.py --write`.

| Target | Source-controlled defaults |
| --- | --- |
| Linux base image | Ubuntu 26.04, LLVM/Clang 22.1.6, GCC 16, CMake 4.3.2, Vulkan SDK 1.4.341.1 |
| Android layer | Android SDK 14742923, NDK 29.0.14206865, CMake 4.1.2 |
| Webserver image | Ubuntu 26.04 |
| Windows build image | Windows Server Core LTSC 2025, Visual Studio Build Tools 18, Vulkan SDK 1.4.341.1, GStreamer 1.28.2, CUDA 12.9.0, ONNX Runtime 1.26.0 |
<!-- generated:version-snapshot:end -->

## Quick Start 🏁

### Linux 🐧

```bash
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

If you run the container from Windows, expose required ports explicitly, for example with `-p 8443:8443`.

Detailed Linux build workflows live in [Linux Build Basics](docs/linux-build-basics.md), [Linux Cross Builds](docs/linux-cross-builds.md), and [Linux Accelerator Images](docs/linux-accelerator-images.md).

### Windows 🪟

```powershell
docker build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t local/kataglyphis:windows-base `
  -f windows/Dockerfile.base .

docker build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t local/kataglyphis:windows-ai `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-base `
  -f windows/Dockerfile.ai .

docker build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-ai `
  -f windows/Dockerfile .
```

Windows-specific build notes are in [Windows Build Image](docs/windows-builds.md).

### Clone The Repository

```bash
git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
```

Runtime topics such as the webserver, display forwarding, Raspberry Pi camera notes, and WebRTC signalling live in [Runtime Services and Streaming](docs/runtime-services.md).

## Project Information

Prerequisites, installation, tests, roadmap, troubleshooting, contributing, license, contact, acknowledgements, and literature are documented in [Project Information](docs/project-info.md).
