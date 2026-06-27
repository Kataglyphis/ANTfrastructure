# Open Source Licenses

This project's container images bundle several open-source and proprietary
software components.  This page lists the major components, their versions,
repositories, and licenses.

The project's own code is licensed under MIT.  Each upstream component carries
its own license terms.

---


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
| Apache TVM | v0.24.0 | [tvm.apache.org](https://tvm.apache.org/) | Apache 2.0 |

### Media Layer (`Dockerfile.media`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| ONNX Runtime | v1.27.0 | [github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | MIT |
| ONNX Runtime GenAI | v0.13.1 | [github.com/microsoft/onnxruntime-genai](https://github.com/microsoft/onnxruntime-genai) | MIT |
| LiteRT (TensorFlow Lite) | v2.1.5 | [www.tensorflow.org/lite](https://www.tensorflow.org/lite) | Apache 2.0 |
| OpenCV | 5.x | [opencv.org](https://opencv.org/) | Apache 2.0 |
| GStreamer | 1.29.1 | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ |
| FFmpeg | n8.1.2 | [ffmpeg.org](https://ffmpeg.org/) | LGPLv2.1+ |
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

### Optional GPU — NVIDIA (`Dockerfile.nvidia`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| CUDA Toolkit | 13-3 | [developer.nvidia.com/cuda-toolkit](https://developer.nvidia.com/cuda-toolkit) | NVIDIA EULA |
| cuDNN | 9 | [developer.nvidia.com/cudnn](https://developer.nvidia.com/cudnn) | NVIDIA cuDNN EULA |
| TensorRT | 11.1.0 | [developer.nvidia.com/tensorrt](https://developer.nvidia.com/tensorrt) | NVIDIA TensorRT EULA |

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
| Vulkan SDK | 1.4.341.1 | [vulkan.lunarg.com](https://vulkan.lunarg.com/) | Apache 2.0 |
| Rust toolchain | latest stable | [rust-lang.org](https://rust-lang.org/) | MIT / Apache 2.0 |
| WiX Toolset | latest | [wixtoolset.org](https://wixtoolset.org/) | MS-RL |
| Flutter SDK | 3.44.4 | [flutter.dev](https://flutter.dev/) | BSD 3-Clause |

### GPU Layer

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| CUDA | 13.3.0 | [developer.nvidia.com/cuda-toolkit](https://developer.nvidia.com/cuda-toolkit) | NVIDIA EULA |
| cuDNN | 9.23.2.1 | [developer.nvidia.com/cudnn](https://developer.nvidia.com/cudnn) | NVIDIA cuDNN EULA |

### Media Layer

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| GStreamer | 1.29.1 | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ |
| ONNX Runtime | v1.27.0 | [github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | MIT |
| ONNX Runtime GenAI | v0.13.1 | [github.com/microsoft/onnxruntime-genai](https://github.com/microsoft/onnxruntime-genai) | MIT |
| ONNX Runtime DirectML | 1.27.0 | [github.com/microsoft/onnxruntime-directml](https://github.com/microsoft/onnxruntime-directml) | MIT |
| OpenCV | 5.x | [opencv.org](https://opencv.org/) | Apache 2.0 |


---

## Flutter Web Frontend

The web frontend uses the Flutter SDK and several Dart/Flutter packages.
Their full license texts are bundled in the application at
`/assets/NOTICES` (auto-generated by the Flutter build).
