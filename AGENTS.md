# Kataglyphis-ContainerHub

Agent context file. Build commands live in `README.md`; deep architecture in
`docs/`. This file captures the **guardrails** an LLM agent must follow to avoid
regressing the build.

## Container Architecture

Three build lanes. Supported Linux arches: `amd64`, `arm64`, `riscv64`. Windows: `windows/amd64`.

| Dockerfile | FROM | Produces |
|------------|------|----------|
| `Dockerfile.base` | `ubuntu:26.04` | `:base` |
| `Dockerfile.toolchain` | `:base` | `:cross-compiler-amd64` |
| `Dockerfile.sdk` | `:cross-compiler-amd64` | `:cross-sdk-<arch>` |
| `Dockerfile.media` | `:cross-sdk-<arch>` | `:cross-media-<arch>` |
| `Dockerfile.android` | `:cross-media-<arch>` | `:cross-android-<arch>` |
| `Dockerfile.package` | `:base` + `:cross-android-<arch>` | `:latest-cross-package-<arch>` |
| `Dockerfile.torch` | `:latest-cross-package-<arch>` | `:latest-cross-<arch>` |
| `Dockerfile.nvidia` / `Dockerfile.amd` | `:cross-sdk-<arch>` | optional GPU layer |
| `windows/Dockerfile.*` | `windows/servercore:ltsc2025` | `:winamd64` |

### Windows-Specific Naming

The Windows lane uses local intermediate tags (`local/kataglyphis:windows-base`, `local/kataglyphis:windows-sdk`, `local/kataglyphis:windows-toolchain`, `local/kataglyphis:windows-media`) and publishes the final image as `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`. See `docs/windows-builds.md` § Build Commands for the full build sequence.

---

## Quick Reference

Build logs are written to `out/build-logs/` by passing `--log-dir` to the orchestrator scripts, or by piping manual `nerdctl build` output through `2>&1 | tee ./out/build-logs/<name>.log`.

Most common build commands:

```bash
# Full cross-build chain (base -> compiler -> sdk -> media -> android -> runtime)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Compiler image only (amd64-hosted, contains cross toolchains for all arches)
./linux/scripts/build-cross-compiler.sh --cross-targets amd64,arm64,riscv64 --log-dir ./out/build-logs

# Compiler with custom image repo (matches --image-repo on the orchestrator)
./linux/scripts/build-cross-compiler.sh --image-repo ghcr.io/myorg/kataglyphis_beschleuniger --push --log-dir ./out/build-logs

# Single cross stage — the canonical way to rebuild one stage for one arch.
# Handles parent digest pinning, build-arg assembly, log capture, and push.
# See docs/linux-cross-builds.md § "Single-Stage Builds" for details.
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push --log-dir ./out/build-logs
bash linux/scripts/build-cross-stage.sh --stage media --arch amd64 --push --log-dir ./out/build-logs
bash linux/scripts/build-cross-stage.sh --stage media --arch arm64 --push --log-dir ./out/build-logs

# Verify chain freshness without building
bash linux/scripts/build-cross-chain.sh --verify-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Standalone quick chain verification (lighter, no orchestrator flags)
bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64

# Print the full stage graph with tag names (no builds)
bash linux/scripts/build-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Dry-run: print all build commands without executing
bash linux/scripts/build-cross-chain.sh --dry-run --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Cheap packaging validation before publish (see docs/linux-cross-builds.md)
# Uses the `wrapper-smoke` target in Dockerfile.package

# Reinstall QEMU/binfmt after host reboot
nerdctl run --rm --privileged tonistiigi/binfmt --install all
```

> **See also:** [`docs/linux-cross-builds.md`](docs/linux-cross-builds.md) for the full stage graph, digest pinning, and single-stage build details. [`docs/linux-build-basics.md`](docs/linux-build-basics.md) for build fundamentals, caching, and troubleshooting.

### Windows Container Build (see `docs/windows-builds.md`)

All stages use **Ninja+clang-cl+lld-link** (not MSBuild/VS generator). Use Stevedore's `docker.exe` for builds (nerdctl has DNS issues in BuildKit on Windows).

```powershell
# Install Stevedore (prerequisite for Windows Containers)
winget install stevedore   # or: choco install stevedore

# === POST-INSTALL FIXES (apply once) ===
# 1. Exclude Stevedore from Windows Defender:
Add-MpPreference -ExclusionProcess "dockerd.exe"
Add-MpPreference -ExclusionPath "$env:ProgramFiles\Stevedore"
Add-MpPreference -ExclusionPath "$env:ProgramData\containerd"

# 2. Remove stale Docker Desktop daemon.json (if Docker Desktop was previously installed):
if (Test-Path "C:\ProgramData\docker\config\daemon.json") { Remove-Item "C:\ProgramData\docker\config\daemon.json" }

# 3. Change default runtime from hcsshim to runhcs:
sc config stevedore binPath="\"C:\Program Files\Stevedore\dockerd.exe\" --run-service --service-name stevedore --group docker-users --host npipe:////./pipe/dockerDesktopWindowsEngine --host npipe:////./pipe/docker_engine --containerd=npipe:////./pipe/containerd-containerd --default-runtime=io.containerd.runhcs.v1"
net stop stevedore /y
net start stevedore

# === BUILD SEQUENCE ===
# All commands use Stevedore's docker.exe (nerdctl has DNS issues on Windows BuildKit):

# Stage 1: Windows toolchain base (VS Build Tools 18, Scoop tools, LLVM 22)
"%ProgramFiles%\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache `
  -t local/kataglyphis:windows-base -f windows/Dockerfile.base .

# Stage 2: GPU SDK layer (CUDA 13.3 Toolkit + cuDNN 9.23, verified post-install)
"%ProgramFiles%\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache `
  -t local/kataglyphis:windows-sdk `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-base `
  -f windows/Dockerfile.sdk .

# Stage 3: CPython 3.14 built from source with ClangCL toolset (not MSVC v143)
"%ProgramFiles%\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache `
  -t local/kataglyphis:windows-toolchain `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-sdk `
  -f windows/Dockerfile.toolchain .

# Stage 4: Media layer — all source-built with Ninja+clang-cl:
#   - ONNX Runtime 1.26 (CPU-only; DirectML disabled due to VS 2026 STL hardening
#     + clang-cl incomplete-type incompatibility in DirectML helper headers)
#   - ONNX GenAI 0.13.1 (source-built via build.py with Ninja)
#   - OpenCV 5.x (with global AVX2/SSSE3/SIMD flags for clang-cl)
#   - LiteRT 2.1.5 (GPU delegate with Vulkan, XNNPACK, external CUDA delegate)
#   - LiteRT-LM 0.13.1 (on-device LLM inference, CUDA enabled, links LiteRT)
#   - GStreamer 1.29.1 (Meson+clang-cl, CUDA auto-detected)
# NOTE: ONNX Runtime AVX-512+AMX compilation with clang-cl needs ~48 GB RAM.
# Adjust --memory to your host's available resources (--cpu-quota not supported on Windows).
"%ProgramFiles%\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache --memory 48g `
  -t local/kataglyphis:windows-media `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-toolchain `
  -f windows/Dockerfile.media .

# Stage 5: Final developer image (VsDevCmd entrypoint)
"%ProgramFiles%\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-media `
  -f windows/Dockerfile .
```

### TensorRT Setup (Optional)

TensorRT is **not downloaded automatically** — it requires accepting NVIDIA's EULA. To include TensorRT:

1. Download from https://developer.nvidia.com/tensorrt (e.g., `TensorRT-10.10.0.39.Windows10.x86_64.cuda-*.zip`)
2. Place the zip in `windows/downloads/`
3. It will be auto-detected during the `Dockerfile.nvidia` build

If no zip is found, the build skips TensorRT gracefully (CUDA + cuDNN still work). The ORT build script auto-detects `$env:TENSORRT_ROOT` and enables the TensorRT EP when available.

### Windows Build Notes

| Component | Generator | Compiler | Notes |
|-----------|-----------|----------|-------|
| CPython 3.14 | `PCbuild\build.bat` | ClangCL (v145→ClangCL via Directory.Build.props) | Requires VS ClangCL toolset |
| ONNX Runtime 1.26 | Ninja | clang-cl, lld-link | DirectML disabled. CUDA enabled via CUDA 13.3 provider (includes crt/ workaround for nvcc). Patches build.ninja for MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM (`.asm` files). AVX-512+AMX compilation with clang-cl needs ~48 GB RAM — pass `--memory 48g` to docker build (--cpu-quota not supported on Windows). |
| ONNX GenAI 0.13.1 | `python build.py` | clang-cl (Ninja generator) | Source-built via `build.py --cmake_generator Ninja --cmake_extra_defines CMAKE_C_COMPILER=clang-cl CMAKE_CXX_COMPILER=clang-cl`. CUDA enabled. VsDevCmd environment loaded for MSVC STL headers. |
| OpenCV 5.x | Ninja | clang-cl, lld-link | Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2. CUDA auto-detected. Custom `CMAKE_AR` path fix. |
| LiteRT 2.1.5 | Ninja | clang-cl, lld-link | GPU delegate enabled (Vulkan + OpenCL backends). XNNPACK enabled. CUDA paths exposed for external delegate. |
| LiteRT-LM 0.13.1 | Ninja | clang-cl, lld-link | On-device LLM inference. CUDA support enabled when detected. Links against LiteRT from previous stage. |
| GStreamer 1.29 | Meson | clang-cl | Downloaded as tarball + subproject wraps. CUDA auto-detected. |

### Windows Scripts

| Script | Location | Purpose |
|--------|----------|---------|
| `build-onnx-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper |
| `build-onnx-genai-from-source.ps1` | `windows/scripts/` | Source build via `python build.py` with Ninja+clang-cl (not NuGet). Loads VsDevCmd environment, clones git tag, runs official `build.py --cmake_generator Ninja`. |
| `build-opencv-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch |
| `build-gstreamer-from-source.ps1` | `windows/scripts/` | Meson+clang-cl with wrap pre-extraction |
| `WindowsSourceBuild.Common.psm1` | `windows/scripts/modules/` | Reusable build helpers: `Invoke-GitClone`, `Invoke-CmakeConfigure`, `Invoke-CmakeBuild` |
| `setup-cuda.ps1` | `windows/scripts/` | Now includes cuDNN post-install verification (headers/libs/DLLs) |
| `smoke-test-container.ps1` | `windows/scripts/` | Comprehensive container validation (14 test categories) |

For detailed build commands, see `docs/windows-builds.md`.

### Orchestrator Stage Selection

```bash
# Resume mid-chain (e.g., after rebuilding compiler)
bash linux/scripts/build-cross-chain.sh --from-stage sdk --target-arches amd64,arm64,riscv64 --log-dir ./out/build-logs

# Build only one stage for one architecture
bash linux/scripts/build-cross-chain.sh --only media --target-arches arm64 --log-dir ./out/build-logs

# Build per-arch stages in parallel (faster on multi-core machines)
bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --parallel-archs --log-dir ./out/build-logs

# Build a single cross stage standalone (with digest-pinned parent when --push)
bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push --log-dir ./out/build-logs
```

### Runtime Helpers

```bash
# Build and push per-arch wrappers + manifest
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 \
  --artifact-image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:cross-android \
  --push \
  --log-dir ./out/build-logs

# Build local artifacts only (no push)
bash linux/scripts/build-runtime-artifacts.sh \
  --image-prefix ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 \
  --log-dir ./out/build-logs

# Dry-run: print what would be built without executing
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --dry-run \
  --log-dir ./out/build-logs

# Manifest repair (rebuild manifest from existing per-arch wrappers)
nerdctl manifest rm "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" >/dev/null 2>&1 || true
nerdctl manifest create "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-amd64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64" \
  "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-riscv64"
nerdctl manifest push --purge "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"

# Or use the helper: rebuild just the manifest (no image rebuilds)
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --manifest-only --push-manifest \
  --log-dir ./out/build-logs

# Shorthand: --repair is an alias for --manifest-only
bash linux/scripts/build-runtime-manifest.sh \
  --image ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  --target-arches amd64,arm64,riscv64 --repair --push-manifest \
  --log-dir ./out/build-logs
```

---

## Build Workflow

```
build-cross-chain.sh → base → compiler → sdk → media → android → runtime → manifest
```

Stages 1-5 run on `linux/amd64`. Stage 6 (runtime) runs on the target platform per architecture (QEMU/binfmt for foreign arches), delegating to `build-runtime-manifest.sh`. Each stage's registry digest is pinned and fed to the next as `--build-arg BASE_IMAGE=<repo>@sha256:<digest>` to prevent stale cache reuse. The stage graph is defined in `linux/scripts/01-core/stage-defs.sh`. See `docs/linux-cross-builds.md` for the full pipeline details.

The **Windows lane** follows a separate 3-stage build (`base → ai → final`) using nerdctl with Stevedore. See `docs/windows-builds.md` for the full build sequence and prerequisites.

### Prerequisites

- **nerdctl** with BuildKit backend
- **QEMU/binfmt** for foreign-architecture runtime builds. **Required before EVERY build** (registration is lost after host reboot):
  ```bash
  nerdctl run --rm --privileged tonistiigi/binfmt --install all
  ```
  Without this, riscv64 and arm64 builds under QEMU will fail with `exec format error` or silent exit code 1.
- **Registry access** (GHCR) for pushing intermediate and final images
- **Disk space**: ~50GB+ for full cross chain with all architectures
- **Python 3** for digest resolution (`registry-digest.py`)

### Windows Prerequisites (see `docs/windows-builds.md` § Prerequisites)

- **Stevedore** (`winget install stevedore` or `choco install stevedore`) — provides nerdctl + containerd for Windows Containers
- **Reboot** after Stevedore install to enable the Windows Containers feature
- **Docker Desktop or Rancher Desktop** can also be used with `docker` commands (swap `nerdctl` → `docker` in build commands)
- **DNS workaround**: Windows `nerdctl build` has broken DNS in BuildKit containers. Use Stevedore's bundled `docker.exe` for builds: `"%ProgramFiles%\Stevedore\bin\docker.exe" build`. `nerdctl run` works fine for running containers.

### Stevedore Fixes After Install

After installing Stevedore, apply these fixes exactly once:

1. **Exclude Stevedore from Windows Defender:**
   ```powershell
   Add-MpPreference -ExclusionProcess "dockerd.exe"
   Add-MpPreference -ExclusionPath "$env:ProgramFiles\Stevedore"
   Add-MpPreference -ExclusionPath "$env:ProgramData\containerd"
   Add-MpPreference -ExclusionPath "$env:ProgramData\nerdctl"
   Add-MpPreference -ExclusionPath "$env:ProgramData\Docker"
   ```

2. **Remove stale Docker Desktop daemon.json** (if Docker Desktop was previously installed):
   ```powershell
   if (Test-Path "C:\ProgramData\docker\config\daemon.json") { Remove-Item "C:\ProgramData\docker\config\daemon.json" }
   ```

3. **Change default runtime from hcsshim to runhcs** (the `com.docker.hcsshim.v1` shim binary is not shipped — use `io.containerd.runhcs.v1`):
   ```powershell
   sc config stevedore binPath="\"C:\Program Files\Stevedore\dockerd.exe\" --run-service --service-name stevedore --group docker-users --host npipe:////./pipe/dockerDesktopWindowsEngine --host npipe:////./pipe/docker_engine --containerd=npipe:////./pipe/containerd-containerd --default-runtime=io.containerd.runhcs.v1"
   net stop stevedore /y
   net start stevedore
   ```

4. **Verify** with:
   ```cmd
   "%ProgramFiles%\Stevedore\bin\docker.exe" run --rm mcr.microsoft.com/windows/servercore:ltsc2025 powershell -Command "Write-Host OK"
   ```

### Supported Platforms

| Component | Build platform | Target platforms |
|-----------|---------------|------------------|
| Cross lane (stages 1-5) | `linux/amd64` | `amd64`, `arm64`, `riscv64` (cross-compiled) |
| Runtime lane (stage 6) | Native or QEMU | `linux/amd64`, `linux/arm64`, `linux/riscv64` |
| Final manifest | N/A | Multi-arch: `amd64`, `arm64`, `riscv64` |
| Windows lane | `windows/amd64` | `windows/amd64` (native Windows Containers) |

### Expected Outputs

After a successful `build-cross-chain.sh` run:
- All cross-lane intermediate images pushed to GHCR
- Per-architecture wrapper images (`:latest-cross-<arch>`) pushed to GHCR
- Multi-arch manifest (`:latest-cross`) pushed to GHCR

---

## Repo Map

```
linux/scripts/
├── 01-core/             shared utilities (41 modules: versions.env, logging, platform, cross-env, cross-gcc, cross-meson, cross-apt, compiler-resolution, tag-naming, stage-defs, digest-pinning, build-helpers, cli-parsers, …)
├── 02-toolchain/        GCC, LLVM, Rust, Python, CMake, Vulkan builds
├── 03-03-media/            media library build scripts
│   ├── core/common.sh   single DRY bootstrap — sourced by every media script
│   ├── build/           per-library build scripts
│   │   ├── onnxruntime/   ONNX Runtime + GenAI (build/ steps, runtime/ pkgconfig, android/)
│   │   ├── litert/        LiteRT + TFLite C API (Critical Fix #2: abseil span.h copy in build-litert.sh)
│   │   ├── opencv/        OpenCV 5.x
│   │   ├── ffmpeg/        FFmpeg (build-ffmpeg.sh has fixed host compiler wrapper)
│   │   ├── gstreamer/     GStreamer monorepo (common/ has patch-gstreamer-sources.sh — Critical Fix #5)
│   │   └── libcamera/     libcamera
│   └── runtime/         artifact collection, runtime config, wheel repair, verification, media-env.sh (canonical ENV)
├── 04-runtime/          entrypoint + env scripts (gstreamer-env.sh, etc.)
├── 05-frameworks/       TVM, Torch, Flutter
└── 06-packaging/        assembly + smoke tests (smoke-media.sh, smoke-common.sh)
```

Top-level orchestrators: `build-cross-chain.sh`, `build-cross-compiler.sh`, `build-cross-stage.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`. Verification: `verify-cross-chain.sh`, `verify-critical-fixes.sh`, `verify-artifact-copy-parity.sh`.

`out/`: generated build artifacts (OCI layouts, rootfs exports). Excluded from Docker context via `.dockerignore`.

## Code Organization (key shared utilities)

- **Architecture resolution:** `platform.sh` → `canonical_target_arch()`, `canonical_resolve_arch()`. Single source of truth — never use ad-hoc `dpkg`/`uname -m`.
- **Architecture list resolution:** `artifact-common.sh` → `resolve_arch_list()`. Normalizes `TARGET_ARCHES` from canonical name + aliases with fallback. Use instead of 4-level fallback chains.
- **Dry-run guard:** `build-helpers.sh` → `is_dry_run()`, `_bool_truthy()`. Use instead of `[ "${DRY_RUN:-0}" -eq 1 ]`.
- **Module loading:** `modules.sh` → `source_modules_framework()`. Bootstrap pattern for sourcing 01-core.
- **Media bootstrap:** `03-media/core/common.sh` → `media_common_init <script_dir>`. Single DRY entry that sources the 01-core module framework. Every media build script sources this instead of duplicating a preamble block. Backward-compatible alias: `media_build_preamble_init`.
- **CC validation:** `validate-compilers.sh` → `_validate_cc_target()` (dumpmachine/ELF/cc1/link smoke).
- **Cross-chain tags:** `tag-naming.sh` → `cross_base_tag()`, `cross_compiler_tag()`, `cross_sdk_tag()`, `cross_media_tag()`, `cross_android_tag()`, runtime tag functions. Never construct tags manually.
- **Stage graph:** `stage-defs.sh` → `CROSS_STAGE_ORDER` (base→compiler→sdk→media→android→runtime), `RUNTIME_STAGE_ORDER` (base→package→wrapper). Pin init: `cross_stage_init_pins()`. Validation: `cross_stage_validate_graph()`. Cross→runtime handoff: `cross_stage_ensure_parent_available()`.
- **Chain verification:** `chain-verify.sh` → `verify_cross_chain_staleness()`, `describe_cross_chain()`.
- **Cross-stage build:** `cross-stage-build.sh` → `cross_stage_run()`, `cross_stage_build_and_push()`, `cross_stage_build_local()`, `cross_stage_resolve_parent_pin()`, `cross_stage_assemble_runtime_helper_args()`.
- **Runtime flow init:** `runtime-flow-common.sh` → `init_runtime_flow_defaults()` (sourced directly by the two runtime scripts).
- **Retry logic:** `logging.sh` → `retry <max> <sleep> <desc> <cmd...>`.
- **Mirror args:** `build-helpers.sh` → `append_mirror_build_args_from_env()`.
- **Version forwarding:** `version-forwarding.sh` → `append_version_build_args()` (auto-discovers from `versions.env`).
- **CMake cache/linker:** `cmake-cache-linker.sh` → `append_cmake_cache_linker_args <array_ref>`. Sourced by `03-media/core/common.sh` automatically.
- **Install deps preamble:** `cross-apt.sh` → `install_deps_preamble [packages...]`.
- **Media ENV reference:** `03-media/runtime/media-env.sh` is the canonical definition of PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH/GI_TYPELIB_PATH. `Dockerfile.media` and `Dockerfile.package` ENV blocks must stay in sync with this file.
- **Media artifact verification:** `03-media/runtime/verify-media-artifacts.sh` validates each media build stage produced output. Called from `Dockerfile.media` RUN steps after every library build. Stages: `onnxruntime-cpu`, `onnxruntime-genai`, `onnxruntime-gpu`, `onnxruntime-pkgconfig`, `litert`, `litert-headers`, `opencv`, `opencv-core`, `ffmpeg`, `gstreamer`, `libcamera`, `app-wheels`, `media-inputs`.
- **Runtime stage elements:** `Dockerfile.torch` final stage is canonical for COPY of runtime scripts, WORKDIR, VOLUME, ENTRYPOINT, CMD, HEALTHCHECK, kataglyphis user, OCI labels.
- **Builder functions:** `run_nerdctl_build()` is the canonical nerdctl build wrapper (`BUILDKIT_HOST` support). Use instead of ad hoc `nerdctl build`.

### Module Loading Order

`artifact-common.sh` sources 01-core modules in dependency order:
1. `common.sh` 2. `tag-naming.sh` 3. `stage-defs.sh` 4. `digest-pinning.sh` 5. `chain-verify.sh` 6. `build-helpers.sh` 7. `cross-stage-build.sh` 8. `context-management.sh` 9. `version-forwarding.sh` 10. `cli-parsers.sh` 11. `runtime-build-fns.sh` 12. `compiler-resolution.sh` 13. `parallel-loop.sh`.

`runtime-flow-common.sh` is sourced directly by `build-runtime-artifacts.sh` and `build-runtime-manifest.sh` (after `artifact-common.sh`).

## Cross Chain Stage Handoff (do not regress)

The cross lane is a sequence of separate `nerdctl build` invocations where each
stage does `FROM ${BASE_IMAGE}`: `base → compiler → sdk → media → android →
package → torch → wrapper → manifest`. The base-image handoff MUST NOT rely on a
bare mutable tag, or a stage can silently consume a STALE locally-cached image.

`--output type=image,name=...,push=true` pushes the new digest but does not
reliably refresh the local containerd tag; BuildKit's default `FROM` prefers an
already-present local image. So rebuilding `media` then building `android` can
quietly reuse the old `media`.

Rules:

1. When ANY base image in the registry tag hierarchy is replaced, rebuild every
   downstream image from the replaced stage, OR verify the downstream images
   already contain the new content (e.g. check `/opt/gcc-16.1.0-native-arm64`
   exists in the pinned sdk digest).
2. `--from-stage` only controls where execution starts; it does NOT update the
   base image of the first stage. If the previous stage's tag was built from a
   stale upstream, your rebuild inherits that staleness.
3. After pushing a rebuilt compiler image, run from `--from-stage sdk` (not
   `media`) so the sdk is built from the new compiler.
4. Do NOT use `--from-stage android` unless you verified the media tag already
   contains the compiler's content (e.g. native GCC directories).
5. Prefer `linux/scripts/build-cross-chain.sh` — it captures each stage's
   registry digest after push and feeds it to the next as
   `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`, making stale reuse
   structurally impossible. Supports `--target-arches`, `--from-stage`,
   `--to-stage`, `--only`.
6. When driving manual `nerdctl` loops, pass `--pull=true` on every stage that
   consumes a `BASE_IMAGE` tag (weaker defense; digest pinning preferred).
7. Capture pinnable digests with `nerdctl manifest inspect --verbose <tag>` →
   `.Descriptor.digest` (the `registry_pin_ref` helper in
   `01-core/digest-pinning.sh`). Do NOT use `RepoDigests`: BuildKit pushes a
   converted `docker.v2+json` manifest whose digest differs from the local OCI
   manifest and is not registry-resolvable.

## Five Critical Fixes To Maintain

Always preserve these. See `docs/linux-cross-builds.md` § "Five Critical Fixes".

1. **gst-python staged libpython** — `rewrite_staged_python_pc()` in `02-toolchain/python/build_python.sh`
2. **libcamera abseil** — copy `absl/types/span.h` in `03-media/build/litert/build-litert.sh`
3. **cross lib-dynload dangling symlinks** — `cp -a -L` + `find -xtype l` guard in `02-toolchain/python/build_python.sh`
4. **cross GCC architecture guard** — three-layer ELF + dumpmachine + cc1 smoke check in `Dockerfile.package`
5. **OpenCV 5 GStreamer compat** — `patch_gstreamer_opencv5_compat()` in `03-media/build/gstreamer/common/patch-gstreamer-sources.sh`

## Linux Build Rules

- Use `nerdctl` first on this host. `buildctl`/`ctr` commonly fail with permission errors.
- Keep both the QEMU/binfmt multi-platform lane and the cross-build lane working.
- `build-cross-compiler.sh` builds one `linux/amd64` compiler image with cross toolchains for all arches. Not a multi-arch compiler manifest.
- Do not remove LLVM/Clang features to make foreign-arch builds pass. Foreign-arch runtime images must keep source-built `clang 22.1.6` (not Ubuntu `clang 22.1.2`). Source-built `gcc 16.1.0` at `/opt/gcc-16.1.0` is the default `cc`/`c++` on all arches. On `arm64`/`riscv64`, GCC is cross-compiled (Canadian cross) and swapped in at the Android stage via `Dockerfile.android`.
- Preserve optional runtime payloads and LLVM normalization in `Dockerfile.package`. Do not drop `/usr/local/lib/onnxruntime-*`, LiteRT/TensorFlow headers, pkg-config files, or `/usr/local/llvm-target` handling.

## Dockerfile.media BuildKit Strategy

`Dockerfile.media` uses a parallel multi-stage DAG (BuildKit runs independent stages concurrently):

```
base ─┬─ onnxruntime ───────┐
      ├─ litert ────────────┤
      ├─ opencv ────────────┼─ media-inputs ─ gstreamer ─ libcamera ─ final
      ├─ ffmpeg ────────────┤
      └─ app-wheelhouse ────┘
```

- `--mount=type=cache` (apt/ccache/sccache/uv/pip/cargo) keyed per-arch via `id=...-${TARGETARCH}`, `sharing=locked`.
- `--mount=type=bind,readonly` for per-library build scripts — no COPY layer, so editing one library's scripts invalidates only that RUN, not downstream layers.
- `--mount=type=tmpfs` for `/tmp` scratch (no layer bloat).
- `COPY --link` for layer-parallel copying from independent build stages.
- Shared/common files (`core/common.sh`, `activate-cross-python.sh`, `verify-media-artifacts.sh`, 01-core helpers) are COPY'd in the `base` stage (rarely change → stable cache).
- Runtime scripts are COPY'd only in the `final` stage (must persist in the published image; build scripts are NOT shipped).

## Push And Publish Rules

- `build-runtime-artifacts.sh --push` pushes only final per-arch wrapper images.
- `build-runtime-manifest.sh --push` pushes wrappers + final manifest.
- `--push-all` only when explicitly requested (publishes `base`/`package` intermediates).
- Final cross release: `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`.
- Before rebuilding expensive foreign-arch wrappers, inspect remote tags with `nerdctl manifest inspect`. If wrappers exist remotely, recreate the manifest directly instead of rebuilding.

## Validation

- For runtime verification, check inside a container or inspect raw symlink targets. Do not use `readlink -f` against `out/linux-runtime/*/rootfs` (absolute symlinks resolve against host root).
- Confirm on all arches: `clang --version` reports `22.1.6`; `cc -dumpmachine` matches arch; `gcc --version` reports `16.1.0`; symlinks `cc/c++/gcc/g++ → /opt/gcc-16.1.0/bin/*`; `clang → /usr/local/llvm-target/bin/clang`; optional runtime payloads present.
- Use the `wrapper-smoke` target (see `docs/linux-build-basics.md`) for cheaper packaging validation before large publish runs.

## Host Constraints

| Symptom | Fix |
|---------|-----|
| `exec format error` | `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` |
| `no space left on device` | `nerdctl system prune -a -f && rm -rf out/local-*` |
| Stale downstream images | `--verify-chain` or rebuild from replaced stage |
| `registry_pin_ref` fails on fresh push | Uses `retry()` with 5 attempts; wait and retry |
| nerdctl DNS failure (Windows BuildKit) | Use Stevedore's `docker.exe build` instead |

### Common Failure Modes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `exec format error` | QEMU/binfmt not registered after host reboot | `sudo nerdctl run --rm --privileged tonistiigi/binfmt --install all` |
| `no space left on device` | Disk full from cached images/artifacts | `nerdctl system prune -a -f && rm -rf out/local-*` |
| Stale downstream images | Base image rebuilt but downstream not refreshed | Use `--verify-chain` or rebuild from replaced stage |
| `registry_pin_ref` fails on fresh push | Registry hasn't propagated the new manifest | Now uses `retry()` with 5 attempts; wait a few seconds and retry |
| Terminal freeze during long build | Build output overwhelms terminal | Use `setsid` / `disown` for very long builds |
| nerdctl DNS failure in build | BuildKit container can't resolve hostnames on Windows (`--dns` and `--network host` unsupported) | Use Stevedore's bundled `"%ProgramFiles%\Stevedore\bin\docker.exe" build` instead — same containerd backend, working DNS. `nerdctl run` works fine for running containers. |
| `hcsshim::ActivateLayer failed (0x20)` during build | Windows Defender scanning new layer files + containerd snapshot contention | Exclude `C:\ProgramData\containerd`, `C:\ProgramData\nerdctl` from Windows Defender. Or use `docker.exe` instead of `nerdctl` for builds (Docker's layer manager is more resilient). |
| Stevedore docker build: `runtime "com.docker.hcsshim.v1" binary not installed` | Service default runtime uses `hcsshim-v1` shim which isn't shipped | Change to `runhcs-v1`: `sc config stevedore binPath="..." --default-runtime=io.containerd.runhcs.v1"` (see docs/windows-builds.md § Fix 3) |
| Stevedore docker build: `failed to create TTRPC connection` | Shim binary mismatch (runhcs copied as hcsshim) | Remove the bad shim copy: `del "C:\Program Files\Stevedore\bin\containerd-shim-hcsshim-v1.exe"`. Apply Fix 3 instead. |
| Stevedore service won't start (1053 timeout) | Windows Defender blocking dockerd.exe OR stale daemon.json from Docker Desktop | `Add-MpPreference -ExclusionProcess "dockerd.exe"` AND delete `C:\ProgramData\docker\config\daemon.json` |
| `error getting credentials - err: exit status 1` | wincred credential helper fails because dockerd runs as SYSTEM without interactive session | OK to ignore for public images (MCR, GitHub). Use `nerdctl pull` instead for images that need auth, or set `"credsStore":""` in docker config. |
| `failed to extract layer ... failed to find link target` when pulling servercore | containerd windows snapshotter can't handle certain Windows reparse points in the layer | Use `docker.exe pull` instead of `nerdctl pull`. Docker Engine's layer extraction handles reparse points correctly. |

---

## Version Bumping

**Single source of truth: `linux/scripts/01-core/versions.env`.** Update it first.

`common.sh` and `artifact-common.sh` source `versions.env` at load time with `set -a`. Per-Dockerfile ARG defaults are safety nets and should match.

After changing versions:
1. `python3 docs/scripts/sync_versions.py --check` (run `--write` if drift)
2. `python3 docs/scripts/generate-website-licenses.py --write` (regenerate website /openSourceLicenses page)
3. Update `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`, and `AGENTS.md`
4. Verify ARG consistency: `bash linux/scripts/01-core/verify-arg-consistency.sh`
5. Rebuild affected stages (base→tooling, compiler→sdk, media→libs, android→SDK/NDK)

GPU constraints: when bumping CUDA/ROCm, verify driver requirements and that `UBUNTU_CODENAME` ARG in `Dockerfile.amd` matches a supported Ubuntu codename (default `plucky`/26.04).

## Development Rules

- Every script: `#!/usr/bin/env bash` + `set -euo pipefail`. Use `run()`/`run_quiet()` from `build-helpers.sh`.
- Source `artifact-common.sh` for shared utilities. Use `parse_shared_orchestrator_args()`/`parse_shared_runtime_args()`.
- Call `cross_stage_init_pins()` before the build loop.
- Use centralized helpers: `resolve_arch_list()`, `is_dry_run()`, `append_mirror_build_args_from_env()`, `append_version_build_args()`, `normalize_target_arches()`.
- New OS packages → `Dockerfile.base`. Compiler changes → `Dockerfile.toolchain`. SDK/frameworks → `Dockerfile.sdk`. Media libs → `Dockerfile.media` + `03-media/build/`. Android → `Dockerfile.android`. GPU → `Dockerfile.nvidia`/`Dockerfile.amd`.
- New architecture: add to `CROSS_DEFAULT_ARCHES` in `versions.env`, update cross-target lists, add triple mapping in `platform.sh`, add checksums in `versions.env`, verify QEMU/binfmt.

## Reusable Sphinx Theme Package

`docs/conf.py` delegates to `sphinx-kataglyphis-theme/sphinx_kataglyphis/__init__.py` (`setup_theme()`), which provides all shared Sphinx config and loads the canonical CSS from the package's `_static/` directory.

**For other projects** — copy the `sphinx-kataglyphis-theme/` directory alongside their repo root (or `pip install -e` in dev mode), then `conf.py` is just:

```python
from sphinx_kataglyphis import setup_theme
setup_theme(globals(), repository_url="https://github.com/org/repo")
```

The canonical CSS lives at `sphinx_kataglyphis/_static/css/custom.css` — edit that file to change the global look. The project's own `_static/css/` can hold additional per-project overrides.

To add the package to a new project's `sys.path`:
```python
_repo_root = Path(__file__).resolve().parent
sys.path.insert(0, str(_repo_root / "sphinx-kataglyphis-theme"))
```

## Documentation Maintenance

- If Dockerfiles or Linux helpers change, update `docs/linux-cross-builds.md`, `docs/linux-build-basics.md`, `docs/project-info.md`.
- If Windows Dockerfiles/scripts change, update `docs/windows-builds.md`.
- If version defaults change, run `python3 docs/scripts/sync_versions.py --write` then `python3 docs/scripts/generate-website-licenses.py --write`.
- If `custom.css` changes, update both `docs/_static/css/custom.css` (project) AND `sphinx-kataglyphis-theme/sphinx_kataglyphis/_static/css/custom.css` (canonical source). Run `python -m sphinx -b html docs/source docs/_build/html` to verify.
