# Windows Build Image

> **Important (Antivirus):** On Windows, **exclude your development folder from antivirus scanning**. Real-time protection can lock files during builds (especially during CMake FetchContent and cargo builds), causing intermittent failures with errors like "Failed to remove directory" or "(os error 32)". Add your project directory to your antivirus exclusion list.

## Source Patch Policy

This repository applies a **patch-first** policy to upstream sources on the Windows lane. **Default: extract upstream modifications into a reviewable `.patch` file** under `windows/scripts/patches/<component>/NNN-<slug>.patch`, applied via the canonical idempotent helper `Invoke-SourcePatch` (`windows/scripts/modules/WindowsSourceBuild.Common.psm1`). Every `.patch` file:

- Is a standard `git diff` / unified diff (`a/`/`b/` prefix, `-p1` strip).
- Applies idempotently: `Invoke-SourcePatch` runs `git apply --reverse --check` first and skips if already applied; falls back to `patch.exe -p1` for non-git tarball extractions; throws loudly with the patch file's first 40 lines on failure.
- Targets a *pinned* upstream version (e.g. the file header references the git tag in `linux/scripts/01-core/versions.env`).

**Exceptions (inline patches are intentional and documented):**

1. **Generated build files** — patches targeting FFmpeg's generated `ffbuild/*.mak`, `library.mak`, `subdir.mak`, `Makefile`, `ffbuild/config.mak` (post-configure output; content varies per `./configure` invocation) AND the `Update-NinjaFile` calls in `build-onnx-from-source.ps1` / `build-onnx-genai-from-source.ps1` that strip MSVC-only flags from CMake-generated `build.ninja` (same family — generated content varies per CMake configure). Inline `-replace` on invariant sub-sequences (`-showIncludes`, `EXTRALIBS-lib*=`, `/experimental:external`, `/Qspectre`) is the canonical form for both.

2. **Fetched third-party deps whose pinned version floats** — `Edit-CppKeywordAlternatives` walks CUTLASS headers fetched by ONNX Runtime's ExternalProject at configure time, AND the companion `_udiv128 → udiv128` substitution on `cutlass/uint128.h` (clang-cl lacks the MSVC-only intrinsic). The CUTLASS fetched SHA varies with the provider's `cutlass-src` ExternalProject pointer; a static `.patch` against a pinned tag would silently rot. The helper form + the targeted inline regex are canonical.

3. **Multi-file conditional substitutions** — LiteRT's `proto/CMakeLists.txt` disable loop (`build-litert-from-source.ps1`) walks ~17 files under `$tfliteSrc` and skips files whose content already lacks `protobuf_generate|protoc`. A static `.patch` against a pinned LiteRT tag cannot express the per-file predicate and would only cover a fraction of the proto directories. Similarly, the OpenCV mlas `<cstring>` prepend loop (`build-opencv-from-source.ps1`) walks every `3rdparty/mlas/**/*.cpp` and skips files that already include `<cstring>` — same canonical-form rationale.

4. **Installed toolchain headers (not the upstream source tree)** — `build-onnx-genai-from-source.ps1` patches the installed MSVC STL `yvals_core.h` (wrapping the single `_EMIT_STL_ERROR` define in `#ifdef __clang__`, which no-ops *every* STL error code — STL1009/1010/1011, etc. — under clang-cl, so no per-header patch such as one for `<experimental/coroutine>` is needed). The MSVC toolset version floats (resolved via `Get-MsvcToolsRoot`), so a static `.patch` against a pinned MSVC build would only work for one toolset version; the edit is guarded by a drift-assertion that fails the build loudly if a future toolset changes the macro's format.

5. **Binary byte-filter edits** — `onnxruntime.rc` non-ASCII byte stripping (`-le 127`) is a byte filter, not a textual diff. Not expressible as unified diff.

6. **Single-file regex edits on aggressively-changing generated-as-schema upstream files** — The OpenCV `add_extra_compiler_option(-include cstring)` removal (plus surrounding CMake add-to-flags lines on `cmake/OpenCVCompilerOptions.cmake`) is kept inline *not* because a `.patch` couldn't be authored today, but because the upstream context drifts enough between minor releases that a static `.patch` would need re-generation on every tag bump:
   - `build-opencv-from-source.ps1` — `cmake/OpenCVCompilerOptions.cmake` `-include cstring` removal

Every inline substitution in a build script carries a `# Inline patch (kept inline, NOT a .patch file):` block comment explaining the canonical-form rationale. The current `.patch` inventory:

| Component | Patch | Upstream target | Purpose |
|-----------|-------|-----------------|---------|
| FFmpeg | `001-allow-msys-builds.patch` | `configure` | Replace `die` with `echo` for MSYS2 build env |
| GStreamer | `001-ges-commit-rename.patch` | `subprojects/gst-editing-services/ges/ges-validate.c` | `#define _commit ges__commit` to dodge `-FIio.h` macro collision |
| ONNX Runtime | `001-softmax-clangcl-keywords.patch` | `core/providers/cuda/math/softmax.cc` | Change the one real ISO-646 `or` → `\|\|` on the dispatch `if` (clang-cl in MS-compat mode treats `or` as an identifier); comments left as upstream |
| ONNX Runtime | `002-disable-cuda-pch.patch` | `cmake/onnxruntime_providers_cuda.cmake` | Disable CUDA EP `target_precompile_headers` (CUDA 13.x CCCL broken with clang-cl) |
| ONNX Runtime | `003-dml-clangcl-compat.patch` | DirectML EP (5 files under `core/providers/dml/`) | clang-cl + `USE_DML=ON`: out-of-line `AbstractOperatorDesc` members past `OperatorField` (incomplete-type), drop the `.##Z` token-paste, widen `Dispatch<uint32_t>` → `size_t` |
| OpenCV | `001-cmake-clang-cl-compat.patch` | `CMakeLists.txt` + `cmake/FindONNX.cmake` | CMP0146/CMP0148 OLD→NEW + clang-cl/CUDA detection compat |
| OpenCV (contrib) | `001-cudev-windows-llp64.patch` | `cudev/.../common.hpp` | Add `ulong`/`longlong`/`ulonglong` typedefs for Windows LLP64 |

`ffmpeg/makedef` is **not** a patch — it is a whole-file replacement script staged over FFmpeg's `makedef` (a byte swap, not a diff), so it is not in the table above.

When bumping any upstream version, audit these `.patch` files before letting the orchestrator loose: run `windows/scripts/tests/Test-PatchesApplyClean.ps1`, which clones each pinned upstream and runs the exact `git apply --check` the build uses (see `windows/scripts/patches/README.md`). If a patch no longer applies, regenerate with `git diff` against the new tag and update the inventory above.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.4.0, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.nvidia` (optional GPU layer) layers CUDA 13.3 + cuDNN 9.23 + TensorRT 11.1.0.106 on top of the base image and is tagged `windows-sdk`. If skipped, the base image is tagged `windows-sdk` directly (`docker tag`; the former no-op `Dockerfile.sdk` shim was removed) and downstream stages perform CPU-only builds (CUDA auto-detection falls back to `CPU-only build`). `windows/build.ps1` handles this automatically via its `-Gpu` switch.
- The toolchain stage builds CPython 3.14 from source (matching the canonical versions.env) via `windows/Dockerfile.toolchain-builder` + `build-toolchain-all.ps1` (run+commit for full cores; the former standalone `Dockerfile.toolchain` was removed as dead code — it duplicated the builder without the nuget pre-seed fix).
- The **media stage fans out into three branch images** by `windows/build.ps1`, built **sequentially** (media-core first — it alone gets the whole RAM budget, maximizing ONNX parallelism). All three branches share ONE multi-stage builder, `windows/Dockerfile.media-builder`, selected per branch via `--target <name>`; then the stage fans in:
  - **media-core** (`--target media-core` + `build-media-core-all.ps1`, run+commit) — the ONNX dependency chain, sequential: ONNX Runtime 1.27.0 (source build; CUDA EP enabled when the NVIDIA layer was used, DirectML EP always via the clang-cl patch) → ONNX GenAI 0.14.0 (CMake+clang-cl, bypassing `build.py`; built with `USE_DML=ON` + `USE_CUDA=ON`) → OpenCV 5.x (CMake+Ninja+clang-cl, CUDA auto-detected, detects the source-built ONNX Runtime) → FFmpeg `master` (MSVC toolchain via MSYS2 bash; `--enable-libonnxruntime` links FFmpeg's DNN filters against the source-built ONNX Runtime — note there is no separate `--enable-dnn` flag; DNN filters come with the backend).
  - **media-litert** (`--target media-litert` + `build-litert-all.ps1`) — LiteRT 2.1.6 → LiteRT-LM 0.13.1 (independent of ONNX).
  - **media-tvm** (`--target media-tvm` + `build-media-tvm-all.ps1`) — TVM 0.25.0 → IREE (both LLVM-heavy ML compilers; each installs its Python wheels into the source-built CPython; IREE native tools land at `C:\runtime\iree`, `IREE_ROOT`/`IREE_BIN`).
  - **merge** (`Dockerfile.media-merge-builder`): `COPY --from` fan-in of the three branch trees into one `C:\runtime` + canonical env layout, then GStreamer 1.29.2 built via `build-gstreamer-from-source.ps1` in the run+commit step (Meson + clang-cl; auto-detects CUDA, OpenCV, ONNX and FFmpeg from the merged tree).
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

1. `docker build` a thin **builder image** (`Dockerfile.media-builder --target media-core`) —
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

`Invoke-MediaBranchRunCommit` in `build.ps1` implements this via the generic
`Invoke-RunCommitStage` helper; tune it with `-MediaCoreCpus` (default: the host's
logical processor count, `[Environment]::ProcessorCount`) and `-MediaMemoryGb`
(default 0 = auto-detect from host RAM minus `-HostReserveGb`).

**Which stages use run+commit.** The same `Invoke-RunCommitStage` path is used for
every **CPU-bound** stage, so they all build at `-MediaCoreCpus` cores instead of
the 2-CPU `docker build` cap:

| Stage | Builder Dockerfile | Run step (the heavy compile) |
|-------|--------------------|------------------------------|
| toolchain | `Dockerfile.toolchain-builder` (clones CPython + writes props) | `build-toolchain-all.ps1` (`PCbuild\build.bat`) |
| media-core | `Dockerfile.media-builder --target media-core` | `build-media-core-all.ps1` (ONNX→GenAI→OpenCV→FFmpeg) |
| media-litert | `Dockerfile.media-builder --target media-litert` | `build-litert-all.ps1` (LiteRT→LiteRT-LM) |
| media-tvm | `Dockerfile.media-builder --target media-tvm` | `build-media-tvm-all.ps1` (TVM → IREE) |
| media merge | `Dockerfile.media-merge-builder` (fan-in `COPY --from` + env) | `build-gstreamer-from-source.ps1` |

The **merge stage splits**: the fan-in (`COPY --from` of the three branch trees)
*must* be a `docker build` because `docker run` can't `COPY --from`, but it is only
IO so 2 CPUs is fine; the CPU-bound GStreamer compile then runs via run+commit.
`docker commit` preserves the builder image's ENV, so each result image is a
drop-in replacement for the old single-Dockerfile output.

The `litert`/`tvm` aux branches **also** run+commit at `-MediaCoreCpus` cores (via
their `Dockerfile.media-builder` targets): media-core is already committed when they
run, so the whole CPU/RAM budget is free — e.g. `~j19` at 32 CPU / 39 g on this host
(still memory-bound per the note below). `base`/`sdk` are the only stages that never
exceed 2 CPUs — they're network/install-bound (no benefit from more).

> **NOTE — parallelism is memory-bound, not core-bound.** `Get-BuildJobCount =
> min(cpu-count, MEMORY_LIMIT_GB / per-job-GB)`. ONNX is ~4 GB/job, so at 48 GB it
> runs `~j12` whether you give it 16 or 32 cores; extra cores only speed the
> lighter TUs (FFmpeg, CPython, GStreamer). True `j32` on ONNX needs ~128 GB RAM,
> which this host does not have — so on the ONNX long pole, **RAM is the ceiling,
> not cores.**

**Trade-off:** a single `docker run` has no per-stage layer cache, so a mid-chain
failure re-runs the whole chain (unlike a multi-`RUN` `docker build`, where each
completed step is cached). The persistent **sccache** remote (below) covers the
recompilation, so in practice only uncached objects rebuild. Regression symptom
for the whole mechanism: `ninja -j2` in `out\windows-build-logs\media-core.log`,
or an `ActivateLayer` error on any commit.

**Root cause (fully diagnosed).** The commit failure is the **`wcifs`** minifilter
(Windows Container Isolation FS) refusing to detach the process-isolation layer on
container teardown — dockerd's `panic.log` shows
`hcsshim::UnprepareLayer failed ... ERROR_FLT_DO_NOT_DETACH (0x801f0010)`, which
leaves the layer files locked so the subsequent commit's `ActivateLayer` fails
`0x20`. The trigger is an **OS-class mismatch**: the host is a Windows **client**
build (26200 / 25H2) but the only base image is Windows **Server** `servercore:ltsc2025`
(build 26100). A client-kernel `wcifs` will not detach a Server layer. This is
below Docker *and* below containerd — it reproduces identically for `docker build`,
`docker run`+`commit`, the containerd snapshotter, and `nerdctl commit`, on the
newest stack (Docker 29.5.3 / containerd 2.3.1 / hcsshim 1.2.1). It is **not**
contradicted by Microsoft's host≥image compatibility matrix: the matrix governs
whether the image can *run* under process isolation (it does — the `RUN` step
executes), not layer *commit/teardown*. The only real fixes are environmental:
build on a **matching build-26100 host** (Windows 11 24H2 or Windows Server 2025),
or wait for a Windows/hcsshim fix.

### Re-testing process isolation on new versions (is the bug gone yet?)

After **any** Docker Engine / containerd / hcsshim / Windows / base-image upgrade,
re-check whether `docker build --isolation process` can commit a layer again — if
it can, the *entire* Windows build (not just media-core) could run at full CPU
count and the run+commit workaround could be retired. A durable, self-contained
probe lives under `windows/diagnostics/`:

```powershell
.\windows\diagnostics\test-process-isolation-commit.ps1
```

It records the current Docker/containerd/host build numbers, runs a `docker run
--isolation process` control (expected: PASS), then builds a tiny ~100 MB probe
layer with `docker build --isolation process` (`Dockerfile.isolation-probe`) and
prints a clear verdict:

- **`BUG GONE` (exit 0):** the commit succeeded — process isolation is usable for
  `docker build`. Follow the on-screen next steps (switch heavy stages to
  process isolation, re-run the full build to confirm parity, then retire
  `Invoke-RunCommitStage` and update this doc + the host-quirks notes).
- **`BUG PRESENT` (exit 1):** the known `wcifs`/`ActivateLayer 0x20` failure still
  occurs — keep the run+commit workaround.
- **exit 2:** the build failed with a *different* signature — investigate; do not
  assume it is fixed.

To test a hypothetical newer *matching-build* base image, pass `-Base <image>`.
Baseline as of Docker 29.5.3 / containerd 2.3.1 / host build 26200 with
`servercore:ltsc2025`: **BUG PRESENT**.

### Run-side wcifs symptoms (process isolation)

The same `wcifs` filter that breaks layer *commits* on this host/base skew also
breaks **runtime file operations inside image-layer directories** of
process-isolated containers (surfaced 2026-07 building
Kataglyphis-Inference-Engine inside the image):

- **Create-then-rename of fresh files fails `ERROR_PATH_NOT_FOUND`**
  (deterministic in hot paths). This breaks `git init/clone/checkout` (*"could
  not write config file"*, *"unable to write new index file"*) and Dart's
  `File.renameSync` (e.g. the sqlite3 package's native-asset hook).
- Plain **copies and tar extractions** in the same directories succeed.
- Directories **created fresh in the sandbox** (e.g. `C:\foo`) are unaffected.
- **Bind mounts avoid the layer FS but are NOT a full fix** (verified 2026-07-16):
  on mounted paths, plain writes and cmd `copy`/`ren` work, but **Dart's
  `copySync`/`renameSync` fail with errno 3** (`bindFlt` rejects the Dart
  runtime's two-path file operations on this skewed host). Consumer recipe:
  bind-mount the sources, then junction the Dart/Flutter write dirs
  (`.dart_tool`, `build`) from the mounted workspace to **container-local**
  dirs (`mklink /J`, run inside the container) — Dart ops work in fresh
  sandbox dirs. A **Dev Drive** source additionally needs
  `fsutil devdrv setfiltersallowed bindFlt, wcifs` once (elevated), then a
  remount.
- **The bind-mount target must NOT already exist in the image** (verified
  2026-07-16): `--mount target=C:\workspace` (a baked image dir) fails at
  container creation with `hcs::CreateComputeSystem ... Die Anforderung wird
  nicht unterstützt`, while the same source mounted to a fresh target
  (`target=C:\ws-mnt`) works. Version-matched CI runners mount over existing
  dirs fine — consider not pre-creating `C:\workspace` in the image, or adopt a
  fresh-target convention on skewed hosts.
- `docker cp` into a **running** Windows container silently copies nothing, and
  against a **stopped** container it triggers the ActivateLayer lock. Use
  `tar -cf - . | docker exec -i <container> tar -xf - -C <dir>` instead.

The run-side variant has its own "is the bug gone yet?" probe, mirroring the
commit-side one — re-run it after any Docker / containerd / hcsshim / Windows /
base-image upgrade:

```powershell
.\windows\diagnostics\test-layer-rename.ps1
```

It renames files in a fresh sandbox dir (CONTROL, expected PASS) and in an
image-layer dir (`C:\Windows\Temp`; VERDICT, **expected FAIL today**) and prints
**BUG GONE** (exit 0) / **BUG PRESENT** (exit 1) / unexpected-signature (exit 2).
Pass `-Base <image>` to probe the built developer image's own layers.

### GPU acceleration in containers (DirectML on the host GPU)

On Windows, **GPU acceleration in containers is DirectX-only** — Direct3D 12 and
everything layered on it, which includes **DirectML** (the ONNX `DmlExecutionProvider`
and onnxruntime-genai's DML path). CUDA/TensorRT cannot be GPU-accelerated in a
Windows container. On this host that is exactly the point: the machine has an **AMD
Radeon RX 9070 XT** (+ iGPU) and **no NVIDIA GPU**, so DirectML — being
vendor-agnostic — is the *only* GPU path. (The CUDA/TensorRT EPs are still built and
smoke-checked for availability, but they have no device to run on here.)

Running DirectML on the physical GPU **inside a container** requires all of:

1. **Process isolation** — Hyper-V-isolated containers get **no** GPU. (The default
   isolation on this host is `hyperv`, so you must pass `--isolation process`.)
2. **The DirectX GPU device**, attached with the **exact** device interface class GUID:
   `--device class/5B45201D-F2F2-4F3B-85BB-30FF1F953599`. A wrong variant is *silently
   accepted* by `docker run` but matches no device, so the container falls back to the
   WARP software renderer with no error.
3. **A base-image OS build that matches the host build.** Basic process isolation
   tolerates skew (a `26100` image runs on a `26200` host), but GPU **driver-store
   injection does not** — `hcs::CreateComputeSystem` fails with *"The system cannot
   find the path specified"* when the builds differ. This is the **same** client-host
   (`26200` / 25H2) vs Server base image (`servercore:ltsc2025` = `26100`) skew that
   breaks `docker build --isolation process` layer commits.

**Current status on this host: BLOCKED by the build skew.** The GPUs *are* GPU-PV
partitionable (`Get-VMHostPartitionableGpu` lists both AMD adapters), process
isolation works, and the DirectML runtime is built correctly — but GPU device
assignment fails at `CreateComputeSystem` because the `ltsc2025` (`26100`) base does
not match the host (`26200`), and no public client `26200` base image exists to
rebuild against. A DXGI enumeration inside the (correctly-flagged) container therefore
sees only `Microsoft Basic Render Driver` (WARP), zero hardware adapters.

To retire the block: rebuild the base on a `servercore`/`nanoserver` tag whose build
equals the host, **or** run the image on a host whose build equals the image
(`26100`, e.g. a Windows Server 2025 host). Until then, **DirectML on the AMD GPU
still works fine _outside_ containers** — run the source-built ORT / GenAI binaries
directly on the bare host and the `DmlExecutionProvider` selects the RX 9070 XT.

Re-check after any Docker / containerd / hcsshim / Windows / base-image / GPU-driver
upgrade with the self-contained probe under `windows/diagnostics/`:

```powershell
.\windows\diagnostics\test-gpu-passthrough.ps1
```

It prints host/image builds and partitionable GPUs, runs a process-isolation control,
attaches the GPU device, compiles + runs a DXGI adapter enumerator inside the
container, and gives a verdict: **PASSTHROUGH WORKS** (a HARDWARE adapter is visible),
**BLOCKED** (build-skew `CreateComputeSystem` failure), or **DEVICE-NOT-INJECTED**
(started but only WARP). Note the DML probes in `smoke-test-container.ps1` validate
that the provider is *built and registered* (`GetAvailableProviders` → `dml=1`, plus
the x64 `D3D12Core.dll` PE-machine check); they do **not** create a device, so they
pass under either isolation regardless of whether a hardware adapter is present.

### Rust toolchain (rustup WITH a default toolchain — never toolchain-less rustup)

Rust is provisioned **exclusively via rustup** (`setup-rust-toolchain.ps1` runs
`rustup-init.exe -y --default-toolchain stable --profile minimal`), and
`flutter_rust_bridge_codegen` is baked alongside so Flutter+Rust consumers skip a
minutes-long cold `cargo install` per fresh container.

rustup is **required**, not merely tolerated: Flutter's **Cargokit** (the build
glue used by `flutter_rust_bridge`-style plugins, e.g. `rust_builder/cargokit` in
Kataglyphis-Inference-Engine) enumerates toolchains/targets via rustup and aborts
with *"rustup not found in PATH."* otherwise — a scoop-only Rust (the previous
setup) failed every Flutter+Rust consumer build at the CMake install step.

The failure mode the old "never rustup" rule guarded against is real but
**narrower than the rule**: a **toolchain-less** rustup (`rustup-init
--default-toolchain none`) drops proxy shims (`cargo.exe`, `rustc.exe`, …) into
`CARGO_BIN` that resolve **no** toolchain and fail with *"rustup could not choose
a version of cargo … no default is configured"*. A rustup installed **with a
default toolchain** resolves fine — and because `Dockerfile.base` points
`CARGO_HOME`/`CARGO_BIN` at `C:\Users\ContainerAdministrator\.cargo`, which sits
ahead of scoop's shim dir on `PATH`, the proxies winning is now the *correct*
outcome. Keep exactly one Rust provider: no `scoop install main/rust` alongside.

Rust is DELIBERATELY unpinned on this lane (`stable` at build time;
versions.env's `RUST_VERSION` pins only the Linux lane). The smoke test asserts a
well-formed rustc version, the Cargokit probe shape (`rustup show
active-toolchain`, `rustup which cargo`), `flutter_rust_bridge_codegen
--version`, and a compile/link/run probe — never the versions.env value.

### Media fan-out and memory budgeting

**Media scheduling is sequential** (media branch logs land in
`out\windows-build-logs\media-core.log` / `media-litert.log` / `media-tvm.log`,
plus `gstreamer.log` for the merge). Sequential gives media-core the *whole* host
RAM budget — and since its parallelism is memory-bound, more RAM = more ONNX jobs,
which matters more than overlapping the small aux branches (a former
`-ConcurrentMedia` overlap mode was removed for exactly that reason).

**`-MediaMemoryGb` auto-detects from host RAM** (default `0` = auto). It resolves
to `usable_physical_GB − HostReserveGb`. `-HostReserveGb` (default 22 — see the
learned-the-hard-way note below) is the RAM left for Windows + dockerd + Defender;
lower it to push closer to the metal (riskier — under memory pressure the hcsshim
`ttrpc` wedge is more likely). Pass an explicit `-MediaMemoryGb N` to override
auto-detection. The cap is forwarded as `MEMORY_LIMIT_GB` so the build scripts
scale their job count to the container's cap (`BUILD_JOBS` overrides the heuristic
outright).

Worked example (this 64 GB host, Windows reports 61.4 GB usable → floor 61,
default `-HostReserveGb 22`): auto `-MediaMemoryGb` = `61 − 22` = **39 g** →
ONNX runs `~j10` (`mem/4`, cores=32).

media-core, toolchain, and the merge/GStreamer stage all build via the run+commit
path (see § Build isolation and CPU parallelism) at `-MediaCoreCpus` CPUs. The
litert/tvm aux branches run+commit at `-MediaCoreCpus` too — the full budget is
free once media-core has committed.

### Maximum resource envelope (verified 2026-07-12)

The defaults ARE the maximum for this 64 GB / 32-thread host — there is no
faster configuration to unlock, and the full-chain rebuild of 2026-07-12
(base → sdk → toolchain → media → final, phase-tagged resource CSV) is the proof:

| Phase        | Minutes | AvgCpuPct | MaxCpuPct | MinFreeGB |
|--------------|---------|-----------|-----------|-----------|
| media-core   | 111     | 37        | 100       | **0.2**   |
| media-litert | 18      | 38        | 100       | 24.9      |
| media-tvm    | ~25     | 42        | 100       | 41.8      |

- **CPUs: 32/32 on every heavy stage.** `docker run --cpu-count 32` (run+commit)
  is the only >2-CPU path on this host; every compile stage uses it. `docker
  build` stages are pinned at 2 CPUs by the host defect — that is why they carry
  only cheap COPY/clone layers.
- **RAM: 39 GB is the measured optimum, not a conservative default.** During
  media-core the host bottomed out at **0.2 GB free** — the 22 GB reserve was
  consumed almost exactly. Raising `-MediaMemoryGb` (or cutting
  `-HostReserveGb`) does not add jobs fast enough to beat the starvation
  cliff: the 53 GB experiment deadlocked media-core at 0 % CPU (see the
  hard-way note below).
- **Average CPU of ~35–45 % during compiles is CORRECT and expected** — it is
  the memory-bound signature (`jobs = min(32, 39 GB / ~4 GB-per-ONNX-job) ≈ 10`),
  not a tuning failure. Do not chase 100 % average CPU on this host.
- **The only real "go faster" levers are infrastructural:** ~128 GB RAM (true
  `j32` on ONNX), or a populated sccache remote (`-SccacheEndpoint` /
  `SCCACHE_WEBDAV_ENDPOINT`) to make *re*builds warm — cold full-chain is
  ~5–6 h with ~2.5 h of that in the media fan-out.

**Per-run resource log.** Every `build.ps1` run samples host CPU / free RAM /
commit charge / container-VM (`vmmem`) size every 20 s into
`out\windows-build-logs\resources-<timestamp>.csv`, tagged with the current build
phase (`build:<dockerfile>`, `run:<stage>`, `commit:<stage>`), and prints a
per-phase exhaustion summary at the end — including on failure. Re-analyze any
run later with
`pwsh -File windows/scripts/build-resource-sampler.ps1 -Summarize -CsvPath <csv>`;
`MinFreeGB` per phase shows which step pushed the host hardest, and an
`AvgCpuPct` far below 100 during a compile phase means the step was memory-bound
(`jobs = min(cores, MEMORY_LIMIT_GB/perJob)`), not CPU-bound. Disable with
`-NoResourceLog`.

> **Why the reserve is 22 GB, not ~8 (learned the hard way).** An earlier default
> of `-HostReserveGb 8` auto-sized media-core to **53 GB**, which **hung the build**:
> during a GPU build dockerd + containerd juggling the ~50 GB CUDA image layers,
> plus `svchost`/Defender, hold **~16–18 GB** steady — so 53 GB container + ~17 GB
> host exceeded the 61 GB physical, the Hyper-V VM starved at ~43 GB, and media-core
> deadlocked at **0 % CPU** with the host at **0.3 GB free** (log frozen mid-ONNX for
> 2 h). The `--memory` cap is real RAM committed to the utility VM, so
> `container_cap + host_footprint` must fit physical RAM with margin. 22 GB reserve
> (→ ~39 GB container, ~56 GB peak) is the verified-safe budget here. The heavy
> CUDA TUs (FlashAttention, MoE kernels) use **more than the ~4 GB/job estimate**, so
> do not shrink the reserve without watching `docker stats` + host free RAM.

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
& "C:\Program Files\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  powershell -File C:\temp\scripts\smoke-test-container.ps1
```

The smoke test validates 22 categories including CUDA Toolkit 13.3, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, TVM (source-built), IREE (source-built; native MLIR→vmfb compile + local-task execution, a CUDA-target compile-only assert on the GPU lane, and a python `iree.compiler`→`iree.runtime` end-to-end), FFmpeg (source-built with DNN/ONNX integration), compiler integration, environment-pointer integrity, and Python bindings. **Current baseline (2026-07-14, GPU lane): 167 passed / 0 failed / 1 skipped** — the single skip is GPU device passthrough, blocked by the host/base OS-build skew. Growth over the 153 baseline: the PyAV asserts (staged `av-*.whl` + an in-memory mpeg4 encode through the container-built FFmpeg) and the IREE suite (section 22 native compile+run incl. a CUDA-target compile-only assert, wheel-pin + `--version` asserts, section 20 staged-wheel + python end-to-end asserts, section 19 `IREE_ROOT`/`IREE_BIN` pointers).

### What is verified: native vs. Python

**Native (C++/CLI) functionality is verified end-to-end.** The suite does not stop
at existence checks: it compiles, links, and *runs* probe programs against the
source-built libraries — ONNX Runtime (C API ABI + a real inference session over
an embedded 63-byte Identity model on the CPU EP), OpenCV (core API call), TVM
(full dependent-DLL chain load), LiteRT-LM (its `litert_lm_main.exe` smoke-run is
a hard gate of the media build itself), FFmpeg (a real lavfi→null filter graph),
GStreamer (a live `videotestsrc ! videoconvert` pipeline), plus clang-cl /
CMake+Ninja / MSBuild integration builds. Version pins (cmake, python, gstreamer)
are asserted against versions.env to catch stale baked layers.

**Python bindings are built, shipped, and functionally verified (since
2026-07-13).** The media branches build python bindings for every source-built
library that supports them and stage the wheels centrally at
**`C:\runtime\wheels`** (`PYTHON_WHEELS` env): `onnxruntime` (CUDA+TRT+DML EPs,
`ENABLE_PYTHON=ON`), `onnxruntime-genai-cuda` (`BUILD_WHEEL=ON`),
`apache-tvm` (scikit-build-core), `iree-base-compiler` + `iree-base-runtime`
(built from the IREE ninja tree's synthesized `compiler/`+`runtime` pip dirs
with `--no-build-isolation` so the wheels pack the existing LLVM objects
instead of rebuilding them), and `av` (PyAV compiled from sdist against
the source-built FFmpeg via `setup.py --ffmpeg-dir` — PyPI's own av wheel is
structurally unloadable on Server Core because its bundled avdevice imports
the desktop-only `AVICAP32.dll`; note the generic `h264` encoder alias
resolves to `h264_d3d12va`, so headless code should request software codecs
like `mpeg4`/`libx264` by name). Because `FFMPEG_VERSION=master` tracks a live
branch, `build-ffmpeg-from-source.ps1` normalizes the import-lib layout after
`make install` — an upstream drop moved `avformat.lib` et al. from `lib\` to
`bin\` overnight (2026-07-13, PyAV died with LNK1181): every `.lib`/`.def` is
harvested into `lib\`, missing import libs are regenerated from their `.def`
via `lib.exe`, and the PyAV step logs the lib inventory up front so the next
layout drift fails loudly with data. `cv2` ships installed into CPython's
site-packages (the opencv repo has no wheel machinery — opencv-python is a
separate upstream project); LiteRT has no python bindings on this lane
(bazel-only python package). All bindings are pre-installed with their PyPI
deps, so `python -c "import onnxruntime, onnxruntime_genai, cv2, tvm, av"`
works out of the box. Smoke section 20 verifies wheels + `win_amd64` tags, real
python-side ONNX inference, a cv2 PNG round-trip, and genai/tvm imports.
Load-bearing plumbing (do not remove): the `sitecustomize.py` shim fixes the
clang-built CPython's win32 platform misreport AND registers the image's
native DLL homes via `os.add_dll_directory` (CUDA 13/cuDNN 9 keep their
runtime DLLs in `bin\x64`; python 3.8+ ignores PATH for pyd dependencies);
OpenCV builds with `WITH_MSMF=OFF` *and* `WITH_OBSENSOR=OFF` because both
hard-import Media Foundation, which Server Core does not ship.

### The torch step (Orchestr-ANT-ion app environment)

The final image bakes the runtime orchestrator at
**`C:\opt\Kataglyphis-Orchestr-ANT-ion`** (`TORCH_APP_DIR`), assembled by
`windows/scripts/assemble-torch-app.ps1` (mirror of the linux
`assemble-torch-app.sh` stage) during the final `docker build`:

- **Ref**: `build.ps1` resolves the app's **latest tag** per build
  (`git ls-remote`), falling back to versions.env's `APP_REF` pin offline; the
  resolved tag reaches the Dockerfile as the `APP_REF` build-arg, so a new
  release busts exactly the torch-step layer.
- **Environment**: `uv sync` on the source-built CPython (extras `ml-ai`,
  `docs`, `pytorch-cpu`, `test`; the wxPython GUI extra excluded, like linux),
  then a reconcile so this lane's wheels always win: PyPI onnx/genai/opencv
  families are uninstalled, `C:\runtime\wheels` force-installed `--no-deps`
  (genai-cuda's metadata names `onnxruntime-gpu`, which our combined wheel
  replaces), and `cv2` + `tvm_ffi` + the sitecustomize shim staged from base
  site-packages into the venv.
- **Known limitation**: `ai-edge-litert` is skipped
  (`--no-install-package`) — its pinned version ships no cp314 wheel and the
  LiteRT python package is bazel-only on Windows, so the app's LiteRT code
  path is unavailable in this venv.
- **Gates**: the docker build itself fails unless the venv passes the import
  battery (numpy/cv2/torch/onnxruntime with a CUDA-EP build assert/genai/tvm)
  **and the app's own wheel-smoke suite** (`python -m orchestr_ant_ion.smoke`
  — real torch/torchvision/ORT-inference/OpenCV work; expected report on this
  lane: 10/11 ok with one WARN for the litert skip on app v0.0.24/v0.0.25
  (v0.0.23 added genai + tvm, v0.0.24 pyav), 11/12 once a tag ships the iree
  check). Smoke section 21 re-runs the same verification offline on every
  suite run.
- **Usage**: `C:\opt\Kataglyphis-Orchestr-ANT-ion\.venv\Scripts\python.exe`
  (or `uv run` from `TORCH_APP_DIR`) is a ready environment where
  `import onnxruntime, onnxruntime_genai, cv2, tvm, torch` all resolve to the
  source-built wheels plus the app's locked PyPI dependency set.
