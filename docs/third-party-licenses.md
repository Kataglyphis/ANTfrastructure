# Third-Party Software & Licenses

The container images published by this project bundle several open-source and
proprietary software components.  This document lists the major components,
their versions, and their licenses.

The project's own code is licensed under MIT (see OCI labels on the published
images).  Each upstream component carries its own license terms.

---

## Linux Images (`ghcr.io/kataglyphis/kataglyphis_beschleuniger`)

### Base Layer (`Dockerfile.base`)

| Software | Version | License |
|----------|---------|---------|
| Ubuntu | <!-- generated:ubuntu -->26.04<!-- /generated:ubuntu --> | GPLv2 / various (individual packages) |
| CMake | <!-- generated:cmake -->4.3.2<!-- /generated:cmake --> | BSD 3-Clause |
| Node.js | <!-- generated:node -->24.16.0<!-- /generated:node --> | MIT |
| uv | <!-- generated:uv -->0.11.16<!-- /generated:uv --> | Apache 2.0 / MIT |
| Vulkan SDK | <!-- generated:vulkan -->1.4.341.1<!-- /generated:vulkan --> | Apache 2.0 |

Ubuntu system packages (`apt-get install`) carry their own licenses (GPL, LGPL,
Apache 2.0, MIT, BSD, zlib, and others).  See `/usr/share/doc/*/copyright` inside
the image for per-package details.

### Compiler Toolchain (`Dockerfile.toolchain`)

| Software | Version | License |
|----------|---------|---------|
| GCC (host + cross) | <!-- generated:gcc -->16.1.0<!-- /generated:gcc --> | GPLv3+ (with GCC Runtime Library Exception) |
| LLVM / Clang | <!-- generated:llvm -->22.1.6<!-- /generated:llvm --> | Apache 2.0 with LLVM Exceptions |
| Python | <!-- generated:python -->3.14.5<!-- /generated:python --> | PSF License |
| Rust toolchain | latest stable | MIT / Apache 2.0 |

### SDK Layer (`Dockerfile.sdk`)

| Software | Version | License |
|----------|---------|---------|
| Apache TVM | <!-- generated:tvm -->v0.24.0<!-- /generated:tvm --> | Apache 2.0 |

### Media Layer (`Dockerfile.media`)

| Software | Version | License |
|----------|---------|---------|
| ONNX Runtime | <!-- generated:onnx -->1.26.0<!-- /generated:onnx --> | MIT |
| ONNX Runtime GenAI | <!-- generated:onnx_genai -->0.13.1<!-- /generated:onnx_genai --> | MIT |
| LiteRT (TensorFlow Lite) | <!-- generated:litert -->2.1.5<!-- /generated:litert --> | Apache 2.0 |
| OpenCV | 5.x | Apache 2.0 |
| GStreamer | <!-- generated:gstreamer -->1.29.1<!-- /generated:gstreamer --> | LGPLv2+ |
| FFmpeg | git master | LGPLv2.1+ |
| libcamera | git master | LGPLv2.1+ |
| Abseil (via LiteRT) | git | Apache 2.0 |

### Android Layer (`Dockerfile.android`)

| Software | Version | License |
|----------|---------|---------|
| Android SDK | <!-- generated:android_sdk -->14742923<!-- /generated:android_sdk --> | Apache 2.0 / Google ToS |
| Android NDK | <!-- generated:android_ndk -->29.0.14206865<!-- /generated:android_ndk --> | Apache 2.0 |
| Android Build Tools | <!-- generated:android_build_tools -->35.0.0<!-- /generated:android_build_tools --> | Apache 2.0 / Google ToS |
| Android CMake | <!-- generated:android_cmake -->4.1.2<!-- /generated:android_cmake --> | BSD 3-Clause |

### Optional GPU — NVIDIA (`Dockerfile.nvidia`)

| Software | Version | License |
|----------|---------|---------|
| CUDA Toolkit | 13.3.0 | [NVIDIA EULA](https://docs.nvidia.com/cuda/eula/index.html) |
| cuDNN | 9 | [NVIDIA cuDNN EULA](https://docs.nvidia.com/deeplearning/cudnn/sla/index.html) |
| TensorRT | 10 | [NVIDIA TensorRT EULA](https://docs.nvidia.com/tensorrt/eula/index.html) |

### Optional GPU — AMD (`Dockerfile.amd`)

| Software | Version | License |
|----------|---------|---------|
| ROCm | latest | Apache 2.0 / MIT (varies by component) |

---

## Webserver Image (`ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver`)

| Software | Version | License |
|----------|---------|---------|
| Ubuntu | 26.04 | GPLv2 / various |
| nginx | latest (apt) | BSD 2-Clause |

---

## Windows Image (`ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`)

| Software | Version | License |
|----------|---------|---------|
| Windows Server Core | LTSC 2025 | Microsoft EULA |
| Visual Studio Build Tools | 18 | Microsoft EULA |
| Vulkan SDK | 1.4.341.1 | Apache 2.0 |
| GStreamer | 1.28.2 | LGPLv2+ |
| CUDA | 12.9.0 | NVIDIA EULA |
| cuDNN | 9.10.1.4 | NVIDIA EULA |
| ONNX Runtime | 1.26.0 | MIT |
| ONNX Runtime GenAI | 0.13.2 | MIT |
| ONNX Runtime DirectML | 1.24.4 | MIT |
| OpenCV | 4.13.0 | Apache 2.0 |
| Rust toolchain | latest stable | MIT / Apache 2.0 |
| WiX Toolset | latest | MS-RL |
| Flutter SDK | latest stable | BSD 3-Clause |

---

## License Summary by Category

| Category | Common Licenses |
|----------|----------------|
| Compilers & toolchains | GPLv3+, Apache 2.0, MIT, BSD |
| Media libraries | LGPLv2+, Apache 2.0, MIT |
| GPU toolkits | NVIDIA EULA, Apache 2.0, MIT |
| Android SDK/NDK | Apache 2.0, Google ToS |
| Runtime languages | MIT, PSF, Apache 2.0 |
| Windows platform | Microsoft EULA |
| Build tools | BSD, MIT, Apache 2.0 |

---

## Notes

- Ubuntu system packages carry diverse licenses (GPL, LGPL, Apache 2.0, MIT,
  BSD, zlib, Public Domain).  Check `/usr/share/doc/<pkg>/copyright` inside
  the image for exact terms.
- NVIDIA EULAs require acceptance before download/use.  The container images
  do not redistribute CUDA/cuDNN/TensorRT downloads — they are downloaded
  during build from official NVIDIA repositories.
- "git master" versions are built from the latest development branch at the
  time the image was built.  For exact commit SHAs, inspect the build logs.
- Version numbers marked with <!-- generated:... --> are automatically kept
  in sync with `linux/scripts/01-core/versions.env` by `sync_versions.py`.
