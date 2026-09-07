# Windows Build Image

**This page is the reference for the image itself** — what is installed, how it
is built, and how it is verified. The lane mechanics, resource budgets and host
fixes moved to their own pages on 2026-08-25:

| Looking for | Read |
|---|---|
| Which lane to build on; isolation policy, preflight gates, RDNA4 A/B history, Store GC | [`windows-build-lanes.md`](windows-build-lanes.md) |
| CPU/memory envelope, sccache wiring, GPU in containers, the 125-layer budget | [`windows-build-resources.md`](windows-build-resources.md) |
| Stevedore post-install fixes, ghcr login, service recovery | [`windows-stevedore-and-docker.md`](windows-stevedore-and-docker.md) |
| Rules you must not regress when editing `windows/` | [`windows-build-invariants.md`](windows-build-invariants.md) |
| An error message | [`failure-modes.md`](failure-modes.md) |
| Open refactor work | [`windows-refactor-backlog.md`](windows-refactor-backlog.md) |
| Building for Windows-on-ARM | [`windows-cross-builds.md`](windows-cross-builds.md) |

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

1. **Generated build files** — patches targeting FFmpeg's generated `ffbuild/*.mak`, `library.mak`, `subdir.mak`, `Makefile`, `ffbuild/config.mak` (post-configure output; content varies per `./configure` invocation) AND the `Update-NinjaFile` calls in `Build-OnnxFromSource.ps1` / `Build-OnnxGenaiFromSource.ps1` that strip MSVC-only flags from CMake-generated `build.ninja` (same family — generated content varies per CMake configure). Inline `-replace` on invariant sub-sequences (`-showIncludes`, `EXTRALIBS-lib*=`, `/experimental:external`, `/Qspectre`) is the canonical form for both.

2. **Fetched third-party deps whose pinned version floats** — `Edit-CppKeywordAlternatives` walks CUTLASS headers fetched by ONNX Runtime's ExternalProject at configure time, AND the companion `_udiv128 → udiv128` substitution on `cutlass/uint128.h` (clang-cl lacks the MSVC-only intrinsic). The CUTLASS fetched SHA varies with the provider's `cutlass-src` ExternalProject pointer; a static `.patch` against a pinned tag would silently rot. The helper form + the targeted inline regex are canonical.

3. **Multi-file conditional substitutions** — LiteRT's `proto/CMakeLists.txt` disable loop (`Build-LitertFromSource.ps1`) walks ~17 files under `$tfliteSrc` and skips files whose content already lacks `protobuf_generate|protoc`. A static `.patch` against a pinned LiteRT tag cannot express the per-file predicate and would only cover a fraction of the proto directories. Similarly, the OpenCV mlas `<cstring>` prepend loop (`Build-OpencvFromSource.ps1`) walks every `3rdparty/mlas/**/*.cpp` and skips files that already include `<cstring>` — same canonical-form rationale.

4. **Installed toolchain headers (not the upstream source tree)** — `Build-OnnxGenaiFromSource.ps1` patches the installed MSVC STL `yvals_core.h` (wrapping the single `_EMIT_STL_ERROR` define in `#ifdef __clang__`, which no-ops *every* STL error code — STL1009/1010/1011, etc. — under clang-cl, so no per-header patch such as one for `<experimental/coroutine>` is needed). The MSVC toolset version floats (resolved via `Get-MsvcToolsRoot`), so a static `.patch` against a pinned MSVC build would only work for one toolset version; the edit is guarded by a drift-assertion that fails the build loudly if a future toolset changes the macro's format.

5. **Binary byte-filter edits** — `onnxruntime.rc` non-ASCII byte stripping (`-le 127`) is a byte filter, not a textual diff. Not expressible as unified diff.

6. **Single-file regex edits on aggressively-changing generated-as-schema upstream files** — The OpenCV `add_extra_compiler_option(-include cstring)` removal (plus surrounding CMake add-to-flags lines on `cmake/OpenCVCompilerOptions.cmake`) is kept inline *not* because a `.patch` couldn't be authored today, but because the upstream context drifts enough between minor releases that a static `.patch` would need re-generation on every tag bump:
   - `Build-OpencvFromSource.ps1` — `cmake/OpenCVCompilerOptions.cmake` `-include cstring` removal

7. **Upstream export-gap bridges (LiteRT-LM v0.14.0) — FROZEN FALLBACK ONLY.**
   The primary LiteRT-LM build is now **Bazel** (`Build-LitertLmBazel.ps1`),
   which is the path Google CI-tests and does NOT need any of these bridges;
   everything in this item applies only to the retired CMake fallback
   `Build-LitertLmFromSource.ps1`. Google ships LiteRT-LM
   tags whose CMake layer lags the source restructure (v0.14.0's was never
   buildable anywhere: it references the deleted `constrained_decoding`
   component, pins a LiteRT from *before* the `support/` tree its own shim
   headers `#include " from @litert"`, and compiles none of the new
   `logits_processor`/support subsystems). `Build-LitertLmFromSource.ps1`
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
|---|---|---|---|
| FFmpeg | `001-allow-msys-builds.patch` | `configure` | Replace `die` with `echo` for MSYS2 build env |
| GStreamer | `001-ges-commit-rename.patch` | `subprojects/gst-editing-services/ges/ges-validate.c` | `#define _commit ges__commit` to dodge `-FIio.h` macro collision |
| ONNX Runtime | `001-softmax-clangcl-keywords.patch` | `core/providers/cuda/math/softmax.cc` | Change the one real ISO-646 `or` → `\|\|` on the dispatch `if` (clang-cl in MS-compat mode treats `or` as an identifier); comments left as upstream |
| ONNX Runtime | `002-disable-cuda-pch.patch` | `cmake/onnxruntime_providers_cuda.cmake` | Disable CUDA EP `target_precompile_headers` (CUDA 13.x CCCL broken with clang-cl) |
| ONNX Runtime | `003-dml-clangcl-compat.patch` | DirectML EP (5 files under `core/providers/dml/`) | [details](#003-dml-clangcl-compatpatch) |
| ONNX Runtime | `004-tunable-severity-macro-collision.patch` | `core/framework/tunable.h` | [details](#004-tunable-severity-macro-collisionpatch) |
| ONNX Runtime | `005-xqa-host-stub-sccache.patch` | `contrib_ops/cuda/bert/xqa/xqa_impl_gen.cuh` | [details](#005-xqa-host-stub-sccachepatch) |
| ONNX Runtime | ~~`006-cuda-llm-bare-nvcc.patch`~~ RETIRED 2026-08-18 | `cmake/onnxruntime_providers_cuda.cmake` | [details](#006-cuda-llm-bare-nvccpatch-retired-2026-08-18) |
| OpenCV | `001-cmake-clang-cl-compat.patch` | `CMakeLists.txt` + `cmake/FindONNX.cmake` | [details](#001-cmake-clang-cl-compatpatch) |
| OpenCV | `002-mlas-clangcl-force-include.patch` | `3rdparty/mlas/CMakeLists.txt` | [details](#002-mlas-clangcl-force-includepatch) |
| OpenCV | `003-mlas-windows-skip.patch` | `3rdparty/mlas/CMakeLists.txt` | [details](#003-mlas-windows-skippatch) |
| OpenCV | `004-dnn-ort-profiling-wchar.patch` | `modules/dnn/src/net_impl_backend.cpp` | [details](#004-dnn-ort-profiling-wcharpatch) |
| OpenCV (contrib) | `001-cudev-windows-llp64.patch` | `cudev/.../common.hpp` | Add `ulong`/`longlong`/`ulonglong` typedefs for Windows LLP64 |

### Per-patch notes

What each of the longer patches does, and why it still exists. A patch whose reason has expired should be retired, not carried.

#### `003-dml-clangcl-compat.patch`

clang-cl + `USE_DML=ON`: out-of-line `AbstractOperatorDesc` members past `OperatorField` (incomplete-type), drop the `.##Z` token-paste, widen `Dispatch<uint32_t>` → `size_t`

#### `004-tunable-severity-macro-collision.patch`

ORT 1.28.0 + CUDA 13.3: `wingdi.h`'s `#define ERROR 0` (reached despite `-DNOGDI` when a header includes wingdi directly — `triton_kernel.h`'s chain does) pre-expands through the `LOGS_DEFAULT` forwarding macro into the nonexistent `Severity::k0` (nvcc: `enum ... has no member "k0"` at the `LOGS_DEFAULT(ERROR)` line, first TU `triton_kernel.cu`); guarded `#undef ERROR` + `#undef VERBOSE` after the includes. Diagnosis trap: the error line number points at whatever `LOGS_DEFAULT(...)` use sits there — read the LINE, not the macro argument you expect

#### `005-xqa-host-stub-sccache.patch`

ORT 1.28.0 XQA (paged-attention) kernels: the host-pass include guard keys on the cmake define `HAS_SM80_OR_LATER`, and sccache's nvcc decomposition (`CMAKE_CUDA_COMPILER_LAUNCHER`) can drop target `-D` defines in the host sub-step → `x_?.cudafe1.stub.c` `C2039/C2065` (`smemSize`/`kernelType`/`cacheVTileSeqLen` missing from `H*::grp*_*`; the synthetic `x_?.cu` TU name is the sccache fingerprint). We pin sm80+ archs, so the patch makes the host stub unconditional. NOT upstreamable as-is (pre-sm80-only builds would regress)

#### ~~`006-cuda-llm-bare-nvcc.patch`~~ RETIRED 2026-08-18

sccache's nvcc decomposition crashes its server deterministically on the fused_moe_gemm generated launchers (two chain runs died at ~4910 s, `os error 10054` on every client). The launchers all live in the `onnxruntime_providers_cuda_llm` OBJECT library, so the patch clears that ONE target's `CUDA_COMPILER_LAUNCHER` property — bare nvcc there. (Historical note: CUDA went opt-in-bare on 2026-08-10, then back to launcher-ON by DEFAULT on 2026-08-18 once mozilla/sccache#2811 fixed the dryrun quote-collapse. So the patch is live again on every normal build; opt out with `-BuildArg SCCACHE_CUDA_LAUNCHER=`.) Hit rates are visible per run via the `sccache-stats|` stderr block after the ONNX build

#### `001-cmake-clang-cl-compat.patch`

CMP0146/CMP0148 OLD→NEW + clang-cl/CUDA detection compat. REGENERATED against 5.0.0 on 2026-08-10 (5.0.0 dropped the `CMP0218` block the old hunk context named; the patch is applied with NO fallback, so drift here throws an hour into media-core — run `Test-PatchesApplyClean.ps1` after every pin bump)

#### `002-mlas-clangcl-force-include.patch`

OpenCV 5.0.0's bundled MLAS treats clang-cl as GNU-Clang and passes the GNU pair `-include` + `cstring`, which the CL dialect parses as an INPUT FILE (`clang-cl: error: no such file or directory: 'cstring'`, first mlas TU). Adds an MSVC-frontend branch (`CMAKE_CXX_COMPILER_FRONTEND_VARIANT`) using `/FIcstring` + `/w`. The older inline `<cstring>` source-prepend loop in Build-OpencvFromSource.ps1 fixes only the CONTENT, not the broken flags

#### `003-mlas-windows-skip.patch`

Skip the vendored MLAS on Windows: its kernels are GAS/ELF-only (`.type sym,@function`, no MASM port) and clang-cl IS a working GAS assembler, so the `check_language(ASM)` guard that saves MSVC does not fire — the `.S` files then die in the integrated assembler ("expected absolute expression", run 12, 2026-08-10). dnn falls back to its built-in SGEMM; inference runs on ONNX Runtime/DirectML anyway

#### `004-dnn-ort-profiling-wchar.patch`

UPSTREAM BUG (5.0.0, run-13 find): dnn's ORT `EnableProfiling` passes `char*` but `ORTCHAR_T` is `wchar_t` on Windows — the model-path call right below is `#ifdef _WIN32`-widened, this one was not (upstream Windows CI never builds dnn with ORT). Issue draft: `out/upstream-issue-opencv-ort-wchar.md`

`ffmpeg/makedef` is **not** a patch — it is a whole-file replacement script staged over FFmpeg's `makedef` (a byte swap, not a diff), so it is not in the table above.

When bumping any upstream version, audit these `.patch` files before letting the orchestrator loose: run `windows/scripts/tests/Test-PatchesApplyClean.ps1`, which clones each pinned upstream and runs the exact `git apply --check` the build uses (see `windows/scripts/patches/README.md`). If a patch no longer applies, regenerate with `git diff` against the new tag and update the inventory above.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake 4.4.2, VS Build Tools 18, LLVM/Clang 22, Rust, Flutter, WiX 4).
- `windows/Dockerfile.nvidia` (optional GPU layer) layers CUDA 13.3 + cuDNN 9.25.0.15 + TensorRT 11.2.1.2 on top of the base image and is tagged `windows-sdk`. If skipped, the base image is tagged `windows-sdk` directly (`docker tag`; the former no-op `Dockerfile.sdk` shim was removed) and downstream stages perform CPU-only builds (CUDA auto-detection falls back to `CPU-only build`). `windows/Build-Buildkit.ps1` handles this automatically via its `-Gpu` switch.
- The toolchain stage builds CPython 3.14 from source (matching the canonical versions.env) via `windows/Dockerfile.toolchain-builder` + `Build-ToolchainAll.ps1` (run+commit for full cores; the former standalone `Dockerfile.toolchain` was removed as dead code — it duplicated the builder without the nuget pre-seed fix).
- The **media stage fans out into three branch images** by `windows/Build-Buildkit.ps1`, built **sequentially** (media-core first — it alone gets the whole RAM budget, maximizing ONNX parallelism). All three branches share ONE multi-stage builder, `windows/Dockerfile.media-builder`, selected per branch via `--target <name>`; then the stage fans in:
  - **media-core** (`--target media-core` + `Build-MediaCoreAll.ps1`, run+commit) — the ONNX dependency chain, sequential: ONNX Runtime 1.28.0 (source build; CUDA EP enabled when the NVIDIA layer was used, DirectML EP always via the clang-cl patch) → ONNX GenAI 0.15.2 (CMake+clang-cl, bypassing `build.py`; built with `USE_DML=ON` + `USE_CUDA=ON`, telemetry off) → OpenCV 5.x (CMake+Ninja+clang-cl, CUDA auto-detected, detects the source-built ONNX Runtime) → FFmpeg `n9.0` (pinned release tag, `FFMPEG_VERSION` in versions.env since 2026-08-04; MSVC toolchain via MSYS2 bash; `--enable-libonnxruntime` links FFmpeg's DNN filters against the source-built ONNX Runtime — note there is no separate `--enable-dnn` flag; DNN filters come with the backend).
  - **media-litert** (`--target media-litert` + `Build-LitertAll.ps1`) — LiteRT 2.1.6 (CMake+Ninja; also builds the TFLite C-API lib `tensorflowlite_c`) → LiteRT-LM 0.15.0 (independent of ONNX; built via **Bazel** with `Build-LitertLmBazel.ps1` → `litert_lm_main.exe`. The former CMake export-bridge path (`Build-LitertLmFromSource.ps1`) is a frozen fallback, see § Source Patch Policy #7).
  - **media-tvm** (`--target media-tvm` + `Build-MediaTvmAll.ps1`) — TVM 0.25.0 → IREE (both LLVM-heavy ML compilers; each installs its Python wheels into the source-built CPython; IREE native tools land at `C:\runtime\iree`, `IREE_ROOT`/`IREE_BIN`).
  - **merge** (`Dockerfile.media-merge-builder`): `COPY --from` fan-in of the three branch trees into one `C:\runtime` + canonical env layout, plus a `cuda-runtime-stage` (via `Copy-CudaRuntime.ps1`) that FLATTENS the CUDA/cuDNN runtime DLLs into `C:\runtime\cuda-runtime\bin` on PATH — the CUDA-linked libs (notably OpenCV, which hard-links `cudnn64_9.dll`) otherwise fail to load in this non-nvidia-based image. Then GStreamer 1.29.2 is built via `Build-GstreamerFromSource.ps1` in the run+commit step (Meson + clang-cl; auto-detects CUDA, OpenCV, ONNX and FFmpeg from the merged tree).
- `windows/Dockerfile.torch` assembles the OrchestrANT app env on the media image (`media → torch → final`; tag `local/kataglyphis:windows-torch`), and `windows/Dockerfile` produces the final developer image FROM that torch image (VsDevCmd entrypoint).

## Component Build Matrix

The **authoritative per-library build reference** for the Windows lane (AGENTS.md § Windows Build Notes points here — update THIS table, never a copy). Versions are pinned in `linux/scripts/01-core/versions.env`.

| Component | Generator | Compiler | Notes |
|---|---|---|---|
| CPython 3.14 | `PCbuild\build.bat` | ClangCL (v145→ClangCL via Directory.Build.props) | Requires VS ClangCL toolset |
| ONNX Runtime (pin: `ONNXRUNTIME_VERSION`) | Ninja | clang-cl, lld-link | [details](#onnx-runtime-pin-onnxruntime_version) |
| ONNX GenAI 0.15.2 | CMake (Ninja) | clang-cl, lld-link | [details](#onnx-genai-0152) |
| OpenCV 5.x | Ninja | clang-cl, lld-link | [details](#opencv-5x) |
| LiteRT 2.1.6 | Ninja | clang-cl, lld-link | [details](#litert-216) |
| LiteRT-LM 0.15.0 | **Bazel** | clang-cl, lld-link | [details](#litert-lm-0150) |
| TVM 0.25.0 | Ninja | clang-cl, lld-link | [details](#tvm-0250) |
| FFmpeg `n9.0` | MSYS2 `make` (MSVC toolchain) | clang-cl via `--toolchain=msvc` | [details](#ffmpeg-n90) |
| GStreamer 1.29.2 | Meson | clang-cl | Downloaded as tarball + subproject wraps. CUDA auto-detected. |

### Per-component notes

The components whose notes do not fit a table cell. Each is linkable, so another page can point at exactly one of them.

#### ONNX Runtime (pin: `ONNXRUNTIME_VERSION`)

**both lanes** (on `-TargetArch arm64` CUDA and TensorRT are OFF, the Python bindings are ON since #120 step 2, and DirectML is **ON** as of backlog #113 — see [`windows-cross-builds.md`](windows-cross-builds.md)): DirectML EP **enabled** (`USE_DML=ON`) via the 3-part clang-cl source patch `003-dml-clangcl-compat.patch` (§ Source Patch Policy; the EOL/context-tolerant inline regex patcher `Invoke-OnnxDmlClangClPatch` in `Build-OnnxFromSource.ps1` remains as the drift fallback): DirectMLHelpers incomplete-type out-lining, `.##Z` token-paste, `Dispatch<size_t>`. CUDA + TensorRT EPs enabled when the NVIDIA layer is the parent (CUDA 13.3 provider, includes crt/ workaround for nvcc). Patches build.ninja for MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM (`.asm` files). **AVX-512/AMX: per-TU only** — global flags OFF (they crashed protoc AND ort's own DLL init at runtime on AVX2 hosts); the build script appends them (`Get-WindowsTargetKernelSimdFlags -Arch` — the old `Get-WindowsX86Avx512Flags` compat shim was deleted 2026-08-26; the amd64 TU pattern was extended 2026-08-24 after under-matching broke the lane, tagged-count floor raised 4→8) to MLAS's runtime-dispatched arch TUs in build.ninja post-configure and logs the tagged count (see AGENTS.md § Windows Build Invariants — don't "simplify" in either direction). 1.28's `ScopedResource<INVALID_HANDLE_VALUE,...>` template arg (rejected by clang-cl) is bridged by an inline post-configure dep patch. Needs ~4 GB RAM/job — media-core runs with `--memory ${MediaMemoryGb}g`.

#### ONNX GenAI 0.15.2

Source-built directly via CMake (bypasses `build.py` which always builds examples). DirectML **enabled** (`USE_DML=ON`, on **both lanes** since #118, 2026-08-24) — compiled straight into `onnxruntime-genai.dll` with 0 source patches (`src/dml` is clang-clean; the `RESTORE_PACKAGES` DXC nuget dep is pruned since shaders are pre-generated DXIL; the `D3D12Core.dll` staged beside the DLL is resolved through a **target-derived** filter — x64 on amd64, arm64 on the cross lane — not the hardcoded x64 an earlier revision of this row implied). CUDA **enabled** (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll`; CUDA and DML are independent CMake blocks so they coexist. `-DENABLE_TELEMETRY=OFF` (0.15 defaults MS 1DS telemetry ON; its bundled zlib also breaks clang-cl under -Werror). VsDevCmd environment loaded for MSVC STL headers.

#### OpenCV 5.x

Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2 (amd64 only; global SIMD flags are empty on arm64 by design). CUDA auto-detected. Custom `CMAKE_AR` path fix.

#### LiteRT 2.1.6

GPU delegate enabled (Vulkan + OpenCL backends). XNNPACK enabled. CUDA paths exposed for external delegate. Also builds the TFLite **C-API** shared lib `tensorflowlite_c` (target injected into the main build, `WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) that gst-plugins-bad's tflite plugin links.

#### LiteRT-LM 0.15.0

On-device LLM inference, built via `Build-LitertLmBazel.ps1` (bazelisk + Temurin JDK, `bazelisk build //runtime/engine:litert_lm_main --config=windows`) → `litert_lm_main.exe`, through the smoke-RUN gate. Bazel is the only path Google CI-tests, so it survives version bumps. The old CMake export-bridge path (`Build-LitertLmFromSource.ps1`, 5 condition-gated self-retiring patches for v0.14's never-functional OSS CMake export — see § Source Patch Policy #7) is a **frozen fallback**.

#### TVM 0.25.0

Auto-detects CUDA/Vulkan. **Builds its own minimal LLVM from pinned source** (#47 heal 2026-08-17: scoop LLVM ships no llvm-config/dev-libs, the official dev tarball is /MT — X86+NVPTX, DIA off, RTTI on, `USE_LLVM=<path>/llvm-config.exe`; SHA pins in `$llvmSrcSha`, ~6 min sccache-warm). Builds a Python wheel. VsDevCmd environment loaded for MSVC STL headers.

#### FFmpeg `n9.0`

Source build from the pinned release tag (`FFMPEG_VERSION=n9.0` in `versions.env`; a release TAG since 2026-08-04 — previously tracked `master`). `--enable-libonnxruntime` links FFmpeg's DNN filter against the source-built ONNX Runtime so ONNX models can run inside `ffmpeg` filters (DNN filters ship with the backend; no separate `--enable-dnn` flag). **x86asm ENABLED on amd64 since 2026-08-24** (#119: nasm-assembled x86 SIMD via `--x86asmexe`; the old unconditional `--disable-x86asm` had no recorded reason — proven the same evening: configure names nasm as the x86 assembler, 154 `X86ASM` objects linked under lld-link). The arm64 cross lane keeps `--disable-x86asm` explicitly (an x86-only knob) and assembles its NEON kernels through clang's integrated assembler. Falls back to a BtbN pre-built GPL binary if the source build fails (the sentinel env var `FFMPEG_SOURCE_BUILD=0` is then set).

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
see [`windows-build-lanes.md`](windows-build-lanes.md) § Getting it going, step 2, including the subnet-drift trap — so
containerd-side networking works too, and `nerdctl` runs the `bk-*` images
fine. `nerdctl` needs an **admin** shell (containerd's pipe is admin-only
upstream); the pre-conf state where `nerdctl run` failed with `needs CNI
plugin "nat"` and `nerdctl build` had broken DNS is historical.

| Tool | Build | Run |
|------|-------|-----|
| `"D:\Stevedore\bin\docker.exe"` (non-admin) | ✅ classic lane | ✅ Works (NAT + DNS + process isolation) |
| `buildctl` via `windows\Build-Buildkit.ps1` (non-admin) | ✅ preferred lane | n/a |
| `nerdctl` (**admin shell only**) | ✅ Works (verified 2026-08-07) — but the chain still uses `buildctl` on purpose, see [`windows-build-lanes.md`](windows-build-lanes.md) § nerdctl lane | ✅ Works — needs the CNI nat **conflist**, see [`windows-build-lanes.md`](windows-build-lanes.md) § nerdctl lane |

## Build Commands

> **Use the BuildKit/containerd lane** — `.\windows\Build-Buildkit.ps1 -Gpu` builds
> the Dockerfiles with **process isolation** (full host CPUs, no Hyper-V 2-CPU cap,
> no run+commit) and real per-stage layer caching. One-time host setup + launch:
> see [`windows-build-lanes.md`](windows-build-lanes.md) § BuildKit/containerd lane.
>
> **The docker-classic lane was RETIRED on 2026-08-26 and its driver
> `windows/build.ps1` DELETED on 2026-08-31** (why, in
> [windows-build-lanes.md](windows-build-lanes.md) § The classic lane was retired).
> `Build-Buildkit.ps1` is now the only driver; a `.\windows\build.ps1` recipe from
> an older page or from shell history has nothing left to run.

Use the driver script from the repository root. It parses `linux/scripts/01-core/versions.env`
and passes every version as `--build-arg` (the Dockerfile ARG defaults are only
fallbacks), builds the stages in order, and applies the correct tags:

```pwsh
# CPU lane (default): base -> tag sdk -> toolchain -> media -> torch -> final
.\windows\Build-Buildkit.ps1

# arm64 cross lane (clang-cl x64 host -> windows-arm64; torch is auto-dropped —
# `uv sync` must execute the target interpreter — and -Gpu is refused):
.\windows\Build-Buildkit.ps1 -TargetArch arm64

# GPU lane: base -> nvidia (CUDA + cuDNN + TensorRT, tagged sdk) -> toolchain -> media -> torch -> final
# Requires a TensorRT zip in windows/downloads/ (see § TensorRT setup (GPU lane, optional) below).
.\windows\Build-Buildkit.ps1 -Gpu

# Iterate on a single stage (layer cache makes this cheap):
.\windows\Build-Buildkit.ps1 -Gpu -Stages media,final

# One media branch only (the merge is skipped unless all three are asked for):
.\windows\Build-Buildkit.ps1 -Gpu -Stages media -MediaBranches media-tvm

# Deliberate clean rebuild (only when you really need it — this discards ALL layer
# caching and rebuilds everything from scratch, which takes many hours):
.\windows\Build-Buildkit.ps1 -Gpu -NoCache

# OrchestrANT app stage (windows/Dockerfile.torch, mirror of linux/Dockerfile.torch):
# a chain stage between media and final (media -> torch -> final) — it assembles the
# app env at APP_REF on windows-media, and the final image builds FROM it. An APP_REF
# bump therefore rebuilds torch + the cheap final tail only (minutes, network-bound):
.\windows\Build-Buildkit.ps1 -Stages torch,final               # versions.env APP_REF pin
.\windows\Build-Buildkit.ps1 -Stages torch,final -LatestApp    # newest release tag
```

Stage results land in the CONTAINERD store as `docker.io/local/kataglyphis:bk-<stage>`
(torch -> `bk-windows-torch`, final -> `bk-winamd64` / `bk-winarm64`), invisible to
`docker` — use `-FinalTar` for a docker-loadable tarball. There is **no**
`-TorchBaseImage` equivalent: the torch stage's `BASE_IMAGE` is pinned to the local
`windows-media` tag, so `-Stages torch,final` needs the local chain images and cannot
be pointed at a published one. `pwsh -File` cannot build arrays — call the script
directly, or `& .\windows\Build-Buildkit.ps1 -Gpu -Stages @('media','final')`.

Layer caching is **on by default**: the Dockerfiles are ordered so that
editing one build script only rebuilds that script's stage and later ones
(`-NoCacheStage <label>` bypasses one stage without the chain-wide `-NoCache`).
`-BuildCtl` overrides the buildctl path (default: the Stevedore install
locations, then `buildctl` on PATH). Set
`KEEP_BUILD_ARTIFACTS=1` (e.g. via a temporary `ENV` line in a media
Dockerfile) to keep the `C:\temp\*-src` build trees for debugging; by default
each build script removes its source tree after installing so the trees don't
bloat the image layers.

### TensorRT setup (GPU lane, optional)

> **Ownership note (2026-08-24):** this subsection is the authoritative home of
> the TensorRT setup procedure and the `current/` rationale (it previously lived
> in AGENTS.md § TensorRT Setup, with this doc pointing back at it — that
> pointer is now flipped: AGENTS.md keeps the operational rules and links
> here). Update THIS section, never a copy.

TensorRT is **not downloaded automatically** — it requires accepting NVIDIA's
EULA. To include TensorRT:

1. Download from https://developer.nvidia.com/tensorrt (e.g.,
   `TensorRT-Enterprise-11.2.1.2-Windows-amd64-cuda-13.3-Release-external.zip`).
   The owner directive that governs this — always take the newest release,
   never lower the pin to match a zip — is
   [`../AGENTS.md`](../AGENTS.md) § TensorRT Setup.
2. Place the zip in `windows/downloads/` and **delete the superseded one**. The
   extract step version-sorts and takes the highest (a `[version]` cast, so
   `11.10.0.1` beats `11.2.1.2` — plain string sort gets that backwards), but a
   stale ~2 GB zip still bloats the `COPY downloads` layer.
3. Set `TENSORRT_ZIP_SHA256` in `versions.env` to the new zip's hash
   (`Get-FileHash -Algorithm SHA256 windows\downloads\TensorRT-*.zip`,
   lowercase). It was EMPTY until 2026-08-14, so ~2 GB of EULA-gated payload
   entered the image unverified. A stale hash now fails the build loudly — that
   is intended, not a bug.
4. It is auto-detected during the `Dockerfile.nvidia` build. `TENSORRT_VERSION`
   never derives a **filesystem** path — the tree is resolved from disk and
   normalized to `current` — and is otherwise used for drift REPORTING. One
   exception, so the claim is not read as absolute: `Install-Tensorrt.ps1` still
   builds its NVIDIA CDN fallback URLs out of the pin, used only when no zip is
   staged.

If no zip is found, the build **skips TensorRT gracefully** (CUDA + cuDNN still
work; `Install-Tensorrt.ps1` warns and returns, ORT auto-disables the TensorRT
EP, and the smoke test's `TENSORRT_ROOT` pointer passes on the guaranteed-empty
`C:\tensorrt`). This zip-less configuration is the NORMAL state of this host's
GPU lane. Do NOT re-harden this into a fail-fast: a 2026-08-04 "fail-fast"
variant (premised on the wrong claim that the smoke test would reject a
TensorRT-less nvidia image) broke the first hardened `-Gpu` rebuild and was
reverted on 2026-08-05. The ORT build script auto-detects `$env:TENSORRT_ROOT`
and enables the TensorRT EP when available.

**A PRESENT zip is a different matter and now fails CLOSED.**
`Set-TensorrtTree.ps1` (bind-mounted into the `trt-extract` stage)
renames the extracted `TensorRT-<version>` tree to a stable **`current`** and
throws if it carries no runtime DLLs. Absent zip = supported; half-extracted
tree = build failure. `Resolve-TensorRtRoot` prefers `current` and falls back
to the versioned glob for older images.

**Why `current` exists — two silent defects, both green for their whole life
(fixed 2026-08-14, backlog #38):** `Dockerfile.nvidia` used to build the
runtime PATH as `$TENSORRT_ROOT\TensorRT-$TENSORRT_VERSION\lib`, which was
wrong twice over. (1) The VERSION came from the pin, so it named a nonexistent
directory the moment the pin and the staged zip disagreed. (2) The DIRECTORY
was `lib\` — **TensorRT 10+ ships the runtime DLLs in `bin\`; `lib\` holds
only link-time `.lib` import libraries** (measured: 14 DLLs vs 6 `.lib`). So
even a correctly pinned image could never load the EP. Neither failed a build,
because ORT resolves its BUILD-time root with a glob and compiles the EP fine —
only the RUNTIME lookup broke, and ORT drops an EP with unreachable DLLs
**silently**. PATH now carries `current\bin` first, `current\lib` after it for
the 8.x/9.x layout. **Never derive that PATH from the pin again**, and note a
Machine-PATH write inside a RUN cannot substitute: `Dockerfile.base` sets
`ENV PATH=` and the image config wins.

### Mandatory GStreamer plugins (the contract)

`libav`, `opencv`, `onnx` and `tflite` are **required** in a shipped image. They
were absent from the published `winamd64` for months and nothing was red:
meson's `auto` feature state means *skip silently when the dependency is
missing*, the build logged `[INFO] not available`, and the healthcheck printed
`[PASS]` for plugins that did not exist (it reports `[FAIL]` now).

The set lives in **one** place — `Get-RequiredGstPlugin`
(`windows/scripts/modules/WindowsGstPlugins.Common.psm1`; it moved out of
`WindowsScripts.Shared.psm1`, which this line named until 2026-08-23, because Shared sits in
the compile closure of all three media branches and this set changes far too often for that)
— and is enforced at four points that used to disagree:

| Where | What it does | On failure |
|---|---|---|
| pre-flight, `Build-GstreamerFromSource.ps1` | emits the missing `.pc` files, disables `FFmpeg.wrap`, resolves every required pkg-config module | **throws in seconds** (54 s on its first live run), before a ~1 h configure+compile |
| meson setup | `-Dlibav=enabled`, `-Dgst-plugins-bad:opencv=enabled`, `-Dgst-plugins-bad:onnx=enabled` | configure fails loudly instead of skipping |
| post-install gate | `gst-inspect-1.0 <plugin>` for the whole set | **throws** — proves the plugin loads, not just that it configured |
| smoke test | same set, as assertions | **fails** the suite |

Four unrelated root causes, diagnosed against gstreamer 1.29.2 sources — one
mechanism per plugin, which is why the single "PKG_CONFIG_PATH" theory never
explained it:

- **opencv** — `gst-plugins-bad/gst-libs/gst/opencv/meson.build` resolves
  `dependency('opencv4', '>= 4.0.0')`. OpenCV installs no `.pc`
  unless `OPENCV_GENERATE_PKGCONFIG` is set, and it would be named `opencv5.pc`
  anyway. Upstream dropped the old `< 4.x` upper bound, so OpenCV 5 is
  version-acceptable — it just needs a file under the name meson looks up.
  Measured on the gate's first live run: the emitter authored `opencv4.pc` with
  **64** import libs enumerated from the actual install.
- **onnx** — `ext/onnx/meson.build` resolves `dependency('libonnxruntime', '>=
  1.16.1')` then calls `subdir_done()`. ORT ships no `.pc` on any platform.
- **libav** — nothing to do with `.pc` files. `subprojects/FFmpeg.wrap`
  *provides* the four `libav*` modules pinned to **FFmpeg 7.1.1**, and
  `-Dwrap_mode=forcefallback` **forces** meson to use it, so pkg-config was
  never consulted: the build was fetching and compiling a second, older FFmpeg
  instead of the `n9.0` it had just built. Even succeeding would have shipped
  gst-libav linked against a different FFmpeg than the image's own `ffmpeg.exe`.
  The wrap is now moved aside before configure. Our own FFmpeg `.pc` files then
  turned out to carry `Version: ..` — which `pkg-config --exists` accepts — so
  it was the pre-flight's `-MinimumVersion` floors, not presence, that caught it
  (fixed by a VERSION file + prefix rewrite).
- **tflite** — a fourth mechanism again: this plugin consults **no pkg-config
  at all**. `ext/tflite/meson.build` probes the compiler directly with
  `cc.find_library('tensorflowlite_c')` (fallback `tensorflow-lite`),
  `cc.has_function('TfLiteInterpreterCreate')` and
  `cc.has_header('tensorflow/lite/c/c_api.h')`. That header path is the
  **pre-rename TensorFlow** one, while LiteRT v2.x ships the post-rename layout
  — `Build-LitertFromSource.ps1` stages headers under `include\tflite\`, so
  upstream's probe could never find them regardless of any `.pc` file. It is a
  namespace mismatch, not a missing dependency, which is why it never looked
  like the opencv/onnx problem. The pre-flight mirrors the header tree to
  `include\tensorflow\lite\`, resolves the C API library by name (failing with
  the list of what *is* staged if neither candidate exists), and puts the LiteRT
  include/lib dirs on `INCLUDE`/`LIB` — the only mechanism `cc.find_library` and
  `cc.has_header` actually consult — as well as into `c_args`/`cpp_args` and the
  link args so the plugin's own compile and link succeed. Both candidate names
  stay listed in upstream's order because on 2026-08-07 only the FALLBACK
  (`tensorflow-lite`) existed; `Build-LitertFromSource.ps1` injects a real
  `tensorflowlite_c` target since, and asserts its import lib after install.

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
> **Six entries since 2026-08-25 (#128):** `webrtc` (gst-plugins-bad) and `nice`
> (libnice's GStreamer plugin) joined the contract on both lanes as meson-native
> entries — the build passes their meson options as `=enabled`, the gate proves
> the DLL and (natively) the load. Proven on the arm64 lane on run 28
> (2026-08-26) after three meson build-only-subproject defects were patched
> around (`docs/windows-refactor-backlog.md` #128), and on amd64 the same day
> (run 7: `gst-inspect` loads `webrtcbin` and `nicesrc`/`nicesink`, smoke
> 222/0/0).

### Toolchain pins and the provenance manifest

Everything that **produces or shapes compiled output** is pinned in
`versions.env` and asserted at base-build time by `Test-Toolchain.ps1`:

| Pin | Installs | Why it is pinned |
|---|---|---|
| `LLVM_WINDOWS_VERSION` | scoop `main/llvm` | clang-cl + lld-link compile the entire media chain, and five patches under `windows/scripts/patches/` are written against a specific clang-cl's diagnostics |
| `NINJA_WINDOWS_VERSION` | scoop `main/ninja` | build-graph executor for every CMake source build |
| `NASM_WINDOWS_VERSION` | scoop `main/nasm` | assembles the x86 SIMD of GStreamer subprojects that ship `.asm` (openh264 — see `Build-GstreamerFromSource.ps1:482`) **and, since #119 (2026-08-24), FFmpeg's hand-written x86 kernels on the amd64 lane** (`--x86asmexe=<nasm>`; before that day FFmpeg passed an unconditional `--disable-x86asm` and nasm assembled nothing for it) — a bump changes shipped object code in both |
| `CMAKE_VERSION`, `VULKAN_VERSION`, `FLUTTER_VERSION`, `GIT_VERSION` | scoop / installer | pre-existing pins, unchanged |

The LLVM pin landed **2026-08-07** and closed a real hole: the OS base is
digest-pinned (`WINDOWS_BASE_DIGEST`) for reproducibility, and the very next
layer then installed whatever clang-cl scoop served that day. A base rebuild
months later would swap the compiler silently, and the breakage surfaces ~2 h
into media-core with no way to reproduce the image that worked. It was pinned
to the version scoop was serving at the time, so it was a no-op for the next
rebuild and a guarantee for every one after. **Bump deliberately**, then re-run
`windows\scripts\tests\Test-PatchesApplyClean.ps1` against the rebuilt base.

Everything else `Install-ScoopTools.ps1` installs (7zip, nano, cppcheck,
sccache, nsis, uv, nuget, zlib, openssl, pkg-config, make, gawk) floats on
purpose — the build only *invokes* those. Move a package into the pinned block
the moment it starts linking into a shipped binary. Note `LLVM_RELEASE` is a
SEPARATE pin for the Linux lane; the two lanes move independently.

Two things still float by design and cannot be pinned the same way: the **MSVC
toolset** inside VS major 18 (Install-Vs.ps1 uses the `aka.ms/vs/18/release`
channel, which refreshes within the major) and scoop's floating block. That is
what the manifest is for:

```pwsh
# in any image built after 2026-08-07
nerdctl --namespace buildkit run --rm --entrypoint pwsh <image> `
  -NoProfile -Command "Get-Content C:\toolchain-manifest.json"
```

`Complete-Container.ps1` writes `C:\toolchain-manifest.json` in the base tail
layer: pinned inputs as `pin`/`resolved` pairs (so a mismatch is visible, not
inferred), the floating ones as resolved values only, plus the OS base digest
and a UTC timestamp. It answers "which compiler built this 49 GB image" from
the artifact rather than from `out\windows-build-logs\`, and it turns
classic-vs-BuildKit lane parity into a `diff` of two files. The smoke test
asserts it exists and records a resolved clang-cl (SKIP on older images).

### Rust toolchain (rustup WITH a default toolchain — never toolchain-less rustup)

Rust is provisioned **exclusively via rustup** (`Install-RustToolchain.ps1` runs
`rustup-init.exe -y --default-toolchain stable --profile minimal`), and
`flutter_rust_bridge_codegen` is baked alongside so Flutter+Rust consumers skip a
minutes-long cold `cargo install` per fresh container.

rustup is **required**, not merely tolerated: Flutter's **Cargokit** (the build
glue used by `flutter_rust_bridge`-style plugins, e.g. `rust_builder/cargokit` in
OmniAccelerANT) enumerates toolchains/targets via rustup and aborts
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

**Since 2026-08-14 this runs AUTOMATICALLY as the last step of every amd64 BK chain
(backlog #44).** `Build-Buildkit.ps1` solves `windows/Dockerfile.smoke-gate`
against the freshly built `winamd64` image after `final`, and a failure fails
the chain. **On `-TargetArch arm64` the gate RUNS since 2026-08-24** (the 2026-08-23 blanket
"inapplicable" verdict was over-broad — roughly half the suite never touches the payload): the
host-toolchain sections (1-6, 14-16, and 19 arch-filtered) execute against the arm64 image with
their own floor column (`MIN_PASSED=66`/`MAX_SKIPPED=20`; measured green at 97/0/15), sections
14/15 compile **for the target** and assert the produced PE machine instead of running, and the
payload sections are skipped as sections with floor 0 — a floor that must stay 0, never be
"fixed" by a skip. The amd64 floors below are untouched, so no later amd64 change can quietly be
measured against a lowered number. The aarch64 payload itself remains verified statically, by
`Test-TargetArch.ps1` in the merge stage. Before that, neither driver invoked the smoke test at all — a
multi-hour build ended with "Done" and zero evidence the image worked, in a repo
whose defect history is dominated by "builds fine, fails to LOAD".

**HISTORICAL — the CLASSIC driver (`build.ps1`) gated too, from 2026-08-21 until the
lane was retired on 2026-08-26 (driver deleted 2026-08-31)** — as a `docker run` with a DIRECTORY mount of
`windows\scripts`: its dockerd has no BuildKit `RUN --mount`, and Windows
containers reject single-FILE bind mounts outright, so the whole scripts directory
was mounted instead; `docker run` also enters through the ENTRYPOINT naturally (no
bare-`RUN` bypass to compensate for). Between 2026-08-14 and 2026-08-21 only the BK
driver gated — a classic chain in that window still ended unverified. Retirement
came from the opposite direction: the gate worked, and it was the gate that proved
the lane could never pass it (`cv2.CAP_GSTREAMER`, see
[windows-build-lanes.md](windows-build-lanes.md) § The classic lane was retired).

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
  (driver: `-SmokeMinPassed` / `-SmokeMaxSkipped`, defaults 160 / 3; the GPU
  lane raises the effective floor to 190 unless overridden) make
  "nothing ran" a distinct failure, **exit 3 = INSUFFICIENT COVERAGE**.
  These defaults describe the **amd64** lane and must not be re-tuned to
  accommodate arm64: that lane has its OWN floor column and driver defaults
  (66/25 — see the smoke-gate paragraph above; this sentence claimed "does not
  run this suite at all" until 2026-08-24, contradicting that same paragraph),
  and a lowered amd64 floor left lying around is how a gate silently stops
  gating. The
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
  pwsh -File C:\temp\scripts\Test-Container.ps1 -ExpectGpu
```

The smoke test validates 22 categories including CUDA Toolkit 13.3, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, TVM (source-built), IREE (source-built; native MLIR→vmfb compile + local-task execution, a CUDA-target compile-only assert on the GPU lane, and a python `iree.compiler`→`iree.runtime` end-to-end), FFmpeg (source-built with DNN/ONNX integration), compiler integration, environment-pointer integrity, and Python bindings. **Current baseline (2026-08-26, `bk-20260826-130136`, via the automatic gate): 222 passed / 0 failed / 0 skipped** — matching the figure this page records in the arm64 parity table. It supersedes 184/0/1 (2026-08-14; the one skip was GPU device passthrough) and the long-stale 2026-07-14 figure of 167/0/1, which predated the mandatory-plugin assertions, the `SCOOP_GLOBAL_SHIMS` checks, the bulk DLL-load enumeration (#57 — it alone load-tests 65 OpenCV DLLs where one was tested before) and the LiteRT export asserts (#67). Record the new figure here from each green run; a HIGHER count is growth, not a regression. Growth over the 153 baseline: the PyAV asserts (staged `av-*.whl` + an in-memory mpeg4 encode through the container-built FFmpeg) and the IREE suite (section 22 native compile+run incl. a CUDA-target compile-only assert, wheel-pin + `--version` asserts, section 20 staged-wheel + python end-to-end asserts, section 19 `IREE_ROOT`/`IREE_BIN` pointers).

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
and nasm are checked against `versions.env` by `Test-Toolchain.ps1` during the
BASE build, where a mismatch costs seconds rather than surfacing two hours into
media-core. This suite deliberately keeps only a well-formedness check on
clang-cl (plus a non-fatal warning when the image's baked pin disagrees), because
it also runs against PUBLISHED and older images whose compiler legitimately
predates the current pin — failing those would make it useless as a regression
gate. It does assert that `C:\toolchain-manifest.json` exists and records a
resolved compiler, skipping on images built before the manifest existed.

**Python bindings are built, shipped, and functionally verified (since
2026-07-13) — on the amd64 lane.** On the arm64 cross lane the same set ships
since 2026-08-24 evening (#120 step 2) and, since 2026-08-26, **including the
TVM and IREE runtime packages** (#133): the target aarch64 CPython
(source-built at `C:\runtime\python`, step 1), the `onnxruntime`,
`onnxruntime_genai_directml`, `av`, `apache_tvm`, `apache_tvm_ffi` and
`iree_base_runtime` wheels in `C:\runtime\wheels` (staged, **not** installed —
nothing here can import them), and `cv2.cp314-win_arm64.pyd` installed into the
target interpreter's site-packages. Six wheels on each lane; the sets differ in
exactly two entries — amd64 additionally has `iree_base_compiler`, and installs
`tvm_ffi` from the vendored source instead of shipping it as a wheel. The
**compiler** packages (`iree.compiler`, TVM codegen) stay amd64-only: they need
an LLVM cross-built for aarch64-windows (#116/#133). On amd64, the media branches build python bindings
for every source-built library that supports them and stage the wheels
centrally at **`C:\runtime\wheels`** (`PYTHON_WHEELS` env): `onnxruntime` (CUDA+TRT+DML EPs,
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
2026-07-13, PyAV died with LNK1181). `Build-FfmpegFromSource.ps1` still
normalizes the import-lib layout after `make install` as a guard across tag
bumps: every `.lib`/`.def` is
harvested into `lib\`, missing import libs are regenerated from their `.def`
via `lib.exe`, and the PyAV step logs the lib inventory up front so the next
layout drift fails loudly with data. `cv2` ships installed into CPython's
site-packages (the opencv repo has no wheel machinery — opencv-python is a
separate upstream project); LiteRT has no python bindings on this lane
(bazel-only python package). All bindings are pre-installed with their PyPI
deps, so `python -c "import onnxruntime, onnxruntime_genai, cv2, tvm, av"`
works out of the box — on amd64; on arm64 the wheels ship staged (install them
on the target host) and no import has ever been executed anywhere.
Smoke section 20 verifies wheels + `win_amd64` tags, real
python-side ONNX inference, a cv2 PNG round-trip, and genai/tvm imports.
Load-bearing plumbing (do not remove): the `sitecustomize.py` shim fixes the
clang-built CPython's win32 platform misreport AND registers the image's
native DLL homes via `os.add_dll_directory` (CUDA 13/cuDNN 9 keep their
runtime DLLs in `bin\x64`; python 3.8+ ignores PATH for pyd dependencies);
OpenCV builds with `WITH_MSMF=OFF` *and* `WITH_OBSENSOR=OFF` because both
hard-import Media Foundation, which Server Core does not ship.

### The torch step (OrchestrANT app environment)

The final image bakes the runtime orchestrator at
**`C:\opt\OrchestrANT`** (`TORCH_APP_DIR`), assembled by
`windows/scripts/build/Build-TorchApp.ps1` (mirror of the linux
`assemble-torch-app.sh` stage) during the final `docker build`:

- **Ref**: `Build-Buildkit.ps1` uses versions.env's **`APP_REF` pin by default** (the
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
  **and the app's own wheel-smoke suite** (`python -m orchestrant.smoke`
  — real torch/torchvision/ORT-inference/OpenCV work). The check inventory is
  the app's per-tag choice, so the expected pass count moves with `APP_REF`;
  the rule on this lane is: **all checks pass except a single WARN for the
  litert skip** (the `ai-edge-litert` limitation above), plus any checks the
  pinned app tag does not yet ship (e.g. an iree check counts only once a tag
  includes it). Smoke section 21 re-runs the same verification offline on
  every suite run.
- **Usage**: `C:\opt\OrchestrANT\.venv\Scripts\python.exe`
  (or `uv run` from `TORCH_APP_DIR`) is a ready environment where
  `import onnxruntime, onnxruntime_genai, cv2, tvm, torch` all resolve to the
  source-built wheels plus the app's locked PyPI dependency set.

## Windows Script Reference

The **authoritative per-script reference** for the Windows lane (AGENTS.md § Windows Build Notes points here — update THIS table, never a copy). Rows marked **HOST maintenance** run on the build host, need the stated elevation, and must never run while a build solves.

**Scan the list, then read the entry.** Grouped by where the script lives;
every entry is individually linkable, and the ones that carry a refusal
condition or a trap say so in their own paragraph rather than in a table cell
nobody can read.

- **Chain components — `windows/scripts/build/`**: [`Build-OnnxFromSource.ps1`](#build-onnxfromsourceps1) · [`Build-OnnxGenaiFromSource.ps1`](#build-onnxgenaifromsourceps1) · [`Build-OpencvFromSource.ps1`](#build-opencvfromsourceps1) · [`Build-LitertFromSource.ps1`](#build-litertfromsourceps1) · [`Build-LitertLmBazel.ps1`](#build-litertlmbazelps1) · [`Build-LitertLmFromSource.ps1`](#build-litertlmfromsourceps1) · [`Copy-CudaRuntime.ps1`](#copy-cudaruntimeps1) · [`Build-TvmFromSource.ps1`](#build-tvmfromsourceps1) · [`Build-FfmpegFromSource.ps1`](#build-ffmpegfromsourceps1) · [`Build-GstreamerFromSource.ps1`](#build-gstreamerfromsourceps1) · [`Import-Versions.ps1`](#import-versionsps1) · [`Complete-Container.ps1`](#complete-containerps1) · [`Test-Toolchain.ps1`](#test-toolchainps1) · [`Test-Health.ps1`](#test-healthps1) · [`Test-Container.ps1`](#test-containerps1) · [`Set-TensorrtTree.ps1`](#set-tensorrttreeps1)
- **Host setup and maintenance — `windows/scripts/host/`**: [`Install-Vs.ps1`](#install-vsps1) · [`Install-ScoopTools.ps1`](#install-scooptoolsps1) · [`Install-Vcpkg.ps1`](#install-vcpkgps1) · [`Install-RustToolchain.ps1`](#install-rusttoolchainps1) · [`Install-Cuda.ps1`](#install-cudaps1) · [`Install-Tensorrt.ps1`](#install-tensorrtps1) · [`Publish-ShimPatch.ps1`](#publish-shimpatchps1) · [`Install-NewHost.ps1`](#install-newhostps1) · [`Set-Rdna4Gpu.ps1`](#set-rdna4gpups1) · [`Get-HostDockerState.ps1`](#get-hostdockerstateps1) · [`Reset-ContainerStores.ps1`](#reset-containerstoresps1) · [`Sync-DefenderExclusions.ps1`](#sync-defenderexclusionsps1) · [`Repair-WindowsComponentstore.ps1`](#repair-windowscomponentstoreps1) · [`Test-HostSetup.ps1`](#test-hostsetupps1) · [`Set-ContainerdConfig.ps1`](#set-containerdconfigps1) · [`Optimize-HostVhdx.ps1`](#optimize-hostvhdxps1) · [`Initialize-Pwsh.ps1`](#initialize-pwshps1) · [`Update-HostVhdx.ps1`](#update-hostvhdxps1) · [`Clear-DiskSpace.ps1`](#clear-diskspaceps1)
- **Diagnostics and probes — `windows/scripts/diagnostics/`**: [`Measure-BuildWarnings.ps1`](#measure-buildwarningsps1) · [`Test-BuildCopy.ps1`](#test-buildcopyps1) · [`Test-Rdna4LayerLock.ps1`](#test-rdna4layerlockps1) · [`Test-CudaCache.ps1`](#test-cudacacheps1) · [`Invoke-SccacheCudaLlmDeadlock.ps1`](#invoke-sccachecudallmdeadlockps1) · [`Test-GeniexNpuDriver.ps1`](#test-geniexnpudriverps1)
- **Reusable modules — `windows/scripts/modules/`**: [`WindowsSourceBuild.Common.psm1`](#windowssourcebuildcommonpsm1) · [`WindowsSmokeTest.Common.psm1`](#windowssmoketestcommonpsm1) · [`WindowsGstPlugins.Common.psm1`](#windowsgstpluginscommonpsm1)
- **Drivers and entry points**: [`Dockerfile.smoke-gate`](#dockerfilesmoke-gate) · [`patches/litert-lm/patch-assert.cmake`](#patcheslitert-lmpatch-assertcmake) · [`Test-SccacheWrite.ps1` + `Invoke-SccacheWriteProbe.ps1` + `Dockerfile.sccache-write-probe`](#test-sccachewriteps1--invoke-sccachewriteprobeps1--dockerfilesccache-write-probe) · [`Test-OpencvVideoBackends.ps1` + `Invoke-OpencvVideoProbe.ps1` + `Dockerfile.opencv-video-probe`](#test-opencvvideobackendsps1--invoke-opencvvideoprobeps1--dockerfileopencv-video-probe)


### Chain components — `windows/scripts/build/`

Run inside the build container as chain stages. Each is invoked by a `*-all` wrapper or directly by the driver.

#### `Build-OnnxFromSource.ps1`

Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper

#### `Build-OnnxGenaiFromSource.ps1`

Source-built directly via CMake+clang-cl (bypasses `build.py` which always builds examples). Loads VsDevCmd via `vswhere`, clones git tag, runs `cmake`/`ninja` directly. CUDA enabled (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll` alongside the DML-enabled `onnxruntime-genai.dll`.

#### `Build-OpencvFromSource.ps1`

Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch

#### `Build-LitertFromSource.ps1`

Ninja+clang-cl; GPU delegate (Vulkan+OpenCL), XNNPACK, external CUDA delegate. Injects + builds the TFLite C-API `tensorflowlite_c` shared lib (`WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) for gst's tflite plugin

#### `Build-LitertLmBazel.ps1`

**PRIMARY LiteRT-LM builder.** Self-installs bazelisk + Temurin JDK; `bazelisk build //runtime/engine:litert_lm_main --config=windows` → `litert_lm_main.exe` through the smoke gate. Neutralizes the base image's Android env/WORKSPACE pollution; patches the WORKSPACE zlib URL to the GitHub release mirror (zlib.net is flaky). `output_base` stays container-local (wcifs rename hazard)

#### `Build-LitertLmFromSource.ps1`

**FROZEN FALLBACK** (superseded by the Bazel builder above). Ninja+clang-cl; carries the v0.14.0 export-bridge patch stack (`[LiteRTLM-winfix export-stubs]` / `[LiteRTLM-winfix support-graft]` / v0.14 orphans + deps blocks) — all gated on the breakage so they self-retire when upstream's CMake catches up

#### `Copy-CudaRuntime.ps1`

Runs in the merge's `cuda-runtime-stage` (derived from media-core). Recursively FLATTENS the CUDA_ROOT/CUDNN_ROOT DLLs into one dir COPY'd to `C:\runtime\cuda-runtime\bin` on PATH (cuDNN 9 buries DLLs in a CUDA-major subdir); hard-gates on `cudnn64_9.dll`. Fixes opencv's plugin load in the non-nvidia merge image

#### `Build-TvmFromSource.ps1`

Ninja+clang-cl; auto-detects CUDA/Vulkan/LLVM; builds Python wheel; VsDevCmd for MSVC STL headers

#### `Build-FfmpegFromSource.ps1`

MSYS2 `make` with `--toolchain=msvc`; `--enable-libonnxruntime` links against the source-built ONNX Runtime. Loads `versions.env` via `Import-Versions.ps1` for the centralized `FFMPEG_VERSION` tag pin. Falls back to BtbN pre-built GPL binary on source-build failure (`FFMPEG_SOURCE_BUILD=0` sentinel).

#### `Build-GstreamerFromSource.ps1`

Meson+clang-cl with wrap pre-extraction; loads `versions.env` via `Import-Versions.ps1`

#### `Import-Versions.ps1`

Reads `C:\temp\versions.env` (COPY'd from `linux/scripts/01-core/versions.env`) and sets matching process env vars so Windows build scripts consume the same canonical versions as Linux

#### `Complete-Container.ps1`

Enables git long paths and sets `core.longpaths` in the final image; writes the **toolchain provenance manifest** `C:\toolchain-manifest.json` (2026-08-07) — pinned inputs with pin-vs-resolved pairs (LLVM, ninja, nasm, CMake, Vulkan, Git, Flutter, VS→MSVC toolset, SDK build) plus the floating ones (lld-link, rustc/cargo, sccache, uv, pwsh, openssl, pkg-config) and the OS base digest. Answers "which compiler built this image" from the ARTIFACT instead of a build log that ages out, and makes classic-vs-BK lane parity a `diff`. Every probe is best-effort (missing tool → `null`, never a failed layer)

#### `Test-Toolchain.ps1`

Verifies clang-cl, lld-link, WiX, Flutter are present after base setup, and ASSERTS the pinned versions (clang-cl/ninja/nasm/CMake vs `versions.env`) — a silent scoop fallback otherwise surfaces ~2 h into media-core as a patch that no longer applies

#### `Test-Health.ps1`

Docker `HEALTHCHECK` script — verifies ONNX Runtime DLL, FFmpeg, GStreamer, CMake, clang-cl

#### `Test-Container.ps1`

Comprehensive container validation — **22** test categories (an earlier AGENTS.md copy of this row said 18 until 2026-08-08; this doc had the right count all along). Runs INSIDE the final image, which `windows/Dockerfile` COPYs it into along with the whole `modules` dir. The 22 sections live here; the assertion harness is in `WindowsSmokeTest.Common.psm1`

#### `Set-TensorrtTree.ps1`

Bind-mounted into `Dockerfile.nvidia`'s `trt-extract` stage. Renames the extracted `TensorRT-<version>` tree to a stable **`current`** so the runtime PATH never spells the pin, WARNS (never fails) on pin-vs-zip drift, and **fails closed** when neither `bin\` nor `lib\` carries runtime DLLs. Backlog #38: the old pin-derived PATH was wrong twice over — wrong version AND wrong dir (TensorRT 10+ moved the DLLs to `bin\`), so the ORT TensorRT EP could never load, silently, while builds stayed green. Absent zip stays a supported graceful skip; a half-extracted tree is a build failure.

### Host setup and maintenance — `windows/scripts/host/`

Run on the HOST, most of them elevated. Several refuse while a build is solving — that is deliberate, not a bug.

#### `Install-Vs.ps1`

Installs VS Build Tools 18 with ClangCL toolset

#### `Install-ScoopTools.ps1`

Installs Git (installer) + WiX 4 (dotnet tool), then via Scoop: 7zip, Vulkan SDK, Flutter, LLVM, ninja, sccache, cppcheck, nano, nsis, uv, nuget, zlib, nasm, openssl, pkg-config, CMake. Installs **no** Rust (rustup via `Install-RustToolchain.ps1` is the sole provider). **PINNED from versions.env (2026-08-07): LLVM/ninja/nasm** (`LLVM_WINDOWS_VERSION`/`NINJA_WINDOWS_VERSION`/`NASM_WINDOWS_VERSION`, forwarded as Dockerfile ARGs) on top of the existing CMake/Vulkan/Flutter/Git pins — those three produce or shape compiled output, and an unpinned clang-cl made the base image unreproducible in its most load-bearing component (five patches under `windows/scripts/patches/` are clang-cl-version-shaped). `Test-Toolchain.ps1` asserts all three at base-build time. The rest stay floating deliberately — the build only invokes them. **Caveat (2026-08-08): that justification stops holding for `sccache` the moment multi-tier caching is wired** — the L0 tier then exists or not depending on the installed version (needs >= v0.16.0), and an older one ignores the config **silently**. Pin sccache in the same change, not after

#### `Install-Vcpkg.ps1`

Bootstraps vcpkg for Windows

#### `Install-RustToolchain.ps1`

Installs Rust via rustup WITH a stable default toolchain (sole provider; local `file://` dist mirror dodges rustup's downloader deadlock in 2-CPU containers), runs Cargokit-shaped asserts, bakes `flutter_rust_bridge_codegen`

#### `Install-Cuda.ps1`

Installs CUDA 13.3 + cuDNN; includes post-install verification (headers/libs/DLLs)

#### `Install-Tensorrt.ps1`

Auto-detects a TensorRT zip in `windows/downloads/` and installs it

#### `Publish-ShimPatch.ps1`

HOST maintenance (admin, never while a build solves): installs a locally built `containerd-shim-runhcs-v1.exe` over Stevedore's, keeping `.orig` (stock, written once) plus a timestamped backup per deployment, and optionally merges env vars into the containerd service (`-ServiceEnvironment`) since the shim inherits them. `-ReportOnly` lists installed binary, backups and env without touching anything; `-Restore .orig` / `-Restore .45min` puts a backup back. Refuses while `buildctl` or a shim process is alive (the binary is locked). Needed because every Stevedore/containerd update silently reverts the patched shim — see [`windows-build-lanes.md`](windows-build-lanes.md) § BuildKit/containerd lane and `windows/upstream/`. NB: a quiet log is NOT proof it took effect (the shim logs its effective timeout at Debug, which does not reach containerd's log) — verify behaviourally with the OpenCV canary

#### `Install-NewHost.ps1`

HOST bring-up (admin, run `-ReportOnly` first, never while a build solves): the ONE elevated run that turns a freshly-rebooted Stevedore host into a green `Test-HostSetup.ps1`. Orchestrates the canonical per-concern scripts rather than duplicating them: authors the CNI `.conflist` from the LIVE `vEthernet (nat)` subnet (derived network/prefix+GW at runtime — no magic subnet literals anywhere), then `Set-ContainerdConfig.ps1` (derives the `.conf`, debug flags, teardown env, Defender), `Set-BuildkitdGcpolicy.ps1` + the `BUILDKIT_STEP_LOG_*` step-log env, the patched runhcs shim (BUILDS the 45min/100min fixed-constant shim from hcsshim source when no `-ShimPath` is given, installing Go via scoop — the recipe from `windows/upstream/`, then `Publish-ShimPatch.ps1`), and dufs (scoops if missing, starts it, registers the ONLOGON task, sets machine `SCCACHE_WEBDAV_ENDPOINT` to the host's LAN IP). Idempotent; every sub-script is called with a HASHTABLE splat (array splatting would bind `-ReportOnly`/`-ShimPath` by position — the array-splat rule in AGENTS.md). Companion to `Test-HostSetup.ps1` below

#### `Set-Rdna4Gpu.ps1`

HOST maintenance (admin): enable/disable the RDNA4 dGPU in Device Manager (`-GpuName` overrides the RX 9070 XT default — the gate fires for ALL RX 9xxx/R9700 SKUs, so the remedy must reach them too; added 2026-08-10 W1). **RE-INSTATED 2026-08-10 as the RDNA4 build-window workaround** (the 2026-08-09 "obsolete" verdict is superseded): an enabled RDNA4 dGPU kills every process-isolated RUN-layer finalize (`ActivateLayer 0x20`, docker/for-win#14977; A/B-proven). Workflow: `-Disable` → build (display falls back to the iGPU) → default action re-enables. `Build-Buildkit.ps1`'s `Assert-NoActiveRdna4Gpu` preflight refuses while the dGPU is enabled.

#### `Get-HostDockerState.ps1`

Cross-machine forensics for "works there, fails here": dumps OS build, optional features (DISM API health - reports "Klasse nicht registriert" when broken), filter drivers, services, engine versions, docker info, HNS. Writes `out\host-docker-forensics.txt`. Elevation needed for feature/fltmc reads.

#### `Reset-ContainerStores.ps1`

HOST maintenance (admin, never while a build solves): full container-store reset - stops the services, RENAMES `C:\ProgramData\containerd`/`buildkitd`/`Docker` to `.bak-<stamp>` (rollback), restarts clean, re-deploys the GC-policy toml. The docs' last resort for persistent, non-release hcsshim weirdness; safe on a fresh host (stores re-pull).

#### `Sync-DefenderExclusions.ps1`

HOST maintenance (admin): prints, then applies if missing, the FULL Defender exclusion set for Windows-container builds - paths (`C:\ProgramData\containerd`/`buildkitd`/`Docker`/`nerdctl`, `C:\ProgramData\Microsoft\Windows\Containers`, `C:\temp`, `C:\WINDOWS\SystemTemp`) and processes (dockerd/containerd/buildkitd/nerdctl/CExecSvc/vmcompute). READ the BEFORE output: non-admin cannot see `Get-MpPreference`, so this is the only proof exclusions were ever applied.

#### `Repair-WindowsComponentstore.ps1`

HOST maintenance (admin, long-running 10-40 min): `DISM /Online /Cleanup-Image /RestoreHealth` + `sfc /scannow`, re-tests the DISM API (was `Klasse nicht registriert` on the reference-discovered box), then re-runs the 3-layer probe. The OS-level repair step for hosts where container-layer ops fail and everything else is clean.

#### `Test-HostSetup.ps1`

The machine-checkable form of `docs/windows-host-setup.md` — run it FIRST on any new machine, and after any host change. Non-admin: services, `buildctl` reaching buildkitd unelevated, nerdctl presence, **BOTH CNI forms** (`.conf` for buildkitd — missing is a FAIL; `.conflist` for nerdctl — missing is a WARN) plus content agreement between them and subnet-vs-adapter drift, patched runhcs shim **by SHA256** against the hash `Publish-ShimPatch.ps1` recorded at install (size only as a fallback, reported as a WARN so "still guessing" is visible), containerd teardown env var + debug flags, worker snapshotter + gcpolicy, disk headroom **on C: AND the repo/build-context drive**, sccache reachability. Exit 1 on any FAIL; each failure prints its fix. Defender exclusions are reported UNKNOWN (not skipped) when unelevated, so their absence cannot masquerade as success. Registry values that do not EXIST (e.g. the containerd `Environment` value before the first apply) degrade to WARNs, not a mid-run crash (fixed 2026-08-09 — the old `(Get-ItemProperty ...).Environment` threw PropertyNotFound at line 212 and silently skipped the teardown-env + debug-flag checks, under-counting the verdict). **Keep it in step with the guide — they are two views of one contract**; the guide had shipped a broken CNI template for days precisely because prose cannot be executed

#### `Set-ContainerdConfig.ps1`

HOST config (admin; never while a build solves — applying restarts containerd and kills in-flight solves). The containerd counterpart to `Set-BuildkitdGcpolicy.ps1`. It owns the debug-log flags, the runhcs shim teardown timeout, the GC policy and the CNI `.conf`/`.conflist` pair — all of which live only in the service's registry values, because containerd runs with no `config.toml` here. What each setting is for, and why a script is the only reproducible way to hold them: [`windows-host-setup.md`](windows-host-setup.md#c1-permanent-debug-flags-on-containerd--buildkitd-owner-policy).

#### `Optimize-HostVhdx.ps1`

HOST maintenance (admin, never while a build solves): reclaims disk when the checkout/store sits on a dynamically-expanding VHDX. Kills stale `buildctl`, stops the build services, detaches → compacts (`Optimize-VHD`) → reattaches read-write in a `finally`, restarts. `-ReportOnly` reports sizes/guest-fs/reclaim potential without touching anything. Machine-specific values are all parameters (`-VhdxPath` mandatory, `-Service`, `-BlockingProcess`, `-VerifyPath`, `-LogPath`, `-Mode`). Warns on ReFS guests, where compaction reclaims ~nothing (measured: 0.2 GB of a possible 254 GB) — see [`windows-build-lanes.md`](windows-build-lanes.md) § Store GC. When it reports a near-zero reclaim, `Update-HostVhdx.ps1` is the answer

#### `Initialize-Pwsh.ps1`

Installs PowerShell 7 as the FIRST RUN of `Dockerfile.base`, BIND-MOUNTED (no layer). Runs under Windows PowerShell **5.1** — the SHELL is not switched to pwsh until after it — so keep it 5.1-safe and do not use `Invoke-DownloadWithRetry` (no module is mounted that early). Carries its own 3-attempt retry with an in-loop SHA256 check. Extracted from a 1214-char inline RUN (backlog #27).

#### `Update-HostVhdx.ps1`

HOST maintenance (admin, never while a build solves): reclaims a dynamically-expanding VHDX by REBUILDING it around its live data — the only reliable reclaim on ReFS guests, where `Optimize-HostVhdx.ps1` returns ~nothing. Creates a fresh dynamic disk, reproduces the source's filesystem/label/cluster size (and Dev Drive flag where `Format-Volume -DevDrive` exists), mirrors with `robocopy /MIR /COPYALL`, then verifies file count AND byte totals before anything is swapped. TWO PHASES on purpose: `-CopyOnly` touches nothing live and is safe with editors/agents still on the volume; the swap DETACHES the volume and so requires that no process holds a handle on it (a stray detach on 2026-08-06 pulled D: out from under a running session and killed it) — it REFUSES rather than forces, keeping the verified copy for a later `-SwapOnly`. Old disk kept as `.old` unless `-RetireOld`; **no space is reclaimed until it is deleted.** Failed swaps roll back to the original disk automatically. Parameters: `-VhdxPath` mandatory, `-NewSizeGB`, `-NewVhdxPath`, `-Service`, `-BlockingProcess`, `-VerifyPath`, `-ExcludeDir`, `-LogPath`, `-ReportOnly`, `-CopyOnly`, `-SwapOnly`, `-RetireOld`, `-Force`. Put `-LogPath` off the volume for swap runs

#### `Clear-DiskSpace.ps1`

HOST disk reclaim — **the only sanctioned one; never compose an ad-hoc cleanup command** (2026-08-21 incident: an improvised one went past the container stores into the installed programs and the user profile, and the host had to be rebuilt by hand). Cleans exactly the regenerable classes: **unused container layers** (`buildctl prune --free-storage`, `docker image prune -f` — the daemon knows what is still referenced), **dead `*.bak-<stamp>` store husks** left by `Reset-ContainerStores.ps1`, **user + Windows TEMP**, rotated host logs and repo `out/` scratch. Works from an ALLOWLIST, never a denylist; **reports by default — `-Apply` is required to delete**; every live-directory rule is **age-gated** (`-TempOlderThanDays`, default 7) so nothing in flight is touched. Fails the WHOLE run if any resolved candidate lands on a protected root (Program Files, Windows, ProgramData outside the container stores, user profiles, AppData, drive roots), because that means the resolution logic is wrong, not that one target should be skipped. Skips any candidate containing a junction/symlink — a reparse point is where a name stops predicting what a recursive delete reaches. **Never touches the sccache/ccache/cargo/uv compile caches** (CACHE1: hours of build time for a few GB) or anything installed. Refuses the destructive half while a build looks live unless `-AllowDuringBuild`. Parameters: `-Apply`, `-KeepGB` (buildkit free-space target, default 100), `-TempOlderThanDays`, `-AllowDuringBuild`, `-NoDaemonPrune`. Enforced from outside the script too, by the `PreToolUse` guard in `.claude/hooks/guard-destructive-deletes.ps1`; behaviour pinned by `windows/scripts/tests/Guard.DestructiveDeletes.Tests.ps1`

### Diagnostics and probes — `windows/scripts/diagnostics/`

Read [`windows-build-invariants.md`](windows-build-invariants.md#when-a-probe-says-the-product-is-broken-suspect-the-probe-first) before trusting any verdict here: three probes lied before one told the truth.

#### `Measure-BuildWarnings.ps1`

Counts compiler warnings in a build log grouped by diagnostic family; `-Baseline` prints the four known upstream floods against their pre-suppression counts with a verdict per family. Run it after a chain to PROVE the targeted `-Wno-` flags (OpenCV/ONNX/TVM) and IREE's `_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING` still earn their place — 16 % of one chain log was upstream warnings, and buildkitd clips a RUN step at 2 MiB then deadlocks it

#### `Test-BuildCopy.ps1`

The committed build probe (assets `windows/scripts/diagnostics/probe-build-copy/`): `FROM servercore` + `RUN` + `COPY`, BK lane exporting `type=image,...,unpack=true` (the real lane's output path), per-lane exit codes; `-Heavy` adds the heavyweight-RUN finalize lane (the shape the RDNA4 interaction kills), `-Docker` the classic-builder lane. **Run `-Heavy` before trusting a new Windows host** — only a `-Heavy`-green verdict counts (light lanes stayed green while the chain died, 2026-08-10). No admin.

#### `Test-Rdna4LayerLock.ps1`

RDNA4 layer-lock A/B (ELEVATED): probes RUN-layer finalize with the dGPU enabled, then disabled (auto re-enables in a finally). Verdicts: GONE / PRESENT / INCONCLUSIVE. **Re-run after every Adrenalin or Windows update** — a GONE verdict is the signal to retire the toggle workflow + `Assert-NoActiveRdna4Gpu` gate (docker/for-win#14977 tracked upstream).

#### `Test-CudaCache.ps1`

CUDA-cache probe (non-admin, ~2 min, safe beside a live build): tiny buildctl solve FROM the local toolchain image compiles one `.cu` TWICE through sccache against the live WebDAV endpoint; exit 0 only when the recompile HIT (per-component: CUDA/Device/PTX/CUBIN) AND objects landed in the store. Verified 2026-08-10 (4/4 hits, 4 objects on disk). **Run after every sccache bump** — the launcher's value rests on this property.

#### `Invoke-SccacheCudaLlmDeadlock.ps1`

**Deliberately fails.** Reproduces the sccache nvcc server deadlock and collects a server-side trace for mozilla/sccache#2808. Sets `SCCACHE_REPRO_CUDA_LLM=1`, which makes `Build-OnnxFromSource.ps1` SKIP patch 006 so the sccache CUDA launcher stays on for `onnxruntime_providers_cuda_llm` — the target the workaround exists to protect. Expect the build to die ~80 min in; that failure IS the artifact. Refuses to start while another `buildctl` is running (a concurrent build shares the sccache server and the locked mount, so a wedge would be unattributable). Needs `ARG SCCACHE_REPRO_CUDA_LLM` wired into `Dockerfile.media-builder`'s media-core-env stage first — it checks and throws with instructions if absent.

#### `Test-GeniexNpuDriver.ps1`

Diagnoses why GenieX's Hexagon NPU path fails on a Snapdragon X Windows host.
Checks the **active** CDSP `libcdsprpc.dll` (matched to the Hexagon NPU
device's installed driver version — the DriverStore keeps stale copies that
would otherwise produce false verdicts) for the `dspqueue_*` symbols GenieX
v0.5.0's bundled llama.cpp `ggml-hexagon` backend dlsyms. A driver predating
2026 exports only the legacy FastRPC API and fails with
`ggml-hex: failed to dlsym dspqueue_create` / `Device 'HTP0' not found`.
Reporting only; never throws on a negative result. See
[`geniex-local-ai-setup.md`](geniex-local-ai-setup.md) § The NPU problem.

### Reusable modules — `windows/scripts/modules/`

Consumer-facing PowerShell API. Never delete on a "zero references" audit — other Kataglyphis repos import these.

#### `WindowsSourceBuild.Common.psm1`

Reusable build helpers: `Invoke-GitClone`, `Invoke-CmakeConfigure`, `Get-SourceBuildVersion`, `Get-CudaRoot`, `Enter-VsDevCmdEnvironment`, `Invoke-SourcePatch` (idempotent, reverse-check, patch.exe fallback), `Edit-CppKeywordAlternatives`, `Update-NinjaFile`, `Initialize-SourceBuildEnvironment`, `Initialize-ToolchainPythonEnvironment`, `Get-GpuEnvironment`, `Resolve-TensorRtRoot`, `Get-WindowsTargetSimdFlags`, `Get-WindowsTargetKernelSimdFlags` (the arch-agnostic pair that replaced `Get-WindowsX86SimdFlags`/`Get-WindowsX86Avx512Flags`, deleted 2026-08-26). This facade is mounted into all 11 media RUNs, so single-consumer helpers live on the leaf modules instead: `Write-AssembledWheelDistInfo` and `Get-PyprojectDependencies` moved to `WindowsTvm.Common.psm1` (2026-08-31), their only caller being `Build-TvmFromSource.ps1`

#### `WindowsSmokeTest.Common.psm1`

Smoke-test assertion harness, extracted 2026-08-08: counters plus `Initialize-SmokeTestRun`, `Get-SmokeTestSummary`, `Assert-Test`, `Assert-CommandExists/FileExists/DirectoryExists/ArtifactPresent/NativeLinkRun/DllLoads/EnvVarSet`, `Skip-Test`, `Write-TestHeader`. **Call `Initialize-SmokeTestRun -ExitOnFirstFailure:$ExitOnFirstFailure` before the first assertion, and read counts via `Get-SmokeTestSummary`** — the module has its own session state, so `$script:passed` read from a caller resolves to a different, always-zero variable, and a script parameter is invisible to the module. Both failure modes are silent, which is why they are unit-tested

#### `WindowsGstPlugins.Common.psm1`

The mandatory GStreamer plugin CONTRACT (see § Mandatory GStreamer plugins and AGENTS.md § Windows Build Invariants): `Get-RequiredGstPlugin` (libav/opencv/onnx/tflite with per-plugin detection mechanism and rationale), `Write-PkgConfigFile`, `Get-LibraryLinkName`, `Assert-PkgConfigModule` (presence AND `-MinimumVersion` floors — `pkg-config --exists` alone passes on a `.pc` whose version field is empty). Merge-stage only, deliberately NOT in `WindowsScripts.Shared.psm1`: that one is in all three media branches' compile closure and this set changes often

### Drivers and entry points

The top-level scripts a human or CI actually invokes.

#### `Dockerfile.smoke-gate`

*`windows/`*

Not a script — the automatic verification stage (backlog #44). Solved against the finished image as the last step of every BK chain — **both lanes** since 2026-08-24 (this row said "NOT run on arm64" until then, contradicting § Smoke Testing): on arm64 the suite runs its host-toolchain sections against the lane's own floors (66/25) while the aarch64 payload stays verified by `Test-TargetArch.ps1` in the merge stage. Runs a buildctl solve rather than `nerdctl run` because containerd's pipe is admin-only while the driver is non-admin, invokes the test **through `entrypoint.cmd`** (a bare RUN bypasses ENTRYPOINT and loses VsDevCmd + the ASAN runtime dir), and **bind-mounts** the current script + modules so a smoke-test fix needs no image rebuild to re-verify. Knobs: `-SkipSmokeGate`, `-SmokeMinPassed`, `-SmokeMaxSkipped`.

#### `patches/litert-lm/patch-assert.cmake`

*`windows/scripts/`*

`patch_replace_required` / `patch_regex_replace_required` — replace-with-verification for the CMake source patchers (backlog #56). `FATAL_ERROR`s when a pattern matched NOTHING, instead of the old bare `string(REPLACE)` + unconditional "Patched …" message that let an upstream reformat silently restore a fixed defect. Lives INSIDE `litert-lm/` because the Dockerfile COPYs that directory specifically. Enforced by `Patches.CmakeNoOpGuards.Tests.ps1`; a legitimate non-source replace opts out with a `patch-assert-exempt` marker + reason.

#### `Test-SccacheWrite.ps1` + `Invoke-SccacheWriteProbe.ps1` + `Dockerfile.sccache-write-probe`

*`windows/scripts/`, `windows/`*

Reproduces the sccache **cache-write** environment in ~2 min instead of a 90-min media build (backlog #99): same cache-mount ids, same ENV, then a configuration matrix (`disk-only`, `disk-mounted-subdir`, `disk-plaindir`, `multilevel-mounted`, `multilevel-plaindir`, `webdav-only`), raw filesystem tests, a process-spawn matrix, a bisect of the cache root, serial-vs-parallel and path-length sections. **Run it against the REAL base image** (`-BaseImage local/kataglyphis:bk-windows-media-core-ffmpeg`), not the toolchain default. **Health warning:** it reproduces the ENVIRONMENT but not the FAILURE — every configuration it blessed then failed in a real build, so treat its verdicts as hypotheses to test in a build, never as clearance. `PROBE_NONCE` + a `probe complete` marker check exist because an unchanged script gives `#6 CACHED` and silently replays an old verdict; `--no-cache` is not the alternative (it empties cache mounts, #96).

#### `Test-OpencvVideoBackends.ps1` + `Invoke-OpencvVideoProbe.ps1` + `Dockerfile.opencv-video-probe`

*`windows/scripts/`, `windows/`*

Asks a BUILT media image what video backends OpenCV actually has (backlog #93-#95): prints the `Video I/O:` block, runs the three #95 assertions, and shows `videoio_registry.getBackends()` beside them. ~4 s against `bk-windows-media-core-ffmpeg`, versus a full chain rebuild — which is what let the #95 guards be watched FAILING on the real artifact before the fixes land. Same two safeguards as the sccache probe: `PROBE_NONCE` (a re-run with an unchanged script otherwise gives `CACHED` and replays an old verdict) and a `probe complete` marker check; `--no-cache` is not the alternative, it empties cache mounts (#96).

## Reusable module: WindowsContainerBuild.Reuse

The container-reuse pattern, packaged so consumers do not each reinvent it. Consumers resolve it ContainerHub-first with a vendored fallback.

`windows/scripts/modules/WindowsContainerBuild.Reuse.psm1` implements the
container-reuse pattern so consumers do not each reinvent it:

- `Get-ReusableBuildContainer` - reuse/start/recreate a named build container,
  recreating it when the image ID changes. Returns whether an existing
  container was reused.
- `Copy-IntoBuildContainer` / `Copy-FromBuildContainer` - tar-pipe transfers
  with exclusion support (mandatory for deep paths; one over-long path aborts
  the whole transfer).
- `Remove-StaleContainerSources` - prune non-build directories from a reused
  workspace (tar extracts over the tree but never deletes).
- `Initialize-ContainerPwsh` - ensure PS 7 exists in a running container
  (scoop install fallback).
- `Test-BuildArtifactsDelivered` - throw when a green build produced no
  executables or the outbound transfer silently delivered nothing.
- `Resolve-DockerExe`, `Get-ContainerIsolationArgs`, `Test-ContainerBindMount`,
  `Remove-BuildContainerSafe` - docker discovery, isolation args, bind-mount
  probing, wcifs-tolerant removal.
- `Wait-ContainerExit` - wait on the CONTAINER's state and return the exit code
  it really had, instead of trusting the docker client. The CLI intermittently
  drops its pipe mid-run while the container keeps building, and the client then
  reports a failure that did not happen; this is the same lost-exit-notification
  family as the 2026-09-01 `tearDownTimeout` finding, one layer up. Upstreamed
  from OxidANT's Stevedore lane, which had hand-rolled it.

`Wait-ContainerExit` only applies to a container whose MAIN process is the
workload - `docker run --name`, and never `--rm`, because `--rm` has the daemon
delete the container (and its exit code) the instant it exits. That is why
`Invoke-ContainerBuild`'s **bind-mount** transport now names its run and removes
it itself - on success only: a failed or timed-out run keeps the container so
the `docker logs` advice in its error stays runnable, and a leftover name that
cannot be freed gets a unique fallback instead of a false green (see
`windows-container-build-performance.md` § Reusable implementation). The
**tar-pipe** transport cannot use it: its reusable container's
main process is a 7-day `ping`, so `State.Status` reads `running` whatever an
exec'd build did. There, a non-zero `docker exec` is instead classified against
the container's state, so "the container died under the build" stops being
reported as a build error to hunt in the log.

Consumers resolve it ContainerHub-first with a vendored fallback (see
BeschleunigerBallett's `scripts/windows/Resolve-BuildModule.ps1`).
