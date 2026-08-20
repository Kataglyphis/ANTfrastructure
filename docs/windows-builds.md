# Windows Build Image

> Building a large project **inside** this image and want it to be fast?
> See [Windows Container Build Performance](windows-container-build-performance.md)
> — measured results for incremental builds, plus the approaches that do not
> work (sccache on C++23 modules, named volumes as build directories).

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

7. **Upstream export-gap bridges (LiteRT-LM v0.14.0) — FROZEN FALLBACK ONLY.**
   The primary LiteRT-LM build is now **Bazel** (`build-litert-lm-bazel.ps1`),
   which is the path Google CI-tests and does NOT need any of these bridges;
   everything in this item applies only to the retired CMake fallback
   `build-litert-lm-from-source.ps1`. Google ships LiteRT-LM
   tags whose CMake layer lags the source restructure (v0.14.0's was never
   buildable anywhere: it references the deleted `constrained_decoding`
   component, pins a LiteRT from *before* the `support/` tree its own shim
   headers `#include " from @litert"`, and compiles none of the new
   `logits_processor`/support subsystems). `build-litert-lm-from-source.ps1`
   bridges this with condition-gated blocks (`[LiteRTLM-winfix export-stubs]`,
   `[LiteRTLM-winfix support-graft]`, the v0.14-orphans + v0.14-deps blocks):
   stub CMakeLists are *generated*, the `support/` tree is *sparse-cloned from
   LiteRT at the version this container already ships* (`LITERT_VERSION`), and
   orphaned sources are injected into the engine lib. Static `.patch` files
   cannot express "graft a tree from another repo at a configurable tag" or
   "only when the referenced dir is missing" — and every block is gated on the
   breakage itself, so a future tag with a fixed export takes upstream's files
   untouched and the bridge self-retires. The Gemma constraint provider is
   upstream's prebuilt-only DLL component: its import lib is linked on the exe
   and the DLL staged beside `litert_lm_main.exe` (with `z.dll` +
   `kissfft-float.dll`, found via `llvm-objdump -p` after the exe died
   0xC0000135 without them).

Every inline substitution in a build script carries a `# Inline patch (kept inline, NOT a .patch file):` block comment explaining the canonical-form rationale. The current `.patch` inventory:

| Component | Patch | Upstream target | Purpose |
|-----------|-------|-----------------|---------|
| FFmpeg | `001-allow-msys-builds.patch` | `configure` | Replace `die` with `echo` for MSYS2 build env |
| GStreamer | `001-ges-commit-rename.patch` | `subprojects/gst-editing-services/ges/ges-validate.c` | `#define _commit ges__commit` to dodge `-FIio.h` macro collision |
| ONNX Runtime | `001-softmax-clangcl-keywords.patch` | `core/providers/cuda/math/softmax.cc` | Change the one real ISO-646 `or` → `\|\|` on the dispatch `if` (clang-cl in MS-compat mode treats `or` as an identifier); comments left as upstream |
| ONNX Runtime | `002-disable-cuda-pch.patch` | `cmake/onnxruntime_providers_cuda.cmake` | Disable CUDA EP `target_precompile_headers` (CUDA 13.x CCCL broken with clang-cl) |
| ONNX Runtime | `003-dml-clangcl-compat.patch` | DirectML EP (5 files under `core/providers/dml/`) | clang-cl + `USE_DML=ON`: out-of-line `AbstractOperatorDesc` members past `OperatorField` (incomplete-type), drop the `.##Z` token-paste, widen `Dispatch<uint32_t>` → `size_t` |
| ONNX Runtime | `004-tunable-severity-macro-collision.patch` | `core/framework/tunable.h` | ORT 1.28.0 + CUDA 13.3: `wingdi.h`'s `#define ERROR 0` (reached despite `-DNOGDI` when a header includes wingdi directly — `triton_kernel.h`'s chain does) pre-expands through the `LOGS_DEFAULT` forwarding macro into the nonexistent `Severity::k0` (nvcc: `enum ... has no member "k0"` at the `LOGS_DEFAULT(ERROR)` line, first TU `triton_kernel.cu`); guarded `#undef ERROR` + `#undef VERBOSE` after the includes. Diagnosis trap: the error line number points at whatever `LOGS_DEFAULT(...)` use sits there — read the LINE, not the macro argument you expect |
| ONNX Runtime | `005-xqa-host-stub-sccache.patch` | `contrib_ops/cuda/bert/xqa/xqa_impl_gen.cuh` | ORT 1.28.0 XQA (paged-attention) kernels: the host-pass include guard keys on the cmake define `HAS_SM80_OR_LATER`, and sccache's nvcc decomposition (`CMAKE_CUDA_COMPILER_LAUNCHER`) can drop target `-D` defines in the host sub-step → `x_?.cudafe1.stub.c` `C2039/C2065` (`smemSize`/`kernelType`/`cacheVTileSeqLen` missing from `H*::grp*_*`; the synthetic `x_?.cu` TU name is the sccache fingerprint). We pin sm80+ archs, so the patch makes the host stub unconditional. NOT upstreamable as-is (pre-sm80-only builds would regress) |
| ONNX Runtime | ~~`006-cuda-llm-bare-nvcc.patch`~~ RETIRED 2026-08-18 | `cmake/onnxruntime_providers_cuda.cmake` | sccache's nvcc decomposition crashes its server deterministically on the fused_moe_gemm generated launchers (two chain runs died at ~4910 s, `os error 10054` on every client). The launchers all live in the `onnxruntime_providers_cuda_llm` OBJECT library, so the patch clears that ONE target's `CUDA_COMPILER_LAUNCHER` property — bare nvcc there. (Historical note: when written, CUDA elsewhere was sccache-wrapped; since the 2026-08-10 opt-in flip ALL CUDA compiles bare unless `SCCACHE_CUDA_LAUNCHER=1`, so today the patch only matters when that opt-in is active — e.g. the #2808 repro, which skips the patch AND sets the opt-in.) Hit rates are visible per run via the `sccache-stats|` stderr block after the ONNX build |
| OpenCV | `001-cmake-clang-cl-compat.patch` | `CMakeLists.txt` + `cmake/FindONNX.cmake` | CMP0146/CMP0148 OLD→NEW + clang-cl/CUDA detection compat. REGENERATED against 5.0.0 on 2026-08-10 (5.0.0 dropped the `CMP0218` block the old hunk context named; the patch is applied with NO fallback, so drift here throws an hour into media-core — run `Test-PatchesApplyClean.ps1` after every pin bump) |
| OpenCV | `002-mlas-clangcl-force-include.patch` | `3rdparty/mlas/CMakeLists.txt` | OpenCV 5.0.0's bundled MLAS treats clang-cl as GNU-Clang and passes the GNU pair `-include` + `cstring`, which the CL dialect parses as an INPUT FILE (`clang-cl: error: no such file or directory: 'cstring'`, first mlas TU). Adds an MSVC-frontend branch (`CMAKE_CXX_COMPILER_FRONTEND_VARIANT`) using `/FIcstring` + `/w`. The older inline `<cstring>` source-prepend loop in build-opencv-from-source.ps1 fixes only the CONTENT, not the broken flags |
| OpenCV | `003-mlas-windows-skip.patch` | `3rdparty/mlas/CMakeLists.txt` | Skip the vendored MLAS on Windows: its kernels are GAS/ELF-only (`.type sym,@function`, no MASM port) and clang-cl IS a working GAS assembler, so the `check_language(ASM)` guard that saves MSVC does not fire — the `.S` files then die in the integrated assembler ("expected absolute expression", run 12, 2026-08-10). dnn falls back to its built-in SGEMM; inference runs on ONNX Runtime/DirectML anyway |
| OpenCV | `004-dnn-ort-profiling-wchar.patch` | `modules/dnn/src/net_impl_backend.cpp` | UPSTREAM BUG (5.0.0, run-13 find): dnn's ORT `EnableProfiling` passes `char*` but `ORTCHAR_T` is `wchar_t` on Windows — the model-path call right below is `#ifdef _WIN32`-widened, this one was not (upstream Windows CI never builds dnn with ORT). Issue draft: `out/upstream-issue-opencv-ort-wchar.md` |
| OpenCV (contrib) | `001-cudev-windows-llp64.patch` | `cudev/.../common.hpp` | Add `ulong`/`longlong`/`ulonglong` typedefs for Windows LLP64 |

`ffmpeg/makedef` is **not** a patch — it is a whole-file replacement script staged over FFmpeg's `makedef` (a byte swap, not a diff), so it is not in the table above.

When bumping any upstream version, audit these `.patch` files before letting the orchestrator loose: run `windows/scripts/tests/Test-PatchesApplyClean.ps1`, which clones each pinned upstream and runs the exact `git apply --check` the build uses (see `windows/scripts/patches/README.md`). If a patch no longer applies, regenerate with `git diff` against the new tag and update the inventory above.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.4.2, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.nvidia` (optional GPU layer) layers CUDA 13.3 + cuDNN 9.25.0.15 + TensorRT 11.2.1.2 on top of the base image and is tagged `windows-sdk`. If skipped, the base image is tagged `windows-sdk` directly (`docker tag`; the former no-op `Dockerfile.sdk` shim was removed) and downstream stages perform CPU-only builds (CUDA auto-detection falls back to `CPU-only build`). `windows/build.ps1` handles this automatically via its `-Gpu` switch.
- The toolchain stage builds CPython 3.14 from source (matching the canonical versions.env) via `windows/Dockerfile.toolchain-builder` + `build-toolchain-all.ps1` (run+commit for full cores; the former standalone `Dockerfile.toolchain` was removed as dead code — it duplicated the builder without the nuget pre-seed fix).
- The **media stage fans out into three branch images** by `windows/build.ps1`, built **sequentially** (media-core first — it alone gets the whole RAM budget, maximizing ONNX parallelism). All three branches share ONE multi-stage builder, `windows/Dockerfile.media-builder`, selected per branch via `--target <name>`; then the stage fans in:
  - **media-core** (`--target media-core` + `build-media-core-all.ps1`, run+commit) — the ONNX dependency chain, sequential: ONNX Runtime 1.28.0 (source build; CUDA EP enabled when the NVIDIA layer was used, DirectML EP always via the clang-cl patch) → ONNX GenAI 0.15.2 (CMake+clang-cl, bypassing `build.py`; built with `USE_DML=ON` + `USE_CUDA=ON`, telemetry off) → OpenCV 5.x (CMake+Ninja+clang-cl, CUDA auto-detected, detects the source-built ONNX Runtime) → FFmpeg `n9.0` (pinned release tag, `FFMPEG_VERSION` in versions.env since 2026-08-04; MSVC toolchain via MSYS2 bash; `--enable-libonnxruntime` links FFmpeg's DNN filters against the source-built ONNX Runtime — note there is no separate `--enable-dnn` flag; DNN filters come with the backend).
  - **media-litert** (`--target media-litert` + `build-litert-all.ps1`) — LiteRT 2.1.6 (CMake+Ninja; also builds the TFLite C-API lib `tensorflowlite_c`) → LiteRT-LM 0.15.0 (independent of ONNX; built via **Bazel** with `build-litert-lm-bazel.ps1` → `litert_lm_main.exe`. The former CMake export-bridge path (`build-litert-lm-from-source.ps1`) is a frozen fallback, see § Source Patch Policy #7).
  - **media-tvm** (`--target media-tvm` + `build-media-tvm-all.ps1`) — TVM 0.25.0 → IREE (both LLVM-heavy ML compilers; each installs its Python wheels into the source-built CPython; IREE native tools land at `C:\runtime\iree`, `IREE_ROOT`/`IREE_BIN`).
  - **merge** (`Dockerfile.media-merge-builder`): `COPY --from` fan-in of the three branch trees into one `C:\runtime` + canonical env layout, plus a `cuda-runtime-stage` (via `stage-cuda-runtime.ps1`) that FLATTENS the CUDA/cuDNN runtime DLLs into `C:\runtime\cuda-runtime\bin` on PATH — the CUDA-linked libs (notably OpenCV, which hard-links `cudnn64_9.dll`) otherwise fail to load in this non-nvidia-based image. Then GStreamer 1.29.2 is built via `build-gstreamer-from-source.ps1` in the run+commit step (Meson + clang-cl; auto-detects CUDA, OpenCV, ONNX and FFmpeg from the merged tree).
- `windows/Dockerfile.torch` assembles the Orchestr-ANT-ion app env on the media image (`media → torch → final`; tag `local/kataglyphis:windows-torch`), and `windows/Dockerfile` produces the final developer image FROM that torch image (VsDevCmd entrypoint).

## Component Build Matrix

The **authoritative per-library build reference** for the Windows lane (AGENTS.md § Windows Build Notes points here — update THIS table, never a copy). Versions are pinned in `linux/scripts/01-core/versions.env`.

| Component | Generator | Compiler | Notes |
|-----------|-----------|----------|-------|
| CPython 3.14 | `PCbuild\build.bat` | ClangCL (v145→ClangCL via Directory.Build.props) | Requires VS ClangCL toolset |
| ONNX Runtime 1.28.0 | Ninja | clang-cl, lld-link | DirectML EP **enabled** (`USE_DML=ON`) via the 3-part clang-cl source patch `003-dml-clangcl-compat.patch` (§ Source Patch Policy; the EOL/context-tolerant inline regex patcher `Invoke-OnnxDmlClangClPatch` in `build-onnx-from-source.ps1` remains as the drift fallback): DirectMLHelpers incomplete-type out-lining, `.##Z` token-paste, `Dispatch<size_t>`. CUDA + TensorRT EPs enabled when the NVIDIA layer is the parent (CUDA 13.3 provider, includes crt/ workaround for nvcc). Patches build.ninja for MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM (`.asm` files). **AVX-512/AMX: per-TU only** — global flags OFF (they crashed protoc AND ort's own DLL init at runtime on AVX2 hosts); the build script appends them (`Get-WindowsX86Avx512Flags`) to MLAS's runtime-dispatched arch TUs in build.ninja post-configure and logs the tagged count (see AGENTS.md § Windows Build Invariants — don't "simplify" in either direction). 1.28's `ScopedResource<INVALID_HANDLE_VALUE,...>` template arg (rejected by clang-cl) is bridged by an inline post-configure dep patch. Needs ~4 GB RAM/job — media-core runs with `--memory ${MediaMemoryGb}g`. |
| ONNX GenAI 0.15.2 | CMake (Ninja) | clang-cl, lld-link | Source-built directly via CMake (bypasses `build.py` which always builds examples). DirectML **enabled** (`USE_DML=ON`) — compiled straight into `onnxruntime-genai.dll` with 0 source patches (`src/dml` is clang-clean; the `RESTORE_PACKAGES` DXC nuget dep is pruned since shaders are pre-generated DXIL; the x64 `D3D12Core.dll` is staged beside the DLL). CUDA **enabled** (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll`; CUDA and DML are independent CMake blocks so they coexist. `-DENABLE_TELEMETRY=OFF` (0.15 defaults MS 1DS telemetry ON; its bundled zlib also breaks clang-cl under -Werror). VsDevCmd environment loaded for MSVC STL headers. |
| OpenCV 5.x | Ninja | clang-cl, lld-link | Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2. CUDA auto-detected. Custom `CMAKE_AR` path fix. |
| LiteRT 2.1.6 | Ninja | clang-cl, lld-link | GPU delegate enabled (Vulkan + OpenCL backends). XNNPACK enabled. CUDA paths exposed for external delegate. Also builds the TFLite **C-API** shared lib `tensorflowlite_c` (target injected into the main build, `WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) that gst-plugins-bad's tflite plugin links. |
| LiteRT-LM 0.15.0 | **Bazel** | clang-cl, lld-link | On-device LLM inference, built via `build-litert-lm-bazel.ps1` (bazelisk + Temurin JDK, `bazelisk build //runtime/engine:litert_lm_main --config=windows`) → `litert_lm_main.exe`, through the smoke-RUN gate. Bazel is the only path Google CI-tests, so it survives version bumps. The old CMake export-bridge path (`build-litert-lm-from-source.ps1`, 5 condition-gated self-retiring patches for v0.14's never-functional OSS CMake export — see § Source Patch Policy #7) is a **frozen fallback**. |
| TVM 0.25.0 | Ninja | clang-cl, lld-link | Auto-detects CUDA/Vulkan. **Builds its own minimal LLVM from pinned source** (#47 heal 2026-08-17: scoop LLVM ships no llvm-config/dev-libs, the official dev tarball is /MT — X86+NVPTX, DIA off, RTTI on, `USE_LLVM=<path>/llvm-config.exe`; SHA pins in `$llvmSrcSha`, ~6 min sccache-warm). Builds a Python wheel. VsDevCmd environment loaded for MSVC STL headers. |
| FFmpeg `n9.0` | MSYS2 `make` (MSVC toolchain) | clang-cl via `--toolchain=msvc` | Source build from the pinned release tag (`FFMPEG_VERSION=n9.0` in `versions.env`; a release TAG since 2026-08-04 — previously tracked `master`). `--enable-libonnxruntime` links FFmpeg's DNN filter against the source-built ONNX Runtime so ONNX models can run inside `ffmpeg` filters (DNN filters ship with the backend; no separate `--enable-dnn` flag). Disabled x86asm. Falls back to a BtbN pre-built GPL binary if the source build fails (the sentinel env var `FFMPEG_SOURCE_BUILD=0` is then set). |
| GStreamer 1.29.2 | Meson | clang-cl | Downloaded as tarball + subproject wraps. CUDA auto-detected. |

## Prerequisites

> **Provisioning a FRESH machine?** Follow the ordered checklist in
> [Fresh Windows Host Bring-Up](windows-host-setup.md) — it sequences
> everything on this page (Stevedore install, CNI conf, debug flags, GC
> policy, Defender exclusions, dufs/sccache, gate tooling) into one
> admin/non-admin-marked path with a verify command per step.

Install [Stevedore](https://github.com/slonopotamus/stevedore):

```pwsh
# WinGet (recommended)
winget install stevedore

# WinGet — custom install directory (e.g. D: NVMe dev drive)
winget install stevedore --custom="INSTALLDIR=D:\Stevedore"

# or Chocolatey
choco install stevedore
```

If you used a custom `INSTALLDIR`, substitute `D:\Stevedore\bin\docker.exe` for `"%ProgramFiles%\Stevedore\bin\docker.exe"` in all commands below.

Reboot after installation. This enables the Windows Containers feature and adds your user to the `docker-users` group.

**Tool roles on this host.** Stevedore's bundled `docker.exe` is the
classic-lane tool for builds, runs and publishing: Docker Engine provides NAT
networking natively, no CNI plugin needed. Since 2026-08-03 the CNI `nat`
**conf** (`C:\Program Files\containerd\cni\conf\0-containerd-nat.conf`; the
`nat.exe` binary always shipped in `...\cni\bin`) is installed on this host —
see § Getting it going, step 2, including the subnet-drift trap — so
containerd-side networking works too, and `nerdctl` runs the `bk-*` images
fine. `nerdctl` needs an **admin** shell (containerd's pipe is admin-only
upstream); the pre-conf state where `nerdctl run` failed with `needs CNI
plugin "nat"` and `nerdctl build` had broken DNS is historical.

| Tool | Build | Run |
|------|-------|-----|
| `"D:\Stevedore\bin\docker.exe"` (non-admin) | ✅ classic lane | ✅ Works (NAT + DNS + process isolation) |
| `buildctl` via `windows\build-buildkit.ps1` (non-admin) | ✅ preferred lane | n/a |
| `nerdctl` (**admin shell only**) | ✅ Works (verified 2026-08-07) — but the chain still uses `buildctl` on purpose, see § nerdctl lane | ✅ Works — needs the CNI nat **conflist**, see § nerdctl lane |

## Build Commands

> **Preferred since 2026-08: the BuildKit/containerd lane** —
> `.\windows\build-buildkit.ps1 -Gpu` builds the same Dockerfiles with **process
> isolation** (full host CPUs, no Hyper-V 2-CPU cap, no run+commit) and real
> per-stage layer caching. One-time host setup + launch: see § BuildKit/containerd
> lane below. The `build.ps1` commands here are the docker-classic fallback lane
> (Hyper-V + run+commit) and remain fully supported.

Use the driver script from the repository root. It parses `linux/scripts/01-core/versions.env`
and passes every version as `--build-arg` (the Dockerfile ARG defaults are only
fallbacks), builds the stages in order, and applies the correct tags:

```pwsh
# CPU lane (default): base -> tag sdk -> toolchain -> media -> torch -> final
.\windows\build.ps1

# GPU lane: base -> nvidia (CUDA + cuDNN + TensorRT, tagged sdk) -> toolchain -> media -> torch -> final
# Requires a TensorRT zip in windows/downloads/ (see AGENTS.md § TensorRT Setup).
.\windows\build.ps1 -Gpu

# Iterate on a single stage (layer cache makes this cheap):
.\windows\build.ps1 -Gpu -Stages media,final

# Deliberate clean rebuild (only when you really need it — this discards ALL layer
# caching and rebuilds everything from scratch, which takes many hours):
.\windows\build.ps1 -Gpu -NoCache

# Orchestr-ANT-ion app stage (windows/Dockerfile.torch, mirror of linux/Dockerfile.torch):
# a chain stage between media and final (media -> torch -> final) — it assembles the
# app env at APP_REF on windows-media, and the final image builds FROM it. An APP_REF
# bump therefore rebuilds torch + the cheap final tail only (minutes, network-bound):
.\windows\build.ps1 -Stages torch,final               # versions.env APP_REF pin
.\windows\build.ps1 -Stages torch,final -LatestApp    # newest release tag
# On a host WITHOUT local chain images, iterate on the published image instead:
.\windows\build.ps1 -Stages torch,final -TorchBaseImage ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
# Tags: torch -> local/kataglyphis:windows-torch (-TorchTag overrides; final builds FROM it).
```

Docker layer caching is **on by default**: the Dockerfiles are ordered so that
editing one build script only rebuilds that script's stage and later ones.
`-Docker` overrides the docker.exe path (default: `$env:DOCKER_EXE`, then the
Stevedore install locations, then `docker` on PATH). Set
`KEEP_BUILD_ARTIFACTS=1` (e.g. via a temporary `ENV` line in a media
Dockerfile) to keep the `C:\temp\*-src` build trees for debugging; by default
each build script removes its source tree after installing so the trees don't
bloat the image layers.

### Mandatory GStreamer plugins (the contract)

`libav`, `opencv`, `onnx` and `tflite` are **required** in a shipped image. They
were absent from the published `winamd64` for months and nothing was red:
meson's `auto` feature state means *skip silently when the dependency is
missing*, the build logged `[INFO] not available`, and the healthcheck printed
`[PASS]` for plugins that did not exist.

The set lives in **one** place — `Get-RequiredGstPlugin`
(`windows/scripts/modules/WindowsScripts.Shared.psm1`) — and is enforced at four
points that used to disagree:

| Where | What it does | On failure |
|---|---|---|
| pre-flight, `build-gstreamer-from-source.ps1` | emits the missing `.pc` files, disables `FFmpeg.wrap`, resolves every required pkg-config module | **throws in seconds**, before a ~1 h configure+compile |
| meson setup | `-Dlibav=enabled`, `-Dgst-plugins-bad:opencv=enabled`, `-Dgst-plugins-bad:onnx=enabled` | configure fails loudly instead of skipping |
| post-install gate | `gst-inspect-1.0 <plugin>` for the whole set | **throws** — proves the plugin loads, not just that it configured |
| smoke test | same set, as assertions | **fails** the suite |

Three unrelated root causes, diagnosed against gstreamer 1.29.2 sources:

- **opencv** — `dependency('opencv4', '>= 4.0.0')`. OpenCV installs no `.pc`
  unless `OPENCV_GENERATE_PKGCONFIG` is set, and it would be named `opencv5.pc`
  anyway. Upstream dropped the old `< 4.x` upper bound, so OpenCV 5 is
  version-acceptable — it just needs a file under the name meson looks up.
- **onnx** — `dependency('libonnxruntime', '>= 1.16.1')` then `subdir_done()`.
  ORT ships no `.pc` on any platform.
- **libav** — nothing to do with `.pc` files. `subprojects/FFmpeg.wrap`
  *provides* the four `libav*` modules pinned to **FFmpeg 7.1.1**, and
  `-Dwrap_mode=forcefallback` **forces** meson to use it, so pkg-config was
  never consulted: the build was fetching and compiling a second, older FFmpeg
  instead of the `n9.0` it had just built. Even succeeding would have shipped
  gst-libav linked against a different FFmpeg than the image's own `ffmpeg.exe`.
  The wrap is now moved aside before configure.
- **tflite** — a fourth mechanism again: this plugin consults **no pkg-config
  at all**. `ext/tflite/meson.build` probes the compiler directly with
  `cc.find_library('tensorflowlite_c')` (fallback `tensorflow-lite`),
  `cc.has_function('TfLiteInterpreterCreate')` and
  `cc.has_header('tensorflow/lite/c/c_api.h')`. That header path is the
  **pre-rename TensorFlow** one, while LiteRT v2.x ships the post-rename layout
  — `build-litert-from-source.ps1` stages headers under `include\tflite\`, so
  upstream's probe could never find them regardless of any `.pc` file. It is a
  namespace mismatch, not a missing dependency, which is why it never looked
  like the opencv/onnx problem. The pre-flight mirrors the header tree to
  `include\tensorflow\lite\`, resolves the C API library by name (failing with
  the list of what *is* staged if neither candidate exists), and puts the LiteRT
  include/lib dirs on `INCLUDE`/`LIB` — the only mechanism `cc.find_library` and
  `cc.has_header` actually consult — as well as into `c_args`/`cpp_args` and the
  link args so the plugin's own compile and link succeed.

Both `.pc` files are authored by the **merge** stage, not by the OpenCV/ONNX
builds: those are the two most expensive layers in the chain (~30 and ~75
minutes) and emitting a text file is not worth invalidating them. The emitter
reads the canonical env contract (`OPENCV_ROOT`, `OPENCV_LIB`, `ONNX_ROOT`,
`ONNX_VERSION`) that the merge image already defines, finds the header root
rather than assuming it, and enumerates link names from the actual `lib`
directory so an OpenCV module-list change cannot rot into a link error.

> **`tensorfilter` is not a GStreamer plugin.** It is an NNStreamer element and
> this repo does not build NNStreamer; it appeared in the old probe lists purely
> because the lying healthcheck "found" it. Requiring it would fail every build
> forever. Wanting it means adding an NNStreamer source-build stage.

> **PROVEN 2026-08-13:** all four mandatory plugins (`libav`, `opencv`, `onnx`,
> `tflite`) build AND load in the merge image — the post-install `gst-inspect`
> gate passes for all of them. `gst-libav` compiles and loads against the image's
> own FFmpeg `n9.0` (the wrap is disabled so it links our FFmpeg, not upstream's
> pinned 7.1.1). Getting there took an OpenCV-4→5 header port of the opencv
> plugin, a `tensorflowlite_c` C-API lib for tflite, and deploying the CUDA/cuDNN
> runtime so opencv's `cudnn64_9.dll` resolves (see the merge-stage notes above
> and the `gstreamer-merge-winfix` build memory). `-SkipPluginGate` still exists
> as the deliberate escape hatch; an image built with it is not shippable.

### Toolchain pins and the provenance manifest

Everything that **produces or shapes compiled output** is pinned in
`versions.env` and asserted at base-build time by `verify-toolchain.ps1`:

| Pin | Installs | Why it is pinned |
|---|---|---|
| `LLVM_WINDOWS_VERSION` | scoop `main/llvm` | clang-cl + lld-link compile the entire media chain, and five patches under `windows/scripts/patches/` are written against a specific clang-cl's diagnostics |
| `NINJA_WINDOWS_VERSION` | scoop `main/ninja` | build-graph executor for every CMake source build |
| `NASM_WINDOWS_VERSION` | scoop `main/nasm` | assembles FFmpeg's hand-written x86 SIMD — a bump changes shipped object code |
| `CMAKE_VERSION`, `VULKAN_VERSION`, `FLUTTER_VERSION`, `GIT_VERSION` | scoop / installer | pre-existing pins, unchanged |

The LLVM pin landed **2026-08-07** and closed a real hole: the OS base is
digest-pinned (`WINDOWS_BASE_DIGEST`) for reproducibility, and the very next
layer then installed whatever clang-cl scoop served that day. A base rebuild
months later would swap the compiler silently, and the breakage surfaces ~2 h
into media-core with no way to reproduce the image that worked. It was pinned
to the version scoop was serving at the time, so it was a no-op for the next
rebuild and a guarantee for every one after. **Bump deliberately**, then re-run
`windows\scripts\tests\Test-PatchesApplyClean.ps1` against the rebuilt base.

Everything else `setup-scoop-tools.ps1` installs (7zip, nano, cppcheck,
sccache, nsis, uv, nuget, zlib, openssl, pkg-config, make, gawk) floats on
purpose — the build only *invokes* those. Move a package into the pinned block
the moment it starts linking into a shipped binary. Note `LLVM_RELEASE` is a
SEPARATE pin for the Linux lane; the two lanes move independently.

Two things still float by design and cannot be pinned the same way: the **MSVC
toolset** inside VS major 18 (setup-vs.ps1 uses the `aka.ms/vs/18/release`
channel, which refreshes within the major) and scoop's floating block. That is
what the manifest is for:

```pwsh
# in any image built after 2026-08-07
nerdctl --namespace buildkit run --rm --entrypoint pwsh <image> `
  -NoProfile -Command "Get-Content C:\toolchain-manifest.json"
```

`finalize-container.ps1` writes `C:\toolchain-manifest.json` in the base tail
layer: pinned inputs as `pin`/`resolved` pairs (so a mismatch is visible, not
inferred), the floating ones as resolved values only, plus the OS base digest
and a UTC timestamp. It answers "which compiler built this 49 GB image" from
the artifact rather than from `out\windows-build-logs\`, and it turns
classic-vs-BuildKit lane parity into a `diff` of two files. The smoke test
asserts it exists and records a resolved clang-cl (SKIP on older images).

### Build isolation and CPU parallelism

**Policy (build.ps1 `-Isolation`, default `auto`): process isolation is always
preferred and used automatically wherever the host can support it.** `auto`
runs the ~10s commit probe (`windows/diagnostics/test-process-isolation-commit.ps1`)
once per (host build, docker version) — verdict cached in
`out\windows-build-logs\isolation-probe-cache.json` — and:

- **probe passes** → every `docker build` and `docker run` gets
  `--isolation process`: full host CPUs everywhere, no 2-CPU cap. (This is the
  normal state on a Windows **Server** host whose build matches the base image
  — the recommended build environment.)
- **probe fails** (the wcifs layer-commit bug, present on client-build hosts
  mismatched against the Server base image) → falls back to `hyperv` with a
  loud warning, and everything below applies.

`-Isolation process|hyperv` forces either mode (forcing `process` on a host
where the probe fails will kill every stage at its first layer commit).

Under Hyper-V, build containers are given only **2 logical CPUs**, so
`Get-BuildJobCount` — `min(ProcessorCount, memGB / memPerJob)` — pins every
in-container `ninja -j` to 2 no matter how many cores the host has. That is the
difference between a ~1-hour and a ~6-hour ONNX/CUDA compile, so the heavy
**media-core** stage does **not** use `docker build` at all.

Two properties of `docker commit` that the run+commit path has to correct for
(both fixed 2026-08-07):

- **`commit` captures the CONTAINER's config, including `Cmd`** — which here is
  the build-script argv the stage was launched with. Left alone,
  `local/kataglyphis:windows-media` (and `windows-torch`, which inherits it)
  ship a `CMD` that RE-RUNS the GStreamer build, so a debugging
  `docker run -it local/kataglyphis:windows-media` starts recompiling over
  `C:\runtime` instead of giving you a shell. The driver now commits with
  `--change 'CMD ["pwsh"]'`. The FINAL image was never affected — a Dockerfile
  `ENTRYPOINT` resets an inherited `CMD` — which is exactly why it stayed
  invisible for so long.
- **A committed layer cannot be shrunk later**, so package-manager scratch has
  to be cleared INSIDE the container before the commit. The classic lane now
  passes `-ScrubAfter` to the media branch and merge/GStreamer runs, matching
  what the BuildKit lane already did on every compile RUN (`Clear-BuildScratch`:
  pip cache, `~\.nuget`, `%TEMP%`, INetCache). Source trees were never the
  issue — each leaf build script removes its own via `Remove-SourceBuildTree`.
  The toolchain stage is deliberately excluded on both lanes: its CPython tree
  at `C:\temp\cpython` IS the deliverable.

### BuildKit/containerd lane (PREFERRED, `windows/build-buildkit.ps1`)

**This is the lane to use from 2026-08 on** — full host CPUs on every stage,
process-isolated layer commits, and real per-stage layer caching, with the
docker-classic run+commit lane kept as the always-working fallback. **Status
2026-08-06: GREEN end-to-end and DE-WARMED** — the host snapshotter defect
(`ExportLayer 0x3`) is fixed at the root by a patched runhcs shim, so the
lane runs DIRECT solves everywhere and the warm/materialize pattern is
retired (full writeup, proof and maintenance rule in the Roadmap section's
entry; the shim is a LOCAL patch that every Stevedore update reverts).
`bk-winamd64` builds in ~44 min hot, and heavy RUN steps bind-mount their
per-file script closures instead of inheriting COPY layers. Probes on
2026-08-03 established that BOTH docker-classic limits are absent on the
buildkitd+containerd path on this same host (and the chain was then rebuilt
from base on this lane the same day — VS2026, CUDA, CPython and the media
compiles all ran as plain process-isolated layers):

| Probe | Result |
|---|---|
| process-isolated RUN + layer commit via buildctl | **works** (the wcifs `ActivateLayer 0x20` bug is a docker-writer artifact) |
| CPUs visible in a buildkit RUN step | **NPROC=32** (no 2-CPU cap) |
| container networking | none by default → **works after installing the CNI nat conf** (`C:\Program Files\containerd\cni\conf\0-containerd-nat.conf`; `nat.exe` ships in `...\cni\bin`) |
| stage handoff (`FROM` a locally built image) | **works** with fully-qualified store names (`docker.io/local/...`) + `--opt image-resolve-mode=local` (buildkit normalizes bare names to docker.io/ and otherwise tries the real registry) |

Consequences: every stage can be a plain build — the heavy compiles run as
`*-built` Dockerfile targets (toolchain-builder `built`, media-builder
`media-<branch>-built`, merge-builder `built`) with real per-stage layer
caching, and the run+commit machinery is unnecessary on this lane. The classic
lane is untouched: `build.ps1` pins `--target builder` / `--target merge`, so
docker never executes those targets.

#### Getting it going — Stevedore + BuildKit host setup (from scratch)

> The end-to-end fresh-machine sequence (including the GC-policy deploy, the
> permanent debug flags, and the repo-gate tooling that this section does not
> cover) lives in [Fresh Windows Host Bring-Up](windows-host-setup.md).

[Stevedore](https://github.com/slonopotamus/stevedore) ships the whole engine
family in one install: `docker.exe`/`buildctl.exe` under
`C:\Program Files\Stevedore\bin\`, plus the `stevedore` (dockerd), `containerd`
and `buildkitd` services. Everything below is one-time, admin unless noted.

0. **Install Stevedore** (MSI from the releases page) and put yourself in the
   **`docker-users`** local group (log out/in afterwards) — dockerd's and
   buildkitd's named pipes are ACL'd to that group, which is what makes
   non-admin builds possible. containerd's own pipe stays admin-only (only
   `nerdctl` needs it; `docker`/`buildctl` don't).

1. **Services**: all three must run; set them to delayed-auto so reboots
   self-heal:

   ```powershell
   Get-Service stevedore, containerd, buildkitd | Set-Service -StartupType AutomaticDelayedStart
   Start-Service stevedore, containerd, buildkitd
   ```

   buildkitd's service must carry `--group docker-users` in its ImagePath
   (Stevedore's default registration does:
   `buildkitd.exe --run-service --service-name buildkitd --group docker-users`).

   **Known dockerd boot-failure pitfall:** a stale
   `C:\ProgramData\docker\config\daemon.json` whose `hosts` entry conflicts
   with the service's `--host` flags prevents the `stevedore` service from
   starting at all (took a debugging session to find, 2026-08-03). If dockerd
   won't start, rename that file first.

2. **CNI networking** (without it every RUN that downloads anything fails with
   "remote name could not be resolved"): `nat.exe` already ships in
   `C:\Program Files\containerd\cni\bin`; install the conf (admin):

   **Install BOTH forms — the two clients disagree and each one silently breaks
   without its own.** Same content, two filenames:

   | File | Needed by | Symptom when missing |
   |---|---|---|
   | `0-containerd-nat.conf` (single-plugin) | **buildkitd** | RUN steps get **no network adapter at all** — empty `ipconfig`, `Could not resolve host`, and a raw TCP connect to a literal IP fails with *unreachable network* |
   | `0-containerd-nat.conflist` (plugin-LIST) | **nerdctl** | panics: indexes `plugins[0]` with no length check → `index out of range [0] with length 0`, in `network create` and again in `run` |

   > **CORRECTION (measured 2026-08-07).** This guide previously claimed
   > *"containerd and BuildKit read either form"*. **That is false**, and it cost
   > a launched chain. Converting the `.conf` to a `.conflist` on 2026-08-07
   > fixed nerdctl and silently killed buildkitd's container networking; nobody
   > noticed because no chain build ran in between. A probe container showed an
   > empty `ipconfig` and *unreachable network* on a raw TCP connect, and the
   > containerd debug log confirmed the `HcsCreateComputeSystem` spec for
   > `buildkitsandbox` carried Storage, MappedDirectories and MappedPipes but
   > **no networking block**. Restoring the `.conf` and restarting buildkitd
   > fixed it immediately (IPv4 `172.31.44.107`, gateway `172.31.32.1`, DNS
   > `192.168.188.1`, `github.com` resolved).
   >
   > `build-buildkit.ps1` now fail-fasts on this in milliseconds
   > (`Get-CniConfFormIssue`). Note the subnet-drift guard does **not** catch it:
   > it compares subnets of whichever file it finds and passed green throughout.
   > Different failure, different check. **When you edit one file, edit both.**

   ```javascript
   // C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist
   {
       "cniVersion": "0.3.0",
       "name": "nat",
       "plugins": [
           {
               "type": "nat",
               "master": "Ethernet",
               "ipam": {
                   "subnet": "<subnet of the vEthernet (nat) adapter>",   // DERIVE, don't copy (see below)
                   "routes": [ { "GW": "<that adapter's IPv4>" } ]
               },
               "capabilities": { "portMappings": true, "dns": true }
           }
       ]
   }
   ```

   **No magic subnets.** `setup-new-host.ps1` authors this file from the live
   `vEthernet (nat)` adapter (derived network/prefix + gateway) — the literals in
   older copies of these docs (`172.31.32.0/20` etc.) were snapshots of one host
   and are stale on any other. To derive by hand:
   `Get-NetIPAddress | ? InterfaceAlias -eq 'vEthernet (nat)'` → adapter IP is
   the GW, and `subnet` = network/prefix of that address.

   After writing it, verify with BOTH clients — a BuildKit RUN step that fetches
   something, and `nerdctl --namespace buildkit run --rm --network nat
   <image> cmd /c ipconfig` (admin). The second is the picky one and therefore
   the better test of this file.

   **Subnet drift warning:** dockerd recreates the `nat` HNS network with a NEW
   subnet on service restarts, silently orphaning this conf (containers then get
   unroutable IPs). `build-buildkit.ps1` fail-fasts on the mismatch at preflight
   with the exact fix; re-sync the conf to `ipconfig`'s `vEthernet (nat)` values
   (`setup-new-host.ps1 -ReportOnly` re-derives and shows any drift) and
   `Restart-Service buildkitd -Force` (plain `Restart-Service` refuses when
   dependent services exist).
3. **Windows Defender exclusions** for `C:\ProgramData\containerd` (and the
   buildkit state dir) — layer extraction races the scanner otherwise.
4. **REQUIRED for the compile stages: disable the per-step log limit.**
   buildkitd clips each RUN step's log at 2 MiB (`[output clipped, log limit
   2MiB reached]`) — and on Windows buildkitd v0.32 this is not cosmetic: after
   the clip the container's stdio pipe stops being drained, every process
   blocks on its next write, and the step **deadlocks silently** (reproduced
   twice on 2026-08-03: media-core froze ~3 min in, right at the clip, with two
   zombie ninja processes at 0 % CPU). ONNX's warning flood alone exceeds 2 MiB
   in minutes, so heavy stages cannot survive the default. One-time (admin; do
   it while no build is running — the restart kills in-flight solves, though
   buildkitd's layer cache survives):

   ```powershell
   Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd `
     -Name Environment -Type MultiString `
     -Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1','BUILDKIT_STEP_LOG_MAX_SPEED=-1')
   Restart-Service buildkitd -Force
   ```

   (`-1` = unlimited; the driver tees everything to per-stage files under
   `out\windows-build-logs\` anyway, so disk is the only cost.)
5. **sccache** (non-admin): serve a cache dir over WebDAV — e.g.
   [dufs](https://github.com/sigoden/dufs): `dufs C:\sccache-cache -p 5000 -A`
   — and export `SCCACHE_WEBDAV_ENDPOINT=http://<host-LAN-IP>:5000`; the
   compile scripts pick it up inside RUN steps (same endpoint serves both
   lanes, so the classic chain pre-warms BK builds and vice versa).
   **dufs does NOT survive reboots** (cost a failed run on 2026-08-04, and
   the warm/materialize handoff also rides this server — without it the BK
   media solves fail fast). Make it logon-persistent once:
   `schtasks /Create /TN dufs-sccache /TR "\"%USERPROFILE%\scoop\shims\dufs.exe\" C:\sccache-cache -A -p 5000" /SC ONLOGON`
   — or restart manually after a reboot and verify
   `(Invoke-WebRequest http://<host-LAN-IP>:5000 -Method Head).StatusCode`
   returns 200. Verified:
   BK's NAT'd containers reach the host's LAN IP fine.

6. **Verify** before the first long build (non-admin):

   ```pwsh
   & "$env:ProgramFiles\Stevedore\bin\buildctl.exe" --addr npipe:////./pipe/buildkitd debug workers   # worker: windows/amd64
   # network smoke: any tiny Dockerfile whose RUN resolves a hostname; or just start
   # the chain - build-buildkit.ps1's preflight guards (buildkitd reachability +
   # CNI subnet drift) fail fast with the exact fix if something is off.
   ```

Launch:

```pwsh
$env:SCCACHE_WEBDAV_ENDPOINT = 'http://<host>:5000'
.\windows\build-buildkit.ps1 -Gpu                        # full chain from base
.\windows\build-buildkit.ps1 -Stages toolchain           # one stage
.\windows\build-buildkit.ps1 -Gpu -FinalTar out\bk-winamd64.tar  # + docker-loadable export
```

> **AMD RDNA4-GPU host (RX 9xxx)?** An ENABLED RDNA4 dGPU makes every
> process-isolated RUN-layer finalize fail with `hcsshim::ActivateLayer 0x20`
> (docker/for-win#14977; A/B-proven 2026-08-10 — see
> `docs/windows-host-setup.md` and AGENTS.md Common Failure Modes). The
> preflight gate `Assert-NoActiveRdna4Gpu` refuses to start while it is
> enabled. Build window: elevated
> `pwsh -File windows\scripts\toggle-rdna4-gpu.ps1 -Disable` → build (display
> falls back to the iGPU) → re-enable with the same script (default action).
> Two extra facts that save hours: failed finalizes WEDGE hcs state until a
> reboot (don't A/B anything on a wedged host), and the severity moved with
> Windows updates (post-KB5101684 even tiny RUN layers trip — expect patch
> days to change behavior). After every Adrenalin/Windows update, re-check in
> ~2 min with `windows\diagnostics\test-rdna4-layer-lock.ps1` (elevated) —
> its GONE verdict is the signal the workaround can be retired.

Remaining gotchas (why the classic lane still exists): images land in the
CONTAINERD store (`docker.io/local/kataglyphis:bk-*`) and are invisible to
docker's windowsfilter store — running/pushing via docker needs the `-FinalTar`
export (or push straight from the BK lane with `-PushRef <ref>`, which needs a
prior `docker login` in the invoking shell). **Inspecting, running and even
building them works via Stevedore's nerdctl in an ELEVATED shell** — the full
recipe set is § nerdctl lane below.

When validating lane parity, compare each `bk-*` image's payload against the
classic tag (the same scripts and Dockerfile targets run in both lanes).

Housekeeping and sharing:

- **Never kill a solve mid-finalize — and if a snapshot is already poisoned,
  `-NoCache` the stage rather than editing the source (measured 2026-08-07).**
  A chain was deliberately aborted (`Stop-Process buildctl`) at 23 GB free to
  escape the disk danger band. The abort was the right call — the documented
  alternative is a run that dies at 4.8 GB and leaves *two* poisoned snapshots —
  but the kill itself left a **half-committed snapshot**, and the next run died
  three times on it, deterministically, with identical IDs:

  ```text
  failed to commit 3p059m2d68o… to o47dumb0ovs4… during finalize:
  failed to reimport snapshot: hcsshim::ImportLayer failed in Win32:
  cannot create a file when that file already exists          ← 0xb7
  ```

  What does NOT work: the transient-retry engine (the failure is deterministic,
  so it just burns all three attempts), and `buildctl prune` (495 MB returned —
  this debris is not a reclaimable cache record, exactly as the `CACHE-BUST`
  comments in `setup-scoop-tools.ps1` already noted).

  What DOES work, and it is cheap:

  ```pwsh
  .\windows\build-buildkit.ps1 -Gpu -Stages sdk -NoCache   # the affected stage ONLY
  ```

  That works for a top-level stage because `-Stages sdk` already narrows the
  run. It does NOT work inside `media`: `-Stages media -NoCache` re-does all
  four media-core sub-stages plus litert plus tvm plus merge, so a single
  poisoned `media-core-built-opencv` used to cost the whole fan-out. Use
  **`-NoCacheStage`** (added 2026-08-14, backlog #64) — substring-matched
  against the stage label shown in the build output and in the log filename:

  ```pwsh
  .\windows\build-buildkit.ps1 -Gpu -Stages media -NoCacheStage opencv
  .\windows\build-buildkit.ps1 -Gpu -NoCacheStage media-merge,torch   # several
  ```

  For a one-off build-arg that no driver parameter covers, `-BuildArg
  'KEY=VALUE'` forwards to every solve (validated as `KEY=VALUE`, applied last so
  it wins over a stage's computed value). The Dockerfile must declare a matching
  `ARG` for it to do anything — BuildKit warns when it does not.

  Chain-wide `-NoCache` still overrides it. Each matched stage announces itself
  (`-NoCacheStage match -> --no-cache for THIS stage only`), and an entry that
  matched **no** stage **fails the run at the end** — printing only on a match
  would have meant a typo printed nothing at all while every stage built from
  cache and the owner believed a poisoned snapshot had been busted. Under
  `-ConcurrentAux` the flag is forwarded to the child drivers, since litert and
  tvm are built by those children and a parent-only flag would be a silent
  no-op for exactly the branches it targets.

  Re-running the RUN produces a new layer digest (its output is not
  bit-identical), so every chain ID beneath it is fresh and the poisoned
  snapshot is no longer in the path. The stage that had failed 3× exported
  cleanly: `[bk:Dockerfile.nvidia] OK`, `Done in 00:17:10`, `exporting layers
  346.1s`. **Prefer this over the in-file cache-bust technique** — identical
  effect, costs one stage re-run, and leaves no comment archaeology in the
  source. Reach for a source-level bust only when the debris sits in a layer
  `-Stages` cannot isolate.

  **Corollary worth internalising: let a doomed solve fail cleanly instead of
  killing it.** A finalize that fails on its own leaves nothing behind; a kill
  during finalize leaves this.
- **Store GC — treat as MANDATORY OPS, not housekeeping.** buildkitd's store
  grows unbounded by default; iterating on the chain stacks full image
  generations (30–40 GB each) in the containerd store on every rebuild cycle.
  On 2026-08-03 disk exhaustion sabotaged one day THREE ways, each wearing a
  different costume: `hcsshim::ExportLayer 0x3` ("path not found") at snapshot
  finalize, a process-spawn flake surfacing as `'cmd.exe' is not recognized`,
  and finally an honest `ExportLayer 0x70` (disk full) — only the last one
  names the disease. If a Windows BK build fails in ANY weird hcsshim way,
  **check free disk first.** Cleanup levers, non-admin first:
  `buildctl prune --all` (build cache only), `docker image prune -f` (the
  classic lane's dangling generations — 91 GB reclaimed that day); the bk-*
  image generations themselves need admin (`nerdctl --namespace buildkit rmi`,
  or stop buildkitd+containerd and delete their state dirs for a full reset —
  dockerd may stop with containerd: `Start-Service stevedore` afterwards).
  **WIRED 2026-08-04, ACTIVE ON THIS HOST since 2026-08-05** (service
  re-registered with `--config`, rules verified via `buildctl debug workers
  -v`: reservedSpace ≈215 GB / minFree ≈27–32 GB / cachemount tier 21 GB/168h).
  Same admin session also added Defender exclusions for `buildkitd.exe`,
  `containerd.exe`, `C:\ProgramData\containerd` and `C:\ProgramData\buildkitd`
  — the 2026-08-05 night grind traced a family of finalize/export sharing-
  violation flakes to something racing the hcs scratch dirs (see the BK retry
  bullet in the roadmap). Originally wired after GC evicted the VS Build
  Tools layer between two runs (root cause, from `buildctl debug workers -v`:
  with no config file
  buildkitd runs computed defaults — `maxUsedSpace 100GB`, `minFreeSpace
  187GB`; the warm chain's cache is ~237GB on a 91%-full disk, so BOTH
  triggers fired on every GC pass and everything reclaimable — including the
  multi-hour VS layer — was evicted the moment a build's references dropped).
  The policy lives in the repo at `windows/buildkitd.toml` (three tiers; the
  load-bearing knob is `reservedSpace = 200GB`, below which GC never prunes —
  that is what protects the ~35GB VS-class layers; v0.32 key names are
  `reservedSpace`/`maxUsedSpace`/`minFreeSpace`, NOT the legacy
  `gckeepstorage`). Deploy/refresh it with
  `windows\scripts\apply-buildkitd-gcpolicy.ps1` from an admin **pwsh 7**
  shell (`pwsh -File …`; the script carries `#requires -Version 7.0`, and
  under Windows PowerShell 5.1 it refuses with a `#requires` message that is
  easy to read as "it ran and did nothing" — cost a round trip 2026-08-08,
  and matches the repo-wide rule that 5.1 appears only in the base bootstrap
  RUN) — it
  copies the toml to `C:\ProgramData\buildkitd\`, re-registers the service
  with `--config` (keeping `--debug`) and restarts buildkitd, so NEVER run it
  while a build is solving (it refuses when it sees a live buildctl unless
  `-Force`). Verify with `buildctl debug workers -v`. Keep real disk headroom
  by pruning the classic docker lane (`docker image prune -f`), not by
  shrinking `reservedSpace`. Manual fallback between chains:
  `buildctl --addr npipe:////./pipe/buildkitd prune --keep-storage 200000`.
  **Unit trap (cost a command on 2026-08-06):** `--keep-storage` is a `float`
  in **MB** and buildctl v0.32 accepts NO unit suffix — `200gb`/`250GB` die
  with `invalid value ... strconv.ParseFloat: invalid syntax`. 200 GB is
  `200000`. Same for `--keep-storage-min` and `--free-storage`. Confirm with
  `buildctl prune --help` before scripting it.
- **`--keep-storage` is the WRONG lever here — use `--free-storage`
  (measured 2026-08-06).** On buildkitd v0.32/WCOW,
  `prune --keep-storage 200000` against a 445.61 GB store returned
  `Total: 0B` — nothing deleted at all, despite `du` reporting
  `Reclaimable: 445.61GB` and every record `InUse: false`. The flags map to
  the same knobs as the gcpolicy (`--keep-storage` → maxUsedSpace,
  `--keep-storage-min` → reservedSpace, `--free-storage` → minFreeSpace) and
  only **`--free-storage`** actually drove a prune. Working invocation:

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd prune --free-storage 240000    # MB
  ```

- **`--free-storage` is a MINIMUM-FREE TARGET, not an amount to delete
  (measured 2026-08-06/07 night).** The daemon prunes until the host has that
  many MB free and then stops — so on a disk that ALREADY exceeds the target
  it deletes nothing, however much is reclaimable. Measured: at 198.5 GB free
  with 150.5 GB `Private` in the store, `prune --free-storage 200000` removed
  **77 MB**; the identical command with `900000` (more than the disk can ever
  offer) removed the full **150.48 GB**. This is also why the earlier runs
  looked like the flag "stops at the Private slice" — they were hitting their
  target, not a ceiling. **Rule: to drain everything unpinned, ask for more
  free space than the disk physically has.** It cannot over-delete: `Shared`
  records stay pinned regardless (next bullet), so an absurd target is safe.

- **A store that no prune lever can touch, with `du` reporting
  `Reclaimable: 0B` (measured 2026-08-08).** Store at 207.63 GB against
  `reservedSpace = 200GB` (= **214.75 GB**; the toml takes GiB); all 37 records
  read `Reclaimable: false` and **every** lever returned `Total: 0B`:

  > **SETTLED 2026-08-08, and it is NOT `reservedSpace`.** The cause is
  > **`Shared: true`** — records pinned by containerd IMAGE TAGS, which prune
  > can never take (see the `Private`/`Shared` bullet below; that note was
  > right all along and got overlooked twice in one day). Decisive
  > measurement: store 109.06 GB reporting `Reclaimable: 109.06GB` under a
  > **42.95 GB** reserve — far ABOVE the reserve, everything nominally
  > reclaimable — still pruned **0 B**, with `du -v` showing `Shared: true` on
  > every record. `Reclaimable` reports the LEASE state, not what prune will
  > hand back.
  >
  > Why the reserve looked causal: lowering it to 150GB coincided with an
  > admin `nerdctl rmi` of eight stage tags, and *that* is what released
  > 98.83 GB (C: 85.1 → 139.1 GB). Two changes, one observation, wrong one
  > credited. **Check `du -v` for `Shared` before touching the GC policy** —
  > the lever for `Shared` is `nerdctl rmi` / `image prune -f`, and it costs
  > you the stage images, so decide deliberately.

  ```text
  buildctl prune                                        Total: 0B
  buildctl prune --free-storage 950000                  Total: 0B   # > disk size
  buildctl prune --all --keep-storage-min 0 ...         Total: 0B
  buildctl prune-histories                              Total: 0B   # listed, freed nothing
  ```

  None of those is broken; the reserve simply forbade the work. **Check
  `reservedSpace` against `du`'s Total BEFORE reaching for a prune flag** —
  if Total < reservedSpace there is nothing any flag can do, and the only
  levers are `nerdctl rmi` (frees the containerd image store, a *separate*
  store — it took 66.5 → 85.0 GB here while buildkit's 207.63 GB did not
  move by a byte) or editing the policy and restarting buildkitd.

- **Size `reservedSpace` against FREE space, not total disk (2026-08-08).**
  The "~20-25 % of the disk" rule of thumb assumes the disk is mostly
  buildkit's. On a host where it is not, it produces an arithmetically
  unsatisfiable policy:

  ```text
  disk 930.8 GB - non-buildkit content ~637 GB = ~294 GB available to buildkit
  reservedSpace 214.75 GB                      =>  ~79 GB of working room
  highest stage disk floor (sdk)                    60 GB
  a heavy media layer's scratch, which GC may not touch   6-10 GB
  ```

  So the chain consumed room, GC was structurally unable to give any back, and
  the stage gate refused at 53.5 GB mid-media — read at the time as a disk
  problem, actually a policy one. `reservedSpace` is **150GB** now (the floor
  this file and `buildkitd.toml` already prescribed), which still exceeds the
  ~120-150 GB fresh chain spine it exists to protect and leaves ~144 GB of
  working room. Note the invariant: **`reservedSpace` + the highest stage disk
  floor must fit in the space actually available to buildkit.**

- **Prune can only ever take the `Private` slice — `Shared` is pinned by the
  image tags.** Same run: 445.61 GB → 371.77 GB, i.e. **exactly the 73.84 GB
  that `du` called `Private`**, and it stopped there (C: 31.6 → 93.3 GB free).
  The remaining 371.77 GB were all `Shared` — held by the ten `bk-*` stage
  tags in the containerd namespace, not by each other. Freeing those means
  `nerdctl --namespace buildkit rmi` (admin) FIRST, and that is not free
  disk: those tags are the hot chain, so deleting them buys GB at the price
  of a cold 5–6 h rebuild. Decide deliberately. Diagnose before pruning with

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd du --format '{{json .}}'   # then sort by Size, read Shared/InUse
  ```

  A healthy store looks like this one did: `InUse: 0` everywhere (nothing
  pinned by a live solve) but most bytes `Shared: true` (pinned by tags).
  Note also that a single chain generation is NOT waste — the "iterating
  stacks 30–40 GB generations" failure mode means DUPLICATE generations of
  the same stage tag; ten distinct stage tags of one chain are the asset.

- **A SUPERSEDED lineage hides whole duplicate copies of your most expensive
  layers — the single biggest reclaim on this host (266 GB, 2026-08-06/07
  night).** After a cache-bust rebuilds `base`/`sdk`/`toolchain`, the older
  stage tags downstream of the OLD base still exist and still pin their own
  full copy of every layer beneath them. They look innocent (distinct tag
  names, no duplicates in `nerdctl images`) because the duplication is one
  level down, in the RECORDS. Measured with 10 tags and a 384 GB store:

  ```text
  setup-cuda.ps1          109.5 GB  in 3 copies
  setup-scoop-tools.ps1    88.5 GB  in 3 copies
  setup-vs.ps1             69.1 GB  in 2 copies
  ```

  One copy per cache-bust — 267 GB of the 384 GB was the base spine held
  three times over. **Diagnose** by grouping the verbose record list by the
  script each record ran and reading `Last used`: records from a superseded
  lineage carry an older date than the current chain's rebuild.

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd du -v     # group by Description, read "Last used"
  ```

  **Fix:** admin `nerdctl --namespace buildkit rmi` on the stage tags of the
  superseded lineage, wait ~30 s for the containerd GC, then prune. Identify
  them by lineage, not by age: a stage tag is dead when its ancestor stage was
  rebuilt after it (compare image IDs against the current chain, and the stage
  logs in `out\windows-build-logs\` for the rebuild times). Deleting them costs
  nothing that a failed chain was not going to rebuild anyway. **Before
  deleting a tagged FINAL image, verify the registry copy** —
  `docker manifest inspect ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`
  — so the local one is not the only one. Sequence that produced the 266 GB:
  prune (42.4 GB) → drop canary tags + prune (15.7 GB) → drop the 6 superseded
  stage tags + prune (109.7 GB) → prune with a target above disk capacity
  (150.5 GB). C: 4.8 → 271.3 GB free, with the current lineage untouched.
- **VHDX-backed checkouts — the reclaim lever that is NOT the store.** When the
  repo (or the store) lives on a dynamically-expanding VHDX, that file only
  ever grows: deleting data inside the guest leaves the blocks allocated in the
  host file. Measured on the reference host 2026-08-06: **270.1 GB physical for
  16.1 GB of live data**, i.e. ~254 GB of dead blocks that no `buildctl prune`
  can ever touch — while C: had silently fallen to **11.7 GB free**, deep
  inside the "hcsshim gets weird before it admits disk-full" band. Lever
  (ADMIN, never while a build solves):

  ```pwsh
  pwsh -File windows\scripts\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx -ReportOnly   # look first
  pwsh -File windows\scripts\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx               # then act
  ```

  **ReFS caveat — measured, do not re-probe:** `Optimize-VHD -Mode Full` ran 42 s
  on that disk, reported success, and reclaimed **0.2 GB**. Compaction can only
  release blocks the guest reports free via UNMAP/TRIM; NTFS guests do that
  reliably, ReFS guests essentially do not. The script detects the guest
  filesystem and warns BEFORE spending the downtime. On ReFS the only reliable
  reclaim is rebuilding the VHDX around its live data (12 GB copy on this host).
  The same run still freed **19.4 GB on C:** — from killing a wedged `buildctl`
  and stopping buildkitd/containerd, which released pinned scratch. That half
  works on any filesystem, which is why the script does both.

  **When compaction returns ~nothing, rebuild instead:**
  `windows\scripts\rebuild-host-vhdx.ps1` creates a fresh disk, mirrors the
  live data into it, compares file count AND byte totals, and only then hands
  over the drive letter. It runs in two phases on purpose, because they have
  very different requirements:

  ```pwsh
  pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -ReportOnly
  pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -CopyOnly    # safe with everything open
  pwsh -File windows\scripts\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -SwapOnly `
       -VerifyPath D:\GitHub\Kataglyphis-ContainerHub -LogPath C:\rebuild.log -RetireOld
  ```

  The COPY phase touches nothing live. The SWAP phase detaches the volume and
  therefore requires that NOTHING holds a handle on it — no shell whose current
  directory is on it, no editor with the checkout open, no agent session. Run
  it from a shell on another drive, and give it a `-LogPath` off the volume.
  **This is not hypothetical:** an unattended `wsl --unmount`/detach on this
  disk on 2026-08-06 pulled D: out from under a running session and killed it.
  The script therefore refuses rather than forces the detach, and keeps the
  verified copy for a later `-SwapOnly` run. The old disk is kept as `.old`
  unless `-RetireOld` is passed — until it is deleted, NO space is reclaimed.
- **Cross-host / CI cache**: `build-buildkit.ps1 -ExportCacheRef <registry-ref>`
  / `-ImportCacheRef <ref>` wire buildkit's registry cache (`mode=max`) once
  registry auth works from buildkitd — a second machine then rebuilds the chain
  from cache instead of from source.

## nerdctl lane (admin): run, inspect, build

**Both possibilities exist and both are supported.** Verified end-to-end on the
reference host 2026-08-07. Use whichever fits the job:

| | `buildctl` (via `build-buildkit.ps1`) | `nerdctl` |
|---|---|---|
| Shell | **non-admin** | **admin, always** |
| Builds the chain | ✅ this is the production lane | ✅ works, but see "why the chain still uses buildctl" |
| Run / exec into an image | ✗ | ✅ the reason to reach for it |
| Image store admin (`images`, `rmi`) | ✗ | ✅ only way to reach the containerd store |

### One-time host requirements

1. **The CNI nat config must be a `.conflist`** — see host-setup § A5. With a
   bare `.conf`, nerdctl PANICS (`index out of range [0] with length 0`); it is
   the single thing that made nerdctl unusable here until 2026-08-07.
2. **Admin shell.** Not negotiable and not a configuration mistake: nerdctl
   opens `\\.\pipe\containerd-containerd`, which is Administrator-only.
   `buildkitd` ships `--group docker-users` (which is exactly why `buildctl`
   runs unelevated); **containerd has no equivalent** — verified against its
   full flag set and default config, `--address` only moves the pipe, it does
   not change who may open it. nerdctl opens that client for *every* subcommand,
   including `build --output type=tar`, so no output mode avoids it.
   **Do not attempt pipe-ACL hacks**: the ACL is recreated on every containerd
   restart, and containerd access is effectively machine-admin. The legitimate
   route is an upstream containerd feature request.
3. **A fresh shell.** `C:\Program Files\Stevedore\bin` is on the MACHINE PATH,
   so shells opened before Stevedore was installed will not find `nerdctl`.
   Reopen the window rather than patching `$env:Path`.
4. **`--namespace buildkit` on every command.** The `bk-*` images live in
   containerd's `buildkit` namespace; the default namespace looks empty.

### Recipes

```powershell
# --- inspect the store -------------------------------------------------------
nerdctl --namespace buildkit images
nerdctl --namespace buildkit ps -a

# --- interactive shell INSIDE a finished image (the main win) -----------------
# NOTE: no trailing command. The final image's ENTRYPOINT (entrypoint.cmd) loads
# VsDevCmd and then starts pwsh by itself.
nerdctl --namespace buildkit run --rm -it --network nat docker.io/local/kataglyphis:bk-winamd64

# once inside: verify what actually shipped
#   python -c "import cv2, onnxruntime; print(cv2.__version__)"
#   where.exe nvcc ; gst-inspect-1.0 --version

# --- one-shot command in an image WITHOUT an entrypoint ----------------------
nerdctl --namespace buildkit run --rm --network nat docker.io/local/kataglyphis:bk-windows-base cmd /c ipconfig

# --- one-shot command in an image WITH an entrypoint: override it -------------
nerdctl --namespace buildkit run --rm --entrypoint pwsh --network nat docker.io/local/kataglyphis:bk-winamd64 -NoProfile -Command "python -c 'import cv2; print(cv2.__version__)'"

# --- build (admin) -----------------------------------------------------------
# BUILDKIT_HOST is REQUIRED on Windows: nerdctl has no unix-socket default to
# fall back to, and without it the build fails to reach buildkitd.
$env:BUILDKIT_HOST = 'npipe:////./pipe/buildkitd'
nerdctl --namespace buildkit build -t local/kataglyphis:my-tag --progress plain <context-dir>

# --- housekeeping (the 266 GB lever) -----------------------------------------
nerdctl --namespace buildkit rmi docker.io/local/kataglyphis:<obsolete-tag>
```

### Why the chain still uses `buildctl`

`nerdctl build` is a wrapper that hands the solve to the same `buildkitd`. Using
it for the chain would cost, and gain nothing:

- **every build would need elevation** — the background/unattended runs this
  project depends on are non-admin today;
- **`--opt image-resolve-mode=local`** is load-bearing for stage handoff (the
  `bk-*` tags resolve from the containerd store instead of attempting a registry
  pull) and is not exposed by `nerdctl build`;
- the driver's transient-retry engine, per-stage logs and preflight gates
  (`Assert-DiskHeadroom`, `Assert-ShimPatch`) are keyed to `buildctl`.

So: **`buildctl` builds the chain, nerdctl inspects and runs its results.**

### Traps (each one cost time on 2026-08-07)

- **Passing a command to an image that has an `ENTRYPOINT`** appends it as
  entrypoint ARGUMENTS. On `bk-winamd64` that exits `255` immediately. Use no
  command, or `--entrypoint`.
- **A killed `nerdctl run` leaves a zombie**, and `nerdctl rm -f` on it can then
  BLOCK for up to 45 minutes — the patched shim waits for teardown instead of
  force-terminating (correct for builds, painful interactively). Recovery:
  `Get-Process containerd-shim-runhcs-v1,CExecSvc | Stop-Process -Force`, then
  `rm -f` again. Safe only when the container did no real filesystem work.
- **Exit code `3221225786`** (`0xC000013A`) means the container was Ctrl+C'd,
  not that the image is broken.
- **Two harmless warnings** on every run: `default network named "nat" does not
  have an internal nerdctl ID` (true — containerd created it) and
  `failed to remove hosts file` at exit. Ignore both.
- **Diagnosing a "hung" nerdctl**: check `containerd-debug.log` for the task's
  exit Span before assuming the container is stuck — it has usually exited
  already and only cleanup is blocked.

Roadmap (**mounts PROBED WORKING on Windows buildkitd v0.32, 2026-08-03** —
both `--mount=type=bind` and `--mount=type=cache` execute correctly in RUN
steps; the remaining work is the Dockerfile surgery):

- **`RUN --mount=type=bind` for build scripts**: DONE 2026-08-04 (single-file
  mounts probed working on WCOW buildkitd v0.32). The BK lane's `*-bk` stages
  in Dockerfile.media-builder + the merge builder's warm/built stages carry NO
  script/patch COPY layers — every RUN bind-mounts exactly its transitive
  script closure at `C:\bkmnt` and passes `-ScriptDir C:\bkmnt`. Editing a
  build script now re-runs ONLY the RUNs that mount it (an OpenCV fix no
  longer re-pays the 75-minute ONNX layer). Modules are mounted PER FILE too
  (2026-08-04): the in-container closure is exactly SourceBuild.Common +
  Shared + SourceBuild.Patches + SourceBuild.Cuda + Native.Common (plus
  Installer.Common for GStreamer) — the earlier whole-dir `modules/` mount
  let edits to the 24 host-only modules (BuildDriver, BuildKit, Flutter, …)
  bust every compile RUN. `load-versions.ps1` is mounted into every build RUN
  so the freshly COPY'd versions.env is re-read instead of the base image's
  baked (possibly stale) Machine env. The classic targets keep their baked
  COPYs (classic docker cannot `--mount`).
- **Concurrent aux branch solves**: available OPT-IN via
  `build-buildkit.ps1 -ConcurrentAux` (2026-08-04) — media-core stays the
  sequential long pole, then litert + tvm build side by side via child
  drivers on half the media memory budget each. Measure host RAM headroom
  before making it the default. Two costs to know: (a) children run a single
  media branch, so the GStreamer merge is gated on all three branches being
  requested and runs only in the parent (children print `[bk:merge] skipped`);
  (b) `MEMORY_LIMIT_GB` is baked as ENV in the media `common` stage, so
  TOGGLING -ConcurrentAux (which halves the aux budget) changes that ENV and
  invalidates the aux branches' compile RUNs — pick a mode and stay in it.
- **Registry push**: available via `build-buildkit.ps1 -PushRef <ref>`
  (2026-08-04) — re-solves the final image from cache with a push exporter;
  needs a prior `docker login` in the invoking shell (buildctl forwards the
  client credential store).
- **`RUN --mount=type=cache` for a local sccache dir** (WebDAV stays as the
  cross-lane L2): kills the HTTP round-trip on ~5000 compiles per stage.
  Probed working. CAUTION (2026-08-04): cache mounts get CLONED whenever the
  record is locked — fine for an L1 compile cache (worst case: cold clone,
  WebDAV L2 still hits), but never rely on two solves seeing the same instance.

  **CORRECTED 2026-08-08 — the wiring is NOT just `SCCACHE_DIR`.** This entry
  used to say "wiring = set SCCACHE_DIR to the cache mount", which alone does
  nothing: with a remote configured sccache runs in single-level *legacy* mode
  and the disk backend is simply not in the chain. Two tiers need the explicit
  chain variable (verified against mozilla/sccache `docs/Configuration.md`):

  ```text
  SCCACHE_MULTILEVEL_CHAIN = disk,webdav      # left-to-right = fast-to-slow
  SCCACHE_DIR              = <the cache mount target>
  SCCACHE_CACHE_SIZE       = <cap for the L0 disk tier>
  SCCACHE_WEBDAV_ENDPOINT  = <unchanged>
  ```

  Read-through/write-through with automatic backfill; each level keeps its own
  variables. `SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY` defaults to `l0` (a write
  failure on the local tier fails; remote-tier write errors are tolerated).

  > **DISABLED SINCE 2026-08-16 — this describes the layout we want back, not
  > the one in effect.** `SCCACHE_MULTILEVEL_CHAIN` now defaults to `""` in both
  > media Dockerfiles, so the WebDAV remote is the sole cache. The L0 tier lives
  > on a BuildKit cache mount, and on Windows those lose writes once the
  > directory holds objects an EARLIER RUN wrote. The `l0` write-error policy
  > above is what turned that into a total failure: with L0 broken, nothing ever
  > reached the remote either (`L1 writes 0`). Measurement, cause and the
  > re-enable recipe: backlog #99.

  **Version dependency this creates:** multi-tier landed in sccache **v0.16.0**
  (2026-06-19; implemented 2026-04-17, PR #2581). The image installs sccache
  from the FLOATING scoop block — measured **0.17.0** in the 2026-08-08 chain,
  so it works today. But the moment this wiring lands, sccache stops being a
  tool the build merely invokes and becomes one whose VERSION gates a feature:
  on an older sccache the chain variable is ignored and the L1 silently does
  nothing, with no error. Pin `sccache` alongside llvm/ninja/nasm if this is
  wired — the same argument that pinned those three.
- **sccache for the merge/GStreamer builder**: DONE 2026-08-04 —
  build-gstreamer-from-source.ps1 sets `CC/CXX='sccache clang-cl'` for meson
  when the remote backend is configured (this build previously ran fully
  uncached, ~30 min hot, because the merge builder never wired the endpoint).
- **Automatic transient retry in the BK driver**: DONE 2026-08-04, extended
  2026-08-05 — Invoke-BkStage retries once on `Activate/PrepareLayer 0x20` /
  ttrpc / shim-task / `rpc Unavailable` failures AND on the hcs-temp
  finalize/export flake family discovered in the 2026-08-05 night grind:
  `failed to reimport snapshot` (GetFileAttributesEx not-found variant) and
  `failed to write compressed diff` (SystemTemp\hcs* sharing violation — the
  retry saved the sdk export live that night). Two hard-won caveats:
  (a) `ImportLayer 0xb7 "already exists"` on IDENTICAL source/target
  chain-IDs across attempts is NOT transient — it is persistent snapshotter
  debris from an earlier low-disk finalize failure; non-admin remedy is a
  deliberate CACHE-BUST of the layer above it (any content change to the
  COPY'd/mounted file → new chain-IDs sidestep the debris; see
  setup-scoop-tools.ps1's 2026-08-05 header comment for the live example).
  (b) disk-full also surfaces as `failed to write compressed diff` — check
  free space before trusting the transient classification. Root causes
  addressed since: gcpolicy active + Defender exclusions for
  buildkitd/containerd (below) + ≥40 GB free-disk discipline.
- **Per-library media-core split**: DONE, and escalated on 2026-08-04 from
  4 RUN layers to **4 chained SOLVES** (targets `media-core-built-onnx` →
  `-opencv` → `-ffmpeg` → `media-core-built`, image handoffs via the
  `MEDIA_CORE_*_IMAGE` ARGs; build-buildkit.ps1 drives them in order). An
  FFmpeg-only change still recompiles nothing else — and each library's
  export is now independent of the others' finalize behavior.
- **🎯 DEFECT SOLVED (2026-08-06, patched runhcs shim).** ROOT CAUSE: the
  entire ExportLayer-0x3 family was hcsshim's hardcoded
  `const tearDownTimeout = 30 * time.Second` in
  `cmd/containerd-shim-runhcs-v1/task_hcs.go` (`close()`: shutdown wait +
  terminate wait; plus the 30 s "waiting for task to be closed" in
  `DeleteExec`). Heavy-churn WCOW silo teardown needs MINUTES — measured
  **117 s** for the OpenCV specimen (HcsShutDownComputeSystem 01:16:08 →
  notification 01:18:05) — so the stock shim terminated mid-hive-flush and
  left the scratch vhdx permanently unexportable. FIX DEPLOYED: shim built
  from hcsshim@main (81e2e01) with the constants raised to 45 min/100 min
  (zero cost on the happy path — the timer only matters when it would have
  killed the build), installed to `C:\Program Files\Stevedore\bin\
  containerd-shim-runhcs-v1.exe` (original preserved as `.exe.orig`;
  replacement needs admin + no running shim processes; containerd itself
  needs NO restart — the shim spawns per container). PROOF: first-ever
  direct OpenCV finalize+export on this host (`bk-canary-shim-opencv`,
  28.6 s export, no 0x3), confirmed per the 3× OPENCV canary rule
  (`bk-canary-shim-opencv{,2,3}` all clean, --no-cache). The lane is
  DE-WARMED since 2026-08-06: direct solves everywhere, warm/materialize
  retired (payload scripts kept in tree as the rollback path, c9586c1^).
  **MAINTENANCE:** any Stevedore/containerd update overwrites the patched
  shim — `build-buildkit.ps1`'s `Assert-ShimPatch` preflight catches it before
  the build starts. Since 2026-08-07 the check is a **SHA256 comparison**
  against the hash `deploy-shim-patch.ps1` recorded when it installed the
  binary (`C:\ProgramData\kataglyphis\shim-patch.json`), which is exact and
  cannot rot as hcsshim moves; the older size table (patched 25 332 736 for the
  env-var build, 25 329 664 for the fixed-constant build, vs stock 23 279 616)
  survives only as the fallback for a host that has not run the deploy script
  since. **Run `deploy-shim-patch.ps1` once to record the hash** — until then
  the gate warns that it is still guessing. `-ReportOnly` shows the recorded
  hash, whether the live binary still matches, the backups and the service
  environment; the same script re-installs. Rebuild recipe: scoop go + `git clone
  microsoft/hcsshim` + apply the in-tree patch + `go build
  .\cmd\containerd-shim-runhcs-v1`. **Upstream submission is FILED as a DRAFT
  PR: [microsoft/hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855)**,
  materials in-tree at `windows/upstream/hcsshim-teardown-timeout/` (issue
  text, PR description, `git format-patch`). It makes all four fixed 30 s
  limits in the binary configurable — the two in `task_hcs.go` plus the
  crash-recovery wait in `delete.go` — with **defaults unchanged at 30 s**.

  **ENV VAR NAMES — get these exactly right:**

  ```text
  CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT    e.g. 45m
  CONTAINERD_SHIM_RUNHCS_V1_TASK_CLOSE_TIMEOUT  optional; defaults to 2x teardown + 30s
  ```

  They follow the shim's existing house convention (`..._WAIT_DEBUGGER`). An
  earlier draft of this document named them `HCSSHIM_TASK_*` — those were
  INVENTED and never existed in any build. Setting a wrong name is silent:
  the shim falls back to 30 s and the defect returns with no error anywhere.
  Set them on the containerd SERVICE (the shim inherits its environment);
  `deploy-shim-patch.ps1 -ServiceEnvironment` merges them in. Note the
  upstream patch is NOT the same as a fixed-constant build: with the defaults
  it behaves exactly like stock, so a shim built from it and no env var set
  is a shim with the bug. Verify BEHAVIOURALLY with an OpenCV canary — the
  shim logs its effective timeout at Debug level, which does not reach
  containerd's log, so a quiet log proves nothing. Getting the PR merged is
  what retires the binary-size check after every Stevedore update.
  The historical bullets below are preserved for diagnosis value.
- **DEFECT PARTIALLY TAMED, NOT GONE (2026-08-05, de-warming attempted and
  ROLLED BACK same evening).** Sequence of record: (1) with the Defender
  exclusions active, a fresh `--no-cache` heavy TVM→IREE canary FINALIZED
  AND EXPORTED CLEAN (`bk-canary-0x3` — a finalize class that used to fail);
  (2) on that evidence the lane was de-warmed to direct solves; (3) the
  FIRST direct OpenCV finalize failed `ExportLayer 0x3` with the original
  signature, deterministic across retries → **OpenCV/GenAI-class churn
  still trips the defect; TVM was the wrong canary specimen.** The Defender
  exclusions remain load-bearing (they cured the hcs-temp finalize/export
  FLAKE family and evidently moved TVM-class finalizes to reliable) but do
  NOT cure the core defect. The warm/materialize pattern was RESTORED from
  git history within minutes — the preserved rollback path worked exactly
  as designed. LESSON: any future de-warming attempt must canary with
  **OpenCV** (the deterministic trigger), not TVM: same recipe as below but
  `--opt target=media-core-warm-opencv` + `--opt
  build-arg:MEDIA_CORE_ONNX_IMAGE=<current onnx tag>`; clean export three
  times in a row before touching the architecture.
  **Canary recipe (after any AV/OS/hcsshim change):**
  `buildctl build ... --opt filename=Dockerfile.media-builder --opt
  target=media-core-warm-opencv --no-cache --output
  type=image,name=docker.io/local/kataglyphis:bk-canary-0x3 --opt
  build-arg:BASE_IMAGE=docker.io/local/kataglyphis:bk-windows-toolchain
  --opt build-arg:MEDIA_CORE_ONNX_IMAGE=docker.io/local/kataglyphis:bk-windows-media-core-onnx
  --opt build-arg:MEMORY_LIMIT_GB=16 --opt
  build-arg:SCCACHE_WEBDAV_ENDPOINT=<endpoint>` (plus the standard --local/
  --opt image-resolve-mode=local flags). Clean export = that class is safe;
  `ExportLayer 0x3` at "exporting layers" = defect present, keep
  warm/materialize. Historical writeup below preserved for diagnosis value.
- **IN-CONTAINER MITIGATIONS EXHAUSTED (2026-08-05 late night, two more
  OpenCV canaries).** The shim injects `WaitToKillServiceTimeout=2147483647`
  into every container; overriding it to 5 s at payload start (probe R1)
  changed nothing — exit 0 is published instantly, `HcsShutDownComputeSystem`
  returns in ms, and the shutdown AND terminate notifications are still lost
  (30 s + 30 s timeouts in the containerd debug log), then `ExportLayer 0x3`.
  Probe R2 additionally stopped/killed every non-baseline resident before
  exit (sccache server, msdtc, AggregatorHost, SysMain, DiagTrack, UsoSvc,
  WinRM + 7 more services — verified stopped in the exit dump): same loss,
  same 0x3. Together with the earlier settle falsification this proves the
  hang is HOST-side (silo/wcifs teardown of heavy-churn scratches), not
  anything running inside the container. Upstream fingerprint:
  microsoft/Windows-Containers#547 (ltsc2025 process isolation, ~10-min
  shutdown, resources stay locked, closed unresolved). NOTE (corrected
  2026-08-06): Win11 24H2+ hosts running ltsc2025 images process-isolated
  is OFFICIALLY SUPPORTED per the version-compatibility doc (the strict
  build-match rule was relaxed for this combination) — so this is a
  reportable platform bug in a supported configuration, not an off-label
  artifact; #547 saw the same hang on a matched-build 26100 host.
  CONSEQUENCE: warm/materialize is the standing architecture on this class
  of host, not a temporary workaround. Do NOT burn more canaries on
  in-container theories; the only genuine escape hatches are a platform fix
  (Windows CU) or the containerd 2.x CimFS/UnionFS snapshotter lane (bypasses
  wcifs entirely — experimental for WCOW, unproven with the BuildKit worker).
  UPDATE 2026-08-06: the CimFS lane was TESTED AND FALSIFIED on containerd
  v2.3.3 (plugin+differ both "ok"): buildkitd with
  `--containerd-worker-snapshotter=cimfs` dies on the FIRST build step with
  `scratch snapshot without any parents isn't supported` — the cimfs
  snapshotter cannot create parentless scratch snapshots, which BuildKit
  needs even to load the Dockerfile context. CimFS is pull/run-only today;
  do not retry until a containerd release notes BuildKit/build support.
  The teardown probe remains in `bk-warm.ps1` (harmless, ~1.5 s, keeps exits
  quiet and preserves the diagnostic exit dump; removing it would cache-bust
  every warm layer for zero gain).
- **HISTORICAL (2026-08-04, worked around via warm/materialize) —
  GenAI/OpenCV snapshot finalize
  (`ExportLayer 0x3`, disk fine)**: those two layers deterministically fail BOTH finalize paths on
  buildkitd v0.32/containerd, on every fresh snapshot. A 17-probe bisection
  (2026-08-04) falsified: poisoned cache records, layer depth (14 stacked
  trivial layers export fine), defective ONNX parent (trivial layers on it
  export fine), file/dir content (a GenAI layer whose ENTIRE diff was deleted
  before step end still fails), lingering compiler daemons, vctip, bare
  .NET-Framework CLR (`MSBuild -version` layer exports clean), pending-delete
  zombies, and build-tree deletion (`KEEP_BUILD_ARTIFACTS=1` still fails).
  Clean under identical conditions: ONNX (ninja, 100-min layer), cpython
  (MSBuild), LiteRT (bazel), every trivial probe. TVM+IREE joined the failing
  set later the same morning (cmake+ninja like the clean ONNX — no build-system
  pattern survives).

  **Root-cause finding (containerd debug log, 2026-08-04 07:59):** the snapshot
  commit RACES a failing container teardown. Timeline: task exits → shim
  cleanup starts → an HCS operation inside that cleanup fails with
  `HCS_E_INVALID_STATE` (0xC0370105, "Containervorgang ist im aktuellen
  Zustand ungültig") → containerd logs `commit snapshot` **70 ms after** the
  cleanup began → 13 s later `ExportLayer` fails 0x3. The scratch VHDX is
  never cleanly released by the half-failed teardown, so the export finds no
  layer paths. Fits the clean/toxic split: layers whose containers exit with
  residual processes + heavy dirty IO (15–25-min compiles) hit the bad
  teardown state; calm exits don't.

  **How to capture the debug evidence again (admin):** set the service
  ImagePaths via registry (sc.exe quoting mangles them in PowerShell):
  `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\containerd' -Name
  ImagePath -Value '"C:\Program Files\Stevedore\bin\containerd.exe"
  --run-service --service-name containerd --log-level debug --log-file
  C:\ProgramData\containerd\containerd-debug.log'` (analog `buildkitd` with
  `--debug` before `--run-service`), `Restart-Service containerd -Force`,
  `Start-Service buildkitd, stevedore`, and
  `icacls <log> /grant "<user>:(R)"` to read it non-elevated. **Policy: debug
  logging stays PERMANENTLY ON on this host** (owner decision 2026-08-04) so
  the next snapshotter incident carries its evidence immediately. The log
  grows unbounded — if it gets large, truncate it (admin:
  `Clear-Content C:\ProgramData\containerd\containerd-debug.log`) rather than
  disabling the flags.

  **All host-level mitigations were exhausted (2026-08-04):** quiesce tail,
  msdtc/WMI stops, and a **full host reboot with a fresh container** all hit
  the identical double-timeout + 0x3 signature. Host processes show the
  container's processes DO die — the HCS shutdown *notification* is what
  never arrives (vmcompute → hcsshim callback), after which the scratch is
  never cleanly released. buildkitd v0.32 has no Hyper-V isolation option.
  **Genuine platform defect** (Win11 host 26200 + ltsc2025 + process
  isolation + heavy-churn layers; GenAI/OpenCV/TVM/GStreamer-class builds
  trip it — ONNX/cpython/LiteRT/torch never did). Worth reporting upstream:
  hcsshim (lost shutdown notification) + buildkit (commit proceeds into a
  known-failed teardown).

  **WORKING SOLUTION — the warm/materialize pattern (BK lane is GREEN
  end-to-end since 2026-08-04, `bk-winamd64` built in 44 min hot):** exploit
  BuildKit's LAZY finalization — a snapshot is only finalized when a child
  step or an exporter needs it. Per heavy library:
  1. **Warm solve** (`media-core-warm-<lib>` / merge `warm`; driver runs it
     via `Invoke-BkStage -NoOutput`): the build runs normally on the scratch;
     the artifact delta (C:\runtime + cpython site-packages, CreationTime >
     step start) leaves as ONE tar over the sccache dufs server
     (`Export-BuildHandoff`). No exporter + no child step ⇒ the toxic
     snapshot is never finalized ⇒ the defect never fires.
  2. **Materialize solve** (`media-core-built-<lib>` / merge `built`,
     exported as the handoff image): a calm seconds-long container downloads
     + extracts the tar (`Import-BuildHandoff`) — clean teardown, clean
     finalize, clean image export.
  Hard-won transport constraints baked into the helpers
  (WindowsSourceBuild.Common.psm1): cache mounts are NOT usable as the
  handoff channel (BuildKit clones them under lock — warm and materialize
  are not guaranteed the same instance; also directory RENAMES fail on
  them); call System32 tar/curl by full path (scoop-git's MSYS GNU tar
  resolves first and parses `C:\` as a hostname); pre-create every parent
  directory before extracting (bsdtar's long-path mode does not, and
  C:\runtime does not exist in a fresh materialize container); stage-local
  `ARG SCCACHE_WEBDAV_ENDPOINT` + ENV in every warm/materialize stage (ARGs
  do not cross FROM boundaries). ONNX/LiteRT keep their direct solves — they
  never trip the defect. Re-test the direct path after host OS or
  buildkitd/hcsshim upgrades: a 15-min tvm direct solve is the canary.
  Upstream issue: ready-to-file draft + preserved debug-log evidence in
  `docs/upstream/hcsshim-lost-shutdown-notification-issue.md` (+
  `containerd-debug-evidence-2026-08-04.log`).
- **Concurrent branch solves** (litert + tvm in parallel buildctl calls) —
  RAM-gated; both branches are memory-bound, so measure before enabling.

### The 125-layer budget (classic lane)

Docker's layer-chain depth is hard-capped at **125**; exceeding it fails with
`max depth exceeded` when the FIRST container of the next stage is created —
i.e. the failure lands one stage *after* the image that overspent. The classic
builder emits a layer **per instruction, metadata included** (28 separate `ENV`
lines in the merge Dockerfile cost 28 layers; consolidating them into one big
`ENV` took the merge builder from 114 → 86 layers on 2026-08-03, and the final
image from a 125 cap-hit to ~108).

Rules of thumb:

- One consolidated `ENV` per Dockerfile stage (same-instruction `${}` refs
  don't resolve — write derived paths as literals).
- Batch flat-file `COPY`s with multi-source form when the destination matches.
- After adding instructions anywhere in the chain, audit headroom:

  ```pwsh
  docker inspect <tag> --format '{{len .RootFS.Layers}}'   # per chain image
  ```

The BuildKit lane is far less exposed (metadata instructions are config-only
there), but the exported images still obey the cap when loaded into docker.

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
   ${MediaMemoryGb}g <builder> pwsh -File build-media-core-all.ps1` — runs
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

**Diagnostic / partial-alternative on hosts where build-`COPY` is broken.**
Measured 2026-08-09 — root cause RESOLVED 2026-08-10: the ENABLED AMD RDNA4
dGPU locks fresh container layers (see AGENTS.md Common Failure Modes "AMD
Radeon host" row; build with the dGPU disabled via `toggle-rdna4-gpu.ps1` —
the earlier "Adrenaline reinstall fixes it, GPU-disable does not" verdict is
SUPERSEDED):
on a host where *every* `docker build`/`buildctl build` `COPY` commits fail
(`hcsshim::ActivateLayer 0x20` on buildkit, `mkdir \\?\Volume{<GUID>}\C:.` on the
docker legacy builder — while `FROM`+`RUN` layers commit fine), the **`CommitLayer`
path via `docker run` + `docker commit` still works** and is a 30-second probe:

```pwsh
docker run --name probe-rc mcr.microsoft.com/windows/servercore:ltsc2025 cmd /c echo hi
docker commit probe-rc local/test:probe-rc      # rc 0 = CommitLayer OK; only ApplyDiff (build COPY) is broken
docker rm -f probe-rc
```

Committed version of the build probe: `pwsh -File
windows\scripts\probe-build-copy.ps1 -Heavy` (assets in
`windows/diagnostics/probe-build-copy/`; only a `-Heavy`-green verdict counts
— the light lanes stay green on hosts whose heavyweight RUN-layer finalize is
broken).

So the classic lane's **CPU-bound run+commit stages remain viable** on such a host.
Caveat: the chain cannot bootstrap end-to-end there, because the FROM images
(base/sdk/merge fan-in) themselves contain `COPY` steps that still break — every
repo Dockerfile has at least one `COPY`. Use the healthiest host for a full chain;
the run+commit path only rescues the heavy compile stages once a starting image
exists.

**2026-08-09 follow-up (SUPERSEDED 2026-08-10 — kept as history; the same-boot
A/B proved the enabled RDNA4 dGPU is the holder and the "cures" below
coincided with patch/reboot changes):**
- A **faulty AMD Adrenaline installation** (GPU + chipset) was blamed for the
  general `0x20` family; **reinstalling Adrenaline** (not GPU-disable)
  appeared to fix it.
- The buildkit-snapshotter residual — "any layer writing into an existing
  parent dir" refused, identical on buildkit 0.32.0 and 0.32.2, on all
  snapshotter names (`windows`/`native`/`windows-uvm`; see the
  `[worker.containerd]` note in `windows/buildkitd.toml`) — was cleared by a
  **Windows in-place repair upgrade** (official ISO, same build, keep
  files+apps): after it every layer commits.
- Residual on that host: only the **final export** (reimport of the committed
  snapshot) still trips `0x20`, where the Defender engine (`MsMpEng`) is
  unkillable by design and the identical Stevedore+OS stack builds the BK lane
  fine on the working machine. ⇒ host-residual; use the classic lane there or
  the healthy host.

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
failure used to re-run the whole chain (unlike a multi-`RUN` `docker build`, where
each completed step is cached). The persistent **sccache** remote (below) covers
recompilation, so in practice only uncached objects rebuild. Regression symptom
for the whole mechanism: `ninja -j2` in `out\windows-build-logs\media-core.log`,
or an `ActivateLayer` error on any commit.

**Resume after a mid-chain failure:** on a non-transient run failure, build.ps1
now PRESERVES the container (it holds every completed stage's output in
`C:\runtime`) and prints the recovery recipe:

```powershell
docker commit <container> <result-tag>-partial
docker container rm -f <container>
docker run --isolation hyperv --cpu-count <N> --memory <M>g --name <container> `
    <result-tag>-partial pwsh -NoProfile -ExecutionPolicy Bypass `
    -File C:\temp\scripts\<payload>.ps1 -ResumeFrom '<failed stage>'
docker commit <container> <result-tag> ; docker container rm -f <container>
```

`-ResumeFrom` (all three `build-*-all.ps1` payloads → `Invoke-SourceBuildChain
-StartAt`) skips the stages before the named one; an unknown name throws instead
of silently rebuilding from scratch. Pick the stage from the last
`=== <label> stage: ... ===` banner in the run log. Do NOT `docker start` the
failed container — that re-runs the original chain command from the beginning.

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

```pwsh
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
  sandbox dirs. A **Dev Drive** source additionally needs the container filters
  allow-listed once (elevated), then a remount:
  `fsutil devdrv setFiltersAllowed /volume D: "bindFlt,wcifs"`. The filter list
  is ONE quoted argument — the unquoted `bindFlt, wcifs` form previously written
  here is parsed as two arguments and fails with a bare syntax dump, which is
  the very trap
  [`windows-container-build-performance.md`](windows-container-build-performance.md)
  § *Transport B* documents. That page owns the full setup, verification and
  revert steps (including the reboot and the "allowed vs attached" distinction);
  do not restate them.
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

```pwsh
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

```pwsh
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
layer, so the WebDAV remote is the only compile cache that survives a
container. **sccache is therefore REQUIRED by default for the media stages:
build.ps1 fails fast when a media stage is requested and no reachable endpoint
is configured** (`-NoSccache` opts into a deliberate cache-less build). The
gate is media-only (`Assert-SccacheEndpoint`, `$compileStages = @('media')` in
`WindowsBuildDriver.Common.psm1`) — the toolchain stage (MSBuild/ClangCL
CPython) has no sccache wiring, so toolchain-only builds are never blocked on
an endpoint they would not use. One-time
host setup:

```pwsh
# one-time host setup (any WebDAV-capable server works; dufs is a single binary)
scoop install dufs
mkdir C:\sccache-cache
dufs C:\sccache-cache -A -p 5000

# then build with the endpoint (use an IP reachable from inside containers,
# e.g. the host's LAN IP — not localhost)
.\windows\build.ps1 -Gpu -SccacheEndpoint http://192.168.1.10:5000
```

CMake-based builds (ONNX, GenAI, OpenCV, LiteRT, LiteRT-LM, TVM) then route
clang-cl through sccache, and since 2026-08-04 GStreamer (Meson) is cached too
(`build-gstreamer-from-source.ps1` sets `CC`/`CXX` to `'sccache clang-cl'`
when the remote backend is configured). FFmpeg (MSVC/make) remains uncached.
The first build populates the cache; subsequent `--no-cache` rebuilds and
version bumps reuse unchanged object files.

> **Note (.dockerignore):** The repo `.dockerignore` must NOT contain a `windows/` exclusion — the Windows Dockerfiles COPY from the `windows/scripts/` directory within the build context. If `windows/` is added to `.dockerignore`, the COPY steps will fail with "file not found in build context". This exclusion is safe for Linux builds (which use `linux/` context) but breaks Windows builds.

## Stevedore Setup Fixes

After installing Stevedore, apply these post-install fixes. They are the canonical source and are maintained in lockstep with the project's CI requirements.

### Fix 1: Remove stale Docker Desktop daemon.json

If Docker Desktop was previously installed, its daemon config at `C:\ProgramData\docker\config\daemon.json` may specify a hosts pipe (`docker_engine_windows`) that conflicts with Stevedore's `docker_engine` pipe. Remove it:

```pwsh
if (Test-Path "C:\ProgramData\docker\config\daemon.json") { Remove-Item "C:\ProgramData\docker\config\daemon.json" }
```

### Fix 2: Change default runtime from hcsshim to runhcs

Stevedore's service defaults to the `com.docker.hcsshim.v1` runtime, but only the `io.containerd.runhcs.v1` shim binary (`containerd-shim-runhcs-v1.exe`) ships with Stevedore. Update the service binary path:

```pwsh
sc config stevedore binPath="\"C:\Program Files\Stevedore\dockerd.exe\" --run-service --service-name stevedore --group docker-users --host npipe:////./pipe/dockerDesktopWindowsEngine --host npipe:////./pipe/docker_engine --containerd=npipe:////./pipe/containerd-containerd --default-runtime=io.containerd.runhcs.v1"
```

Then restart:

```pwsh
net stop stevedore /y
net start stevedore
```

### Fix 3: Windows Defender exclusions for containerd data

Add exclusions for containerd's snapshot directories (prevents hcsshim layer commit errors — `hcsshim::ActivateLayer failed (0x20)`):

```pwsh
Add-MpPreference -ExclusionPath "C:\ProgramData\containerd"
Add-MpPreference -ExclusionPath "C:\ProgramData\nerdctl"
Add-MpPreference -ExclusionPath "C:\temp"
```

### Fix 4: docker.exe vs nerdctl (historical — pre-CNI-conf state)

Before the CNI `nat` conf was installed (2026-08-03), `nerdctl build` lacked
DNS resolution and `nerdctl run` failed outright on this host (`failed to
create default network: needs CNI plugin "nat" to be installed in CNI_PATH` —
the conf, not the binary, was missing), so `docker.exe` was the only working
tool. Current state: with `0-containerd-nat.conf` installed (see § Getting it
going, step 2) `nerdctl` works from **admin** shells; builds go through
`build-buildkit.ps1`/buildctl on the preferred lane. Stevedore's `docker.exe`
remains the classic-lane tool and needs no CNI plugin:

```pwsh
"D:\Stevedore\bin\docker.exe" build --platform windows/amd64 --no-cache -t local/kataglyphis:windows-base -f windows/Dockerfile.base .
```

## Running the Image

Run with **process isolation** to get the host's full CPU count (Hyper-V
isolation, the Windows default, exposes only 2 logical CPUs). Process isolation
is allowed here because the host build (26200) is ≥ the container base build
(`servercore:ltsc2025`, 26100):

```pwsh
& "D:\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

Drop `--isolation process` to fall back to Hyper-V isolation (stronger boundary,
but capped at 2 CPUs on this host). NAT networking and DNS work in both modes.

## Smoke Testing

**Since 2026-08-14 this runs AUTOMATICALLY as the last step of every BK chain
(backlog #44).** `build-buildkit.ps1` solves `windows/Dockerfile.smoke-gate`
against the freshly built `winamd64` image after `final`, and a failure fails
the chain. Before that, neither driver invoked the smoke test at all — a
multi-hour build ended with "Done" and zero evidence the image worked, in a repo
whose defect history is dominated by "builds fine, fails to LOAD".

Three things about the gate are load-bearing:

- **It runs through `entrypoint.cmd`, not as a bare `RUN`.** A bare RUN bypasses
  `ENTRYPOINT`, which is what loads VsDevCmd and the LLVM clang_rt ASAN runtime
  dir. Skipping it made SIX assertions fail against a perfectly good image
  (msbuild, `VCToolsInstallDir`, MSBuild+ClangCL, nvcc, ASAN). If you ever see
  that cluster fail, suspect the invocation before the image.
- **It bind-mounts the CURRENT script + modules** instead of the copies baked
  into the image, so a fix to the smoke test is re-verifiable without first
  rebuilding the whole image — the friction that let this script go unrun for a
  month. It adds no layer, so the gate never alters the artifact it verifies.
- **Coverage floors, not just "0 failures".** `-MinPassed` / `-MaxSkipped`
  (driver: `-SmokeMinPassed` / `-SmokeMaxSkipped`, defaults 40 / 24) make
  "nothing ran" a distinct failure, **exit 3 = INSUFFICIENT COVERAGE**. The
  verdict used to read only `$summary.Failed`, so a run where every section
  skipped printed "All smoke tests passed!" and exited 0. `-SkipSmokeGate`
  exists for iterating on the chain itself and says loudly that the image is
  unverified; it is not a way to ship one.

To run it by hand against an existing image:

```pwsh
# Run smoke tests inside the built container. On a GPU (nvidia-lane) image,
# ALWAYS pass -ExpectGpu: without it a broken/missing CUDA_ROOT env silently
# SKIPS the whole CUDA section instead of failing it (the gate otherwise
# cannot distinguish a legitimate CPU-only image from a damaged GPU image).
& "C:\Program Files\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64 `
  pwsh -File C:\temp\scripts\smoke-test-container.ps1 -ExpectGpu
```

The smoke test validates 22 categories including CUDA Toolkit 13.3, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, TVM (source-built), IREE (source-built; native MLIR→vmfb compile + local-task execution, a CUDA-target compile-only assert on the GPU lane, and a python `iree.compiler`→`iree.runtime` end-to-end), FFmpeg (source-built with DNN/ONNX integration), compiler integration, environment-pointer integrity, and Python bindings. **Current baseline (2026-08-14, via the automatic gate): 184 passed / 0 failed / 1 skipped (185 total)** — the single skip is GPU device passthrough, blocked by the host/base OS-build skew. This supersedes the long-stale 2026-07-14 figure of 167/0/1, which predated the mandatory-plugin assertions, the `SCOOP_GLOBAL_SHIMS` checks, the bulk DLL-load enumeration (#57 — it alone load-tests 65 OpenCV DLLs where one was tested before) and the LiteRT export asserts (#67). Record the new figure here from each green run; a HIGHER count is growth, not a regression. Growth over the 153 baseline: the PyAV asserts (staged `av-*.whl` + an in-memory mpeg4 encode through the container-built FFmpeg) and the IREE suite (section 22 native compile+run incl. a CUDA-target compile-only assert, wheel-pin + `--version` asserts, section 20 staged-wheel + python end-to-end asserts, section 19 `IREE_ROOT`/`IREE_BIN` pointers).

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

The **toolchain** pins are asserted one layer earlier instead — clang-cl, ninja
and nasm are checked against `versions.env` by `verify-toolchain.ps1` during the
BASE build, where a mismatch costs seconds rather than surfacing two hours into
media-core. This suite deliberately keeps only a well-formedness check on
clang-cl (plus a non-fatal warning when the image's baked pin disagrees), because
it also runs against PUBLISHED and older images whose compiler legitimately
predates the current pin — failing those would make it useless as a regression
gate. It does assert that `C:\toolchain-manifest.json` exists and records a
resolved compiler, skipping on images built before the manifest existed.

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
like `mpeg4`/`libx264` by name). `FFMPEG_VERSION` is pinned to the release tag
`n9.0` since 2026-08-04 (it previously tracked `master`, which is when an
upstream drop moved `avformat.lib` et al. from `lib\` to `bin\` overnight —
2026-07-13, PyAV died with LNK1181). `build-ffmpeg-from-source.ps1` still
normalizes the import-lib layout after `make install` as a guard across tag
bumps: every `.lib`/`.def` is
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

- **Ref**: `build.ps1` uses versions.env's **`APP_REF` pin by default** (the
  same commit always builds the same final image); pass `-LatestApp` to opt
  into resolving the app repo's newest release tag at build time via a live
  `git ls-remote` (the old always-on behavior). The resolved ref reaches the
  Dockerfile as the `APP_REF` build-arg, so moving the app busts exactly the
  torch-step layer.
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
  — real torch/torchvision/ORT-inference/OpenCV work). The check inventory is
  the app's per-tag choice, so the expected pass count moves with `APP_REF`;
  the rule on this lane is: **all checks pass except a single WARN for the
  litert skip** (the `ai-edge-litert` limitation above), plus any checks the
  pinned app tag does not yet ship (e.g. an iree check counts only once a tag
  includes it). Smoke section 21 re-runs the same verification offline on
  every suite run.
- **Usage**: `C:\opt\Kataglyphis-Orchestr-ANT-ion\.venv\Scripts\python.exe`
  (or `uv run` from `TORCH_APP_DIR`) is a ready environment where
  `import onnxruntime, onnxruntime_genai, cv2, tvm, torch` all resolve to the
  source-built wheels plus the app's locked PyPI dependency set.

## Windows Script Reference

The **authoritative per-script table** for the Windows lane (AGENTS.md § Windows Build Notes points here — update THIS table, never a copy). Rows marked **HOST maintenance** run on the build host, need the stated elevation, and must never run while a build solves.

| Script | Location | Purpose |
|--------|----------|---------|
| `build-onnx-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper |
| `build-onnx-genai-from-source.ps1` | `windows/scripts/` | Source-built directly via CMake+clang-cl (bypasses `build.py` which always builds examples). Loads VsDevCmd via `vswhere`, clones git tag, runs `cmake`/`ninja` directly. CUDA enabled (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll` alongside the DML-enabled `onnxruntime-genai.dll`. |
| `build-opencv-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch |
| `build-litert-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl; GPU delegate (Vulkan+OpenCL), XNNPACK, external CUDA delegate. Injects + builds the TFLite C-API `tensorflowlite_c` shared lib (`WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) for gst's tflite plugin |
| `build-litert-lm-bazel.ps1` | `windows/scripts/` | **PRIMARY LiteRT-LM builder.** Self-installs bazelisk + Temurin JDK; `bazelisk build //runtime/engine:litert_lm_main --config=windows` → `litert_lm_main.exe` through the smoke gate. Neutralizes the base image's Android env/WORKSPACE pollution; patches the WORKSPACE zlib URL to the GitHub release mirror (zlib.net is flaky). `output_base` stays container-local (wcifs rename hazard) |
| `build-litert-lm-from-source.ps1` | `windows/scripts/` | **FROZEN FALLBACK** (superseded by the Bazel builder above). Ninja+clang-cl; carries the v0.14.0 export-bridge patch stack (`[LiteRTLM-winfix export-stubs]` / `[LiteRTLM-winfix support-graft]` / v0.14 orphans + deps blocks) — all gated on the breakage so they self-retire when upstream's CMake catches up |
| `stage-cuda-runtime.ps1` | `windows/scripts/` | Runs in the merge's `cuda-runtime-stage` (derived from media-core). Recursively FLATTENS the CUDA_ROOT/CUDNN_ROOT DLLs into one dir COPY'd to `C:\runtime\cuda-runtime\bin` on PATH (cuDNN 9 buries DLLs in a CUDA-major subdir); hard-gates on `cudnn64_9.dll`. Fixes opencv's plugin load in the non-nvidia merge image |
| `build-tvm-from-source.ps1` | `windows/scripts/` | Ninja+clang-cl; auto-detects CUDA/Vulkan/LLVM; builds Python wheel; VsDevCmd for MSVC STL headers |
| `build-ffmpeg-from-source.ps1` | `windows/scripts/` | MSYS2 `make` with `--toolchain=msvc`; `--enable-libonnxruntime` links against the source-built ONNX Runtime. Loads `versions.env` via `load-versions.ps1` for the centralized `FFMPEG_VERSION` tag pin. Falls back to BtbN pre-built GPL binary on source-build failure (`FFMPEG_SOURCE_BUILD=0` sentinel). |
| `build-gstreamer-from-source.ps1` | `windows/scripts/` | Meson+clang-cl with wrap pre-extraction; loads `versions.env` via `load-versions.ps1` |
| `WindowsSourceBuild.Common.psm1` | `windows/scripts/modules/` | Reusable build helpers: `Invoke-GitClone`, `Invoke-CmakeConfigure`, `Get-SourceBuildVersion`, `Get-CudaRoot`, `Enter-VsDevCmdEnvironment`, `Invoke-SourcePatch` (idempotent, reverse-check, patch.exe fallback), `Edit-CppKeywordAlternatives`, `Update-NinjaFile`, `Initialize-SourceBuildEnvironment`, `Initialize-ToolchainPythonEnvironment`, `Get-GpuEnvironment`, `Resolve-TensorRtRoot`, `Get-WindowsX86SimdFlags`, `Get-WindowsX86Avx512Flags` |
| `setup-vs.ps1` | `windows/scripts/` | Installs VS Build Tools 18 with ClangCL toolset |
| `setup-scoop-tools.ps1` | `windows/scripts/` | Installs Git (installer) + WiX 4 (dotnet tool), then via Scoop: 7zip, Vulkan SDK, Flutter, LLVM, ninja, sccache, cppcheck, nano, nsis, uv, nuget, zlib, nasm, openssl, pkg-config, CMake. Installs **no** Rust (rustup via `setup-rust-toolchain.ps1` is the sole provider). **PINNED from versions.env (2026-08-07): LLVM/ninja/nasm** (`LLVM_WINDOWS_VERSION`/`NINJA_WINDOWS_VERSION`/`NASM_WINDOWS_VERSION`, forwarded as Dockerfile ARGs) on top of the existing CMake/Vulkan/Flutter/Git pins — those three produce or shape compiled output, and an unpinned clang-cl made the base image unreproducible in its most load-bearing component (five patches under `windows/scripts/patches/` are clang-cl-version-shaped). `verify-toolchain.ps1` asserts all three at base-build time. The rest stay floating deliberately — the build only invokes them. **Caveat (2026-08-08): that justification stops holding for `sccache` the moment multi-tier caching is wired** — the L0 tier then exists or not depending on the installed version (needs >= v0.16.0), and an older one ignores the config **silently**. Pin sccache in the same change, not after |
| `setup-vcpkg.ps1` | `windows/scripts/` | Bootstraps vcpkg for Windows |
| `setup-rust-toolchain.ps1` | `windows/scripts/` | Installs Rust via rustup WITH a stable default toolchain (sole provider; local `file://` dist mirror dodges rustup's downloader deadlock in 2-CPU containers), runs Cargokit-shaped asserts, bakes `flutter_rust_bridge_codegen` |
| `setup-cuda.ps1` | `windows/scripts/` | Installs CUDA 13.3 + cuDNN; includes post-install verification (headers/libs/DLLs) |
| `setup-tensorrt.ps1` | `windows/scripts/` | Auto-detects a TensorRT zip in `windows/downloads/` and installs it |
| `load-versions.ps1` | `windows/scripts/` | Reads `C:\temp\versions.env` (COPY'd from `linux/scripts/01-core/versions.env`) and sets matching process env vars so Windows build scripts consume the same canonical versions as Linux |
| `finalize-container.ps1` | `windows/scripts/` | Enables git long paths and sets `core.longpaths` in the final image; writes the **toolchain provenance manifest** `C:\toolchain-manifest.json` (2026-08-07) — pinned inputs with pin-vs-resolved pairs (LLVM, ninja, nasm, CMake, Vulkan, Git, Flutter, VS→MSVC toolset, SDK build) plus the floating ones (lld-link, rustc/cargo, sccache, uv, pwsh, openssl, pkg-config) and the OS base digest. Answers "which compiler built this image" from the ARTIFACT instead of a build log that ages out, and makes classic-vs-BK lane parity a `diff`. Every probe is best-effort (missing tool → `null`, never a failed layer) |
| `verify-toolchain.ps1` | `windows/scripts/` | Verifies clang-cl, lld-link, WiX, Flutter are present after base setup, and ASSERTS the pinned versions (clang-cl/ninja/nasm/CMake vs `versions.env`) — a silent scoop fallback otherwise surfaces ~2 h into media-core as a patch that no longer applies |
| `healthcheck.ps1` | `windows/scripts/` | Docker `HEALTHCHECK` script — verifies ONNX Runtime DLL, FFmpeg, GStreamer, CMake, clang-cl |
| `smoke-test-container.ps1` | `windows/scripts/` | Comprehensive container validation — **22** test categories (an earlier AGENTS.md copy of this row said 18 until 2026-08-08; this doc had the right count all along). Runs INSIDE the final image, which `windows/Dockerfile` COPYs it into along with the whole `modules` dir. The 22 sections live here; the assertion harness is in `WindowsSmokeTest.Common.psm1` |
| `WindowsSmokeTest.Common.psm1` | `windows/scripts/modules/` | Smoke-test assertion harness, extracted 2026-08-08: counters plus `Initialize-SmokeTestRun`, `Get-SmokeTestSummary`, `Assert-Test`, `Assert-CommandExists/FileExists/DirectoryExists/ArtifactPresent/NativeLinkRun/DllLoads/EnvVarSet`, `Skip-Test`, `Write-TestHeader`. **Call `Initialize-SmokeTestRun -ExitOnFirstFailure:$ExitOnFirstFailure` before the first assertion, and read counts via `Get-SmokeTestSummary`** — the module has its own session state, so `$script:passed` read from a caller resolves to a different, always-zero variable, and a script parameter is invisible to the module. Both failure modes are silent, which is why they are unit-tested |
| `WindowsGstPlugins.Common.psm1` | `windows/scripts/modules/` | The mandatory GStreamer plugin CONTRACT (see § Mandatory GStreamer plugins and AGENTS.md § Windows Build Invariants): `Get-RequiredGstPlugin` (libav/opencv/onnx/tflite with per-plugin detection mechanism and rationale), `Write-PkgConfigFile`, `Get-LibraryLinkName`, `Assert-PkgConfigModule` (presence AND `-MinimumVersion` floors — `pkg-config --exists` alone passes on a `.pc` whose version field is empty). Merge-stage only, deliberately NOT in `WindowsScripts.Shared.psm1`: that one is in all three media branches' compile closure and this set changes often |
| `Measure-BuildWarnings.ps1` | `windows/scripts/` | Counts compiler warnings in a build log grouped by diagnostic family; `-Baseline` prints the four known upstream floods against their pre-suppression counts with a verdict per family. Run it after a chain to PROVE the targeted `-Wno-` flags (OpenCV/ONNX/TVM) and IREE's `_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING` still earn their place — 16 % of one chain log was upstream warnings, and buildkitd clips a RUN step at 2 MiB then deadlocks it |
| `deploy-shim-patch.ps1` | `windows/scripts/` | HOST maintenance (admin, never while a build solves): installs a locally built `containerd-shim-runhcs-v1.exe` over Stevedore's, keeping `.orig` (stock, written once) plus a timestamped backup per deployment, and optionally merges env vars into the containerd service (`-ServiceEnvironment`) since the shim inherits them. `-ReportOnly` lists installed binary, backups and env without touching anything; `-Restore .orig` / `-Restore .45min` puts a backup back. Refuses while `buildctl` or a shim process is alive (the binary is locked). Needed because every Stevedore/containerd update silently reverts the patched shim — see § BuildKit/containerd lane and `windows/upstream/`. NB: a quiet log is NOT proof it took effect (the shim logs its effective timeout at Debug, which does not reach containerd's log) — verify behaviourally with the OpenCV canary |
| `setup-new-host.ps1` | `windows/scripts/` | HOST bring-up (admin, run `-ReportOnly` first, never while a build solves): the ONE elevated run that turns a freshly-rebooted Stevedore host into a green `verify-host-setup.ps1`. Orchestrates the canonical per-concern scripts rather than duplicating them: authors the CNI `.conflist` from the LIVE `vEthernet (nat)` subnet (derived network/prefix+GW at runtime — no magic subnet literals anywhere), then `apply-containerd-config.ps1` (derives the `.conf`, debug flags, teardown env, Defender), `apply-buildkitd-gcpolicy.ps1` + the `BUILDKIT_STEP_LOG_*` step-log env, the patched runhcs shim (BUILDS the 45min/100min fixed-constant shim from hcsshim source when no `-ShimPath` is given, installing Go via scoop — the recipe from `windows/upstream/`, then `deploy-shim-patch.ps1`), and dufs (scoops if missing, starts it, registers the ONLOGON task, sets machine `SCCACHE_WEBDAV_ENDPOINT` to the host's LAN IP). Idempotent; every sub-script is called with a HASHTABLE splat (array splatting would bind `-ReportOnly`/`-ShimPath` by position — the array-splat rule in AGENTS.md). Companion to `verify-host-setup.ps1` below |
| `toggle-rdna4-gpu.ps1` | `windows/scripts/` | HOST maintenance (admin): enable/disable the RDNA4 dGPU in Device Manager (`-GpuName` overrides the RX 9070 XT default — the gate fires for ALL RX 9xxx/R9700 SKUs, so the remedy must reach them too; added 2026-08-10 W1). **RE-INSTATED 2026-08-10 as the RDNA4 build-window workaround** (the 2026-08-09 "obsolete" verdict is superseded): an enabled RDNA4 dGPU kills every process-isolated RUN-layer finalize (`ActivateLayer 0x20`, docker/for-win#14977; A/B-proven). Workflow: `-Disable` → build (display falls back to the iGPU) → default action re-enables. `build-buildkit.ps1`'s `Assert-NoActiveRdna4Gpu` preflight refuses while the dGPU is enabled. |
| `probe-build-copy.ps1` | `windows/scripts/` | The committed build probe (assets `windows/diagnostics/probe-build-copy/`): `FROM servercore` + `RUN` + `COPY`, BK lane exporting `type=image,...,unpack=true` (the real lane's output path), per-lane exit codes; `-Heavy` adds the heavyweight-RUN finalize lane (the shape the RDNA4 interaction kills), `-Docker` the classic-builder lane. **Run `-Heavy` before trusting a new Windows host** — only a `-Heavy`-green verdict counts (light lanes stayed green while the chain died, 2026-08-10). No admin. |
| `test-rdna4-layer-lock.ps1` | `windows/diagnostics/` | RDNA4 layer-lock A/B (ELEVATED): probes RUN-layer finalize with the dGPU enabled, then disabled (auto re-enables in a finally). Verdicts: GONE / PRESENT / INCONCLUSIVE. **Re-run after every Adrenalin or Windows update** — a GONE verdict is the signal to retire the toggle workflow + `Assert-NoActiveRdna4Gpu` gate (docker/for-win#14977 tracked upstream). |
| `verify-cuda-cache.ps1` | `windows/diagnostics/` | CUDA-cache probe (non-admin, ~2 min, safe beside a live build): tiny buildctl solve FROM the local toolchain image compiles one `.cu` TWICE through sccache against the live WebDAV endpoint; exit 0 only when the recompile HIT (per-component: CUDA/Device/PTX/CUBIN) AND objects landed in the store. Verified 2026-08-10 (4/4 hits, 4 objects on disk). **Run after every sccache bump** — the launcher's value rests on this property. |
| `collect-host-docker-state.ps1` | `windows/scripts/` | Cross-machine forensics for "works there, fails here": dumps OS build, optional features (DISM API health - reports "Klasse nicht registriert" when broken), filter drivers, services, engine versions, docker info, HNS. Writes `out\host-docker-forensics.txt`. Elevation needed for feature/fltmc reads. |
| `reset-container-stores.ps1` | `windows/scripts/` | HOST maintenance (admin, never while a build solves): full container-store reset - stops the services, RENAMES `C:\ProgramData\containerd`/`buildkitd`/`Docker` to `.bak-<stamp>` (rollback), restarts clean, re-deploys the GC-policy toml. The docs' last resort for persistent, non-release hcsshim weirdness; safe on a fresh host (stores re-pull). |
| `sync-defender-exclusions.ps1` | `windows/scripts/` | HOST maintenance (admin): prints, then applies if missing, the FULL Defender exclusion set for Windows-container builds - paths (`C:\ProgramData\containerd`/`buildkitd`/`Docker`/`nerdctl`, `C:\ProgramData\Microsoft\Windows\Containers`, `C:\temp`, `C:\WINDOWS\SystemTemp`) and processes (dockerd/containerd/buildkitd/nerdctl/CExecSvc/vmcompute). READ the BEFORE output: non-admin cannot see `Get-MpPreference`, so this is the only proof exclusions were ever applied. |
| `repair-windows-componentstore.ps1` | `windows/scripts/` | HOST maintenance (admin, long-running 10-40 min): `DISM /Online /Cleanup-Image /RestoreHealth` + `sfc /scannow`, re-tests the DISM API (was `Klasse nicht registriert` on the reference-discovered box), then re-runs the 3-layer probe. The OS-level repair step for hosts where container-layer ops fail and everything else is clean. |
| `verify-host-setup.ps1` | `windows/scripts/` | The machine-checkable form of `docs/windows-host-setup.md` — run it FIRST on any new machine, and after any host change. Non-admin: services, `buildctl` reaching buildkitd unelevated, nerdctl presence, **BOTH CNI forms** (`.conf` for buildkitd — missing is a FAIL; `.conflist` for nerdctl — missing is a WARN) plus content agreement between them and subnet-vs-adapter drift, patched runhcs shim **by SHA256** against the hash `deploy-shim-patch.ps1` recorded at install (size only as a fallback, reported as a WARN so "still guessing" is visible), containerd teardown env var + debug flags, worker snapshotter + gcpolicy, disk headroom **on C: AND the repo/build-context drive**, sccache reachability. Exit 1 on any FAIL; each failure prints its fix. Defender exclusions are reported UNKNOWN (not skipped) when unelevated, so their absence cannot masquerade as success. Registry values that do not EXIST (e.g. the containerd `Environment` value before the first apply) degrade to WARNs, not a mid-run crash (fixed 2026-08-09 — the old `(Get-ItemProperty ...).Environment` threw PropertyNotFound at line 212 and silently skipped the teardown-env + debug-flag checks, under-counting the verdict). **Keep it in step with the guide — they are two views of one contract**; the guide had shipped a broken CNI template for days precisely because prose cannot be executed |
| `apply-containerd-config.ps1` | `windows/scripts/` | HOST config (admin, never while a build solves — applying restarts containerd and kills in-flight solves). The containerd counterpart to `apply-buildkitd-gcpolicy.ps1`: containerd runs with NO `config.toml` on this host, so its settings live only in the service's `ImagePath`/`Environment` registry values and existed nowhere in the repo until 2026-08-07. Owns: `--log-level debug --log-file` (permanent owner policy — truncate the log, never disable the flags), `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT` (the runhcs shim inherits the SERVICE environment; a shim built from the upstream patch keeps its 30 s defaults and silently reverts to the 0x3 defect without it — `TASK_CLOSE_TIMEOUT` stays unset on purpose, the patch derives it as 2×teardown+30 s), and the load-bearing Defender exclusions (otherwise invisible: `Get-MpPreference` needs admin). `-ReportOnly` shows drift without admin and changes nothing |
| `compact-host-vhdx.ps1` | `windows/scripts/` | HOST maintenance (admin, never while a build solves): reclaims disk when the checkout/store sits on a dynamically-expanding VHDX. Kills stale `buildctl`, stops the build services, detaches → compacts (`Optimize-VHD`) → reattaches read-write in a `finally`, restarts. `-ReportOnly` reports sizes/guest-fs/reclaim potential without touching anything. Machine-specific values are all parameters (`-VhdxPath` mandatory, `-Service`, `-BlockingProcess`, `-VerifyPath`, `-LogPath`, `-Mode`). Warns on ReFS guests, where compaction reclaims ~nothing (measured: 0.2 GB of a possible 254 GB) — see § Store GC. When it reports a near-zero reclaim, `rebuild-host-vhdx.ps1` is the answer |
| `repro-sccache-cuda-llm-deadlock.ps1` | `windows/scripts/` | **Deliberately fails.** Reproduces the sccache nvcc server deadlock and collects a server-side trace for mozilla/sccache#2808. Sets `SCCACHE_REPRO_CUDA_LLM=1`, which makes `build-onnx-from-source.ps1` SKIP patch 006 so the sccache CUDA launcher stays on for `onnxruntime_providers_cuda_llm` — the target the workaround exists to protect. Expect the build to die ~80 min in; that failure IS the artifact. Refuses to start while another `buildctl` is running (a concurrent build shares the sccache server and the locked mount, so a wedge would be unattributable). Needs `ARG SCCACHE_REPRO_CUDA_LLM` wired into `Dockerfile.media-builder`'s media-core-env stage first — it checks and throws with instructions if absent. |
| `Dockerfile.smoke-gate` | `windows/` | Not a script — the automatic verification stage (backlog #44). Solved against the finished `winamd64` image as the last step of every BK chain; a smoke-test failure fails the chain. Runs a buildctl solve rather than `nerdctl run` because containerd's pipe is admin-only while the driver is non-admin, invokes the test **through `entrypoint.cmd`** (a bare RUN bypasses ENTRYPOINT and loses VsDevCmd + the ASAN runtime dir), and **bind-mounts** the current script + modules so a smoke-test fix needs no image rebuild to re-verify. Knobs: `-SkipSmokeGate`, `-SmokeMinPassed`, `-SmokeMaxSkipped`. |
| `patches/litert-lm/patch-assert.cmake` | `windows/scripts/` | `patch_replace_required` / `patch_regex_replace_required` — replace-with-verification for the CMake source patchers (backlog #56). `FATAL_ERROR`s when a pattern matched NOTHING, instead of the old bare `string(REPLACE)` + unconditional "Patched …" message that let an upstream reformat silently restore a fixed defect. Lives INSIDE `litert-lm/` because the Dockerfile COPYs that directory specifically. Enforced by `Patches.CmakeNoOpGuards.Tests.ps1`; a legitimate non-source replace opts out with a `patch-assert-exempt` marker + reason. |
| `normalize-tensorrt-tree.ps1` | `windows/scripts/` | Bind-mounted into `Dockerfile.nvidia`'s `trt-extract` stage. Renames the extracted `TensorRT-<version>` tree to a stable **`current`** so the runtime PATH never spells the pin, WARNS (never fails) on pin-vs-zip drift, and **fails closed** when neither `bin\` nor `lib\` carries runtime DLLs. Backlog #38: the old pin-derived PATH was wrong twice over — wrong version AND wrong dir (TensorRT 10+ moved the DLLs to `bin\`), so the ORT TensorRT EP could never load, silently, while builds stayed green. Absent zip stays a supported graceful skip; a half-extracted tree is a build failure. |
| `bootstrap-pwsh.ps1` | `windows/scripts/` | Installs PowerShell 7 as the FIRST RUN of `Dockerfile.base`, BIND-MOUNTED (no layer). Runs under Windows PowerShell **5.1** — the SHELL is not switched to pwsh until after it — so keep it 5.1-safe and do not use `Invoke-DownloadWithRetry` (no module is mounted that early). Carries its own 3-attempt retry with an in-loop SHA256 check. Extracted from a 1214-char inline RUN (backlog #27). |
| `probe-sccache-write.ps1` + `run-sccache-write-probe.ps1` + `Dockerfile.sccache-write-probe` | `windows/scripts/`, `windows/` | Reproduces the sccache **cache-write** environment in ~2 min instead of a 90-min media build (backlog #99): same cache-mount ids, same ENV, then a configuration matrix (`disk-only`, `disk-mounted-subdir`, `disk-plaindir`, `multilevel-mounted`, `multilevel-plaindir`, `webdav-only`), raw filesystem tests, a process-spawn matrix, a bisect of the cache root, serial-vs-parallel and path-length sections. **Run it against the REAL base image** (`-BaseImage local/kataglyphis:bk-windows-media-core-ffmpeg`), not the toolchain default. **Health warning:** it reproduces the ENVIRONMENT but not the FAILURE — every configuration it blessed then failed in a real build, so treat its verdicts as hypotheses to test in a build, never as clearance. `PROBE_NONCE` + a `probe complete` marker check exist because an unchanged script gives `#6 CACHED` and silently replays an old verdict; `--no-cache` is not the alternative (it empties cache mounts, #96). |
| `probe-opencv-video-backends.ps1` + `run-opencv-video-probe.ps1` + `Dockerfile.opencv-video-probe` | `windows/scripts/`, `windows/` | Asks a BUILT media image what video backends OpenCV actually has (backlog #93-#95): prints the `Video I/O:` block, runs the three #95 assertions, and shows `videoio_registry.getBackends()` beside them. ~4 s against `bk-windows-media-core-ffmpeg`, versus a full chain rebuild — which is what let the #95 guards be watched FAILING on the real artifact before the fixes land. Same two safeguards as the sccache probe: `PROBE_NONCE` (a re-run with an unchanged script otherwise gives `CACHED` and replays an old verdict) and a `probe complete` marker check; `--no-cache` is not the alternative, it empties cache mounts (#96). |
| `rebuild-host-vhdx.ps1` | `windows/scripts/` | HOST maintenance (admin, never while a build solves): reclaims a dynamically-expanding VHDX by REBUILDING it around its live data — the only reliable reclaim on ReFS guests, where `compact-host-vhdx.ps1` returns ~nothing. Creates a fresh dynamic disk, reproduces the source's filesystem/label/cluster size (and Dev Drive flag where `Format-Volume -DevDrive` exists), mirrors with `robocopy /MIR /COPYALL`, then verifies file count AND byte totals before anything is swapped. TWO PHASES on purpose: `-CopyOnly` touches nothing live and is safe with editors/agents still on the volume; the swap DETACHES the volume and so requires that no process holds a handle on it (a stray detach on 2026-08-06 pulled D: out from under a running session and killed it) — it REFUSES rather than forces, keeping the verified copy for a later `-SwapOnly`. Old disk kept as `.old` unless `-RetireOld`; **no space is reclaimed until it is deleted.** Failed swaps roll back to the original disk automatically. Parameters: `-VhdxPath` mandatory, `-NewSizeGB`, `-NewVhdxPath`, `-Service`, `-BlockingProcess`, `-VerifyPath`, `-ExcludeDir`, `-LogPath`, `-ReportOnly`, `-CopyOnly`, `-SwapOnly`, `-RetireOld`, `-Force`. Put `-LogPath` off the volume for swap runs |

## Refactor Backlog (Windows container chain)

> **COUNTING NOTE:** item numbers are HISTORICAL and never reused — the highest
> number is not the item count. Resolved narratives move to the dated archives
> (`windows-backlog-archive-*.md`); a bare "#N" that is not in this file
> resolves there. Lean-OPEN-only is the owner''s standing policy.

### CURRENT SEQUENCE (the one list — batches A–D/G completed, see archive)

> Ordered by what unblocks what; the verification chain is the bottleneck, not
> the code. One experiment per build.
>
> **2026-08-17 late: steps 1+2 are DONE-GREEN** (verify10–15 + final; smoke
> gate 190 passed / 1 skipped / 0 failed). That run verified #93/#95/#65/#66/#88
> end-to-end and en passant surfaced+fixed: the #47 TVM LLVM heal (own minimal
> LLVM — scoop has none, dev tarball is /MT), the Anubis/`.git` wrap-download
> pair, graphene's clang-cl port, and #113 (stall-guard exports).
>
> 1. **versions.env bump full-chain ride — DONE-GREEN 2026-08-18** (4 h 01,
>    smoke 190/1/0, image verified; first full-chain #61 manifest: onnx 60.5
>    min, litert 43.9, base 31.1, merge 28.9 incl. two snapshotter-mount
>    retries, tvm 21.8 with the mini-LLVM warm). #112's `chain=''` reproduced
>    deterministically on this ride too — it is a parse hole, not a flake.
> 2. **Deadlock repro — VERDICT IN (2026-08-18, run 2):**
>    * **Deadlock GONE under WebDAV-only** — all 1891 CUDA objects incl.
>      every fused_moe launcher compiled through the sccache server, no
>      stall. The two historical wedges were #99 collateral (the L0
>      write-failure storm), not a decomposition hang.
>    * **Miscompile CONFIRMED, storage-independent, on a COLD-CACHE run** —
>      link died on dropped instantiations (`QkvToContext<*, __nv_fp8_e4m3>`,
>      `BiasSoftmaxImpl<double>`, `run_memory_efficient_attention`): the
>      objects are wrong as they leave the wrapped compile, so the loss is in
>      sccache's nvcc decomposition itself, not cache-hit replay. **CUDA
>      stays bare; the launcher-default question is CLOSED (canary 3 is red
>      before any hits are even consumed).** Addendum draft updated:
>      `out/upstream-sccache-2808-addendum.md` (owner posts).
>    * (Run 1 earlier that morning was a false all-clear — `& pwsh -File`
>      flattened the -BuildArg pair into one mangled string buildctl silently
>      discarded. Fixed: in-process invocation + driver key validation.)
> 3. **After those builds free the mounts/files:** #100 (FFmpeg/PyAV sccache),
>    #107 (extract sccache session helpers), #112 (opencv-stage provenance
>    gate empty-read), #68/#69 (FFmpeg fallback + pin drift), #45 (CUDA path
>    fail-open), #106 rest (mass `#requires`), #49/#51 (media ENV split).
> 4. **Base-tier batch — NEVER land alone** (#50 + #81, plus #78/#79 if their
>    fixes touch setup-vs): one deliberate base rebuild for all of them.
> 5. **Owner decisions:** #31 (registry push; #59 branch protection DECLINED 2026-08-17), and the
>    upstream actions in "Pending" below.
> 6. **Latent / needs a repro first:** #73 (ONNX-CUDA infinite retry — needs a
>    runtime repro), #75/#76 (timeout+heartbeat insurance; re-measured quiet
>    across 5 chains), #80 (warning-stream noise filter), #52/#54 (toolchain
>    bind-mounts / merge CUDA-runtime dedup — each wants its own verify build,
>    #54 carries a load-bearing warning).

### P0 — LIVE DEFECTS (not refactors; the chain is green *and* wrong)

> Found by the 2026-08-14 deep audit (static sweep of 151 scripts + 6
> Dockerfiles + 102 build logs). Each was verified against the tree/logs, not
> inferred. These ship broken today — do them before any refactor below.

### P0d — RESOLVED 2026-08-16 (stub; full narrative in windows-backlog-archive-2026-08-17.md)

sccache lost 100 % of L0 cache writes (`os error 3`). ROOT CAUSE: BuildKit WCOW
cache mounts lose writes into a directory an EARLIER RUN populated (158/250 on
the mount vs 0/250 in a plain dir; fresh dir on the same mount is clean).
RESOLUTION: `SCCACHE_MULTILEVEL_CHAIN` defaults to `""` (WebDAV only) in both
media Dockerfiles; genai went 157 write errors → 0 → 157 HITS. Eleven
hypotheses were measured and killed on the way; the method lessons live in
AGENTS.md (probe-reproduces-environment-not-failure; probe-destroys-own-
experiment). Trail items #89–#99 (verbatim, with every measurement): archive.
Upstream follow-ups: see "Pending" at the bottom.

### P0b — Confirmed by log forensics (49 runs, 185 MB; 2026-08-14)

> The corpus predates the step-log fix, so 28 of these logs are CLIPPED
> (the green reference run is 49 % blind in its merge step; historical ONNX
> steps are 83 % blind). Findings below survive that caveat — they rest on
> end-of-step stat blocks and timestamps, not on clipped body text. Re-run the
> forensics once a full chain has been captured with the env now in place.

- **72 [M·★★★, none] CLOSED 2026-08-20 - PREMISE DISPROVEN by the 2026-08-16 re-measurement (export ~1.2% of the chain, not 23%; the old figures came from stall/cache-failure-dominated runs). Standing instruction: do NOT collapse the media-core checkpoints on this item's authority - the resume granularity is worth more than ~60 s. Original finding: image export/unpack costs MORE than the build it wraps —
  4.33 h across the corpus, 339 operations.** The chain is split into 9+
  separate `buildctl` invocations and **each pays a full Windows-image export
  AND unpack**. Torch: 358.4 s export vs 172.6 s build (**2.08×**). LiteRT:
  1401.8 s export vs 1117 s build (1.25×). Today's base build: 605.6 s
  export/unpack = **33.5 % of the whole stage**. In the green 41:30 run,
  export/unpack is **23 % of the entire chain** — more than every COPY, every
  fan-in and the torch build combined. No static reading of the Dockerfiles
  reveals this. FIX: collapse the four `media-core-built-*` checkpoints into
  one invocation → removes 3 export/unpack round-trips per run. **CONFLICT —
  decide before doing:** those four checkpoints are exactly what gives
  media-core its per-library BuildKit-native resume (the reason litert/tvm,
  which lack them, re-pay a whole branch on any failure). Collapsing them buys
  ~3 export round-trips and costs that resume granularity. Measure both before
  choosing; this is a trade-off, not a free win.

  **RE-MEASURED 2026-08-16 on five complete media chains — THE PREMISE NO LONGER
  HOLDS; DOWNGRADE TO [S·★].** Batch A's standing caution said this item rests
  on the clipped pre-fix corpus and must be re-checked before anyone acts on it.
  Done, across `bk-run-{webdavonly,reuse,chain-disk,legacy-disk,forcelocal}.log`:

  | | per chain |
  |---|---|
  | `exporting layers`, all vertices summed | **63–69 s** |
  | longest single build vertex (onnx) | 3277–3517 s |
  | whole chain | ~5 400 s |

  Export is **~1.2 % of the chain**, not 23 %, and nowhere near "more than the
  build it wraps". The old figures were real for the runs they came from, but
  those runs were dominated by stalls and cache failures that no longer occur.
  **Do NOT collapse the four `media-core-built-*` checkpoints on this item's
  authority** — the resume granularity it would cost is now worth far more than
  the ~60 s it would save. Keep the entry only as the record of a disproven
  premise.
- **73 [S·★★★, none] SOLVED 2026-08-20 (verify: next media rebuild must show ZERO -Winfinite-recursion) - and the culprit was OUR OWN inline patch: the `_udiv128 -> udiv128` substitution (added for clang-cl's missing MSVC intrinsic; probe-udiv128-recursion proved clang 22.1.8 has no _udiv128) rewrote the call INSIDE cutlass's udiv128 into a self-call. Fix: disable CUTLASS's intrinsic guard for __clang__ instead - the portable 128-bit loop compiles, correct by construction. Upstream candidate (owner): NVIDIA/cutlass's guard `#if _MSC_VER >= 1920 && !defined(__CUDA_ARCH__)` should also carry `&& !defined(__clang__)`. Original finding: latent defect in the SHIPPED ONNX CUDA provider: infinite
  recursion in CUTLASS `udiv128`.** 225 occurrences of
  `uint128.h(96,90): warning: all paths through this function will call itself
  [-Winfinite-recursion]`, reached via `flash_api.h:36` while compiling
  `onnxruntime_providers_cuda` TUs (`attention.cc`, `paged_attention.cc`,
  `packed_multihead_attention.cc`). CUTLASS selects an MSVC `_udiv128`
  intrinsic path that clang-cl does not resolve, so the function calls itself
  unconditionally → stack overflow **if that path is taken at runtime**. It
  sits in the flash-/paged-attention code of a shipped provider. Static
  analysis cannot see this — it exists only in the clang-cl port's compiler
  output. FIX: runtime smoke test of flash-attention, then a clang-cl
  `udiv128` patch alongside the existing `patches/onnxruntime` set.
- **74 [S·★★, none] PARTLY DONE 2026-08-15 — the `-j9` half is fixed, the
  measurement is not.** Backlog #28 lowered `MemGBPerJob` to 2 for onnx and
  opencv only, so the 2026-08-15 chain still logged `ninja -j9` three times
  (genai, litert, tvm) against `-j19` three times. Those three are now at 2 as
  well, justified by the ONNX measurement (9274 samples, peak per-process
  WorkingSet 998 MB, same nvcc workload) and by build-iree, which compiles LLVM
  in-tree — the heaviest TUs in the chain — at 2 all along. **UNVERIFIED:** no
  build has run since the change, and the claim that sccache is "provisioned for
  32 jobs" while ninja runs at 9 came from the CLIPPED corpus. Confirm the job
  count and the wall-clock on the next cold media build before closing.

- **75 [S·★★★, none] DONE 2026-08-19 (module edit, next media rebuild): the downgrade is now LOUD - Write-Warning before (naming the cross-run crash signature to watch for) and after (stamping the serial fallback's added minutes on a green finish); the ladder was already bounded to ONE incremental attempt. Original finding: the `-j` downgrade ladder is a SILENT self-heal that
  converts a failure into an hours-long serial rebuild.** One run
  (`bk-chain-20260810-nogpu`) burned **11 h 17 m re-running the same ONNX build
  11 times**, each cycle ending
  `ninja -j9 failed (exit 2) - retrying incrementally with -j2...` at 4911.5 s
  / 4909.2 s — a ±2 s determinism that identifies the sccache-CUDA server crash
  rather than an env flake. 12 occurrences corpus-wide. FIX: make the downgrade
  loud and bounded; abort instead of grinding serially.

  **RE-MEASURED 2026-08-16: zero occurrences across five complete media chains.**
  Still worth fixing — a self-heal that can silently cost 11 h must be loud and
  bounded whether or not it fires today — but it is **latent, not active**, so it
  does not belong ahead of work on live defects. Same status as #76.
- **76 [S·★★, none] DONE 2026-08-20: the make/gawk provisioning region is bounded (10-min ceiling, 60-s heartbeat via Invoke-BoundedProvisionStep) - a recurrence costs minutes and names itself. Original finding: the ~120-min ffmpeg stall (old #35) is CONFIRMED as a
  one-off and DENIED as recurring — and it is a TIMEOUT, not jitter.** Exact
  gap: **7200.9 s** (≈ exactly 2 h) of zero output between
  `WARNING: vswhere returned no installation; using filesystem fallback` and
  `Replaced MSYS2 awk with gawk`. In 10 other runs that marker lands at
  t = 11.5-17.9 s. Actual ffmpeg work in that step was only ~162 s. The
  two-hour boundary reads as a network timeout in the MSYS2/gawk provisioning
  call. Not recurred in 9 subsequent runs → latent, not active. FIX: bound that
  step with an explicit timeout + heartbeat. **Supersedes the old #35 observe
  entry**, which can now be closed.

  **RE-MEASURED 2026-08-16: not recurred in five more complete chains** (longest
  vertex anywhere 3 517 s = onnx, no >2 h gap). 14 clean runs since the one-off.
  Confirms latent-not-active; the timeout+heartbeat is still the right fix and
  is cheap, but it is insurance, not a repair.
- **77 [S·★★, none] STALE 2026-08-17 — the retry has NOT fired since the GStreamer 1.29.2 bump.** Today's full chain compiled GStreamer clean on attempt 1 (0 hits for the retry marker), matching the code comment: in 1.29.2 there is no `_commit` collision and the reactive path is documented DORMANT INSURANCE (the .patch stays git-appliable for a future clang/io.h/gstreamer combination). The "3/3 runs, ~20 min each" evidence predates the bump. No action; re-open only if the marker reappears. Original finding: GStreamer's GES `_commit` conflict is patched REACTIVELY
  after a failed compile — deterministic, 3/3 runs, ~20 min discarded each
  time.** `Compile attempt 1 failed; patching _commit conflict in GES and
  retrying...` at 1236.8 s / 1392.2 s / 1391.3 s in three separate runs. Tight
  clustering + 100 % reproduction = this belongs in `patches/gstreamer`
  applied up-front, not as a post-failure repair.
- **78 [S·★★, none] DONE 2026-08-20: the filesystem fallback prefers the VISUAL_STUDIO_VERSION major (a VS promotion can no longer float in newest-first), warns loudly on a pin miss, and is memoized per process (was x100 warnings). Original finding: the VS major-version pin is NOT being honoured — the
  toolchain is pinned by luck.** Today's base build:
  `WARNING: major-pinned VS alias unavailable — used floating 'stable' channel
  (currently VS 18…)`. Plus `vswhere returned no installation; using filesystem
  fallback` ×100 — so the build depends on a literal path string rather than on
  discovery. The day Microsoft promotes VS 19, the pin floats AND the fallback
  path breaks simultaneously, re-opening the documented vcpkg/VS-toolset
  rejection class.
- **79 [S·★★, none] DONE 2026-08-20: pinned-alias retry budget 2->3 before the loud stable degrade; the Adoptium half already shipped separately (github-first JDK fetch in build-litert-lm-bazel). The MZ-signature guard remains the HTML defence; no bootstrapper preseed (its hash floats within a channel by design). Original finding: `aka.ms` serves HTML instead of the VS bootstrapper binary
  — the same failure family as the known nuget trap.** Today's base build:
  `expected a MZ-signature file but got first bytes 60,33 (likely an HTML error
  page)` — `60,33` is `<!`. Also 3 consecutive failures against
  `api.adoptium.net` for JDK 21. The MZ-signature guard is excellent defence,
  but the retry budget is 2 and it self-heals only because a fallback URL
  exists. The pre-seed fix already applied to nuget was never extended to the
  VS bootstrapper or Adoptium.
- **80 [S·★★, none] HALF DONE 2026-08-17 — the observability half shipped: `analyze-warning-stream.ps1` classifies any build log in seconds (verified against today's 34-MB chain: 87,515 warnings, 82.7 % noise, and LIVE signal — 422 ×inconsistent-missing-override, 26 ×undefined-var-template, 14 ×infinite-recursion, 68 ×inconsistent-dllimport). STILL OPEN: suppress the top-5 noise classes at build-script level (files are bind-mounted — land between builds). Original finding: 96 % of the warning stream is 5 noise classes, hiding 1,055
  genuine signals.** Corpus totals: `-Wunused-parameter` 68,502,
  `-Wdocumentation-unknown-command` 18,144, `-Wdeprecated-copy…` 17,887,
  `-Wundef` 17,056, `-Wmissing-field-initializers` 12,294 — vs the signal
  classes `-Winconsistent-missing-override` 9,449 (vtable/ABI),
  `-Wundefined-var-template` 552 (ODR/link), `-Winconsistent-dllimport` 252
  (Windows linkage), `-Winfinite-recursion` 225 (#73), `C4715` 26 (UB — all in
  the vendored `tvm-ffi/.../creator.h(112)`, falling off the end of a
  value-returning function). Also `-Wunused-command-line-argument` 7,200:
  `/Zc:preprocessor` is passed but ignored by clang-cl — a config smell worth
  removing. FIX: suppress the top-5 noise classes at build-script level so CI
  can see the rest.

### P0e — status 2026-08-17 (stub; full narrative in windows-backlog-archive-2026-08-17.md)

- **#94 RESOLVED, DEFAULT ON** — OpenCV links the chain''s FFmpeg (avcodec 63,
  avdevice YES; was prebuilt 61/NO). Four parts, all required: stage swap
  (ffmpeg before opencv), `pkgconfig-shim.cmake` via CMAKE_PROJECT_INCLUDE,
  SKIP_DOWNLOAD + ENABLE_LIBAVDEVICE, and the FFmpeg-9 source patch
  (`ffmpeg9-avcodec-config.ps1` — AVCodec::pix_fmts/supported_framerates were
  removed upstream). Full-chain smoke: 188/1/1. `(prebuilt binaries)` is NOT a
  provenance signal — the avcodec-major comparison is.
- **#95 DONE** — smoke asserts the video backends (runtime-aware since the
  plugin route). Watched failing before the fixes, as designed.
- **#93 IMPLEMENTED, awaiting its first merge build** — standalone
  `opencv_videoio_gstreamer` plugin built in the merge stage AFTER GStreamer
  (`build-opencv-gstreamer-plugin.ps1`); breaks the circularity without a
  second OpenCV pass. `getBuildInformation()` stays `GStreamer: NO` BY DESIGN
  (compile-time string; plugin is runtime) — the smoke guard asserts
  `hasBackend(CAP_GSTREAMER)` + an actual videotestsrc frame read instead.

### P2 — Fail-open gates & silent degradation (green build, crippled image)

- **45 [S·★★★, none] DONE 2026-08-19 (module edit, next media rebuild): Get-GpuEnvironment THROWS on GPU_TYPE=nvidia with no resolvable CUDA root; FORCE_CPU opt-outs short-circuit before the gate (2 unit tests).** Original finding: a mis-plumbed CUDA path yields a fully green, CPU-ONLY
  media chain — discovered hours later. `WindowsSourceBuild.Cuda.psm1:47`
  gates on `Test-Path $cudaRoot`; every consumer then takes a quiet else-branch
  (`build-onnx:307` "CPU-only build", `build-opencv:277` `WITH_CUDA=OFF`,
  `build-tvm:39` silently). `GPU_TYPE=nvidia` is baked at `Dockerfile.nvidia:93`,
  so "lane says nvidia but no CUDA" is never legitimate. Cost: ~75 min ONNX +
  ~30 min OpenCV + ~45 min GenAI all green and all useless. The explicit
  opt-outs (`ONNX_FORCE_CPU`, `GENAI_FORCE_CPU`) already exist, so a `throw`
  is safe. FIX: fail closed when `GpuType -eq 'nvidia' -and -not $CudaRoot`.
- **47 [S·★★, none] DONE + VERIFIED 2026-08-17 — and the gate's first live run
  DISPROVED its own premise:** "the toolchain always bakes LLVM" was false —
  scoop LLVM (official Windows installer) ships NO llvm-config/dev-libs at all,
  so every prior Windows TVM was silently USE_LLVM=OFF. The throw fired on
  verify5 and forced the real fix: the tvm stage now builds its own minimal
  pinned LLVM (see Component Build Matrix row + AGENTS invariants; the /MT dev
  tarball detour and the 4-fix path are in the 2026-08-17 commits). Loud
  cuDNN/Vulkan OFF-paths shipped as planned. Original finding: TVM silently
  drops LLVM / Vulkan / cuDNN.**
  `build-tvm-from-source.ps1:76-82` (and :68-73, :53-64) print on the ON path
  and print NOTHING on the OFF path. `USE_LLVM=OFF` removes TVM's CPU codegen
  entirely: build green, `import tvm` green, and every `tvm.build` for an LLVM
  target fails at runtime in the shipped image. An LLVM/scoop bump that drops
  `llvm-config.exe` off PATH is a plausible one-line regression.
### P2b — Per-component build-script gaps (sibling scripts that drifted apart)

- **65 [S·★★★, none] DONE 2026-08-17 (verify in the next merge build) — GStreamer compiles with NO job budget, NO retry ladder and
  NO sccache stall guard — while using sccache.** Verified: 0 hits for
  `Start-SccacheStallGuard` / `Get-BuildJobCount` / `MemGBPerJob` in
  `build-gstreamer-from-source.ps1`. It sets `$env:CC = 'sccache clang-cl'`
  (:205) then runs `meson compile` (:879) with no `-j`, so ninja's default
  (cores+2) ignores `MEMORY_LIMIT_GB` entirely — exactly the OOM shape
  `MemGBPerJob` exists to prevent. It is also the ONE compile stage using
  sccache without the watchdog written for the documented sccache-server
  deadlock; a wedge there hangs the merge stage indefinitely with no
  kill/resume. FIX: `meson compile -j (Get-BuildJobCount -MemGBPerJob 2)` +
  the stall guard.
- **66 [S·★★★, none] DONE 2026-08-17 via an EARLY presence-only fast-fail (the full gate stays where its outputs are consumed; a missing fan-in now dies in seconds) — original finding: GStreamer's "must resolve NOW" pre-flight runs AFTER the
  tarball, ~20 wrap downloads and five patch loops.** The gate's own comment
  reads "Everything the required set needs must resolve NOW, not after an
  hour" (:676) — but the block starts at :522 while the downloads run at
  :242-:323 and patching at :404-:485, and the things it checks (OpenCV
  headers, `onnxruntime.lib`, LiteRT headers, `tensorflowlite_c.lib`) depend on
  NONE of that work. Hoisting it above :228 turns a missing media fan-in from
  "full download+patch phase, then fail" into a ~5-second failure.
- **68 [M·★★★, none] DONE 2026-08-20: the BtbN fallback is FAIL-CLOSED (throws unless FFMPEG_ALLOW_PREBUILT=1; the opt-in path scrubs the whole prefix first so a MIX is impossible, and the .pc gate skip is loud); the skip-if-present early return runs Assert-FfmpegPkgConfig before trusting an inherited install. Original finding: FFmpeg's prebuilt fallback ships a MIXED install, and the
  skip-if-present early return bypasses every gate on re-entry.** On a missing
  `ffmpeg.exe` it downloads BtbN's zip and copies `*.exe`/`*.dll` over whatever
  a partial `make install` left (:441-459), while OUR import libs and `.pc`
  files stay — so gst-libav links a version mismatch, announced by one
  `Write-Warning`. Separately `:110` returns early when `ffmpeg.exe` exists, so
  a `-ResumeFrom FFmpeg` after such a failure skips `Assert-FfmpegPkgConfig`,
  the import-lib assert and PyAV — the resumed run cannot detect the broken
  install it inherited.
- **88 [S·★★★, none] DONE + VERIFIED 2026-08-17 (fail-closed summary after the
  loop; VERIFIED live in verify15+smoke. NOTE the fetch route changed same-day:
  wraps + libffi go through the script-local `Invoke-WrapDownload` — curl-native
  UA + magic-byte check — NOT the shared `Invoke-DownloadWithRetry`, whose
  browser UA gets Anubis HTML challenge pages from freedesktop/videolan GitLab;
  `.git` is stripped from GitLab archive URLs. The gate's first live run also
  caught graphene entering the build for the first time, see AGENTS invariants)
  — original finding: GStreamer wrap downloads fail SILENTLY and the build ships
  a feature-reduced image — OBSERVED, not theorised.** The 2026-08-14 full chain
  logged **22 failed wrap downloads** in one merge stage:
  `gst-plugins-base` ×15, `theora` ×5, `pango` ×2, each as
  `WARNING: failed to download ... features may be disabled`, and the build went
  green. The fetch is `curl.exe ... 2>nul` (`build-gstreamer-from-source.ps1`
  ~:294 and the libffi fetch at ~:313), so the ONE thing that distinguishes a
  moved wrap revision (404) from a DNS/TLS problem is discarded — and 20 lines
  earlier the main tarball already uses `Invoke-DownloadWithRetry` with backoff
  and non-empty verification. Only the four MANDATORY plugins are gated; every
  other codec silently becomes optional. FIX: route the wrap and libffi fetches
  through the shared helper, and fail (or at least summarise loudly at the end
  of the stage) rather than emitting 22 warnings nobody counts. NOTE this was in
  the 2026-08-14 audit and was dropped when the findings were numbered — the
  numbers came from the audit's list, and this one fell out; re-verify the P2b
  set against the audit before assuming it is complete.
- **69 [S·★★, none] DONE 2026-08-20: W1c AST scanner covers the if($env:KEY){...}else{'<literal>'} idiom (pin membership filters behavior defaults; scanner-rot guard pins 9 sites) and caught 3 LIVE drifts, all fixed: build-ffmpeg NV_CODEC_HEADERS_REF n13.0.19.0->n13.1.15.0 (the documented 404/NVENC-skip seed), build-litert-lm-bazel 0.15.0->0.16.1, assemble-torch-app v0.0.22->v0.0.27. Original finding: live pin drift that the parity gate structurally cannot
  see.** `build-ffmpeg-from-source.ps1:241` hardcodes
  `else { 'n13.0.19.0' }` against `versions.env:184 NV_CODEC_HEADERS_REF=n13.1.15.0`
  — verified drift. `SourceBuild.PinParity.Tests.ps1:80` scans only
  `Get-SourceBuildVersion` call sites, so the `if ($env:X) {…} else {<literal>}`
  idiom is invisible to it (~13 such sites; four more version literals bypass
  the gate the same way). versions.env:180-183 records that a wrong
  nv-codec-headers ref once "404'd and NVENC was silently skipped on both
  lanes" — this is that incident's seed, re-planted. FIX: route the literals
  through `Get-SourceBuildVersion`; teach the AST scanner the second idiom.
- **70 [S·★★, none] DONE 2026-08-20, subsumed by #100: FFmpeg compiles through the make-time sccache launcher (2198/2198, 100.00% on the hit run) and the chain epilogue emits its stats.** Original finding: FFmpeg is the only compile stage with NO sccache wiring at
  all — verified: 0 `Write-SccacheStats` calls, and the script never sets the
  sccache endpoint. The precedent is its sibling, which documents that
  GStreamer "ran completely uncached (~30 min hot)" until 2026-08-04 because
  "the merge builder simply never wired the endpoint through". A 30-60 min
  stage recompiles cold every attempt and is not even MEASURABLE. Emitting the
  stats is unconditionally safe; whether FFmpeg's `configure` tolerates
  `--cc="sccache clang-cl"` needs a configure-only probe first.

### P3 — Cache tiering (pure rebuild-time cost; no correctness change)

- **49 [M·★★★, media-core once] LANDED 2026-08-19, riding the full ride (verify: a later PYAV-only bump must NOT re-run onnx): per-component ARG/ENV blocks in the BK stages, media-core-env is classic-lane-only, TwinParity suite carries the new contract. Original finding: nine version ARGs share ONE ENV layer directly
  above the ~75-min ONNX compile.** `Dockerfile.media-builder:142-168` declares
  ONNX/GENAI/OPENCV/FFMPEG/PYAV/NV_CODEC/CUDA_ARCH/PYTHON in a single
  `media-core-env`, and opencv/ffmpeg/genai chain `FROM` ONNX's output. So a
  **PyAV bump re-runs the full ONNX build** and cascades through the whole
  branch (hours). The 2026-08-07 versions.env-COPY removal fixed this at BRANCH
  granularity and never reached COMPONENT granularity. FIX: move each ARG+ENV
  into the stage that consumes it.
- **50 [M·★★★, base once] DONE 2026-08-18 (riding the #114 base batch): versions.env COPY relocated below scoop/vcpkg/rust; the 9 consumed keys (incl. helper-reads GIT_VERSION/WIX_*/SCOOP_INSTALLER_SHA256 - invisible to a naive $env: grep) ride as ARGs mirrored in both drivers. AFTERMATH FIXED 2026-08-19: the final-stage ARG mirrors sat in the process env during the bake RUN, load-versions' override branch left Machine untouched, and those keys (measured: SCCACHE_GIT_REV, machine=[] in-container) were never baked into post-#50 images - load-versions now persists the winning override to Machine (Dockerfile.load-versions-probe, fail-closed; rides the next base build). Original finding: `versions.env` is COPY'd above scoop + vcpkg + the
  ~30-min rust/sccache-from-source layer.** `Dockerfile.base:87-89`, then
  `:114-120`, then `:156`. versions.env is shared by BOTH lanes, so editing a
  purely *Linux* key (`PANDOC_VERSION`, `ROCM_VERSION`, `UBUNTU_DIGEST`)
  re-pays GB-scale scoop + vcpkg + the 30-min rust layer on the next base
  build. The file already proves it knows the pattern — `setup-vs.ps1` was
  deliberately hoisted above this COPY for exactly this reason (`:71-76`). Only
  8 keys are needed below the COPY; promote those to ARGs and move the COPY
  down. (The sibling ARG-below-the-expensive-RUN fix for TensorRT shipped
  2026-08-14 — same pattern, see the archive addendum.)

  **SCOPED 2026-08-14 — and the audit's "only 8 keys" was wrong.** Enumerating
  what the three RUNs below the COPY actually read (both `$env:X` *and*
  `Resolve-ContainerImageValue -EnvironmentVariable 'X'`, which the first pass
  missed because it uses no `$env:` syntax):
  - `setup-scoop-tools.ps1`: CMAKE_VERSION, FLUTTER_VERSION, GIT_INSTALLER_URL,
    GIT_VERSION, GIT_WINDOWS_INSTALLER_SHA256, LLVM_WINDOWS_VERSION,
    NASM_WINDOWS_VERSION, NINJA_WINDOWS_VERSION, SCOOP_INSTALLER_SHA256,
    VULKAN_VERSION, WIX_UI_EXT_VERSION, WIX_VERSION
  - `setup-vcpkg.ps1`: VCPKG_REF
  - `setup-rust-toolchain.ps1`: SCCACHE_GIT_REV, RUSTUP_DIST_SERVER,
    RUSTUP_IO_THREADS

  Five of those (CMAKE/LLVM/NINJA/NASM/VULKAN) **already have ARGs** and are
  passed as parameters, so the work is ~11 NEW ARG declarations, each
  duplicating a versions.env pin into the most expensive Dockerfile in the repo.

  **TRADE-OFF — decide before doing.** The gain is purely cache cost: editing a
  Linux-only key (PANDOC_VERSION, ROCM_VERSION, UBUNTU_DIGEST) would stop
  re-paying scoop + vcpkg + the ~30-min rust/sccache layer on the next base
  build. The cost is eleven new duplicated pins, i.e. exactly the drift surface
  that #69 still tracks and that `Pins.CanonicalValues.Tests.ps1` was written to
  police (closed #60) — that test covers Dockerfile.media-merge-builder today
  and would have to be extended to Dockerfile.base before landing them. Not obviously
  worth it; that judgement is the owner's, which is why this was NOT landed with
  #81 on 2026-08-14 even though the base was rebuilt anyway.
- **51 [M·★★★, media once] DONE 2026-08-20: no longer image metadata - the driver publishes the effective budget to the webdav (preseed/memory-limit-gb.txt), Get-BuildJobCount reads env -> webdav (memoized) -> CIM; under -ConcurrentAux every branch now gets the halved budget (the old full+halved+halved asymmetry oversubscribed the host). Original finding: `MEMORY_LIMIT_GB` — a scheduling knob — is an image
  ENV and therefore a CACHE KEY** (`Dockerfile.media-builder:29,67`). The
  driver halves it for `-ConcurrentAux` (`build-buildkit.ps1:378`), so merely
  TOGGLING that flag changes the layer digest and invalidates every litert/tvm
  compile. Same on any host with different RAM. `Dockerfile.torch:57-60`
  already states the principle ("Build-time state belongs in the build step,
  not in the artifact"). FIX: derive in-container, or bind-mount it.
- **52 [M·★★, toolchain] LANDED 2026-08-19, riding the full ride: BK 'built' stage bind-mounts script/module/versions.env (sibling versions.env preferred), classic lane gets builder-classic COPY stage (build.ps1 target updated). Original finding: the toolchain builder never got the bind-mount
  treatment.** `Dockerfile.toolchain-builder:38-43` COPYs the shared module +
  versions.env + the build script into the stage whose child RUNs the CPython
  compile — so editing *any* of them (incl. a module ~30 scripts share)
  re-pays the full CPython build, and toolchain is the parent of every media
  branch. `Dockerfile.media-builder:243-259` documents the exact solution.
- **81 [S·★, base] DONE - STALE ENTRY: already fixed 2026-08-14 (the SHELL line sets PSNativeCommandUseErrorActionPreference correctly; the entry outlived its fix). Original finding: The base SHELL sets a variable
  that does not exist.** `Dockerfile.base:58` sets
  `$PSNativeCommandErrorActionPreference = $false`; the real pwsh variable is
  **`PSNativeCommandUseErrorActionPreference`** (verified against pwsh 7.6.4,
  exactly `PWSH_VERSION`: `Get-Variable PSNative*` returns only
  `PSNativeCommandArgumentPassing` and `PSNativeCommandUseErrorActionPreference`).
  The assignment creates an unrelated variable and does nothing — the base
  believes it has a guard it does not have. Harmless *today* only because the
  real variable already defaults to `False`; the day pwsh flips that default
  (its stated direction), every native non-zero exit inside a base RUN starts
  throwing. Note the repo spells it correctly elsewhere
  (`WindowsFormatting.Common.psm1:279`). Also: all six derived Dockerfiles
  re-declare `SHELL` and drop the clause — `SHELL` IS inherited via image
  config, so those are redundant layers against the 125-cap.
- **54 [S·★★, merge] DONE 2026-08-20, PREMISE DISPROVEN + RE-SCOPED TO A TRIM: the merge lineage (merge-fanin FROM toolchain; final <- torch <- media) never carries the nvidia originals, so the flatten is the ONLY copy, not a duplicate. The real win: the closure probe (probe-cuda-runtime-closure) showed 13/36 staged DLLs statically imported; the stage now trims the closure-verified-unreferenced, non-dynamic-load families (cusparse/cusolver/cusolvermg/nvjpeg/npps, ~436 MB) and KEEPS all cudnn_* + the nvrtc JIT chain (dlopened at runtime; unverifiable on this GPU-less host). Next merge build. Original finding: `cuda-runtime-stage` ships a SECOND, flattened copy of the
  CUDA + cuDNN runtime DLLs** (`Dockerfile.media-merge-builder:138`); cuDNN's
  set alone is 0.52 GB uncompressed, plus CUDA 13's cublas/cufft/cusolver/nvrtc.
  The originals are still in the image (merge descends from the nvidia stage)
  and `Dockerfile.nvidia:97` already PATHs them. One extra PATH entry for
  cuDNN's nested layout likely replaces the whole stage. NOTE: verify the
  actual cuDNN 9 nesting against the installed tree before removing the stage —
  the flatten fix was load-bearing for OpenCV's `cudnn64_9.dll`.
- **100 [M·★★★, media-core] SOLVED 2026-08-20 after 5 probe rounds - make-time launcher ON, 2198/2198 compile requests through sccache (was 0 forever):** the crash trigger was `-options:strict` - cl.exe-only; clang-cl parses the PREFIX as the deprecated `-o` (output). Bare builds survived by ORDER (the later -Fo wins); sccache's generate_compile_commands REORDERS (-Fo first), the hijack wins, and the object lands in an NTFS ALTERNATE DATA STREAM (`ptions:strict.obj`, literally recovered by probe-sccache-options-strict.ps1) at exit 0 -> 'failed to zip up compiler outputs'. Chain fix: the flag is stripped in Remove-MakefileShowIncludes (a bare-build correctness fix too - the silent -o hijack was always there, just overridden). configure stays bare (its own tests still break through sccache). UPSTREAM angles (owner decides, possible PR 3): (a) sccache's -Fo-first reorder is a semantic hazard for ANY unknown flag whose prefix parses as -o; fix = emit the output flag AFTER the forwarded args; (b) sccache never logs the spawned compile line even at trace. Hit-run VERIFIED 2026-08-20: 2198/2198 hits, 100.00%, 0 misses. PyAV remains the open lower-value half. Previous state: (1) configure --cc='sccache clang-cl': configure's own compiler tests produce objects lld-link rejects ("unknown file type"); (2) make-time CC override: dies ~20 files in with sccache "failed to zip up compiler outputs" on the RELATIVE forward-slash -Fo outputs (libavdevice/dshow*.o resolved to C:	emp\...\libavdevice/dshow_pin.o, file absent) - and the bare `make install` then silently recompiled everything launcher-less (15 min), so both "green" rides were uncached anyway. Next angle: sccache-side (does it mishandle relative -Fo through a server whose cwd differs? possibly upstream PR 3 material - owner decides); PyAV unchanged. Original finding: FFmpeg and PyAV compile with sccache COMPLETELY
  BYPASSED — the whole ffmpeg branch is uncached, every build, forever.**
  Measured 2026-08-15 in the #99 verification run: the `media-core-built-ffmpeg`
  stage reported `Compile requests 0` — not "0 hits", *zero requests*. sccache
  never saw a single compile.

  CAUSE: sccache is wired **only** through CMake, in
  `WindowsBuild.Common.psm1:642-643` (`CMAKE_C_COMPILER_LAUNCHER` /
  `CMAKE_CXX_COMPILER_LAUNCHER`). FFmpeg does not use CMake — it configures with
  `--toolchain=msvc --cc=clang-cl --ld=lld-link`
  (`build-ffmpeg-from-source.ps1:317`), so every one of its C files goes
  straight to `clang-cl`. PyAV is the same story from the other direction: it
  builds through setuptools, which invokes MSVC `cl.exe` directly (visible in
  the same log right before `Staged wheel: av-18.0.0-…`).

  WHY IT WENT UNNOTICED: the chain's aggregate hit rate looks excellent
  (onnx 1498/1498, opencv 1861/1862) precisely BECAUSE the uncached components
  contribute no requests to the denominator. A component that bypasses sccache
  entirely is invisible in a hit-rate metric — it can only be seen by reading
  `Compile requests` per stage. Cf. the AGENTS.md "aggregate evidence" rule.

  FIX TO TRY: pass the launcher into FFmpeg's own configure —
  `--cc="sccache clang-cl"` (FFmpeg's configure tolerates a launcher prefix in
  `--cc`; verify `ffbuild/config.mak` afterwards, and that `--ld` stays bare).
  For PyAV, setuptools honours `CC`/`CXX` only on non-MSVC; the realistic lever
  is a compiler shim on PATH, so treat PyAV as a separate, lower-value item.
  VERIFY BY: `Compile requests` > 0 for the ffmpeg stage — that number, not the
  hit rate, is the acceptance criterion. Do NOT accept a rerun with a warm
  cache as evidence: a stage with 0 misses writes nothing and proves nothing
  (that trap cost two stages' worth of "0 write errors" in this very run).

### P4 — Missing regression tests (each maps to a bug that already cost hours)

- **59 [S·★★, none] CLOSED 2026-08-17 — owner decision: no branch protection wanted. Lint/tests are advisory, not gating.** `main` is not
  branch-protected (`gh api …/protection` → 404); `windows-scripts.yml:50` runs
  the linter WITHOUT `-FailOnAnalyzer`; `.githooks/pre-commit` runs the Linux
  preflight but neither `Invoke-Lint.ps1` nor `Invoke-Tests.ps1`. The gate is
  currently human discipline plus a post-hoc notification.
### P5 — Observability (makes everything above measurable)

- **61 [M·★★★, none] DONE 2026-08-17 (first manifest lands with the next driver run) — stage logs now carry a per-run id (bk-<runid>-<label>.log; the Keep-80 rotation finally has something to rotate), each stage prints its duration, and a machine-readable per-stage manifest is written at the end. Original finding: No per-stage timing, no run manifest, and stage logs are
  OVERWRITTEN every run.** `build-buildkit.ps1:284` names logs by label only —
  no run id, no timestamp — so run N truncates run N-1, and `Limit-DiagnosticLogs
  -Keep 80` never fires because there are only ~10 distinct names. On failure
  the BK lane prints no elapsed time at all (the total is past the throw; the
  `finally` only pops the location). The Linux orchestrator already emits
  `chain-status.json` per stage — Windows has no equivalent, so run-over-run
  comparison is done by hand in CHANGELOG prose. FIX: stamp logs with a run id;
  emit `run-<id>.json` (stage, tag, attempts, seconds, exit, disk before/after);
  print the table at the end AND in a `finally` on failure.
### P6 — 2026-08-17 static audit, OPEN remainder (done items #101/#102/#103/#105 + methodology: archive)

- **104 [S·★, none] DONE 2026-08-17 — with a finding: the corpse was ALREADY GONE.** `clean-sccache-mount.ps1` (+ `Dockerfile.cache-mount-clean`, via the shared probe runner, network-free) found the mount root holding only KB-scale bucket remnants — **no v2, no v3, no v4** — and freed just 0.1 MiB. v4 (~63 MiB, experiment B) verifiably existed yesterday; something reclaimed the mount contents during today's build churn, most plausibly buildkitd GC treating the exec.cachemount as reclaimable under the shared tier-0 budget. RELEVANT LATER: when the disk,webdav tier returns (#99 restore), do not assume cache-mount contents survive GC pressure between runs. Fixtures probe-persist/bulk-inherit kept (the #99 repro). Original finding: The sccache cache mount carries dead weight that no build will ever read again.** The damaged original root tree (buckets `0..f`,
  ~114 MiB — the #99 corpse), the empty `v3`, experiment B''s `v4` (~63 MiB),
  and the probe fixtures `probe-persist`/`bulk-inherit` (keep those until the
  BuildKit upstream report is filed). Only `v2` is referenced. One probe-style
  cleanup RUN reclaims ~200 MiB of the shared 40 GB tier-0 budget. Builder
  disk, not image size. BLOCKED while any build holds the locked mount.
- **106 [S·★, none] PARTLY DONE — the 5.1 parse gate shipped and immediately
  corrected the entry''s own premise** (only `bootstrap-pwsh.ps1` runs under
  WPS 5.1; setup-vs/setup-scoop declare 7.0 and run after the SHELL switch).
  STILL OPEN: add `#requires -Version 7.0` to the ~52 undeclared files — many
  are bind-mounted into media stages, land between builds.
- **114 [M·★★★, BASE-TIER] DONE 2026-08-18 EVENING: shipped with the base batch ride (3h30, smoke 190/1/0), three-canary bar PASSED (cold: link green + 153 CUDA device writes; hit: link green at 100.00% CUDA/PTX/CUBIN hit rate, 207/816 hits), SCCACHE_CUDA_LAUNCHER default flipped ON. Original: Ship the sccache nvcc quote-protection fix.**
  2026-08-18: the dropped-instantiation miscompile is ROOT-CAUSED and the fix
  VERIFIED on the reproducer (patch-verify probe: bare 3189 == wrapped 3189
  symbols). Cause: nvcc.rs flattens `\` before tokenizing dryrun lines, `\"`
  escapes collapse, shlex packs ~30 -D pairs into one 493-char token, the
  cpp4 preprocess loses `USE_CUDA` & friends, cudafe++ emits no stubs. The
  package (patch + README + verify probe) lives in
  `windows/upstream/sccache-nvcc-quote-fix/`. Shipping = editing
  `setup-rust-toolchain.ps1` (clone+apply+install instead of `cargo install
  --git`) = BASE rebuild — rides the next base-tier batch, never alone.
  After shipping: three canaries + a cache-hit second run, THEN the
  SCCACHE_CUDA_LAUNCHER default discussion reopens (~50 min/chain at stake).
  Upstream PR mozilla/sccache#2811 MERGED 2026-08-19 (ffac4a5, sylvestre);
  SCCACHE_GIT_REV bumped to the merge commit, patches 0001/0002 deleted —
  the series now carries only 0003 (#115 diag-suppress; local until its own
  PR lands). Owner: post the #2808 addendum comment referencing it.
- **116 [S·★★, none] DONE 2026-08-19 (module edit — takes effect with the
  next media rebuild, cache closure): Invoke-GitClone retries transient
  failures** (3 attempts, backoff doubling capped at 30 s, mount-safe
  partial-tree wipe between attempts; throw/SkipOnFailure only after the
  last). 4 unit tests (fake git.bat, NinjaRetry pattern). Original finding:
  one TCP drop (`curl 18 transfer closed` at 610 s of the LiteRT clone)
  killed a 4-hour ride; the driver correctly does not infra-retry script
  failures, so the chain stopped and the relaunch cost the full stage queue.
- **115 [S·★★★, none] DONE 2026-08-19 EVENING - OPENCV_CUDA_LAUNCHER default ON: cold run wrote every CUDA category (155 cudafe++/nvcc, 620 cicc/ptxas, link green), the no-cache hit run came back 100.00% on all four CUDA categories (99.97% overall) and cut the opencv stage ~13->~4.3 min. Upstream PR 2 submitted by the owner (fix/nvcc-diag-suppress-separated). Original: OpenCV
  CUDA was never an rsp/length problem** (both earlier theories were probe
  artifacts: an undefined `$obj` interleaved 'replay1.obj' between every
  character and manufactured a phantom 24k command). The real command is
  ~2,040 chars, inline, no rsp. sccache rejects it as
  `CannotCache(multiple input files)` because **`--diag-suppress 1394,1388`
  (separated) is missing from the nvcc ARGS table** - the value parses as a
  bare token = phantom second input. Measured: separated form uncached,
  attached form cached; all 155 OpenCV .cu compiles carry the flag. Fix =
  patch 0003 in windows/upstream/sccache-nvcc-quote-fix (diag-error/
  suppress/warn, both dash forms, + regression test); ships with the next
  base ride, upstream PR 2 draft in the package (OWNER submits - no direct
  PR interaction per 2026-08-19 directive). The OPENCV_CUDA_NO_RSP knob is
  moot and stays only as a documented dead end. AFTER the ship: the
  OPENCV_CUDA_LAUNCHER=1 experiment repeats and should finally show CUDA
  cache categories.
- **112 [S·★, none] DONE 2026-08-19 (verify in the next media rebuild):
  the chain-side probe read back empty because ffmpeg.exe died 0xC0000135
  STATUS_DLL_NOT_FOUND** — `--enable-libonnxruntime` links avfilter-12.dll
  against the chain's onnxruntime.dll (lib\onnxruntime-source\bin), which the
  bin-dir-on-PATH fix never covered. Measured in-image via
  Dockerfile.ffmpeg-provenance-probe (symptom → dumpbin walker names the DLL
  → fixed-gate replay exit 0 / avcodec 63). Gate now adds the discovered
  onnxruntime.dll dir to the probe PATH and prints the exit code hex on a
  parse miss instead of a silent chain=''. Original finding: verify5
  (2026-08-17) logged `could not compare avcodec majors (chain=''
  configure='63')`. Not release-gating: the
  authoritative #94/#95 assertion runs in `smoke-test-container.ps1` against
  the shipped image. But the stage gate exists to fail 25 minutes earlier than
  the smoke does; today it can only ever throw when BOTH majors read back,
  so the empty-read path silently waives exactly the case it was built for.
  Fix: make the empty chain-read loud (assert the probe path exists + version
  output non-empty when `OPENCV_LINK_CHAIN_FFMPEG=1`), and print WHY it was
  empty (path missing vs exit code vs regex miss).
- **107 [M·★★, none] DONE 2026-08-19 (module edit — takes effect with the
  next media rebuild): `Start-/Complete-SccacheServerSession` extracted** with
  a `-SccachePath` test seam + 6 unit tests pinning the truncation and the
  failures-first dump (each had cost a false alarm); war-story comments moved
  with the code, chain functions back to readable size, suite 511/511.
  Original finding: the chain functions carried 134/158 lines of inline
  sccache choreography accreted through #97–#99.

### P7 — PERFECTION CAMPAIGN (owner mandate 2026-08-17: "drastische Maßnahmen erlaubt")

> Sequenced by the verification chain — every tranche lands with the build that
> proves it, never blind. Tranche 1 (uniform `#requires`, zero build cost)
> landed 2026-08-17.

- **108 [M·★★, none] Directory convention for `windows/scripts/` (60 flat
  scripts).** Target: `scripts/build/` (chain components), `scripts/host/`
  (setup/repair/elevated tools), `scripts/diagnostics/` (probes + analyzers,
  merging the half-empty top-level `diagnostics/`), `modules/` and `tests/`
  stay. COSTS: every bind-mount path in the Dockerfiles, the docs script
  table, and downstream repos'' vendored references (CONSUMED-BY modules stay
  put). Land in ONE sweep with a full-chain verify — path moves are the most
  cache-hostile edit there is.
- **109 [L·★★★, staged] Phase-split the monolith build scripts.**
  **TRANCHE PLAN (2026-08-20, execute one tranche per planned rebuild window,
  never standalone - script edits bust the bind-mount cache keys):**
  T1 build-gstreamer (largest, most phases; carry #110's logging sweep for
  the files touched); T2 build-onnx + build-opencv; T3 the litert/tvm pair;
  T4 the setup-* family + #108's directory convention in the same window
  (one big COPY/mount path sweep, all Dockerfiles + drivers + tests in ONE
  commit, verified by a full ride). #110 rides each tranche (its own entry
  says so); #108 lands WITH T4, never alone.
  `build-gstreamer` (991 lines), `build-litert-lm` (1207),
  `smoke-test-container` (1419) each mix download/patch/configure/compile/
  verify in one file. Target: phase functions in the script (not new files —
  bind-mount closures stay stable), each with its own gate, so a failure names
  its phase and a reader navigates by structure instead of scrolling. Do ONE
  script per tranche, verify with its own build; gstreamer first (its three
  fresh gates from #65/#66/#88 already mark the seams).
- **110 [S·★★, none] One logging idiom.** `log` vs `Write-Host` vs
  `Write-BuildLog` across sibling scripts; pick the module helper, sweep the
  rest during #109''s per-script tranches (zero extra builds that way).
> **DECLINED by owner 2026-08-17:** branch protection (#59) and a scheduled
> nightly/weekly chain run (would-be #111). Manual launches remain the
> verification cadence — do not re-propose either.

### Pending host/upstream actions (not refactors — do not let these evaporate)

> The elevated between-runs window (buildkitd step-log env restore, GC-budget
> deploy = #34, poisoned probe-chain prune, diagnostic tag cleanup) and the dufs
> SYSTEM-service migration were APPLIED by the owner 2026-08-13 — see the archive
> addendum. Sanity-check the GC deploy with `buildctl debug workers -v`
> (reservedSpace must read 200GB).

- **UPSTREAM, consolidated 2026-08-17 (was scattered across #99''s body and two
  Open-items entries):**
  1. **moby/buildkit — WCOW cache mounts lose writes into an inherited
     directory.** Cause, A/B measurements and the 2-minute repro are in the
     archive (#99). Strengthen before filing: reproduce with PLAIN file writes
     (no sccache). Goes to moby/buildkit, NOT mozilla/sccache.
  2. **mozilla/sccache#2808 addendum** — the issue''s "WebDAV cache was largely
     empty" reasoning is now explained by the BuildKit mount defect (writes
     never reached the remote because L0 failed first under the default
     write-error-policy=l0). Core findings (nvcc deadlock + miscompile) stand;
     a two-sentence correction protects the report''s credibility. Also note
     CUDA is launcher-off by default since 2026-08-10, so the deadlock repro
     needs SCCACHE_CUDA_LAUNCHER=1.
  3. **Restore `disk,webdav`** once WCOW cache mounts stop losing inherited
     writes — owner intent; two-step re-verification recipe in the archive
     (#99): probe twice (ON-mount row must be clean on the SECOND, inheriting
     run), then one media build with the chain re-enabled and genai at 0 write
     errors.
- **Post the upstream issues** — POSTED 2026-08-13:
  mozilla/sccache → https://github.com/mozilla/sccache/issues/2808 (nvcc
  deadlock + miscompile), google-ai-edge/LiteRT-LM →
  https://github.com/google-ai-edge/LiteRT-LM/issues/3245 (CMake-lane
  staleness, four findings). **STILL TO POST:** opencv/opencv
  (out/upstream-issue-opencv-ort-wchar.md — dnn/ORT `char*` vs `wchar_t`).
- **Post-run diagnostics queue — DEMOTED 2026-08-14: the sccache half is
  CLOSED.** The forensics had escalated this to "sccache has never worked, on
  any run" (0 hits / 189,861 failed writes across 94 stat blocks). **That was
  stale evidence, not a live defect** — the newest sccache stats in the whole
  corpus are from 2026-08-13 19:43, the dufs SYSTEM-service migration landed
  the same day, and every run since had media-core CACHED, so nothing could
  have shown the improvement. A direct probe (real cache mount, real WebDAV
  endpoint, one TU compiled twice) returned **miss → store → HIT, 0 write
  errors, 0 read errors**, and confirmed `HEAD`/`GET`/`PUT` succeed **from
  inside a container** — the direction `Assert-SccacheEndpoint` never tests.
  `SCCACHE_ERROR_LOG` is no longer "the missing artifact": the cache mount was
  found EMPTY, so there was never a log to recover.
  What remains here: (1) the exact-TU replay (`bias_softmax_impl.cu`) for the
  miscompile mechanism and the nvcc/CUDA sccache crash — **untested by the
  clang-cl probe and still genuinely open** (it is what drives #75's silent
  `-j` downgrade ladder); (2) one `probe-build-copy.ps1 -Heavy` smoke after the
  poisoned-chain prune; (3) re-measure the at-scale hit rate on the first real
  media build after 2026-08-13 — until then it is simply unmeasured.
  VERIFIED 2026-08-14: the buildkitd service env now really does carry
  `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `..._MAX_SPEED=-1` (checked at the service
  registry key, and today's base build no longer emits the clip warning) — so
  the next full chain will be the FIRST fully-captured one. The 49-run corpus
  analysed above predates this: 28 of those logs contain real clip events, the
  green reference run is 49 % blind in its merge step, and historical ONNX
  steps are 83 % blind. Re-run the forensics against a full captured chain.
