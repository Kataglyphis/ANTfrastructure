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

This repository applies a **patch-first** policy to upstream sources on the Windows lane. **Default: extract upstream modifications into a reviewable `.patch` file** under `windows/scripts/patches/<component>/NNN-<slug>.patch`, applied via the canonical idempotent helper `Invoke-SourcePatch` (`windows/scripts/modules/WindowsSourceBuild.Patches.psm1`, re-exported by `WindowsSourceBuild.Common.psm1`). Every `.patch` file:

- Is a standard `git diff` / unified diff (`a/`/`b/` prefix, `-p1` strip).
- Applies idempotently: `Invoke-SourcePatch` runs `git apply --reverse --check` first and skips if already applied; falls back to `patch.exe -p1` for non-git tarball extractions; throws loudly with the patch file's first 40 lines on failure.
- Targets a *pinned* upstream version (e.g. the file header references the git tag in `linux/scripts/01-core/versions.env`).

**Exceptions (inline patches are intentional and documented):**

1. **Generated build files** — patches targeting FFmpeg's generated `ffbuild/*.mak`, `library.mak`, `subdir.mak`, `Makefile`, `ffbuild/config.mak` (post-configure output; content varies per `./configure` invocation) AND the `Update-NinjaFile` calls in `Build-OnnxFromSource.ps1` / `Build-OnnxGenaiFromSource.ps1` that strip MSVC-only flags from CMake-generated `build.ninja` (same family — generated content varies per CMake configure). Inline `-replace` on invariant sub-sequences (`-showIncludes`, `EXTRALIBS-lib*=`, `/experimental:external`, `/Qspectre`) is the canonical form for both.

2. **Fetched third-party deps whose pinned version floats** — `Edit-CppKeywordAlternatives` walks CUTLASS headers fetched by ONNX Runtime's ExternalProject at configure time, AND the companion `_udiv128 → udiv128` substitution on `cutlass/uint128.h` (clang-cl lacks the MSVC-only intrinsic). The CUTLASS fetched SHA varies with the provider's `cutlass-src` ExternalProject pointer; a static `.patch` against a pinned tag would silently rot. The helper form + the targeted inline regex are canonical.

3. **Multi-file conditional substitutions** — LiteRT's `proto/CMakeLists.txt` disable loop (`Build-LitertFromSource.ps1`) walks ~17 files under `$tfliteSrc` and skips files whose content already lacks `protobuf_generate|protoc`. A static `.patch` against a pinned LiteRT tag cannot express the per-file predicate and would only cover a fraction of the proto directories. Similarly, the OpenCV mlas `<cstring>` prepend loop (`Build-OpencvFromSource.ps1`) walks every `3rdparty/mlas/**/*.cpp` and skips files that already include `<cstring>` — same canonical-form rationale.

4. **Installed toolchain headers (not the upstream source tree)** — `Build-OnnxGenaiFromSource.ps1` patches the installed MSVC STL `yvals_core.h` (wrapping the single `_EMIT_STL_ERROR` define in `#ifdef __clang__`, which no-ops *every* STL error code — STL1009/1010/1011, etc. — under clang-cl, so no per-header patch such as one for `<experimental/coroutine>` is needed). The MSVC toolset version floats (resolved via `Get-MsvcToolsRoot`), so a static `.patch` against a pinned MSVC build would only work for one toolset version; the edit is guarded by a drift-assertion that fails the build loudly if a future toolset changes the macro's format.

5. **Binary byte-filter edits** — `onnxruntime.rc` non-ASCII byte stripping (`-le 127`) is a byte filter, not a textual diff. Not expressible as unified diff.

6. **Single-file regex edits on aggressively-changing generated-as-schema upstream files** — none left (checked 2026-09-25). The one entry, an inline removal of OpenCV's `add_extra_compiler_option(-include cstring)` from `cmake/OpenCVCompilerOptions.cmake`, is gone: no build script edits that file. `Build-OpencvFromSource.ps1` passes `/FIcstring` in `CMAKE_CXX_FLAGS` on the configure line instead, and patch `002` does the same inside MLAS.

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

8. **OpenCV CMake hooks, not patches.** `windows/scripts/patches/opencv/cmake-hooks/`
   holds files OpenCV itself includes through `OPENCV_CMAKE_HOOKS_DIR`, one
   `<HOOK_NAME>.cmake` per hook. OpenCV registers every `*.cmake` there under its
   basename, so nothing else may live in that directory (a test enforces it). A hook
   only adds to a target (today `opencv_gapi`'s `/DELAYLOAD`s for the G-API DirectML
   EP) and edits no upstream text, so it needs no drift assert;
   `Get-OpencvOrtConfigureFinding` reads `build.ninja` to prove it took effect. See
   [`onnxruntime-single-source.md` § OpenCV on Windows](onnxruntime-single-source.md#opencv-on-windows-the-shim-the-hook-and-the-gate).

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
| OpenCV | `001-cmake-clang-cl-compat.patch` | `CMakeLists.txt` + `cmake/FindONNX.cmake` + `cmake/OpenCVDetectCUDA{Language,Utils}.cmake` | [details](#001-cmake-clang-cl-compatpatch) |
| OpenCV | `002-mlas-clangcl-force-include.patch` | `3rdparty/mlas/CMakeLists.txt` | [details](#002-mlas-clangcl-force-includepatch) |
| OpenCV | `003-mlas-windows-skip.patch` | `3rdparty/mlas/CMakeLists.txt` | [details](#003-mlas-windows-skippatch) — the reviewable form only: the build inserts the same guard inline, because `002` already edits that file |
| OpenCV | `004-dnn-ort-profiling-wchar.patch` | `modules/dnn/src/net_impl_backend.cpp` | [details](#004-dnn-ort-profiling-wcharpatch) |
| OpenCV | `cmake-hooks/POST_CREATE_MODULE_LIBRARY_opencv_gapi.cmake` (a hook, not a patch) | `opencv_gapi` link options | Delay-load dxcore/d3d12/dxgi/DirectML for the now-compiled G-API DirectML EP (§ Source Patch Policy, item 8) |
| OpenCV (contrib) | `001-cudev-windows-llp64.patch` | `cudev/.../common.hpp` + `cudev/.../util/vec_traits.hpp` | Add `ulong`/`longlong`/`ulonglong` typedefs for Windows LLP64 |
| OpenCV (contrib) | `002-arm64-cudafilters-popcount.patch` | `modules/cudafilters/src/cuda/wavelet_matrix_2d.cuh` | Software popcount under `_M_ARM64`: `_mm_popcnt_u64` is x86-only and nvcc's device front-end rejects `__builtin_popcountll` (#176, 2026-09-20) |
| LLVM | `001-aarch64-ehlabel-size.patch`, `002-aarch64-seh-pseudo-size.patch` | `llvm/lib/Target/AArch64/AArch64InstrInfo.cpp` | The AArch64 instruction-size fixes of the patched toolchain (llvm#219275, llvm#219276), applied by `Build-LlvmFromSource.ps1` |
| MIGraphX | `001-mlir-off-stubs.patch` | `src/targets/gpu/mlir.cpp` | Upstream 5a80dc91ba's MLIR-off stubs, which the `MIGRAPHX_WINDOWS_COMMIT` pin predates (rocm lane, [`windows-rocm.md`](windows-rocm.md)) |
| HailoRT | `001-quantization-msvc-guard.patch` | `hailort/libhailort/include/hailo/quantization.hpp` | The x86 rounding intrinsics only under MSVC on x86/x64, never under clang-cl or on ARM64 |
| HailoRT | `002-ioctl-nullptr-template-specialization.patch` | `hailort/libhailort/src/vdma/driver/os/windows/driver_os_specific.cpp` | The missing `template<>` on the two `nullptr_t` specialisations |
| HailoRT | `003-windows-lockedfile-dtor.patch` | `hailort/common/os/windows/filesystem.cpp` | Define `LockedFile::~LockedFile`, which the Windows stub declares and never defines (undefined symbol at link) |
| HailoRT | `004-cmake-target-arch-macro.patch` | `hailort/CMakeLists.txt` | `_ARM64_=1` on an ARM64 target instead of the pointer-size `_AMD64_=1` |

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

UPSTREAM BUG (5.0.0, run-13 find): dnn's ORT `EnableProfiling` passes `char*` but `ORTCHAR_T` is `wchar_t` on Windows — the model-path call right below is `#ifdef _WIN32`-widened, this one was not (upstream Windows CI never builds dnn with ORT). Filed as opencv#29788 and closed: `5.x` had already fixed it (PR #29309, after the 5.0.0 tag we pin), so the patch retires with the next `OPENCV_VERSION` ([`upstream-windows-patches.md`](upstream-windows-patches.md))

`ffmpeg/makedef` is **not** a patch — it is a whole-file replacement script staged over FFmpeg's `makedef` (a byte swap, not a diff), so it is not in the table above.

When bumping any upstream version, audit these `.patch` files before letting the orchestrator loose: run `windows/scripts/tests/Test-PatchesApplyClean.ps1`, which clones each pinned upstream and runs the exact `git apply --check` the build uses (see `windows/scripts/patches/README.md`). If a patch no longer applies, regenerate with `git diff` against the new tag and update the inventory above.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker distribution for Windows Containers) and is split into staged images:

- `windows/Dockerfile.base` builds the cached Windows toolchain base image (CMake, VS Build Tools 18, LLVM/Clang, Rust, Flutter, WiX 4; every version from `versions.env`).
- The **sdk slot**: on the GPU lane `windows/Dockerfile.nvidia` layers CUDA + cuDNN + TensorRT (`CUDA_VERSION`, `CUDNN_VERSION`, `TENSORRT_VERSION`) on top of the base image and is tagged `windows-sdk`; on `-Variant rocm` `windows/Dockerfile.rocm` takes the slot (§ ROCm layer). On the CPU lane the base image is re-exported as `windows-sdk` through a one-line `FROM` stage (containerd has no unprivileged `tag`; the former no-op `Dockerfile.sdk` shim was removed) and downstream stages perform CPU-only builds (CUDA auto-detection falls back to `CPU-only build`). `windows/Build-Buildkit.ps1` handles this through `-Gpu` / `-Variant`.
- The toolchain stage builds CPython 3.14 from source (matching the canonical versions.env) via `windows/Dockerfile.toolchain-builder` + `Build-ToolchainAll.ps1`, and by default the patched clang/LLVM on top (`patched-llvm` target, `BUILD_PATCHED_LLVM=1`; `-StockLlvm` opts out). The former standalone `Dockerfile.toolchain` was removed as dead code — it duplicated the builder without the nuget pre-seed fix.
- The **media stage fans out into three branch images** by `windows/Build-Buildkit.ps1`, built **sequentially** by default (media-core first — it alone gets the whole RAM budget, maximizing ONNX parallelism; `-ConcurrentAux` builds litert and tvm side by side after it). All three branches share ONE multi-stage builder, `windows/Dockerfile.media-builder`, selected per stage via `--target`; then the stage fans in:
  - **media-core** (one `media-core-built-*` target and tag per library, in this order; each runs `Build-MediaCoreAll.ps1` for its one library, except HailoRT, whose script is called directly) — ONNX Runtime (source build, pin `ONNXRUNTIME_VERSION`; CUDA EP enabled when the NVIDIA layer was used, DirectML EP always via the clang-cl patch, the WebGPU EP on the rocm spike) → FFmpeg (pinned release tag `FFMPEG_VERSION`; MSVC toolchain via MSYS2 bash; `--enable-libonnxruntime` links FFmpeg's DNN filters against the source-built ONNX Runtime — note there is no separate `--enable-dnn` flag; DNN filters come with the backend) → OpenCV 5.x (CMake+Ninja+clang-cl, CUDA auto-detected, built against the chain ONNX Runtime through a header shim, no configure-time download; after FFmpeg so its videoio links ours, #94) → HailoRT (`Build-HailortFromSource.ps1`, pin `HAILORT_VERSION`) → ONNX GenAI (CMake+clang-cl, bypassing `build.py`; built against the chain ONNX Runtime through an `ORT_HOME` shim, never the NuGet ORT its `cmake/ortlib.cmake` would download; `USE_DML=ON` + `USE_CUDA=ON`, telemetry off).
  - **media-litert** (`--target media-litert-built` + `Build-LitertAll.ps1`) — LiteRT (pin `LITERT_VERSION`; CMake+Ninja; also builds the TFLite C-API lib `tensorflowlite_c`) → LiteRT-LM (pin `LITERT_LM_VERSION`; independent of ONNX; built via **Bazel** with `Build-LitertLmBazel.ps1` → `litert_lm_main.exe`. The former CMake export-bridge path (`Build-LitertLmFromSource.ps1`) is a frozen fallback, see § Source Patch Policy #7).
  - **media-tvm** (`--target media-tvm-built` + `Build-MediaTvmAll.ps1`) — TVM → IREE (both LLVM-heavy ML compilers; each installs its Python wheels into the source-built CPython; IREE native tools land at `C:\runtime\iree`, `IREE_ROOT`/`IREE_BIN`).
  - **merge** (`Dockerfile.media-merge-builder`): `COPY --from` fan-in of the three branch trees into one `C:\runtime` + canonical env layout, plus a `cuda-runtime-stage` (via `Copy-CudaRuntime.ps1`) that FLATTENS the CUDA/cuDNN runtime DLLs into `C:\runtime\cuda-runtime\bin` on PATH — the CUDA-linked libs (notably OpenCV, which hard-links `cudnn64_9.dll`) otherwise fail to load in this non-nvidia-based image. Then GStreamer (pin `GSTREAMER_VERSION`) is built via `Build-GstreamerFromSource.ps1` (Meson + clang-cl; auto-detects CUDA, OpenCV, ONNX and FFmpeg from the merged tree).
- `windows/Dockerfile.torch` assembles the OrchestrANT app env on the media image (`media → torch → final`; tag `bk-windows-torch`), and `windows/Dockerfile` produces the final developer image FROM that torch image (VsDevCmd entrypoint). On `-Variant rocm` the `migraphx` and `llama` stages sit between media and torch ([`windows-rocm.md`](windows-rocm.md)).

## The Windows lane as AGENTS.md carried it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

**Fresh Windows machine?** Follow
[`docs/windows-host-setup.md`](windows-host-setup.md) rather than
reconstructing the sequence — after the interactive steps, the scriptable half
is one elevated `Install-NewHost.ps1` run.

All stages use **Ninja + clang-cl + lld-link**. The container toolchain is
**containerd + BuildKit + nerdctl**. Role split — each tool where its pipe ACL
allows:

| Task | Tool | Shell |
|---|---|---|
| Build the chain | `windows\Build-Buildkit.ps1` → `buildctl` | non-admin |
| Inspect / run the `bk-*` images | `nerdctl --namespace buildkit` | **admin** |
| Publish / inspect images | Stevedore's `docker.exe` | non-admin |

```pwsh
.\windows\Build-Buildkit.ps1 -Gpu          # build (non-admin)
```

**The lane mechanics live in
[`docs/windows-build-lanes.md`](windows-build-lanes.md)** — isolation
policy and the probe-log trap, the sccache and RDNA4 and step-log preflight
gates, the BuildKit/containerd lane, the nerdctl lane, the classic lane's
run+commit path (historical), mid-chain failure recovery, and the RDNA4 A/B
history.

Four things an agent gets wrong without reading it:

- **There is ONE Windows driver, `Build-Buildkit.ps1`.** The classic lane was
  retired 2026-08-26 and `build.ps1` DELETED 2026-08-31. Two independent
  structural defects, both verified; reviving it is a redesign, not a target-pin
  change. Reasoning and the cut list live in
  [`windows-build-lanes.md`](windows-build-lanes.md) — that page owns this
  topic; do not restate the reasons here.
- **`nerdctl` needs an ADMIN shell** — containerd's pipe is Administrator-only
  upstream, and there is no `--group` equivalent. Do not attempt pipe-ACL
  hacks and do not re-litigate it.
- **Every Stevedore/containerd update reverts the patched runhcs shim.**
  `windows/scripts/host/Publish-ShimPatch.ps1 -ReportOnly` belongs in your
  post-update routine. Since 2026-09-01 the deployed shim is the
  **`upstream-env` variant built from the owner's fork**
  (`Kataglyphis/hcsshim@feature/configurable-teardown-timeout`), and it is only
  patched-in-effect when the **containerd** service `Environment` carries
  `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m` — a **Go duration string**;
  a bare number silently means stock 30 s. So an update now reverts TWO things:
  the binary AND (via reinstall) possibly that env value — check both, restore
  both with `Publish-ShimPatch.ps1 -ShimPath <fork build> -ServiceEnvironment
  CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m`. Changing the env value needs
  a containerd restart (the shim inherits containerd's environment at spawn).
  **It can also wipe the buildkitd service `Environment`**
  (the `BUILDKIT_STEP_LOG_MAX_SIZE=-1` / `BUILDKIT_STEP_LOG_MAX_SPEED=-1` keys
  that prevent the 2 MiB step-log clip) — check with
  `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -Name Environment).Environment`
  after any update, and re-apply via `Install-NewHost.ps1` or the registry
  `Set-ItemProperty` if empty. The build driver refuses to start without them.
- **A Stevedore REINSTALL wipes more than the shim** — the buildkitd service
  `Environment`, the dufs task and its serve directory all go with it. See
  [`docs/windows-host-setup.md`](windows-host-setup.md) § Phase R.

See [`docs/windows-builds.md`](windows-builds.md) § Build Commands for the
full build sequence.

## The build notes AGENTS.md carried

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited then except for this heading and the relative links; the media-core order and the per-script pointer were corrected on 2026-09-25. The RULES stayed there; this is the reference behind them.

The Windows lane source-builds the media stack with Ninja + clang-cl + lld-link (exceptions: CPython via `PCbuild\build.bat` with the VS ClangCL toolset; FFmpeg via MSYS2 `make` with `--toolchain=msvc`; GStreamer via Meson; LiteRT-**LM** via Bazel/bazelisk, `Build-LitertLmBazel.ps1`): CPython in the toolchain stage; ONNX Runtime → **FFmpeg → OpenCV** → HailoRT → ONNX GenAI in media-core (FFmpeg before OpenCV is load-bearing, #94: OpenCV's video backend links what FFmpeg installed — the authority is the `media-core-built-*` stage chain in `Dockerfile.media-builder`, which `Build-Buildkit.ps1` solves in that order, not this sentence); LiteRT (Ninja) → LiteRT-LM (Bazel) in media-litert; TVM → IREE in media-tvm; GStreamer in the merge stage. **That is the amd64 chain.** On `-TargetArch arm64` all three media branches build since 2026-08-24 (TVM/IREE runtime-only; what a branch cannot build for the target is decided INSIDE the branch and shipped as an empty, marker-carrying tree — the driver-level `$crossBlockedBranches` refusal list was removed on 2026-08-25), and what each branch skips or names ABSENT inside the bundle (LiteRT-LM, the TVM/IREE compilers, the python packages that need the compilers) is owned by the status banner of `docs/windows-cross-builds.md` — do not restate it here, it moves. **Assemblers are the one place the "clang-cl everywhere" rule does not hold on amd64:** NASM-syntax kernels (FFmpeg since #119, libjpeg-turbo in OpenCV, openh264 in GStreamer) go through the pinned `nasm` — LLVM has no NASM-syntax assembler — and MASM-syntax sources split by what LLVM's `llvm-ml` can actually parse (#123, 2026-08-25/26): IREE's single trampoline `x86_64_msvc.asm` goes through `llvm-ml -m64` (`-m64` is load-bearing — llvm-ml assembles i386 by default and then rejects the `.seh_*` directives; proven on the cross lane's host tools), while **MLAS's x64 kernels stay on MSVC's `ml64.exe` by design** — measured on amd64 run 6: every MLAS `.asm` opens with `.xlist` (LLVM 22's MasmParser has no listing directives), `INCLUDE mlasi.inc` is not found (llvm-ml searches `-I` dirs only, ml64 also the includer's directory), and behind it sits the Windows SDK's MASM macro layer; the ORT configure log asserts ml64 so a drift stops at configure. On arm64 every assembly path is clang's integrated assembler. All version pins come from `linux/scripts/01-core/versions.env` — never restate versions here (the duplicated tables this section used to carry drifted, e.g. the GenAI/LiteRT-LM labels).

- **Per-library reference** (generator/compiler per component, EP/delegate flags, patch stacks, RAM budgets, fallback paths): the authoritative table is `docs/windows-builds.md` § Component Build Matrix.
- **Per-script reference** (build/setup/verify and HOST-maintenance scripts, with flags, gotchas and refusal conditions; the ones without an entry yet are listed there): the authoritative table is `docs/windows-builds.md` § Windows Script Reference.
- Build sequence and commands: `docs/windows-builds.md` § Build Commands; container validation: § Smoke Testing there.

Update those tables in `docs/windows-builds.md` — this section stays a pointer. The Windows Build Invariants above remain here because they are agent-behavioral rules, not reference data.

## Component Build Matrix

The **authoritative per-library build reference** for the Windows lane (AGENTS.md § Windows Build Notes points here — update THIS table, never a copy). Versions are pinned in `linux/scripts/01-core/versions.env`.

| Component | Generator | Compiler | Notes |
|---|---|---|---|
| CPython 3.14 | `PCbuild\build.bat` | ClangCL (v145→ClangCL via Directory.Build.props) | Requires VS ClangCL toolset |
| ONNX Runtime (pin: `ONNXRUNTIME_VERSION`) | Ninja | clang-cl, lld-link | [details](#onnx-runtime-pin-onnxruntime_version) |
| ONNX GenAI 0.15.2 | CMake (Ninja) | clang-cl, lld-link | [details](#onnx-genai-0152) |
| OpenCV 5.x | Ninja | clang-cl, lld-link | [details](#opencv-5x) |
| LiteRT (pin: `LITERT_VERSION`) | Ninja | clang-cl, lld-link | [details](#litert-pin-litert_version) |
| LiteRT-LM (pin: `LITERT_LM_VERSION`) | **Bazel** | clang-cl, lld-link | [details](#litert-lm-pin-litert_lm_version) |
| TVM (pin: `TVM_REF`) | Ninja | clang-cl, lld-link | [details](#tvm-pin-tvm_ref) |
| IREE (pin: `IREE_VERSION`) | Ninja | clang-cl, lld-link | Two configures on the arm64 cross lane (§ TVM and IREE in [`windows-cross-builds.md`](windows-cross-builds.md)) |
| HailoRT (pin: `HAILORT_VERSION`) | Ninja | clang-cl, lld-link | Four static patches (§ Source Patch Policy) |
| FFmpeg (pin: `FFMPEG_VERSION`) | MSYS2 `make` (MSVC toolchain) | clang-cl via `--toolchain=msvc` | [details](#ffmpeg-pin-ffmpeg_version) |
| GStreamer (pin: `GSTREAMER_VERSION`) | Meson | clang-cl | Downloaded as tarball + subproject wraps. CUDA auto-detected. |

### Per-component notes

The components whose notes do not fit a table cell. Each is linkable, so another page can point at exactly one of them.

#### ONNX Runtime (pin: `ONNXRUNTIME_VERSION`)

**both lanes** (on `-TargetArch arm64` TensorRT is OFF, CUDA is ON only when the image carries the arm64 CUDA payload (`-Gpu`, #176, 2026-09-20), the Python bindings are ON since #120 step 2, and DirectML is **ON** as of backlog #113 — see [`windows-cross-builds.md`](windows-cross-builds.md)): DirectML EP **enabled** (`USE_DML=ON`) via the 3-part clang-cl source patch `003-dml-clangcl-compat.patch` (§ Source Patch Policy; the EOL/context-tolerant inline regex patcher `Invoke-OnnxDmlClangClPatch` in `Build-OnnxFromSource.ps1` remains as the drift fallback): DirectMLHelpers incomplete-type out-lining, `.##Z` token-paste, `Dispatch<size_t>`. CUDA + TensorRT EPs enabled when the NVIDIA layer is the parent (CUDA provider at `CUDA_VERSION`, includes crt/ workaround for nvcc). Patches build.ninja for MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM (`.asm` files). **AVX-512/AMX: per-TU only** — global flags OFF (they crashed protoc AND ort's own DLL init at runtime on AVX2 hosts); the build script appends them (`Get-WindowsTargetKernelSimdFlags -Arch` — the old `Get-WindowsX86Avx512Flags` compat shim was deleted 2026-08-26; the amd64 TU pattern was extended 2026-08-24 after under-matching broke the lane, tagged-count floor raised 4→8) to MLAS's runtime-dispatched arch TUs in build.ninja post-configure and logs the tagged count (see AGENTS.md § Windows Build Invariants — don't "simplify" in either direction). 1.28's `ScopedResource<INVALID_HANDLE_VALUE,...>` template arg (rejected by clang-cl) is bridged by an inline post-configure dep patch. Needs ~4 GB RAM/job — media-core runs with `--memory ${MediaMemoryGb}g`.

#### ONNX GenAI 0.15.2

Source-built directly via CMake (bypasses `build.py` which always builds examples). DirectML **enabled** (`USE_DML=ON`, on **both lanes** since #118, 2026-08-24) — compiled straight into `onnxruntime-genai.dll` with 0 source patches (`src/dml` is clang-clean; the `D3D12Core.dll` staged beside the DLL is resolved through a **target-derived** filter — x64 on amd64, arm64 on the cross lane — not the hardcoded x64 an earlier revision of this row implied). CUDA **enabled** (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll`; CUDA and DML are independent CMake blocks so they coexist. `-DENABLE_TELEMETRY=OFF` (0.15 defaults MS 1DS telemetry ON; its bundled zlib also breaks clang-cl under -Werror). VsDevCmd environment loaded for MSVC STL headers.

**ONNX Runtime: the chain's, never NuGet's (owner rule 2026-09-23).** Upstream `cmake/ortlib.cmake` has two branches. With no `ORT_HOME` it FetchContents `Microsoft.ML.OnnxRuntime.DirectML` 1.24.4 from the aiinfra ORT-Nightly feed, with no hash, and compiles GenAI and onnxruntime-extensions against it; the image built that way until 2026-09-23. With `ORT_HOME` it takes the headers and library from there. `ortlib.cmake` wants `ORT_HOME\include\onnxruntime_c_api.h` and `ORT_HOME\lib\onnxruntime.dll`, while the chain installs its headers flat under `include\onnxruntime\` and its DLL under `bin\`. So `New-GenaiOrtHome` copies them into `<src>\ort-home\{include,lib}`, and configure gets `-DORT_HOME:PATH=<shim>` (typed, because `ortlib.cmake` reads the variable without declaring it) plus `-DFETCHCONTENT_SOURCE_DIR_ORTLIB` and `-DFETCHCONTENT_SOURCE_DIR_ONNXRUNTIME` pointing at an empty `ort-fetch-blocked` dir. If GenAI or onnxruntime-extensions (a GitHub 1.19.2 zip) ever falls back to a download, configure fails instead; CMake's "Manually-specified variables were not used" for the two is expected. The configure log is teed to `onnx-genai-configure.log` rather than discarded. `Get-GenaiOrtConfigureFinding` then requires the shim in the log and in `CMakeCache.txt`, `-I<shim>/include` on every GenAI compile and `-LIBPATH:<shim>/lib` on every `onnxruntime.lib` link in `build.ninja`. `Get-GenaiOrtTreeFinding` runs after configure and after the build: chain bytes under every chain ORT file name, no ORT archive or FetchContent ORT dir, and no ORT file in the install dir; its post-build findings throw through the ORT build gate. The DLL now needs an ONNX Runtime at least as new as the chain at run time, and `ORT_GENAI_HAS_MODEL_PACKAGE` code is compiled on Windows for the first time. Suite: `SourceBuild.GenaiOrt.Tests.ps1`.

**Still fetched, and not ORT:** `DirectML.h` and `D3D12Core.dll` come from GenAI's own `Microsoft.AI.DirectML` 1.15.2 and `Microsoft.Direct3D.D3D12` 1.614.1 NuGet fetches from nuget.org, without a hash. The `RESTORE_PACKAGES` dependency-drop patch matches nothing at v0.15.2 (upstream writes `add_dependencies(${ORTGENAI_COMPILE_TARGET} RESTORE_PACKAGES)`), so the build still downloads `nuget.exe` and restores `Microsoft.Direct3D.DXC` from the ORT-Nightly feed. Both are open follow-ups.

#### OpenCV 5.x

Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2 (amd64 only; global SIMD flags are empty on arm64 by design). CUDA auto-detected. Custom `CMAKE_AR` path fix. ONNX Runtime: the chain's on every lane, through a nested-header shim with `HAVE_ONNXRUNTIME` pre-set, so there is no configure-time download, and G-API's ONNX DirectML EP is compiled in. `Get-OpencvOrtConfigureFinding` gates both after configure; see [`onnxruntime-single-source.md` § OpenCV on Windows](onnxruntime-single-source.md#opencv-on-windows-the-shim-the-hook-and-the-gate).

#### LiteRT (pin: `LITERT_VERSION`)

GPU delegate enabled (Vulkan + OpenCL backends). XNNPACK enabled. CUDA paths exposed for external delegate. Also builds the TFLite **C-API** shared lib `tensorflowlite_c` (target injected into the main build, `WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) that gst-plugins-bad's tflite plugin links.

#### LiteRT-LM (pin: `LITERT_LM_VERSION`)

On-device LLM inference, built via `Build-LitertLmBazel.ps1` (bazelisk + Temurin JDK, `bazelisk build //runtime/engine:litert_lm_main --config=windows`) → `litert_lm_main.exe`, through the smoke-RUN gate. Bazel is the only path Google CI-tests, so it survives version bumps. The old CMake export-bridge path (`Build-LitertLmFromSource.ps1`, 5 condition-gated self-retiring patches for v0.14's never-functional OSS CMake export — see § Source Patch Policy #7) is a **frozen fallback**.

#### TVM (pin: `TVM_REF`)

Auto-detects CUDA/Vulkan. **LLVM:** on amd64 TVM links the llvm-config first on PATH, which is the toolchain's patched LLVM (`C:\llvm-patched`, `AArch64;X86`), so TVM's LLVM `nvptx` target is absent on the nvidia lane too; the CUDA source codegen does not need it. The #47 heal builds a minimal LLVM from the pinned llvm-project source (DIA off, RTTI on, no xml2/zlib/zstd, `USE_LLVM=<path>/llvm-config.exe`, SHA from `Get-LlvmSourceSha256` / `LLVM_WINDOWS_SRC_SHA256`). It runs in two cases only: when PATH has no llvm-config (`-StockLlvm`: `X86;AArch64;NVPTX`, ~6 min sccache-warm), and on the rocm lane's `TVM_ROCM=1` spike, whose PATH LLVM lacks AMDGPU (`X86;AArch64;NVPTX;AMDGPU`; built on the 2026-09-25 rocm run, inside a 2:55:07 media-tvm stage, its own share unmeasured; see [`windows-rocm.md` § IREE and TVM](windows-rocm.md#iree-and-tvm-on-the-rocm-lane)). The arm64 cross lane builds runtime-only with no LLVM (#116). Builds a Python wheel. VsDevCmd environment loaded for MSVC STL headers.

#### FFmpeg (pin: `FFMPEG_VERSION`)

Source build from the pinned release tag (`FFMPEG_VERSION` in `versions.env`; a release TAG since 2026-08-04 — previously tracked `master`). `--enable-libonnxruntime` links FFmpeg's DNN filter against the source-built ONNX Runtime so ONNX models can run inside `ffmpeg` filters (DNN filters ship with the backend; no separate `--enable-dnn` flag). **x86asm ENABLED on amd64 since 2026-08-24** (#119: nasm-assembled x86 SIMD via `--x86asmexe`; the old unconditional `--disable-x86asm` had no recorded reason — proven the same evening: configure names nasm as the x86 assembler, 154 `X86ASM` objects linked under lld-link). The arm64 cross lane keeps `--disable-x86asm` explicitly (an x86-only knob) and assembles its NEON kernels through clang's integrated assembler. A failed source build **fails the stage** (fail-closed since #68). Only `FFMPEG_ALLOW_PREBUILT=1` opts into a BtbN pre-built GPL binary, never on the cross lane; it scrubs the prefix first and sets the sentinel `FFMPEG_SOURCE_BUILD=0`.

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

**Tool roles on this host.** Stevedore's bundled `docker.exe` publishes,
inspects and runs images (it was also the classic lane's build tool until that
lane was retired on 2026-08-26): Docker Engine provides NAT networking
natively, no CNI plugin needed. Since 2026-08-03 the CNI `nat`
**conf** (`C:\Program Files\containerd\cni\conf\0-containerd-nat.conf`; the
`nat.exe` binary always shipped in `...\cni\bin`) is installed on this host —
see [`windows-build-lanes.md`](windows-build-lanes.md) § Getting it going, step 2, including the subnet-drift trap — so
containerd-side networking works too, and `nerdctl` runs the `bk-*` images
fine. `nerdctl` needs an **admin** shell (containerd's pipe is admin-only
upstream); the pre-conf state where `nerdctl run` failed with `needs CNI
plugin "nat"` and `nerdctl build` had broken DNS is historical.

| Tool | Build | Run |
|------|-------|-----|
| `"D:\Stevedore\bin\docker.exe"` (non-admin) | — (the classic lane, retired 2026-08-26) | ✅ Works (NAT + DNS + process isolation) |
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
# `uv sync` must execute the target interpreter. -Gpu adds the arm64 CUDA/cuDNN
# payload since #176; -Variant rocm is refused):
.\windows\Build-Buildkit.ps1 -TargetArch arm64

# GPU lane: base -> nvidia (CUDA + cuDNN + TensorRT, tagged sdk) -> toolchain -> media -> torch -> final
# TensorRT is optional: a zip in windows/downloads/ adds it (see § TensorRT setup (GPU lane, optional) below).
.\windows\Build-Buildkit.ps1 -Gpu            # same as -Variant nvidia

# ROCm variant (amd64 only): base -> rocm (tagged sdk) -> toolchain -> media -> migraphx
# -> llama -> torch -> final, every tag after base with a -rocm infix; see § ROCm layer below.
.\windows\Build-Buildkit.ps1 -Variant rocm
# ...without the three spikes (MIGraphX stage, TVM ROCm, ORT WebGPU EP):
.\windows\Build-Buildkit.ps1 -Variant rocm -NoRocmSpikes
# ...only the app tail, reusing the rocm lane's llama image:
.\windows\Build-Buildkit.ps1 -Variant rocm -Stages torch,final

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
(torch -> `bk-windows-torch`, final -> `bk-winamd64` / `bk-winarm64`; the rocm lane adds a
`-rocm` infix to every tag after base, e.g. `bk-windows-toolchain-rocm`), invisible to
`docker` — use `-FinalTar` for a docker-loadable tarball. There is **no**
`-TorchBaseImage` equivalent: the torch stage's `BASE_IMAGE` is pinned to the local
`windows-media` tag (the rocm lane's `llama` image on `-Variant rocm`), so `-Stages torch,final` needs the local chain images and cannot
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

**The smoke's TensorRT assertions follow the staged state (2026-09-20).** With a
tree staged they require the EP (`cuda=1 trt=1`, the provider DLL, the python
EP); zip-less they assert its ABSENCE (`cuda=1 trt=0`, no provider DLL, python
CUDA-EP only), keyed on `Test-TensorRtTreeStaged` -- the same presence rule
`Resolve-TensorRtRoot` applies at build time. So the zip-less lane reports zero
skips and a STAGED tree with a silently-disabled EP still reds. Until this fix
the asserts were unconditional and turned the documented normal zip-less state
into three false reds on the 2026-09-20 `-Gpu` run.

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

### ROCm layer (`Dockerfile.rocm`)

`-Variant rocm` (amd64 only) installs AMD's TheRock ROCm for Windows tarball in the **sdk
slot**, like `Dockerfile.nvidia` on the GPU lane (since 2026-09-23). Toolchain and media
build on top of it and turn on ROCm and AMD-GPU features behind
`(Get-GpuEnvironment).HasRocm`; the cpu and nvidia lanes keep their flags and outputs.
Every rocm tag after `bk-windows-base` carries a `-rocm` infix, so a rocm run never
overwrites a default image.

The lineage, tags, stages (`migraphx`, `llama`), `-NoRocmSpikes`, the CMake isolation of
the ROCm tree, the smoke checks and what each media component enables are on their own
page: [windows-rocm.md](windows-rocm.md).

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
| `LLVM_WINDOWS_VERSION` | scoop `main/llvm` in the base; since #135 (2026-08-29) the toolchain stage also builds the patched clang/LLVM from the same pinned source into `C:\llvm-patched`, ahead on PATH | clang-cl + lld-link compile the entire media chain, and five patches under `windows/scripts/patches/` are written against a specific clang-cl's diagnostics |
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
nsis, uv, nuget, zlib, openssl, pkg-config, make, gawk) floats on
purpose — the build only *invokes* those. Move a package into the pinned block
the moment it starts linking into a shipped binary. sccache is the exception
in a different direction: it is pinned (for a cache FEATURE, not output) and
installed by `Install-RustToolchain.ps1` from the official released 0.18.0 zip
into `CARGO_BIN` — the source build is retired
([`windows-build-resources.md`](windows-build-resources.md) § Persistent compile cache (sccache)).
Note `LLVM_RELEASE` is a SEPARATE pin for the Linux lane; the two lanes move
independently.

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
host-toolchain and static sections (1-6, 14-16, 19 arch-filtered, 23 and 25; 7 too on the cross GPU lane) execute against the arm64 image with
their own floor column (`MIN_PASSED=76`/`MAX_SKIPPED=20`; measured green at 97/0/15 before sections 19 and 25 grew, so re-measure), sections
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
  (driver: `-SmokeMinPassed` / `-SmokeMaxSkipped`, defaults 170 / 3; the GPU
  lane raises the effective floor to 190 unless overridden) make
  "nothing ran" a distinct failure, **exit 3 = INSUFFICIENT COVERAGE**.
  These defaults describe the **amd64** lane and must not be re-tuned to
  accommodate arm64: that lane has its OWN floor column and driver defaults
  (76/20 — see the smoke-gate paragraph above; this sentence claimed "does not
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

The smoke test validates 25 categories including the CUDA Toolkit, ONNX Runtime with CUDA, ONNX GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with CUDA, TVM (source-built), IREE (source-built; native MLIR→vmfb compile + local-task execution, a CUDA-target compile-only assert on the GPU lane, and a python `iree.compiler`→`iree.runtime` end-to-end), FFmpeg (source-built with DNN/ONNX integration), compiler integration, environment-pointer integrity, and Python bindings. **Current baseline (2026-09-22, `bk-20260922-034440`, the GPU lane with Hailo, zip-less): 236 passed / 0 failed / 0 skipped** — the TensorRT asserts are conditional on the staged state (§ TensorRT setup) and Hailo section 24 adds six host-runnable assertions plus the two `HAILO_*` pointers, so the zip-less GPU run is a full pass; the CPU-lane figure remains 222/0/0 (2026-08-26, `bk-20260826-130136`, via the automatic gate), matching the arm64 parity table. It supersedes 184/0/1 (2026-08-14; the one skip was GPU device passthrough) and the long-stale 2026-07-14 figure of 167/0/1, which predated the mandatory-plugin assertions, the `SCOOP_GLOBAL_SHIMS` checks, the bulk DLL-load enumeration (#57 — it alone load-tests 65 OpenCV DLLs where one was tested before) and the LiteRT export asserts (#67). Record the new figure here from each green run; a HIGHER count is growth, not a regression. Growth over the 153 baseline: the PyAV asserts (staged `av-*.whl` + an in-memory mpeg4 encode through the container-built FFmpeg) and the IREE suite (section 22 native compile+run incl. a CUDA-target compile-only assert, wheel-pin + `--version` asserts, section 20 staged-wheel + python end-to-end asserts, section 19 `IREE_ROOT`/`IREE_BIN` pointers). Section 23 (#167) is the baked `C:\temp\scripts` surface, which this hand-run invocation does not exercise. On 2026-09-23 three sections grew for the ONNX Runtime single-source rule: section 19 gained the ort-crate-env assertion (floors Gpu 31 / Cpu 27 / Arm64 25), section 21 the venv's DirectML and chain-wheel checks (floor 4 on amd64), and the new section 25 is the ORT census (floor 5 on the amd64 columns, the four census assertions plus `ORT in-box`, and 4 on arm64, where the in-box assertion is a skip; plus the STAMP assertion now that the build gate exists; [`onnxruntime-single-source.md`](onnxruntime-single-source.md)). The next green run's figures are not measured yet.

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
like `mpeg4`/`libx264` by name). Consumer CI venvs synced inside the image are
reconciled onto the ORT/GenAI wheels in this store (`Sync-UvChainOnnxRuntime`,
[`python-ci.md` § Trap 3](python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi)).
`FFMPEG_VERSION` is pinned to a release tag since 2026-08-04
(`n9.0` then; it previously tracked `master`, which is when an
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
`assemble-torch-app.sh` stage) in the torch stage (`windows/Dockerfile.torch`),
which the final image builds FROM:

- **Ref**: `Build-Buildkit.ps1` uses versions.env's **`APP_REF` pin by default** (the
  same commit always builds the same final image); pass `-LatestApp` to opt
  into resolving the app repo's newest release tag at build time via a live
  `git ls-remote` (the old always-on behavior). The resolved ref reaches the
  Dockerfile as the `APP_REF` build-arg, so moving the app busts exactly the
  torch-step layer.
- **Environment**: `uv sync` on the source-built CPython (extras `ml-ai`,
  `docs`, `pytorch-cpu` — `pytorch-cu130` on the nvidia lane — and `test`; the
  wxPython GUI extra excluded, like linux),
  with `--no-install-package` for every `onnxruntime*` name in `uv.lock` (a
  locked name whose family has no chain wheel stops the stage),
  then a reconcile so this lane's wheels always win. The ORT census
  (`ort-venv-census.py --purge-list`, run in the venv) names every installed
  ONNX Runtime distribution: any `onnxruntime` or `onnxruntime-*` name and any
  owner of the `onnxruntime`, `onnxruntime_genai` or `onnxruntime_extensions`
  package; there is no fixed list. Those and the opencv-python variants are
  uninstalled, `C:\runtime\wheels` is force-installed `--no-deps`
  (genai-cuda's metadata names `onnxruntime-gpu`, which our combined wheel
  replaces), and `cv2` + `tvm_ffi` + the sitecustomize shim are staged from
  base site-packages into the venv. The install ends with the census `--check`:
  every ORT distribution byte-identical to a wheel in `C:\runtime\wheels` and
  `onnxruntime` owned once, or the stage fails
  ([failure-modes](failure-modes.md#the-torch-stage-fails-with-ort-census-fail)).
- **Known limitation**: `ai-edge-litert` is excluded from `uv sync`
  (`--no-install-package`) on every lane. The old reason, "its pinned version
  ships no cp314 wheel", is stale: the app lock at v0.0.28 locks 2.1.6, which
  has one. It stays excluded so the cpu/nvidia app layer does not change. The
  rocm lane adds `ai-edge-litert` 2.2.0, hash-pinned and `--no-deps`, in the
  torch stage's `rocm-1` ([`windows-rocm.md` § PyTorch on the rocm lane](windows-rocm.md#pytorch-on-the-rocm-lane-torch-stage)).
- **Gates**: the docker build itself fails unless the venv passes the import
  battery (numpy/cv2/torch/onnxruntime with a CUDA-EP build assert/genai/tvm)
  **and the app's own wheel-smoke suite** (`python -m orchestrant.smoke`
  — real torch/torchvision/ORT-inference/OpenCV work). The check inventory is
  the app's per-tag choice, so the expected pass count moves with `APP_REF`;
  the rule on this lane is: **all checks pass except a single WARN for the
  litert skip** on cpu/nvidia (the `ai-edge-litert` limitation above; the rocm
  verify finds it installed), plus any checks the pinned app tag does not yet
  ship (e.g. an iree check counts only once a tag includes it). `-Mode verify`
  runs the ORT census first, so the rocm-1 stage and smoke section 21 enforce it
  too. Smoke section 21 re-runs the same verification offline on every suite
  run; its app-verify assertion also requires the `ORT-CENSUS PASS` line and
  reports the census's FAIL lines as its message. It adds two GPU-less checks on
  every amd64 lane: the venv's onnxruntime lists `DmlExecutionProvider` and its
  GenAI reports `is_dml_available()` (the verify above asserts only the CUDA
  EP), and the venv's onnxruntime is the chain wheel, the sole owner of the
  package with every `.pyd`/`.dll` byte-identical to
  `C:\runtime\wheels\onnxruntime-*.whl`. Section 21's floor is 4 on amd64.
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

- **Chain components — `windows/scripts/build/`**: [`Build-OnnxFromSource.ps1`](#build-onnxfromsourceps1) · [`Build-OnnxGenaiFromSource.ps1`](#build-onnxgenaifromsourceps1) · [`Build-OpencvFromSource.ps1`](#build-opencvfromsourceps1) · [`Build-OpencvGstreamerPlugin.ps1`](#build-opencvgstreamerpluginps1) · [`Build-LitertFromSource.ps1`](#build-litertfromsourceps1) · [`Build-LitertLmBazel.ps1`](#build-litertlmbazelps1) · [`Build-LitertLmFromSource.ps1`](#build-litertlmfromsourceps1) · [`Copy-CudaRuntime.ps1`](#copy-cudaruntimeps1) · [`Build-TvmFromSource.ps1`](#build-tvmfromsourceps1) · [`Build-FfmpegFromSource.ps1`](#build-ffmpegfromsourceps1) · [`Build-GstreamerFromSource.ps1`](#build-gstreamerfromsourceps1) · [`Import-Versions.ps1`](#import-versionsps1) · [`Complete-Container.ps1`](#complete-containerps1) · [`Test-Toolchain.ps1`](#test-toolchainps1) · [`Test-Health.ps1`](#test-healthps1) · [`Test-Container.ps1`](#test-containerps1) · [`Set-TensorrtTree.ps1`](#set-tensorrttreeps1)
- **Host setup and maintenance — `windows/scripts/host/`**: [`Install-Vs.ps1`](#install-vsps1) · [`Install-ScoopTools.ps1`](#install-scooptoolsps1) · [`Install-Vcpkg.ps1`](#install-vcpkgps1) · [`Install-RustToolchain.ps1`](#install-rusttoolchainps1) · [`Install-Cuda.ps1`](#install-cudaps1) · [`Install-Tensorrt.ps1`](#install-tensorrtps1) · [`Publish-ShimPatch.ps1`](#publish-shimpatchps1) · [`Install-NewHost.ps1`](#install-newhostps1) · [`Set-Rdna4Gpu.ps1`](#set-rdna4gpups1) · [`Get-HostDockerState.ps1`](#get-hostdockerstateps1) · [`Reset-ContainerStores.ps1`](#reset-containerstoresps1) · [`Sync-DefenderExclusions.ps1`](#sync-defenderexclusionsps1) · [`Repair-WindowsComponentstore.ps1`](#repair-windowscomponentstoreps1) · [`Test-HostSetup.ps1`](#test-hostsetupps1) · [`Set-ContainerdConfig.ps1`](#set-containerdconfigps1) · [`Optimize-HostVhdx.ps1`](#optimize-hostvhdxps1) · [`Initialize-Pwsh.ps1`](#initialize-pwshps1) · [`Update-HostVhdx.ps1`](#update-hostvhdxps1) · [`Clear-DiskSpace.ps1`](#clear-diskspaceps1)
- **Diagnostics and probes — `windows/scripts/diagnostics/`**: [`Measure-BuildWarnings.ps1`](#measure-buildwarningsps1) · [`Test-BuildCopy.ps1`](#test-buildcopyps1) · [`Test-Rdna4LayerLock.ps1`](#test-rdna4layerlockps1) · [`Test-CudaCache.ps1`](#test-cudacacheps1) · [`Invoke-SccacheCudaLlmDeadlock.ps1`](#invoke-sccachecudallmdeadlockps1) · [`Test-GeniexNpuDriver.ps1`](#test-geniexnpudriverps1)
- **Reusable modules — `windows/scripts/modules/`**: [`WindowsSourceBuild.Common.psm1`](#windowssourcebuildcommonpsm1) · [`WindowsSmokeTest.Common.psm1`](#windowssmoketestcommonpsm1) · [`WindowsGstPlugins.Common.psm1`](#windowsgstpluginscommonpsm1)
- **Drivers and entry points**: [`Dockerfile.smoke-gate`](#dockerfilesmoke-gate) · [`Dockerfile.publish-gate`](#dockerfilepublish-gate) · [`patches/litert-lm/patch-assert.cmake`](#patcheslitert-lmpatch-assertcmake) · [`Test-SccacheWrite.ps1` + `Invoke-SccacheWriteProbe.ps1` + `Dockerfile.sccache-write-probe`](#test-sccachewriteps1--invoke-sccachewriteprobeps1--dockerfilesccache-write-probe) · [`Test-OpencvVideoBackends.ps1` + `Invoke-OpencvVideoProbe.ps1` + `Dockerfile.opencv-video-probe`](#test-opencvvideobackendsps1--invoke-opencvvideoprobeps1--dockerfileopencv-video-probe)
- **No entry here yet** (counted 2026-09-25; the script's header comment is its reference until one is written): `build/` — `Build-HailortFromSource.ps1`, `Build-IreeFromSource.ps1`, `Build-LitertAll.ps1`, `Build-LlvmFromSource.ps1`, `Build-MediaCoreAll.ps1`, `Build-MediaTvmAll.ps1`, `Build-MigraphxFromSource.ps1`, `Build-OrtAmdgpuEpFromSource.ps1`, `Build-ResourceSampler.ps1`, `Build-TargetCpython.ps1`, `Build-ToolchainAll.ps1`, `Build-TorchApp.ps1`, `Copy-TargetPythonDeps.ps1`, `Debug-LitertlmLink.ps1`, `Export-LitertLmBridge.ps1`, `Install-LlamaCpp.ps1`, `Install-TorchRocm.ps1`, `Test-RocmImage.ps1`, `Test-TargetArch.ps1`, `Write-BundleManifest.ps1`; `host/` — `Clear-SccacheMount.ps1`, `Disable-Sleep.ps1`, `Install-DufsService.ps1`, `Install-Rocm.ps1`, `Install-VulkanLoader.ps1`, `Invoke-BkMaterialize.ps1`, `Invoke-BkWarm.ps1`, `Reset-ContainerLocks.ps1`, `Set-BuildkitdGcpolicy.ps1`, `Set-ElevatedWindow.ps1`, `Start-GeniexServers.ps1`; `diagnostics/` — `Find-LsmEventHolder.ps1`, `Get-HostLsm.ps1`, `Get-LsmWaitObject.ps1`, `Get-LsmWaitstack.ps1`, `Get-SiloProcesses.ps1`, `Invoke-DiagnosticProbe.ps1`, `Invoke-LlvmAarch64Layout.ps1`, `Measure-WarningStream.ps1`, `Test-Arm64Prereqs.ps1`, `Test-GpuPassthrough.ps1`, `Test-HipMsvcCmath.ps1`, `Test-LayerRename.ps1`, `Test-OnnxTuReplay.ps1`, `Test-OpencvCudaCmdshape.ps1`, `Test-ProcessIsolationCommit.ps1`. Several are described on the page that owns their topic ([`windows-cross-builds.md`](windows-cross-builds.md), [`windows-rocm.md`](windows-rocm.md), [`windows-build-lanes.md`](windows-build-lanes.md)).


### Chain components — `windows/scripts/build/`

Run inside the build container as chain stages. Each is invoked by a `*-all` wrapper or directly by the driver.

#### `Build-OnnxFromSource.ps1`

Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper. On the rocm spike it also builds the in-tree WebGPU EP ([`windows-rocm.md` § ONNX Runtime WebGPU EP](windows-rocm.md#onnx-runtime-webgpu-ep-rocm-lane-spike)).

#### `Build-OnnxGenaiFromSource.ps1`

Source-built directly via CMake+clang-cl (bypasses `build.py` which always builds examples). Loads VsDevCmd via `vswhere`, clones git tag, runs `cmake`/`ninja` directly. CUDA enabled (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll` alongside the DML-enabled `onnxruntime-genai.dll`. Builds against the chain ORT through the `ORT_HOME` shim, and the configure, tree and ORT build gates fail the stage on any ORT not from the chain (§ ONNX GenAI above).

#### `Build-OpencvFromSource.ps1`

Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch. Builds dnn and G-API against the chain ORT through a header shim, and ends in the ORT build gate (§ OpenCV 5.x above).

#### `Build-OpencvGstreamerPlugin.ps1`

**Standalone GStreamer videoio plugin (backlog #93)** — breaks the circularity without a second OpenCV pass: OpenCV configures in media-core BEFORE GStreamer exists, so its videoio ships with `GStreamer: NO` compiled in and `cv::VideoCapture(..., CAP_GSTREAMER)` has no backend; GStreamer builds in the MERGE stage and needs OpenCV for its own gst-plugins-bad opencv elements (the other direction, which works). OpenCV 5.0.0 ships `modules/videoio/misc/plugin_gstreamer`, a self-contained CMake project that builds `opencv_videoio_gstreamer` as a RUNTIME-LOADED DLL against an INSTALLED OpenCV, out of tree, from one source file (`cap_gstreamer.cpp`); videoio's plugin loader (`VIDEOIO_ENABLE_PLUGINS` ON by default) picks it up from the directory of `opencv_videoio*.dll`. **CONSEQUENCE FOR VERIFICATION, do not "fix" this back:** with the plugin route `cv2.getBuildInformation()` KEEPS saying `GStreamer: NO` — that string reflects videoio's COMPILE-TIME configuration and this plugin is loaded at runtime; the authoritative runtime check is `cv2.videoio_registry.hasBackend(cv2.CAP_GSTREAMER)` (it attempts the plugin load), and the #95 smoke assertions were updated accordingly. GStreamer detection on WIN32 uses find_path/find_library against `GSTREAMER_DIR` — OpenCV's `detect_gstreamer.cmake` does NOT use pkg-config on Windows, so the merge prefix (`C:\runtime`: `include\gstreamer-1.0`, `include\glib-2.0`, `lib\*.lib`) is handed over directly; no pkgconfig shim needed here, unlike the #94 FFmpeg route

#### `Build-LitertFromSource.ps1`

Ninja+clang-cl; GPU delegate (Vulkan+OpenCL), XNNPACK, external CUDA delegate. Injects + builds the TFLite C-API `tensorflowlite_c` shared lib (`WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) for gst's tflite plugin

#### `Build-LitertLmBazel.ps1`

**PRIMARY LiteRT-LM builder.** Self-installs bazelisk + Temurin JDK; `bazelisk build //runtime/engine:litert_lm_main --config=windows` → `litert_lm_main.exe` through the smoke gate. Neutralizes the base image's Android env/WORKSPACE pollution; patches the WORKSPACE zlib URL to the GitHub release mirror (zlib.net is flaky). `output_base` stays container-local (wcifs rename hazard)

#### `Build-LitertLmFromSource.ps1`

**FROZEN FALLBACK** (superseded by the Bazel builder above). Ninja+clang-cl; carries the v0.14.0 export-bridge patch stack (`[LiteRTLM-winfix export-stubs]` / `[LiteRTLM-winfix support-graft]` / v0.14 orphans + deps blocks) — all gated on the breakage so they self-retire when upstream's CMake catches up

#### `Copy-CudaRuntime.ps1`

Runs in the merge's `cuda-runtime-stage` (derived from the toolchain image since #134, 2026-08-26, so it re-runs only when the toolchain does). Recursively FLATTENS the CUDA_ROOT/CUDNN_ROOT DLLs into one dir COPY'd to `C:\runtime\cuda-runtime\bin` on PATH (cuDNN 9 buries DLLs in a CUDA-major subdir; `bin\arm64` on the cross GPU lane, #176); hard-gates on `cudnn64_9.dll`; stages an empty dir and exits 0 when neither root is set (the CPU lanes). Fixes opencv's plugin load in the non-nvidia merge image

#### `Build-TvmFromSource.ps1`

Ninja+clang-cl; auto-detects CUDA/Vulkan/LLVM; builds Python wheel; VsDevCmd for MSVC STL headers

#### `Build-FfmpegFromSource.ps1`

MSYS2 `make` with `--toolchain=msvc`; `--enable-libonnxruntime` links against the source-built ONNX Runtime. Loads `versions.env` via `Import-Versions.ps1` for the centralized `FFMPEG_VERSION` tag pin. A failed source build fails the stage (fail-closed since #68); `FFMPEG_ALLOW_PREBUILT=1` opts into the BtbN pre-built GPL binary on amd64 only (`FFMPEG_SOURCE_BUILD=0` sentinel).

#### `Build-GstreamerFromSource.ps1`

Meson+clang-cl with wrap pre-extraction; loads `versions.env` via `Import-Versions.ps1`

#### `Import-Versions.ps1`

Reads `C:\temp\versions.env` (COPY'd from `linux/scripts/01-core/versions.env`) and sets matching process env vars so Windows build scripts consume the same canonical versions as Linux

#### `Complete-Container.ps1`

Enables git long paths and sets `core.longpaths` in the final image; writes the **toolchain provenance manifest** `C:\toolchain-manifest.json` (2026-08-07) — pinned inputs with pin-vs-resolved pairs (LLVM, ninja, nasm, sccache, CMake, Vulkan, Git, Flutter, VS→MSVC toolset, SDK build) plus the floating ones (lld-link, rustc/cargo, uv, pwsh, openssl, pkg-config) and the OS base digest. Answers "which compiler built this image" from the ARTIFACT instead of a build log that ages out, and makes classic-vs-BK lane parity a `diff`. Every probe is best-effort (missing tool → `null`, never a failed layer)

#### `Test-Toolchain.ps1`

Verifies clang-cl, lld-link, WiX, Flutter are present after base setup, and ASSERTS the pinned versions (clang-cl/ninja/nasm/CMake vs `versions.env`) — a silent scoop fallback otherwise surfaces ~2 h into media-core as a patch that no longer applies

#### `Test-Health.ps1`

Docker `HEALTHCHECK` script — verifies ONNX Runtime DLL, FFmpeg, GStreamer, CMake, clang-cl

#### `Test-Container.ps1`

Comprehensive container validation — **25** test categories (23 until section 24, Hailo, and section 25, the ORT single-source census, landed in 2026-09; an earlier AGENTS.md copy of this row said 18 until 2026-08-08). Runs INSIDE the final image, which `windows/Dockerfile` COPYs it into along with the whole `modules` dir. The 25 sections live here; the assertion harness is in `WindowsSmokeTest.Common.psm1`

#### `Set-TensorrtTree.ps1`

Bind-mounted into `Dockerfile.nvidia`'s `trt-extract` stage. Renames the extracted `TensorRT-<version>` tree to a stable **`current`** so the runtime PATH never spells the pin, WARNS (never fails) on pin-vs-zip drift, and **fails closed** when neither `bin\` nor `lib\` carries runtime DLLs. Backlog #38: the old pin-derived PATH was wrong twice over — wrong version AND wrong dir (TensorRT 10+ moved the DLLs to `bin\`), so the ORT TensorRT EP could never load, silently, while builds stayed green. Absent zip stays a supported graceful skip; a half-extracted tree is a build failure.

### Host setup and maintenance — `windows/scripts/host/`

Run on the HOST, most of them elevated. Several refuse while a build is solving — that is deliberate, not a bug.

#### `Install-Vs.ps1`

Installs VS Build Tools 18 with ClangCL toolset

#### `Install-ScoopTools.ps1`

Installs Git (installer) + WiX 4 (dotnet tool), then via Scoop: 7zip, Vulkan SDK (plus its optional ARM64 component), Flutter, LLVM (plus the aarch64 compiler-rt builtins from the matching release archive), ninja, nasm, cppcheck, nano, nsis, uv, nuget, zlib, openssl (plus the arm64 build beside it), pkg-config, CMake, make, gawk. Installs **no** Rust (rustup via `Install-RustToolchain.ps1` is the sole provider) and, since 2026-09-18, **no** sccache (`Install-RustToolchain.ps1` installs the pinned released zip). **PINNED from versions.env (2026-08-07): LLVM/ninja/nasm** (`LLVM_WINDOWS_VERSION`/`NINJA_WINDOWS_VERSION`/`NASM_WINDOWS_VERSION`, forwarded as Dockerfile ARGs) on top of the existing CMake/Vulkan/Flutter/Git pins — those three produce or shape compiled output, and an unpinned clang-cl made the base image unreproducible in its most load-bearing component (five patches under `windows/scripts/patches/` are clang-cl-version-shaped). `Test-Toolchain.ps1` asserts all three at base-build time. The rest stay floating deliberately — the build only invokes them. **The 2026-08-08 caveat that the floating rule stops holding for `sccache` once multi-tier caching is wired is settled:** sccache is pinned (`SCCACHE_WINDOWS_VERSION`, recorded pin-vs-resolved in the toolchain manifest) and no longer comes from scoop

#### `Install-Vcpkg.ps1`

Bootstraps vcpkg for Windows

#### `Install-RustToolchain.ps1`

Installs Rust via rustup WITH a stable default toolchain (sole provider; local `file://` dist mirror dodges rustup's downloader deadlock in 2-CPU containers), runs Cargokit-shaped asserts, bakes `flutter_rust_bridge_codegen`

#### `Install-Cuda.ps1`

Installs CUDA + cuDNN at the `versions.env` pins; includes post-install verification (headers/libs/DLLs). `-TargetArch arm64` also stages the Windows-arm64 redist components and cuDNN into the same root (`lib\arm64`, `bin\arm64`; #176)

#### `Install-Tensorrt.ps1`

Auto-detects a TensorRT zip in `windows/downloads/` and installs it

#### `Publish-ShimPatch.ps1`

HOST maintenance (admin, never while a build solves): installs a locally built `containerd-shim-runhcs-v1.exe` over Stevedore's, keeping `.orig` (stock, written once) plus a timestamped backup per deployment, and optionally merges env vars into the containerd service (`-ServiceEnvironment`) since the shim inherits them. `-ReportOnly` lists installed binary, backups and env without touching anything; `-Restore .orig` / `-Restore .45min` puts a backup back. Refuses while `buildctl` or a shim process is alive (the binary is locked). Needed because every Stevedore/containerd update silently reverts the patched shim — see [`windows-build-lanes.md`](windows-build-lanes.md) § BuildKit/containerd lane and `windows/upstream/`. NB: a quiet log is NOT proof it took effect (the shim logs its effective timeout at Debug, which does not reach containerd's log) — verify behaviourally with the OpenCV canary

#### `Install-NewHost.ps1`

HOST bring-up (admin, run `-ReportOnly` first, never while a build solves): the ONE elevated run that turns a freshly-rebooted Stevedore host into a green `Test-HostSetup.ps1`. Orchestrates the canonical per-concern scripts rather than duplicating them: authors the CNI `.conflist` from the LIVE `vEthernet (nat)` subnet (derived network/prefix+GW at runtime — no magic subnet literals anywhere), then `Set-ContainerdConfig.ps1` (derives the `.conf`, debug flags, teardown env, Defender), `Set-BuildkitdGcpolicy.ps1` + the `BUILDKIT_STEP_LOG_*` step-log env, the patched runhcs shim (when no `-ShimPath` is given it BUILDS the env-configurable shim from the owner's fork, `Kataglyphis/hcsshim@feature/configurable-teardown-timeout` checked out at a pinned commit, installing Go via scoop, then `Publish-ShimPatch.ps1` with `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m` on the containerd service; the 45min/100min fixed-constant builds are history), and dufs (scoops if missing, starts it, registers the ONLOGON task, sets machine `SCCACHE_WEBDAV_ENDPOINT` to the host's LAN IP). Idempotent; every sub-script is called with a HASHTABLE splat (array splatting would bind `-ReportOnly`/`-ShimPath` by position — the array-splat rule in AGENTS.md). Companion to `Test-HostSetup.ps1` below

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

HOST config (admin; never while a build solves — applying restarts containerd and kills in-flight solves). The containerd counterpart to `Set-BuildkitdGcpolicy.ps1`. It owns the debug-log flags and the runhcs shim teardown timeout, which live only in the service's registry values because containerd runs with no `config.toml` here, plus containerd's Defender exclusions, and it derives the CNI `.conf` from the authored `.conflist`. What each setting is for, and why a script is the only reproducible way to hold them: [`windows-host-setup.md`](windows-host-setup.md#c1-permanent-debug-flags-on-containerd--buildkitd-owner-policy).

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

**Obsolete since 2026-08-18.** It reproduced the sccache nvcc server deadlock for mozilla/sccache#2808 by setting `SCCACHE_REPRO_CUDA_LLM=1`, which made `Build-OnnxFromSource.ps1` skip patch 006 so the sccache CUDA launcher stayed on for `onnxruntime_providers_cuda_llm`. Patch 006 and that knob were retired on 2026-08-18: the fused_moe family goes through the launcher on every build, the ARG stays declared in `Dockerfile.media-builder` only so old commands do not silently no-op, and nothing reads it. #2808 is closed, fixed in the sccache 0.18.0 release this lane pins ([`upstream-windows-patches.md`](upstream-windows-patches.md)). A run today is an ordinary `-Gpu` media-core rebuild. It still refuses to start while another `buildctl` is running.

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

The mandatory GStreamer plugin CONTRACT (see § Mandatory GStreamer plugins and AGENTS.md § Windows Build Invariants): `Get-RequiredGstPlugin` (libav/opencv/onnx/webrtc/nice/tflite with per-plugin detection mechanism and rationale), `Write-PkgConfigFile`, `Get-LibraryLinkName`, `Assert-PkgConfigModule` (presence AND `-MinimumVersion` floors — `pkg-config --exists` alone passes on a `.pc` whose version field is empty). Merge-stage only, deliberately NOT in `WindowsScripts.Shared.psm1`: that one is in all three media branches' compile closure and this set changes often

### Drivers and entry points

The top-level scripts a human or CI actually invokes.

#### `Dockerfile.smoke-gate`

*`windows/`*

Not a script — the automatic verification stage (backlog #44). Solved against the finished image as the last step of every BK chain — **both lanes** since 2026-08-24 (this row said "NOT run on arm64" until then, contradicting § Smoke Testing): on arm64 the suite runs its host-toolchain sections against the lane's own floors (76/20) while the aarch64 payload stays verified by `Test-TargetArch.ps1` in the merge stage. Runs a buildctl solve rather than `nerdctl run` because containerd's pipe is admin-only while the driver is non-admin, invokes the test **through `entrypoint.cmd`** (a bare RUN bypasses ENTRYPOINT and loses VsDevCmd + the ASAN runtime dir), and **bind-mounts** the current script + modules so a smoke-test fix needs no image rebuild to re-verify. Knobs: `-SkipSmokeGate`, `-SmokeMinPassed`, `-SmokeMaxSkipped`.

#### `Dockerfile.publish-gate`

*`windows/`*

Not a script — the publish gate (2026-09-23). `Invoke-BkPublishGate` solves it `-NoOutput` at three points of every lane, the last one before any export or push, and **`-SkipSmokeGate` skips none of them**. Its one RUN bind-mounts `WindowsImageEnv.Common.psm1` and runs `Assert-ImageEnvPublishable`, which fails when the image's environment (the config ENV plus the Machine and User registry scopes) carries a build-host sccache variable or an RFC1918/link-local address. No ARG after FROM and no entrypoint, so the environment it grades is the one that ships. The three points, why it exists and what it cannot see: [`windows-build-resources.md` § What the published image carries](windows-build-resources.md#what-the-published-image-carries). Tests: `ImageEnv.PublishGate.Tests.ps1` (the matcher against `linux/scripts/tests/image-env-cases.json`, one mutant per rule, and the driver's call order).

#### `patches/litert-lm/patch-assert.cmake`

*`windows/scripts/`*

`patch_replace_required` / `patch_regex_replace_required` — replace-with-verification for the CMake source patchers (backlog #56). `FATAL_ERROR`s when a pattern matched NOTHING, instead of the old bare `string(REPLACE)` + unconditional "Patched …" message that let an upstream reformat silently restore a fixed defect. Lives INSIDE `litert-lm/` because the Dockerfile COPYs that directory specifically. Enforced by `Patches.CmakeNoOpGuards.Tests.ps1`; a legitimate non-source replace opts out with a `patch-assert-exempt` marker + reason.

#### `Test-SccacheWrite.ps1` + `Invoke-SccacheWriteProbe.ps1` + `Dockerfile.sccache-write-probe`

*`windows/scripts/`, `windows/`*

Reproduces the sccache **cache-write** environment in ~2 min instead of a 90-min media build (backlog #99): same cache-mount ids, same sccache settings (the endpoint and chain as ARGs since 2026-09-23, like the real stages — [`windows-build-resources.md` § What the published image carries](windows-build-resources.md#what-the-published-image-carries)), then a configuration matrix (`disk-only`, `disk-mounted-subdir`, `disk-plaindir`, `multilevel-mounted`, `multilevel-plaindir`, `webdav-only`), raw filesystem tests, a process-spawn matrix, a bisect of the cache root, serial-vs-parallel and path-length sections. **Run it against the REAL base image** (`-BaseImage local/kataglyphis:bk-windows-media-core-ffmpeg`), not the toolchain default. **Health warning:** it reproduces the ENVIRONMENT but not the FAILURE — every configuration it blessed then failed in a real build, so treat its verdicts as hypotheses to test in a build, never as clearance. `PROBE_NONCE` + a `probe complete` marker check exist because an unchanged script gives `#6 CACHED` and silently replays an old verdict; `--no-cache` is not the alternative (it empties cache mounts, #96).

#### `Test-OpencvVideoBackends.ps1` + `Invoke-OpencvVideoProbe.ps1` + `Dockerfile.opencv-video-probe`

*`windows/scripts/`, `windows/`*

Asks a BUILT media image what video backends OpenCV actually has (backlog #93-#95): prints the `Video I/O:` block, runs the three #95 assertions, and shows `videoio_registry.getBackends()` beside them. ~4 s against a built media-core image, versus a full chain rebuild. Pass `-BaseImage local/kataglyphis:bk-windows-media-core` (or `-opencv`): the script's default, the `-ffmpeg` intermediate, has carried no OpenCV since #94 moved OpenCV after FFmpeg — which is what let the #95 guards be watched FAILING on the real artifact before the fixes land. Same two safeguards as the sccache probe: `PROBE_NONCE` (a re-run with an unchanged script otherwise gives `CACHED` and replays an old verdict) and a `probe complete` marker check; `--no-cache` is not the alternative, it empties cache mounts (#96).

## Why the pin suite runs on a Windows runner, under Pester 3.4.0

Written here once because three consumers each carried a 40-line copy of it in
their own `submodule-pins.yml`, and they had begun to disagree.

`.github/actions/run-pester-suite` installs **Pester 3.4.0** by default — the
dialect BeschleunigerBallett's Windows lane pins — and 3.4.0 is a Windows
PowerShell-era module. So the lane needs a **Windows** runner, not one of the
cheaper `ubuntu-26.04` ones the rest of the Linux jobs use. The suite itself is
version-agnostic: `shared/windows/tests/Submodule.Pins.Tests.ps1` asserts with
`throw` rather than `Should`, and was verified under both 3.4.0 and 6.1.0 — so
the lane can move to a cheaper runner the day the action's invocation survives a
Core-compatible Pester. Today it does not: 5.x loses the per-failure diagnostics
and 6.x rejects `-Quiet` (measured 2026-09-07). The workflow's `pester-version`
and `runner` inputs are the switch; nothing else has to change for that.

The label is **`windows-2025`, pinned**, not `windows-latest`. The alias
resolves to windows-2025 today, so pinning is a no-op right now; the point is
that a future repoint would swap the OS image — and with it the Windows
PowerShell 5.1 that Pester 3.4.0 needs — under a green build with no commit to
blame.

The hub's `submodule-pins.yml` is `workflow_call`-able, so a consumer calls it
with `uses:` and inherits all of the above instead of restating it:

```yaml
jobs:
  pins:
    uses: Kataglyphis/ANTfrastructure/.github/workflows/submodule-pins.yml@develop
```

## Reusable module: WindowsContainerBuild.Reuse

The container-reuse pattern, packaged so consumers do not each reinvent it. Consumers resolve it ANTfrastructure-first with a vendored fallback.

`windows/scripts/modules/WindowsContainerBuild.Reuse.psm1` implements the
container-reuse pattern so consumers do not each reinvent it:

- `Invoke-ContainerBuild` - the entry point: runs a consumer's build command in
  the image over the tar pipe (default) or a bind mount (`-UseBindMount`) and
  returns a result object. `Resolve-ContainerBuildCommand`, `Get-ContainerEnvArgs` and
  `Get-SccacheContainerEnv` are its exported helpers.
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

**Docker's output goes to the host, never into a function's result (2026-09-23).**
Consumers call `$null = Invoke-ContainerBuild ...`, and the build's `docker exec` (tar
pipe) and `docker run` (bind mount) wrote their stdout into the function's output, so
that one `$null =` swallowed every line of a failing CI build — including the sccache
failure that made CMake call clang-cl broken. Every docker call whose output nothing
consumes now ends in `| Out-Host`; `$LASTEXITCODE` still reads the docker client's
exit code after the pipe, and the function returns its result object alone.
`ContainerBuild.Output.Tests.ps1` holds the class guard (an AST scan for any
unconsumed `& $DockerExe` pipeline in the module) and a child-session check that a
discarded result still prints the build.

**The host's sccache remote tier is forwarded at run time (2026-09-24).** The image no
longer carries `SCCACHE_WEBDAV_ENDPOINT`, so `Invoke-ContainerBuild` adds this host's
endpoint and chain to `-CacheEnv` as `-e` entries unless the caller set them (`''`
opts out): [`windows-build-resources.md` § The build host's remote tier, at run time](windows-build-resources.md#the-build-hosts-remote-tier-at-run-time).

Consumers resolve it ANTfrastructure-first with a vendored fallback (see
BeschleunigerBallett's `scripts/windows/Resolve-BuildModule.ps1`).
