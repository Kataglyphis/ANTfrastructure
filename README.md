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
    - [NVIDIA GPU Build](#nvidia-gpu-build-linux)
    - [AMD GPU Build](#amd-gpu-build-linux)
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
- `linux/Dockerfile.compiler`: GCC + LLVM/Clang compiler toolchain.
- `linux/Dockerfile.sdk`: Vulkan SDK layer on top of compiler.
- `linux/Dockerfile.media`: ONNX Runtime + GStreamer + Libcamera builds.
- `linux/Dockerfile.android`: Android SDK/NDK setup.
- `linux/Dockerfile`: runtime scripts + entrypoint (final image).

Optional NVIDIA GPU image chain (built by passing `--build-arg ENABLE_NVIDIA=true` to standard Dockerfiles):

- `linux/Dockerfile.nvidia`: CUDA 13.1, cuDNN 9, TensorRT 10, NCCL, cuBLAS/cuSPARSE/cuFFT, NVTX. (Inserts after `:sdk`)
- `linux/Dockerfile.media`: Builds media stack with NVIDIA codec headers + ORT CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true`.
- `linux/Dockerfile.android`: Android SDK/NDK on top of the NVIDIA media layer.
- `linux/Dockerfile.torch`: Torch/Python add-on on top of the Android NVIDIA layer.
- `linux/Dockerfile`: Final entrypoint image (`:nvidia` tag).

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
nerdctl build --platform linux/riscv64 --build-arg GSTREAMER_VERSION=1.28.1 --no-cache \
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
  --platform=linux/arm64,linux/amd64,linux/arm64,linux/riscv64 \
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
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-os-deps,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-os-deps \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler,push=true' \
  -f linux/Dockerfile.compiler \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:os-deps \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-compiler,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-compiler \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk,push=true' \
  -f linux/Dockerfile.sdk \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:compiler \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-sdk,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-sdk \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media,push=true' \
  -f linux/Dockerfile.media \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android,push=true' \
  -f linux/Dockerfile.android \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch \
  . 2>&1 | tee -a output.log
sudo nerdctl build --platform linux/amd64,linux/arm64,linux/riscv64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true' \
  -f linux/Dockerfile \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-latest,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-latest \
  . 2>&1 | tee -a output.log
```

### NVIDIA GPU Build (Linux)

> **Requirements:**
> - Host driver >= 590.44 (for CUDA 13.1).
> - `nvidia-container-toolkit` installed and configured on the host.
> - `--runtime=nvidia` or `--gpus all` passed to `docker run`.

The NVIDIA variant inserts a new `Dockerfile.nvidia` layer **after** `:sdk` and before the media stage. Subsequent stages reuse the standard Dockerfiles by passing `--build-arg ENABLE_NVIDIA=true`.

**Files involved:**
| File | Purpose |
|---|---|
| `linux/Dockerfile.nvidia` | Installs CUDA 13.1, cuDNN 9, TensorRT 10, NCCL, cuBLAS, cuSPARSE, cuFFT, NVTX |
| `linux/Dockerfile.media` | Media stack: conditionally builds ORT with CUDA/TRT/cuDNN EPs when `ENABLE_NVIDIA=true` |
| `linux/Dockerfile.android` | Conditionally builds on top of the NVIDIA media image |
| `linux/Dockerfile` | Conditionally tags the final entrypoint image |
| `linux/scripts/03-media/onnxruntime/build/30-build-native-nvidia.sh` | ORT build script with CUDA, TensorRT, cuDNN EPs |

**Sequential build (nerdctl):**

```bash
# Step 1: NVIDIA layer (builds on top of existing :sdk from standard chain)
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia,push=true' \
  -f linux/Dockerfile.nvidia \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia \
  . 2>&1 | tee -a output.log

# Step 2: media-nvidia (GStreamer nvcodec + ORT with CUDA/TRT/cuDNN EPs)
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-nvidia,push=true' \
  -f linux/Dockerfile.media \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-nvidia \
  . 2>&1 | tee -a output.log

# Step 3: android-nvidia
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-nvidia,push=true' \
  -f linux/Dockerfile.android \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-nvidia \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-nvidia \
  . 2>&1 | tee -a output.log

# Step 4: torch-nvidia
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-nvidia,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-nvidia \
  --build-arg ONNX_PACKAGE="onnxruntime-gpu" \
  --build-arg PYTORCH_EXTRA="pytorch-cu130" \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-nvidia \
  . 2>&1 | tee -a output.log

# Step 5: final nvidia image
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia,push=true' \
  -f linux/Dockerfile \
  --build-arg ENABLE_NVIDIA=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-nvidia \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-nvidia \
  . 2>&1 | tee -a output.log
```

**Run with GPU access:**

```bash
sudo nerdctl run --rm -it --gpus all ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia

# or with nvidia runtime explicitly
sudo nerdctl run --rm -it --runtime=nvidia ghcr.io/kataglyphis/kataglyphis_beschleuniger:nvidia
```

**Version overrides** (all have sensible defaults):

```bash
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-nvidia,push=true' \
  -f linux/Dockerfile.nvidia \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --build-arg CUDA_VERSION=13.1.1 \
  --build-arg CUDA_VERSION_MAJOR_MINOR=13-1 \
  --build-arg CUDNN_VERSION=9 \
  --build-arg TENSORRT_VERSION=10 \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-nvidia \
  . 2>&1 | tee -a output.log
```

**Key differences from the standard build:**

| Feature | Standard build | NVIDIA build |
|---|---|---|
| CUDA Toolkit | Not installed | CUDA 13.1 |
| cuDNN | Not installed | cuDNN 9 |
| TensorRT | Not installed | TensorRT 10 |
| NCCL | Not installed | Installed |
| cuBLAS/cuSPARSE/cuFFT | Not installed | Installed |
| NVTX | Not installed | Installed |
| GStreamer nvcodec | Auto-detected (off in builds) | Always enabled |
| ORT native EP | CPU only | CPU + CUDA + TensorRT + cuDNN |
| ORT Python Package | `onnxruntime-webgpu` | `onnxruntime-gpu` (via `ONNX_PACKAGE`) |
| PyTorch Extra | `pytorch-cpu` | `pytorch-cu130` (via `PYTORCH_EXTRA`) |
| ORT output dir | `/usr/local/lib/onnxruntime-cpu` | Both cpu and `/usr/local/lib/onnxruntime-gpu` |
| Image tag | `:latest` | `:nvidia` |

### Torch Add-on (Linux)

Builds on the base image:

```bash
docker build -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch -f linux/torch/Dockerfile .
```

### AMD GPU Build (Linux)

> **Requirements:**
> - Host driver >= 6.0 (for ROCm 6.1).
> - `--device=/dev/kfd --device=/dev/dri` passed to `docker run`.

The AMD variant inserts a new `Dockerfile.amd` layer **after** `:sdk` and before the media stage. Subsequent stages reuse the standard Dockerfiles by passing `--build-arg ENABLE_AMD=true`.

**Files involved:**
| File | Purpose |
|---|---|
| `linux/Dockerfile.amd` | Installs ROCm Toolkit, MIOpen, RCCL, rocBLAS, rocFFT |
| `linux/Dockerfile.media` | Media stack: conditionally builds ORT with ROCm EP when `ENABLE_AMD=true` |
| `linux/Dockerfile.android` | Conditionally builds on top of the AMD media image |
| `linux/Dockerfile` | Conditionally tags the final entrypoint image |
| `linux/scripts/03-media/onnxruntime/build/30-build-native-amd.sh` | ORT build script with ROCm EP |

**Sequential build (nerdctl):**

```bash
# Step 1: AMD layer (builds on top of existing :sdk from standard chain)
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-amd,push=true' \
  -f linux/Dockerfile.amd \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:sdk \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-toolchain-amd \
  . 2>&1 | tee -a output.log

# Step 2: media-amd
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-amd,push=true' \
  -f linux/Dockerfile.media \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:toolchain-amd \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-media-amd \
  . 2>&1 | tee -a output.log

# Step 3: android-amd
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-amd,push=true' \
  -f linux/Dockerfile.android \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:media-amd \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-android-amd \
  . 2>&1 | tee -a output.log

# Step 4: torch-amd
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-amd,push=true' \
  -f linux/Dockerfile.torch \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:android-amd \
  --build-arg ONNX_PACKAGE="onnxruntime-rocm" \
  --build-arg PYTORCH_EXTRA="pytorch-rocm" \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-torch-amd \
  . 2>&1 | tee -a output.log

# Step 5: final amd image
sudo nerdctl build --platform linux/amd64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd \
  --output 'type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd,push=true' \
  -f linux/Dockerfile \
  --build-arg ENABLE_AMD=true \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:torch-amd \
  --cache-to=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-amd,mode=max,oci-mediatypes=true \
  --cache-from=type=registry,ref=ghcr.io/kataglyphis/kataglyphis_beschleuniger:buildcache-amd \
  . 2>&1 | tee -a output.log
```

**Run with GPU access:**

```bash
sudo nerdctl run --rm -it --device=/dev/kfd --device=/dev/dri ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd
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

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

```powershell
C:\PATH_TO_NERDCTL\nerdctl.exe build --platform windows/amd64 `
  --progress=plain --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  -f windows/Dockerfile .
```

> **Note (Windows):** For Windows-based containers and heavy workloads you may need to increase the container memory. Add the `--memory 48g` flag to your `docker run` command, for example:

```powershell
docker run --memory 48g -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

You can also increase memory for buildx builders when creating them, e.g. `docker buildx create --driver docker-container --driver-opt memory=48g --use`.

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

## WebRTC Streaming

The container includes a WebRTC signalling server (`gst-webrtc-signalling-server`) for real-time video streaming.

### Firewall Configuration

Allow port 8443 for the WebRTC signalling server:

```bash
sudo ufw allow 8443/tcp
```

### Running the Signalling Server

The `beschleuniger` container starts the signalling server automatically on port 8443:

```bash
docker-compose up -d beschleuniger
```

### Streaming from KataglyphisCppInference

The cppInference project includes WebRTC streaming support via GStreamer's `webrtcsink`:

```bash
# Build the project (inside container or on host with GStreamer)
cd /KataglyphisCppInference
cmake --preset=linux-release-clang
cmake --build build-release

# Stream with test pattern
./build-release/bin/KataglyphisCppInference --webrtc --source test --server ws://localhost:8443

# Stream from libcamera (Raspberry Pi camera)
./build-release/bin/KataglyphisCppInference --webrtc --source libcamera --server ws://localhost:8443

# Stream from V4L2 USB camera
./build-release/bin/KataglyphisCppInference --webrtc --source v4l2 --device /dev/video0 --server ws://localhost:8443
```

### CLI Options

```
--webrtc                Start WebRTC streaming
--server <uri>          Signalling server URI (default: ws://127.0.0.1:8443)
--source <type>         Video source: libcamera, v4l2, test (default: libcamera)
--device <path>         V4L2 device path (default: /dev/video0)
--width <pixels>        Video width (default: 1280)
--height <pixels>       Video height (default: 720)
--fps <rate>            Framerate (default: 30)
--encoder <type>        Encoder: h264-hw, h264-sw, vp8, vp9 (default: h264-hw)
--bitrate <kbps>        Bitrate in kbps (default: 2000)
```

### Viewing the Stream

Open the webserver in your browser and use the GstWebRTC API to connect to the stream:

```
http://localhost/javascript/webrtc/index.html
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
