# Windows Build Image

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

## Source Patch Policy

This repository applies a **patch-first** policy to upstream sources on the Windows lane. **Default: extract upstream modifications into a reviewable `.patch` file** under `windows/scripts/patches/<component>/NNN-<slug>.patch`, applied via the canonical idempotent helper `Invoke-SourcePatch` (`windows/scripts/modules/WindowsSourceBuild.Common.psm1`). Every `.patch` file:

- Is a standard `git diff` / unified diff (`a/`/`b/` prefix, `-p1` strip).
- Applies idempotently: `Invoke-SourcePatch` runs `git apply --reverse --check` first and skips if already applied; falls back to `patch.exe -p1` for non-git tarball extractions; throws loudly with the patch file's first 40 lines on failure.
- Targets a *pinned* upstream version (e.g. the file header references the git tag in `linux/scripts/01-core/versions.env`).

**Exceptions (inline patches are intentional and documented):**

1. **Generated build files** — patches targeting FFmpeg's generated `ffbuild/*.mak`, `library.mak`, `subdir.mak`, `Makefile`, `ffbuild/config.mak` (post-configure output; content varies per `./configure` invocation) AND the `Update-NinjaFile` calls in `build-onnx-from-source.ps1` / `build-onnx-genai-from-source.ps1` that strip MSVC-only flags from CMake-generated `build.ninja` (same family — generated content varies per CMake configure). Inline `-replace` on invariant sub-sequences (`-showIncludes`, `EXTRALIBS-lib*=`, `/experimental:external`, `/Qspectre`) is the canonical form for both.

2. **Fetched third-party deps whose pinned version floats** — `Replace-CppKeywordAlternatives` walks CUTLASS headers fetched by ONNX Runtime's ExternalProject at configure time, AND the companion `_udiv128 → udiv128` substitution on `cutlass/uint128.h` (clang-cl lacks the MSVC-only intrinsic). The CUTLASS fetched SHA varies with the provider's `cutlass-src` ExternalProject pointer; a static `.patch` against a pinned tag would silently rot. The helper form + the targeted inline regex are canonical.

3. **Multi-file conditional substitutions** — LiteRT's `proto/CMakeLists.txt` disable loop (`build-litert-from-source.ps1`) walks ~17 files under `$tfliteSrc` and skips files whose content already lacks `protobuf_generate|protoc`. A static `.patch` against a pinned LiteRT tag cannot express the per-file predicate and would only cover a fraction of the proto directories. Similarly, the OpenCV mlas `<cstring>` prepend loop (`build-opencv-from-source.ps1`) walks every `3rdparty/mlas/**/*.cpp` and skips files that already include `<cstring>` — same canonical-form rationale.

4. **Installed toolchain headers (not the upstream source tree)** — `build-onnx-genai-from-source.ps1` patches the installed MSVC STL `experimental/coroutine` and `yvals_core.h`. The MSVC toolset version floats (resolved via `Get-MsvcToolsRoot`), so a static `.patch` against a pinned MSVC build would only work for one toolset version.

5. **Binary byte-filter edits** — `onnxruntime.rc` non-ASCII byte stripping (`-le 127`) is a byte filter, not a textual diff. Not expressible as unified diff.

6. **Single-file regex edits on aggressively-changing-generated-as-schema upstream files** — Two single-file regex edits are kept inline *not* because a `.patch` couldn't be authored today, but because the upstream context drifts enough between minor releases (`protobuf_generate(...)` argument shape on LiteRT-LM's `runtime/proto/CMakeLists.txt`; `add_extra_compiler_option(-include cstring)` plus surrounding CMake add-to-flags lines on OpenCV's `cmake/OpenCVCompilerOptions.cmake`) that a static `.patch` would need re-generation on every tag bump:
   - `build-litert-lm-from-source.ps1:44-48` — `runtime/proto/CMakeLists.txt` regex substitutions
   - `build-opencv-from-source.ps1:48-52` — `cmake/OpenCVCompilerOptions.cmake` `-include cstring` removal

Every inline substitution in a build script carries a `# Inline patch (kept inline, NOT a .patch file):` block comment explaining the canonical-form rationale. The current `.patch` inventory:

| Component | Patch | Upstream target | Purpose |
|-----------|-------|-----------------|---------|
| FFmpeg | `001-allow-msys-builds.patch` | `configure` | Replace `die` with `echo` for MSYS2 build env |
| FFmpeg | `002-replacement-makedef.patch` | `makedef` | Read `.ver` directly (avoid Windows cmdline length limit) |
| GStreamer | `001-ges-commit-rename.patch` | `subprojects/gst-editing-services/ges/ges-validate.c` | `#define _commit ges__commit` to dodge `-FIio.h` macro collision |
| ONNX Runtime | `001-softmax-clangcl-keywords.patch` | `core/providers/cuda/math/softmax.{cc,h}` | Replace `and`/`or`/`not` keyword alternatives with `&&`/`||`/`!` for clang-cl |
| ONNX Runtime | `002-disable-cuda-pch.patch` | `cmake/onnxruntime_providers_cuda.cmake` | Disable CUDA EP `target_precompile_headers` (CUDA 13.x CCCL broken with clang-cl) |

When bumping any upstream version, audit these `.patch` files (`git apply --reverse --check` against the new tag) before letting the orchestrator loose. If a patch no longer applies, regenerate with `git diff` against the new tag and update the inventory above.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into five staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.3.3, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.sdk` is a generic (non-GPU) SDK shim layer between base and the optional GPU layer. No CUDA/cuDNN are installed here; it only initializes the SDK directory layout.
- `windows/Dockerfile.nvidia` (optional GPU layer) layers CUDA 13.3 + cuDNN 9.23 + TensorRT 11.1.0.106 on top of the SDK shim. Build this stage **instead of** `Dockerfile.sdk` to produce a GPU-enabled image. If skipped, downstream stages will perform CPU-only builds (CUDA auto-detection falls back to `CPU-only build`).
- `windows/Dockerfile.toolchain` builds CPython 3.14 from source (matching the canonical versions.env).
- `windows/Dockerfile.media` layers the AI/media stack in dependency order so each finds the previous: ONNX Runtime 1.27.0 (source build; CUDA EP enabled when the NVIDIA layer was used), ONNX GenAI 0.14.0 (source build via CMake+clang-cl, bypassing `build.py`; CUDA is disabled at build time because clang-cl cannot compile cuRAND host headers — GenAI uses ONNX Runtime's CUDA EP at runtime), OpenCV 5.x (CMake+Ninja+clang-cl, CUDA auto-detected), LiteRT 2.1.5 (GPU delegate enabled via Vulkan/OpenCL + external CUDA delegate), LiteRT-LM 0.13.1 (on-device LLM inference; CUDA auto-detected), TVM 0.25.0 (Ninja+clang-cl; auto-detects CUDA/Vulkan/LLVM; builds a Python wheel), FFmpeg `main` branch (MSVC toolchain via MSYS2 bash; `--enable-dnn --enable-libonnx` links FFmpeg's DNN filter against the source-built ONNX Runtime so ONNX models can run inside `ffmpeg` filters), GStreamer 1.29.2 (from source via Meson + clang-cl, with CUDA auto-detected).
- `windows/Dockerfile` produces the final developer image from the media image (VsDevCmd entrypoint).

## Prerequisites

Install [Stevedore](https://github.com/slonopotamus/stevedore):

```powershell
# WinGet (recommended)
winget install stevedore

# WinGet — custom install directory (e.g. D: NVMe dev drive)
winget install stevedore --custom="INSTALLDIR=D:\Stevedore"

# or Chocolatey
choco install stevedore
```

If you used a custom `INSTALLDIR`, substitute `D:\Stevedore\bin\docker.exe` for `"%ProgramFiles%\Stevedore\bin\docker.exe"` in all commands below.

Reboot after installation. This enables the Windows Containers feature and adds your user to the `docker-users` group.

**DNS note:** Windows `nerdctl build` has broken DNS in BuildKit containers.  
Use Stevedore's bundled `docker.exe` for all builds below:

| Tool | Build | Run |
|------|-------|-----|
| `"D:\Stevedore\bin\docker.exe" build` | ✅ Working DNS | N/A |
| `nerdctl build` | ❌ Broken DNS | N/A |
| `nerdctl run` | N/A | ✅ Works |

## Build Commands

Run from the repository root in order. Update `$DOCKER` to match your Stevedore install path (default: `D:\Stevedore\bin\docker.exe`; adjust if different):

```powershell
$DOCKER = "D:\Stevedore\bin\docker.exe"

# Stage 1: toolchain base (VS, Scoop, LLVM, Rust)
& $DOCKER build --no-cache --progress=plain `
  -t local/kataglyphis:windows-base `
  -f windows/Dockerfile.base .

# Stage 2 — choose ONE of the two SDK variants:
#   (a) GPU variant — build Dockerfile.nvidia to get CUDA 13.3 + cuDNN + TensorRT
#   (b) CPU variant — build Dockerfile.sdk (generic shim, no GPU) [default below]
# Both variants produce the `local/kataglyphis:windows-sdk` tag so downstream stages
# pick up whichever variant you built.

# Stage 2a (GPU variant, optional): NVIDIA GPU SDK (CUDA + cuDNN + TensorRT)
# Requires a TensorRT zip in windows/downloads/ (see AGENTS.md § TensorRT Setup).
# & $DOCKER build --no-cache --progress=plain `
#   -t local/kataglyphis:windows-sdk `
#   --build-arg BASE_IMAGE=local/kataglyphis:windows-base `
#   -f windows/Dockerfile.nvidia .

# Stage 2b (CPU variant, default): generic non-GPU SDK shim
& $DOCKER build --no-cache --progress=plain `
  -t local/kataglyphis:windows-sdk `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-base `
  -f windows/Dockerfile.sdk .

# Stage 3: Python toolchain (CPython 3.14 from source)
& $DOCKER build --no-cache --progress=plain `
  -t local/kataglyphis:windows-toolchain `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-sdk `
  -f windows/Dockerfile.toolchain .

# Stage 4: media libs (ONNX, GenAI, OpenCV, LiteRT, LiteRT-LM, TVM, FFmpeg, GStreamer)
# Build order: ONNX -> GenAI -> OpenCV -> LiteRT -> LiteRT-LM -> TVM -> FFmpeg -> GStreamer
# NOTE: ONNX Runtime AVX-512+AMX compilation with clang-cl needs ~48 GB RAM.
# Adjust --memory to your host's available resources (--cpu-quota not supported on Windows).
& $DOCKER build --no-cache --progress=plain --memory 48g `
  -t local/kataglyphis:windows-media `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-toolchain `
  -f windows/Dockerfile.media .

# Stage 5: final developer image
& $DOCKER build --no-cache --progress=plain `
  -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  --build-arg BASE_IMAGE=local/kataglyphis:windows-media `
  -f windows/Dockerfile .
```

> **Note (.dockerignore):** The repo `.dockerignore` must NOT contain a `windows/` exclusion — the Windows Dockerfiles COPY from the `windows/scripts/` directory within the build context. If `windows/` is added to `.dockerignore`, the COPY steps will fail with "file not found in build context". This exclusion is safe for Linux builds (which use `linux/` context) but breaks Windows builds.

## Stevedore Setup Fixes

After installing Stevedore, apply these post-install fixes. They are the canonical source and are maintained in lockstep with the project's CI requirements.

### Fix 1: Remove stale Docker Desktop daemon.json

If Docker Desktop was previously installed, its daemon config at `C:\ProgramData\docker\config\daemon.json` may specify a hosts pipe (`docker_engine_windows`) that conflicts with Stevedore's `docker_engine` pipe. Remove it:

```powershell
if (Test-Path "C:\ProgramData\docker\config\daemon.json") { Remove-Item "C:\ProgramData\docker\config\daemon.json" }
```

### Fix 2: Change default runtime from hcsshim to runhcs

Stevedore's service defaults to the `com.docker.hcsshim.v1` runtime, but only the `io.containerd.runhcs.v1` shim binary (`containerd-shim-runhcs-v1.exe`) ships with Stevedore. Update the service binary path:

```powershell
sc config stevedore binPath="\"C:\Program Files\Stevedore\dockerd.exe\" --run-service --service-name stevedore --group docker-users --host npipe:////./pipe/dockerDesktopWindowsEngine --host npipe:////./pipe/docker_engine --containerd=npipe:////./pipe/containerd-containerd --default-runtime=io.containerd.runhcs.v1"
```

Then restart:

```powershell
net stop stevedore /y
net start stevedore
```

### Fix 3: Windows Defender exclusions for containerd data

Add exclusions for containerd's snapshot directories (prevents hcsshim layer commit errors — `hcsshim::ActivateLayer failed (0x20)`):

```powershell
Add-MpPreference -ExclusionPath "C:\ProgramData\containerd"
Add-MpPreference -ExclusionPath "C:\ProgramData\nerdctl"
Add-MpPreference -ExclusionPath "C:\temp"
```

### Fix 4: Use docker.exe for builds (not nerdctl)

Always use Stevedore's `docker.exe` for builds — `nerdctl build` lacks DNS resolution:

```powershell
"D:\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache -t local/kataglyphis:windows-base -f windows/Dockerfile.base .
```

`nerdctl run` works fine for running containers (DNS resolution is only broken during BuildKit builds, not for runs).

## Running the Image

```powershell
nerdctl run --memory 48g -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

## Smoke Testing

After building, run the container smoke test to verify all components:

```powershell
# Run smoke tests inside the built container
nerdctl run --memory 48g -it --rm `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  powershell -File C:\temp\scripts\smoke-test-container.ps1
```

The smoke test validates 18 categories including CUDA Toolkit 13.3, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, TVM (source-built), FFmpeg (source-built with DNN/ONNX integration), and compiler integration.
