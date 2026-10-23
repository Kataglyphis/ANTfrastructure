# Windows Build Image

The reference for the image itself: what is installed, how it is built, how it is verified. Lane
mechanics, resource budgets and host fixes moved to their own pages on 2026-08-25:

| Looking for | Read |
|---|---|
| Which lane to build on; isolation policy, preflight gates, RDNA4 A/B history, Store GC | [`windows-build-lanes.md`](windows-build-lanes.md) |
| CPU/memory envelope, sccache wiring, GPU in containers, the 125-layer budget | [`windows-build-resources.md`](windows-build-resources.md) |
| Stevedore post-install fixes, ghcr login, service recovery | [`windows-stevedore-and-docker.md`](windows-stevedore-and-docker.md) |
| Rules you must not regress when editing `windows/` | [`windows-build-invariants.md`](windows-build-invariants.md) |
| An error message | [`failure-modes.md`](failure-modes.md) |
| Open refactor work | [`windows-refactor-backlog.md`](windows-refactor-backlog.md) |
| Building for Windows-on-ARM | [`windows-cross-builds.md`](windows-cross-builds.md) |
| Building a large project **inside** this image fast: incremental-build measurements, what does not work (named volumes as build directories), why the released sccache is unsafe on clang-cl C++23 modules | [Windows Container Build Performance](windows-container-build-performance.md) |

**Antivirus: exclude your development folder.** Real-time protection locks files during builds
(especially CMake FetchContent and cargo builds) and fails them intermittently with "Failed to
remove directory" or "(os error 32)".

## Source Patch Policy

**Patch-first.** An upstream modification on the Windows lane is a reviewable `.patch` file under
`windows/scripts/patches/<component>/NNN-<slug>.patch`, applied by the idempotent helper
`Invoke-SourcePatch` (`windows/scripts/modules/WindowsSourceBuild.Patches.psm1`, re-exported by
`WindowsSourceBuild.Common.psm1`). Every `.patch` file:

- Is a standard `git diff` / unified diff (`a/`/`b/` prefix, `-p1` strip).
- Applies idempotently: `Invoke-SourcePatch` runs `git apply --reverse --check` first and skips an
  applied patch, falls back to `patch.exe -p1` for non-git tarball extractions, and throws with the
  patch file's first 40 lines on failure.
- Targets a *pinned* upstream version (e.g. the file header names the git tag in
  `linux/scripts/01-core/versions.env`).

Regex and callback edits share file reads and write/no-change verdicts in
`WindowsSourceBuild.Patches`; their transformations and idempotence rules stay separate.
`Add-SourceRegexGuard` shares ordered regex wrapping for LiteRT-LM preprocessor
guards. Callers retain patterns, conditions, indentation and marker-based idempotence;
the helper returns text and leaves file writes and diagnostics to the patch API.
`Edit-SourceRegexText` owns ordered case-sensitive .NET substitutions, including match
evaluators, while preserving replacement backreferences and exceptions.
Callback edits also accept `-Guard` to skip before transformation when the input
does not match, sharing input selection with their marker handling.
`Edit-SourceFile` and `Invoke-InlineRegexPatch` accept `-Quiet` for callers that
already own change counters and diagnostics. It suppresses informational and
no-change messages; required-input errors, callback exceptions and `AssertGone`
postconditions still throw. `Invoke-InlineRegexPatch -IfPresent` skips only an
absent optional input; present inputs retain required postconditions and failures.
Defaults retain their existing warnings. GStreamer's
zero-match C++ standard warning remains at the caller. C++ keyword conversion,
Ninja cleanup, IREE egg-info edits and LiteRT-LM CMake edits use the same
write/no-change machinery.

`Assert-SourceFileContent`, also re-exported by `WindowsSourceBuild.Common`, verifies
the written file with a caller predicate and diagnostic. The predicate must return
exactly one Boolean true; empty, textual or multiple results fail. OpenCV's ARM
softfloat and MLAS checks use it. Fixture coverage exercises source edits and these
postconditions, without building OpenCV or proving compiler behavior.

**Exceptions, kept inline on purpose:**

1. **Generated build files.** FFmpeg's post-configure `ffbuild/*.mak`, `library.mak`, `subdir.mak`,
   `Makefile`, `ffbuild/config.mak` (content varies per `./configure` invocation), and the
   `Update-NinjaFile` calls in `Build-OnnxFromSource.ps1` / `Build-OnnxGenaiFromSource.ps1` that
   strip MSVC-only flags from CMake-generated `build.ninja` (varies per CMake configure). The
   canonical form for both: inline `-replace` on invariant sub-sequences (`-showIncludes`,
   `EXTRALIBS-lib*=`, `/experimental:external`, `/Qspectre`).

2. **Fetched third-party deps whose pinned version floats.** `Edit-CppKeywordAlternatives` walks the
   CUTLASS headers ONNX Runtime's ExternalProject fetches at configure time, plus the
   `_udiv128 → udiv128` substitution on `cutlass/uint128.h` (clang-cl lacks the MSVC-only
   intrinsic). The fetched CUTLASS SHA follows the provider's `cutlass-src` ExternalProject
   pointer, so a static `.patch` against a pinned tag would silently rot. The helper plus the
   targeted inline regex are canonical.

3. **Multi-file conditional substitutions.** LiteRT's `proto/CMakeLists.txt` disable loop
   (`Build-LitertFromSource.ps1`) walks ~17 files under `$tfliteSrc` and skips files whose content
   already lacks `protobuf_generate|protoc`; the OpenCV mlas `<cstring>` prepend loop
   (`Build-OpencvFromSource.ps1`) walks every `3rdparty/mlas/**/*.cpp` and skips files that already
   include `<cstring>`. A static `.patch` against a pinned tag cannot express the per-file predicate
   and would cover only a fraction of the directories.

4. **Installed toolchain headers, not the upstream source tree.** `Build-OnnxGenaiFromSource.ps1`
   patches the installed MSVC STL `yvals_core.h`: it wraps the single `_EMIT_STL_ERROR` define in
   `#ifdef __clang__`, which no-ops *every* STL error code (STL1009/1010/1011, etc.) under clang-cl,
   so no per-header patch (e.g. for `<experimental/coroutine>`) is needed. The MSVC toolset version
   floats (resolved via `Get-MsvcToolsRoot`), so a static `.patch` would fit one toolset only; a
   drift assertion fails the build loudly if a future toolset changes the macro's format.

5. **Binary byte-filter edits.** `onnxruntime.rc` non-ASCII byte stripping (`-le 127`) is a byte
   filter, not expressible as a unified diff.

6. **Single-file regex edits on aggressively-changing generated-as-schema upstream files**: none
   left (checked 2026-09-25). The last one, an inline removal of OpenCV's
   `add_extra_compiler_option(-include cstring)` from `cmake/OpenCVCompilerOptions.cmake`, is gone;
   no build script edits that file. `Build-OpencvFromSource.ps1` passes `/FIcstring` in
   `CMAKE_CXX_FLAGS` on the configure line instead, and patch `002` does the same inside MLAS.

7. **Upstream export-gap bridges (LiteRT-LM v0.14.0): FROZEN FALLBACK ONLY.** The primary LiteRT-LM
   build is **Bazel** (`Build-LitertLmBazel.ps1`), the path Google CI-tests, which needs none of
   these bridges; this item covers only the retired CMake fallback `Build-LitertLmFromSource.ps1`.
   - Google ships LiteRT-LM tags whose CMake layer lags the source restructure. v0.14.0's was never
     buildable anywhere: it references the deleted `constrained_decoding` component, pins a LiteRT
     from *before* the `support/` tree its own shim headers `#include " from @litert"`, and
     compiles none of the new `logits_processor`/support subsystems.
   - The fallback bridges this with condition-gated blocks (`[LiteRTLM-winfix export-stubs]`,
     `[LiteRTLM-winfix support-graft]`, the v0.14-orphans + v0.14-deps blocks): stub CMakeLists are
     *generated*, the `support/` tree is *sparse-cloned from LiteRT at the version this container
     already ships* (`LITERT_VERSION`), and orphaned sources are injected into the engine lib.
   - A static `.patch` cannot express "graft a tree from another repo at a configurable tag" or
     "only when the referenced dir is missing". Every block is gated on the breakage itself, so a
     tag with a fixed export builds upstream's files untouched and the bridge self-retires.
   - The Gemma constraint provider is upstream's prebuilt-only DLL component: its import lib is
     linked on the exe, and the DLL is staged beside `litert_lm_main.exe` with `z.dll` +
     `kissfft-float.dll` (found via `llvm-objdump -p` after the exe died 0xC0000135 without them).

8. **OpenCV CMake hooks, not patches.** `windows/scripts/patches/opencv/cmake-hooks/` holds files
   OpenCV itself includes through `OPENCV_CMAKE_HOOKS_DIR`, one `<HOOK_NAME>.cmake` per hook. OpenCV
   registers every `*.cmake` there under its basename, so nothing else may live in that directory
   (a test enforces it). A hook only adds to a target (today `opencv_gapi`'s `/DELAYLOAD`s for the
   G-API DirectML EP) and edits no upstream text, so it needs no drift assert;
   `Get-OpencvOrtConfigureFinding` reads `build.ninja` to prove it took effect. See
   [`onnxruntime-single-source.md` § OpenCV on Windows](onnxruntime-single-source.md#opencv-on-windows-the-shim-the-hook-and-the-gate).

Every inline substitution in a build script carries a
`# Inline patch (kept inline, NOT a .patch file):` block comment with its canonical-form rationale.
The `.patch` inventory:

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
| HailoRT | `001-quantization-msvc-guard.patch` | `hailort/libhailort/include/hailo/quantization.hpp` | The x86 rounding intrinsics only under MSVC on x86/x64, never under clang-cl or on ARM64 |
| HailoRT | `002-ioctl-nullptr-template-specialization.patch` | `hailort/libhailort/src/vdma/driver/os/windows/driver_os_specific.cpp` | The missing `template<>` on the two `nullptr_t` specialisations |
| HailoRT | `003-windows-lockedfile-dtor.patch` | `hailort/common/os/windows/filesystem.cpp` | Define `LockedFile::~LockedFile`, which the Windows stub declares and never defines (undefined symbol at link) |
| HailoRT | `004-cmake-target-arch-macro.patch` | `hailort/CMakeLists.txt` | `_ARM64_=1` on an ARM64 target instead of the pointer-size `_AMD64_=1` |

### Per-patch notes

Why each longer patch still exists. Retire a patch whose reason has expired; never carry it.

#### `003-dml-clangcl-compat.patch`

clang-cl + `USE_DML=ON`: out-of-line `AbstractOperatorDesc` members past `OperatorField`
(incomplete-type), drop the `.##Z` token-paste, widen `Dispatch<uint32_t>` → `size_t`.

#### `004-tunable-severity-macro-collision.patch`

ORT 1.28.0 + CUDA 13.3: `wingdi.h`'s `#define ERROR 0` (reached despite `-DNOGDI` when a header
includes wingdi directly, as `triton_kernel.h`'s chain does) pre-expands through the `LOGS_DEFAULT`
forwarding macro into the nonexistent `Severity::k0` (nvcc: `enum ... has no member "k0"` at the
`LOGS_DEFAULT(ERROR)` line, first TU `triton_kernel.cu`). Fix: guarded `#undef ERROR` +
`#undef VERBOSE` after the includes. Diagnosis trap: the error line points at whatever
`LOGS_DEFAULT(...)` use sits there; read the LINE, not the macro argument you expect.

#### `005-xqa-host-stub-sccache.patch`

ORT 1.28.0 XQA (paged-attention) kernels: the host-pass include guard keys on the cmake define
`HAS_SM80_OR_LATER`, and sccache's nvcc decomposition (`CMAKE_CUDA_COMPILER_LAUNCHER`) can drop
target `-D` defines in the host sub-step → `x_?.cudafe1.stub.c` `C2039/C2065` (`smemSize`/
`kernelType`/`cacheVTileSeqLen` missing from `H*::grp*_*`; the synthetic `x_?.cu` TU name is the
sccache fingerprint). We pin sm80+ archs, so the patch makes the host stub unconditional. NOT
upstreamable as-is (pre-sm80-only builds would regress).

#### ~~`006-cuda-llm-bare-nvcc.patch`~~ RETIRED 2026-08-18

sccache's nvcc decomposition crashed its server deterministically on the fused_moe_gemm generated
launchers (two chain runs died at ~4910 s, `os error 10054` on every client). The launchers all
live in the `onnxruntime_providers_cuda_llm` OBJECT library, so the patch cleared that ONE target's
`CUDA_COMPILER_LAUNCHER` property: bare nvcc there. History: CUDA went opt-in-bare on 2026-08-10,
then back to launcher-ON by DEFAULT on 2026-08-18 once mozilla/sccache#2811 fixed the dryrun
quote-collapse, so the launcher is on for every normal build; opt out with
`-BuildArg SCCACHE_CUDA_LAUNCHER=`. Hit rates per run: the `sccache-stats|` stderr block after the
ONNX build.

#### `001-cmake-clang-cl-compat.patch`

CMP0146/CMP0148 OLD→NEW + clang-cl/CUDA detection compat. REGENERATED against 5.0.0 on 2026-08-10
(5.0.0 dropped the `CMP0218` block the old hunk context named). The patch applies with NO fallback,
so drift throws an hour into media-core: run `Test-PatchesApplyClean.ps1` after every pin bump.

#### `002-mlas-clangcl-force-include.patch`

OpenCV 5.0.0's bundled MLAS treats clang-cl as GNU-Clang and passes the GNU pair `-include` +
`cstring`, which the CL dialect parses as an INPUT FILE
(`clang-cl: error: no such file or directory: 'cstring'`, first mlas TU). Adds an MSVC-frontend
branch (`CMAKE_CXX_COMPILER_FRONTEND_VARIANT`) using `/FIcstring` + `/w`. The older inline
`<cstring>` source-prepend loop in Build-OpencvFromSource.ps1 fixes only the CONTENT, not the
broken flags.

#### `003-mlas-windows-skip.patch`

Skip the vendored MLAS on Windows: its kernels are GAS/ELF-only (`.type sym,@function`, no MASM
port), and clang-cl IS a working GAS assembler, so the `check_language(ASM)` guard that saves MSVC
does not fire; the `.S` files then die in the integrated assembler ("expected absolute expression",
run 12, 2026-08-10). dnn falls back to its built-in SGEMM; inference runs on ONNX Runtime/DirectML
anyway.

#### `004-dnn-ort-profiling-wchar.patch`

UPSTREAM BUG (5.0.0, run-13 find): dnn's ORT `EnableProfiling` passes `char*`, but `ORTCHAR_T` is
`wchar_t` on Windows; the model-path call right below is `#ifdef _WIN32`-widened, this one was not
(upstream Windows CI never builds dnn with ORT). Filed as opencv#29788 and closed: `5.x` had
already fixed it (PR #29309, after the 5.0.0 tag we pin), so the patch retires with the next
`OPENCV_VERSION` ([`upstream-windows-patches.md`](upstream-windows-patches.md)).

`ffmpeg/makedef` is **not** a patch: it is a whole-file replacement script staged over FFmpeg's
`makedef` (a byte swap, not a diff), so the table omits it.

**After bumping any upstream version**, audit the `.patch` files before letting the orchestrator
loose: `windows/scripts/tests/Test-PatchesApplyClean.ps1` clones each pinned upstream and runs the
exact `git apply --check` the build uses (`windows/scripts/patches/README.md`). A patch that no
longer applies: regenerate it with `git diff` against the new tag and update the inventory above.

The Windows container build uses [Stevedore](https://github.com/slonopotamus/stevedore) (a Docker
distribution for Windows Containers) and is split into staged images:

- `windows/Dockerfile.base` builds the cached toolchain base image (CMake, VS Build Tools 18,
  LLVM/Clang, Rust, Flutter, WiX 7; every version from `versions.env`).
- The **sdk slot**. GPU lane: `windows/Dockerfile.nvidia` layers CUDA + cuDNN + TensorRT
  (`CUDA_VERSION`, `CUDNN_VERSION`, `TENSORRT_VERSION`) on the base, tagged `windows-sdk`;
  `-Variant rocm`: `windows/Dockerfile.rocm` takes the slot (§ ROCm layer). CPU lane: the base is
  re-exported as `windows-sdk` through a one-line `FROM` stage (containerd has no unprivileged
  `tag`; the former no-op `Dockerfile.sdk` shim was removed), and downstream stages build CPU-only
  (CUDA auto-detection falls back to `CPU-only build`). `windows/Build-Buildkit.ps1` selects with
  `-Gpu` / `-Variant`.
- The toolchain stage builds CPython `PYTHON_VERSION` (versions.env, 3.15.0) from source via
  `windows/Dockerfile.toolchain-builder` + `Build-ToolchainAll.ps1`, twice from one checkout: the
  GIL build and its free-threaded twin (§ [The free-threaded CPython](#the-free-threaded-cpython)).
  Then it builds the patched clang/LLVM on top by default (`patched-llvm` target,
  `BUILD_PATCHED_LLVM=1`; `-StockLlvm` opts out). The former standalone `Dockerfile.toolchain` was
  removed as dead code: it duplicated the builder without the nuget pre-seed fix.
- The **media stage fans out into three branch images** (`windows/Build-Buildkit.ps1`), built
  **sequentially** by default: media-core first, alone with the whole RAM budget for maximum ONNX
  parallelism; `-ConcurrentAux` builds litert and tvm side by side after it. All three branches
  share ONE multi-stage builder, `windows/Dockerfile.media-builder`, selected per stage via
  `--target`; then the stage fans in:
  - **media-core**: one `media-core-built-*` target and tag per library, in this order, each
    running `Build-MediaCoreAll.ps1` for its one library (HailoRT's script is called directly).
    ONNX Runtime (source build, pin `ONNXRUNTIME_VERSION`; CUDA EP when the NVIDIA layer was used,
    DirectML EP always via the clang-cl patch, the WebGPU EP on the rocm spike) → FFmpeg (pinned
    release tag `FFMPEG_VERSION`; MSVC toolchain via MSYS2 bash) → OpenCV 5.x (CMake+Ninja+clang-cl,
    CUDA auto-detected; after FFmpeg so its videoio links ours, #94) → HailoRT
    (`Build-HailortFromSource.ps1`, pin `HAILORT_VERSION`) → ONNX GenAI. All three consumers of ONNX
    Runtime take the chain's (§ FFmpeg, § OpenCV 5.x, § ONNX GenAI).
  - **media-litert** (`--target media-litert-built` + `Build-LitertAll.ps1`): LiteRT (pin
    `LITERT_VERSION`; CMake+Ninja; also the TFLite C-API lib `tensorflowlite_c`) → LiteRT-LM (pin
    `LITERT_LM_VERSION`; independent of ONNX; **Bazel** via `Build-LitertLmBazel.ps1` →
    `litert_lm_main.exe`; the CMake export-bridge path `Build-LitertLmFromSource.ps1` is a frozen
    fallback, § Source Patch Policy #7).
  - **media-tvm** (`--target media-tvm-built` + `Build-MediaTvmAll.ps1`): TVM → IREE (both
    LLVM-heavy ML compilers; each installs its Python wheels into the source-built CPython; IREE
    native tools land at `C:\runtime\iree`, `IREE_ROOT`/`IREE_BIN`).
  - **merge** (`Dockerfile.media-merge-builder`): `COPY --from` fan-in of the three branch trees
    into one `C:\runtime` + canonical env layout. The host CPython's site-packages of media-core and
    media-tvm merge in one `RUN` instead (`Merge-SitePackageTree`), because a `COPY` over a file a
    lower layer holds stores its name lowercased
    ([invariant](windows-build-invariants.md#a-layer-that-replaces-a-lower-layers-file-stores-its-name-lowercased)).
    A `cuda-runtime-stage` (`Copy-CudaRuntime.ps1`) FLATTENS the CUDA/cuDNN runtime DLLs into
    `C:\runtime\cuda-runtime\bin` on PATH; without it the CUDA-linked libs (notably OpenCV, which
    hard-links `cudnn64_9.dll`) fail to load in this non-nvidia-based image. Then GStreamer (pin
    `GSTREAMER_VERSION`) builds via `Build-GstreamerFromSource.ps1` (Meson + clang-cl; auto-detects
    CUDA, OpenCV, ONNX and FFmpeg from the merged tree).
- `windows/Dockerfile.torch` assembles the OrchestrANT app env on the media image
  (`media → torch → final`; tag `bk-windows-torch`), and `windows/Dockerfile` produces the final
  developer image FROM that torch image (VsDevCmd entrypoint). On `-Variant rocm` the `migraphx` and
  `llama` stages sit between media and torch ([`windows-rocm.md`](windows-rocm.md)).

## The Windows lane as AGENTS.md carried it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10). The RULES stayed there; this is the
reference behind them.

All stages use **Ninja + clang-cl + lld-link**. The container toolchain is
**containerd + BuildKit + nerdctl**, each tool where its pipe ACL allows:

| Task | Tool | Shell |
|---|---|---|
| Build the chain | `windows\Build-Buildkit.ps1` → `buildctl` | non-admin |
| Inspect / run the `bk-*` images | `nerdctl --namespace buildkit` | **admin** |
| Publish / inspect images | Stevedore's `docker.exe` | non-admin |

```pwsh
.\windows\Build-Buildkit.ps1               # build :winamd64, CPU + DirectML (non-admin)
.\windows\Build-Buildkit.ps1 -Gpu          # build :winamd64-nvidia, bk-*-nvidia stage tags
```

**The lane mechanics live in [`docs/windows-build-lanes.md`](windows-build-lanes.md)**: isolation
policy and the probe-log trap, the sccache, RDNA4 and step-log preflight gates, the
BuildKit/containerd lane, the nerdctl lane, the classic lane's run+commit path (historical),
mid-chain failure recovery, and the RDNA4 A/B history. Four things an agent gets wrong without it:

- **There is ONE Windows driver, `Build-Buildkit.ps1`.** The classic lane was retired 2026-08-26
  and `build.ps1` DELETED 2026-08-31, for two independent structural defects, both verified;
  reviving it is a redesign, not a target-pin change. A `.\windows\build.ps1` recipe from an older
  page or from shell history has nothing left to run. Reasons and the cut list:
  [windows-build-lanes.md](windows-build-lanes.md) § The classic lane was retired, which owns the
  topic; do not restate them.
- **`nerdctl` needs an ADMIN shell**: containerd's pipe is Administrator-only upstream, with no
  `--group` equivalent. No pipe-ACL hacks; do not re-litigate it.
- **Every Stevedore/containerd update reverts the patched runhcs shim.** Put
  `windows/scripts/host/Publish-ShimPatch.ps1 -ReportOnly` in your post-update routine.
  - Since 2026-09-01 the deployed shim is the **`upstream-env` variant built from the owner's
    fork** (`Kataglyphis/hcsshim@feature/configurable-teardown-timeout`). It is patched in effect
    only while the **containerd** service `Environment` carries
    `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m`, a **Go duration string**; a bare number
    silently means stock 30 s.
  - So an update reverts TWO things: the binary AND (via reinstall) possibly that env value. Check
    both, restore both with `Publish-ShimPatch.ps1 -ShimPath <fork build> -ServiceEnvironment
    CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m`. A changed env value needs a containerd restart
    (the shim inherits containerd's environment at spawn).
  - **It can also wipe the buildkitd service `Environment`** (the `BUILDKIT_STEP_LOG_MAX_SIZE=-1` /
    `BUILDKIT_STEP_LOG_MAX_SPEED=-1` keys that prevent the 2 MiB step-log clip). Check with
    `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -Name Environment).Environment`
    after any update; if empty, re-apply via `Install-NewHost.ps1` or the registry
    `Set-ItemProperty`. The build driver refuses to start without them.
- **A Stevedore REINSTALL wipes more than the shim**: the buildkitd service `Environment`, the dufs
  task and its serve directory go with it ([`docs/windows-host-setup.md`](windows-host-setup.md)
  § Phase R).

Fresh machine: § Prerequisites. Full build sequence: § Build Commands.

## The build notes AGENTS.md carried

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10); the media-core order and the
per-script pointer were corrected on 2026-09-25. The RULES stayed there; this is the reference
behind them.

The Windows lane source-builds the media stack with Ninja + clang-cl + lld-link; the exceptions
(CPython with the VS ClangCL toolset, FFmpeg, GStreamer, LiteRT-**LM**) are the Generator column of
§ Component Build Matrix.

- **The amd64 chain** is the staged-image list above. FFmpeg before OpenCV is load-bearing (#94):
  OpenCV's video backend links what FFmpeg installed. The authority is the `media-core-built-*`
  stage chain in `Dockerfile.media-builder`, which `Build-Buildkit.ps1` solves in that order, not
  this page.
- **arm64** (`-TargetArch arm64`): all three media branches build since 2026-08-24 (TVM/IREE
  runtime-only). What a branch cannot build for the target is decided INSIDE the branch and shipped
  as an empty, marker-carrying tree; the driver-level `$crossBlockedBranches` refusal list was
  removed on 2026-08-25. What each branch skips or names ABSENT inside the bundle (LiteRT-LM, the
  TVM/IREE compilers, the python packages that need the compilers) is owned by the status banner of
  `docs/windows-cross-builds.md`; do not restate it here, it moves.
- **Assemblers are the one place the "clang-cl everywhere" rule does not hold on amd64.**
  NASM-syntax kernels (FFmpeg since #119, libjpeg-turbo in OpenCV, openh264 in GStreamer) go
  through the pinned `nasm`; LLVM has no NASM-syntax assembler. MASM-syntax sources split by what
  LLVM's `llvm-ml` can actually parse (#123, 2026-08-25/26):
  - IREE's single trampoline `x86_64_msvc.asm` goes through `llvm-ml -m64`. `-m64` is
    load-bearing: llvm-ml assembles i386 by default and then rejects the `.seh_*` directives
    (proven on the cross lane's host tools).
  - **MLAS's x64 kernels stay on MSVC's `ml64.exe` by design**, measured on amd64 run 6: every MLAS
    `.asm` opens with `.xlist` (LLVM 22's MasmParser has no listing directives),
    `INCLUDE mlasi.inc` is not found (llvm-ml searches `-I` dirs only, ml64 also the includer's
    directory), and behind it sits the Windows SDK's MASM macro layer. The ORT configure log
    asserts ml64, so a drift stops at configure.
  - On arm64 every assembly path is clang's integrated assembler.
- **Versions.** All pins come from `linux/scripts/01-core/versions.env`; never restate versions
  here (the duplicated tables this section used to carry drifted, e.g. the GenAI/LiteRT-LM labels).
- **Per-library reference** (generator/compiler per component, EP/delegate flags, patch stacks, RAM
  budgets, fallback paths): § Component Build Matrix.
- **Per-script reference** (build/setup/verify and HOST-maintenance scripts, with flags, gotchas
  and refusal conditions; the ones without an entry yet are listed there):
  § Windows Script Reference.
- Build sequence and commands: § Build Commands; container validation: § Smoke Testing.

Update those tables in `docs/windows-builds.md`; this section stays a pointer. The Windows Build
Invariants are agent-behavioral rules, not reference data, so they are not here
([`windows-build-invariants.md`](windows-build-invariants.md)).

## Component Build Matrix

The **authoritative per-library build reference** for the Windows lane
(AGENTS.md § Windows Build Notes points here; update THIS table, never a copy). Versions are pinned
in `linux/scripts/01-core/versions.env`.

| Component | Generator | Compiler | Notes |
|---|---|---|---|
| CPython (pin: `PYTHON_VERSION`) | `PCbuild\build.bat` | ClangCL (v145→ClangCL via Directory.Build.props) | Requires VS ClangCL toolset; built GIL and free-threaded, [details](#the-free-threaded-cpython) |
| ONNX Runtime (pin: `ONNXRUNTIME_VERSION`) | Ninja | clang-cl, lld-link | [details](#onnx-runtime-pin-onnxruntime_version) |
| ONNX GenAI (pin: `ONNXRUNTIME_GENAI_VERSION`) | CMake (Ninja) | clang-cl, lld-link | [details](#onnx-genai-pin-onnxruntime_genai_version) |
| OpenCV 5.x | Ninja | clang-cl, lld-link | [details](#opencv-5x) |
| LiteRT (pin: `LITERT_VERSION`) | Ninja | clang-cl, lld-link | [details](#litert-pin-litert_version) |
| LiteRT-LM (pin: `LITERT_LM_VERSION`) | **Bazel** | clang-cl, lld-link, llvm-lib: Bazel 7's own clang-cl toolchain, proven by an aquery gate (CON92) | [details](#litert-lm-pin-litert_lm_version) |
| ai-edge-litert wheel (pins: `LITERT_VERSION`, `LITERT_WINDOWS_SOURCE_COMMIT`, `LITERT_BAZEL_WINDOWS_*`) | **Bazel** | clang-cl, lld-link, llvm-lib: Bazel 7's own clang-cl toolchain, proven by an aquery gate | [details](#the-ai-edge-litert-wheel) |
| TVM (pin: `TVM_REF`) | Ninja | clang-cl, lld-link | [details](#tvm-pin-tvm_ref) |
| IREE (pin: `IREE_VERSION`) | Ninja | clang-cl, lld-link | Two configures on the arm64 cross lane (§ TVM and IREE in [`windows-cross-builds.md`](windows-cross-builds.md)) |
| HailoRT (pin: `HAILORT_VERSION`) | Ninja | clang-cl, lld-link | Four static patches (§ Source Patch Policy) |
| FFmpeg (pin: `FFMPEG_VERSION`) | MSYS2 `make` (MSVC toolchain) | clang-cl via `--toolchain=msvc` | [details](#ffmpeg-pin-ffmpeg_version) |
| GStreamer (pin: `GSTREAMER_VERSION`) | Meson | clang-cl | Downloaded as tarball + subproject wraps. CUDA auto-detected. |

### Per-component notes

Notes too long for a table cell, one linkable heading each.


#### The free-threaded CPython

The toolchain stage builds `PYTHON_VERSION` twice from one checkout with `PCbuild\build.bat` and the
ClangCL toolset: the GIL build in place, then the same command plus `--disable-gil` (owner request
2026-10-07). Before that, every Windows `3.14t` leg had uv download a python-build-standalone
interpreter.

- **Own trees and prefix.** The free-threaded build writes `PCbuild\freethreaded\amd64` and
  `PCbuild\obj\freethreaded` (`Get-CpythonPcbuildArguments -FreeThreaded`). CPython's own
  `PC\layout --include-freethreaded --include-dev --include-venv --include-stable` installs it into
  `C:\python-freethreaded` (`PYTHON_FREETHREADED_BIN`), 38.7 MB at 3.15.0: `python3.15t.exe`,
  `python315t.dll`, `DLLs\*.cp315t-win_amd64.pyd`, `Lib`, `include` and `libs\python315t.lib`. Its
  `site-packages` starts empty, so the GIL tree's pip, cp315 wheels and `sitecustomize.py` never
  reach it.
- **PATH order picks the build.** `PYTHON_FREETHREADED_BIN` is last on `PATH` and holds no
  `python.exe`: a bare `python`, a `3.15` and a `3.15+gil` request stay on
  `C:\temp\cpython\PCbuild\amd64\python.exe`; only a `3.15t` request finds `python3.15t.exe`.
- **Measured in `:winamd64` on 2026-10-07** (`Build-ToolchainAll.ps1 -SourceDir` on a fresh v3.14.8
  checkout, `UV_PYTHON_DOWNLOADS=never`, two runs, 32 CPUs): the GIL build took 120-207 s with the
  externals download, the free-threaded one 104-124 s. `uv python find 3.14t`,
  `uv venv --python 3.14t` and `New-UvProjectEnvironment -PythonVersion 3.14t` all took
  `C:\python-freethreaded\python3.14t.exe`, and uv's managed store stayed empty without the variable
  too. `uv build --python 3.14t` built a `cp314-cp314t-win_amd64` wheel, `3.14+gil` a `cp314-cp314`
  one.
- **Import libraries.** `Select-CpythonImportLib` gives a GIL caller `python315.lib` and a
  `-FreeThreaded` one `python315t.lib`, never the other; `Get-SourceBuildPython -FreeThreaded`
  returns the install's exe, `include` and `libs`. `PC\pyconfig.h` (3.14 and 3.15) does not define
  `Py_GIL_DISABLED` itself, so an extension built against the install must pass
  `Py_GIL_DISABLED=1`: setuptools does, a hand-written CMake or clang-cl build must too. A clang-cl
  extension built that way imported with the GIL still off.
- **The GIL tree links extensions like an install** (CON93). Right after the GIL build,
  `Install-CpythonInTreeImportLib` copies `python3XY.lib` and `python3.lib` from `PCbuild\amd64`
  into `C:\temp\cpython\libs`. setuptools links an extension against `sys.base_exec_prefix\libs`,
  and its `PCbuild\<arch>` entry follows a venv's prefix, not the tree's. Without the copy, every
  sdist with a C extension failed `LNK1104 python315.lib` in a venv of the image's Python, uv's
  isolated build environments included (probe P13, 2026-10-12); under 3.14 every locked package had
  a cp314 wheel, so nothing hit it. Smoke section 2 checks both files.
- **Checked twice.** `Build-ToolchainAll.ps1` stops unless both interpreters report
  `PYTHON_VERSION`, the `AMD64` marker and their GIL state after the scrub
  (`Assert-CpythonInterpreter`); smoke section 2 checks the free-threaded one again and uv's
  resolution with downloads off. Tests: `SourceBuild.FreeThreadedCpython.Tests.ps1`.
- **The arm64 bundle carries one too.** In media-core, `Build-TargetCpython.ps1` builds the target
  interpreter twice (`Invoke-CpythonPcbuild -Platform ARM64`, `-FreeThreaded`, both with
  `/p:PreferredToolArchitecture=x64`); one function, `Install-CpythonTargetTree`, stages each tree
  right after its own build (tests: `SourceBuild.TargetCpythonTree.Tests.ps1`):
  - **`C:\runtime\python`**: the GIL build, unchanged.
  - **`C:\runtime\python-freethreaded`**: `python3.15t.exe`, `libs\python315t.lib` and the
    stable-ABI `libs\python3t.lib` (IREE's twin needs FindPython's `Development.SABIModule`), no
    `python.exe`, an empty `site-packages` without the DLL-directory shim, and `venvlaunchert.exe`
    and `venvwlaunchert.exe` in `Lib\venv\scripts\nt`, where `PC\layout --include-venv` puts them.
    With no `python.exe` to copy, `uv venv` refuses the tree without them: "Could not find a
    suitable Python executable".
  - **`BUNDLE-ENV`** sets `KATA_PYTHON_FREETHREADED` and appends the tree last to `PATH`.
  - **media-tvm builds both trees too.** The merge takes only media-core's, but TVM's and IREE's
    cross twins link the free-threaded tree's `python315t.lib`
    ([§ The arm64 cross twins](#the-arm64-cross-twins)).
- **Measured in `:winamd64` on 2026-10-07** on a fresh v3.14.8 checkout:
  - The ARM64 GIL build took 65-96 s with the externals fetch, the free-threaded one 67 s.
  - The GIL tree was byte-identical to the old staging code's on the same build output (2792 files
    plus 9 in `bin`).
  - The free-threaded tree: 2793 files, 82.5 MB, every one of its 61 PE files `0xAA64`.
  - The merge stage's arch gate passed with `-ImportWalk` over both trees. It extracts each tree's
    ensurepip `pip-*.whl` into its own directory; the second copy of the same name had made it throw.
  - The same function on an x64 free-threaded build of that checkout gave a tree that ran on the
    host: `uv venv --python 3.14t` with `UV_PYTHON_DOWNLOADS=never` took it, and its venv reported
    `sys._is_gil_enabled()` False.
  - Only `windows-11-arm` can run the ARM64 tree; `Test-Arm64Bundle.ps1` does so on every bundle and
    fails unless the GIL is off.

#### The free-threaded wheels

Every wheel the media stages build, on `:winamd64` and on the arm64 cross lane, gets a
`cp3XY-cp3XYt` twin beside its unchanged `cp3XY` wheel, but only when the package's own code
declares free-threading (owner request 2026-10-07). The twins are built with the interpreter of
[§ The free-threaded CPython](#the-free-threaded-cpython), on the image's VS 2026 and clang-cl.

- **The list is data, shared with Linux.** `Get-FreeThreadedTwinTable` reads
  `linux/scripts/03-media/free-threaded-twins.txt`, the file Linux's `ft_wheel_table` reads, so both
  lanes hold one verdict per distribution. Each row also names the `versions.env` pin its evidence
  was read at, and that evidence; `PythonWheel.FreeThreadedTwin.Tests.ps1` fails when a pin moves,
  so a bump re-reads the evidence.
  - **twin**: `onnxruntime`, `av`, `apache-tvm-ffi`, `iree-base-runtime` and `iree-base-compiler`.
  - **none**: `apache-tvm` (a `py3` wheel with no extension, which an X.Yt venv installs as it is)
    and `torchvision`.
  - **gil**: `onnxruntime-genai`, `ai-edge-litert`, `hailort`, `libcamera` and `opencv`, whose
    modules re-enable the GIL.
  - **Where the file is.** The three twin RUNs of `Dockerfile.media-builder` mount it at
    `C:\bkmnt\free-threaded-twins.txt`, one level above `modules\` as the helper is; the final image
    bakes it into `C:\temp\scripts`, where section 20 reads it. A missing table throws, never reads
    as an empty list.
- **A separate store.** The twins go to `C:\runtime\wheels-free-threaded`
  (`PYTHON_WHEELS_FREE_THREADED`, as on Linux; images before CON91 named it `wheels-cp314t` /
  `PYTHON_WHEELS_CP314T`, which every reader still takes), never into `PYTHON_WHEELS`, and
  `Save-PythonWheel` refuses a `cp3XYt` wheel there. An X.Yt venv can be given both stores: pip and
  uv take only `cp3XYt` and `py3-none` wheels on that interpreter. `Sync-UvChainOnnxRuntime` reads
  the twins' store for a `cp3XYt` venv
  ([`python-ci.md` § Free-threaded and GIL legs](python-ci.md#free-threaded-and-gil-legs-in-one-container)).
- **Nothing installs into `C:\python-freethreaded`.** Its `site-packages` stays empty, as the
  interpreter's contract says; a consumer installs the twins into a venv. The GIL interpreter is
  unchanged.
- **One path per twin.** Each build script asks `Get-FreeThreadedTwinPlan`, which skips, with a log
  line, a non-twin row and a cross lane without a target CPython. It throws when a twin is due but
  the image has no free-threaded install: the host's interpreter, or the `python3XYt.lib` the twin
  links (the target tree's on a cross lane).
  - `New-FreeThreadedBuildPython` makes a uv venv of `C:\python-freethreaded` holding the GIL build
    interpreter's versions of the build tools.
  - `Invoke-PythonWheelBuild -FreeThreaded` builds with it; `Save-FreeThreadedWheel` stores the one
    `cp3XYt` wheel after checking the tags (`Get-FreeThreadedWheelFinding`: the name, the target's
    platform, every tagged `.pyd`) and the imports (`Get-FreeThreadedWheelImportFinding`: a `.pyd`
    that imports a Python runtime imports `python3XYt.dll`, and at least one does).
  - Then `Invoke-FreeThreadedWheelVenvProof` installs the wheel alone, offline, into a fresh venv
    and runs `linux/scripts/02-toolchain/python/free-threaded-wheel.py prove`, the helper the Linux
    lane runs. The proof venv's `sitecustomize.py` registers the image's DLL homes
    (`Get-PythonDllHome`, the list of the image's own shim) and the wheel's own DLL directories,
    which the package's `__init__` would load first.
- **`Py_GIL_DISABLED` is the build's job** (`pyconfig.h` leaves it undefined on Windows,
  § The free-threaded CPython). CMake 4.4's FindPython adds it to `Python::Module` when the
  interpreter it runs is free-threaded. ONNX Runtime only logs it, so
  `Assert-NinjaFreeThreadedDefine` checks `build.ninja` before the ORT and IREE twins compile.
- **No `win32` tag.** The clang-built X.Yt keeps the `AMD64` marker in `sys.version`, so
  `sysconfig`, setuptools and `packaging` all report `win-amd64` without the GIL tree's platform
  shim (measured on 3.14t 2026-10-07; `sys.version` and `sysconfig` on 3.15t 2026-10-19). The tag
  check still refuses any other platform.

How each twin is built:

- **A re-configured tree must settle first.** CMake 4.4's Ninja generator writes `\` paths into
  `build.ninja` on a tree's first configure and `/` on every later one, so a twin that re-configured
  the GIL tree changed every command line and ninja recompiled all 1474 ORT edges.
  `Invoke-CmakeConfigure -Settle` configures the GIL pass twice when a twin will follow, so both
  passes compile with one spelling.
- **ONNX Runtime** re-configures the GIL tree with the venv's Python and rebuilds only
  `onnxruntime_pybind11_state`:
  - `Update-OrtNinjaFile` re-applies the `build.ninja` edits a configure discards.
  - `Set-OrtNinjaCommandPython` keeps the GIL interpreter in the custom commands, so `gen_def.py`
    does not re-run and relink `onnxruntime.dll`.
  - `Get-WheelMemberDifference` then requires every DLL in the twin to be byte-identical to the GIL
    wheel's, so both wheels are one build. Without the two steps above it failed on
    `onnxruntime.dll` and `onnxruntime_providers_shared.dll`.
- **PyAV** runs the same sdist's `setup.py --ffmpeg-dir` with the venv, in a fresh `build\`
  (`Invoke-FreeThreadedTwinWheel`).
- **apache-tvm-ffi** is packed from TVM's vendored `3rdparty/tvm-ffi` with `pip wheel` in its own
  scikit-build directory, by the same function. Its GIL side still installs in place, so the twin is
  the only tvm-ffi wheel the image ships.
- **IREE** re-configures its tree for the venv (`Get-IreeFreeThreadedCmakeArgs`); the shipped
  `C:\runtime\iree` stays the GIL pass's.
  - `IREE_ENABLE_PYTHON_STABLE_ABI=OFF` and `MLIR_ENABLE_PYTHON_STABLE_ABI=OFF`: upstream turns abi3
    on unless `SOABI` starts `cpython-NNt` (`CMakeLists.txt:782-791`), Windows' is
    `cp3XYt-win_amd64`, and X.Yt loads no abi3 module.
  - `-UNB_SUFFIX -UNB_SUFFIX_S`: nanobind caches the GIL pass's `.cp3XY-win_amd64.pyd`, which X.Yt
    never imports.
  - `ninja -t cleandead` and a fresh `build\` beside each `setup.py`: the GIL pass's bare abi3
    `_runtime.pyd` is no output any more, and left in place it went into the twin, where it failed
    to load (`python3.dll`).

**The ORT census takes the twin as a chain artifact.** `Get-OrtChainWheel -Abi gil|free-threaded`
matches only its own store's ABI, and `Get-OrtChainReferenceWheel` gives the image census and
`Test-OrtProvenanceTree` both wheels as references. The image census also keeps the twins' store a
home and scans `C:\python-freethreaded` ([`onnxruntime-single-source.md`](onnxruntime-single-source.md)).

**Checked in the image.** Section 20 of `Test-Container.ps1` requires one wheel per twin in the
store, each with the right tags, no `cp3XYt` wheel in `PYTHON_WHEELS` and an empty free-threaded
`site-packages`, and proves every twin again with the image's copy of the helper in
`C:\temp\scripts`. Tests: `SourceBuild.FreeThreadedTwin.Tests.ps1`,
`PythonWheel.FreeThreadedTwin.Tests.ps1` and the twin cases of `Smoke.OrtCensus.Tests.ps1`.

**Measured in `:winamd64` on 2026-10-07**, the published image of 2026-10-04 with a
`C:\python-freethreaded` built by `Build-ToolchainAll.ps1` from v3.14.8 (213 s for both CPython
builds):

- **ONNX Runtime v1.30.0**: GIL ninja 425-614 s on a shared host, twin pass 59.6 s. Fourteen
  compile lines carried `Py_GIL_DISABLED=1`, and the proof loaded one module with the GIL off.
- **PyAV 19.0.1** on the image's FFmpeg: 50 modules proved. **apache-tvm-ffi** at `daf594da`: one
  module, 100 s.
- **IREE v3.12.0**, runtime-only tree (`IREE_BUILD_COMPILER=OFF`): GIL pass 59 s, twin 20 s over 68
  ninja edges, one module proved.
- **IREE v3.12.0 with the compiler** and its in-tree LLVM, `Build-IreeFromSource.ps1` unchanged
  (`-j20` beside a Linux IREE build; 166 s for both CPython builds):
  - GIL pass: configured twice in 114 s, 8696 ninja edges in 23 min 9 s; the install, the native
    gate and both `cp312-abi3` wheels took 48 s more.
  - Twin pass: 94 s (configure 53 s, ninja 21 s over 137 edges, then both wheels packed and proved).
    80 of those edges reach Python: `nanobind-ft-mlir.dll`, MLIR's and IREE's bindings, the 14
    `.cp314t-win_amd64.pyd` modules. The other 56 follow the VM ISA genrule, whose command names
    `Python3_EXECUTABLE`, so it re-runs for the venv and relinks `IREECompiler.dll` and the tools;
    they differ from the GIL wheel's only in the COFF `TimeDateStamp`.
  - `prove` loaded all 13 compiled modules of `iree-base-compiler`, the MLIR nanobind ones included,
    and the one of `iree-base-runtime` with the GIL off.
  - In a 3.14t venv with the wheels' `Requires-Dist` (`numpy`, `ml_dtypes`, `sympy`),
    `iree.compiler` and `iree.runtime` import with the GIL off. `compile_str` plus `local-task` ran
    in eight threads at once, and the twins' `iree-compile` and `iree-run-module` gave
    `abs(-5) = 5`. The GIL wheels pass the same gate on the GIL interpreter.
  - The twin's configure logs `CMake IGNORED` for `IREE_ENABLE_PYTHON_STABLE_ABI` and the Python
    hints, yet all of them take effect: upstream declares the ABI switch only while it is unset, so
    the untyped `-D` stays `UNINITIALIZED`; the cache holds it `OFF`, and the twin has no abi3
    module.
- **A module that declares nothing about the GIL is refused**: a one-function `setup.py` extension
  failed with `the GIL was re-enabled, first by gilmod._c`, and nothing reached the store.
- **The ORT census over both stores** was clean with both wheels as references. With the GIL wheel
  alone, as before this change, the twin's `onnxruntime_pybind11_state.pyd` read as `STALE`.
- **IREE v3.12.0 needed two fixes on clang-cl, twin or not**: its VM ISA genrules run a bare
  `python3`, which no Windows image has, so `Build-IreeFromSource.ps1` points them at
  `Python3_EXECUTABLE`; its profile statistics sink divides 128-bit integers, so every IREE link gets
  compiler-rt's `clang_rt.builtins-<arch>.lib` (`Get-IreeCompilerRtCmakeArgs`).

**Not yet:** the ROCm lane's torch twin.

#### The arm64 cross twins

The arm64 cross lane builds the same twins for `win_arm64` since 2026-10-07 (CON79): `onnxruntime`,
`av`, `apache-tvm-ffi` and `iree-base-runtime`; with no IREE compiler built, there is no
`iree-base-compiler` wheel to pair. The host's x64 3.15t runs every build, and each module links the
target tree's `C:\runtime\python-freethreaded\libs\python315t.lib`
([§ The free-threaded CPython](#the-free-threaded-cpython)).

- **The venv names its modules for the target.** `New-FreeThreadedBuildPython` takes its link
  inputs from `Get-TargetBuildPython -FreeThreaded` and, on a cross lane, writes the platform shim
  into the venv's `site-packages` after uv installs the build tools. The shim pins `EXT_SUFFIX` to
  `.cp315t-win_arm64.pyd` (it keeps the `t` when `Py_GIL_DISABLED` is set, the one formula the GIL
  build interpreter's shim uses too); `get_platform()` stays the host's.
- **`--plat-name win_arm64`.** `Invoke-PythonWheelBuild -FreeThreaded` adds it to a `bdist_wheel`
  on a cross lane, as `-CrossStage` does for the GIL wheel. The IREE twin packs with
  `setup.py bdist_wheel` there, since `pip wheel` takes no platform.
- **PyAV links with `-L <target libs>`.** setuptools puts `C:\python-freethreaded\libs` on the link
  line too, and its x64 `python314t.lib` came first: `LNK2001: __imp_PyModuleDef_Init` (measured
  2026-10-07). `build_ext -L` puts the target's first.
- **ORT and IREE re-apply the lane's `build.ninja` edits** after the twin's re-configure (ORT's
  per-TU MLAS flags with `-Cross`, IREE's arm_64 ukernel flags, `Update-IreeCrossNinjaFile`). A
  configure drops them; without them the twin would recompile those objects and ORT would relink
  `onnxruntime.dll`, which the byte-for-byte check refuses.
- **tvm-ffi** is assembled for the target as its GIL wheel is (`New-TvmFfiCrossWheel`, one function
  for both): its own tvm-ffi tree, the Cython core linked against `python315t.lib`, and
  `Assert-NinjaFreeThreadedDefine` before ninja. `apache-tvm`'s assembled wheel is now
  `py3-none-win_arm64`, as upstream's `wheel.py-api = "py3"` builds it, so an X.Yt venv installs it
  too; it was tagged `cp314-cp314` before, which no 3.14t venv takes.

**Proved statically on the build host, on the device by the bundle gate.** No ARM64 module loads on
the x64 host, so `Save-FreeThreadedWheel` runs no venv proof on a cross lane. It stores a twin after
three static gates instead: the tags (`cp3XY-cp3XYt`, `win_arm64`, every tagged `.pyd`
`.cp3XYt-win_arm64.pyd`), the imports (every module imports `python3XYt.dll`, never
`python3XY.dll` or `python3.dll`), and `Assert-WheelTargetArch` (every PE member `0xAA64`).

- **The merge** checks the store twice. `Write-BundleManifest.ps1` refuses a cross bundle unless
  every twin-verdict GIL wheel in `C:\runtime\wheels` has exactly one tag-clean twin of its version,
  and no twin lacks its GIL wheel (`Get-FreeThreadedStoreFinding`); smoke section 20, which checks
  that on `:winamd64`, cannot run a cross bundle. `Test-TargetArch.ps1 -ImportWalk` machine-checks
  every wheel's native members, which it only walked before, and fails a `cp3XYt` wheel module that
  imports a GIL runtime. The bundle ships both runtimes, so the walk alone resolves either.
- **The device.** `Export-Arm64Bundle.ps1` puts `free-threaded-wheel.py` beside
  `Test-Arm64Bundle.ps1`. The gate installs each twin offline into a `python3XYt.exe -m venv`, with
  its dependencies from `deps\` (below), and runs `free-threaded-wheel.py prove`, with the bundle's
  DLL homes registered in the venv's `sitecustomize.py`. A bundle without `deps\` gets each twin
  alone (`--no-deps`), as before 2026-10-11.
- **What only the device proves:** that the ARM64 modules load and keep the GIL off. A module that
  declares nothing passes every static gate and fails only there.
- **Their dependencies sit in `wheels-free-threaded\deps`** (CON79, in source since 2026-10-11).
  After the GIL store, `Copy-TargetPythonDeps.ps1` reads each twin's `Requires-Dist` and downloads
  the requirements for the target as `cp3XYt` or ABI-free wheels, never `abi3`, which the
  free-threaded ABI cannot load. Today: numpy and ml_dtypes as `cp315t-win_arm64`, plus flatbuffers,
  packaging, protobuf and typing-extensions as pure wheels. It fails when a downloaded wheel carries
  another ABI, or when a twin's or a dependency's requirement resolves in neither directory. The
  store's top keeps the twins alone, which the mirror gate reads; a consumer installs a twin offline
  with `--find-links` on both directories.
- **`deps\` also holds the `cp3XYt` wheels PyPI lacks for the target** (CON111): psutil 7.2.2 ships
  `cp313t`/`cp314t` `win_arm64` wheels and no `cp315t` one, and OrchestrANT's and WebDavClient's
  free-threaded device legs lock it. `Build-TargetSdistWheel.ps1` builds it in the merge, before the
  gate above, from the sdist pinned by `PY_PSUTIL_SDIST_SHA256`. setuptools' compiler runs copies
  of clang-cl, lld-link and llvm-lib named `cl`, `link` and `lib` (as the torch stage's sdists do),
  and `CL` carries `--target=aarch64-pc-windows-msvc` and `/clang:-fcommon`: psutil's headers define
  their function pointers in every object, which `cl` merges and clang rejects as duplicates. The
  wheel passes the twins' three static gates, and fails when a member carries MSVC's Rich header.

**Measured in `:winarm64` on 2026-10-07**, the published image of 2026-10-04 with an x64 3.14t built
from v3.14.7 (104 s) and the ARM64 trees of this checkout's `Build-TargetCpython.ps1` (212 s for
both). Each script ran unmodified with `versions.env`'s pins; PyAV ran its script's own wheel section
against the image's ARM64 FFmpeg. The twin pass is the time from the GIL wheel to the stored twin:

- **PyAV 19.0.1**: 107 s, 50 modules `.cp314t-win_arm64.pyd`. **apache-tvm-ffi** `0.1.14.post0`:
  72 s, a bare `core.pyd` that imports `python314t.dll`.
- **ONNX Runtime v1.30.0**: GIL ninja 427 s, twin 90 s; its four DLLs were byte-identical to the GIL
  wheel's. Fourteen compile lines carried `Py_GIL_DISABLED=1`.
- **IREE v3.12.0 runtime**: 36 s over 68 ninja edges, none of them an arm_64 ukernel;
  `_runtime.cp314t-win_arm64.pyd`. The first run stopped at configure
  (`Could NOT find Python3 (missing: Python3_SABI_LIBRARIES)`): the target tree held no
  `python3t.lib`, which `Install-CpythonTargetTree` stages now.
- **Every member of the four twins is `0xAA64`, and every module imports `python314t.dll`.** The
  merge gates over the resulting tree: the manifest's store check passed with 4 twins for 4
  twin-verdict GIL wheels; the arch gate inspected 1275 binaries with 0 violations and 0 unresolved
  imports; 53 modules in 4 `cp3XYt` wheels imported their runtime. Over the published bundles the
  arch gate's new wheel-member check found nothing: 1000 → 1124 inspected on `:winarm64`, 982 → 1074
  on `:winamd64`, 0 violations each.
- **The device step**, run on the x64 3.14t there: a module declaring `Py_MOD_GIL_NOT_USED` passed
  in 4.8 s, one declaring nothing failed with `the GIL was re-enabled, first by gilneed`, and a
  missing helper stopped the step.
- **A GIL module dressed as a twin** (`ftmod.cp314-win_arm64.pyd` in a `cp3XYt` wheel) failed the
  tag gate, and the import gate named `python314.dll`. Without `-L`, the cross PyAV-style link
  failed `LNK2001: __imp_PyModuleDef_Init`.

#### ONNX Runtime (pin: `ONNXRUNTIME_VERSION`)

**Both lanes.** On `-TargetArch arm64`: TensorRT is OFF, CUDA is ON only when the image carries the
arm64 CUDA payload (`-Gpu`, #176, 2026-09-20), the Python bindings are ON since #120 step 2, and
DirectML is **ON** as of backlog #113 ([`windows-cross-builds.md`](windows-cross-builds.md)).

- **DirectML EP enabled** (`USE_DML=ON`) via the 3-part clang-cl source patch
  `003-dml-clangcl-compat.patch` (§ Source Patch Policy): DirectMLHelpers incomplete-type
  out-lining, `.##Z` token-paste, `Dispatch<size_t>`. The EOL/context-tolerant inline regex patcher
  `Invoke-OnnxDmlClangClPatch` in `Build-OnnxFromSource.ps1` remains as the drift fallback.
- **CUDA + TensorRT EPs** when the NVIDIA layer is the parent (CUDA provider at `CUDA_VERSION`,
  with the crt/ workaround for nvcc).
- Patches build.ninja for the MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM
  (`.asm` files).
- **AVX-512/AMX: per-TU only.** Global flags stay OFF: they crashed protoc AND ort's own DLL init at
  runtime on AVX2 hosts. The build script appends them post-configure to MLAS's runtime-dispatched
  arch TUs in build.ninja (`Get-WindowsTargetKernelSimdFlags -Arch`) and logs the tagged count. The
  old `Get-WindowsX86Avx512Flags` compat shim was deleted 2026-08-26; the amd64 TU pattern was
  extended 2026-08-24 after under-matching broke the lane, and the tagged-count floor raised 4→8.
  Don't "simplify" in either direction (AGENTS.md § Windows Build Invariants).
- 1.28's `ScopedResource<INVALID_HANDLE_VALUE,...>` template arg (rejected by clang-cl) is bridged
  by an inline post-configure dep patch.
- Needs ~4 GB RAM/job; media-core runs with `--memory ${MediaMemoryGb}g`.

#### ONNX GenAI (pin: `ONNXRUNTIME_GENAI_VERSION`)

Source-built directly via CMake, bypassing `build.py` (which always builds examples).

- **DirectML enabled** (`USE_DML=ON`, on **both lanes** since #118, 2026-08-24), compiled straight
  into `onnxruntime-genai.dll` with 0 source patches (`src/dml` is clang-clean). The
  `D3D12Core.dll` staged beside the DLL is resolved through a **target-derived** filter (x64 on
  amd64, arm64 on the cross lane), not a hardcoded x64.
- **CUDA enabled** (`USE_CUDA=ON`): a separate `onnxruntime-genai-cuda.dll`. CUDA and DML are
  independent CMake blocks, so they coexist.
- `-DENABLE_TELEMETRY=OFF`: 0.15 defaults MS 1DS telemetry ON, and its bundled zlib also breaks
  clang-cl under -Werror.
- VsDevCmd environment loaded for MSVC STL headers.

**ONNX Runtime: the chain's, never NuGet's (owner rule 2026-09-23).** Upstream `cmake/ortlib.cmake`
has two branches:

- **No `ORT_HOME`**: it downloads an ORT NuGet package with no hash
  (`Microsoft.ML.OnnxRuntime.DirectML` 1.24.4 from the aiinfra ORT-Nightly feed at v0.15.2, a NuGet
  restore into `__nuget` since v0.17.0) and compiles GenAI and onnxruntime-extensions against it.
  The image built that way until 2026-09-23.
- **With `ORT_HOME`**: it takes the headers and library from there. `ortlib.cmake` wants
  `ORT_HOME\include\onnxruntime_c_api.h` and `ORT_HOME\lib\onnxruntime.dll`, while the chain
  installs its headers flat under `include\onnxruntime\` and its DLL under `bin\`.

So `New-GenaiOrtHome` copies them into `<src>\ort-home\{include,lib}`, and configure gets
`-DORT_HOME:PATH=<shim>` (typed, because `ortlib.cmake` reads the variable without declaring it)
plus `-DFETCHCONTENT_SOURCE_DIR_ORTLIB` and `-DFETCHCONTENT_SOURCE_DIR_ONNXRUNTIME` pointing at an
empty `ort-fetch-blocked` dir. If GenAI or onnxruntime-extensions (a GitHub 1.19.2 zip) ever falls
back to a download, configure fails; CMake's "Manually-specified variables were not used" for the
two is expected. The configure log is teed to `onnx-genai-configure.log`, not discarded.

- `Get-GenaiOrtConfigureFinding` requires the shim in the log and in `CMakeCache.txt`,
  `-I<shim>/include` on every GenAI compile and `-LIBPATH:<shim>/lib` on every `onnxruntime.lib`
  link in `build.ninja`.
- `Get-GenaiOrtTreeFinding` runs after configure and after the build: chain bytes under every chain
  ORT file name, no ORT archive or FetchContent ORT dir, and no ORT file in the install dir. Its
  post-build findings throw through the ORT build gate.
- The DLL now needs an ONNX Runtime at least as new as the chain at run time, and
  `ORT_GENAI_HAS_MODEL_PACKAGE` code is compiled on Windows for the first time.
- Suite: `SourceBuild.GenaiOrt.Tests.ps1`.

**Still fetched, and not ORT:** `DirectML.h` and `D3D12Core.dll` come from GenAI's own
`Microsoft.AI.DirectML` 1.15.2 and `Microsoft.Direct3D.D3D12` 1.614.1 packages from nuget.org,
without a hash. Since v0.17.0 they are a NuGet restore into `<build>\__nuget\` (`cmake/nuget.cmake`)
by the `nuget.exe` the base image's scoop installs, which configure now requires on `PATH`
(`find_program(NUGET_PATH ... REQUIRED)`); `D3D12Core.dll` is staged from there, and the `_deps`
match covers the older layout. The `RESTORE_PACKAGES` dependency-drop patch still matches nothing
(upstream writes `add_dependencies(${ORTGENAI_COMPILE_TARGET} RESTORE_PACKAGES)`), so
`Microsoft.Direct3D.DXC` is restored too, from nuget.org now that the ORT-Nightly `nuget.config` is
gone. Hash-pinning these restores is an open follow-up.

#### OpenCV 5.x

Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2 (amd64 only; empty on arm64 by design). CUDA
auto-detected. Custom `CMAKE_AR` path fix. ONNX Runtime: the chain's on every lane, through a
nested-header shim with `HAVE_ONNXRUNTIME` pre-set, so there is no configure-time download, and
G-API's ONNX DirectML EP is compiled in. `Get-OpencvOrtConfigureFinding` gates both after configure
([`onnxruntime-single-source.md` § OpenCV on Windows](onnxruntime-single-source.md#opencv-on-windows-the-shim-the-hook-and-the-gate)).

The chain's FFmpeg (`OPENCV_LINK_CHAIN_FFMPEG=1`): OpenCV runs `find_package(PkgConfig)` only on
UNIX, so on Windows its videoio pkg-config route never fires and it downloads its own prebuilt
FFmpeg. `patches/opencv/pkgconfig-shim.cmake`, injected through `CMAKE_PROJECT_INCLUDE`, runs that
probe. It works only together with `-DOPENCV_FFMPEG_SKIP_DOWNLOAD=ON`,
`-DOPENCV_FFMPEG_ENABLE_LIBAVDEVICE=ON` and the `Get-Ffmpeg9AvcodecConfig.ps1` source patch;
`SKIP_DOWNLOAD` alone leaves `FFMPEG: NO`. Verify with CMake's own `pkg_check_modules`, not a shell
`pkg-config`, which can say yes while OpenCV still configures without FFmpeg.

#### LiteRT (pin: `LITERT_VERSION`)

GPU delegate enabled (Vulkan + OpenCL backends). XNNPACK enabled. CUDA paths exposed for external
delegate. Also builds the TFLite **C-API** shared lib `tensorflowlite_c` (target injected into the
main build, `WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) that gst-plugins-bad's
tflite plugin links.

#### LiteRT-LM (pin: `LITERT_LM_VERSION`)

On-device LLM inference, built by `Build-LitertLmBazel.ps1` → `litert_lm_main.exe`, through the
smoke-RUN gate.

- **Bazel**: the pinned `LITERT_LM_BAZEL_WINDOWS_VERSION`, which must equal the clone's
  `.bazelversion`, plus Temurin JDK. `bazel build //runtime/engine:litert_lm_main --config=windows`
  runs on Bazel's own clang-cl toolchain, the recipe of § The ai-edge-litert wheel. An aquery gate
  after the build throws on any action that is not clang-cl, lld-link or llvm-lib.
- `OPENVINO_NATIVE_DIR` names an empty dir, so LiteRT-LM's WORKSPACE no longer downloads the
  unhashed 744 MB OpenVINO nightly, which `litert_lm_main` never uses.
- `--output_user_root=C:\bzl-user` keeps bazel's install base out of the profile, so the cleanup
  removes it with the rest (CON92).
- Probe LM2 (2026-10-13): 5244 actions in 539 s, all 3829 compile, link and archive actions on LLVM
  tools, `--help` OK.
- Bazel is the only path Google CI-tests, so it survives version bumps. Its actions are cached on
  the host's dufs, as the wheel's are (§ The ai-edge-litert wheel).
- The old CMake export-bridge path (`Build-LitertLmFromSource.ps1`, 5 condition-gated
  self-retiring patches for v0.14's never-functional OSS CMake export, § Source Patch Policy #7) is
  a **frozen fallback**.

#### The ai-edge-litert wheel

PyPI has no `ai-edge-litert` wheel or sdist for cp315, so the media-litert stage builds it for the
pinned Python (owner decision 2026-10-12, CON91): upstream's own target
`//ci/tools/python/wheel:litert_wheel` at `LITERT_VERSION`, by `Build-LitertWheelBazel.ps1` in the
stage's second RUN. That RUN follows the LiteRT/LiteRT-LM one, so a wheel edit never re-runs them.
Its actions are cached on the host's dufs
([`windows-build-resources.md` § Bazel's cache](windows-build-resources.md#bazels-cache)).

- **Compiler.** Bazel 7's built-in clang-cl toolchain from `C:\llvm-patched`
  (`Get-BazelClangClArg`): `BAZEL_LLVM`, `--compiler=clang-cl`,
  `--extra_toolchains=@local_config_cc//:cc-toolchain-x64_windows-clang-cl`, and TF's
  `x64_windows-clang-cl` platform as target, host and execution platform. After the build,
  `Assert-BazelActionCompiler` reads an aquery and throws on any action that is not `clang-cl`,
  `lld-link` or `llvm-lib`. No shipped PE may carry MSVC's Rich header. `--linkopt=/DEBUG:NONE`
  drops the PDBs LiteRT's `.bazelrc` asks for; lld-link honours the last `/DEBUG` (probe P4).
- **Python.** Bazel's hermetic Python is the image's own CPython: a `PC\layout` copy, tarred and
  handed to rules_ml_toolchain through `HERMETIC_PYTHON_URL/SHA256/PREFIX/VERSION`. Its `@pypi`
  closure is numpy, setuptools and wheel, hash-pinned in
  `windows/scripts/patches/litert/requirements_lock_<X>_<Y>.txt` at the `PY_*` pins (probe P5b).
  - At v2.2.0, TF's rules_python ran its own pinned pip (24.3.1), which dies on 3.15's `typing`
    (probe P5). `@pypi__pip` stays overridden with CPython's `ensurepip` wheel, so the pip comes
    from the image too; the driver logs which pip it replaced (26.0.1 at v2.3.0).
  - Since v2.3.0, LiteRT pins rules_python 2.2.0 itself, which takes `base_urls`, while
    rules_ml_toolchain's `HERMETIC_PYTHON_URL` branch still passes `base_url` and fails the
    WORKSPACE. Patch `003` adds a fix for rules_ml_toolchain to LiteRT's own
    `litert_workspace.bzl`.
- **No floating fetch.** `@litert_prebuilts`, upstream's `latest` zip, is overridden with a local
  repo holding only `libLiteRtWebGpuAccelerator.dll`. That DLL is closed source and comes from the
  pinned PyPI wheel (`LITERT_WINDOWS_ACCELERATOR_WHEEL_*`), checked against
  `LITERT_WINDOWS_WEBGPU_ACCELERATOR_SHA256`. `OPENVINO_NATIVE_DIR` names an empty directory, so
  the unhashed OpenVINO nightly is never downloaded (744 MB, probe P5b). Patch `001` drops the two
  OpenVINO plugins, which the wheel cannot ship. Every other external comes from upstream's
  WORKSPACE with its sha256 (probe P6: 175 repos fetched, none unhashed).
- **Source fixes.** Upstream's post-fetch rewrites for MSVC's STL, which clang-cl shares, run
  throw-on-miss in `Invoke-LitertExternalRewrite`: absl's `std::source_location` off, protobuf's
  java `field_common.h`, `UntypedMessage` held by `unique_ptr`, the protoc objc/rust generators
  dropped, and highwayhash's alignment as a leading `__declspec(align)`. Patch `002` puts
  `backports.strenum` behind `python_version<"3.11"`, where it is imported. snappy takes
  `_bzhi_u32` whenever `_MSC_VER` is set, and clang-cl wants the target feature, so snappy alone
  gets `-mbmi2`; the AVX2 floor already implies BMI2.
- **Measured (probe P12, 2026-10-12, 32 CPUs):** the production driver on the 3.15 toolchain image.
  The bazel build took 272 s from 5619 actions, all 4522 compile, link and archive actions on LLVM
  tools. The whole RUN took 530 s, and the work tree reached 6.0 GB before the cleanup removed it.
- **Measured at v2.3.0 (probe `probe-litert-230`, 2026-10-13):** the same driver, with the Pester
  suite running beside it. The bazel build took 390 s from 5655 actions, all 4545 compile, link and
  archive actions on LLVM tools, and the rewrites moved 21 `HH_ALIGNAS` lines. The whole RUN took
  799 s and peaked at 6.2 GB. v2.3.0 brings its own absl 20260526.0 and protobuf 6.31.1 (v2.2.0
  took TF's 20250814.1 and 33.6); every rewrite anchor is still there.
- **Gates.** The wheel must be `ai_edge_litert-<version>-cpXY-cpXY-win_amd64.whl`, hold the four
  `_pywrap_litert_*` extensions, have `pywrap_litert_common.dll` import `pythonXY.dll`, carry the
  pinned accelerator and no OpenVINO vendor dir, and no PE may import an ONNX Runtime. A CPU smoke
  then runs `simple_floor_op.tflite` through the `Interpreter` and `CompiledModel` APIs.
- **Cross.** The arm64 lane leaves the store empty with an ABSENT marker: upstream has no
  windows-arm64 config.

#### TVM (pin: `TVM_REF`)

Auto-detects CUDA/Vulkan. Builds a Python wheel. VsDevCmd environment loaded for MSVC STL headers.

- **LLVM on amd64**: TVM links the llvm-config first on PATH, the toolchain's patched LLVM
  (`C:\llvm-patched`, `AArch64;X86`), so TVM's LLVM `nvptx` target is absent on the nvidia lane
  too; the CUDA source codegen does not need it.
- **The #47 heal** builds a minimal LLVM from the pinned llvm-project source (DIA off, RTTI on, no
  xml2/zlib/zstd, `USE_LLVM=<path>/llvm-config.exe`, SHA from `Get-LlvmSourceSha256` /
  `LLVM_WINDOWS_SRC_SHA256`). It runs in two cases only: when PATH has no llvm-config
  (`-StockLlvm`: `X86;AArch64;NVPTX`, ~6 min sccache-warm), and on the rocm lane's `TVM_ROCM=1`
  spike, whose PATH LLVM lacks AMDGPU (`X86;AArch64;NVPTX;AMDGPU`; built on the 2026-09-25 rocm
  run, inside a 2:55:07 media-tvm stage, its own share unmeasured;
  [`windows-rocm.md` § IREE and TVM](windows-rocm.md#iree-and-tvm-on-the-rocm-lane)).
- The arm64 cross lane builds runtime-only with no LLVM (#116).

#### FFmpeg (pin: `FFMPEG_VERSION`)

Source build from the pinned release tag (`FFMPEG_VERSION` in `versions.env`; a release TAG since
2026-08-04, previously tracked `master`).

- `--enable-libonnxruntime` links FFmpeg's DNN filter against the source-built ONNX Runtime, so ONNX
  models can run inside `ffmpeg` filters. DNN filters ship with the backend; there is no separate
  `--enable-dnn` flag.
- **x86asm ENABLED on amd64 since 2026-08-24** (#119): nasm-assembled x86 SIMD via `--x86asmexe`.
  The old unconditional `--disable-x86asm` had no recorded reason. Proven the same evening:
  configure names nasm as the x86 assembler, 154 `X86ASM` objects linked under lld-link.
- The arm64 cross lane keeps `--disable-x86asm` explicitly (an x86-only knob) and assembles its
  NEON kernels through clang's integrated assembler.
- A failed source build **fails the stage** (fail-closed since #68). Only `FFMPEG_ALLOW_PREBUILT=1`
  opts into a BtbN pre-built GPL binary, never on the cross lane; it scrubs the prefix first and
  sets the sentinel `FFMPEG_SOURCE_BUILD=0`.

## Prerequisites

**Provisioning a FRESH machine?** Follow the ordered checklist in
[Fresh Windows Host Bring-Up](windows-host-setup.md): it sequences everything on this page
(Stevedore install, CNI conf, debug flags, GC policy, Defender exclusions, dufs/sccache, gate
tooling) into one admin/non-admin-marked path with a verify command per step. After the interactive
steps, the scriptable half is one elevated `Install-NewHost.ps1` run.

Install [Stevedore](https://github.com/slonopotamus/stevedore):

```pwsh
# WinGet (recommended)
winget install stevedore

# WinGet — custom install directory (e.g. D: NVMe dev drive)
winget install stevedore --custom="INSTALLDIR=D:\Stevedore"

# or Chocolatey
choco install stevedore
```

With a custom `INSTALLDIR`, substitute `D:\Stevedore\bin\docker.exe` for
`"%ProgramFiles%\Stevedore\bin\docker.exe"` in all commands below.

Reboot after installation: it enables the Windows Containers feature and adds your user to the
`docker-users` group.

**Tool roles on this host.** Stevedore's bundled `docker.exe` publishes, inspects and runs images;
Docker Engine provides NAT networking natively, no CNI plugin needed. Since 2026-08-03 the CNI `nat`
**conf** (`C:\Program Files\containerd\cni\conf\0-containerd-nat.conf`; the `nat.exe` binary always
shipped in `...\cni\bin`) is installed on this host
([`windows-build-lanes.md`](windows-build-lanes.md) § Getting it going, step 2, including the
subnet-drift trap), so containerd-side networking works too and `nerdctl` (admin shell) runs the
`bk-*` images. Historical: before the conf, `nerdctl run` failed with `needs CNI plugin "nat"` and
`nerdctl build` had broken DNS.

| Tool | Build | Run |
|------|-------|-----|
| `"D:\Stevedore\bin\docker.exe"` (non-admin) | — (the classic lane, retired 2026-08-26) | ✅ Works (NAT + DNS + process isolation) |
| `buildctl` via `windows\Build-Buildkit.ps1` (non-admin) | ✅ preferred lane | n/a |
| `nerdctl` (**admin shell only**) | ✅ Works (verified 2026-08-07) — but the chain still uses `buildctl` on purpose, see [`windows-build-lanes.md`](windows-build-lanes.md) § nerdctl lane | ✅ Works — needs the CNI nat **conflist**, see [`windows-build-lanes.md`](windows-build-lanes.md) § nerdctl lane |

## Build Commands

**Use the BuildKit/containerd lane**, the only one since the docker-classic driver
`windows/build.ps1` went (§ The Windows lane as AGENTS.md carried it).
`.\windows\Build-Buildkit.ps1 -Gpu` builds the Dockerfiles with **process isolation** (full host
CPUs, no Hyper-V 2-CPU cap, no run+commit) and real per-stage layer caching. One-time host setup +
launch: [`windows-build-lanes.md`](windows-build-lanes.md) § BuildKit/containerd lane.

Run the driver from the repository root. It parses `linux/scripts/01-core/versions.env`, passes
every version as `--build-arg` (the Dockerfile ARG defaults are only fallbacks), builds the stages
in order and applies the tags:

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
# app env at APP_REF on windows-media, and the final image builds FROM it. A new app
# commit therefore rebuilds torch + the cheap final tail only (minutes, network-bound):
.\windows\Build-Buildkit.ps1 -Stages torch,final               # APP_REF (develop) at its current commit
.\windows\Build-Buildkit.ps1 -Stages torch,final -LatestApp    # newest release tag instead
```

- **Where results land.** Stage results go to the CONTAINERD store as
  `docker.io/local/kataglyphis:bk-<stage>` (torch -> `bk-windows-torch`, final -> `bk-winamd64` /
  `bk-winarm64`; the rocm lane adds a `-rocm` infix to every tag after base, e.g.
  `bk-windows-toolchain-rocm`), invisible to `docker`; use `-FinalTar` for a docker-loadable
  tarball.
- **No `-TorchBaseImage` equivalent.** The torch stage's `BASE_IMAGE` is pinned to the local
  `windows-media` tag (the rocm lane's `llama` image on `-Variant rocm`), so `-Stages torch,final`
  needs the local chain images and cannot be pointed at a published one.
- **`pwsh -File` cannot build arrays**: call the script directly, or
  `& .\windows\Build-Buildkit.ps1 -Gpu -Stages @('media','final')`.
- **Layer caching is on by default.** The Dockerfiles are ordered so that editing one build script
  rebuilds only that script's stage and later ones; `-NoCacheStage <label>` bypasses one stage
  without the chain-wide `-NoCache`.
- `-BuildCtl` overrides the buildctl path (default: the Stevedore install locations, then
  `buildctl` on PATH).
- `KEEP_BUILD_ARTIFACTS=1` (e.g. via a temporary `ENV` line in a media Dockerfile) keeps the
  `C:\temp\*-src` build trees for debugging. By default each build script removes its source tree
  after installing, so the trees don't bloat the image layers.

### TensorRT setup (GPU lane, optional)

**The authoritative home of the TensorRT setup procedure and the `current/` rationale** (since
2026-08-24; it previously lived in AGENTS.md § TensorRT Setup, which now keeps the operational rules
and links here). Update THIS section, never a copy.

TensorRT is **not downloaded automatically**: it requires accepting NVIDIA's EULA. To include it:

1. Download from https://developer.nvidia.com/tensorrt (e.g.
   `TensorRT-Enterprise-11.4.0.106-Windows-amd64-cuda-13.4-Release-external.zip`, which NVIDIA's
   CDN serves under `developer.download.nvidia.com/compute/machine-learning/tensorrt/11.4.0/zip/`;
   measured 2026-10-13). The owner directive that governs this (always take the newest release,
   never lower the pin to match a zip) is [`../AGENTS.md`](../AGENTS.md) § TensorRT Setup.
2. Place the zip in `windows/downloads/` and **delete the superseded one**. The extract step
   version-sorts and takes the highest (a `[version]` cast, so `11.10.0.1` beats `11.2.1.2`; a
   plain string sort gets that backwards), but a stale ~2 GB zip still bloats the `COPY downloads`
   layer.
3. Set `TENSORRT_ZIP_SHA256` in `versions.env` to the new zip's hash
   (`Get-FileHash -Algorithm SHA256 windows\downloads\TensorRT-*.zip`, lowercase). It was EMPTY
   until 2026-08-14, so ~2 GB of EULA-gated payload entered the image unverified. A stale hash now
   fails the build loudly, by design.
4. The `Dockerfile.nvidia` build auto-detects it. `TENSORRT_VERSION` never derives a **filesystem**
   path (the tree is resolved from disk and normalized to `current`) and is otherwise used for
   drift REPORTING. One exception: `Install-Tensorrt.ps1` still builds its NVIDIA CDN fallback URLs
   out of the pin, used only when no zip is staged.

**No zip: the build skips TensorRT gracefully.** CUDA + cuDNN still work; `Install-Tensorrt.ps1`
warns and returns, ORT auto-disables the TensorRT EP, and the smoke test's `TENSORRT_ROOT` pointer
passes on the guaranteed-empty `C:\tensorrt`. This zip-less configuration is the NORMAL state of
this host's GPU lane. Do NOT re-harden it into a fail-fast: a 2026-08-04 "fail-fast" variant
(premised on the wrong claim that the smoke test would reject a TensorRT-less nvidia image) broke
the first hardened `-Gpu` rebuild and was reverted on 2026-08-05. The ORT build script auto-detects
`$env:TENSORRT_ROOT` and enables the TensorRT EP when available.

**The smoke's TensorRT assertions follow the staged state (2026-09-20).** With a tree staged they
require the EP (`cuda=1 trt=1`, the provider DLL, the python EP); zip-less they assert its ABSENCE
(`cuda=1 trt=0`, no provider DLL, python CUDA-EP only), keyed on `Test-TensorRtTreeStaged`, the same
presence rule `Resolve-TensorRtRoot` applies at build time. So the zip-less lane reports zero skips,
and a STAGED tree with a silently-disabled EP still reds. Before this fix the asserts were
unconditional and turned the documented normal zip-less state into three false reds on the
2026-09-20 `-Gpu` run.

**A PRESENT zip fails CLOSED.** `Set-TensorrtTree.ps1` (bind-mounted into the `trt-extract` stage)
renames the extracted `TensorRT-<version>` tree to a stable **`current`** and throws if it carries
no runtime DLLs. Absent zip = supported; half-extracted tree = build failure. `Resolve-TensorRtRoot`
prefers `current` and falls back to the versioned glob for older images.

**Only the runtime DLLs ship (owner, 2026-10-21).** TensorRT's SLA names "the runtime files .so
and .dll" distributable ([`linux-accelerator-images.md` § Redistribution](linux-accelerator-images.md#redistribution)).
`Copy-TensorrtRuntime.ps1` copies the DLLs ORT's TensorRT EP loads into `C:\tensorrt-runtime\current\bin`:
`nvinfer_<M>.dll` and `nvonnxparser_<M>.dll` (linked, ORT v1.31.0's
`onnxruntime_providers_tensorrt.cmake`), `nvinfer_plugin_<M>.dll` (`LoadLibrary`), and every
`nvinfer_builder_resource*_<M>.dll` (`nvinfer` loads them for an engine build), plus the licence
texts. For 11.4.0.106 that is 11 DLLs, 2.39 GB, the set NVIDIA's own `tensorrt_cu13_libs` win_amd64
wheel carries. The sdk image COPYs only that; headers, `.lib` import libraries, `trtexec`, the lean,
dispatch and version-compatibility runtimes, samples, Python wheels and docs stay in `trt-extract`.
`Build-Buildkit.ps1 -Gpu` tags `trt-extract` as `bk-windows-tensorrt-sdk-nvidia`, and the ORT RUN in
`Dockerfile.media-builder` bind-mounts its `C:\tensorrt` at `C:\tensorrt-sdk` (`TENSORRT_SDK_ROOT`,
read by `Resolve-TensorRtSdkRoot`), so no layer the image inherits holds the SDK. The tag stays in the
local containerd store: only `-PushRef` pushes, and an nvidia `-ExportCacheRef` in the public package
is refused. Without the tag the
mount is an empty dir and ORT builds no TensorRT EP, which the smoke then fails on a staged tree. The
smoke fails every image whose `TENSORRT_ROOT` holds anything but `current\bin\*.dll` and
`current\licenses\` (`Get-TensorRtShipViolation`), and an EP whose TensorRT DLLs are missing there
(`Get-TensorRtEpGap` over `Get-PeImportNames`).

**Why `current` exists: two silent defects, both green for their whole life (fixed 2026-08-14,
backlog #38).** `Dockerfile.nvidia` used to build the runtime PATH as
`$TENSORRT_ROOT\TensorRT-$TENSORRT_VERSION\lib`, wrong twice over:

1. The VERSION came from the pin, so it named a nonexistent directory the moment the pin and the
   staged zip disagreed.
2. The DIRECTORY was `lib\`, but **TensorRT 10+ ships the runtime DLLs in `bin\`; `lib\` holds only
   link-time `.lib` import libraries** (measured: 14 DLLs vs 6 `.lib`). So even a correctly pinned
   image could never load the EP.

Neither failed a build: ORT resolves its BUILD-time root with a glob and compiles the EP fine; only
the RUNTIME lookup broke, and ORT drops an EP with unreachable DLLs **silently**. PATH now carries
`current\bin` only, where `Copy-TensorrtRuntime.ps1` puts the DLLs of either layout (2026-10-21).
**Never derive that PATH from the pin again.** A Machine-PATH write inside a RUN cannot substitute: `Dockerfile.base` sets
`ENV PATH=` and the image config wins.

### ROCm layer (`Dockerfile.rocm`)

`-Variant rocm` (amd64 only) installs AMD's TheRock ROCm for Windows tarball in the **sdk slot**,
like `Dockerfile.nvidia` on the GPU lane (since 2026-09-23). Toolchain and media build on top of it
and turn on ROCm and AMD-GPU features behind `(Get-GpuEnvironment).HasRocm`; the cpu and nvidia
lanes keep their flags and outputs. Every rocm tag after `bk-windows-base` carries a `-rocm` infix,
so a rocm run never overwrites a default image.

The lineage, tags, stages (`migraphx`, `llama`), `-NoRocmSpikes`, the CMake isolation of the ROCm
tree, the smoke checks and what each media component enables: [windows-rocm.md](windows-rocm.md).

### Mandatory GStreamer plugins (the contract)

`libav`, `opencv`, `onnx` and `tflite` are **required** in a shipped image. They were absent from
the published `winamd64` for months and nothing was red: meson's `auto` feature state means *skip
silently when the dependency is missing*, the build logged `[INFO] not available`, and the
healthcheck printed `[PASS]` for plugins that did not exist (it reports `[FAIL]` now).

The set lives in **one** place, `Get-RequiredGstPlugin`
(`windows/scripts/modules/WindowsGstPlugins.Common.psm1`), and is enforced at four points that used
to disagree. It moved out of `WindowsScripts.Shared.psm1` (named here until 2026-08-23) because
Shared sits in the compile closure of all three media branches and this set changes far too often
for that.

| Where | What it does | On failure |
|---|---|---|
| pre-flight, `Build-GstreamerFromSource.ps1` | emits the missing `.pc` files, disables `FFmpeg.wrap`, resolves every required pkg-config module | **throws in seconds** (54 s on its first live run), before a ~1 h configure+compile |
| meson setup | `-Dlibav=enabled`, `-Dgst-plugins-bad:opencv=enabled`, `-Dgst-plugins-bad:onnx=enabled` | configure fails loudly instead of skipping |
| post-install gate | `gst-inspect-1.0 <plugin>` for the whole set | **throws** — proves the plugin loads, not just that it configured |
| smoke test | same set, as assertions | **fails** the suite |

Four unrelated root causes, diagnosed against gstreamer 1.29.2 sources, one mechanism per plugin
(why the single "PKG_CONFIG_PATH" theory never explained it):

- **opencv**: `gst-plugins-bad/gst-libs/gst/opencv/meson.build` resolves
  `dependency('opencv4', '>= 4.0.0')`. OpenCV installs no `.pc` unless `OPENCV_GENERATE_PKGCONFIG`
  is set, and it would be named `opencv5.pc` anyway. Upstream dropped the old `< 4.x` upper bound,
  so OpenCV 5 is version-acceptable; it just needs a file under the name meson looks up. Measured on
  the gate's first live run: the emitter authored `opencv4.pc` with **64** import libs enumerated
  from the actual install.
- **onnx**: `ext/onnx/meson.build` resolves `dependency('libonnxruntime', '>=
  1.16.1')` then calls `subdir_done()`. ORT ships no `.pc` on any platform.
- **libav**: nothing to do with `.pc` files. `subprojects/FFmpeg.wrap` *provides* the four `libav*`
  modules pinned to **FFmpeg 7.1.1**, and `-Dwrap_mode=forcefallback` **forces** meson to use it, so
  pkg-config was never consulted: the build fetched and compiled a second, older FFmpeg instead of
  the `n9.0` it had just built. Even succeeding would have shipped gst-libav linked against a
  different FFmpeg than the image's own `ffmpeg.exe`. The wrap is now moved aside before configure.
  Our own FFmpeg `.pc` files then turned out to carry `Version: ..`, which `pkg-config --exists`
  accepts, so the pre-flight's `-MinimumVersion` floors caught it, not presence (fixed by a VERSION
  file + prefix rewrite).
- **tflite**: consults **no pkg-config at all**. `ext/tflite/meson.build` probes the compiler with
  `cc.find_library('tensorflowlite_c')` (fallback `tensorflow-lite`),
  `cc.has_function('TfLiteInterpreterCreate')` and `cc.has_header('tensorflow/lite/c/c_api.h')`.
  That header path is the **pre-rename TensorFlow** one, while LiteRT v2.x ships the post-rename
  layout: `Build-LitertFromSource.ps1` stages headers under `include\tflite\`, so upstream's probe
  could never find them, `.pc` file or not. A namespace mismatch, not a missing dependency, which is
  why it never looked like the opencv/onnx problem. The pre-flight mirrors the header tree to
  `include\tensorflow\lite\`, resolves the C API library by name (failing with the list of what *is*
  staged if neither candidate exists), and puts the LiteRT include/lib dirs on `INCLUDE`/`LIB` (the
  only mechanism `cc.find_library` and `cc.has_header` consult) as well as into
  `c_args`/`cpp_args` and the link args, so the plugin's own compile and link succeed. Both
  candidate names stay listed in upstream's order because on 2026-08-07 only the FALLBACK
  (`tensorflow-lite`) existed; `Build-LitertFromSource.ps1` injects a real `tensorflowlite_c`
  target since, and asserts its import lib after install.

Both `.pc` files are authored by the **merge** stage, not by the OpenCV/ONNX builds: those are the
two most expensive layers in the chain (~30 and ~75 minutes), and emitting a text file is not worth
invalidating them. The emitter reads the canonical env contract (`OPENCV_ROOT`, `OPENCV_LIB`,
`ONNX_ROOT`, `ONNX_VERSION`) that the merge image already defines, finds the header root rather than
assuming it, and enumerates link names from the actual `lib` directory, so an OpenCV module-list
change cannot rot into a link error.

**`tensorfilter` is not a GStreamer plugin.** It is an NNStreamer element, and this repo does not
build NNStreamer; it appeared in the old probe lists only because the lying healthcheck "found" it.
Requiring it would fail every build forever. Wanting it means adding an NNStreamer source-build
stage.

**PROVEN 2026-08-13:** all four mandatory plugins (`libav`, `opencv`, `onnx`, `tflite`) build AND
load in the merge image; the post-install `gst-inspect` gate passes for all of them. `gst-libav`
compiles and loads against the image's own FFmpeg `n9.0` (the wrap is disabled, so it links our
FFmpeg, not upstream's pinned 7.1.1). Getting there took an OpenCV-4→5 header port of the opencv
plugin, a `tensorflowlite_c` C-API lib for tflite, and deploying the CUDA/cuDNN runtime so opencv's
`cudnn64_9.dll` resolves (the merge-stage notes above and the `gstreamer-merge-winfix` build
memory). `-SkipPluginGate` still exists as the escape hatch; an image built with it is not
shippable.

**Six entries since 2026-08-25 (#128):** `webrtc` (gst-plugins-bad) and `nice` (libnice's GStreamer
plugin) joined the contract on both lanes as meson-native entries: the build passes their meson
options as `=enabled`, the gate proves the DLL and (natively) the load. Proven on the arm64 lane on
run 28 (2026-08-26) after three meson build-only-subproject defects were patched around
(`docs/windows-refactor-backlog.md` #128), and on amd64 the same day (run 7: `gst-inspect` loads
`webrtcbin` and `nicesrc`/`nicesink`, smoke 222/0/0).

**Thirteen entries since 2026-10-05 (CON28):** WebRTC needs more than `webrtcbin` and `nice`, and
each of these is loaded by element name at run time, so only a load probe sees one missing:

- `dtls`, `srtp`, `sctp`, `rtpmanager` and `openh264`: meson entries, passed as `=enabled`.
- `rswebrtc` (`webrtcsink`/`webrtcsrc`) and `rsrtp` (`rtpgccbwe`): two gst-plugins-rs crates with
  `Detection = 'cargo'`.
- The gate finds each DLL by its exact name, `gst<name>.dll`; the `gst*<name>*.dll` wildcard it used
  before would hand `gstrswebrtc.dll` to the `webrtc` entry.
- The smoke test's section 11 ends with a WebRTC loopback, the one assertion that would have caught
  the two defects below. The loopback passes a consumer that exits 1 in one case only: it reached
  EOS after the frames had flowed for `Frames/30` s, and its only error is webrtcsrc's own
  signaller failing in teardown (`send failed because receiver is gone`). That race hit 1 run in 30
  idle and 5 in 25 under load; the smoke test prints it as a `[WARN]`
  (`Get-GstLoopbackTeardownError`, CON68).

### libffi's type exports

**Symptom.** WebRTC on Windows did nothing: `webrtcbin`'s `create-offer`, `get-stats` and
`create-data-channel` never replied, not even with the `closed` error a bare `webrtcbin` in NULL
state must send. Every GObject signal with arguments or a return value lost its C class handler,
while signals with none still worked. `ffi_prep_cif` in the image's `ffi-7.dll` returned
`FFI_BAD_TYPEDEF`, and the DLL's exported `ffi_type_*` descriptors were all zero:
`ffi_type_sint32 size=0 align=0 type=0`.

**Cause.** The libffi meson port (`LIBFFI_MESON_VERSION` 3.2.9999.4, and .5 alike) defines
`FFI_EXTERN` as a bare `__declspec(dllexport)` when it builds the DLL. Every libffi file that
includes `ffi.h` therefore holds a tentative definition of each of the twelve types; only `types.c`
holds the real, initialized ones. MSVC's `cl` turns tentative definitions into COMMON symbols and
the real definition wins. clang-cl defaults to `-fno-common`, so each file emits a strong zero
definition in `.bss`. The link then has six definitions of every type, and the 60
`duplicate symbol: ffi_type_*` errors were hidden by the `/FORCE:MULTIPLE` this lane added in June
for exactly those duplicates. lld-link kept the first copy, `prep_cif.c.obj`'s zeros. The image's
own build log carried the 60 warnings, the only lld-link diagnostics in the whole x64 build.

**Fix.** `-fcommon` is in the C arguments of both lanes, and in the native file's `c_args` for the
cross lane's build machine, which links its own `ffi-7.dll` as a default target. `/FORCE:MULTIPLE`
is gone, so a duplicate symbol fails the link again. After install, `Assert-LibffiTypeExport`
(`WindowsMeson.Common.psm1`) reads the shipped `ffi-7.dll` statically and fails the build unless
`ffi_type_sint32`, `_pointer` and `_void` are 4/4/10, 8/8/14 and 1/1/0. Being a static read, it is
also the only libffi proof the cross lane has. An upstream-style source patch (an
`FFI_API`/`FFI_EXTERN` split as in libffi 3.3, with `types.c` exporting its own definitions) gives
the same DLL, measured; `-fcommon` won because it is one token and matches what `cl` does.

### DTLS with OpenSSL 4

**Symptom.** With libffi fixed, signalling, the offer, the answer and ICE all completed, then both
peers died at the first DTLS step:
`dtlsconnection ... ssl error: ...:error:0A000126:SSL routines::unexpected eof
while reading:ssl\record\rec_layer_d1.c:254` and `GstDtlsEnc ... Fatal SSL
error`.

**Cause.** gstdtls links OpenSSL 4 (`libssl-4-x64.dll`). OpenSSL 4.0.0's `bread_conv`
(openssl/openssl#29290) treats a 0-byte read from an old-style `BIO_meth_set_read` callback as end
of file. GStreamer 1.29.2's `bio_method_read` returns 0 to mean "no datagram yet". OpenSSL 3.x
surfaced that as a `SSL_ERROR_SYSCALL` the plugin ignores; 4.0 makes it fatal.

**Fix.** Upstream GStreamer commit 17d22abe89 (MR !11897) makes the empty read
`BIO_set_retry_read (bio); return -1;`. It is 277 commits past the 1.29.2 tag, so
`Build-GstreamerFromSource.ps1` carries it through `Edit-SourceFile`. The build fails when the hunk
neither applies nor is already upstream, and logs a retirement note when upstream carries it.
**Retire the patch once `GSTREAMER_VERSION` moves past 1.29.2** to a release that contains the
commit. The OpenSSL DLLs gstdtls imports are staged into `<prefix>\bin` on both lanes; on amd64 they
used to load only when scoop's `openssl\current\bin` happened to be on `PATH`, which the image's
`PATH` does not carry.

### gst-plugins-rs on Windows

`webrtcsink`, `webrtcsrc` and the signalling server live in gst-plugins-rs, not in the meson
monorepo build. Phase `8b` of `Build-GstreamerFromSource.ps1` builds them as the Linux lane does: a
shallow clone of `github.com/GStreamer/gst-plugins-rs` at `gstreamer-$GSTREAMER_VERSION`, then a
plain `cargo build --release --locked -p gst-plugin-webrtc -p gst-plugin-rtp` against the prefix's
own `.pc` files. The cdylibs are the plugin DLLs, so no `cargo-c` is involved.
`Get-GstRustCargoPlan` (`WindowsGstPlugins.Common.psm1`) derives the packages from the contract's
`CargoPackage` fields and, on the cross lane, adds `--target aarch64-pc-windows-msvc`,
`PKG_CONFIG_ALLOW_CROSS=1`, `lld-link` as the target linker and `clang-cl --target=…` for the C
that `ring` compiles.

**cargo does not go through sccache, on measurement (2026-10-16).** With `RUSTC_WRAPPER`, the step
took 125 s bare (2026-10-14), 153 s on the first fill, and 131 s warm at 99 % Rust hits (230 of
250). Its time is the two plugin crates, which are cdylibs that sccache cannot cache (57
`crate-type` calls). The wrapper also has a trap: cc-rs wraps whatever `CC` names in it, and phase 3
leaves meson's sccache shim in `CC`. ring's build script then ran `sccache <shim>`, which sccache
refused (`Compiler not supported: ""`). The real `clang-cl` in `CC` fixed that, but the time did not
move, so the wrapper was taken out. The crates' C compiles still go through the shim.

- **Default features**, as on Linux: `janus`, `whip`, `web_server`, `whep`, `pixelstreaming`. TLS
  is rustls with `ring`; no AWS or LiveKit SDK, so no aws-lc and no OpenSSL in the crate graph.
- **`--locked`**, because upstream's `Cargo.lock` pins every crate and the two git dependencies
  (gstreamer-rs on gitlab.freedesktop.org, gtk-rs-core on GitHub) to commits.
- **gstreamer-rs comes from its GitHub mirror.** gitlab.freedesktop.org served the gstreamer-rs
  clone at 10-15 KiB/s on 2026-10-05, from the host and from the container alike, and cargo was
  still on it when the run was stopped after 20 minutes. `Get-GstRustSourceMirrorConfig` reads the
  lock's `gitlab.freedesktop.org/gstreamer/*` sources and writes a cargo `[source]` replacement onto
  `github.com/GStreamer/<repo>`, the official mirror with the same commits; the script passes it as
  `cargo build --config <file>`. `--locked` still holds, because a replaced source keeps the lock's
  commit, so a mirror that lacks the commit fails the build rather than resolving another one.
  Measured: the whole fetch and build took 3 min 7 s.
- **Network.** The merge RUN already fetches the GStreamer tarball, the wraps and rust-std, and the
  toolchain stage runs `cargo install` from crates.io, so cargo fetches at build time like
  everything else here; nothing is vendored. TLS verification stays on for this clone and for
  cargo: the `GIT_SSL_NO_VERIFY` the script sets for meson's wrap fetches is lifted for the step.
  (The `-Dgst-devtools:dots-viewer=disabled` comment's "fetch fails offline" is not about this RUN's
  network: at 1.29.2 the option is spelled `dots_viewer`.)
- **Layer hygiene.** Phase 10 removes the checkout, the target tree and only the cargo
  `registry`/`git` caches this run created, so nothing is whited out of a lower layer.

### Toolchain pins and the provenance manifest

Everything that **produces or shapes compiled output** is pinned in `versions.env` and asserted at
base-build time by `Test-Toolchain.ps1`:

| Pin | Installs | Why it is pinned |
|---|---|---|
| `LLVM_WINDOWS_VERSION` | scoop `main/llvm` in the base; since #135 (2026-08-29) the toolchain stage also builds the patched clang/LLVM from the same pinned source into `C:\llvm-patched`, ahead on PATH | clang-cl + lld-link compile the entire media chain, and five patches under `windows/scripts/patches/` are written against a specific clang-cl's diagnostics |
| `NINJA_WINDOWS_VERSION` | scoop `main/ninja` | build-graph executor for every CMake source build |
| `NASM_WINDOWS_VERSION` | scoop `main/nasm` | assembles the x86 SIMD of GStreamer subprojects that ship `.asm` (openh264 — see `Build-GstreamerFromSource.ps1:482`) **and, since #119 (2026-08-24), FFmpeg's hand-written x86 kernels on the amd64 lane** (`--x86asmexe=<nasm>`; before that day FFmpeg passed an unconditional `--disable-x86asm` and nasm assembled nothing for it) — a bump changes shipped object code in both |
| `CMAKE_VERSION`, `VULKAN_VERSION`, `FLUTTER_VERSION`, `GIT_VERSION` | scoop / installer | pre-existing pins, unchanged |

The LLVM pin landed **2026-08-07** and closed a real hole: the OS base is digest-pinned
(`WINDOWS_BASE_DIGEST`) for reproducibility, and the very next layer then installed whatever
clang-cl scoop served that day. A base rebuild months later would swap the compiler silently, and
the breakage surfaces ~2 h into media-core with no way to reproduce the image that worked. It was
pinned to the version scoop served at the time: a no-op for the next rebuild, a guarantee for every
one after. **Bump deliberately**, then re-run
`windows\scripts\tests\Test-PatchesApplyClean.ps1` against the rebuilt base.

Everything else `Install-ScoopTools.ps1` installs (7zip, nano, cppcheck, nsis, uv, nuget, zlib,
openssl, pkg-config, make, gawk) floats on purpose: the build only *invokes* those. Move a package
into the pinned block the moment it starts linking into a shipped binary. sccache is the exception
in a different direction: pinned (for a cache FEATURE, not output) and installed by
`Install-RustToolchain.ps1` from the official released 0.18.0 zip into `CARGO_BIN`; the source
build is retired ([`windows-build-resources.md`](windows-build-resources.md)
§ Persistent compile cache (sccache)). `LLVM_RELEASE` is a SEPARATE pin for the Linux lane; the two
lanes move independently.

Two things still float by design and cannot be pinned the same way: the **MSVC toolset** inside VS
major 18 (Install-Vs.ps1 uses the `aka.ms/vs/18/release` channel, which refreshes within the major)
and scoop's floating block. That is what the manifest is for:

```pwsh
# in any image built after 2026-08-07
nerdctl --namespace buildkit run --rm --entrypoint pwsh <image> `
  -NoProfile -Command "Get-Content C:\toolchain-manifest.json"
```

`Complete-Container.ps1` writes `C:\toolchain-manifest.json` in the base tail layer: pinned inputs
as `pin`/`resolved` pairs (so a mismatch is visible, not inferred), the floating ones as resolved
values only, plus the OS base digest and a UTC timestamp. It answers "which compiler built this
49 GB image" from the artifact rather than from `out\windows-build-logs\`, and it turns
classic-vs-BuildKit lane parity into a `diff` of two files. The smoke test asserts it exists and
records a resolved clang-cl (SKIP on older images).

### Rust toolchain (rustup WITH a default toolchain — never toolchain-less rustup)

Rust is provisioned **exclusively via rustup**: `Install-RustToolchain.ps1` runs
`rustup-init.exe -y --default-toolchain <RUST_VERSION> --profile minimal`, and bakes
`flutter_rust_bridge_codegen` at `FLUTTER_RUST_BRIDGE_VERSION` alongside, so Flutter+Rust consumers
skip a minutes-long cold `cargo install` per fresh container.

- **rustup is required**, not merely tolerated. Flutter's **Cargokit** (the build glue of
  `flutter_rust_bridge`-style plugins, e.g. `rust_builder/cargokit` in OmniAccelerANT) enumerates
  toolchains/targets via rustup and aborts with *"rustup not found in PATH."* otherwise; a
  scoop-only Rust (the previous setup) failed every Flutter+Rust consumer build at the CMake
  install step.
- **The old "never rustup" rule was broader than its failure mode.** A **toolchain-less** rustup
  (`rustup-init --default-toolchain none`) drops proxy shims (`cargo.exe`, `rustc.exe`, …) into
  `CARGO_BIN` that resolve **no** toolchain and fail with *"rustup could not choose a version of
  cargo … no default is configured"*. A rustup installed **with a default toolchain** resolves
  fine. `Dockerfile.base` points `CARGO_HOME`/`CARGO_BIN` at
  `C:\Users\ContainerAdministrator\.cargo`, ahead of scoop's shim dir on `PATH`, so the proxies
  winning is the *correct* outcome. Keep exactly one Rust provider: no `scoop install main/rust`
  alongside.
- **Pinned to `RUST_VERSION`, as on Linux** (owner decision 2026-10-05, CON60). Until then this lane
  installed `stable` at build time, so Windows and Linux built `oxidant` with different compilers
  after every Windows chain, and the toolchain was named `stable-x86_64-pc-windows-msvc`, which a
  `rustup update` would move silently. The mirror fetches `channel-rust-<RUST_VERSION>.toml`, and
  the toolchain is named `<RUST_VERSION>-x86_64-pc-windows-msvc`. OmniAccelerANT's Cargokit builds
  with whatever rustup resolves since 2026-10-05, so this pin is the app's too.
- `Dockerfile.base` declares `RUST_VERSION` and `FLUTTER_RUST_BRIDGE_VERSION` right above the Rust
  layer. The smoke test asserts both values, the Cargokit probe shape
  (`rustup show active-toolchain`, `rustup which cargo`) and a compile/link/run probe.

## Running the Image

Run with **process isolation** to get the host's full CPU count (Hyper-V isolation, the Windows
default, exposes only 2 logical CPUs). Process isolation is allowed here because the host build
(26200) is ≥ the container base build (`servercore:ltsc2025`, 26100):

```pwsh
& "D:\Stevedore\bin\docker.exe" run --memory 48g -it --rm --isolation process `
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

Drop `--isolation process` to fall back to Hyper-V isolation (stronger boundary, but capped at 2
CPUs on this host). NAT networking and DNS work in both modes.

## Smoke Testing

**Automatic since 2026-08-14 (backlog #44): the last step of every amd64 BK chain.**
`Build-Buildkit.ps1` solves `windows/Dockerfile.smoke-gate` against the freshly built `winamd64`
image after `final`, and a failure fails the chain. Before that, neither driver invoked the smoke
test at all: a multi-hour build ended with "Done" and zero evidence the image worked, in a repo whose
defect history is dominated by "builds fine, fails to LOAD".

**On `-TargetArch arm64` the gate RUNS since 2026-08-24.** The 2026-08-23 blanket "inapplicable"
verdict was over-broad: roughly half the suite never touches the payload.

- The host-toolchain and static sections (1-6, 14-16, 19 arch-filtered, 23 and 25; 7 too on the
  cross GPU lane) execute against the arm64 image with their own floor column
  (`MIN_PASSED=76`/`MAX_SKIPPED=20`; measured green at 97/0/15 before sections 19 and 25 grew, so
  re-measure).
- Sections 14/15 compile **for the target** and assert the produced PE machine instead of running.
- The payload sections are skipped as sections with floor 0, a floor that must stay 0, never be
  "fixed" by a skip.
- The amd64 floors are untouched, so no later amd64 change can quietly be measured against a
  lowered number. The aarch64 payload itself remains verified statically, by `Test-TargetArch.ps1`
  in the merge stage.

**HISTORICAL: the CLASSIC driver (`build.ps1`) gated from 2026-08-21 until the lane's retirement**
(2026-08-14 to 2026-08-21 only the BK driver gated, so a classic chain then still ended
unverified). It ran a `docker run` with a DIRECTORY mount of
`windows\scripts`: its dockerd has no BuildKit `RUN --mount`, and Windows containers reject
single-FILE bind mounts outright; `docker run` enters through the ENTRYPOINT naturally (no
bare-`RUN` bypass to compensate for). The gate worked, and it proved the lane could never pass it
(`cv2.CAP_GSTREAMER`, [windows-build-lanes.md](windows-build-lanes.md)
§ The classic lane was retired).

Three things about the gate are load-bearing:

- **It runs through `entrypoint.cmd`, not as a bare `RUN`.** A bare RUN bypasses `ENTRYPOINT`,
  which loads VsDevCmd and the LLVM clang_rt ASAN runtime dir. Skipping it made SIX assertions fail
  against a perfectly good image (msbuild, `VCToolsInstallDir`, MSBuild+ClangCL, nvcc, ASAN). If
  that cluster fails, suspect the invocation before the image.
- **It bind-mounts the CURRENT script + modules** instead of the copies baked into the image, so a
  fix to the smoke test is re-verifiable without first rebuilding the whole image (the friction that
  let this script go unrun for a month). It adds no layer, so the gate never alters the artifact it
  verifies.
- **Coverage floors, not just "0 failures".** `-MinPassed` / `-MaxSkipped` (driver:
  `-SmokeMinPassed` / `-SmokeMaxSkipped`, defaults 178 / 3; the GPU lane raises the effective floor
  to 198 unless overridden) make "nothing ran" a distinct failure, **exit 3 = INSUFFICIENT
  COVERAGE**. The verdict used to read only `$summary.Failed`, so a run where every section skipped
  printed "All smoke tests passed!" and exited 0. These defaults describe the **amd64** lane; never
  re-tune them to accommodate arm64, which has its OWN floor column and driver defaults (76/20,
  above). A lowered amd64 floor left lying around is how a gate silently stops gating.
  `-SkipSmokeGate` is for iterating on the chain itself and says loudly that the image is
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

The smoke test validates 25 categories, including the CUDA Toolkit, ONNX Runtime with CUDA, ONNX
GenAI with CUDA, LiteRT with GPU delegate, LiteRT-LM with CUDA, OpenCV with CUDA, GStreamer with
CUDA, TVM (source-built), IREE (source-built; native MLIR→vmfb compile + local-task execution, a
CUDA-target compile-only assert on the GPU lane, and a python `iree.compiler`→`iree.runtime`
end-to-end), FFmpeg (source-built with DNN/ONNX integration), compiler integration,
environment-pointer integrity, and Python bindings.

**Baselines.** Record the new figure here from each green run; a HIGHER count is growth, not a
regression.

- **Current (2026-09-22, `bk-20260922-034440`, the GPU lane with Hailo, zip-less): 236 passed /
  0 failed / 0 skipped.** The TensorRT asserts are conditional on the staged state
  (§ TensorRT setup), and Hailo section 24 adds six host-runnable assertions plus the two
  `HAILO_*` pointers, so the zip-less GPU run is a full pass.
- The CPU-lane figure remains 222/0/0 (2026-08-26, `bk-20260826-130136`, via the automatic gate),
  matching the arm64 parity table.
- It supersedes 184/0/1 (2026-08-14; the one skip was GPU device passthrough) and the long-stale
  2026-07-14 figure of 167/0/1, which predated the mandatory-plugin assertions, the
  `SCOOP_GLOBAL_SHIMS` checks, the bulk DLL-load enumeration (#57: it alone load-tests 65 OpenCV
  DLLs where one was tested before) and the LiteRT export asserts (#67).
- Growth over the 153 baseline: the PyAV asserts (staged `av-*.whl` + an in-memory mpeg4 encode
  through the container-built FFmpeg) and the IREE suite (section 22 native compile+run incl. a
  CUDA-target compile-only assert, wheel-pin + `--version` asserts, section 20 staged-wheel + python
  end-to-end asserts, section 19 `IREE_ROOT`/`IREE_BIN` pointers).
- Section 23 (#167) is the baked `C:\temp\scripts` surface, which this hand-run invocation does not
  exercise.
- On 2026-09-23 three sections grew for the ONNX Runtime single-source rule: section 19 gained the
  ort-crate-env assertion (floors Gpu 31 / Cpu 27 / Arm64 25), section 21 the venv's DirectML and
  chain-wheel checks (floor 4 on amd64), and the new section 25 is the ORT census (floor 5 on the
  amd64 columns, the four census assertions plus `ORT in-box`, and 4 on arm64, where the in-box
  assertion is a skip; plus the STAMP assertion now that the build gate exists;
  [`onnxruntime-single-source.md`](onnxruntime-single-source.md)). The next green run's figures are
  not measured yet.

### What is verified: native vs. Python

**Native (C++/CLI) functionality is verified end-to-end.** The suite compiles, links and *runs*
probe programs against the source-built libraries: ONNX Runtime (C API ABI + a real inference
session over an embedded 63-byte Identity model on the CPU EP), OpenCV (core API call), TVM (full
dependent-DLL chain load), LiteRT-LM (its `litert_lm_main.exe` smoke-run is a hard gate of the media
build itself), FFmpeg (a real lavfi→null filter graph), GStreamer (a live
`videotestsrc ! videoconvert` pipeline), plus clang-cl / CMake+Ninja / MSBuild integration builds.
Version pins (cmake, python, gstreamer) are asserted against versions.env to catch stale baked
layers.

The **toolchain** pins are asserted one layer earlier: `Test-Toolchain.ps1` checks clang-cl, ninja
and nasm against `versions.env` during the BASE build, where a mismatch costs seconds rather than
surfacing two hours into media-core. This suite keeps only a well-formedness check on clang-cl (plus
a non-fatal warning when the image's baked pin disagrees, and the manifest check of
§ Toolchain pins and the provenance manifest), because it also runs against PUBLISHED and older
images whose compiler legitimately predates the current pin; failing those would make it useless as
a regression gate.

**Python bindings are built, shipped, and functionally verified (since 2026-07-13) on the amd64
lane.**

- **amd64.** The media branches build python bindings for every source-built library that supports
  them and stage the wheels centrally at **`C:\runtime\wheels`** (`PYTHON_WHEELS` env):
  `onnxruntime` (CUDA+TRT+DML EPs, `ENABLE_PYTHON=ON`), `onnxruntime-genai-cuda` (`BUILD_WHEEL=ON`),
  `apache-tvm` (scikit-build-core), `iree-base-compiler` + `iree-base-runtime` (built from the IREE
  ninja tree's synthesized `compiler/`+`runtime` pip dirs with `--no-build-isolation`, so the wheels
  pack the existing LLVM objects instead of rebuilding them), and `av` (PyAV, below). `cv2` ships
  installed into CPython's site-packages (the opencv repo has no wheel machinery; opencv-python is a
  separate upstream project); `ai-edge-litert` is media-litert's bazel wheel
  (§ The ai-edge-litert wheel). All bindings are pre-installed with their PyPI deps, so
  `python -c "import onnxruntime, onnxruntime_genai, cv2, tvm, av"` works out of the box. Smoke
  section 20 verifies wheels + `win_amd64` tags, real python-side ONNX inference, a cv2 PNG
  round-trip, and genai/tvm imports.
- **arm64 cross lane.** The same set ships since 2026-08-24 evening (#120 step 2) and, since
  2026-08-26, **including the TVM and IREE runtime packages** (#133): the target aarch64 CPython
  (source-built at `C:\runtime\python`, step 1), the `onnxruntime`, `onnxruntime_genai_directml`,
  `av`, `apache_tvm`, `apache_tvm_ffi` and `iree_base_runtime` wheels in `C:\runtime\wheels`
  (staged, **not** installed: nothing here can import them; install them on the target host), and
  `cv2.cp315-win_arm64.pyd` installed into the target interpreter's site-packages. A device imports
  them: `Test-Arm64Bundle.ps1` on `windows-11-arm` installs the ORT, GenAI and `av` wheels offline
  and imports `numpy`, `onnxruntime`, `av` and `cv2`
  ([`windows-cross-builds.md` § Verification](windows-cross-builds.md#verification)).
- **The two sets.** Six wheels on each lane, differing in exactly two entries: amd64 additionally
  has `iree_base_compiler`, and installs `tvm_ffi` from the vendored source instead of shipping it
  as a wheel. The **compiler** packages (`iree.compiler`, TVM codegen) stay amd64-only: they need an
  LLVM cross-built for aarch64-windows (#116/#133).
- **PyAV** is compiled from sdist against the source-built FFmpeg via `setup.py --ffmpeg-dir`.
  PyPI's own av wheel is structurally unloadable on Server Core: its bundled avdevice imports the
  desktop-only `AVICAP32.dll`. The generic `h264` encoder alias resolves to `h264_d3d12va`, so
  headless code should request software codecs like `mpeg4`/`libx264` by name.
- **Consumer CI venvs** synced inside the image are reconciled onto the ORT/GenAI wheels in this
  store (`Sync-UvChainOnnxRuntime`,
  [`python-ci.md` § Trap 3](python-ci.md#trap-3--onnx-runtime-comes-from-the-chain-not-pypi)).
- **FFmpeg's import-lib layout.** `FFMPEG_VERSION` is pinned to a release tag since 2026-08-04
  (`n9.0` then). It previously tracked `master`, where an upstream drop moved `avformat.lib` et al.
  from `lib\` to `bin\` overnight (2026-07-13; PyAV died with LNK1181). `Build-FfmpegFromSource.ps1`
  still normalizes the import-lib layout after `make install` as a guard across tag bumps: every
  `.lib`/`.def` is harvested into `lib\`, missing import libs are regenerated from their `.def` via
  `lib.exe`, and the PyAV step logs the lib inventory up front, so the next layout drift fails
  loudly with data.
- **Load-bearing plumbing (do not remove):** the `sitecustomize.py` shim fixes the clang-built
  CPython's win32 platform misreport AND registers the image's native DLL homes via
  `os.add_dll_directory` (CUDA 13/cuDNN 9 keep their runtime DLLs in `bin\x64`; python 3.8+ ignores
  PATH for pyd dependencies). OpenCV builds with `WITH_MSMF=OFF` *and* `WITH_OBSENSOR=OFF`, because
  both hard-import Media Foundation, which Server Core does not ship.

### The torch step (OrchestrANT app environment)

The final image bakes the runtime orchestrator at **`C:\opt\OrchestrANT`** (`TORCH_APP_DIR`),
assembled by `windows/scripts/build/Build-TorchApp.ps1` (mirror of the linux
`assemble-torch-app.sh` stage) in the torch stage (`windows/Dockerfile.torch`), which the final
image builds FROM:

- **Ref**: versions.env's **`APP_REF` names the branch the stage tracks** (`develop`, owner decision
  2026-09-29). `Resolve-TorchAppRef` resolves it to the commit it points at when the torch stage
  starts (`git ls-remote`, via `Resolve-GitRefCommit`), and that commit reaches the Dockerfile as
  the `APP_REF` build-arg. So the torch-step layer rebuilds exactly when the app moved, and the
  commit is the image's version label. `Build-TorchApp.ps1` fetches a commit as itself
  (`clone --branch` takes names only). A 40-hex `APP_REF` is built as given, with no lookup; an
  unreachable remote stops the stage. `-LatestApp` tracks the newest release tag instead. The Linux
  lane does the same: [`linux-cross-builds.md`](linux-cross-builds.md#the-app-the-wrapper-builds).
- **Sdists compile with clang-cl** (CON93). Under 3.15, line-profiler 5.0.2 and pyyaml 6.0.3 have no
  cp315 wheel, so uv builds them, and setuptools takes VS's `cl.exe` and `link.exe`. For both syncs,
  `Enable-TorchAppClangClSdist` puts copies of `clang-cl`, `lld-link` and `llvm-lib` first on
  `PATH`, named `cl`, `link` and `lib`, with `DISTUTILS_USE_SDK=1` and `MSSdk=1`. clang-cl and
  lld-link find VS and the SDK themselves.
  - After the sync, `Assert-TorchAppSdistCompiler` fails the stage if any distribution uv reports as
    `Built` has a PE under site-packages with MSVC's Rich header. uv's own `Scripts\*.exe` launchers
    are outside site-packages.
  - Probe P13: line-profiler built this way has no Rich header and imports on 3.15. pyyaml compiles
    `_yaml` with clang-cl, finds no `yaml.h` and falls back to pure Python, as designed.
  - The shim is for native builds only, because a cross target would need `--target`.
- **Environment**: `uv sync` on the source-built CPython (extras `ml-ai`, `docs`, `pytorch-cpu`
  (`pytorch-cu130` on the nvidia lane) and `test`; no `frontend` extra, like Linux),
  with `--no-install-package` for every `onnxruntime*` name in `uv.lock` (a locked name whose family
  has no chain wheel stops the stage), then a reconcile so this lane's wheels always win.
  - Image assembly and consumer sync parse ORT lock names through
    `WindowsUvLock.Common.psm1`. Copy this companion with `WindowsUv.Common.psm1`;
    `Dockerfile.torch` also copies it beside the build script's other modules.
    Package-table counts, normalized ORT family names and safe package spelling are
    checked once. Consumer sync still treats an absent lock as empty; image assembly
    still refuses one. Focused lock fixtures cover parsing, not a real uv installation.
  - The ORT census (`ort-venv-census.py --purge-list`, run in the venv) names every installed ONNX
    Runtime distribution: any `onnxruntime` or `onnxruntime-*` name and any owner of the
    `onnxruntime`, `onnxruntime_genai` or `onnxruntime_extensions` package; there is no fixed list.
  - Those and the opencv-python variants are uninstalled, `C:\runtime\wheels` is force-installed
    `--no-deps` (genai-cuda's metadata names `onnxruntime-gpu`, which our combined wheel replaces),
    and `cv2` + `tvm_ffi` + the sitecustomize shim are staged from base site-packages into the venv.
  - The install ends with the census `--check`: every ORT distribution byte-identical to a wheel in
    `C:\runtime\wheels` and `onnxruntime` owned once, or the stage fails
    ([failure-modes](failure-modes.md#the-torch-stage-fails-with-ort-census-fail)).
- **`ai-edge-litert`** was installed from the app lock on every lane from 2026-09-26 (BACKLOG CON28)
  until the Python 3.15 pin: no release has a cp315 `win_amd64` wheel. `Get-TorchAppLitertSyncArg`
  now leaves it out of `uv sync` when the chain's store holds an `ai_edge_litert` wheel (built from
  source for the pin, CON91), or, with a warning, when neither the store nor the lock has one for
  the image's tag; the app's smoke then WARNs for litert. The rocm lane no longer pins its own
  ([`windows-rocm.md` § The LiteRT extra](windows-rocm.md#the-litert-extra)).
- **Gates**: the docker build itself fails unless the venv passes the import battery
  (numpy/cv2/torch/onnxruntime with a CUDA-EP build assert/genai/tvm) **and the app's own
  wheel-smoke suite** (`python -m orchestrant.smoke`: real torch/torchvision/ORT-inference/OpenCV
  work).
  - The check inventory is the app's own choice, so the expected pass count moves with the app
    commit. The rule on this lane: **all checks pass except a single WARN for the litert skip** on
    cpu/nvidia (the `ai-edge-litert` limitation above; the rocm verify finds it installed), plus any
    checks the built app commit does not yet ship (e.g. an iree check counts only once the app
    includes it).
  - `-Mode verify` runs the ORT census first, so the rocm-1 stage and smoke section 21 enforce it
    too. Smoke section 21 re-runs the same verification offline on every suite run; its app-verify
    assertion also requires the `ORT-CENSUS PASS` line and reports the census's FAIL lines as its
    message.
  - Section 21 adds two GPU-less checks on every amd64 lane: the venv's onnxruntime lists
    `DmlExecutionProvider` and its GenAI reports `is_dml_available()` (the verify above asserts only
    the CUDA EP), and the venv's onnxruntime is the chain wheel, the sole owner of the package with
    every `.pyd`/`.dll` byte-identical to `C:\runtime\wheels\onnxruntime-*.whl`. Section 21's floor
    is 4 on amd64.
- **Usage**: `C:\opt\OrchestrANT\.venv\Scripts\python.exe` (or `uv run` from `TORCH_APP_DIR`) is a
  ready environment where `import onnxruntime, onnxruntime_genai, cv2, tvm, torch` all resolve to
  the source-built wheels plus the app's locked PyPI dependency set.

## Windows Script Reference

The **authoritative per-script reference** for the Windows lane (AGENTS.md § Windows Build Notes
points here; update THIS table, never a copy). Rows marked **HOST maintenance** run on the build
host, need the stated elevation, and must never run while a build solves.

Scan the list, then read the entry. Grouped by where the script lives; every entry is individually
linkable, and a refusal condition or a trap gets its own paragraph, not a table cell.

- **Chain components — `windows/scripts/build/`**: [`Build-OnnxFromSource.ps1`](#build-onnxfromsourceps1) · [`Build-OnnxGenaiFromSource.ps1`](#build-onnxgenaifromsourceps1) · [`Build-OpencvFromSource.ps1`](#build-opencvfromsourceps1) · [`Build-OpencvGstreamerPlugin.ps1`](#build-opencvgstreamerpluginps1) · [`Build-LitertFromSource.ps1`](#build-litertfromsourceps1) · [`Build-LitertLmBazel.ps1`](#build-litertlmbazelps1) · [`Build-LitertLmFromSource.ps1`](#build-litertlmfromsourceps1) · [`Copy-CudaRuntime.ps1`](#copy-cudaruntimeps1) · [`Build-TvmFromSource.ps1`](#build-tvmfromsourceps1) · [`Build-FfmpegFromSource.ps1`](#build-ffmpegfromsourceps1) · [`Build-GstreamerFromSource.ps1`](#build-gstreamerfromsourceps1) · [`Import-Versions.ps1`](#import-versionsps1) · [`Complete-Container.ps1`](#complete-containerps1) · [`Test-Toolchain.ps1`](#test-toolchainps1) · [`Test-Health.ps1`](#test-healthps1) · [`Test-Container.ps1`](#test-containerps1) · [`Set-TensorrtTree.ps1`](#set-tensorrttreeps1) · [`Copy-TensorrtRuntime.ps1`](#copy-tensorrtruntimeps1)
- **Host setup and maintenance — `windows/scripts/host/`**: [`Install-Vs.ps1`](#install-vsps1) · [`Install-ScoopTools.ps1`](#install-scooptoolsps1) · [`Install-Vcpkg.ps1`](#install-vcpkgps1) · [`Install-RustToolchain.ps1`](#install-rusttoolchainps1) · [`Install-Cuda.ps1`](#install-cudaps1) · [`Install-Tensorrt.ps1`](#install-tensorrtps1) · [`Publish-ShimPatch.ps1`](#publish-shimpatchps1) · [`Install-NewHost.ps1`](#install-newhostps1) · [`Set-Rdna4Gpu.ps1`](#set-rdna4gpups1) · [`Get-HostDockerState.ps1`](#get-hostdockerstateps1) · [`Reset-ContainerStores.ps1`](#reset-containerstoresps1) · [`Sync-DefenderExclusions.ps1`](#sync-defenderexclusionsps1) · [`Repair-WindowsComponentstore.ps1`](#repair-windowscomponentstoreps1) · [`Test-HostSetup.ps1`](#test-hostsetupps1) · [`Set-ContainerdConfig.ps1`](#set-containerdconfigps1) · [`Optimize-HostVhdx.ps1`](#optimize-hostvhdxps1) · [`Initialize-Pwsh.ps1`](#initialize-pwshps1) · [`Update-HostVhdx.ps1`](#update-hostvhdxps1) · [`Clear-DiskSpace.ps1`](#clear-diskspaceps1)
- **Diagnostics and probes — `windows/scripts/diagnostics/`**: [`Measure-BuildWarnings.ps1`](#measure-buildwarningsps1) · [`Test-BuildCopy.ps1`](#test-buildcopyps1) · [`Test-Rdna4LayerLock.ps1`](#test-rdna4layerlockps1) · [`Test-CudaCache.ps1`](#test-cudacacheps1) · [`Invoke-SccacheCudaLlmDeadlock.ps1`](#invoke-sccachecudallmdeadlockps1) · [`Test-GeniexNpuDriver.ps1`](#test-geniexnpudriverps1)
- **Reusable modules — `windows/scripts/modules/`**: [`WindowsSourceBuild.Common.psm1`](#windowssourcebuildcommonpsm1) · [`WindowsSmokeTest.Common.psm1`](#windowssmoketestcommonpsm1) · [`WindowsGstPlugins.Common.psm1`](#windowsgstpluginscommonpsm1)
- **Drivers and entry points**: [`Dockerfile.smoke-gate`](#dockerfilesmoke-gate) · [`Dockerfile.publish-gate`](#dockerfilepublish-gate) · [`patches/litert-lm/patch-assert.cmake`](#patcheslitert-lmpatch-assertcmake) · [`Test-SccacheWrite.ps1` + `Invoke-SccacheWriteProbe.ps1` + `Dockerfile.sccache-write-probe`](#test-sccachewriteps1--invoke-sccachewriteprobeps1--dockerfilesccache-write-probe) · [`Test-OpencvVideoBackends.ps1` + `Invoke-OpencvVideoProbe.ps1` + `Dockerfile.opencv-video-probe`](#test-opencvvideobackendsps1--invoke-opencvvideoprobeps1--dockerfileopencv-video-probe)
- **No entry here yet** (counted 2026-09-25; the script's header comment is its reference until one is written): `build/` — `Build-HailortFromSource.ps1`, `Build-IreeFromSource.ps1`, `Build-LitertAll.ps1`, `Build-LlvmFromSource.ps1`, `Build-MediaCoreAll.ps1`, `Build-MediaTvmAll.ps1`, `Build-MigraphxFromSource.ps1`, `Build-OrtAmdgpuEpFromSource.ps1`, `Build-ResourceSampler.ps1`, `Build-TargetCpython.ps1`, `Build-ToolchainAll.ps1`, `Build-TorchApp.ps1`, `Copy-TargetPythonDeps.ps1`, `Debug-LitertlmLink.ps1`, `Export-LitertLmBridge.ps1`, `Install-LlamaCpp.ps1`, `Install-TorchRocm.ps1`, `Test-RocmImage.ps1`, `Test-TargetArch.ps1`, `Write-BundleManifest.ps1`; `host/` — `Clear-SccacheMount.ps1`, `Disable-Sleep.ps1`, `Install-DufsService.ps1`, `Install-Rocm.ps1`, `Install-VulkanLoader.ps1`, `Invoke-BkMaterialize.ps1`, `Invoke-BkWarm.ps1`, `Reset-ContainerLocks.ps1`, `Set-BuildkitdGcpolicy.ps1`, `Set-ElevatedWindow.ps1`, `Start-GeniexServers.ps1`; `diagnostics/` — `Find-LsmEventHolder.ps1`, `Get-HostLsm.ps1`, `Get-LsmWaitObject.ps1`, `Get-LsmWaitstack.ps1`, `Get-SiloProcesses.ps1`, `Invoke-DiagnosticProbe.ps1`, `Invoke-LlvmAarch64Layout.ps1`, `Measure-WarningStream.ps1`, `Test-Arm64Prereqs.ps1`, `Test-GpuPassthrough.ps1`, `Test-LayerRename.ps1`, `Test-OnnxTuReplay.ps1`, `Test-OpencvCudaCmdshape.ps1`, `Test-ProcessIsolationCommit.ps1`. Several are described on the page that owns their topic ([`windows-cross-builds.md`](windows-cross-builds.md), [`windows-rocm.md`](windows-rocm.md), [`windows-build-lanes.md`](windows-build-lanes.md)).

### Chain components — `windows/scripts/build/`

Run inside the build container as chain stages, each invoked by a `*-all` wrapper or directly by
the driver.

#### `Build-OnnxFromSource.ps1`

Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper (§ ONNX Runtime). On the rocm
spike it also builds the in-tree WebGPU EP
([`windows-rocm.md` § ONNX Runtime WebGPU EP](windows-rocm.md#onnx-runtime-webgpu-ep-rocm-lane-spike)).

#### `Build-OnnxGenaiFromSource.ps1`

CMake+clang-cl, bypassing `build.py`: loads VsDevCmd via `vswhere`, clones the git tag, runs
`cmake`/`ninja` directly. The CUDA and DML DLLs, the `ORT_HOME` shim and the configure, tree and ORT
build gates that fail the stage on any ORT not from the chain: § ONNX GenAI above.

#### `Build-OpencvFromSource.ps1`

Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch. Builds dnn and G-API against the
chain ORT through a header shim, and ends in the ORT build gate (§ OpenCV 5.x above).

#### `Build-OpencvGstreamerPlugin.ps1`

**Standalone GStreamer videoio plugin (backlog #93).** It breaks the circularity without a second
OpenCV pass:

- **The circularity.** OpenCV configures in media-core BEFORE GStreamer exists, so its videoio
  ships with `GStreamer: NO` compiled in, and `cv::VideoCapture(..., CAP_GSTREAMER)` has no backend.
  GStreamer builds in the MERGE stage and needs OpenCV for its own gst-plugins-bad opencv elements
  (the other direction, which works).
- **The plugin.** OpenCV 5.0.0 ships `modules/videoio/misc/plugin_gstreamer`, a self-contained CMake
  project that builds `opencv_videoio_gstreamer` as a RUNTIME-LOADED DLL against an INSTALLED
  OpenCV, out of tree, from one source file (`cap_gstreamer.cpp`). videoio's plugin loader
  (`VIDEOIO_ENABLE_PLUGINS` ON by default) picks it up from the directory of `opencv_videoio*.dll`.
- **CONSEQUENCE FOR VERIFICATION, do not "fix" this back:** with the plugin route
  `cv2.getBuildInformation()` KEEPS saying `GStreamer: NO`; that string reflects videoio's
  COMPILE-TIME configuration, and this plugin is loaded at runtime. The authoritative runtime check
  is `cv2.videoio_registry.hasBackend(cv2.CAP_GSTREAMER)` (it attempts the plugin load); the #95
  smoke assertions were updated accordingly.
- **GStreamer detection on WIN32** uses find_path/find_library against `GSTREAMER_DIR`: OpenCV's
  `detect_gstreamer.cmake` does NOT use pkg-config on Windows, so the merge prefix (`C:\runtime`:
  `include\gstreamer-1.0`, `include\glib-2.0`, `lib\*.lib`) is handed over directly. No pkgconfig
  shim needed here, unlike the #94 FFmpeg route.

#### `Build-LitertFromSource.ps1`

Ninja+clang-cl; GPU delegate (Vulkan+OpenCL), XNNPACK, external CUDA delegate. Injects + builds the
TFLite C-API `tensorflowlite_c` shared lib (`WINDOWS_EXPORT_ALL_SYMBOLS` +
`/EXPORT:TfLiteXNNPackDelegate*`) for gst's tflite plugin.

#### `Build-LitertLmBazel.ps1`

**PRIMARY LiteRT-LM builder**: self-installs the pinned bazel + Temurin JDK, builds on Bazel's own
clang-cl toolchain behind an aquery gate (CON92), smoke-runs `litert_lm_main.exe` (§ LiteRT-LM).
Neutralizes the base image's Android env/WORKSPACE pollution; patches the WORKSPACE zlib URL to the
GitHub release mirror (zlib.net is flaky). `output_base` stays container-local (wcifs rename
hazard).

#### `Build-LitertWheelBazel.ps1`

The `ai-edge-litert` wheel for the pinned Python with Bazel's clang-cl toolchain, gated and
smoke-tested, then stored in `C:\runtime\wheels`; see § The ai-edge-litert wheel.

#### `Build-LitertLmFromSource.ps1`

**FROZEN FALLBACK** (superseded by the Bazel builder above). Ninja+clang-cl with the v0.14.0
export-bridge patch stack, gated on the breakage so it self-retires when upstream's CMake catches up
(§ Source Patch Policy #7).

#### `Copy-CudaRuntime.ps1`

Runs in the merge's `cuda-runtime-stage`, derived from the toolchain image since #134 (2026-08-26),
so it re-runs only when the toolchain does. Recursively FLATTENS the CUDA_ROOT/CUDNN_ROOT DLLs into
one dir COPY'd to `C:\runtime\cuda-runtime\bin` on PATH (cuDNN 9 buries DLLs in a CUDA-major
subdir; `bin\arm64` on the cross GPU lane, #176). Hard-gates on `cudnn64_9.dll`; stages an empty dir
and exits 0 when neither root is set (the CPU lanes). Fixes opencv's plugin load in the non-nvidia
merge image.

#### `Build-TvmFromSource.ps1`

Ninja+clang-cl; auto-detects CUDA/Vulkan/LLVM; builds Python wheel; VsDevCmd for MSVC STL headers
(§ TVM).

#### `Build-FfmpegFromSource.ps1`

MSYS2 `make` with `--toolchain=msvc`; loads `versions.env` via `Import-Versions.ps1` for the
centralized `FFMPEG_VERSION` tag pin. `--enable-libonnxruntime`, fail-closed builds and the BtbN
opt-in: § FFmpeg.

#### `Build-GstreamerFromSource.ps1`

Meson+clang-cl with wrap pre-extraction; loads `versions.env` via `Import-Versions.ps1`. Pins meson
to `PY_MESON_VERSION`, carries the DTLS fix for OpenSSL 4, stages the OpenSSL runtime into
`<prefix>\bin` on both lanes, builds `rswebrtc`/`rsrtp` from gst-plugins-rs in phase `8b`, and
checks the shipped `ffi-7.dll` with `Assert-LibffiTypeExport` before the plugin gate
(§ libffi's type exports, § DTLS with OpenSSL 4, § gst-plugins-rs on Windows).

#### `Import-Versions.ps1`

Reads `C:\temp\versions.env` and sets matching process env vars, so Windows build scripts consume
the same canonical versions as Linux.

- **The file** is `windows/generated/versions.env`, which `Build-Buildkit.ps1` writes from
  `linux/scripts/01-core/versions.env` on every run (`Write-WindowsVersionsEnv`, CON87): the same
  keys in the same order, minus comments and the Linux-only keys nothing under `windows/` names, so
  a riscv64 or Android pin bump no longer re-keys the base and every stage above it. A Linux-only
  key is one `$script:LinuxOnlyVersionKeyPattern` matches; a key that also says `WINDOWS`, or that a
  Windows script, Dockerfile or mounted Linux file names, always stays, so a gap in the pattern
  costs a rebuild and never a missing pin.
- **Overrides.** A key counts as an explicit override only when its process value differs from its
  Machine value: the base bakes every key into the Machine environment and every container process
  inherits it, so presence alone proves nothing. An override wins the RUN and is also written back
  to Machine, so the image records what it was built with, including the base's own ARG-mirrored
  keys; every other key is refreshed from the file. That is why media stages take pins as
  build-args instead of re-COPYing `versions.env`.

#### `Complete-Container.ps1`

Enables git long paths and sets `core.longpaths` in the final image. Writes the **toolchain
provenance manifest** `C:\toolchain-manifest.json` (2026-08-07; why:
§ Toolchain pins and the provenance manifest): pinned inputs with pin-vs-resolved pairs (LLVM,
ninja, nasm, sccache, CMake, Vulkan, Git, Flutter, VS→MSVC toolset, SDK build) plus the floating
ones (lld-link, rustc/cargo, uv, pwsh, openssl, pkg-config) and the OS base digest. Every probe is
best-effort (missing tool → `null`, never a failed layer).

#### `Test-Toolchain.ps1`

Verifies clang-cl, lld-link, WiX, Flutter are present after base setup, and ASSERTS the pinned
versions (clang-cl/ninja/nasm/CMake vs `versions.env`); a silent scoop fallback otherwise surfaces
~2 h into media-core as a patch that no longer applies.

#### `Test-Health.ps1`

Docker `HEALTHCHECK` script: verifies ONNX Runtime DLL, FFmpeg, GStreamer, CMake, clang-cl.

#### `Test-Container.ps1`

Comprehensive container validation, **25** test categories (23 until section 24, Hailo, and section
25, the ORT single-source census, landed in 2026-09). Runs INSIDE the final
image, which `windows/Dockerfile` COPYs it into along with the whole `modules` dir. The 25 sections
live here; the assertion harness is in `WindowsSmokeTest.Common.psm1`. The smoke imports
`WindowsContainerImage.Common` for version precedence and VS root discovery. A missing
module fails before section reporting; the final image's modules COPY and the live
smoke mount both provide it. There are no private fallback implementations.

#### `Set-TensorrtTree.ps1`

Bind-mounted into `Dockerfile.nvidia`'s `trt-extract` stage. Renames the extracted tree to
**`current`** so the runtime PATH never spells the pin, WARNS (never fails) on pin-vs-zip drift,
and **fails closed** when neither `bin\` nor `lib\` carries runtime DLLs. Why (backlog #38):
§ TensorRT setup (GPU lane, optional).

#### `Copy-TensorrtRuntime.ps1`

Bind-mounted into `trt-extract` after `Set-TensorrtTree.ps1`. Copies the DLLs ORT's TensorRT EP
loads, and the licence texts, into `C:\tensorrt-runtime`, which the sdk image COPYs as `C:\tensorrt`;
throws when one of the four kinds is missing. Zip-less, it leaves the destination empty.
§ TensorRT setup (GPU lane, optional).

### Host setup and maintenance — `windows/scripts/host/`

Run on the HOST, most of them elevated. Several refuse while a build is solving, on purpose.

#### `Install-Vs.ps1`

Installs VS Build Tools 18 with ClangCL toolset.

#### `Install-ScoopTools.ps1`

Installs Git (installer) + WiX 7 (dotnet tool, with the wix7 OSMF EULA accepted for the image user),
then via Scoop: 7zip, Vulkan SDK (plus its optional ARM64 component), Flutter, LLVM (plus the
aarch64 compiler-rt builtins from the matching release archive), ninja, nasm, cppcheck, nano, nsis,
uv, nuget, zlib, openssl (plus the arm64 build beside it), pkg-config, CMake, make, gawk.

- Installs **no** Rust (rustup via `Install-RustToolchain.ps1` is the sole provider) and, since
  2026-09-18, **no** sccache (`Install-RustToolchain.ps1` installs the pinned released zip).
- **PINNED from versions.env (2026-08-07): LLVM/ninja/nasm** (`LLVM_WINDOWS_VERSION`/
  `NINJA_WINDOWS_VERSION`/`NASM_WINDOWS_VERSION`, forwarded as Dockerfile ARGs), on top of the
  existing CMake/Vulkan/Flutter/Git pins: an unpinned clang-cl made the base image unreproducible in
  its most load-bearing component. `Test-Toolchain.ps1` asserts all three at base-build time. Why
  pinned, and why the rest float: § Toolchain pins and the provenance manifest.
- **The 2026-08-08 caveat that the floating rule stops holding for `sccache` once multi-tier caching
  is wired is settled:** sccache is pinned (`SCCACHE_WINDOWS_VERSION`, recorded pin-vs-resolved in
  the toolchain manifest) and no longer comes from scoop.

#### `Install-Vcpkg.ps1`

Bootstraps vcpkg for Windows.

#### `Install-RustToolchain.ps1`

Installs Rust via rustup WITH the pinned `RUST_VERSION` default toolchain (sole provider;
§ Rust toolchain). A local `file://` dist mirror dodges rustup's downloader deadlock in 2-CPU
containers. Runs Cargokit-shaped asserts, bakes `flutter_rust_bridge_codegen`.

#### `Install-Cuda.ps1`

Installs CUDA + cuDNN at the `versions.env` pins, with post-install verification
(headers/libs/DLLs). `-TargetArch arm64` also stages the Windows-arm64 redist components and cuDNN
into the same root (`lib\arm64`, `bin\arm64`; #176).

#### `Install-Tensorrt.ps1`

Auto-detects a TensorRT zip in `windows/downloads/` and installs it.

#### `Publish-ShimPatch.ps1`

HOST maintenance (admin, never while a build solves): installs a locally built
`containerd-shim-runhcs-v1.exe` over Stevedore's, keeping `.orig` (stock, written once) plus a
timestamped backup per deployment, and optionally merges env vars into the containerd service
(`-ServiceEnvironment`), since the shim inherits them.

- `-ReportOnly` lists installed binary, backups and env without touching anything;
  `-Restore .orig` / `-Restore .45min` puts a backup back.
- Refuses while `buildctl` or a shim process is alive (the binary is locked).
- Needed because every Stevedore/containerd update silently reverts the patched shim
  (§ The Windows lane as AGENTS.md carried it, [`windows-build-lanes.md`](windows-build-lanes.md)
  § BuildKit/containerd lane and `windows/upstream/`).
- NB: a quiet log is NOT proof it took effect (the shim logs its effective timeout at Debug, which
  does not reach containerd's log). Verify behaviourally with the OpenCV canary.

#### `Install-NewHost.ps1`

HOST bring-up (admin, run `-ReportOnly` first, never while a build solves): the ONE elevated run that
turns a freshly-rebooted Stevedore host into a green `Test-HostSetup.ps1`, its companion below. It
orchestrates the canonical per-concern scripts rather than duplicating them, in this order:

1. Authors the CNI `.conflist` from the LIVE `vEthernet (nat)` subnet (network/prefix+GW derived at
   runtime; no magic subnet literals anywhere).
2. `Set-ContainerdConfig.ps1` (derives the `.conf`, debug flags, teardown env, Defender).
3. `Set-BuildkitdGcpolicy.ps1` + the `BUILDKIT_STEP_LOG_*` step-log env.
4. The patched runhcs shim (§ The Windows lane as AGENTS.md carried it). Without `-ShimPath` it
   BUILDS the env-configurable shim from the owner's fork at a pinned commit (installing Go via
   scoop), then runs `Publish-ShimPatch.ps1` with the teardown env on the containerd service; the
   45min/100min fixed-constant builds are history.
5. dufs: scoops it if missing, starts it, registers the ONLOGON task, sets machine
   `SCCACHE_WEBDAV_ENDPOINT` to the host's LAN IP.
6. The host's `TcpTimedWaitDelay` at 30 s (#179, live after a reboot; `-SkipTcpTimeWait` leaves it).

Idempotent. Every sub-script is called with a HASHTABLE splat: array splatting would bind
`-ReportOnly`/`-ShimPath` by position (the array-splat rule in AGENTS.md).

#### `Set-Rdna4Gpu.ps1`

HOST maintenance (admin): enable/disable the RDNA4 dGPU in Device Manager. `-GpuName` overrides the
RX 9070 XT default; the gate fires for ALL RX 9xxx/R9700 SKUs, so the remedy must reach them too
(added 2026-08-10 W1). **RE-INSTATED 2026-08-10 as the RDNA4 build-window workaround** (the
2026-08-09 "obsolete" verdict is superseded): an enabled RDNA4 dGPU kills every process-isolated
RUN-layer finalize (`ActivateLayer 0x20`, docker/for-win#14977; A/B-proven). Workflow: `-Disable` →
build (display falls back to the iGPU) → default action re-enables. `Build-Buildkit.ps1`'s
`Assert-NoActiveRdna4Gpu` preflight refuses while the dGPU is enabled.

#### `Get-HostDockerState.ps1`

Cross-machine forensics for "works there, fails here": dumps OS build, optional features (DISM API
health; reports "Klasse nicht registriert" when broken), filter drivers, services, engine versions,
docker info, HNS. Writes `out\host-docker-forensics.txt`. Elevation needed for feature/fltmc reads.

#### `Reset-ContainerStores.ps1`

HOST maintenance (admin, never while a build solves): full container-store reset. Stops the
services, RENAMES `C:\ProgramData\containerd`/`buildkitd`/`Docker` to `.bak-<stamp>` (rollback),
restarts clean, re-deploys the GC-policy toml. The docs' last resort for persistent, non-release
hcsshim weirdness; safe on a fresh host (stores re-pull).

#### `Sync-DefenderExclusions.ps1`

HOST maintenance (admin): prints, then applies if missing, the FULL Defender exclusion set for
Windows-container builds: paths (`C:\ProgramData\containerd`/`buildkitd`/`Docker`/`nerdctl`,
`C:\ProgramData\Microsoft\Windows\Containers`, `C:\temp`, `C:\WINDOWS\SystemTemp`) and processes
(dockerd/containerd/buildkitd/nerdctl/CExecSvc/vmcompute). READ the BEFORE output: non-admin cannot
see `Get-MpPreference`, so this is the only proof exclusions were ever applied.

#### `Repair-WindowsComponentstore.ps1`

HOST maintenance (admin, long-running 10-40 min): `DISM /Online /Cleanup-Image /RestoreHealth` +
`sfc /scannow`, re-tests the DISM API (was `Klasse nicht registriert` on the reference-discovered
box), then re-runs the 3-layer probe. The OS-level repair step for hosts where container-layer ops
fail and everything else is clean.

#### `Test-HostSetup.ps1`

The machine-checkable form of `docs/windows-host-setup.md`: run it FIRST on any new machine, and
after any host change. Non-admin. Checks:

- services, `buildctl` reaching buildkitd unelevated, nerdctl presence;
- **BOTH CNI forms** (`.conf` for buildkitd: missing is a FAIL; `.conflist` for nerdctl: missing is
  a WARN), content agreement between them, and subnet-vs-adapter drift;
- the patched runhcs shim **by SHA256** against the hash `Publish-ShimPatch.ps1` recorded at
  install (size only as a fallback, reported as a WARN so "still guessing" is visible);
- containerd teardown env var + debug flags, worker snapshotter + gcpolicy;
- disk headroom **on C: AND the repo/build-context drive**, sccache reachability.

Exit 1 on any FAIL; each failure prints its fix. Defender exclusions are reported UNKNOWN (not
skipped) when unelevated, so their absence cannot masquerade as success. Registry values that do not
EXIST (e.g. the containerd `Environment` value before the first apply) degrade to WARNs, not a
mid-run crash (fixed 2026-08-09: the old `(Get-ItemProperty ...).Environment` threw
PropertyNotFound at line 212 and silently skipped the teardown-env + debug-flag checks,
under-counting the verdict). **Keep it in step with the guide; they are two views of one
contract.** The guide had shipped a broken CNI template for days precisely because prose cannot be
executed.

#### `Set-ContainerdConfig.ps1`

HOST config (admin; never while a build solves: applying restarts containerd and kills in-flight
solves). The containerd counterpart to `Set-BuildkitdGcpolicy.ps1`. It owns the debug-log flags and
the runhcs shim teardown timeout, which live only in the service's registry values because
containerd runs with no `config.toml` here, plus containerd's Defender exclusions, and it derives
the CNI `.conf` from the authored `.conflist`. What each setting is for, and why a script is the
only reproducible way to hold them:
[`windows-host-setup.md`](windows-host-setup.md#c1-permanent-debug-flags-on-containerd--buildkitd-owner-policy).

#### `Optimize-HostVhdx.ps1`

HOST maintenance (admin, never while a build solves): reclaims disk when the checkout/store sits on
a dynamically-expanding VHDX. Kills stale `buildctl`, stops the build services, detaches → compacts
(`Optimize-VHD`) → reattaches read-write in a `finally`, restarts. `-ReportOnly` reports
sizes/guest-fs/reclaim potential without touching anything. Machine-specific values are all
parameters (`-VhdxPath` mandatory, `-Service`, `-BlockingProcess`, `-VerifyPath`, `-LogPath`,
`-Mode`). Warns on ReFS guests, where compaction reclaims ~nothing (measured: 0.2 GB of a possible
254 GB; [`windows-build-lanes.md`](windows-build-lanes.md) § Store GC). When it reports a near-zero
reclaim, `Update-HostVhdx.ps1` is the answer.

#### `Initialize-Pwsh.ps1`

Installs PowerShell 7 as the FIRST RUN of `Dockerfile.base`, BIND-MOUNTED (no layer). Runs under
Windows PowerShell **5.1** (the SHELL switches to pwsh only after it), so keep it 5.1-safe and do
not use `Invoke-DownloadWithRetry` (no module is mounted that early). Carries its own 3-attempt
retry with an in-loop SHA256 check. Extracted from a 1214-char inline RUN (backlog #27).

#### `Update-HostVhdx.ps1`

HOST maintenance (admin, never while a build solves): reclaims a dynamically-expanding VHDX by
REBUILDING it around its live data, the only reliable reclaim on ReFS guests, where
`Optimize-HostVhdx.ps1` returns ~nothing.

- Creates a fresh dynamic disk, reproduces the source's filesystem/label/cluster size (and Dev
  Drive flag where `Format-Volume -DevDrive` exists), mirrors with `robocopy /MIR /COPYALL`, then
  verifies file count AND byte totals before anything is swapped.
- TWO PHASES on purpose: `-CopyOnly` touches nothing live and is safe with editors/agents still on
  the volume. The swap DETACHES the volume and so requires that no process holds a handle on it (a
  stray detach on 2026-08-06 pulled D: out from under a running session and killed it); it REFUSES
  rather than forces, keeping the verified copy for a later `-SwapOnly`.
- Old disk kept as `.old` unless `-RetireOld`; **no space is reclaimed until it is deleted.** Failed
  swaps roll back to the original disk automatically.
- Parameters: `-VhdxPath` mandatory, `-NewSizeGB`, `-NewVhdxPath`, `-Service`, `-BlockingProcess`,
  `-VerifyPath`, `-ExcludeDir`, `-LogPath`, `-ReportOnly`, `-CopyOnly`, `-SwapOnly`, `-RetireOld`,
  `-Force`. Put `-LogPath` off the volume for swap runs.

#### `Clear-DiskSpace.ps1`

HOST disk reclaim: **the only sanctioned one; never compose an ad-hoc cleanup command** (2026-08-21
incident: an improvised one went past the container stores into the installed programs and the user
profile, and the host had to be rebuilt by hand).

- **Cleans exactly the regenerable classes**: **unused container layers**
  (`buildctl prune --free-storage`, `docker image prune -f`; the daemon knows what is still
  referenced), **dead `*.bak-<stamp>` store husks** left by `Reset-ContainerStores.ps1`, **user +
  Windows TEMP**, rotated host logs and repo `out/` scratch.
- Works from an ALLOWLIST, never a denylist; **reports by default, `-Apply` is required to delete**;
  every live-directory rule is **age-gated** (`-TempOlderThanDays`, default 7), so nothing in flight
  is touched.
- `-StoreHusksOnly` selects only `C:\ProgramData\{containerd,buildkitd,Docker}.bak-*`
  directories and disables every daemon report/prune call, even with `-Apply`. It excludes TEMP,
  logs and checkout scratch. Report with this selector first; apply only after checking the list.
- Fails the WHOLE run if any resolved candidate lands on a protected root (Program Files, Windows,
  ProgramData outside the container stores, user profiles, AppData, drive roots): that means the
  resolution logic is wrong, not that one target should be skipped.
- Skips any candidate containing a junction/symlink or an unreadable descendant: an incomplete
  traversal cannot prove containment. Rechecks the tree immediately before deletion. A skipped
  or locked husk remains in place; do not bypass its ACLs or use a different deletion tool.
- The **file allowlist excludes sccache/ccache/cargo/uv compile caches** and installed software.
  Daemon GC is separate: its existing unfiltered BuildKit prune can select unused cache mounts;
  use `-StoreHusksOnly` to disable it for husk cleanup. Refuses the destructive half while a build
  looks live unless `-AllowDuringBuild`.
- Parameters: `-Apply`, `-KeepGB` (buildkit free-space target, default 100), `-TempOlderThanDays`,
  `-AllowDuringBuild`, `-NoDaemonPrune`, `-StoreHusksOnly`.
- Enforced from outside the script too, by the `PreToolUse` guard in
  `.claude/hooks/guard-destructive-deletes.ps1`; behaviour pinned by
  `windows/scripts/tests/Guard.DestructiveDeletes.Tests.ps1`.

### Diagnostics and probes — `windows/scripts/diagnostics/`

Read [`windows-build-invariants.md`](windows-build-invariants.md#when-a-probe-says-the-product-is-broken-suspect-the-probe-first)
before trusting any verdict here: three probes lied before one told the truth.

#### `Measure-BuildWarnings.ps1`

Counts compiler warnings in a build log grouped by diagnostic family; `-Baseline` prints the four
known upstream floods against their pre-suppression counts with a verdict per family. Run it after a
chain to PROVE the targeted `-Wno-` flags (OpenCV/ONNX/TVM) and IREE's
`_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING` still earn their place: 16 % of one chain log was
upstream warnings, and buildkitd clips a RUN step at 2 MiB, then deadlocks it.

#### `Test-BuildCopy.ps1`

The committed build probe (assets `windows/scripts/diagnostics/probe-build-copy/`):
`FROM servercore` + `RUN` + `COPY`, BK lane exporting `type=image,...,unpack=true` (the real lane's
output path), per-lane exit codes. `-Heavy` adds the heavyweight-RUN finalize lane (the shape the
RDNA4 interaction kills), `-Docker` the classic-builder lane. **Run `-Heavy` before trusting a new
Windows host**: only a `-Heavy`-green verdict counts (light lanes stayed green while the chain died,
2026-08-10). No admin.

#### `Test-Rdna4LayerLock.ps1`

RDNA4 layer-lock A/B (ELEVATED): probes RUN-layer finalize with the dGPU enabled, then disabled
(auto re-enables in a finally). Verdicts: GONE / PRESENT / INCONCLUSIVE. **Re-run after every
Adrenalin or Windows update**: a GONE verdict is the signal to retire the toggle workflow +
`Assert-NoActiveRdna4Gpu` gate (docker/for-win#14977 tracked upstream).

#### `Test-CudaCache.ps1`

CUDA-cache probe (non-admin, ~2 min, safe beside a live build): a tiny buildctl solve FROM the local
toolchain image compiles one `.cu` TWICE through sccache against the live WebDAV endpoint. Exit 0
only when the recompile HIT (per-component: CUDA/Device/PTX/CUBIN) AND objects landed in the store.
Verified 2026-08-10 (4/4 hits, 4 objects on disk). **Run after every sccache bump**: the launcher's
value rests on this property.

#### `Invoke-SccacheCudaLlmDeadlock.ps1`

**Obsolete since 2026-08-18.** It reproduced the sccache nvcc server deadlock for
mozilla/sccache#2808 by setting `SCCACHE_REPRO_CUDA_LLM=1`, which made `Build-OnnxFromSource.ps1`
skip patch 006 so the sccache CUDA launcher stayed on for `onnxruntime_providers_cuda_llm`. Patch 006
and that knob were retired on 2026-08-18: the fused_moe family goes through the launcher on every
build, and the ARG stays declared in `Dockerfile.media-builder` only so old commands do not silently
no-op; nothing reads it. #2808 is closed, fixed in the sccache 0.18.0 release this lane pins
([`upstream-windows-patches.md`](upstream-windows-patches.md)). A run today is an ordinary `-Gpu`
media-core rebuild. It still refuses to start while another `buildctl` is running.

#### `Test-GeniexNpuDriver.ps1`

Diagnoses why GenieX's Hexagon NPU path fails on a Snapdragon X Windows host. Checks the **active**
CDSP `libcdsprpc.dll` (matched to the Hexagon NPU device's installed driver version; the DriverStore
keeps stale copies that would otherwise produce false verdicts) for the `dspqueue_*` symbols GenieX
v0.5.0's bundled llama.cpp `ggml-hexagon` backend dlsyms. A driver predating 2026 exports only the
legacy FastRPC API and fails with `ggml-hex: failed to dlsym dspqueue_create` /
`Device 'HTP0' not found`. Reporting only; never throws on a negative result. See
[`geniex-local-ai-setup.md`](geniex-local-ai-setup.md) § The NPU problem.

### Reusable modules — `windows/scripts/modules/`

Consumer-facing PowerShell API. Never delete on a "zero references" audit: other Kataglyphis repos
import these.

#### `WindowsSourceBuild.Common.psm1`

Reusable build helpers: `Invoke-GitClone`, `Invoke-CmakeConfigure`, `Get-SourceBuildVersion`,
`Get-CudaRoot`, `Enter-VsDevCmdEnvironment`, `Invoke-SourcePatch` (idempotent, reverse-check,
patch.exe fallback), `Edit-CppKeywordAlternatives`, `Update-NinjaFile`,
`Initialize-SourceBuildEnvironment`, `Initialize-ToolchainPythonEnvironment`, `Get-GpuEnvironment`,
`Resolve-TensorRtRoot`, `Get-WindowsTargetSimdFlags`, `Get-WindowsTargetKernelSimdFlags` (the
arch-agnostic pair that replaced `Get-WindowsX86SimdFlags`/`Get-WindowsX86Avx512Flags`, deleted
2026-08-26). This facade is mounted into all 11 media RUNs, so single-consumer helpers live on the
leaf modules instead: `Write-AssembledWheelDistInfo` and `Get-PyprojectDependencies` moved to
`WindowsTvm.Common.psm1` (2026-08-31), their only caller being `Build-TvmFromSource.ps1`.

#### `WindowsSmokeTest.Common.psm1`

Smoke-test assertion harness, extracted 2026-08-08: counters plus `Initialize-SmokeTestRun`,
`Get-SmokeTestSummary`, `Assert-Test`,
`Assert-CommandExists/FileExists/DirectoryExists/ArtifactPresent/NativeLinkRun/DllLoads/EnvVarSet`,
`Skip-Test`, `Write-TestHeader`. **Call `Initialize-SmokeTestRun -ExitOnFirstFailure:$ExitOnFirstFailure`
before the first assertion, and read counts via `Get-SmokeTestSummary`.** The module has its own
session state, so `$script:passed` read from a caller resolves to a different, always-zero variable,
and a script parameter is invisible to the module. Both failure modes are silent, which is why they
are unit-tested.

#### `WindowsGstPlugins.Common.psm1`

The mandatory GStreamer plugin CONTRACT (§ Mandatory GStreamer plugins and
AGENTS.md § Windows Build Invariants):

- `Get-RequiredGstPlugin`: libav/opencv/onnx/webrtc/nice/tflite, WebRTC's
  dtls/srtp/sctp/rtpmanager/openh264 and the gst-plugins-rs rswebrtc/rsrtp, with per-plugin
  detection mechanism and rationale.
- `Get-GstRustCargoPlan`: the cargo build of the `cargo` entries.
- `Invoke-GstWebRtcLoopback`: the smoke test's webrtcsink to webrtcsrc run.
- `Write-PkgConfigFile`, `Get-LibraryLinkName`, `Assert-PkgConfigModule` (presence AND
  `-MinimumVersion` floors; `pkg-config --exists` alone passes on a `.pc` whose version field is
  empty).

Merge-stage only, deliberately NOT in `WindowsScripts.Shared.psm1` (why:
§ Mandatory GStreamer plugins).

### Drivers and entry points

The top-level scripts a human or CI actually invokes.

#### `Dockerfile.smoke-gate`

*`windows/`*

Not a script: the automatic verification stage (backlog #44), solved against the finished image as
the last step of every BK chain, on **both lanes** since 2026-08-24 (arm64: its own floors, 76/20).
Runs a buildctl solve rather than `nerdctl run`, because containerd's pipe is admin-only while the
driver is non-admin. Invokes the test **through `entrypoint.cmd`** and **bind-mounts** the current
script + modules; why both: § Smoke Testing. Knobs: `-SkipSmokeGate`, `-SmokeMinPassed`,
`-SmokeMaxSkipped`.

#### `Dockerfile.publish-gate`

*`windows/`*

Not a script: the publish gate (2026-09-23). `Invoke-BkPublishGate` solves it `-NoOutput` at three
points of every lane, the last one before any export or push, and **`-SkipSmokeGate` skips none of
them**. Its one RUN bind-mounts `WindowsImageEnv.Common.psm1` and runs `Assert-ImageEnvPublishable`,
which fails when the image's environment (the config ENV plus the Machine and User registry scopes)
carries a build-host sccache variable or an RFC1918/link-local address. No ARG after FROM and no
entrypoint, so the environment it grades is the one that ships. The three points, why it exists and
what it cannot see:
[`windows-build-resources.md` § What the published image carries](windows-build-resources.md#what-the-published-image-carries).
Tests: `ImageEnv.PublishGate.Tests.ps1` (the matcher against
`linux/scripts/tests/image-env-cases.json`, one mutant per rule, and the driver's call order).

#### `patches/litert-lm/patch-assert.cmake`

*`windows/scripts/`*

`patch_replace_required` / `patch_regex_replace_required`: replace-with-verification for the CMake
source patchers (backlog #56). They `FATAL_ERROR` when a pattern matched NOTHING, instead of the old
bare `string(REPLACE)` + unconditional "Patched …" message that let an upstream reformat silently
restore a fixed defect. Lives INSIDE `litert-lm/` because the Dockerfile COPYs that directory
specifically. Enforced by `Patches.CmakeNoOpGuards.Tests.ps1`; a legitimate non-source replace opts
out with a `patch-assert-exempt` marker + reason.

#### `Test-SccacheWrite.ps1` + `Invoke-SccacheWriteProbe.ps1` + `Dockerfile.sccache-write-probe`

*`windows/scripts/`, `windows/`*

Reproduces the sccache **cache-write** environment in ~2 min instead of a 90-min media build
(backlog #99): same cache-mount ids, same sccache settings (the endpoint as a secret mount since
2026-10-20, like the real stages, passed through `Invoke-DiagnosticProbe.ps1 -Secret`; the chain an ARG;
[`windows-build-resources.md` § What the published image carries](windows-build-resources.md#what-the-published-image-carries)),
then a configuration matrix (`disk-only`, `disk-mounted-subdir`, `disk-plaindir`,
`multilevel-mounted`, `multilevel-plaindir`, `webdav-only`), raw filesystem tests, a process-spawn
matrix, a bisect of the cache root, serial-vs-parallel and path-length sections.

- **Run it against the REAL base image**
  (`-BaseImage local/kataglyphis:bk-windows-media-core-ffmpeg`), not the toolchain default.
- **Health warning:** it reproduces the ENVIRONMENT but not the FAILURE. Every configuration it
  blessed then failed in a real build, so treat its verdicts as hypotheses to test in a build, never
  as clearance.
- `PROBE_NONCE` + a `probe complete` marker check exist because an unchanged script gives
  `#6 CACHED` and silently replays an old verdict; `--no-cache` is not the alternative (it empties
  cache mounts, #96).

#### `Test-OpencvVideoBackends.ps1` + `Invoke-OpencvVideoProbe.ps1` + `Dockerfile.opencv-video-probe`

*`windows/scripts/`, `windows/`*

Asks a BUILT media image what video backends OpenCV actually has (backlog #93-#95): prints the
`Video I/O:` block, runs the three #95 assertions, and shows `videoio_registry.getBackends()` beside
them. ~4 s against a built media-core image, versus a full chain rebuild. Pass
`-BaseImage local/kataglyphis:bk-windows-media-core` (or `-opencv`): the script's default, the
`-ffmpeg` intermediate, has carried no OpenCV since #94 moved OpenCV after FFmpeg, which is what let
the #95 guards be watched FAILING on the real artifact before the fixes landed. Same two safeguards
as the sccache probe: `PROBE_NONCE` (a re-run with an unchanged script otherwise gives `CACHED` and
replays an old verdict) and a `probe complete` marker check; `--no-cache` is not the alternative, it
empties cache mounts (#96).

## Why the pin suite runs on a Windows runner, under Pester 3.4.0

Written here once because three consumers each carried a 40-line copy of it in their own
`submodule-pins.yml`, and they had begun to disagree.

- **Windows runner.** `.github/actions/run-pester-suite` installs **Pester 3.4.0** by default, the
  dialect BeschleunigerBallett's Windows lane pins, and 3.4.0 is a Windows PowerShell-era module.
  So the lane needs a **Windows** runner, not one of the cheaper `ubuntu-26.04` ones the rest of the
  Linux jobs use.
- **The suite is version-agnostic**: `shared/windows/tests/Submodule.Pins.Tests.ps1` asserts with
  `throw` rather than `Should`, verified under both 3.4.0 and 6.1.0. The lane can move to a cheaper
  runner the day the action's invocation survives a Core-compatible Pester. Today it does not: 5.x
  loses the per-failure diagnostics and 6.x rejects `-Quiet` (measured 2026-09-07). The workflow's
  `pester-version` and `runner` inputs are the switch; nothing else has to change.
- **The label is `windows-2025`, pinned**, not `windows-latest`. The alias resolves to windows-2025
  today, so pinning is a no-op right now; a future repoint would swap the OS image, and with it the
  Windows PowerShell 5.1 that Pester 3.4.0 needs, under a green build with no commit to blame.

The hub's `submodule-pins.yml` is `workflow_call`-able, so a consumer calls it with `uses:` and
inherits all of the above instead of restating it:

```yaml
jobs:
  pins:
    uses: Kataglyphis/ANTfrastructure/.github/workflows/submodule-pins.yml@develop
```

## Reusable module: WindowsContainerBuild.Reuse

`windows/scripts/modules/WindowsContainerBuild.Reuse.psm1` packages the container-reuse pattern so
consumers do not each reinvent it. Consumers resolve it ANTfrastructure-first with a vendored
fallback (see BeschleunigerBallett's `scripts/windows/Resolve-BuildModule.ps1`).

- `Invoke-ContainerBuild` - the entry point: runs a consumer's build command in the image over the
  tar pipe (default) or a bind mount (`-UseBindMount`) and returns a result object. `-InboundItems`
  (default `.`) selects the top-level entries to stream, so a root directory can be dropped without
  a pattern that bsdtar would also match at every depth
  (`windows-container-build-performance.md` § Transport A). `Resolve-ContainerBuildCommand`,
  `Get-ContainerEnvArgs` and `Get-SccacheContainerEnv` are its exported helpers.
- `Get-ReusableBuildContainer` - reuse/start/recreate a named build container, recreating it when
  the image ID changes. Returns whether an existing container was reused.
- `Copy-IntoBuildContainer` / `Copy-FromBuildContainer` - tar-pipe transfers with exclusion support
  (mandatory for deep paths; one over-long path aborts the whole transfer).
- `Remove-StaleContainerSources` - prune non-build directories from a reused workspace (tar
  extracts over the tree but never deletes).
- `Initialize-ContainerPwsh` - ensure PS 7 exists in a running container (scoop install fallback).
- `Test-BuildArtifactsDelivered` - throw when a green build produced no executables or the outbound
  transfer silently delivered nothing.
- `Resolve-DockerExe`, `Get-ContainerIsolationArgs`, `Test-ContainerBindMount`,
  `Remove-BuildContainerSafe` - docker discovery, isolation args, bind-mount probing,
  wcifs-tolerant removal.
- `Wait-ContainerExit` - wait on the CONTAINER's state and return the exit code it really had,
  instead of trusting the docker client. The CLI intermittently drops its pipe mid-run while the
  container keeps building, and the client then reports a failure that did not happen: the same
  lost-exit-notification family as the 2026-09-01 `tearDownTimeout` finding, one layer up.
  Upstreamed from OxidANT's Stevedore lane, which had hand-rolled it.

**`Wait-ContainerExit` applies only to a container whose MAIN process is the workload**:
`docker run --name`, and never `--rm`, because `--rm` has the daemon delete the container (and its
exit code) the instant it exits.

- So `Invoke-ContainerBuild`'s **bind-mount** transport names its run and removes it itself, on
  success only: a failed or timed-out run keeps the container so the `docker logs` advice in its
  error stays runnable, and a leftover name that cannot be freed gets a unique fallback instead of a
  false green (`windows-container-build-performance.md` § Reusable implementation).
- The **tar-pipe** transport cannot use it: its reusable container's main process is a 7-day
  `ping`, so `State.Status` reads `running` whatever an exec'd build did. There a non-zero
  `docker exec` is classified against the container's state instead, so "the container died under
  the build" is no longer reported as a build error to hunt in the log.

**Docker's output goes to the host, never into a function's result (2026-09-23).** Consumers call
`$null = Invoke-ContainerBuild ...`, and the build's `docker exec` (tar pipe) and `docker run` (bind
mount) wrote their stdout into the function's output, so that one `$null =` swallowed every line of
a failing CI build, including the sccache failure that made CMake call clang-cl broken. Every docker
call whose output nothing consumes now ends in `| Out-Host`; `$LASTEXITCODE` still reads the docker
client's exit code after the pipe, and the function returns its result object alone.
`ContainerBuild.Output.Tests.ps1` holds the class guard (an AST scan for any unconsumed
`& $DockerExe` pipeline in the module) and a child-session check that a discarded result still
prints the build.

**The host's sccache remote tier is forwarded at run time (2026-09-24).** The image no longer
carries `SCCACHE_WEBDAV_ENDPOINT`, so `Invoke-ContainerBuild` adds this host's endpoint and chain to
`-CacheEnv` as `-e` entries unless the caller set them (`''` opts out):
[`windows-build-resources.md` § The build host's remote tier, at run time](windows-build-resources.md#the-build-hosts-remote-tier-at-run-time).

### Shared executable lookup

`WindowsScripts.Shared` exports `Resolve-BuildExecutable`, used internally by both
`WindowsAppRunner.Common` and `WindowsTesting.Common`. Each caller supplies its own
ordered directories. The app runner searches the root and `bin` first, then
`bin/<configuration>` and `<configuration>` for each requested configuration; direct
hits return a resolved path. The test runner searches the root, Debug, Release,
RelWithDebInfo and additional directories; direct hits retain the caller's path.
Both then search recursively and return null on a miss. Vendoring the app runner
also requires `WindowsScripts.Shared.psm1` beside it; both callers import the shared
module without `-Force`.

`Executable.Lookup.Tests.ps1` checks those orders, path forms, recursive fallback
and absence using empty files. Its `-Standalone` mode runs these four cases with
an explicit count and exit status. It starts no application and proves no Windows
binary can run. Mutation checks reverse the candidates, remove app normalization
and remove recursion; each must fail the suite.

## Structural test AST helpers

`TestHarness.psm1` owns file/snippet parsing, exact command-name queries and static
parameter binding. `Get-TestAstCommands` includes nested scopes; callers retain
their lane/ancestor checks. `Get-TestScriptCommands` combines file loading and a
command query. `Get-TestCommandArguments` returns the original argument source,
including quotes, rather than evaluating it. The parser helpers reject malformed
input and never execute the inspected script.

OpenCV wiring tests use these queries and the shared binder. Structural driver,
Python, ROCm and smoke suites use the parser helpers. `Harness.Ast.Tests.ps1`
checks nested queries, exact names, unparameterized commands and non-execution.
Target-architecture tests retain independent literal SIMD expectations and check
that modifying a cloned record cannot change flags or MLAS floors. These fixtures
provide no native Windows build or runtime proof; suites using Windows drives or
command files also need a Windows run.

`Invoke-WithFunctionModule` also accepts an optional prelude, import prefix,
constructor argument array and body argument array. Defaults retain existing
mutant imports. The helper owns module and temporary-directory cleanup even when
the body throws; callers keep their fixture state and command policy.

## Shared Windows behavior

`Resolve-BuildValue` owns raw explicit, ordered environment and default selection.
Source-build and container-image wrappers keep their distinct version-prefix rules.
Meson native and cross files share binary rendering. IREE and LiteRT share ordered
per-file ARM feature selection and application while keeping different minimum
architectures and source predicates. PE and COFF checks share machine names through
`WindowsTargetArch.Common`. Handoff transfers share context and curl execution;
source-build sccache sessions share lookup and command capture without changing
startup, upload-drain or completion policy.

`Set-CompilerWrapperEnvironment` and `Remove-CompilerWrapperEnvironment` share the
canonical launcher names in `WindowsScripts.Shared`. Build sets its five launchers,
CMake clears its launchers including CUDA, and CodeQL removes its five variables.
An empty variable remains different from a removed variable. Packaging shares venv
cleanup, CMake shares environment/stat diagnostics, Flutter shares link cleanup and
the agentic loop shares lazy environment-to-config fallback. Caller ordering,
whitespace, retry, broken-link and trace-marker policies stay at the caller.

`Write-DiagnosticResult` renders the existing verdict bytes, including ARM64's
separate detail line. The sccache write probe shares rename evidence, directory
rows and server shutdown while preserving staged-source retention versus temporary
source cleanup on failure. Cleanup uses literal paths so brackets remain filenames.
ONNX replay shares step projection and clipped traces with caller limits. New-host
setup shares maintenance logging and live-build guards before protected writes;
forced, report-only and skipped steps keep their own policy. Optional Vulkan file
verdicts share `Assert-VulkanArm64Library`; installation and verification still
run independently with their own paths, strict inputs and messages.

Required sibling imports bind into each owner's scope without forcing a reload.
Fixtures cover cold, private-warm and global-warm visibility plus fatal missing
companions. The sccache-write and OpenCV-video probe Dockerfiles mount their script
under `diagnostics` and exactly `WindowsDiagnostics.Common` plus
`WindowsScripts.Shared` under sibling `modules`. A mount-derived child-import
fixture removes a companion as a negative control; it does not run BuildKit or the
probe experiments.

The harness owns batch-tool construction, child-pwsh capture and literal-source
assertions. Retry suites keep tool-specific behavior in their shared fixture.
`Invoke-TestFunctionMutations` constructs each module before expecting the original
test body to fail, so malformed source or import failures cannot count as proof.
It forwards fixture state and restores module lifetime. Direct source arguments
share recipe construction; `-Throws` preserves tests of required exceptions. These tests exercise local
policies with stubs and isolated files, without validating an installed SDK,
compiler, GPU, live host service or container image.

`Expand-SourceTarball` owns the two 7-Zip passes. Its default rejects every failed
pass and retains the intermediate tar. `Expand-PinnedArchive` supplies the existing
MIGraphX dangerous-link classifier and requests tar removal; unrelated extraction
errors still throw. `SourceBuild.Archive.Tests.ps1` checks both policies with a
stub 7-Zip, including failure and cleanup mutants.

`Get-OrtGateDirectoryIndex` owns chain file hashing. GenAI retains recursive
`include/onnxruntime` and flat `lib`/`bin` scans with fatal read errors. G2 retains
recursive scans, its narrower filename pattern and unreadable-file sentinel.
Directory-index fixtures check those distinctions without compiling or loading ORT.

Flutter's plugin patcher shares its idempotent text policy. Artifact sync shares
robocopy setup and exit handling while the public caller keeps separate CMake and
Rust exclusions. Missing optional plugin text stays optional; copy exits at least
8 warn, both copies are attempted, and the native exit code is reset afterward.
The fixture suite exercises text and copy arguments, not real robocopy I/O.

The sccache write diagnostic shares root-directory startup, serial compilation,
unique compiled source tokens and first-match counters. Each mode keeps its
absent, empty or configured cache levels and its verdict. Missing counters stay
`-1`, and `/Fo` has no colon. Stubbed regressions and mutations check orchestration;
they do not establish real cache writes or BuildKit mount behavior.

Python CI suites import `WindowsPythonCi.DriverFixture.psm1` beside the harness.
It owns fake-tool setup, child status, call-log reset and plain error text. The
callers keep tool-specific scripts, summaries and path normalization. Transport
fixtures check arguments with spaces and colons, environment/location restoration,
failed exits and stale logs; the existing consumer suites retain their assertions.

The harness file-tree writer joins relative fixture paths with `Join-Path` so
Windows separators retain their directory meaning when structural suites run on
Linux. `Harness.Fixtures.Tests.ps1` keeps its nested path, bracket and content
checks; all cases remain included in the lifted-module mutation baselines.

Native GPU probes share process capture, timeout and process-tree cleanup in
`WindowsNative.Common.psm1`. Callers retain trimmed or exact output and inherited
or captured stderr; environment overrides affect the child only. JSON probes
share temporary-source cleanup and last-report parsing while preserving Python
arguments, stderr handling and failure diagnostics. A valid JSON report cannot
excuse a failed interpreter. Smoke compilation shares scratch and artifact
verdicts; required assertions still reach the aggregate and cross-target skips
remain visible. Cold nested-consumer tests cover module helper visibility.

Source builders share modules-before-ortmods leaf lookup without importing a
larger dependency tree. Shared child-directory discovery retains provider order,
caller filters and relative marker paths for GStreamer and Visual Studio; the
source-build module reexports it without forcing a reload. The same directory
lookup serves the ARM64 toolchain prerequisite check without changing warning
or strict-failure policy. TVM package staging, dist-info creation and wheel packing
share one owner; absent or multiple wheel outputs still fail. Bundle environment
renderers share their ordered input model while retaining batch and PowerShell
syntax. FFmpeg AMF and Vulkan listings share missing-entry verdicts and keep their
backend-specific symbol sets. Compiler, GPU and installed-image behavior still
requires the real chain and mandatory smoke gate. FFmpeg table queries must exit
successfully even when partial output matches; scratch allocation or cleanup
failures also fail the smoke operation.

Consumer helpers share build duration accounting, container-client attempts,
raw-byte tar transport, log pipelines, benchmark rows and delta rendering. Callers
keep fatal versus optional results, tar quoting, benchmark locale handling and
cross-runtime file masks. `Resolve-PathFromRoot` and
`ConvertTo-MsixSigningPassword` are exported by `WindowsScripts.Shared.psm1`;
Build-log directories and Rust Cargo target directories use the same rooted-path
resolver; external absolute paths stay external. Python app wrappers retain their
public names and signing callers retain their
empty or whitespace password policies. WasmOpt uses the shared SHA256 assertion;
a mismatch still deletes the archive and fails before extraction.

Isolation diagnostics carry `WindowsDiagnostics.Common.psm1` and
`WindowsScripts.Shared.psm1`. They share Docker lookup, native transport, control
checks and host evidence while retaining distinct verdicts. Host cleanup and
repair scripts carry `WindowsHostMaintenance.Common.psm1` with Shared; its logger,
filtered probes and live-build guards preserve each caller's protected operations
and fatal or advisory policy. `Test-HostSetup.ps1` also carries
`WindowsBuildKit.Common.psm1` for subnet checks. Malformed CIDR values fail the
host check; the shared subnet API keeps throwing by default. ONNX replay literal
counters now count all case-insensitive occurrences instead of always returning
zero; regex counters and classifier precedence retain their separate policies.
LLVM diagnostic modes share command parsing and first-line compiler identity
capture while keeping each mode's arguments, exact label spacing, suppressed stderr
and native exit status.

ROCm suites use the harness source reader for repository and rooted mutation
inputs. `Invoke-InTestScriptDir` parses before allocating a workspace, supplies the
absolute script path and cleans up when the body fails; reading never executes the
inspected source. Its fixtures cover malformed input and callback failure.

`Copy-TestModuleClosure` validates and copies a complete sibling import closure
for cold-import fixtures. Deliberately incomplete companion fixtures still name
their partial file set explicitly.

The harness also owns scoped fake-function restoration and recorded call state.
`Invoke-WithFunctionModule -ScriptPath` loads selected functions without running
top-level source; `-FixtureState` passes one object to initialization and the body,
including empty collections. `Invoke-WithTestFunction -FixtureState` binds the
same object as `$State` in the fake and passes it to the body without changing the
fake's arguments. Both reject mixed state and explicit argument arrays.
`Invoke-WithTestNativeCommand` shares argv recording and exit-code publication,
then restores the parent's exit state even when the fixture body throws.
`Invoke-InTestDir -Files` initializes a tree inside its cleanup scope. AST ancestry
supports nearest-first filtering and an exclusive stop; command assertions reject
missing, repeated, altered and unassigned sites. Suites using media wiring helpers
carry `WindowsMedia.WiringFixture.psm1` beside the harness. Regression and mutation
fixtures exercise these policies with independent expectations; they do not
replace container, compiler, certificate or GPU acceptance.


The Windows unit runner's discovery floor is 2,442 after a complete 2,467-test
run. Keep that floor close to the measured suite count as coverage grows;
missing or skipped suites fail rather than yielding a partial green result.

Shared harness mutations run `Harness.Fixtures.Tests.ps1` on Linux as well as
Windows. Its batch-writer cases inspect complete ASCII/CRLF bytes and apply real
content mutations. `Harness.BatchTools.Tests.ps1` retains native batch execution:
quoted argument forwarding, requested final exit, caller early exit and execution
mutation proofs. The normal Windows suite discovery includes both files. Linux
has no batch interpreter; it does not emulate, skip or claim native execution.

`New-TestBatchFixture`, `Assert-TestBatchFile` and
`Invoke-TestBatchToolMutationCases` in `TestHarness.psm1` own common construction,
byte verdicts and fault lifecycle. The native suite supplies execution assertions;
the portable suite supplies byte assertions. Mutation callbacks are captured
before `It` registration so its own body parameter cannot shadow the verdict.
A dedicated mutation removes the byte assertion and requires the writer mutants
to survive, making the outer suite fail instead of accepting an inert callback.

ORT dependency archives share the lowercase SHA1 pin check in the ONNX builder;
Dawn still verifies its SHA256 pin first, and each caller keeps its mismatch
diagnostic. Fixture archive hashes remain independent of the source helper.

Compiler-rt callers share `Expand-CompilerRtLibrary` and `Find-InstalledCompilerRtLibrary`
from `WindowsScripts.Shared`; source-build consumers reach both through their
existing module companion. The archive is hashed before tar lookup or extraction.
Native tar output remains separate from the selected library path. Source builds
fail on a missing library; Scoop retains advisory fetching and its independent
`WINDOWS_ARM64_STRICT` verdict. Both callers clean scratch on failure. `Find-FirstTreeFile` also owns recursive
first-file discovery for OpenSSL installation and GStreamer prerequisites; callers
retain advisory or fatal missing-file verdicts.

Source preparation shares remote-cache eligibility, cache executable discovery,
CPU defaults, portable ZIP extraction and cross-protoc preparation. Callers keep
launcher selection, diagnostics, minimum versions and cleanup choices. DLL closure
walks retain traversal order, import readers and system-library exclusions. Cross-bundle
closure delegates its multi-root breadth-first walk to the architecture graph with
explicit policies: the first indexed directory wins, machine checks precede traversal,
and indexed API sets and system descendants remain included.
`Get-RequiredBuildArtifact` retains caller filters, recursion and minimum/maximum
cardinality; finding matching bytes cannot bypass a required artifact verdict.
UV shares ABI probe transport while keeping fatal interpreter assertions separate
from optional twin-store selection. Required companions import without forced
reloads; malformed or missing companions fail before use.

`Invoke-WithProcessEnvironment` restores missing, defined-empty and existing
variables even if a setup write fails. GenieX log setup and hidden process launch
use that scope. The standalone agentic module instead applies sanitizer overrides
inside its existing child pwsh transport, retaining command logs and exit handling
without adding a vendored dependency. Silo probes share recursive read-only log
access, wininit identifier projection and debugger transport through their existing
`WindowsSiloProbe.Common` companion. Probe-specific commands stay with each caller.
Debugger output and stderr go to the caller log and raw exit status stays visible.
Attaches default to non-invasive; only the existing wait-object opt-in uses a
controlling attach. A supplied LSM process/handle pair skips debugger discovery
and optional debugger detail without reading an unset variable.

`New-TestDir -Files` initializes files inside the allocation cleanup scope;
suite-scoped directories still clean up in `AfterAll`. `Invoke-InTestDir -Prefix`
retains diagnostic names without leaking its prefix into lifted module parameters.
`New-TestBatchToolSetup` captures a fake tool's writer and policy for retry suites.
`Invoke-TestFunctionMutations -IncludeControl` runs the unmodified exercise first;
a baseline failure cannot count as a killed mutation. Module-argument factories
share temporary recipe workspaces; factory and import failures propagate before
mutation expectations. These fixtures cover local
policy and failure cleanup, not installed toolchains, ACLs or container builds.

`Get-DriveFreeSpaceGb` shares the optional-drive lookup and one-decimal reading
between initial, per-stage and host setup checks. A full disk returns zero; an
absent drive or null `Free` returns unknown. The initial check and host report
retain their skip policy, while per-stage checks warn and record an unreadable
drive. Thresholds, force overrides and refusal diagnostics remain with each caller.

`Invoke-BuildArtifactCopy` owns bounded robocopy transport and returns its raw
status. Build synchronization keeps its fatal threshold of 16 and exit reset;
Flutter keeps warning at 8, attempts both trees and resets afterward. Testing's
ASan and runtime-path scopes delegate restoration to `Invoke-WithProcessEnvironment`;
no-options and no-runtime-directory calls still invoke the body without a scope.

`Copy-SourceBuildFileTree` owns relative layout, parent creation and counted file
copying for LiteRT headers and LiteRT-LM support staging. Selected files outside
the source root and copy failures terminate. `Invoke-SourceFilePatchSet` owns ordered
patch invocation, changed counts and optional per-change callbacks; each source
builder keeps its file selection, transformations and minimum-count verdicts.

The harness shares temporary working-directory restoration and local download
fixtures. Temporary-directory cleanup uses literal paths, so bracketed diagnostic
prefixes cannot leave roots behind after a successful or failed body. Fake download transport records forwarded pins and signature options
before a caller hook runs, then writes its archive stand-in. Script-command
fixtures parse and enforce cardinality before returning executable command blocks.
Their failure and mutation cases verify local policy without fetching upstream
archives, copying a live build tree or running upstream compilers.
`WindowsTest.MutationCases.psm1` owns named mutation-check registration and
control execution for consumer operations and source preparation. Copy that
companion beside those suites and the harness; copy suites also carry
`WindowsConsumer.ArtifactFixtures.psm1`. Case bodies keep their independent
assertions, and invalid recipes or failed controls remain failed test results.

`Initialize-BuildDirectory` shares literal-root reset and directory creation for
Python app staging, GenAI's ORT shim and proven ORT payloads. Child directories
are created in caller order; reset and allocation failures terminate before a
payload can be copied or proved. App wrappers keep their public signatures and
work-directory defaults. The payload module binds its existing Shared companion
directly so a private earlier import cannot hide the operation.

`Write-BuildCommandOutput` shares streamed capture and logging for native builds
and CMake; whitespace remains in failure evidence and nonempty lines reach the
logger. Native execution retains one capture path for empty and nonempty argv.
CMake build and DLL smoke probes use the existing process-environment scope;
exceptions restore PATH, logging still sees the build environment, and native exit
codes reach each caller's verdict. Cross-target link probes still avoid execution.
Single-DLL and tree probes share load/export/free operations while retaining their
separate verdicts and minimums.
Copies of `WindowsSmokeTest.Common.psm1` carry `WindowsScripts.Shared.psm1`;
its required import fails immediately when that companion is absent.

`WindowsHarness.GitFixtures.psm1` owns checked git commands, repository creation,
local identity and staged commits for repository fixtures. Copy it beside suites
that import it and `TestHarness.psm1`. Commands preserve native output and fail
on nonzero status; file contents remain independent fixture inputs. Batch fixture
writers and source AST readers use the existing harness operations.
`WindowsHarness.TextFixtures.psm1` preserves native line serialization for fixture
file maps; `Invoke-InTestLineDir` owns their temporary workspace and cleanup.
Consumer execution suites carry `WindowsConsumer.ExecutionFixtures.psm1`
for environment case setup and their shared CMake stand-in. Graph suites carry
`WindowsSourceBuild.GraphFixture.psm1` for their PE closure fixture.
The named mutation companion also transports function source safely into child
probes. Those children terminate on inner errors so failed setup cannot produce
a green exit. `Consumer.NativeExecution.Tests.ps1` keeps actual batch transport
separate from the portable consumer suite. These checks do not establish installed
compiler behavior or live debugger acceptance.
