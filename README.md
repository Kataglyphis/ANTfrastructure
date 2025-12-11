| # Kataglyphis-ContainerHub 🚀 |
|:--:|

| ![Kataglyphis logo](images/logo.png) |
|:--:|

Docker templates for GPU-friendly Linux dev stacks, a slim nginx webserver, and a Windows build image. 🐳

> ⚠️ **Important:** add the current user to the docker group
> ```bash
> sudo usermod -aG docker $USER
> ```
> You can only push to ghcr.io without sudo when the user is in the docker group.

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)
[![Twitter](https://img.shields.io/twitter/follow/Cataglyphis_?style=social)](https://twitter.com/Cataglyphis_)

## Table of Contents

- [About The Project](#about-the-project)
  - [Key Features](#key-features)
  - [Dependencies](#dependencies)
  - [Useful Tools](#useful-tools)
- [Getting Started](#getting-started)
  - [Linux](#linux)
    - [Build](#build)
    - [Multi-Arch Build](#multi-arch-build)
    - [RICV64](#ricv64)
    - [Setup](#setup)
    - [Torch Add-on](#torch-add-on-linux)
    - [Webserver](#webserver-linux)
  - [Windows](#windows)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
- [Tests](#tests)
- [Roadmap](#roadmap)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)
- [Contact](#contact)
- [Acknowledgements](#acknowledgements)
- [Literature](#literature)

## About The Project 🧭

This project ships ready-to-build Dockerfiles for multiple targets in a single repo.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/pkgs/container/kataglyphis_beschleuniger) — published multi-arch images (Linux base, Torch add-on, webserver) and Windows build image.

Published images and tag hints:

| Image | Platforms | Tag examples | Description |
| --- | --- | --- | --- |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest`, `<git-sha>`, `amd64`, `arm64`, `riscv64` | Base Linux toolchain image with Clang/GCC, Rust, Vulkan, GStreamer, Android SDK/NDK. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | linux/amd64, linux/arm64 (as pushed) | `webserver`, `webserver-<git-sha>` | Minimal nginx static webserver image. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 | windows/amd64 | `winamd64`, `winamd64-<git-sha>` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX. |

Images in this repository:
- 📦 **linux/Dockerfile:** Ubuntu 24.04 toolchain image (Clang/GCC, Rust, Vulkan, GStreamer, Android SDK/NDK for x86_64).
- 🔥 **linux/torch/Dockerfile:** Torch/Python add-on on top of the base image.
- 🌐 **linux/webserver/Dockerfile:** Minimal nginx static webserver (config at linux/webserver/nginx.conf).
- 🪟 **windows/Dockerfile:** Windows Server Core 2025 build image with MSVC Build Tools, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX.

What you get:
- ✅ Multi-arch builds via buildx/nerdctl.
- 🎮 Vulkan + toolchains ready for GPU passthrough.
- 🧠 Optional Torch layer for Python/ROCm work.
- 📡 Ready-to-serve static web content with nginx.

### Key Features ✨

- 🪟 Windows Server 2025 x64 **Clang 21.7.0** and **MSVC Build Tools 2026**.
- 🐧 Ubuntu 24.04 x64 **Clang 21.7.0**.
- 🐧 Ubuntu 24.04 ARM **Clang 21.7.0**.

| Category                 | Feature                         | Status |
| ------------------------ | -------------------------------- | :----: |
| Packaging agnostic       | Binary-only deployment           |   ✔️   |
| Packaging agnostic       | Lore ipsum                       |   ✔️   |
| Lore ipsum agnostic      | LORE IPSUM                       |   ✔️   |
| Lore ipsum agnostic      | Advanced unit testing            |   🔶   |
| Lore ipsum agnostic      | Advanced performance testing     |   🔶   |
| Lore ipsum agnostic      | Advanced fuzz testing            |   🔶   |

**Legend:** ✔️ completed · 🔶 in progress · ❌ not started

### Dependencies 🧩

This enumeration also includes submodules.

### Useful Tools 🛠️

Handy extras that pair well with the images.

## Getting Started 🏁

### Linux 🐧

#### Build

```bash
docker build -t kataglyphis/kataglyphis_beschleuniger_test:latest -f linux/Dockerfile .
# on Windows you must expose ports one by one
docker run -it --rm -p 8443:8443 kataglyphis/kataglyphis_beschleuniger_test:latest
```

#### Multi-Arch Build 🌍

##### RICV64 example

```bash
nerdctl build --platform linux/riscv64 --build-arg GSTREAMER_VERSION=1.25.90 --no-cache -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:riscv -f linux/Dockerfile .
```

##### Setup essentials

Always build with `--platform`:

```bash
docker buildx imagetools create --tag ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest_multiarch ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd64
```

```bash
cat > /tmp/buildkitd.toml <<'TOML'
# limit BuildKit worker parallelism to 2 (set to 1 on very small machines)
[worker.oci]
  max-parallelism = 2
TOML
```

```bash
nerdctl run --rm --privileged tonistiigi/binfmt --install all

sudo nerdctl login ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest -u Kataglyphis

sudo nerdctl build \
  --platform=linux/arm64,linux/amd64,linux/riscv64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  -f linux/Dockerfile .
```

##### Build & push (docker buildx)

```bash
sudo docker buildx build \
  -f linux/Dockerfile \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:$(git rev-parse --short HEAD) \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  --push \
  .
```

##### Reset builder

```bash
docker buildx rm mybuilder 2>/dev/null || true
docker buildx create --name mybuilder --driver docker-container --buildkitd-config /tmp/buildkitd.toml --use --
```

##### Combined build (nerdctl)

```bash
nerdctl run --rm --privileged tonistiigi/binfmt --install all
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest -f linux/Dockerfile .
```

### Torch Add-on (Linux) 🔥

Builds on the base image:

```bash
docker build -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch -f linux/torch/Dockerfile .
```

### Webserver (Linux) 🌐

```bash
docker build -t kataglyphis-webserver:latest -f linux/webserver/Dockerfile .
docker run -d --name kataglyphis-webserver \
  -p 8080:80 \
  -v "$(pwd)/linux/webserver/dist:/var/www/html" \
  -v "$(pwd)/linux/webserver/nginx.conf:/etc/nginx/nginx.conf:ro" \
  kataglyphis-webserver:latest
```

Run with frontend display support:

```bash
nerdctl run --rm -it \
  -e DISPLAY=$DISPLAY \
  -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
  -e XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
  -e PULSE_SERVER=$PULSE_SERVER \
  -v /mnt/wslg:/mnt/wslg \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v $XDG_RUNTIME_DIR:$XDG_RUNTIME_DIR \
  -v "$(pwd)":/workspace \
  --workdir /workspace \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

### Windows 🪟

```powershell
C:\PATH_TO_NERDCTL\nerdctl.exe build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  -f windows/Dockerfile .
```

### Prerequisites ✅

- Docker with buildx/nerdctl support.
- GPU passthrough configured when building Vulkan-enabled images.

### Installation 📥

1. Clone the repo:
   ```bash
   git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-DockerHub.git
   ```

## Tests 🧪

Add test steps here as they become available.

## Roadmap 🗺️

Upcoming :)

## Troubleshooting 🩺

- **Symptom:** caching is weird or files cannot be found.  
  **Solution:**
  ```bash
  # change this line
  RUSTC_WRAPPER= /usr/bin/sccache \ 
  # to 
  RUSTC_WRAPPER= \ 
  ```

## Contributing 🤝

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are greatly appreciated.

1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a pull request.

## License 📄

Add your license details here.

## Contact 📬

Jonas Heinle - [@Cataglyphis_](https://twitter.com/Cataglyphis_) - jonasheinle@googlemail.com

Project Link: [https://github.com/Kataglyphis/...](https://github.com/Kataglyphis/...)

## Acknowledgements 🙏

Thanks for free 3D models:
- [Morgan McGuire, Computer Graphics Archive, July 2017](http://casual-effects.com/data)
- [Viking room](https://sketchfab.com/3d-models/viking-room-a49f1b8e4f5c4ecf9e1fe7d81915ad38)

## Literature 📚

Some very helpful literature, tutorials, etc.

- [Rancher Desktop](https://rancherdesktop.io/)
- [containerd](https://github.com/containerd/containerd)
