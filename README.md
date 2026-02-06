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
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest` | Base Linux toolchain image with Clang/GCC, Rust, Vulkan, GStreamer, Android SDK/NDK. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | linux/amd64, linux/arm64 (as pushed) | `webserver`, `webserver-<git-sha>` | Minimal nginx static webserver image. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 | windows/amd64 | `winamd64` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX. |

Images in this repository:
- 📦 **linux/Dockerfile:** Ubuntu 24.04 toolchain image (Clang/GCC, Rust, Vulkan, GStreamer, Android SDK/NDK).
- 🔥 **linux/torch/Dockerfile:** Torch/Python add-on on top of the base image.
- 🌐 **linux/webserver/Dockerfile:** Minimal nginx static webserver (config at linux/webserver/nginx.conf).
- 🪟 **windows/Dockerfile:** Windows Server Core 2025 build image with MSVC Build Tools, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX.

Linux image chain (built as separate images for caching):

- `linux/Dockerfile.os-deps`: Ubuntu base + stable apt dependencies (no project scripts copied).
- `linux/Dockerfile.toolchain`: GCC/LLVM/Vulkan toolchain setup via scripts.
- `linux/Dockerfile.media`: ONNX Runtime + GStreamer + Libcamera builds.
- `linux/Dockerfile.android`: Android SDK/NDK setup.
- `linux/Dockerfile`: runtime scripts + entrypoint (final image).

Build images sequentially (recommended for cache reuse across images):

```bash
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -f linux/Dockerfile.os-deps -t local/kataglyphis:os-deps \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -f linux/Dockerfile.toolchain --build-arg BASE_IMAGE=local/kataglyphis:os-deps -t local/kataglyphis:toolchain \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -f linux/Dockerfile.media --build-arg BASE_IMAGE=local/kataglyphis:toolchain -t local/kataglyphis:media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -f linux/Dockerfile.android --build-arg BASE_IMAGE=local/kataglyphis:media -t local/kataglyphis:android \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -f linux/Dockerfile --build-arg BASE_IMAGE=local/kataglyphis:android -t local/kataglyphis:latest \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  . 2>&1 | tee -a output.log
```

What you get:
- ✅ Multi-arch builds via buildx/nerdctl.
- 🎮 Vulkan + toolchains ready for GPU passthrough.
- 🧠 Optional Torch layer for Python/ROCm work.
- 📡 Ready-to-serve static web content with nginx.

### Key Features ✨

- 🪟 Windows Server 2025 x64 **Clang 21.8.0** and **MSVC Build Tools 2026**.
- 🐧 Ubuntu 24.04 x64 **Clang 21.8.0**.
- 🐧 Ubuntu 24.04 ARM **Clang 21.8.0**.

<div align="center">

| Category                 | Feature                         | Status |
| ------------------------ | -------------------------------- | :----: |
| Packaging agnostic       | Binary-only deployment           |   ✔️   |
| Packaging agnostic       | Lore ipsum                       |   ✔️   |
| Lore ipsum agnostic      | LORE IPSUM                       |   ✔️   |
| Lore ipsum agnostic      | Advanced unit testing            |   🔶   |
| Lore ipsum agnostic      | Advanced performance testing     |   🔶   |
| Lore ipsum agnostic      | Advanced fuzz testing            |   🔶   |

</div>

**Legend:** ✔️ completed · 🔶 in progress · ❌ not started


### Dependencies 🧩

This enumeration also includes submodules.

### Useful Tools 🛠️

Handy extras that pair well with the images.

## Getting Started 🏁

### Linux 🐧

#### Build

```bash
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
# on Windows you must expose ports one by one
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
```

#### Multi-Arch Build 🌍

##### RICV64 example

```bash
nerdctl build --platform linux/riscv64 --build-arg GSTREAMER_VERSION=1.25.90 --no-cache \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:riscv -f linux/Dockerfile.media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
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
sudo nerdctl login ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest -u Kataglyphis

sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all

sudo nerdctl build \
  --platform=linux/arm64,linux/amd64,linux/riscv64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  -f linux/Dockerfile . 2>&1 | tee -a output.log
```

##### Build & push (docker buildx)

```bash
docker buildx create --name wsl-limited --use --driver docker-container --driver-opt memory=12g --driver-opt cpu-period=100000 --driver-opt cpu-quota=800000
```

```bash
--builder wsl-limited
```

```bash
sudo docker buildx build \
  -f linux/Dockerfile \
  --platform linux/amd64,linux/arm64,linux/riscv64 \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:$(git rev-parse --short HEAD) \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  --build-arg BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --build-arg VCS_REF="$(git rev-parse --short HEAD)" \
  --build-arg BUILD_BY="local" \
  --push \
  . 2>&1 | tee -a output.log
```

##### Reset builder

```bash
docker buildx ls
docker buildx rm mybuilder 2>/dev/null || true
docker buildx create --name mybuilder --driver docker-container --buildkitd-config /tmp/buildkitd.toml --use --
```

##### Sequential build (nerdctl)

```bash
sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:os-deps \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:os-deps,push=true' \
  -f linux/Dockerfile.os-deps \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain,push=true' \
  -f linux/Dockerfile.toolchain \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:os-deps \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media,push=true' \
  -f linux/Dockerfile.media \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android,push=true' \
  -f linux/Dockerfile.android \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  -f linux/Dockerfile \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache \
  .
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
   git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
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
  RUSTC_WRAPPER="" \ 
  ```

  - **Symptom:** no space left on this device 
  **Solution:**
  Don't write to `tmp/` folder! This is stupid.  Write to tmp2 f.e.  

## Contributing 🤝

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are greatly appreciated.

1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a pull request.

## Raspberry Pi Camera

[rpi-cam sources](https://www.raspberrypi.com/documentation/computers/camera_software.html#rpicam-apps)

```bash
# list if camera is available
v4l2-ctl --list-devices
```

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
