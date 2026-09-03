# Open-Source-Lizenzen

Die Container-Images dieses Projekts enthalten mehrere Open-Source- und
proprietäre Softwarekomponenten. Diese Seite listet die wichtigsten
Komponenten, ihre Versionen, Quellen und Lizenzen auf.

Der eigene Code des Projekts steht unter der MIT-Lizenz. Für jede
vorgelagerte Komponente gelten die jeweiligen Lizenzbedingungen.

---


## Linux Images (`ghcr.io/kataglyphis/kataglyphis_beschleuniger`)

### Base Layer (`Dockerfile.base`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Ubuntu | 26.04 | [ubuntu.com](https://ubuntu.com/) | GPLv2 / various (individual packages) |
| CMake | 4.4.3 | [cmake.org](https://cmake.org/) | BSD 3-Clause |
| Node.js | 26.8.1 | [nodejs.org](https://nodejs.org/) | MIT |
| uv | 0.12.6 | [github.com/astral-sh/uv](https://github.com/astral-sh/uv) | Apache 2.0 / MIT |
| Vulkan SDK | 1.4.357.0 | [vulkan.lunarg.com](https://vulkan.lunarg.com/) | Apache 2.0 |

### Compiler Toolchain (`Dockerfile.toolchain`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| GCC (host + cross) | 16.2.0 | [gcc.gnu.org](https://gcc.gnu.org/) | GPLv3+ with GCC Runtime Library Exception |
| LLVM / Clang | 23.1.0 | [llvm.org](https://llvm.org/) | Apache 2.0 with LLVM Exceptions |
| Python | 3.14.7 | [python.org](https://python.org/) | PSF License |
| Rust toolchain | latest stable | [rust-lang.org](https://rust-lang.org/) | MIT / Apache 2.0 |

### SDK Layer (`Dockerfile.sdk`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Apache TVM | v0.26.0 | [tvm.apache.org](https://tvm.apache.org/) | Apache 2.0 |

### Media Layer (`Dockerfile.media`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| ONNX Runtime | v1.29.0 | [github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | MIT |
| ONNX Runtime GenAI | v0.15.2 | [github.com/microsoft/onnxruntime-genai](https://github.com/microsoft/onnxruntime-genai) | MIT |
| LiteRT (TensorFlow Lite) | v2.2.0 | [www.tensorflow.org/lite](https://www.tensorflow.org/lite) | Apache 2.0 |
| OpenCV | 5.0.0 | [opencv.org](https://opencv.org/) | Apache 2.0 |
| GStreamer | 1.29.2 | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ |
| GStreamer Rust plugins (gst-plugins-rs) | 1.29.2 | [gitlab.freedesktop.org/gstreamer/gst-plugins-rs](https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs) | MPL-2.0 |
| librice / rice-proto (webrtcbin2) | v0.4.3 | [github.com/ystreet/librice](https://github.com/ystreet/librice) | Apache 2.0 |
| FFmpeg | n9.0 | [ffmpeg.org](https://ffmpeg.org/) | GPLv3+ (built with --enable-gpl --enable-version3) |
| FFmpeg codec libraries (x264, x265, libvpx, aom, dav1d, SVT-AV1, opus, LAME, vorbis, libass, twolame) | Ubuntu apt | [ffmpeg.org/legal.html](https://ffmpeg.org/legal.html) | GPL / LGPL / various |
| VVdeC (VVC/H.266 decoder) | v3.2.0 | [github.com/fraunhoferhhi/vvdec](https://github.com/fraunhoferhhi/vvdec) | BSD-3-Clause-Clear |
| ArmNN (arm64) | v26.07 | [github.com/ARM-software/armnn](https://github.com/ARM-software/armnn) | MIT |
| Arm Compute Library (arm64) | v53.2.0 | [github.com/ARM-software/ComputeLibrary](https://github.com/ARM-software/ComputeLibrary) | MIT |
| libcamera | v0.7.2 | [libcamera.org](https://libcamera.org/) | LGPLv2.1+ |
| Abseil | 20260817.0 | [github.com/abseil/abseil-cpp](https://github.com/abseil/abseil-cpp) | Apache 2.0 |
| FreeType | 2.14.3 | [freetype.org](https://freetype.org/) | GPLv2 / FTL |
| nv-codec-headers | n13.1.15.0 | [git.videolan.org/git/ffmpeg/nv-codec-headers.git](https://git.videolan.org/git/ffmpeg/nv-codec-headers.git) | MIT |
| GObject-Introspection | 1.86.0 | [gitlab.gnome.org/GNOME/gobject-introspection](https://gitlab.gnome.org/GNOME/gobject-introspection) | LGPLv2+ |
| IREE | v3.11.0 | [iree.dev](https://iree.dev/) | Apache 2.0 with LLVM Exception |
| PyAV | 18.1.0 | [github.com/PyAV-Org/PyAV](https://github.com/PyAV-Org/PyAV) | BSD 3-Clause |

### Android Layer (`Dockerfile.android`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Android SDK | 15859902 | [developer.android.com/studio](https://developer.android.com/studio) | Apache 2.0 / Google ToS |
| Android NDK | 29.0.14206865 | [developer.android.com/ndk](https://developer.android.com/ndk) | Apache 2.0 |
| Android Build Tools | 36.0.0 | [developer.android.com/studio/releases/build-tools](https://developer.android.com/studio/releases/build-tools) | Apache 2.0 |
| Android CMake | 4.1.2 | [cmake.org](https://cmake.org/) | BSD 3-Clause |
| Android builds of LiteRT / ONNX Runtime / OpenCV / GStreamer | same versions as Media Layer | [developer.android.com/ndk](https://developer.android.com/ndk) | Apache 2.0 / MIT / LGPLv2+ (per component) |

### Optional GPU — NVIDIA (`Dockerfile.nvidia`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| CUDA Toolkit | 13.3.1 | [developer.nvidia.com/cuda-toolkit](https://developer.nvidia.com/cuda-toolkit) | NVIDIA EULA |
| cuDNN | 9.25.0.15 | [developer.nvidia.com/cudnn](https://developer.nvidia.com/cudnn) | NVIDIA cuDNN EULA |
| TensorRT | 11.2.1.2 | [developer.nvidia.com/tensorrt](https://developer.nvidia.com/tensorrt) | NVIDIA TensorRT EULA |

### Optional GPU — AMD (`Dockerfile.amd`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| ROCm | 10.0 | [rocm.docs.amd.com](https://rocm.docs.amd.com/) | Apache 2.0 / MIT (varies by component) |
| MIGraphX | 2.17.0 | [github.com/ROCm/AMDMIGraphX](https://github.com/ROCm/AMDMIGraphX) | MIT |

### Frameworks (`Dockerfile.torch`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| PyTorch | v2.13.0 | [pytorch.org](https://pytorch.org/) | BSD-3-Clause |
| TorchVision | v0.28.0 | [github.com/pytorch/vision](https://github.com/pytorch/vision) | BSD-3-Clause |
| Flutter SDK | 3.47.1 | [flutter.dev](https://flutter.dev/) | BSD 3-Clause |

### Runtime (`Dockerfile.torch`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Kataglyphis Orchestr-ANT-ion | v0.0.27 | [github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion](https://github.com/Kataglyphis/Kataglyphis-Orchestr-ANT-ion) | MIT |

### LLM Stack (`llm-stack/Dockerfile`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Ollama | 0.33.1 | [github.com/ollama/ollama](https://github.com/ollama/ollama) | MIT |

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
| Python (source-built, ClangCL) | 3.14.7 | [python.org](https://python.org/) | PSF License |
| CPython bundled externals (OpenSSL, SQLite, libffi, xz, bzip2, zlib, tcl/tk, expat, mpdecimal) | bundled with Python | [github.com/python/cpython-source-deps](https://github.com/python/cpython-source-deps) | various (Apache 2.0, MIT, PD, …) |
| CMake | 4.4.3 | [cmake.org](https://cmake.org/) | BSD 3-Clause |
| Vulkan SDK | 1.4.357.0 | [vulkan.lunarg.com](https://vulkan.lunarg.com/) | Apache 2.0 |
| Rust toolchain | latest stable | [rust-lang.org](https://rust-lang.org/) | MIT / Apache 2.0 |
| WiX Toolset | latest | [wixtoolset.org](https://wixtoolset.org/) | MS-RL |
| Flutter SDK | 3.47.1 | [flutter.dev](https://flutter.dev/) | BSD 3-Clause |

### GPU Layer

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| CUDA | 13.3.1 | [developer.nvidia.com/cuda-toolkit](https://developer.nvidia.com/cuda-toolkit) | NVIDIA EULA |
| cuDNN | 9.25.0.15 | [developer.nvidia.com/cudnn](https://developer.nvidia.com/cudnn) | NVIDIA cuDNN EULA |
| TensorRT | 11.2.1.2 | [developer.nvidia.com/tensorrt](https://developer.nvidia.com/tensorrt) | NVIDIA TensorRT EULA |

### Media Layer

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| GStreamer | 1.29.2 | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ |
| GStreamer meson subprojects (glib, orc, libnice, x264, openh264, …) | per wrap files | [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/) | LGPLv2+ / GPL (x264) / BSD (openh264) |
| ONNX Runtime | v1.29.0 | [github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | MIT |
| ONNX Runtime GenAI | v0.15.2 | [github.com/microsoft/onnxruntime-genai](https://github.com/microsoft/onnxruntime-genai) | MIT |
| OpenCV | 5.0.0 | [opencv.org](https://opencv.org/) | Apache 2.0 |
| FFmpeg | n9.0 | [ffmpeg.org](https://ffmpeg.org/) | GPLv3+ (built with --enable-gpl --enable-version3) |
| LiteRT (TensorFlow Lite) | v2.2.0 | [www.tensorflow.org/lite](https://www.tensorflow.org/lite) | Apache 2.0 |
| LiteRT-LM | 0.16.1 | [github.com/google-ai-edge/LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) | Apache 2.0 |
| Apache TVM | v0.26.0 | [tvm.apache.org](https://tvm.apache.org/) | Apache 2.0 |

### Build Tooling (build-time only)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Scoop package manager | latest | [scoop.sh](https://scoop.sh/) | Unlicense / MIT |
| Scoop-installed tools (7-Zip, Git, LLVM, ninja, sccache, NASM, OpenSSL, NSIS, cppcheck, nano, uv, NuGet) | latest (scoop) | [scoop.sh](https://scoop.sh/) | various (GPL, Apache 2.0, BSD, zlib) |
| vcpkg | master | [github.com/microsoft/vcpkg](https://github.com/microsoft/vcpkg) | MIT |
| vcpkg packages (zlib, protobuf — linked into builds) | vcpkg baseline | [github.com/microsoft/vcpkg](https://github.com/microsoft/vcpkg) | Zlib / BSD 3-Clause |


## Documentation Image (`pandoc_all`)

### Document Toolchain (`external/Kataglyphis-DocumANTation/Dockerfile`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Ubuntu | 26.04 | [ubuntu.com](https://ubuntu.com/) | GPLv2 / various (individual packages) |
| Pandoc | 3.10.2 | [github.com/jgm/pandoc](https://github.com/jgm/pandoc) | GPLv2+ |
| TeX Live (texlive-full) | Ubuntu apt | [tug.org/texlive](https://tug.org/texlive/) | Collection; per package LPPL / GPL / X11 / modified BSD |
| Latin Modern fonts (lmodern) | Ubuntu apt | [www.gust.org.pl/projects/e-foundry/latin-modern](http://www.gust.org.pl/projects/e-foundry/latin-modern) | GUST Font License (LPPL-style) |
| Ghostscript | Ubuntu apt | [www.ghostscript.com](https://www.ghostscript.com/) | AGPLv3+ |
| ImageMagick | Ubuntu apt | [imagemagick.org](https://imagemagick.org/) | ImageMagick License (Apache 2.0-style) |

### Python (`external/Kataglyphis-DocumANTation/Dockerfile`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| Python | Ubuntu apt (python3-full) | [python.org](https://python.org/) | PSF License |
| uv | 0.12.6 | [github.com/astral-sh/uv](https://github.com/astral-sh/uv) | Apache 2.0 / MIT |
| Pygments | pinned by uv.lock | [pygments.org](https://pygments.org/) | BSD 2-Clause |

### Base Utilities (`external/Kataglyphis-DocumANTation/Dockerfile`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| GNU C Library locales (locales) | Ubuntu apt | [www.gnu.org/software/libc](https://www.gnu.org/software/libc/) | LGPLv2.1+ |
| curl | Ubuntu apt | [curl.se](https://curl.se/) | curl (MIT/X-style) |
| GNU Wget | Ubuntu apt | [www.gnu.org/software/wget](https://www.gnu.org/software/wget/) | GPLv3+ |
| ca-certificates | Ubuntu apt | [packages.ubuntu.com/ca-certificates](https://packages.ubuntu.com/ca-certificates) | MPL-2.0 (CA bundle) / GPLv2+ (packaging) |
| less | Ubuntu apt | [www.greenwoodsoftware.com/less](https://www.greenwoodsoftware.com/less/) | GPLv3+ or Less License |
| sudo | Ubuntu apt | [www.sudo.ws](https://www.sudo.ws/) | ISC (with BSD-2/3-Clause parts) |

### Vendored LaTeX Themes (`external/Kataglyphis-DocumANTation/Dockerfile`)

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| awesome-beamer (fork of LukasPietzschmann/awesome-beamer) | git submodule | [github.com/Kataglyphis/awesome-beamer](https://github.com/Kataglyphis/awesome-beamer) | BSD 3-Clause |
| smile (fork of LukasPietzschmann/smile) | git submodule | [github.com/Kataglyphis/smile](https://github.com/Kataglyphis/smile) | BSD 3-Clause |


## Host Build Infrastructure (runs on the build host, not inside any image)

### Container Engines & Builders

| Software | Version | Repository | License |
| --- | --- | --- | --- |
| nerdctl (Linux builds & container runs) | host install | [github.com/containerd/nerdctl](https://github.com/containerd/nerdctl) | Apache 2.0 |
| containerd | host install | [containerd.io](https://containerd.io/) | Apache 2.0 |
| BuildKit (buildkitd) | host install | [github.com/moby/buildkit](https://github.com/moby/buildkit) | Apache 2.0 |
| Stevedore (Windows builds — bundled docker.exe) | host install | [github.com/slonopotamus/stevedore](https://github.com/slonopotamus/stevedore) | Apache 2.0 |
| GenieX (on-device LLM/VLM runtime for Snapdragon; WSL2 client + Windows host server) | host install (GenieX CLI v0.5.0) | [github.com/qualcomm/GenieX](https://github.com/qualcomm/GenieX) | BSD 3-Clause |


---

## What these licences require

Every obligation below is triggered by at least one component actually shipped in an image on this page. This is a structured reading of the licence texts, not legal advice.

- **keep-notice** — Reproduce the upstream copyright notice with the distributed binary.
- **include-text** — Ship the full licence text alongside the binary.
- **state-changes** — Mark modified files as changed, and say what was changed.
- **notice-file** — Propagate the upstream NOTICE file if one exists.
- **offer-source** — Provide the complete corresponding source, or a written offer valid for three years. Publishing the binary without either is the obligation most often missed.
- **allow-relink** — Let the recipient replace the library and relink. Shipping it as a shared object, as this project does, satisfies the mechanism; the notice and text are still required.
- **network-source** — AGPL section 13: users interacting with the software OVER A NETWORK must be offered its source. This reaches further than the GPL and is worth checking against how the component is actually exposed.
- **same-licence** — Derivative works of this component must carry the same licence.
- **eula-review** — Proprietary terms. Redistribution is NOT automatically granted -- the vendor EULA decides whether this component may ship in a published image at all. This is a legal question, not a documentation one.


---

## Corresponding source

The components below are copyleft-licensed, so their source must accompany the binaries. Each entry names the exact upstream and the revision this project builds, any patches applied on top, and — where the build configuration is what determines the licence — the flags used.

If a link ever fails to resolve, the obligation stands: request the corresponding source and it will be provided.

### Ubuntu — Linux Images

- **Licence:** LicenseRef-Distro-Bundle
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### GCC (host + cross) — Linux Images

- **Licence:** GPL-3.0-or-later WITH GCC-exception-3.1
- **Source:** <https://ftp.gnu.org/gnu/gcc/>
- **Revision:** 16.2.0
- Built unmodified from the GNU release tarball. The Runtime Library Exception covers programs COMPILED with GCC; it does not cover shipping GCC itself, which the runtime image does.

### GStreamer — Linux Images

- **Licence:** LGPL-2.0-or-later
- **Source:** <https://gitlab.freedesktop.org/gstreamer/gstreamer>
- **Revision:** 1.29.2

### GStreamer Rust plugins (gst-plugins-rs) — Linux Images

- **Licence:** MPL-2.0
- **Source:** <https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs>
- **Revision:** 1.29.2

### FFmpeg — Linux Images

- **Licence:** GPL-3.0-or-later
- **Source:** <https://git.ffmpeg.org/ffmpeg.git>
- **Revision:** n9.0
- **Build configuration:** `--enable-gpl --enable-version3 --enable-libx264 --enable-libx265`
- Those flags are what make the shipped binary GPLv3, rather than FFmpeg's default LGPL.

### FFmpeg codec libraries (x264, x265, libvpx, aom, dav1d, SVT-AV1, opus, LAME, vorbis, libass, twolame) — Linux Images

- **Licence:** GPL-2.0-or-later AND LGPL-2.1-or-later
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### libcamera — Linux Images

- **Licence:** LGPL-2.1-or-later
- **Source:** <https://git.libcamera.org/libcamera/libcamera.git>
- **Revision:** v0.7.2

### FreeType — Linux Images

- **Licence:** GPL-2.0-or-later OR FTL
- **Source:** <https://download.savannah.gnu.org/releases/freetype/>
- **Revision:** 2.14.3
- Dual-licensed. This project elects the FTL, which needs only notice and text; the source pointer is provided anyway.

### GObject-Introspection — Linux Images

- **Licence:** LGPL-2.0-or-later
- **Source:** <https://gitlab.gnome.org/GNOME/gobject-introspection>
- **Revision:** 1.86.0

### Android builds of LiteRT / ONNX Runtime / OpenCV / GStreamer — Linux Images

- **Licence:** Apache-2.0 AND MIT AND LGPL-2.0-or-later
- **Source:** <https://gitlab.freedesktop.org/gstreamer/gstreamer>
- **Revision:** same refs as the Media Layer rows above

### ccache — Linux Images

- **Licence:** GPL-3.0-or-later
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### cerbero (GStreamer Android build system) — Linux Images

- **Licence:** LGPL-2.1-or-later
- **Source:** <https://gitlab.freedesktop.org/gstreamer/cerbero>
- **Revision:** default branch
- Build-time only; never shipped in a runtime image.

### Ubuntu — Webserver Image

- **Licence:** LicenseRef-Distro-Bundle
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### CPython bundled externals (OpenSSL, SQLite, libffi, xz, bzip2, zlib, tcl/tk, expat, mpdecimal) — Windows Image

- **Licence:** LicenseRef-Distro-Bundle
- **Source:** <https://github.com/python/cpython-source-deps>
- **Revision:** as bundled by the pinned CPython
- Redistributed unmodified as part of the CPython build.

### GStreamer — Windows Image

- **Licence:** LGPL-2.0-or-later
- **Source:** <https://gitlab.freedesktop.org/gstreamer/gstreamer>
- **Revision:** 1.29.2
- **Patches applied:** `windows/scripts/patches/gstreamer/001-ges-commit-rename.patch`

### GStreamer meson subprojects (glib, orc, libnice, x264, openh264, …) — Windows Image

- **Licence:** LGPL-2.0-or-later AND GPL-2.0-or-later AND BSD-2-Clause
- **Source:** <https://gitlab.freedesktop.org/gstreamer/gstreamer/-/tree/main/subprojects>
- **Revision:** pinned by the GStreamer release's wrap files
- x264 is GPL, so its presence is what makes this subproject set copyleft.

### FFmpeg — Windows Image

- **Licence:** GPL-3.0-or-later
- **Source:** <https://git.ffmpeg.org/ffmpeg.git>
- **Revision:** n9.0
- **Build configuration:** `--enable-gpl --enable-version3 --enable-libx264 --enable-libx265`
- **Patches applied:** `windows/scripts/patches/ffmpeg/001-allow-msys-builds.patch`
- Those flags are what make the shipped binary GPLv3, rather than FFmpeg's default LGPL.

### Scoop-installed tools (7-Zip, Git, LLVM, ninja, sccache, NASM, OpenSSL, NSIS, cppcheck, nano, uv, NuGet) — Windows Image

- **Licence:** LicenseRef-Distro-Bundle
- **Source:** <https://scoop.sh/>
- **Revision:** —
- Build-time tooling installed from upstream publishers; each carries its own source location. sccache is the exception -- see its own row, it is built from patched source.

### Ubuntu — Documentation Image

- **Licence:** LicenseRef-Distro-Bundle
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### Pandoc — Documentation Image

- **Licence:** GPL-2.0-or-later
- **Source:** <https://github.com/jgm/pandoc>
- **Revision:** 3.10.2

### TeX Live (texlive-full) — Documentation Image

- **Licence:** LicenseRef-Distro-Bundle
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### Ghostscript — Documentation Image

- **Licence:** AGPL-3.0-or-later
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive. AGPL section 13 also reaches network-exposed use -- check how this component is exposed.

### GNU C Library locales (locales) — Documentation Image

- **Licence:** LGPL-2.1-or-later
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### GNU Wget — Documentation Image

- **Licence:** GPL-3.0-or-later
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### ca-certificates — Documentation Image

- **Licence:** MPL-2.0 AND GPL-2.0-or-later
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.

### less — Documentation Image

- **Licence:** GPL-3.0-or-later
- **Source:** <https://archive.ubuntu.com/ubuntu/>
- **Revision:** —
- Unmodified Ubuntu binary package. Source: `apt-get source <pkg>` on the matching release, or the Ubuntu source archive.


## Modified components

This project patches the following upstreams before redistributing them. Both the Apache-2.0 and the GPL families require that modification be stated.

- **sccache — Linux Images** — Built from source at the pinned git rev with a local patch series, NOT installed from a package manager. Patches: `windows/upstream/sccache-nvcc-quote-fix/`.
- **GStreamer — Windows Image** — The Windows build patches a GES symbol rename. Patches: `windows/scripts/patches/gstreamer/001-ges-commit-rename.patch`.
- **FFmpeg — Windows Image** — The Windows build patches configure to allow MSYS2 builds. Patches: `windows/scripts/patches/ffmpeg/001-allow-msys-builds.patch`.

Each patch is in this repository at the path shown, and travels with the corresponding source above.


---

## Flutter Web Frontend

Das Web-Frontend verwendet das Flutter SDK und mehrere Dart/Flutter-Pakete.
Die vollständigen Lizenztexte sind in der Anwendung unter
`/assets/NOTICES` gebündelt (automatisch vom Flutter-Build generiert).
