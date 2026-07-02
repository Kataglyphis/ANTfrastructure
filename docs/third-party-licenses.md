# Third-Party Software & Licenses

The container images published by this project bundle several open-source and
proprietary software components.  This document lists the major components,
their versions, and their licenses.

The project's own code is licensed under MIT (see OCI labels on the published
images).  Each upstream component carries its own license terms.

<!-- generated:deps-table:start -->

## Linux Images (`ghcr.io/kataglyphis/kataglyphis_beschleuniger`)

### Base Layer (`Dockerfile.base`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Ubuntu | 26.04 | [ubuntu.com](https://ubuntu.com/) | GPLv2 / various (individual packages) |
| CMake | 4.3.3 | [cmake.org](https://cmake.org/) | BSD 3-Clause |
| Node.js | 26.4.0 | [nodejs.org](https://nodejs.org/) | MIT |
| uv | 0.11.25 | [github.com/astral-sh/uv](https://github.com/astral-sh/uv) | Apache 2.0 / MIT |
| Vulkan SDK | 1.4.341.1 | [vulkan.lunarg.com](https://vulkan.lunarg.com/) | Apache 2.0 |

### Compiler Toolchain (`Dockerfile.toolchain`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| GCC (host + cross) | 16.1.0 | [gcc.gnu.org](https://gcc.gnu.org/) | GPLv3+ with GCC Runtime Library Exception |
| LLVM / Clang | 22.1.8 | [llvm.org](https://llvm.org/) | Apache 2.0 with LLVM Exceptions |
| Python | 3.14.6 | [python.org](https://python.org/) | PSF License |
| Rust toolchain | latest stable | [rust-lang.org](https://rust-lang.org/) | MIT / Apache 2.0 |

### SDK Layer (`Dockerfile.sdk`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Apache TVM | v0.25.0 | [tvm.apache.org](https://tvm.apache.org/) | Apache 2.0 |

### Media Layer (`Dockerfile.media`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| ONNX Runtime | v1.27.0 | [github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | MIT |
| ONNX Runtime GenAI | v0.14.0 | [github.com/microsoft/onnxruntime-genai](https://github.com/microsoft/onnxruntime-genai) | MIT |
| LiteRT (TensorFlow Lite) | v2.1.6 | [www.tensorflow.org/lite](https://www.tensorflow.org/lite) | Apache 2.0 |
| OpenCV | 5.x | [opencv.org](https://opencv.org/) | Apache 2.0 |
| GStreamer | 1.29.2 | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ |
| GStreamer Rust plugins (gst-plugins-rs) | 1.29.2 | [gitlab.freedesktop.org/gstreamer/gst-plugins-rs](https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs) | MPL-2.0 |
| librice / rice-proto (webrtcbin2) | v0.4.3 | [github.com/ystreet/librice](https://github.com/ystreet/librice) | Apache 2.0 |
| FFmpeg | master | [ffmpeg.org](https://ffmpeg.org/) | GPLv3+ (built with --enable-gpl --enable-version3) |
| FFmpeg codec libraries (x264, x265, libvpx, aom, dav1d, SVT-AV1, opus, LAME, vorbis, libass, twolame) | Ubuntu apt | [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html) | GPL / LGPL / various |
| VVdeC (VVC/H.266 decoder) | v3.1.0 | [github.com/fraunhoferhhi/vvdec](https://github.com/fraunhoferhhi/vvdec) | BSD-3-Clause-Clear |
| ArmNN (arm64) | v25.11 | [github.com/ARM-software/armnn](https://github.com/ARM-software/armnn) | MIT |
| Arm Compute Library (arm64) | v25.04 | [github.com/ARM-software/ComputeLibrary](https://github.com/ARM-software/ComputeLibrary) | MIT |
| libcamera | git master | [libcamera.org](https://libcamera.org/) | LGPLv2.1+ |
| Abseil | 20240722.0 | [github.com/abseil/abseil-cpp](https://github.com/abseil/abseil-cpp) | Apache 2.0 |
| FreeType | 2.14.2 | [freetype.org](https://freetype.org/) | GPLv2 / FTL |
| nv-codec-headers | n12.2.1 | [git.videolan.org/git/ffmpeg/nv-codec-headers.git](https://git.videolan.org/git/ffmpeg/nv-codec-headers.git) | MIT |
| GObject-Introspection | 1.80.1 | [gitlab.gnome.org/GNOME/gobject-introspection](https://gitlab.gnome.org/GNOME/gobject-introspection) | LGPLv2+ |

### Android Layer (`Dockerfile.android`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Android SDK | 14742923 | [developer.android.com/studio](https://developer.android.com/studio) | Apache 2.0 / Google ToS |
| Android NDK | 29.0.14206865 | [developer.android.com/ndk](https://developer.android.com/ndk) | Apache 2.0 |
| Android Build Tools | 35.0.0 | [developer.android.com/studio/releases/build-tools](https://developer.android.com/studio/releases/build-tools) | Apache 2.0 |
| Android CMake | 4.1.2 | [cmake.org](https://cmake.org/) | BSD 3-Clause |
| Android builds of LiteRT / ONNX Runtime / OpenCV / GStreamer | same versions as Media Layer | [developer.android.com/ndk](https://developer.android.com/ndk) | Apache 2.0 / MIT / LGPLv2+ (per component) |

### Optional GPU — NVIDIA (`Dockerfile.nvidia`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| CUDA Toolkit | 13.3.0 | [developer.nvidia.com/cuda-toolkit](https://developer.nvidia.com/cuda-toolkit) | NVIDIA EULA |
| cuDNN | 9.23.2.1 | [developer.nvidia.com/cudnn](https://developer.nvidia.com/cudnn) | NVIDIA cuDNN EULA |
| TensorRT | 11.1.0.106 | [developer.nvidia.com/tensorrt](https://developer.nvidia.com/tensorrt) | NVIDIA TensorRT EULA |

### Optional GPU — AMD (`Dockerfile.amd`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| ROCm | 7.1 | [rocm.docs.amd.com](https://rocm.docs.amd.com/) | Apache 2.0 / MIT (varies by component) |
| MIGraphX | 2.14.0 | [github.com/ROCm/AMDMIGraphX](https://github.com/ROCm/AMDMIGraphX) | MIT |

### Frameworks (`Dockerfile.torch`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| PyTorch | v2.12.1 | [pytorch.org](https://pytorch.org/) | BSD-3-Clause |
| TorchVision | v0.27.1 | [github.com/pytorch/vision](https://github.com/pytorch/vision) | BSD-3-Clause |
| Flutter SDK | 3.44.4 | [flutter.dev](https://flutter.dev/) | BSD 3-Clause |

### Runtime (`Dockerfile.torch`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Kataglyphis Orchestr-ANT-ion | v0.0.19 | [github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion](https://github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion) | MIT |

### LLM Stack (`llm-stack/Dockerfile`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Ollama | 0.30.10 | [github.com/ollama/ollama](https://github.com/ollama/ollama) | MIT |

### Build Tooling (build-time only, not in runtime images)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Emscripten / emsdk (ONNX Runtime WASM build) | pinned by ONNX Runtime | [emscripten.org](https://emscripten.org/) | MIT / NCSA |
| ccache | Ubuntu apt | [ccache.dev](https://ccache.dev/) | GPLv3+ |
| sccache | Ubuntu apt | [github.com/mozilla/sccache](https://github.com/mozilla/sccache) | Apache 2.0 |
| Meson | latest (PyPI) | [mesonbuild.com](https://mesonbuild.com/) | Apache 2.0 |
| Ninja | latest (PyPI) | [ninja-build.org](https://ninja-build.org/) | Apache 2.0 |
| cargo-c (C-ABI build of gst-plugins-rs) | latest (crates.io) | [github.com/lu-zero/cargo-c](https://github.com/lu-zero/cargo-c) | MIT / Apache 2.0 |
| cerbero (GStreamer Android build system) | git default branch | [gitlab.freedesktop.org/gstreamer/cerbero](https://gitlab.freedesktop.org/gstreamer/cerbero) | LGPLv2.1+ |


## Webserver Image (`ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver`)

### Packages

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Ubuntu | 26.04 | [ubuntu.com](https://ubuntu.com/) | GPLv2 / various |
| nginx | latest (apt) | [nginx.org](https://nginx.org/) | BSD 2-Clause |


## Windows Image (`ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`)

### Base Toolchain

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Windows Server Core | 2025 | [www.microsoft.com](https://www.microsoft.com/) | Microsoft EULA |
| Visual Studio Build Tools | 18 | [visualstudio.microsoft.com](https://visualstudio.microsoft.com/) | Microsoft EULA |
| Python (source-built, ClangCL) | 3.14.6 | [python.org](https://python.org/) | PSF License |
| CPython bundled externals (OpenSSL, SQLite, libffi, xz, bzip2, zlib, tcl/tk, expat, mpdecimal) | bundled with Python | [github.com/python/cpython-source-deps](https://github.com/python/cpython-source-deps) | various (Apache 2.0, MIT, PD, …) |
| CMake | 4.3.3 | [cmake.org](https://cmake.org/) | BSD 3-Clause |
| Vulkan SDK | 1.4.341.1 | [vulkan.lunarg.com](https://vulkan.lunarg.com/) | Apache 2.0 |
| Rust toolchain | latest stable | [rust-lang.org](https://rust-lang.org/) | MIT / Apache 2.0 |
| WiX Toolset | latest | [wixtoolset.org](https://wixtoolset.org/) | MS-RL |
| Flutter SDK | 3.44.4 | [flutter.dev](https://flutter.dev/) | BSD 3-Clause |

### GPU Layer

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| CUDA | 13.3.0 | [developer.nvidia.com/cuda-toolkit](https://developer.nvidia.com/cuda-toolkit) | NVIDIA EULA |
| cuDNN | 9.23.2.1 | [developer.nvidia.com/cudnn](https://developer.nvidia.com/cudnn) | NVIDIA cuDNN EULA |
| TensorRT | 11.1.0.106 | [developer.nvidia.com/tensorrt](https://developer.nvidia.com/tensorrt) | NVIDIA TensorRT EULA |

### Media Layer

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| GStreamer | 1.29.2 | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ |
| GStreamer meson subprojects (glib, orc, libnice, x264, openh264, …) | per wrap files | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ / GPL (x264) / BSD (openh264) |
| ONNX Runtime | v1.27.0 | [github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | MIT |
| ONNX Runtime GenAI | v0.14.0 | [github.com/microsoft/onnxruntime-genai](https://github.com/microsoft/onnxruntime-genai) | MIT |
| OpenCV | 5.x | [opencv.org](https://opencv.org/) | Apache 2.0 |
| FFmpeg | master | [ffmpeg.org](https://ffmpeg.org/) | GPLv3+ (built with --enable-gpl --enable-version3) |
| LiteRT (TensorFlow Lite) | v2.1.6 | [www.tensorflow.org/lite](https://www.tensorflow.org/lite) | Apache 2.0 |
| LiteRT-LM | 0.13.1 | [github.com/google-ai-edge/LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) | Apache 2.0 |
| Apache TVM | v0.25.0 | [tvm.apache.org](https://tvm.apache.org/) | Apache 2.0 |

### Build Tooling (build-time only)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Scoop package manager | latest | [scoop.sh](https://scoop.sh/) | Unlicense / MIT |
| Scoop-installed tools (7-Zip, Git, LLVM, ninja, sccache, NASM, OpenSSL, NSIS, cppcheck, nano, uv, NuGet) | latest (scoop) | [scoop.sh](https://scoop.sh/) | various (GPL, Apache 2.0, BSD, zlib) |
| vcpkg | master | [github.com/microsoft/vcpkg](https://github.com/microsoft/vcpkg) | MIT |
| vcpkg packages (zlib, protobuf — linked into builds) | vcpkg baseline | [github.com/microsoft/vcpkg](https://github.com/microsoft/vcpkg) | Zlib / BSD 3-Clause |


## Host Build Infrastructure (runs on the build host, not inside any image)

### Container Engines & Builders

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| nerdctl (Linux builds & container runs) | host install | [github.com/containerd/nerdctl](https://github.com/containerd/nerdctl) | Apache 2.0 |
| containerd | host install | [containerd.io](https://containerd.io/) | Apache 2.0 |
| BuildKit (buildkitd) | host install | [github.com/moby/buildkit](https://github.com/moby/buildkit) | Apache 2.0 |
| Stevedore (Windows builds — bundled docker.exe) | host install | [github.com/slonopotamus/stevedore](https://github.com/slonopotamus/stevedore) | Apache 2.0 |

<!-- generated:deps-table:end -->

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
