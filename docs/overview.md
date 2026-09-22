# Project Overview

## About The Project

This project ships ready-to-build Dockerfiles for multiple targets in a single repo — plus the reusable tooling consumer projects build on: PowerShell modules (`windows/scripts/modules/`), bash libraries (`linux/scripts/lib/`: agentic-loop, app-runner), cross-platform shared data (`shared/agentic-loop/prompts/`), and CI composite actions (`.github/actions/`, see its README). The AGENTS.md Repo Map is the authoritative index of that half of the repo.

Container registry: [ghcr.io/kataglyphis/kataglyphis_beschleuniger](https://github.com/Kataglyphis/ANTfrastructure/pkgs/container/kataglyphis_beschleuniger) — published multi-arch images (Linux base, Torch add-on, webserver) and Windows build image.

## The architecture summary AGENTS.md carried

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

Three build lanes. Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows **host**:
`windows/amd64` only; Windows **targets**: `amd64` (image, production) and `arm64`
(cross-compiled artifact bundle — plumbing landed 2026-08-22 and the lane **BUILDS** since
2026-08-23; **nothing it produces has ever been RUN**, because Windows x64 has no ARM64 emulation,
so every arm64 signal is a static PE machine-type check. `Build-Buildkit.ps1 -TargetArch arm64`
just works: `torch` is dropped from the DEFAULT stage list with a notice (asking for it
**explicitly** still throws — it runs `uv sync`, which must execute the target interpreter).
Which components are through is tracked in the status banner of `docs/windows-cross-builds.md` —
do not restate it here, it moves). **Since 2026-08-26 the two lanes are at RUNTIME parity**: same
GStreamer plugin set (200 DLLs, six contract plugins, `gst-ptp-helper`), same media/inference
surface, and the same six python wheels — the TVM/IREE **runtime** python packages are
cross-built and assembled on this lane (#133). What stays amd64-only is a short, closed list:
CUDA/cuDNN/TensorRT, the TVM and IREE **compilers** (target-arch LLVM), LiteRT-LM, the torch app
stage — each named in the bundle by an `ABSENT-ON-ARM64.txt` / `COMPILER-ABSENT-ON-ARM64.txt`
marker, so a consumer never has to guess.

> **Never publish the arm64 lane's output with `--platform windows/arm64`.** It
> is a cross build out of the same `windows/amd64` container and its product is
> an artifact bundle, not a runnable image; that flag yields a manifest nothing
> can run. Why no arm64 Windows container can exist, and the lane's current
> coverage: [`docs/windows-cross-builds.md`](windows-cross-builds.md).
>
> **The base carries four arm64-only prerequisites, all installed UNCONDITIONALLY in the shared
> base** — never gate them on an arch ARG (that re-pays the chain's most expensive layers on every
> lane switch). They are warn-only in the base (`Test-Arm64Prereqs.ps1` reports on all four); the
> GStreamer build **throws** on the ones it actually needs. `WINDOWS_ARM64_STRICT=1` promotes the
> base checks to hard gates, but it must be passed as a build-arg (`-BuildArg
> WINDOWS_ARM64_STRICT=1`; a host env var alone does nothing) and it never reaches `Install-Vs.ps1`'s
> MSVC `lib\arm64` check (that RUN sits above the `ARG` declaration in `Dockerfile.base`). The
> prerequisite list, rationale and traps: `docs/windows-cross-builds.md`.

| Dockerfile | FROM | Produces |
|------------|------|----------|
| `Dockerfile.base` | `ubuntu:26.04` | `:base` (stable apt deps only; copies no project scripts — stays cache-stable) |
| `Dockerfile.toolchain` | `:base` | `:cross-compiler-amd64` |
| `Dockerfile.sdk` | `:cross-compiler-amd64` | `:cross-sdk-<arch>` |
| `Dockerfile.media` | `:cross-sdk-<arch>` | `:cross-media-<arch>` |
| `Dockerfile.android` | `:cross-media-<arch>` | `:cross-android-<arch>` |
| `Dockerfile.package` | `:latest-base-<arch>` + `:cross-android-<arch>` | `:latest-package-<arch>` |
| `Dockerfile.torch` | `:latest-package-<arch>` | `:latest-<arch>` (incl. the Hailo payload on amd64/arm64) |
| `Dockerfile.nvidia` / `Dockerfile.amd` | `:cross-sdk-<arch>` | optional GPU layer (CUDA or MIGraphX) |
| `windows/Dockerfile.*` | `windows/servercore:ltsc2025` | `:winamd64` (a **manifest** over `windows/amd64`; variants as `:winamd64-<variant>`), or `:winarm64` under `-TargetArch arm64` — the arm64 **artifact bundle**, still a `windows/amd64` image; **never publish it with `--platform windows/arm64`, and never as a manifest entry** ([`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags)) |

## Supported platforms, as AGENTS.md listed them

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

| Component | Build platform | Target platforms |
|-----------|---------------|------------------|
| Cross lane (stages 1-5) | `linux/amd64` | `amd64`, `arm64`, `riscv64` (cross-compiled) |
| Runtime lane (stage 6) | Native or QEMU | `linux/amd64`, `linux/arm64`, `linux/riscv64` |
| Final manifest | N/A | Multi-arch: `amd64`, `arm64`, `riscv64` |
| Windows lane | `windows/amd64` | `windows/amd64` (native Windows Containers) |
| Windows cross lane | `windows/amd64` | `arm64` artifact bundle (clang-cl `aarch64-pc-windows-msvc`; **not** a container image) |

## Expected outputs, as AGENTS.md listed them

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

After a successful `build-cross-chain.sh` run:
- All cross-lane intermediate images pushed to GHCR
- Per-architecture wrapper images (`:latest-<arch>`) pushed to GHCR
- Multi-arch manifest (`:latest`) pushed to GHCR

---

## Published Images and Tag Hints

| Image | Platforms | Tag examples | Description |
| --- | --- | --- | --- |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64, linux/arm64, linux/riscv64 | `latest` | The default **manifest** — the current cross-lane release, Hailo and (when staged) QNN included. Built via digest-pinned stage chain (`base → compiler → sdk → media → android → package → torch → wrapper → manifest`). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | the variant's arches (nvidia: linux/amd64 + linux/arm64; rocm: linux/amd64) | `latest-nvidia`, `latest-rocm` | A variant's **manifest** over all its arches, only for a stack that cannot ship in `latest` (`<variant>` is a feature, never an architecture). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | linux/amd64 | `cross-compiler-amd64`, `cross-sdk-<arch>`, `cross-media-<arch>`, `cross-android-<arch>` | Cross-lane intermediate images (amd64-hosted, cross-compiled for target arches). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | per-arch native | `latest-base-<arch>`, `latest-package-<arch>`, `latest-<arch>`, `latest-<variant>-<arch>` | Runtime lane per-arch **wrapper** images the manifests are assembled from (internal). |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger:webserver | linux/amd64, linux/arm64 (as pushed) | `webserver`, `webserver-<git-sha>` | Minimal nginx static webserver image. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | windows/amd64 | `winamd64` | Windows Server Core 2025 build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX — a **manifest** over `windows/amd64`; variants as `:winamd64-<variant>`. |
| ghcr.io/kataglyphis/kataglyphis_beschleuniger | windows/amd64 (arm64 **bundle**) | `winarm64` | The arm64 cross artifact bundle: a `windows/amd64` image carrying the aarch64 payload. Not a platform, not a manifest entry — see [`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags). |

## Images in This Repository

- 🔥 `linux/Dockerfile.torch`: Final Linux wrapper image — Torch/Python layer + runtime scripts + entrypoint.
- 🌐 `linux/webserver/Dockerfile`: Minimal nginx static webserver (config at `linux/webserver/nginx.conf`).
- 🪟 `windows/Dockerfile.base`, `windows/Dockerfile.nvidia` (optional GPU layer), `windows/Dockerfile.toolchain-builder`, `windows/Dockerfile.media-merge-builder` (+ per-branch media builders), `windows/Dockerfile` (driven by `windows/Build-Buildkit.ps1`): Windows Server Core 2025 build image with MSVC Build Tools, LLVM/Clang, Vulkan SDK, Rust, Flutter, WiX.

## Linux Image Chain

The Linux images build as a chain of separate Dockerfiles (one per stage, for layer caching), ending in the `linux/Dockerfile.torch` wrapper. This page does not enumerate the stages: the authoritative per-stage table (Dockerfile → FROM → produced tag) is AGENTS.md § Container Architecture, and the README's repo tree carries the annotated per-stage contents. Per-stage mechanics live in [Linux build basics](linux-build-basics.md) and [Linux cross builds](linux-cross-builds.md) — including `Dockerfile.sdk`'s reuse for amd64-hosted cross SDK artifact builds via `BUILD_MODE=cross` and `Dockerfile.package`'s clean-base runtime assembly in both native and cross flows.

## What You Get

- ✅ Multi-arch builds via buildx/nerdctl.
- 🎮 Vulkan + toolchains ready for GPU passthrough.
- 🧠 Torch/Python runtime included in the final Linux image chain.
- 📡 Ready-to-serve static web content with nginx.

## Key Features

| Category | Feature | Status |
| --- | --- | :---: |
| Cross-build | Multi-arch cross toolchain (amd64, arm64, riscv64) | ✔️ |
| Cross-build | Digest-pinned stage handoff | ✔️ |
| Cross-build | Runtime packaging via QEMU/binfmt | ✔️ |
| GPU acceleration | NVIDIA CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, cuDNN, TensorRT | ✔️ |
| GPU acceleration | DirectML (Windows, vendor-agnostic — ONNX Runtime + GenAI DML EP) | ✔️ |
| GPU acceleration | AMD MIGraphX | ✔️ |
| GPU acceleration | Vulkan SDK <!-- generated:vulkan -->1.4.357.0<!-- /generated:vulkan --> | ✔️ |
| Media | ONNX Runtime <!-- generated:onnx -->1.30.0<!-- /generated:onnx --> | ✔️ |
| Media | GStreamer <!-- generated:gstreamer -->1.29.2<!-- /generated:gstreamer -->, OpenCV <!-- generated:opencv -->5.0.0<!-- /generated:opencv -->, LiteRT | ✔️ |
| Media | libcamera, FFmpeg | ✔️ |
| Compiler | GCC <!-- generated:gcc -->16.2.0<!-- /generated:gcc -->, LLVM/Clang <!-- generated:llvm -->23.1.1<!-- /generated:llvm --> | ✔️ |
| Language runtime | Python <!-- generated:python -->3.14.7<!-- /generated:python -->, Node.js <!-- generated:node -->26.9.0<!-- /generated:node --> | ✔️ |
| Android | SDK <!-- generated:android_sdk -->15859902<!-- /generated:android_sdk -->, NDK <!-- generated:android_ndk -->29.0.14206865<!-- /generated:android_ndk --> | ✔️ |
| Windows | MSVC Build Tools, CUDA <!-- generated:cuda -->13.4<!-- /generated:cuda -->, GStreamer <!-- generated:gstreamer -->1.29.2<!-- /generated:gstreamer --> | ✔️ |
| Windows | Vulkan SDK <!-- generated:vulkan -->1.4.357.0<!-- /generated:vulkan -->, ONNX Runtime <!-- generated:onnx -->1.30.0<!-- /generated:onnx --> | ✔️ |
| Windows-on-ARM | Cross-built **artifact bundle** (`:winarm64` labels a `windows/amd64` image — never publish it as `windows/arm64`): media + inference measured at runtime parity with amd64 on 2026-08-26 (statically verified only; HEAD carries unvalidated changes since). **CUDA/cuDNN and HailoRT cross-built since 2026-09-20/21 (#176 + Phase 3: arm64 toolkit payload, ORT CUDA EP, GenAI CUDA, OpenCV CUDA modules, TVM CUDA, `libhailort.dll` + `hailortcli`, all 0xAA64; running them needs an arm64 device).** Not included: classic TensorRT, TAPPAS, the pyhailort wheel, the TVM/IREE compilers, LiteRT-LM, the torch app. [Details](windows-cross-builds.md) | ✔️ |

**Legend:** ✔️ completed · 🔶 in progress · ❌ not started

See [Third-Party Licenses](third-party-licenses.md) for license information on bundled software.


