<div align="center">
  <a href="https://jonasheinle.de">
    <img src="images/logo.png" alt="logo" width="200" />
  </a>

  <h1>Kataglyphis-ContainerHub</h1>

  <h4>Docker templates for GPU-friendly Linux dev stacks, a slim nginx webserver, and a Windows build image.</h4>
</div>

> add the current user to the docker group so you can push to ghcr.io without sudo:
> `sudo usermod -aG docker $USER`

[![Build Media](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/build-media.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/build-media.yml)
[![ghcr-cleanup](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml/badge.svg)](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/actions/workflows/ghcr-cleanup.yml)
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)

---

## Architecture

Three build lanes share one script tree:

```
linux/
├── Dockerfile.base          ubuntu:26.04 + CMake/Node/uv
├── Dockerfile.toolchain     GCC 16.1.0 + LLVM/Clang 22.1.6 + Python 3.14 (FROM base)
├── Dockerfile.sdk           Vulkan SDK + TVM (FROM toolchain)
├── Dockerfile.media         ONNX Runtime · LiteRT · OpenCV · FFmpeg · GStreamer · libcamera (FROM sdk)
├── Dockerfile.android       Android SDK/NDK + native GCC swap (FROM media)
├── Dockerfile.package       lean runtime assembly + validation (FROM base + android)
├── Dockerfile.torch         final wrapper: entrypoint, labels, runtime scripts (FROM package)
├── Dockerfile.nvidia        optional CUDA/cuDNN/TensorRT layer (FROM sdk)
├── Dockerfile.amd           optional ROCm layer (FROM sdk)
└── scripts/
    ├── 01-core/             shared utilities (logging, platform, downloads, tag-naming, stage-defs, digest-pinning)
    ├── 02-toolchain/        GCC, LLVM, Rust, Python, CMake, Vulkan builds
    ├── media/               ← media library build scripts (refactored)
    │   ├── core/common.sh   single DRY bootstrap sourced by every media script
    │   ├── build/           per-library build scripts (onnxruntime, litert, opencv, ffmpeg, gstreamer, libcamera)
    │   └── runtime/         artifact collection, runtime config, verification, media-env.sh
    ├── 04-runtime/          entrypoint + env scripts
    ├── 05-frameworks/       TVM, Torch, Flutter
    └── 06-packaging/        assembly + smoke tests
```

**Cross lane** (`linux/amd64` host, cross-compiles all arches): `base → compiler → sdk → media → android → package → torch`
**Runtime lane** (native/QEMU per arch): `base → package → wrapper`
**Windows lane** (native Windows Containers): `base → sdk → toolchain → media → final`

Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows: `windows/amd64`.

## Published Images

Registry: `ghcr.io/kataglyphis/kataglyphis_beschleuniger`

| Tag | What |
|-----|------|
| `:latest-cross` | Multi-arch release (amd64/arm64/riscv64) — the stable API |
| `:latest-cross-<arch>` | Per-architecture wrapper |
| `:cross-media-<arch>` | Media libraries layer (CI-built via `build-media.yml`) |
| `:webserver` | Slim nginx webserver |
| `:winamd64` | Windows build image |

## Quick Start

### Run the prebuilt image

```bash
sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
sudo nerdctl run -it --rm -p 8443:8443 ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
```

### Build the full cross chain locally

```bash
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64
```

### Build just the media layer (with BuildKit caching)

```bash
nerdctl build \
  --progress=plain \
  -f linux/Dockerfile.media \
  --build-arg BASE_IMAGE=ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-sdk-amd64 \
  --build-arg TARGET_ARCH=amd64 \
  --build-arg BUILD_MODE=cross \
  -t kataglyphis:cross-media-amd64 \
  .
```

### Verify a single cross stage without building

```bash
bash linux/scripts/build-cross-chain.sh --verify-chain --target-arches amd64,arm64,riscv64
```

### Reinstall QEMU/binfmt after a host reboot

```bash
sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all
```

## CI

| Workflow | Purpose |
|----------|---------|
| `build-media.yml` | Builds `Dockerfile.media` with `type=gha` BuildKit cache (per-arch) |
| `build-docs.yml` | Sphinx docs + version-consistency checks |
| `ghcr-cleanup.yml` | Retains last 3 per tag, 14-day safety net |

## Documentation

| Topic | Doc |
|-------|-----|
| Published images, feature snapshot | [docs/overview.md](docs/overview.md) |
| Local runs, multi-arch, buildx, mirrors | [docs/linux-build-basics.md](docs/linux-build-basics.md) |
| Cross-compiler lane, artifacts, manifest publishing | [docs/linux-cross-builds.md](docs/linux-cross-builds.md) |
| NVIDIA / AMD / Torch variants | [docs/linux-accelerator-images.md](docs/linux-accelerator-images.md) |
| Webserver, display forwarding, WebRTC | [docs/runtime-services.md](docs/runtime-services.md) |
| Windows containers | [docs/windows-builds.md](docs/windows-builds.md) |
| Prerequisites, tests, troubleshooting | [docs/project-info.md](docs/project-info.md) |
| Third-party licenses | [docs/third-party-licenses.md](docs/third-party-licenses.md) |

**Agent context:** see [AGENTS.md](AGENTS.md) for the build-system guardrails, critical fixes, and script-organization rules that LLM agents must follow.

## Clone

```bash
git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
```
