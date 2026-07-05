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

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.3.3, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.nvidia` (optional GPU layer) layers CUDA 13.3 + cuDNN 9.23 + TensorRT 11.1.0.106 on top of the base image and is tagged `windows-sdk`. If skipped, the base image is tagged `windows-sdk` directly (`docker tag`; the former no-op `Dockerfile.sdk` shim was removed) and downstream stages perform CPU-only builds (CUDA auto-detection falls back to `CPU-only build`). `windows/build.ps1` handles this automatically via its `-Gpu` switch.
- `windows/Dockerfile.toolchain` builds CPython 3.14 from source (matching the canonical versions.env).
- The **media stage fans out into three branch images built concurrently** by `windows/build.ps1`, then fans in:
  - `windows/Dockerfile.media-core` — the ONNX dependency chain, sequential: ONNX Runtime 1.27.0 (source build; CUDA EP enabled when the NVIDIA layer was used) → ONNX GenAI 0.14.0 (CMake+clang-cl, bypassing `build.py`; CUDA disabled at build time — GenAI uses ONNX Runtime's CUDA EP at runtime) → OpenCV 5.x (CMake+Ninja+clang-cl, CUDA auto-detected, detects the source-built ONNX Runtime) → FFmpeg `master` (MSVC toolchain via MSYS2 bash; `--enable-libonnxruntime` links FFmpeg's DNN filters against the source-built ONNX Runtime — note there is no separate `--enable-dnn` flag; DNN filters come with the backend).
  - `windows/Dockerfile.media-litert` — LiteRT 2.1.5 → LiteRT-LM 0.13.1 (independent of ONNX).
  - `windows/Dockerfile.media-tvm` — TVM 0.25.0 (independent; installs its Python wheel into the source-built CPython).
  - `windows/Dockerfile.media` — merge stage: `COPY --from` fan-in of the three branch trees into one `C:\runtime`, canonical env layout, then GStreamer 1.29.2 (Meson + clang-cl; auto-detects CUDA, OpenCV, ONNX and FFmpeg from the merged tree).
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

**Use Stevedore's bundled `docker.exe` for both builds and runs on this host.**
`nerdctl build` has broken DNS in BuildKit containers, and `nerdctl run` fails
before the container starts — it needs the Windows CNI `nat` plugin in
`C:\Program Files\containerd\cni\bin`, which is not installed (Stevedore does not
bundle it). `docker.exe` has no such dependency: Docker Engine provides NAT
networking natively, so both `docker build` and `docker run` just work.

| Tool | Build | Run |
|------|-------|-----|
| `"D:\Stevedore\bin\docker.exe"` | ✅ Working DNS | ✅ Works (NAT + DNS + process isolation) |
| `nerdctl` | ❌ Broken DNS | ❌ Fails: missing CNI `nat` plugin |

## Build Commands

Use the driver script from the repository root. It parses `linux/scripts/01-core/versions.env`
and passes every version as `--build-arg` (the Dockerfile ARG defaults are only
fallbacks), builds the stages in order, and applies the correct tags:

```powershell
# CPU lane (default): base -> tag sdk -> toolchain -> media -> final
.\windows\build.ps1

# GPU lane: base -> nvidia (CUDA + cuDNN + TensorRT, tagged sdk) -> toolchain -> media -> final
# Requires a TensorRT zip in windows/downloads/ (see AGENTS.md § TensorRT Setup).
.\windows\build.ps1 -Gpu

# Iterate on a single stage (layer cache makes this cheap):
.\windows\build.ps1 -Gpu -Stages media,final

# Deliberate clean rebuild (only when you really need it — this discards ALL layer
# caching and rebuilds everything from scratch, which takes many hours):
.\windows\build.ps1 -Gpu -NoCache
```

Docker layer caching is **on by default**: the Dockerfiles are ordered so that
editing one build script only rebuilds that script's stage and later ones.
`-Docker` overrides the docker.exe path (default: `$env:DOCKER_EXE`, then the
Stevedore install locations, then `docker` on PATH). Set
`KEEP_BUILD_ARTIFACTS=1` (e.g. via a temporary `ENV` line in a media
Dockerfile) to keep the `C:\temp\*-src` build trees for debugging; by default
each build script removes its source tree after installing so the trees don't
bloat the image layers.

### Build isolation and CPU parallelism

Hyper-V-isolated build containers (the Windows default) are given only **2
logical CPUs**, so `Get-BuildJobCount` — `min(ProcessorCount, memGB / memPerJob)`
— pins every in-container `ninja -j` to 2 no matter how many cores the host has.
That is the difference between a ~1-hour and a ~6-hour ONNX/CUDA compile, so the
heavy **media-core** stage does **not** use `docker build` at all.

**Why `docker build` can't be fixed on this host.** The classic Windows builder
offers no working CPU lever, all verified with a ~6-second repro (a Dockerfile
that writes a dummy layer):

| Attempt | Result |
|---|---|
| `docker build --cpu-count N` | rejected — "unknown flag" |
| `docker build --cpuset-cpus 0-15` | build fails |
| `docker build --isolation process` | container sees all 32 CPUs **but cannot commit any layer** — `hcsshim::ActivateLayer failed 0x20 "file used by another process"`, even for a 100 MB dummy layer |

The `ActivateLayer` failure is **not** Windows Defender, Windows Search, or
SysMain — all were ruled out by disabling each and re-running the repro. It is a
container-filter / Docker-Engine level defect with process isolation on this
host, so `--isolation process` is unusable for building (every build dies at the
first commit). Hyper-V isolation commits reliably but is stuck at 2 CPUs. **Do
not add `--isolation process` to any `docker build`.**

**The run+commit path (how media-core gets its cores).** `docker run` — unlike
`docker build` — *does* honor `--cpu-count` under Hyper-V (verified: `docker run
--isolation hyperv --cpu-count 16` → `NUMBER_OF_PROCESSORS=16`), and a Hyper-V
container commits fine via `docker commit`. So `build.ps1` builds media-core as:

1. `docker build` a thin **builder image** (`Dockerfile.media-core-builder`) —
   toolchain + all media-core scripts/patches, no heavy RUN, so its cheap COPY
   layers commit fine under Hyper-V.
2. `docker run --isolation hyperv --cpu-count $MediaCoreCpus --memory
   ${MediaMemoryGb}g <builder> powershell -File build-media-core-all.ps1` — runs
   the whole ONNX → GenAI → OpenCV → FFmpeg chain in one container at the full
   CPU count. `Get-BuildJobCount` sees `--cpu-count` as `ProcessorCount`, so ONNX
   compiles at `min(cpu-count, memGB/4)` (e.g. `-j14` at `-MediaCoreCpus 16
   -MediaMemoryGb 56`).
3. `docker commit` the container to `local/kataglyphis:windows-media-core` — a
   drop-in replacement for the old `Dockerfile.media-core` output.

`Invoke-MediaCoreRunCommit` in `build.ps1` implements this; tune it with
`-MediaCoreCpus` (default 16) and `-MediaMemoryGb` (default 48). The lighter
`docker build` stages (base, sdk, toolchain, the litert/tvm aux branches, the
merge/GStreamer stage) still run at 2 CPUs — acceptable, as they are far smaller
than the ONNX/CUDA compile.

**Trade-off:** a single `docker run` has no per-stage layer cache, so a mid-chain
failure re-runs the whole chain (unlike a multi-`RUN` `docker build`, where each
completed step is cached). The persistent **sccache** remote (below) covers the
recompilation, so in practice only uncached objects rebuild. Regression symptom
for the whole mechanism: `ninja -j2` in `out\windows-build-logs\media-core.log`,
or an `ActivateLayer` error on any commit.

### Rust toolchain (scoop only — never rustup)

Rust is provisioned **exclusively via scoop** (`setup-rust-toolchain.ps1` runs
`scoop install main/rust`). Do not install rustup in the base image. A
toolchain-less rustup (`rustup-init --default-toolchain none`) drops proxy shims
(`cargo.exe`, `rustc.exe`, …) into `CARGO_BIN`, and because `CARGO_BIN` sits ahead
of scoop's shim dir on `PATH`, those proxies win and fail at runtime with *"rustup
could not choose a version of cargo … no default is configured"* — which is what
made the Rust smoke test fail for a long time. `setup-scoop-tools.ps1` installs no
rustup and `Dockerfile.base` points `CARGO_HOME`/`CARGO_BIN` at a plain
`C:\Users\ContainerAdministrator\.cargo` (not a rustup path), so scoop's real
`cargo`/`rustc` resolve. If you need to "fix" Rust, fix the scoop path — do not
re-introduce rustup.

### Media fan-out and memory budgeting

The media branches build concurrently (branch logs land in
`out\windows-build-logs\*.err.log` — docker's `--progress=plain` output goes to
stderr). `-MediaMemoryGb` (default 48) caps the media-core branch and the
merge/GStreamer stage; `-AuxMemoryGb` (default 8) caps each of the two
auxiliary branches. Size them so `MediaMemoryGb + 2*AuxMemoryGb` roughly fits
host RAM. Each cap is forwarded as `MEMORY_LIMIT_GB` so the build scripts scale
their parallel job count to the container's cap instead of host RAM
(`BUILD_JOBS` overrides the heuristic outright). media-core builds via the
run+commit path (see § Build isolation and CPU parallelism) so it gets
`-MediaCoreCpus` CPUs; the aux branches are ordinary 2-CPU `docker build`s that
run concurrently underneath it. On memory-constrained hosts pass
`-SequentialMedia` to build the branches one after another.

### Persistent compile cache (sccache)

Without BuildKit cache mounts a container-local sccache cache dies with the
layer, so sccache stays **disabled unless a remote backend is configured**.
To enable a cross-build cache, run a small WebDAV server on the host and pass
its endpoint:

```powershell
# one-time host setup (any WebDAV-capable server works; dufs is a single binary)
scoop install dufs
mkdir C:\sccache-cache
dufs C:\sccache-cache -A -p 5000

# then build with the endpoint (use an IP reachable from inside containers,
# e.g. the host's LAN IP — not localhost)
.\windows\build.ps1 -Gpu -SccacheEndpoint http://192.168.1.10:5000
```

CMake-based builds (ONNX, GenAI, OpenCV, LiteRT, LiteRT-LM, TVM) then route
clang-cl through sccache; FFmpeg (MSVC/make) and GStreamer (Meson) are not
cached. The first build populates the cache; subsequent `--no-cache` rebuilds
and version bumps reuse unchanged object files.

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

### Fix 4: Use docker.exe for builds and runs (not nerdctl)

Always use Stevedore's `docker.exe` — `nerdctl build` lacks DNS resolution, and
`nerdctl run` fails on this host because the Windows CNI `nat` plugin is not
installed (`failed to create default network: needs CNI plugin "nat" to be
installed in CNI_PATH`). `docker.exe` needs no CNI plugin:

```powershell
"D:\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache -t local/kataglyphis:windows-base -f windows/Dockerfile.base .
```

## Running the Image

Run with **process isolation** to get the host's full CPU count (Hyper-V
isolation, the Windows default, exposes only 2 logical CPUs). Process isolation
is allowed here because the host build (26200) is ≥ the container base build
(`servercore:ltsc2025`, 26100):

```powershell
& "D:\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

Drop `--isolation process` to fall back to Hyper-V isolation (stronger boundary,
but capped at 2 CPUs on this host). NAT networking and DNS work in both modes.

## Smoke Testing

After building, run the container smoke test to verify all components:

```powershell
# Run smoke tests inside the built container
& "D:\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  powershell -File C:\temp\scripts\smoke-test-container.ps1
```

The smoke test validates 18 categories including CUDA Toolkit 13.3, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, TVM (source-built), FFmpeg (source-built with DNN/ONNX integration), and compiler integration.
