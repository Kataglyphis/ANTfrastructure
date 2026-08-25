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
| ONNX Runtime (pin: `ONNXRUNTIME_VERSION`) | Ninja | clang-cl, lld-link | **both lanes** (on `-TargetArch arm64` CUDA, TensorRT and the Python bindings are OFF, but DirectML is **ON** as of backlog #113 — see [`windows-cross-builds.md`](windows-cross-builds.md)): DirectML EP **enabled** (`USE_DML=ON`) via the 3-part clang-cl source patch `003-dml-clangcl-compat.patch` (§ Source Patch Policy; the EOL/context-tolerant inline regex patcher `Invoke-OnnxDmlClangClPatch` in `build-onnx-from-source.ps1` remains as the drift fallback): DirectMLHelpers incomplete-type out-lining, `.##Z` token-paste, `Dispatch<size_t>`. CUDA + TensorRT EPs enabled when the NVIDIA layer is the parent (CUDA 13.3 provider, includes crt/ workaround for nvcc). Patches build.ninja for MSVC-only `/experimental:external`. Runs under VsDevCmd for MASM (`.asm` files). **AVX-512/AMX: per-TU only** — global flags OFF (they crashed protoc AND ort's own DLL init at runtime on AVX2 hosts); the build script appends them (`Get-WindowsTargetKernelSimdFlags -Arch` — the old `Get-WindowsX86Avx512Flags` name survives only as a zero-caller compat shim; the amd64 TU pattern was extended 2026-08-24 after under-matching broke the lane, tagged-count floor raised 4→8) to MLAS's runtime-dispatched arch TUs in build.ninja post-configure and logs the tagged count (see AGENTS.md § Windows Build Invariants — don't "simplify" in either direction). 1.28's `ScopedResource<INVALID_HANDLE_VALUE,...>` template arg (rejected by clang-cl) is bridged by an inline post-configure dep patch. Needs ~4 GB RAM/job — media-core runs with `--memory ${MediaMemoryGb}g`. |
| ONNX GenAI 0.15.2 | CMake (Ninja) | clang-cl, lld-link | Source-built directly via CMake (bypasses `build.py` which always builds examples). DirectML **enabled** (`USE_DML=ON`, on **both lanes** since #118, 2026-08-24) — compiled straight into `onnxruntime-genai.dll` with 0 source patches (`src/dml` is clang-clean; the `RESTORE_PACKAGES` DXC nuget dep is pruned since shaders are pre-generated DXIL; the `D3D12Core.dll` staged beside the DLL is resolved through a **target-derived** filter — x64 on amd64, arm64 on the cross lane — not the hardcoded x64 an earlier revision of this row implied). CUDA **enabled** (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll`; CUDA and DML are independent CMake blocks so they coexist. `-DENABLE_TELEMETRY=OFF` (0.15 defaults MS 1DS telemetry ON; its bundled zlib also breaks clang-cl under -Werror). VsDevCmd environment loaded for MSVC STL headers. |
| OpenCV 5.x | Ninja | clang-cl, lld-link | Global SIMD flags: AVX2, SSSE3, SSE4.1/4.2 (amd64 only; global SIMD flags are empty on arm64 by design). CUDA auto-detected. Custom `CMAKE_AR` path fix. |
| LiteRT 2.1.6 | Ninja | clang-cl, lld-link | GPU delegate enabled (Vulkan + OpenCL backends). XNNPACK enabled. CUDA paths exposed for external delegate. Also builds the TFLite **C-API** shared lib `tensorflowlite_c` (target injected into the main build, `WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) that gst-plugins-bad's tflite plugin links. |
| LiteRT-LM 0.15.0 | **Bazel** | clang-cl, lld-link | On-device LLM inference, built via `build-litert-lm-bazel.ps1` (bazelisk + Temurin JDK, `bazelisk build //runtime/engine:litert_lm_main --config=windows`) → `litert_lm_main.exe`, through the smoke-RUN gate. Bazel is the only path Google CI-tests, so it survives version bumps. The old CMake export-bridge path (`build-litert-lm-from-source.ps1`, 5 condition-gated self-retiring patches for v0.14's never-functional OSS CMake export — see § Source Patch Policy #7) is a **frozen fallback**. |
| TVM 0.25.0 | Ninja | clang-cl, lld-link | Auto-detects CUDA/Vulkan. **Builds its own minimal LLVM from pinned source** (#47 heal 2026-08-17: scoop LLVM ships no llvm-config/dev-libs, the official dev tarball is /MT — X86+NVPTX, DIA off, RTTI on, `USE_LLVM=<path>/llvm-config.exe`; SHA pins in `$llvmSrcSha`, ~6 min sccache-warm). Builds a Python wheel. VsDevCmd environment loaded for MSVC STL headers. |
| FFmpeg `n9.0` | MSYS2 `make` (MSVC toolchain) | clang-cl via `--toolchain=msvc` | Source build from the pinned release tag (`FFMPEG_VERSION=n9.0` in `versions.env`; a release TAG since 2026-08-04 — previously tracked `master`). `--enable-libonnxruntime` links FFmpeg's DNN filter against the source-built ONNX Runtime so ONNX models can run inside `ffmpeg` filters (DNN filters ship with the backend; no separate `--enable-dnn` flag). **x86asm ENABLED on amd64 since 2026-08-24** (#119: nasm-assembled x86 SIMD via `--x86asmexe`; the old unconditional `--disable-x86asm` had no recorded reason — proven the same evening: configure names nasm as the x86 assembler, 154 `X86ASM` objects linked under lld-link). The arm64 cross lane keeps `--disable-x86asm` explicitly (an x86-only knob) and assembles its NEON kernels through clang's integrated assembler. Falls back to a BtbN pre-built GPL binary if the source build fails (the sentinel env var `FFMPEG_SOURCE_BUILD=0` is then set). |
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
# Requires a TensorRT zip in windows/downloads/ (see § TensorRT setup (GPU lane, optional) below).
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
   **OWNER DIRECTIVE: always take the NEWEST release.** Never resolve a
   pin-vs-zip mismatch by lowering `TENSORRT_VERSION` — stage a newer zip.
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
   exception, so the claim is not read as absolute: `setup-tensorrt.ps1` still
   builds its NVIDIA CDN fallback URLs out of the pin, used only when no zip is
   staged.

If no zip is found, the build **skips TensorRT gracefully** (CUDA + cuDNN still
work; `setup-tensorrt.ps1` warns and returns, ORT auto-disables the TensorRT
EP, and the smoke test's `TENSORRT_ROOT` pointer passes on the guaranteed-empty
`C:\tensorrt`). This zip-less configuration is the NORMAL state of this host's
GPU lane. Do NOT re-harden this into a fail-fast: a 2026-08-04 "fail-fast"
variant (premised on the wrong claim that the smoke test would reject a
TensorRT-less nvidia image) broke the first hardened `-Gpu` rebuild and was
reverted on 2026-08-05. The ORT build script auto-detects `$env:TENSORRT_ROOT`
and enables the TensorRT EP when available.

**A PRESENT zip is a different matter and now fails CLOSED.**
`normalize-tensorrt-tree.ps1` (bind-mounted into the `trt-extract` stage)
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
`[PASS]` for plugins that did not exist.

The set lives in **one** place — `Get-RequiredGstPlugin`
(`windows/scripts/modules/WindowsGstPlugins.Common.psm1`; it moved out of
`WindowsScripts.Shared.psm1`, which this line named until 2026-08-23, because Shared sits in
the compile closure of all three media branches and this set changes far too often for that)
— and is enforced at four points that used to disagree:

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
| `NASM_WINDOWS_VERSION` | scoop `main/nasm` | assembles the x86 SIMD of GStreamer subprojects that ship `.asm` (openh264 — see `build-gstreamer-from-source.ps1:482`) **and, since #119 (2026-08-24), FFmpeg's hand-written x86 kernels on the amd64 lane** (`--x86asmexe=<nasm>`; before that day FFmpeg passed an unconditional `--disable-x86asm` and nasm assembled nothing for it) — a bump changes shipped object code in both |
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
runs the ~10s commit probe (`windows/scripts/diagnostics/test-process-isolation-commit.ps1`)
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
> `docs/windows-host-setup.md` and § RDNA4 dGPU layer-lock (A/B history and
> diagnostics) below). The
> preflight gate `Assert-NoActiveRdna4Gpu` refuses to start while it is
> enabled. Build window: elevated
> `pwsh -File windows\scripts\host\toggle-rdna4-gpu.ps1 -Disable` → build (display
> falls back to the iGPU) → re-enable with the same script (default action).
> Two extra facts that save hours: failed finalizes WEDGE hcs state until a
> reboot (don't A/B anything on a wedged host), and the severity moved with
> Windows updates (post-KB5101684 even tiny RUN layers trip — expect patch
> days to change behavior). After every Adrenalin/Windows update, re-check in
> ~2 min with `windows\scripts\diagnostics\test-rdna4-layer-lock.ps1` (elevated) —
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
  `windows\scripts\host\apply-buildkitd-gcpolicy.ps1` from an admin **pwsh 7**
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

- **FULL LIQUIDATION playbook — when the store has accreted ~1 TB and no
  surgical lever pays (measured 2026-08-20/21, store at 1,098 GB real).**
  After weeks of chain iterations the surgical levers converge on zero: probe
  tags rmi'd (+17 GB — they share the spine), `prune-histories` emptied,
  buildkitd restarted, naked `prune` → `Total: 0B`, all 182 records
  `Reclaimable: false` (the Shared/lease mechanism above — the 13 live chain
  tags weave the whole store together). At that point the ECONOMIC move is
  reset-and-rebuild, not archaeology:
  1. `windows/scripts/host/reset-container-stores.ps1` (elevated; stops
     services, RENAMES `containerd`/`buildkitd`/`Docker` state dirs to
     `.bak-<stamp>`, restarts, re-deploys the GC toml). The rename frees
     NOTHING by itself.
  2. Delete the `.bak` trees. **NOT with `takeown /R` + `icacls /T`** — three
     full tree walks over millions of windowsfilter files (hours). The fast
     path is robocopy in backup mode, which bypasses the
     SYSTEM/TrustedInstaller ACLs entirely and runs 32-way parallel
     (3–5× faster; plain `Remove-Item` fails outright on `Files\bootmgr`
     etc.):
     ```pwsh
     robocopy C:\empty-dir $bak /MIR /B /R:0 /W:0 /NFL /NDL /NJH /NJS /NP /MT:32
     Remove-Item -LiteralPath $bak -Recurse -Force   # empty husk
     ```
  3. One overnight ride rebuilds the chain. The sccache WebDAV store lives
     OUTSIDE the container stores and survives, so the "cold" rebuild runs
     compile-warm (~3–4 h, measured 3h14 on 2026-08-20) and the store
     restarts at a lean ~150–250 GB instead of 1 TB.
  Prevention (the reason it got this big): buildkit GC never prunes NAMED
  images, and every ride re-tags the full chain — superseded generations
  accumulate silently. Release probe/diag tags promptly
  (`apply-elevated-window.ps1` step 3) and expect a reset every few weeks of
  heavy iteration until the ride wrapper learns to untag its predecessors.

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
  pwsh -File windows\scripts\host\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx -ReportOnly   # look first
  pwsh -File windows\scripts\host\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx               # then act
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
  `windows\scripts\host\rebuild-host-vhdx.ps1` creates a fresh disk, mirrors the
  live data into it, compares file count AND byte totals, and only then hands
  over the drive letter. It runs in two phases on purpose, because they have
  very different requirements:

  ```pwsh
  pwsh -File windows\scripts\host\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -ReportOnly
  pwsh -File windows\scripts\host\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -CopyOnly    # safe with everything open
  pwsh -File windows\scripts\host\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -SwapOnly `
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
  (STALE-NOTE corrected 2026-08-21: an earlier revision claimed a teardown
  probe remained in `bk-warm.ps1` — it does not; the file is a 55-line
  arg-forward + Export-BuildHandoff wrapper, and all solves are direct,
  so there are no warm layers to cache-bust either.)
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

#### RDNA4 dGPU layer-lock (A/B history and diagnostics)

**Diagnostic / partial-alternative on hosts where build-`COPY` is broken.**
Measured 2026-08-09 — root cause RESOLVED 2026-08-10: the ENABLED AMD RDNA4
dGPU locks fresh container layers (full A/B history + falsification list at
the end of this subsection — since 2026-08-24 THIS doc owns that story and
AGENTS.md's Common Failure Modes rows link here; build with the dGPU disabled
via `toggle-rdna4-gpu.ps1` — the earlier "Adrenaline reinstall fixes it,
GPU-disable does not" verdict is SUPERSEDED):
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
windows\scripts\diagnostics\probe-build-copy.ps1 -Heavy` (assets in
`windows/scripts/diagnostics/probe-build-copy/`; only a `-Heavy`-green verdict counts
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

**The full A/B history and falsification list (moved here from AGENTS.md's
Common Failure Modes "AMD Radeon host" row on 2026-08-24 — this doc owns the
story now):**

- **2026-08-09 final verdict of that day (measured; superseded as a root-cause
  claim the next day, kept as history):** "the BK build lane is UNUSABLE ON
  THE DISCOVERED HOST" — the reimport/double-activation `0x20` persisted
  identically on buildkit 0.32.0 AND a throwaway v0.32.2 daemon (instrumented
  A/B, pristine Stevedore reinstall, every host lever tried incl. AMD
  GPU-disable + driver/chipset reinstall); read as host-level
  hcs/windows-snapshotter behavior, NOT engine/config/OS-version (the working
  machine is the same 26200 build). dockerd (classic lane) committed the same
  shapes fine there, and `nerdctl run` of pre-built images was unaffected.
  Practical note that survives: buildkit 0.32.x includes the upstream retry
  fix (#5885) — it does not help a persistently-held VHD. HVCI/Memory
  Integrity was falsified too (off + reboot + retest = identical `0x20`).
- **2026-08-10 morning: LIGHT-probe-green but NOT chain-green.** The fixed
  3-layer probe (now exporting `type=image,...,unpack=true`, the same output
  path as `build-buildkit.ps1`) passed commit + export + unpack — but the real
  chain's first COPY after the heavy pwsh-install RUN died deterministically
  (`ActivateLayer 0x20` at child finalize/reimport, FRESH snapshot IDs under
  `-NoCache` — not poisoned cache). This is why probe verdict discipline says
  only a `-Heavy`-green `probe-build-copy.ps1` verdict counts.
- **RESOLVED 2026-08-10 by same-boot A/B: the holder is the ENABLED RDNA4 dGPU
  itself (RX 9070 XT + Adrenalin), upstream docker/for-win#14977 (RDNA3.5/4,
  open).** Disable the dGPU → tiny AND heavy RUN-layer finalize green, first
  try; enable → red. Severity tracks the WINDOWS PATCH LEVEL: pre-KB5101684
  only heavyweight RUN layers tripped (light probes green — exactly why the
  host looked probe-healthy while the chain died); post-KB5101684 even
  10-byte RUN layers fail. COPY-only layers finalize fine either way (no
  container involved). The 2026-08-09 Adrenaline-reinstall and in-place-repair
  "fixes" above are SUPERSEDED as root-cause claims — each coincided with a
  patch-level/reboot change that moved the trigger threshold.
- **Falsified on the way (all still-red):** Defender (full exclusion set incl.
  the snapshotter root + `MsMpEng.exe`; realtime-off blocked by tamper
  protection), WSearch/SysMain, daemon bounces, vmcompute restart, non-core
  minifilter detaches (no third-party filters exist on C:), fresh IDs under
  `--no-cache`, settle delays, reboots, nanoserver base, split solves.
- **Failed finalizes additionally WEDGE hcs state until a REBOOT** (survives
  service bounces + vmcompute restarts; after one red finalize even tiny RUN
  finalizes fail). This cascade is what made every earlier session's A/Bs
  contradict each other — after ANY red finalize, REBOOT before further A/Bs;
  a wedged host falsifies every experiment.
- **Order of operations on any weird host:** (1)
  `windows\scripts\diagnostics\probe-build-copy.ps1 -Heavy` (the committed
  probe; only `-Heavy`-green counts), (2) RDNA4 dGPU present? elevated
  `toggle-rdna4-gpu.ps1 -Disable` → re-probe `-Heavy` → build → re-enable
  (display falls back to the iGPU; DirectML-on-host is unavailable during the
  window; `build-buildkit.ps1`'s `Assert-NoActiveRdna4Gpu` preflight enforces
  this — `-SkipHostChecks` overrides, and a verified-healthy host can bypass
  just this gate via `-SkipRdna4Gate`), (3) after ANY red finalize: REBOOT
  before further A/Bs.
- The docker-classic legacy builder's `COPY` defect on that host is presumably
  the same interaction (untested with the GPU off). And note the probe itself
  had two pwsh bugs masking all of this until 2026-08-10 (the ArgQuoting traps
  in AGENTS.md § Windows Build Invariants).

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
probe lives under `windows/scripts/diagnostics/`:

```pwsh
.\windows\scripts\diagnostics\test-process-isolation-commit.ps1
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
Baseline history: Docker 29.5.3 / containerd 2.3.1 / host build 26200 with
`servercore:ltsc2025` measured **BUG PRESENT**; the 2026-08-21 re-probe (after a
Stevedore reinstall) measured **BUG GONE — process isolation commits fine**, which
is the current baseline AGENTS.md § Isolation policy operates on. Re-probe (delete
the probe cache first) rather than trusting either verdict after any Docker/
containerd/host update.

**The 2026-08-21 incident — how a broken PROBE manufactured a "host defect"
(the ProbeShell story; moved here from AGENTS.md § Isolation policy on
2026-08-24 — no other doc carried it before):** the probe's own
`Dockerfile.isolation-probe` set `SHELL ["pwsh", ...]` on the PUBLIC
`servercore` base — which ships Windows PowerShell 5.1 only — so every `RUN`
died with `hcs::System::CreateProcess ... The system cannot find the file
specified`, for a reason that had nothing to do with wcifs. The driver read
that manufactured verdict as a host defect and silently fell back to Hyper-V:
**2 CPUs on a 32-core host**, behind a warning that looked legitimate. After
the Dockerfile fix, the SAME host re-probed **BUG GONE — process isolation
commits fine** (the current baseline above). Regression guard:
`windows/scripts/tests/Dockerfile.ProbeShell.Tests.ps1` — no `pwsh` SHELL on a
public base before pwsh is installed; comments do not count as an install.

Two operational lessons from that incident:

- **`BUILD FAILED (exit 1) but NOT with the known signature -- investigate` in
  the probe log means the VERDICT IS WORTHLESS, not that the host is broken.**
  Trust the driver's Hyper-V-fallback warning only after reading the probe log
  (`out\windows-build-logs\isolation-probe.log`) — the probe distinguishes the
  known `wcifs`/`ActivateLayer 0x20` signature from every other failure
  exactly so that an unrelated breakage cannot masquerade as the known bug
  (the exit-2 verdict in the list above is the same rule seen from the exit
  code).
- **Force a re-probe by deleting the cached verdict.** The verdict is cached
  per host build + docker version in
  `out\windows-build-logs\isolation-probe-cache.json`; a stale (or
  manufactured) verdict lives there until the file is deleted. Recipe after
  any fix or doubt: delete the cache file, re-run the probe, read the log.

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
.\windows\scripts\diagnostics\test-layer-rename.ps1
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
upgrade with the self-contained probe under `windows/scripts/diagnostics/`:

```pwsh
.\windows\scripts\diagnostics\test-gpu-passthrough.ps1
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
`pwsh -File windows/scripts/build/build-resource-sampler.ps1 -Summarize -CsvPath <csv>`;
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

**Why sccache is BUILT FROM SOURCE at `SCCACHE_GIT_REV`, not installed from
scoop (decision history moved here 2026-08-24; it previously lived only in
AGENTS.md and a closed backlog archive):** released sccache cannot wrap nvcc
on CUDA 13.3 — it parses `nvcc --dryrun` positionally, 13.3.33 moved
`--simt-only` after the input file, and the build DIES with `fatbinary fatal:
Could not open input file '<tu>.compute_80.cubin'` (mozilla/sccache#2722,
merged 2026-08-04, five days AFTER v0.17.0 shipped). `verify-toolchain.ps1`
asserts sccache resolves from `CARGO_BIN`, because `--version` cannot tell the
fixed and broken builds apart — main still reports 0.17.0. Never bump
`SCCACHE_GIT_REV` without checking the local patch series still applies (the
base rust layer THROWS if not).

**The CUDA launcher (`CMAKE_CUDA_COMPILER_LAUNCHER`) is ON BY DEFAULT since
2026-08-18** (`SCCACHE_CUDA_LAUNCHER="1"` in the media-core-built-onnx stage),
after a decision history worth keeping:

- The 2026-08-10 miscompile (dropped instantiations, `lld-link: undefined
  symbol`) was root-caused to sccache's Windows dryrun quote-collapse — `\"`
  escapes flattened before tokenization packed ~30 `-D` pairs into one
  493-char token, so the cpp4 preprocess lost `USE_CUDA` & friends. Fixed
  upstream (mozilla/sccache#2811, MERGED 2026-08-19 = `SCCACHE_GIT_REV`
  ffac4a5).
- The local series in `windows/upstream/sccache-nvcc-quote-fix/` now carries
  only 0003 (`--diag-suppress` separated form, OpenCV #115 — its own PR is
  drafted, owner submits), applied by the base rust layer (#114).
- The three-canary bar passed on the evening of 2026-08-18: fused_moe compile
  green, providers_cuda link green COLD (153 CUDA device writes), link green
  on the HIT run at **100.00% CUDA/PTX/CUBIN hit rate** (207/816 hits) —
  onnx's CUDA portion drops from ~60 to ~33 min warm. The canaries are
  `verify-cuda-cache.ps1` + a fused_moe compile + a full providers_cuda LINK —
  the miscompile class is invisible until link, which is why all three are
  required before trusting any new sccache with the launcher.
- The #2808 DEADLOCK separately proved to be #99 collateral (gone under a
  healthy backend). Patch 006 (bare fused_moe) was RETIRED 2026-08-18 (moe
  compiles through the launcher, link green).
- Opt out per run with `-BuildArg SCCACHE_CUDA_LAUNCHER=`; **never flip the
  default off silently.**

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

## Docker on Windows: registry auth, networking, service recovery

Traps that are specific to running the Docker CLI/daemon on a Windows host, as
opposed to the BuildKit/containerd lane above.

### `--password-stdin` does not work — ghcr.io login

The documented login form silently fails on Windows:

```powershell
# does NOT work here
echo $CR_PAT | docker login ghcr.io -u USERNAME --password-stdin
```

Two ways through. First, the credential helper is often the real culprit — open
`$env:USERPROFILE\.docker\config.json` and clear `credsStore` (typically
`wincred` or `desktop`), then retry an interactive `docker login`. See also the
`error getting credentials - err: exit status 1` row in
[`AGENTS.md`](../AGENTS.md) § Common Failure Modes, which is the same helper
failing for dockerd-as-SYSTEM.

If that is not an option, write the auth entry directly:

```powershell
$username = "<user>"
$token    = "<GITHUB_PAT>"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${token}"))
```

```json
{
  "auths": {
    "ghcr.io": {
      "auth": "<the base64 string>"
    }
  }
}
```

The value is base64, **not** encryption — treat that file as a credential. Prefer
a short-lived PAT, and see [Build secrets](build-secrets.md) for getting a token
into a *build* without it landing in a layer.

### `--network=host` is Linux-only

On Windows it is silently not what you want — ports must be mapped explicitly:

```powershell
docker run -p 9090:9090 <image>
```

And from inside a container, `127.0.0.1` is the *container's* loopback, not the
host's. To reach a service running on the host, use the Docker Desktop-provided
name:

```
host.docker.internal
```

### Heavy Windows container workloads

Windows containers do not get the host's full memory by default. For a heavy
build or test run:

```powershell
docker run --memory=48g <image>
```

### DNS: "could not resolve host" inside containers

Edit `C:\ProgramData\Docker\config\daemon.json`:

```json
{
  "experimental": false,
  "hosts": ["npipe:////./pipe/docker_engine_windows"],
  "dns": ["8.8.8.8", "8.8.4.4"]
}
```

```powershell
Restart-Service -Name com.docker.service
Restart-Service docker
```

### When the service is wedged

```powershell
Restart-Service -Name com.docker.service
Restart-Service docker
```

If the daemon is unreachable rather than merely stopped, the desktop app's
backend processes have to go first:

```powershell
'com.docker.backend','Docker Desktop','dockerd' | ForEach-Object {
    Get-Process -Name $_ -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 5
Start-Process -FilePath "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
```

A version rollback is a legitimate fix when an update breaks the lane — the
installer accepts an explicit downgrade:

```powershell
.\DockerDesktopInstaller.exe install --disable-version-check
```

### Two container-image gotchas

- **MSBuild Tools** are not in the base images; see
  [Microsoft's build-tools container guidance](https://learn.microsoft.com/en-us/visualstudio/install/build-tools-container?view=vs-2022).
- **WinGet is only available on Windows Server Core 2025 images.** Anything
  older has to install packages another way.

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
(backlog #44).** `build-buildkit.ps1` solves `windows/Dockerfile.smoke-gate`
against the freshly built `winamd64` image after `final`, and a failure fails
the chain. **On `-TargetArch arm64` the gate RUNS since 2026-08-24** (the 2026-08-23 blanket
"inapplicable" verdict was over-broad — roughly half the suite never touches the payload): the
host-toolchain sections (1-6, 14-16, and 19 arch-filtered) execute against the arm64 image with
their own floor column (`MIN_PASSED=66`/`MAX_SKIPPED=25`; measured green at 97/0/15), sections
14/15 compile **for the target** and assert the produced PE machine instead of running, and the
payload sections are skipped as sections with floor 0 — a floor that must stay 0, never be
"fixed" by a skip. The amd64 floors below are untouched, so no later amd64 change can quietly be
measured against a lowered number. The aarch64 payload itself remains verified statically, by
`verify-target-arch.ps1` in the merge stage. Before that, neither driver invoked the smoke test at all — a
multi-hour build ended with "Done" and zero evidence the image worked, in a repo
whose defect history is dominated by "builds fine, fails to LOAD".

**The CLASSIC driver (`build.ps1`) gates too, since 2026-08-21** — as a
`docker run` with a DIRECTORY mount of `windows\scripts`: its dockerd has no
BuildKit `RUN --mount`, and Windows containers reject single-FILE bind mounts
outright, so the whole scripts directory is mounted instead; `docker run` also
enters through the ENTRYPOINT naturally (no bare-`RUN` bypass to compensate
for). Between 2026-08-14 and 2026-08-21 only the BK driver gated — a classic
chain in that window still ended unverified.

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
2026-07-13) — on the amd64 lane.** On the arm64 cross lane the same set minus TVM/IREE
ships since 2026-08-24 evening (#120 step 2): the target aarch64 CPython
(source-built at `C:\runtime\python`, step 1), the `onnxruntime`,
`onnxruntime_genai_directml` and `av` wheels tagged `cp314-win_arm64` in
`C:\runtime\wheels` (staged, **not** installed — nothing here can import them),
and `cv2.cp314-win_arm64.pyd` installed into the target interpreter's
site-packages. TVM/IREE python packages are absent on arm64 by design (they
drive the compilers, which are amd64-only; #116). On amd64, the media branches build python bindings
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

### The torch step (Orchestr-ANT-ion app environment)

The final image bakes the runtime orchestrator at
**`C:\opt\Kataglyphis-Orchestr-ANT-ion`** (`TORCH_APP_DIR`), assembled by
`windows/scripts/build/assemble-torch-app.ps1` (mirror of the linux
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
| `build-onnx-from-source.ps1` | `windows/scripts/build/` | Ninja+clang-cl build with build.ninja patching and VsDevCmd wrapper |
| `build-onnx-genai-from-source.ps1` | `windows/scripts/build/` | Source-built directly via CMake+clang-cl (bypasses `build.py` which always builds examples). Loads VsDevCmd via `vswhere`, clones git tag, runs `cmake`/`ninja` directly. CUDA enabled (`USE_CUDA=ON`) — builds a separate `onnxruntime-genai-cuda.dll` alongside the DML-enabled `onnxruntime-genai.dll`. |
| `build-opencv-from-source.ps1` | `windows/scripts/build/` | Ninja+clang-cl with global SIMD flags and mlas `<cstring>` patch |
| `build-litert-from-source.ps1` | `windows/scripts/build/` | Ninja+clang-cl; GPU delegate (Vulkan+OpenCL), XNNPACK, external CUDA delegate. Injects + builds the TFLite C-API `tensorflowlite_c` shared lib (`WINDOWS_EXPORT_ALL_SYMBOLS` + `/EXPORT:TfLiteXNNPackDelegate*`) for gst's tflite plugin |
| `build-litert-lm-bazel.ps1` | `windows/scripts/build/` | **PRIMARY LiteRT-LM builder.** Self-installs bazelisk + Temurin JDK; `bazelisk build //runtime/engine:litert_lm_main --config=windows` → `litert_lm_main.exe` through the smoke gate. Neutralizes the base image's Android env/WORKSPACE pollution; patches the WORKSPACE zlib URL to the GitHub release mirror (zlib.net is flaky). `output_base` stays container-local (wcifs rename hazard) |
| `build-litert-lm-from-source.ps1` | `windows/scripts/build/` | **FROZEN FALLBACK** (superseded by the Bazel builder above). Ninja+clang-cl; carries the v0.14.0 export-bridge patch stack (`[LiteRTLM-winfix export-stubs]` / `[LiteRTLM-winfix support-graft]` / v0.14 orphans + deps blocks) — all gated on the breakage so they self-retire when upstream's CMake catches up |
| `stage-cuda-runtime.ps1` | `windows/scripts/build/` | Runs in the merge's `cuda-runtime-stage` (derived from media-core). Recursively FLATTENS the CUDA_ROOT/CUDNN_ROOT DLLs into one dir COPY'd to `C:\runtime\cuda-runtime\bin` on PATH (cuDNN 9 buries DLLs in a CUDA-major subdir); hard-gates on `cudnn64_9.dll`. Fixes opencv's plugin load in the non-nvidia merge image |
| `build-tvm-from-source.ps1` | `windows/scripts/build/` | Ninja+clang-cl; auto-detects CUDA/Vulkan/LLVM; builds Python wheel; VsDevCmd for MSVC STL headers |
| `build-ffmpeg-from-source.ps1` | `windows/scripts/build/` | MSYS2 `make` with `--toolchain=msvc`; `--enable-libonnxruntime` links against the source-built ONNX Runtime. Loads `versions.env` via `load-versions.ps1` for the centralized `FFMPEG_VERSION` tag pin. Falls back to BtbN pre-built GPL binary on source-build failure (`FFMPEG_SOURCE_BUILD=0` sentinel). |
| `build-gstreamer-from-source.ps1` | `windows/scripts/build/` | Meson+clang-cl with wrap pre-extraction; loads `versions.env` via `load-versions.ps1` |
| `WindowsSourceBuild.Common.psm1` | `windows/scripts/modules/` | Reusable build helpers: `Invoke-GitClone`, `Invoke-CmakeConfigure`, `Get-SourceBuildVersion`, `Get-CudaRoot`, `Enter-VsDevCmdEnvironment`, `Invoke-SourcePatch` (idempotent, reverse-check, patch.exe fallback), `Edit-CppKeywordAlternatives`, `Update-NinjaFile`, `Initialize-SourceBuildEnvironment`, `Initialize-ToolchainPythonEnvironment`, `Get-GpuEnvironment`, `Resolve-TensorRtRoot`, `Get-WindowsX86SimdFlags`, `Get-WindowsX86Avx512Flags` |
| `setup-vs.ps1` | `windows/scripts/host/` | Installs VS Build Tools 18 with ClangCL toolset |
| `setup-scoop-tools.ps1` | `windows/scripts/host/` | Installs Git (installer) + WiX 4 (dotnet tool), then via Scoop: 7zip, Vulkan SDK, Flutter, LLVM, ninja, sccache, cppcheck, nano, nsis, uv, nuget, zlib, nasm, openssl, pkg-config, CMake. Installs **no** Rust (rustup via `setup-rust-toolchain.ps1` is the sole provider). **PINNED from versions.env (2026-08-07): LLVM/ninja/nasm** (`LLVM_WINDOWS_VERSION`/`NINJA_WINDOWS_VERSION`/`NASM_WINDOWS_VERSION`, forwarded as Dockerfile ARGs) on top of the existing CMake/Vulkan/Flutter/Git pins — those three produce or shape compiled output, and an unpinned clang-cl made the base image unreproducible in its most load-bearing component (five patches under `windows/scripts/patches/` are clang-cl-version-shaped). `verify-toolchain.ps1` asserts all three at base-build time. The rest stay floating deliberately — the build only invokes them. **Caveat (2026-08-08): that justification stops holding for `sccache` the moment multi-tier caching is wired** — the L0 tier then exists or not depending on the installed version (needs >= v0.16.0), and an older one ignores the config **silently**. Pin sccache in the same change, not after |
| `setup-vcpkg.ps1` | `windows/scripts/host/` | Bootstraps vcpkg for Windows |
| `setup-rust-toolchain.ps1` | `windows/scripts/host/` | Installs Rust via rustup WITH a stable default toolchain (sole provider; local `file://` dist mirror dodges rustup's downloader deadlock in 2-CPU containers), runs Cargokit-shaped asserts, bakes `flutter_rust_bridge_codegen` |
| `setup-cuda.ps1` | `windows/scripts/host/` | Installs CUDA 13.3 + cuDNN; includes post-install verification (headers/libs/DLLs) |
| `setup-tensorrt.ps1` | `windows/scripts/host/` | Auto-detects a TensorRT zip in `windows/downloads/` and installs it |
| `load-versions.ps1` | `windows/scripts/build/` | Reads `C:\temp\versions.env` (COPY'd from `linux/scripts/01-core/versions.env`) and sets matching process env vars so Windows build scripts consume the same canonical versions as Linux |
| `finalize-container.ps1` | `windows/scripts/build/` | Enables git long paths and sets `core.longpaths` in the final image; writes the **toolchain provenance manifest** `C:\toolchain-manifest.json` (2026-08-07) — pinned inputs with pin-vs-resolved pairs (LLVM, ninja, nasm, CMake, Vulkan, Git, Flutter, VS→MSVC toolset, SDK build) plus the floating ones (lld-link, rustc/cargo, sccache, uv, pwsh, openssl, pkg-config) and the OS base digest. Answers "which compiler built this image" from the ARTIFACT instead of a build log that ages out, and makes classic-vs-BK lane parity a `diff`. Every probe is best-effort (missing tool → `null`, never a failed layer) |
| `verify-toolchain.ps1` | `windows/scripts/build/` | Verifies clang-cl, lld-link, WiX, Flutter are present after base setup, and ASSERTS the pinned versions (clang-cl/ninja/nasm/CMake vs `versions.env`) — a silent scoop fallback otherwise surfaces ~2 h into media-core as a patch that no longer applies |
| `healthcheck.ps1` | `windows/scripts/build/` | Docker `HEALTHCHECK` script — verifies ONNX Runtime DLL, FFmpeg, GStreamer, CMake, clang-cl |
| `smoke-test-container.ps1` | `windows/scripts/build/` | Comprehensive container validation — **22** test categories (an earlier AGENTS.md copy of this row said 18 until 2026-08-08; this doc had the right count all along). Runs INSIDE the final image, which `windows/Dockerfile` COPYs it into along with the whole `modules` dir. The 22 sections live here; the assertion harness is in `WindowsSmokeTest.Common.psm1` |
| `WindowsSmokeTest.Common.psm1` | `windows/scripts/modules/` | Smoke-test assertion harness, extracted 2026-08-08: counters plus `Initialize-SmokeTestRun`, `Get-SmokeTestSummary`, `Assert-Test`, `Assert-CommandExists/FileExists/DirectoryExists/ArtifactPresent/NativeLinkRun/DllLoads/EnvVarSet`, `Skip-Test`, `Write-TestHeader`. **Call `Initialize-SmokeTestRun -ExitOnFirstFailure:$ExitOnFirstFailure` before the first assertion, and read counts via `Get-SmokeTestSummary`** — the module has its own session state, so `$script:passed` read from a caller resolves to a different, always-zero variable, and a script parameter is invisible to the module. Both failure modes are silent, which is why they are unit-tested |
| `WindowsGstPlugins.Common.psm1` | `windows/scripts/modules/` | The mandatory GStreamer plugin CONTRACT (see § Mandatory GStreamer plugins and AGENTS.md § Windows Build Invariants): `Get-RequiredGstPlugin` (libav/opencv/onnx/tflite with per-plugin detection mechanism and rationale), `Write-PkgConfigFile`, `Get-LibraryLinkName`, `Assert-PkgConfigModule` (presence AND `-MinimumVersion` floors — `pkg-config --exists` alone passes on a `.pc` whose version field is empty). Merge-stage only, deliberately NOT in `WindowsScripts.Shared.psm1`: that one is in all three media branches' compile closure and this set changes often |
| `Measure-BuildWarnings.ps1` | `windows/scripts/diagnostics/` | Counts compiler warnings in a build log grouped by diagnostic family; `-Baseline` prints the four known upstream floods against their pre-suppression counts with a verdict per family. Run it after a chain to PROVE the targeted `-Wno-` flags (OpenCV/ONNX/TVM) and IREE's `_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING` still earn their place — 16 % of one chain log was upstream warnings, and buildkitd clips a RUN step at 2 MiB then deadlocks it |
| `deploy-shim-patch.ps1` | `windows/scripts/host/` | HOST maintenance (admin, never while a build solves): installs a locally built `containerd-shim-runhcs-v1.exe` over Stevedore's, keeping `.orig` (stock, written once) plus a timestamped backup per deployment, and optionally merges env vars into the containerd service (`-ServiceEnvironment`) since the shim inherits them. `-ReportOnly` lists installed binary, backups and env without touching anything; `-Restore .orig` / `-Restore .45min` puts a backup back. Refuses while `buildctl` or a shim process is alive (the binary is locked). Needed because every Stevedore/containerd update silently reverts the patched shim — see § BuildKit/containerd lane and `windows/upstream/`. NB: a quiet log is NOT proof it took effect (the shim logs its effective timeout at Debug, which does not reach containerd's log) — verify behaviourally with the OpenCV canary |
| `setup-new-host.ps1` | `windows/scripts/host/` | HOST bring-up (admin, run `-ReportOnly` first, never while a build solves): the ONE elevated run that turns a freshly-rebooted Stevedore host into a green `verify-host-setup.ps1`. Orchestrates the canonical per-concern scripts rather than duplicating them: authors the CNI `.conflist` from the LIVE `vEthernet (nat)` subnet (derived network/prefix+GW at runtime — no magic subnet literals anywhere), then `apply-containerd-config.ps1` (derives the `.conf`, debug flags, teardown env, Defender), `apply-buildkitd-gcpolicy.ps1` + the `BUILDKIT_STEP_LOG_*` step-log env, the patched runhcs shim (BUILDS the 45min/100min fixed-constant shim from hcsshim source when no `-ShimPath` is given, installing Go via scoop — the recipe from `windows/upstream/`, then `deploy-shim-patch.ps1`), and dufs (scoops if missing, starts it, registers the ONLOGON task, sets machine `SCCACHE_WEBDAV_ENDPOINT` to the host's LAN IP). Idempotent; every sub-script is called with a HASHTABLE splat (array splatting would bind `-ReportOnly`/`-ShimPath` by position — the array-splat rule in AGENTS.md). Companion to `verify-host-setup.ps1` below |
| `toggle-rdna4-gpu.ps1` | `windows/scripts/host/` | HOST maintenance (admin): enable/disable the RDNA4 dGPU in Device Manager (`-GpuName` overrides the RX 9070 XT default — the gate fires for ALL RX 9xxx/R9700 SKUs, so the remedy must reach them too; added 2026-08-10 W1). **RE-INSTATED 2026-08-10 as the RDNA4 build-window workaround** (the 2026-08-09 "obsolete" verdict is superseded): an enabled RDNA4 dGPU kills every process-isolated RUN-layer finalize (`ActivateLayer 0x20`, docker/for-win#14977; A/B-proven). Workflow: `-Disable` → build (display falls back to the iGPU) → default action re-enables. `build-buildkit.ps1`'s `Assert-NoActiveRdna4Gpu` preflight refuses while the dGPU is enabled. |
| `probe-build-copy.ps1` | `windows/scripts/diagnostics/` | The committed build probe (assets `windows/scripts/diagnostics/probe-build-copy/`): `FROM servercore` + `RUN` + `COPY`, BK lane exporting `type=image,...,unpack=true` (the real lane's output path), per-lane exit codes; `-Heavy` adds the heavyweight-RUN finalize lane (the shape the RDNA4 interaction kills), `-Docker` the classic-builder lane. **Run `-Heavy` before trusting a new Windows host** — only a `-Heavy`-green verdict counts (light lanes stayed green while the chain died, 2026-08-10). No admin. |
| `test-rdna4-layer-lock.ps1` | `windows/scripts/diagnostics/` | RDNA4 layer-lock A/B (ELEVATED): probes RUN-layer finalize with the dGPU enabled, then disabled (auto re-enables in a finally). Verdicts: GONE / PRESENT / INCONCLUSIVE. **Re-run after every Adrenalin or Windows update** — a GONE verdict is the signal to retire the toggle workflow + `Assert-NoActiveRdna4Gpu` gate (docker/for-win#14977 tracked upstream). |
| `verify-cuda-cache.ps1` | `windows/scripts/diagnostics/` | CUDA-cache probe (non-admin, ~2 min, safe beside a live build): tiny buildctl solve FROM the local toolchain image compiles one `.cu` TWICE through sccache against the live WebDAV endpoint; exit 0 only when the recompile HIT (per-component: CUDA/Device/PTX/CUBIN) AND objects landed in the store. Verified 2026-08-10 (4/4 hits, 4 objects on disk). **Run after every sccache bump** — the launcher's value rests on this property. |
| `collect-host-docker-state.ps1` | `windows/scripts/host/` | Cross-machine forensics for "works there, fails here": dumps OS build, optional features (DISM API health - reports "Klasse nicht registriert" when broken), filter drivers, services, engine versions, docker info, HNS. Writes `out\host-docker-forensics.txt`. Elevation needed for feature/fltmc reads. |
| `reset-container-stores.ps1` | `windows/scripts/host/` | HOST maintenance (admin, never while a build solves): full container-store reset - stops the services, RENAMES `C:\ProgramData\containerd`/`buildkitd`/`Docker` to `.bak-<stamp>` (rollback), restarts clean, re-deploys the GC-policy toml. The docs' last resort for persistent, non-release hcsshim weirdness; safe on a fresh host (stores re-pull). |
| `sync-defender-exclusions.ps1` | `windows/scripts/host/` | HOST maintenance (admin): prints, then applies if missing, the FULL Defender exclusion set for Windows-container builds - paths (`C:\ProgramData\containerd`/`buildkitd`/`Docker`/`nerdctl`, `C:\ProgramData\Microsoft\Windows\Containers`, `C:\temp`, `C:\WINDOWS\SystemTemp`) and processes (dockerd/containerd/buildkitd/nerdctl/CExecSvc/vmcompute). READ the BEFORE output: non-admin cannot see `Get-MpPreference`, so this is the only proof exclusions were ever applied. |
| `repair-windows-componentstore.ps1` | `windows/scripts/host/` | HOST maintenance (admin, long-running 10-40 min): `DISM /Online /Cleanup-Image /RestoreHealth` + `sfc /scannow`, re-tests the DISM API (was `Klasse nicht registriert` on the reference-discovered box), then re-runs the 3-layer probe. The OS-level repair step for hosts where container-layer ops fail and everything else is clean. |
| `verify-host-setup.ps1` | `windows/scripts/host/` | The machine-checkable form of `docs/windows-host-setup.md` — run it FIRST on any new machine, and after any host change. Non-admin: services, `buildctl` reaching buildkitd unelevated, nerdctl presence, **BOTH CNI forms** (`.conf` for buildkitd — missing is a FAIL; `.conflist` for nerdctl — missing is a WARN) plus content agreement between them and subnet-vs-adapter drift, patched runhcs shim **by SHA256** against the hash `deploy-shim-patch.ps1` recorded at install (size only as a fallback, reported as a WARN so "still guessing" is visible), containerd teardown env var + debug flags, worker snapshotter + gcpolicy, disk headroom **on C: AND the repo/build-context drive**, sccache reachability. Exit 1 on any FAIL; each failure prints its fix. Defender exclusions are reported UNKNOWN (not skipped) when unelevated, so their absence cannot masquerade as success. Registry values that do not EXIST (e.g. the containerd `Environment` value before the first apply) degrade to WARNs, not a mid-run crash (fixed 2026-08-09 — the old `(Get-ItemProperty ...).Environment` threw PropertyNotFound at line 212 and silently skipped the teardown-env + debug-flag checks, under-counting the verdict). **Keep it in step with the guide — they are two views of one contract**; the guide had shipped a broken CNI template for days precisely because prose cannot be executed |
| `apply-containerd-config.ps1` | `windows/scripts/host/` | HOST config (admin, never while a build solves — applying restarts containerd and kills in-flight solves). The containerd counterpart to `apply-buildkitd-gcpolicy.ps1`: containerd runs with NO `config.toml` on this host, so its settings live only in the service's `ImagePath`/`Environment` registry values and existed nowhere in the repo until 2026-08-07. Owns: `--log-level debug --log-file` (permanent owner policy — truncate the log, never disable the flags), `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT` (the runhcs shim inherits the SERVICE environment; a shim built from the upstream patch keeps its 30 s defaults and silently reverts to the 0x3 defect without it — `TASK_CLOSE_TIMEOUT` stays unset on purpose, the patch derives it as 2×teardown+30 s), and the load-bearing Defender exclusions (otherwise invisible: `Get-MpPreference` needs admin). `-ReportOnly` shows drift without admin and changes nothing |
| `compact-host-vhdx.ps1` | `windows/scripts/host/` | HOST maintenance (admin, never while a build solves): reclaims disk when the checkout/store sits on a dynamically-expanding VHDX. Kills stale `buildctl`, stops the build services, detaches → compacts (`Optimize-VHD`) → reattaches read-write in a `finally`, restarts. `-ReportOnly` reports sizes/guest-fs/reclaim potential without touching anything. Machine-specific values are all parameters (`-VhdxPath` mandatory, `-Service`, `-BlockingProcess`, `-VerifyPath`, `-LogPath`, `-Mode`). Warns on ReFS guests, where compaction reclaims ~nothing (measured: 0.2 GB of a possible 254 GB) — see § Store GC. When it reports a near-zero reclaim, `rebuild-host-vhdx.ps1` is the answer |
| `repro-sccache-cuda-llm-deadlock.ps1` | `windows/scripts/diagnostics/` | **Deliberately fails.** Reproduces the sccache nvcc server deadlock and collects a server-side trace for mozilla/sccache#2808. Sets `SCCACHE_REPRO_CUDA_LLM=1`, which makes `build-onnx-from-source.ps1` SKIP patch 006 so the sccache CUDA launcher stays on for `onnxruntime_providers_cuda_llm` — the target the workaround exists to protect. Expect the build to die ~80 min in; that failure IS the artifact. Refuses to start while another `buildctl` is running (a concurrent build shares the sccache server and the locked mount, so a wedge would be unattributable). Needs `ARG SCCACHE_REPRO_CUDA_LLM` wired into `Dockerfile.media-builder`'s media-core-env stage first — it checks and throws with instructions if absent. |
| `Dockerfile.smoke-gate` | `windows/` | Not a script — the automatic verification stage (backlog #44). Solved against the finished image as the last step of every BK chain — **both lanes** since 2026-08-24 (this row said "NOT run on arm64" until then, contradicting § Smoke Testing): on arm64 the suite runs its host-toolchain sections against the lane's own floors (66/25) while the aarch64 payload stays verified by `verify-target-arch.ps1` in the merge stage. Runs a buildctl solve rather than `nerdctl run` because containerd's pipe is admin-only while the driver is non-admin, invokes the test **through `entrypoint.cmd`** (a bare RUN bypasses ENTRYPOINT and loses VsDevCmd + the ASAN runtime dir), and **bind-mounts** the current script + modules so a smoke-test fix needs no image rebuild to re-verify. Knobs: `-SkipSmokeGate`, `-SmokeMinPassed`, `-SmokeMaxSkipped`. |
| `patches/litert-lm/patch-assert.cmake` | `windows/scripts/` | `patch_replace_required` / `patch_regex_replace_required` — replace-with-verification for the CMake source patchers (backlog #56). `FATAL_ERROR`s when a pattern matched NOTHING, instead of the old bare `string(REPLACE)` + unconditional "Patched …" message that let an upstream reformat silently restore a fixed defect. Lives INSIDE `litert-lm/` because the Dockerfile COPYs that directory specifically. Enforced by `Patches.CmakeNoOpGuards.Tests.ps1`; a legitimate non-source replace opts out with a `patch-assert-exempt` marker + reason. |
| `normalize-tensorrt-tree.ps1` | `windows/scripts/build/` | Bind-mounted into `Dockerfile.nvidia`'s `trt-extract` stage. Renames the extracted `TensorRT-<version>` tree to a stable **`current`** so the runtime PATH never spells the pin, WARNS (never fails) on pin-vs-zip drift, and **fails closed** when neither `bin\` nor `lib\` carries runtime DLLs. Backlog #38: the old pin-derived PATH was wrong twice over — wrong version AND wrong dir (TensorRT 10+ moved the DLLs to `bin\`), so the ORT TensorRT EP could never load, silently, while builds stayed green. Absent zip stays a supported graceful skip; a half-extracted tree is a build failure. |
| `bootstrap-pwsh.ps1` | `windows/scripts/host/` | Installs PowerShell 7 as the FIRST RUN of `Dockerfile.base`, BIND-MOUNTED (no layer). Runs under Windows PowerShell **5.1** — the SHELL is not switched to pwsh until after it — so keep it 5.1-safe and do not use `Invoke-DownloadWithRetry` (no module is mounted that early). Carries its own 3-attempt retry with an in-loop SHA256 check. Extracted from a 1214-char inline RUN (backlog #27). |
| `probe-sccache-write.ps1` + `run-sccache-write-probe.ps1` + `Dockerfile.sccache-write-probe` | `windows/scripts/`, `windows/` | Reproduces the sccache **cache-write** environment in ~2 min instead of a 90-min media build (backlog #99): same cache-mount ids, same ENV, then a configuration matrix (`disk-only`, `disk-mounted-subdir`, `disk-plaindir`, `multilevel-mounted`, `multilevel-plaindir`, `webdav-only`), raw filesystem tests, a process-spawn matrix, a bisect of the cache root, serial-vs-parallel and path-length sections. **Run it against the REAL base image** (`-BaseImage local/kataglyphis:bk-windows-media-core-ffmpeg`), not the toolchain default. **Health warning:** it reproduces the ENVIRONMENT but not the FAILURE — every configuration it blessed then failed in a real build, so treat its verdicts as hypotheses to test in a build, never as clearance. `PROBE_NONCE` + a `probe complete` marker check exist because an unchanged script gives `#6 CACHED` and silently replays an old verdict; `--no-cache` is not the alternative (it empties cache mounts, #96). |
| `probe-opencv-video-backends.ps1` + `run-opencv-video-probe.ps1` + `Dockerfile.opencv-video-probe` | `windows/scripts/`, `windows/` | Asks a BUILT media image what video backends OpenCV actually has (backlog #93-#95): prints the `Video I/O:` block, runs the three #95 assertions, and shows `videoio_registry.getBackends()` beside them. ~4 s against `bk-windows-media-core-ffmpeg`, versus a full chain rebuild — which is what let the #95 guards be watched FAILING on the real artifact before the fixes land. Same two safeguards as the sccache probe: `PROBE_NONCE` (a re-run with an unchanged script otherwise gives `CACHED` and replays an old verdict) and a `probe complete` marker check; `--no-cache` is not the alternative, it empties cache mounts (#96). |
| `rebuild-host-vhdx.ps1` | `windows/scripts/host/` | HOST maintenance (admin, never while a build solves): reclaims a dynamically-expanding VHDX by REBUILDING it around its live data — the only reliable reclaim on ReFS guests, where `compact-host-vhdx.ps1` returns ~nothing. Creates a fresh dynamic disk, reproduces the source's filesystem/label/cluster size (and Dev Drive flag where `Format-Volume -DevDrive` exists), mirrors with `robocopy /MIR /COPYALL`, then verifies file count AND byte totals before anything is swapped. TWO PHASES on purpose: `-CopyOnly` touches nothing live and is safe with editors/agents still on the volume; the swap DETACHES the volume and so requires that no process holds a handle on it (a stray detach on 2026-08-06 pulled D: out from under a running session and killed it) — it REFUSES rather than forces, keeping the verified copy for a later `-SwapOnly`. Old disk kept as `.old` unless `-RetireOld`; **no space is reclaimed until it is deleted.** Failed swaps roll back to the original disk automatically. Parameters: `-VhdxPath` mandatory, `-NewSizeGB`, `-NewVhdxPath`, `-Service`, `-BlockingProcess`, `-VerifyPath`, `-ExcludeDir`, `-LogPath`, `-ReportOnly`, `-CopyOnly`, `-SwapOnly`, `-RetireOld`, `-Force`. Put `-LogPath` off the volume for swap runs |
| `free-disk-space.ps1` | `windows/scripts/host/` | HOST disk reclaim — **the only sanctioned one; never compose an ad-hoc cleanup command** (2026-08-21 incident: an improvised one went past the container stores into the installed programs and the user profile, and the host had to be rebuilt by hand). Cleans exactly the regenerable classes: **unused container layers** (`buildctl prune --free-storage`, `docker image prune -f` — the daemon knows what is still referenced), **dead `*.bak-<stamp>` store husks** left by `reset-container-stores.ps1`, **user + Windows TEMP**, rotated host logs and repo `out/` scratch. Works from an ALLOWLIST, never a denylist; **reports by default — `-Apply` is required to delete**; every live-directory rule is **age-gated** (`-TempOlderThanDays`, default 7) so nothing in flight is touched. Fails the WHOLE run if any resolved candidate lands on a protected root (Program Files, Windows, ProgramData outside the container stores, user profiles, AppData, drive roots), because that means the resolution logic is wrong, not that one target should be skipped. Skips any candidate containing a junction/symlink — a reparse point is where a name stops predicting what a recursive delete reaches. **Never touches the sccache/ccache/cargo/uv compile caches** (CACHE1: hours of build time for a few GB) or anything installed. Refuses the destructive half while a build looks live unless `-AllowDuringBuild`. Parameters: `-Apply`, `-KeepGB` (buildkit free-space target, default 100), `-TempOlderThanDays`, `-AllowDuringBuild`, `-NoDaemonPrune`. Enforced from outside the script too, by the `PreToolUse` guard in `.claude/hooks/guard-destructive-deletes.ps1`; behaviour pinned by `windows/scripts/tests/Guard.DestructiveDeletes.Tests.ps1` |

## Refactor Backlog (Windows container chain)

> **COUNTING NOTE:** item numbers are HISTORICAL and never reused — the highest
> number is not the item count. Resolved narratives move to the dated archives
> (`windows-backlog-archive-*.md`); a bare "#N" that is not in this file
> resolves there. Lean-OPEN-only is the owner''s standing policy.

### OPEN

#### ARM64 parity (opened 2026-08-23)

The `:winarm64` cross lane completes end to end — since 2026-08-24 that includes the source-built
target CPython, plain LiteRT and the restored `tflite` GStreamer plugin, with all four mandatory
plugins shipping on BOTH lanes again — its arch gate passes **931 binaries, 0 violations** (the
390 recorded at opening predates those additions), and the smoke gate now RUNS on this lane:
**97 passed / 0 failed / 15 skipped** against floors 66/25. As of 2026-08-24 evening (arm64 run
11: all three media branches, arch gate 950/0, smoke 97/0/15) every component **builds** for the
target: the Python-binding consumers landed (#120 step 2) and TVM/IREE ship as runtimes (#116);
amd64-only by construction are the TVM/IREE *compilers* and their python packages, LiteRT-LM
(Bazel), CUDA (#122, deferred by the owner) and the torch app stage — each marked ABSENT inside
the bundle; the QNN EP is wired but needs a hand-staged SDK (#121). **CORRECTED 2026-08-25
(consumer-side audit, three reviewers, claims re-checked against code and configure logs): "built"
is not "usable at first touch".** The bundle's Python surface would fail on a clean
Windows-on-ARM machine before any user code runs — `python.exe` cannot find its own
`vcruntime140.dll` (#124), no `sitecustomize` registers the DLL directories for the target
interpreter (#125), no numpy/pip/runtime deps are staged for the target (#126) — and two
silent degradations no gate watches: GStreamer arm64 lacks `webrtc`/`nice` (#128) and OpenCV arm64
ships **zero dispatched NEON kernels** (#129). Entries #124–#131 below carry the evidence and the
fixes; every one is host-side and statically gateable. **FIXED 2026-08-25 (arm64 run 14, `[bk]
Done in 01:26:50`): #124–#127 are closed** — CRT beside `python.exe` and in `C:\runtime\bin`
(9 DLLs), a target `sitecustomize`, 7 wheels with every `Requires-Dist` resolving in the store, and
a whole-tree import walk as a hard merge gate (`970 inspected / 0 violations; 571 walked / 0
unresolved`); its first run had found 13 real gaps (OpenSSL runtime DLLs, `vcruntime140_threads`,
client-OS names), all now staged or classified. #128/#129 stay open as degradations, not blockers.
Each item below carries a
**verified** blocker — every one was researched against the actual code and upstream, then
adversarially re-checked, because an optimistic "solvable" here costs 25 min to several hours
of build time per attempt. Ordered by leverage ÷ risk, which is the order they should be done in.

- **#112 — FFmpeg aarch64 assembly.** ✅ **DONE 2026-08-24 (Route A, built and verified).**
  Route A needed **no new tooling**: `$confFlags += "--as=clang$ffCcTargetFlag"` replaced
  `--disable-asm`, letting clang's integrated assembler handle the GAS syntax that
  `gas-preprocessor.pl` + `armasm64` (Route B) would otherwise have been needed for. The
  precondition held: `--enable-cross-compile` disables configure's runtime probes, so configure only
  *assembles* its test fragments and never runs a produced binary — which is the only reason this is
  tractable on a host that cannot execute aarch64 at all.
  **Evidence, not inference:** the build log reports `NEON enabled yes`, `config.mak: ARCH=aarch64`
  and `config.mak: AS=clang --target=aarch64-pc-windows-msvc`, and of the **99 distinct
  `aarch64/*.o`** objects, **56 went through real `AS` steps** — `swscale_unscaled_neon.o`,
  `vf_bwdif_neon.o`, `aacencdsp_neon.o`, `ac3dsp_neon.o` and so on — while the other 43 are
  C-compiled `*_init*`/dispatch TUs. (Two earlier notes said 87 and then "99 assembled"; both were
  mis-counts — 99 is the total, 56 is the assembled subset, measured 2026-08-24 with `AS`-line
  extraction rather than filename counting.) The amd64 lane is untouched because the flag sits inside the
  cross-only branch and is composed solely from the cross-lane target flag. At the time this landed
  amd64 had **no** nasm path to keep — `--disable-x86asm` had been appended unconditionally since
  bd6adca4 (2026-06-25, it entered with the file itself), so FFmpeg built no external x86 assembly on
  either lane. That asymmetry (arm64 with NEON assembly, amd64 with none) was filed as #119 and
  closed the same day by enabling x86asm on the amd64 lane (see #119 below).

- **#113 — DirectML on arm64.** ✅ **DONE 2026-08-24 (ORT side; built and gate-verified).**
  Confirmed by byte inspection, not inference: `Microsoft.AI.DirectML` 1.15.4 *does* ship
  `bin/arm64-win/DirectML.lib` (COFF import archive, machine `0xAA64`). This was never a packaging
  gap, and the "no arm64 import library" verdict recorded until 2026-08-23 is retracted.
  `cmake/external/dml.cmake` declares the download's outputs lower-case as `bin/arm64-win`, while
  `cmake/onnxruntime_providers_dml.cmake` composes its consumer paths as
  `bin/${onnxruntime_target_platform}-win` — and `onnxruntime_target_platform` holds the verbatim,
  upper-case `ARM64`. The two spellings never meet, so the lane failed with
  `bin/ARM64-win/DirectML.lib ... missing and no known rule to make it`. That the failing message
  itself said `ARM64` is what proves the variable's casing, and therefore that `TOLOWER` lands on
  the directory that exists.
  **Fix:** two `Invoke-InlineRegexPatch` edits in `build-onnx-from-source.ps1` — one inserts
  `string(TOLOWER "${onnxruntime_target_platform}" onnxruntime_dml_redist_platform)` above the
  `if (NOT onnxruntime_USE_CUSTOM_DIRECTML)` block, the other reroutes both consumers through it;
  a re-read then throws if either edit misses, so upstream drift fails loudly instead of silently
  reverting to the broken path. Both were simulated against the real upstream file before building
  (TOLOWER inserted once at module scope, zero upper-case consumers left, two lower-case). A static
  `.patch` was written first and deleted — its hunk line counts were hand-computed, and the inline
  patcher is already this repo's drift-tolerant mechanism. `USE_DML` is now ON unconditionally in
  ORT.
  **Evidence it worked:** both patch lines logged at 33.5s; `ONNX: DirectML EP ON`;
  `[1116/1118] Linking CXX static library onnxruntime_providers_dml.lib`; `DirectML.dll` staged to
  `C:\runtime\lib\onnxruntime-source\bin`; 117 of 994 sccache requests missed — the DML translation
  units that had never compiled on this lane. The merge-stage arch gate then reported
  **390 binaries inspected, 0 violations** (389 before DirectML joined), with no allowlist skips.
  Since the gate's root is `C:\runtime`, `.dll` is in its extension set, and
  `Dockerfile.media-merge-builder:155` copies the whole `C:\runtime` tree, `DirectML.dll` was
  necessarily among the 390 — so the shipped DirectML is arm64.
  **Honest limit:** this proves the right *bytes* ship, not that the DML EP *runs*. Nothing arm64
  executes on this x64 host; only the `windows-11-arm` CI job can show that.
  **Follow-up — closed by #118 (2026-08-24):** GenAI (`-DUSE_DML`) and OpenCV (`WITH_DIRECTML`)
  were OFF when this entry was written; both are ON on both lanes since #118 landed the same
  day. Worth recording so the
  next reader does not re-investigate it: GenAI's `D3D12Core.dll` staging is *already* correct for
  arm64 — `$d3d12ArchDir = (Get-WindowsRuntimeIdentifier) -replace '^win-', ''` resolves through
  `Get-WindowsTargetArch`, i.e. the **target**, giving `arm64` on this lane, and the nuget's
  directory names are exactly those RID arch components. That was made target-derived deliberately
  (see the comment at `build-onnx-genai-from-source.ps1:286`) precisely for this eventuality.

- **#114 — aarch64 CPython, and the Python bindings it unblocks.** L · ★★★ · **SUPERSEDED-BY #120** (its Phase-0 questions still apply — answer them there first)
  The highest-leverage item: it is what keeps `cv2`, the ONNX Runtime wheel, ONNX GenAI's bindings
  and PyAV off the lane. **Do Phase 0 first** — a ~20 min probe (no chain rebuild) answering exactly
  three questions: does the image's VS ship `Platforms\ARM64\PlatformToolsets\ClangCL`, does
  `Hostx86\arm64\cl.exe` exist (setuptools' `x86_arm64` spec needs it for PyAV), and does
  `PCbuild\build.bat -p ARM64` actually run to completion. Could not be answered up front because
  `ctr`/`docker` need elevation on this host. **The decisive distinction** is between *compiling and
  linking a `.pyd` against the target's headers and import lib* (no execution, feasible) and
  *setuptools/pip wheel packaging*, which normally runs the interpreter (not feasible here).
  `Get-SourceBuildPython` must stay HOST-pinned — the cross lane runs builds with the host
  interpreter while linking against the target one. Those two must never be conflated again.

- **#115 — plain LiteRT without LiteRT-LM (would also restore the `tflite` GStreamer plugin).** L · ★★ · ✅ **DONE 2026-08-24 (built, merged, gate- and smoke-verified).**
  `media-litert` runs on arm64 — 146 libs staged incl. the aarch64 `tensorflowlite_c.lib`; the
  LiteRT-LM stage self-skips (citing its two real Bazel blockers, below) and stages the empty
  litert-lm stand-in tree so the merge COPY keeps working. Cross needs exactly TWO host tools, both
  from pinned sources: `flatc` built natively from the SAME tree (the `flatbuffers-flatc` target, a
  per-call `-TargetArch` host override on that one choke point) and protoc **21.9** (github release
  zip — the version derives from the VENDORED protobuf commit `90b73ac3` = C++ runtime 3.21.9, NOT
  the LM lane's `PROTOC_VERSION=31.1`, whose gencode needs a `google/protobuf/runtime_version.h`
  that 3.21.9 does not ship). XNNPACK needed the MLAS-class per-TU treatment, now in
  `build-litert-from-source.ps1`: 569 C microkernel TUs tagged per-FAMILY in `build.ninja`
  post-configure (families completed against upstream's `PROD_*` list; SME skipped; floor 100),
  while the 335 hand-written aarch64 `.S` kernels get a FULL-UNION in-source
  `.arch armv8.2-a+fp16+dotprod+i8mm+bf16` directive — an assembler validates but never emits, so
  the union is byte-neutral for asm, while C stays per-family because a compiler may auto-vectorize
  (floor 10). The green took **8 iterations**: two self-inflicted (a PowerShell
  plus-sign-outside-parameter binding bug; the legacy export-symbol assumption, next paragraph),
  the rest genuine cross gaps — the per-TU features, the chain-wide ASM triple
  (`Get-CMakeCrossArgs` now also sets `CMAKE_ASM_COMPILER_TARGET` / `CMAKE_ASM_FLAGS_INIT`; before
  that, any project enabling the ASM language assembled with the X64 default target, and an aarch64
  `-march` handed to that x86 driver was misread as a CPU name — amd64 untouched, its cross args
  stay empty), host `flatc`, host protoc + its version family, and the vcruntime redist copy (#120).
  **Durable measurement (2026-08-24), so no future gate re-asserts the wrong symbol:** the plugin
  contract demands all four mandatory plugins on BOTH lanes again (`Get-RequiredGstPlugin`'s
  `UnavailableOn.arm64` deleted), the tflite switch is presence-driven
  (`-Dgst-plugins-bad:tflite=enabled`, never auto), and the hardened cross plugin gate walks the
  dependency tree (dumpbin) AND asserts the per-plugin export marker — MEASURED: modern GStreamer
  (per-plugin registration since 1.14) exports `gst_plugin_<name>_get_desc` + `_register`, NOT the
  legacy `gst_plugin_desc` the gate's first version asserted; that version failed all four plugins
  incl. three amd64-proven ones and was recalibrated from dumped export tables.
  **History — the pre-build analysis below is kept as written (it dates its own corrections):**
  **Corrected twice — the 2026-08-23 correction that stood here was itself half-wrong (fixed
  2026-08-24):** the original note blamed ONLY the prebuilt `libGemmaModelConstraintProvider.lib`;
  the 2026-08-23 rewrite swung to blaming ONLY the `.bazelrc`. **Both halves are real** on
  LiteRT-**LM**'s active **Bazel** path: (a) `.bazelrc` has no windows-arm64 config (only
  android/macos/ios arm64 ones), and (b) the prebuilt **x86_64-only**
  `libGemmaModelConstraintProvider` *is* in the default Windows dependency graph via
  `gemma3_data_processor` — severable with the `litert_lm_fst_constraints_disabled` config_setting
  (`model_data_processor/BUILD:26-33`), so a removable blocker, not a wall. (The earlier "upstream's
  CMake path compiles the `gemma_model_constraint_provider.cc` stub instead" observation described
  the frozen CMake fallback, not the active Bazel path.) **Neither half applies to plain LiteRT**:
  pure CMake, no Bazel, no prebuilt — its only cross obstacle is upstream's `TFLITE_HOST_TOOLS_DIR`
  requirement for a host `flatc`, and `flatc` is already named on the merge gate's host-tool
  allowlist. That plain-LiteRT cross build is exactly this item. If it lands, the
  `media-branch-absent` stand-in shrinks and `Get-RequiredGstPlugin -Arch` can stop dropping `tflite`.

- **#116 — TVM + IREE on arm64.** XL · ★
  Lowest priority: highest cost, narrowest benefit, medium confidence. First, a retraction: an
  earlier note claimed TVM's "codegen cannot emit aarch64 … not fixable in this repository" — false
  since it was written, because `LLVM_TARGETS_TO_BUILD=X86;NVPTX` is set **by this repo** in
  `build-tvm-from-source.ps1`, in an array the script fully controls. **Phase 0 is worth doing on
  its own merits and is amd64-only:** adding `AArch64` to that list is a one-token edit that
  lets the **x64** image's TVM emit aarch64 code (`tvm.build(target='llvm -mtriple=aarch64-…')`) for
  one extra LLVM target of build time. It does **not** unblock the arm64 branch — do not conflate
  the two. The **real** remaining cross cost is that `USE_LLVM=<path>` must *execute*
  `llvm-config.exe`, which an x64 host cannot do against a target-arch LLVM — the cross lane needs a
  host-tools/target-libs split of the minimal-LLVM build. **IREE rides this same dropped branch and
  must be named wherever the absent branches are listed** (it was a silent casualty of TVM-only
  phrasings); upstream already supports the split there via `IREE_HOST_BIN_DIR`. Everything past
  Phase 0 (cross-capable minimal LLVM, IREE's in-tree LLVM and its host tools) is genuinely large.
  **Phase 0 DONE 2026-08-24, measured:** the amd64 full regression (media all-branches + merge +
  final + smoke) built TVM's LLVM with `LLVM_TARGETS_TO_BUILD=X86;AArch64;NVPTX` and passed —
  `media-tvm-built` green in 21:17 (sccache carried the LLVM rebuild; 9110 compile requests,
  8388/8389 targets incl. IREE), then arch gate 1134/0 and smoke 220/0/0. The x64 image's TVM
  can now emit aarch64 code.
  **Runtime-only cross IMPLEMENTED 2026-08-24 evening (the scope that needs no host-tools split
  for TVM at all, and only upstream's documented one for IREE):** the arm64 bundle ships
  `tvm_runtime.dll` + `tvm_ffi.dll` (+ import libs, headers) and IREE's runtime tools/libs; the
  compilers and python packages stay amd64-only and are named ABSENT in `COMPILER-ABSENT-ON-ARM64.txt`.
  Mechanics: TVM configures `USE_LLVM=OFF`, python OFF, builds `ninja tvm_runtime` alone (a
  `-Targets` parameter on `Invoke-NinjaBuildWithRetry`, so `tvm_compiler` never builds) and stages
  by hand with an in-stage PE gate; IREE configures the same tree twice — a native runtime-only
  host build installed to `build-host\install` (asserted to hold `iree-flatcc-cli.exe` +
  `iree-c-embed-data.exe` (IREE 3.x's name; the pre-rename `generate_embed_data` was asserted first and run 5 caught it)), then the target configure with `IREE_HOST_BIN_DIR`,
  `IREE_BUILD_COMPILER=OFF`, python OFF — with a static PE gate replacing the compile+run gate.
  `media-tvm` left `$crossBlockedBranches` (the driver-level refusal list, removed altogether on 2026-08-25 in #131 once empty), all three branches are
  merge-required on both lanes, and the `media-branch-absent` stand-in stage is retired. Full
  description in `docs/windows-cross-builds.md` § "TVM and IREE cross-build runtime-only".
  **Measured on the way (arm64 runs 3–4):** (1) TVM runtime cross-builds in under a minute — 4
  runtime binaries, all `0xAA64` — but the header copy hit 0.26's layout: `dmlc-core` is gone and
  `dlpack` lives inside the `tvm-ffi` submodule's own `3rdparty`; the copy is now layout-searched
  and asserts `tvm\runtime\c_backend_api.h`, `tvm\runtime\device_api.h`, `tvm\ffi\c_api.h`,
  `dlpack\dlpack.h` landed (the first anchor tried, `c_runtime_api.h`, is itself gone with the
  FFI split — run 4 caught that, which is what the assert is for). (2) The
  IREE host pass died in its first try-compile: `msvcrtd.lib(exe_main.obj): machine type arm64
  conflicts with x64` — VsDevCmd `-arch=arm64` leaves `LIB` on the ARM64 CRT and lld-link reads
  only `LIB` (CMake calls it directly, no clang-driver auto-detection). Exactly the "necessary but
  not sufficient" the choke point's comment warned about. `Invoke-WithHostArchLibraryEnvironment`
  now rewrites the arch segment of every `LIB`/`LIBPATH` entry (`\arm64` → `\x64`) for the duration
  of the host pass and restores it (`SourceBuild.HostArchLibEnv.Tests.ps1`), without re-entering
  VsDevCmd (a second invocation appends rather than resets). (3) With the host tools built, the
  target ninja died on `'build-host/install/bin/iree-flatcc-cli', needed by '…/dummy_reader.h',
  missing and no known rule to make it` — IREE composes `${IREE_HOST_BIN_DIR}/<tool>` **without the
  `.exe` suffix** (Linux-shaped), and ninja wants that exact file as a dependency. An **upstream
  gap for Windows hosts** (draft: `out/upstream-issue-iree-host-bin-dir-exe.md`); the script stages a
  suffix-less twin of each host tool next to the `.exe` — ninja sees the file, `CreateProcess`
  appends `.exe` when launching an extension-less full path, same bytes either way. Also caught on
  the way: the host tool is `iree-c-embed-data.exe` in IREE 3.x, not the pre-rename
  `generate_embed_data`. (4) With the host tools resolved, the **target** build reached IREE's
  arm_64 ukernels and died the MLAS/XNNPACK way: `always_inline function 'vfmaq_f16' requires
  target feature 'fullfp16'` — upstream hands each feature kernel its `-march=armv8.2-a+<feat>`
  through `iree_select_compiler_opts(CLANG_OR_GCC …)`, and clang-cl is classified as MSVC there,
  so the flags are dropped; plus bare `asm(...)` (GNU keyword, off under MS compat) in
  `mmt4d_arm_64_fp16fml.c`. Same remedy, same discipline as the other two: post-configure
  per-TU tagging of `build.ninja` (`/clang:-march=armv8.2-a+{fp16,fp16fml,bf16,dotprod,i8mm}`
  on the five feature kernels, floor **5** — the pre-fix state tags 0 — and `-Dasm=__asm__` on
  every arm_64 ukernel TU). (5) Past the ukernels, `iree_hal_local_elf_arch.lib` failed to
  archive: `x86_64_msvc.obj: file machine type x64 conflicts with library machine type arm64` —
  **upstream bug**, `hal/local/elf/CMakeLists.txt` adds the x86-64 MASM trampoline whenever
  `MSVC_C_ARCHITECTURE_ID MATCHES 64`, and `ARM64` matches `64` (draft:
  `out/upstream-issue-iree-elf-arch-arm64-msvc.md`). Inline-patched to an exact x64 match on both
  lanes (on amd64 the id is `x64`; nothing changes there), verified post-patch. (6) With that,
  the **entire ARM64 runtime compiled** (608/659) and the tools failed only to *link*:
  `undefined symbol: iree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm`. Checked file by file:
  it is upstream's one non-static C `inline` definition in the arm_64 kernel set, and the entry
  point takes its address — under C99 inline semantics (clang's default in C mode) an `inline`
  definition without `extern` emits no external symbol. Per-TU `/clang:-fgnu89-inline` was tried
  first (run 10) and did **not** produce the symbol under clang-cl, so the definition itself is
  inline-patched to a plain `void …(` — `inline` buys nothing for a function used by address;
  verified after applying, inert on amd64 (the arm_64 dir is not compiled there). How upstream's
  own Linux/clang builds link this is not verified here; flagged as a question, not asserted.
  ✅ **DONE 2026-08-24 evening, measured (arm64 run 11):** `media-tvm-built` green in 7:59 —
  TVM runtime 4 binaries, IREE 14 target binaries under `bin\`, every one PE `0xAA64` in-stage;
  merge 34:50 with the arch gate at **950 inspected / 0 violations** (up from 931: the TVM/IREE
  runtimes are now in the bundle); final + smoke **97/0/15**. Runtime-only is the shipped scope;
  the compilers and python packages stay amd64-only and are named ABSENT in
  `COMPILER-ABSENT-ON-ARM64.txt`. Execution proof, as for everything on this lane, is owed to a
  native host.

- **#117 — the arch gate covers `C:\runtime` only; the CPython tree is outside it.** S · ★★ · ✅ **RESOLVED 2026-08-24 (see the resolution below; the question stands as history).**
  `Dockerfile.media-merge-builder:172` fans in `C:\temp\cpython\Lib\site-packages`, and the gate runs
  `-Path 'C:\runtime'`. So the arm64 image carries the **host x64 CPython and its site-packages**, and
  the binaries the gate reported were all genuinely arm64 — they just were not *everything*.
  **Not obviously a defect, which is why this is a question and not a fix:** that interpreter is the
  HOST tool that *runs* the builds and is legitimately x64, so simply adding `C:\temp\cpython` to
  `-Path` turns a correct build red. Decide first what `C:\temp` *is* — build residue or shipped
  payload — then either exclude it from the image on the cross lane or gate it with the host-tool
  allowlist. A first attempt at "just gate it too" was written and reverted on 2026-08-23 for exactly
  this reason. Resolve together with #114, which changes the answer.
  **Resolution (2026-08-24):** exactly as this entry predicted, #114's successor — #120 — changed
  the answer. The merge arch gate now scans `C:\runtime` AND `C:\temp\cpython\Lib\site-packages`,
  with `-IncludeArchives`; the 58 host x64 `.pyd`s in site-packages appear as REPORTED allowlist
  skips, and the green figure — **931 binaries, 0 violations** — is the whole-image statement this
  item asked for. The "is `C:\temp` payload?" half is settled by #120: the SHIPPED interpreter on
  arm64 is `C:\runtime\python`; the host CPython stays build tooling.

- **#118 — flip DirectML ON for GenAI and OpenCV now that ORT's arm64 DML is verified.** S · ★★ · ✅ **DONE 2026-08-24 (both flips built and gate-verified).**
  Unblocked by #113. Both are OFF **purely as sequencing**, not for any platform reason: GenAI links
  ORT, so a half-enabled DML there produces link errors that read like a GenAI bug, and OpenCV's
  `cv::dnn` would advertise a backend whose runtime half was unproven. ORT's side is now built,
  linked and gate-verified, so that reason has expired.
  **Two things already checked, so the next reader does not redo them:** (1) GenAI's `D3D12Core.dll`
  staging is already target-derived — `(Get-WindowsRuntimeIdentifier) -replace '^win-', ''` resolves
  through `Get-WindowsTargetArch`, yielding `arm64` here, and the `Microsoft.Direct3D.D3D12` nuget's
  directory names are exactly those RID arch components. (2) The Agility SDK does ship an arm64
  `D3D12Core.dll`. So this is close to two one-line flips plus a rebuild.
  **What to watch:** the arch gate count must rise again (each newly staged DLL is one more
  inspected binary, and `D3D12Core.dll` is not on the host-tool allowlist), and OpenCV's
  `WITH_DIRECTML=ON` pulls DirectML headers into `cv::dnn` TUs that have never seen them on this
  lane. Do GenAI first and OpenCV second — same reasoning as #113's ordering.
  **The limit stays the same as #113:** a green build proves the right bytes ship, never that the EP
  runs. Only the `windows-11-arm` CI job can show that.
  **Done (2026-08-24):** GenAI builds with `USE_DML=ON` on both lanes and stages the **arm64**
  `D3D12Core.dll` from the nuget's `bin/arm64` — the target-derived filter above resolved exactly
  as recorded, no re-investigation needed; OpenCV builds with `WITH_DIRECTML=ON`, consumed via the
  G-API EP. The arch gate count rose as predicted and the whole-image figure stands at
  **931 binaries, 0 violations** (see #117). The runtime limit above is unchanged: bytes proven,
  execution still owed to the `windows-11-arm` CI job.

- **#119 — amd64 FFmpeg ships with NO external x86 assembly, and arm64 now has more SIMD than it.** M · ★★
  ✅ **DONE 2026-08-24, proven the same evening on the amd64 regression:** configure reports
  `x86 assembler  …/nasm.exe`, the build assembled **154** `X86ASM` objects (`libavcodec/x86`,
  `libavfilter/x86`, `libswscale/x86`, …) and linked them under lld-link into `ffmpeg.exe` + the
  7 DLLs; the stage went green in 6:15 including the PyAV wheel and its `import av` gate. The
  lld-link-vs-nasm-object question the original entry raised is answered by that link step.
  Found 2026-08-24 while checking whether #112 could regress amd64. It cannot — but the check turned
  up something else: `build-ffmpeg-from-source.ps1` appended `--disable-x86asm` **unconditionally**
  (present since `bd6adca4`, 2026-06-25 -- it entered with the file itself; an earlier note here blamed `8c5c50e7`, which is only the relicense commit that MOVED the file), so FFmpeg built none of its hand-written x86 SIMD
  on either lane. After #112 the cross lane assembled 99 NEON objects while amd64 assembled zero —
  the arm64 bundle was, in this one respect, *ahead* of the shipped amd64 image.
  **The archaeology was done before the flip, as this entry demanded.** `git show bd6adca4` is a
  bare "fix" commit (5 files, 347 insertions) that added the whole FFmpeg script; the flag sits
  between `--toolchain=msvc` and the CUDA comment with **no rationale, no failing configure, no
  nasm/lld-link note** — a first-bring-up simplification that later got documented as a premise. The
  script now enables x86asm on the amd64 lane (`--x86asmexe=<pinned nasm>`, asserting nasm is on
  PATH — `verify-toolchain.ps1` already pins it) and keeps `--disable-x86asm` **explicitly** on the
  cross lane, where the knob is meaningless for aarch64. The comment at
  `build-ffmpeg-from-source.ps1:410` no longer calls the disabled state a premise of the toolchain
  choice; it was never load-bearing for the msvc-preset-plus-compiler-override approach (configure
  assembles nasm fragments independently of `--cc`).
  **What "proof" meant here, and what delivered it:** configure names the x86 assembler only when
  nasm assembled its test fragment, and the build log then carries `X86ASM` lines for the `.asm`
  kernels. The deciding artifact was the amd64 `media-core-built-ffmpeg` solve of 2026-08-24
  ~23:10 (see the DONE line above) — nasm invoked through its scoop shim, 154 objects, clean link.
  **The misattribution this uncovered** (three places claimed nasm was *FFmpeg's* assembler: the pins
  table, `verify-toolchain.ps1`, the old #112 text) was corrected the same morning — and then
  re-corrected the same evening, because the flip made the original attribution *true again*: nasm
  now shapes both GStreamer's openh264 (`build-gstreamer-from-source.ps1:482`) and FFmpeg's amd64
  kernels.

- **#120 — target aarch64 CPython built from source (`PCbuild -p ARM64`, ClangCL), and the
  bindings it unblocks.** L · ★★★ · ✅ **DONE 2026-08-24 — step 1 (the interpreter) in the
  morning, step 2 (all four binding consumers) in the evening** (opened 2026-08-24; supersedes #114)
  The gap it closes: the arm64 image advertises `PYTHON_WHEELS` while the wheel store
  `C:\runtime\wheels` is **empty** on that lane — no `cv2`, no ORT wheel, no GenAI bindings, no
  PyAV. Decided 2026-08-24: build the target CPython **from source** via `PCbuild\build.bat -p
  ARM64` under ClangCL, the same route the host CPython already takes; the alternative — fetching
  the upstream nuget arm64 CPython — was considered and **rejected by the owner** (2026-08-24), so
  do not resurrect it. #114's Phase-0 questions (ClangCL ARM64 platform toolset present?
  `Hostx86\arm64\cl.exe` present? does `PCbuild\build.bat -p ARM64` complete?) still apply and come
  first. #114's decisive distinction also carries over unchanged: `Get-SourceBuildPython` stays
  HOST-pinned — the cross lane runs builds with the host interpreter while linking against the
  target one; the two must never be conflated again.
  **Step 1 DONE (2026-08-24), measured:** `PCbuild\build.bat -e -p ARM64` with the repo's ClangCL
  props + `/p:PreferredToolArchitecture=x64` completes in ~91 s incl. the externals fetch;
  `python.exe` is PE `0xAA64`, verified IN-STAGE; **2864 files** staged to `C:\runtime\python`
  (interpreter, `python314.lib`, headers, stdlib). This answers #114's Phase-0 Q1 POSITIVELY: VS 18
  ships the ClangCL PlatformToolset for ARM64 — pythoncore's own "Toolset ClangCL is not used for
  official builds" warning fired, which proves the toolset resolved.
  **Durable fact (2026-08-24), so nobody hunts for a "missing" DLL:** `vcruntime140_1.dll` has NO
  ARM64 edition **by design** — it exists only to carry x64 FH4 exception helpers; ARM64 keeps
  everything in `vcruntime140.dll`. MSBuild's host-blind redist copy put the **x64** one into the
  ARM64 build output, the extended arch gate caught it (the single violation among 932 scanned),
  and the stage now self-polices every staged binary's PE machine and drops exactly that file under
  a tightly-guarded rule.
  **Step 2 DONE (2026-08-24 evening, arm64 run 3), measured — all four consumers build for the
  target:** `onnxruntime-1.29.0-cp314-cp314-win_arm64.whl` (4 native members, all `0xAA64`),
  `onnxruntime_genai_directml-0.15.2-cp314-cp314-win_arm64.whl` (3), `av-18.1.0-cp314-cp314-win_arm64.whl`
  (49), and `cv2.cp314-win_arm64.pyd` installed into the **target** interpreter's site-packages
  (`C:\runtime\python\Lib\site-packages`, inside the arch gate's scan root). The design that made it
  work, in one line each — full detail in `docs/windows-cross-builds.md` § "#120 step 2":
  the HOST interpreter *runs* every build (`Get-TargetBuildPython .Exe`), the TARGET import lib is
  what gets *linked* (`.Lib`/`.LibDir`); wheels are built with an explicit `--plat-name win_arm64`
  and **staged, never installed or imported** here (`Invoke-PythonWheelBuild -StageOnly`, since #131 the one-call `-CrossStage` →
  `Assert-WheelTargetArch`, which opens the wheel and PE-checks every native member **and** its
  `EXT_SUFFIX` name tag); cv2 gets the static equivalent of its import gate. Three findings the
  runs produced, each now pinned by code or test: (1) ORT's CMake reads `Python_*`, not
  `Python3_*` — the names passed for months were silently ignored on **every** lane ("Manually-
  specified variables were not used"), amd64 only worked by auto-detection; GenAI needs **both**
  `Python_*` (its own `find_package`) and the legacy `PYTHON_*` (its vendored pybind11 in classic
  mode) — `SourceBuild.FindPythonPrefix.Tests.ps1`. (2) `if (Test-WindowsCrossTarget -and -not
  …)` is parsed in *command mode* — `-and`/`-not` become arguments, the branch fires regardless —
  which is how run 2 skipped the ORT wheel with "python wheel 0s". (3) The host-pinned
  `sitecustomize` shim stamped the **host** `EXT_SUFFIX` on target modules
  (`cv2.cp314-win_amd64.pyd`, machine `0xAA64`: right bytes, unloadable name — an arm64 interpreter
  loads only `.cp314-win_arm64.pyd` or bare `.pyd`); the shim now pins `EXT_SUFFIX` to the target on
  the cross lane while `get_platform()` stays host (pip resolves downloads with it), verified
  standalone under a host python before the run. The `C:\runtime\wheels` store is no longer empty
  on arm64. What still cannot happen here: importing any of it — every arm64 signal stays static.

- **#121 — QNN execution provider (Qualcomm AI Engine Direct / QAIRT).** L–XL · ★★★ strategically ·
  **SCAFFOLD DONE 2026-08-24 — opt-in, unproven until an SDK zip is staged.**
  The one accelerator whose entire reason to exist is the hardware `:winarm64` actually targets:
  Microsoft's own Snapdragon guidance points at the **QNN** EP, not DirectML, for NPU inference on
  Windows-on-ARM. The 2026-08-24 parity audit found **zero code** for it on either lane and — more
  importantly — **no blocker to cite**: the obstacles are SDK acquisition and verification, not
  platform support. The verification ceiling is exactly DirectML's: a green cross build proves the
  right bytes ship, never that the EP runs — NPU execution needs Snapdragon hardware, which not even
  a `windows-11-arm` CI runner guarantees.
  **What landed (2026-08-24 evening):** the vendor-zip pattern, adapted — `windows/qnn-sdk/` is the
  hand-staging drop (git-ignored except its README, which carries the download/EULA/layout facts),
  bind-mounted into the media-core `onnx` RUN; `QNN_SDK_ZIP_SHA256` in `versions.env` is the
  optional integrity pin (media-core-env ARG/ENV, driver map, `bump_versions.py` allowlist — the
  TensorRT contract); `build-onnx-from-source.ps1` extracts, anchors the SDK root on
  `include\QNN\QnnInterface.h`, asserts the target's `lib\<arch>\QnnCpu.dll`
  (`Get-QnnSdkLibDirName` in the arch table), passes `-Donnxruntime_USE_QNN=ON -Donnxruntime_QNN_HOME`
  on both lanes, and post-install asserts `onnxruntime_providers_qnn.dll` and stages the backend
  DLLs + `hexagon-v*` skels beside `onnxruntime.dll`. **No zip = EP off with one notice**, which is
  the only path any run has exercised — this host never held the SDK, so the SDK-present branch is
  a scaffold whose asserts are written to fail loudly on the first staged zip. Full description in
  `docs/windows-cross-builds.md` § QNN. Open: stage a real SDK, run once, then a native Snapdragon
  host for execution.

- **#122 — CUDA 13.4 (preview) on arm64: Phase 0 probe, then decide.** Probe S, wiring L · ★
  Phase 0 (~30 min, NO chain rebuild): arch-parameterize the literal `windows-x86_64` in
  `setup-cuda.ps1` (the audit found it hardcoded at the download-URL composition), HEAD the
  already-200-verified arm64 cuDNN archive at the exact pin, pull the CUDA 13.4 preview installer
  and confirm arm64 device `.lib`s are machine `0xAA64`. Only if all three hold: re-key the ORT
  CUDA branch on "an arm64 CUDA root exists" rather than "this is a cross build", point nvcc at
  the already-installed `Hostx64\arm64` MSVC toolset, and patch GenAI's `ortlib.cmake` CUDA
  package-name branch (it keys on `CMAKE_GENERATOR_PLATFORM`, empty under Ninja, so a naive flip
  fetches the x64-only nuget). **Do not relax the `-Gpu` driver refusal until both hold** — the
  image-state hazard it guards is real and unrelated. Value stays low while CUDA-on-WoA is a
  preview; the entry exists so the next reader starts from facts, not from the retracted
  "does not exist at all".

**Permanently out of reach — do not re-litigate without new upstream facts:** classic TensorRT
(genuinely x64-only — NVIDIA's support matrix has no ARM64 row), and the `torch` app stage (`uv
sync` must **execute** the target interpreter — uv can cross-RESOLVE into a directory, but the
synced venv is the stage's contract — and PyTorch builds no `win_arm64` wheel for **Python 3.14**,
this repo's cp314 pin). **Two premises originally recorded in this block (2026-08-23) were wrong
and are retracted (2026-08-24 parity audit):** "CUDA / cuDNN / TensorRT: no Windows-on-ARM builds
exist at all" — false: the cuDNN windows-arm64 9.25.0.15 archive exists at this repo's exact pin
(HTTP 200, 421 MB, `lib/arm64` inside), CUDA 13.4 (preview) advertises Windows ARM64 incl.
x86_64-hosted cross-compile, and TensorRT-RTX publishes Windows-on-Arm packages for CUDA 13.4 —
wiring CUDA into the cross lane is unscheduled backlog work, not fiction; and "the pinned PyTorch
publishes no `win_arm64` wheel" — false as an absolute: download.pytorch.org does publish
`win_arm64` `+cpu` wheels, just none for cp314. The verdicts stand on the corrected reasons.
**Note the meta-lesson: a false premise inside a do-not-re-litigate block is precisely how such
errors survive — the block shields its reasons from checking, so the reasons recorded here must be
verified facts, never remembered summaries.**

**A measurement that used to sit in the tree was retracted and has since been re-taken:** the PyAV
note in `build-ffmpeg-from-source.ps1` ("`ImportError: DLL load failed while importing Utils`") was
recorded while `Initialize-PythonPlatformTag` was still stamping the **target** tag on the **host**
interpreter — so pip resolved a `win_arm64` Cython into the x64 host Python. The bug and its fix
landed in the same commit (`ed2a04d4`). **Re-measured 2026-08-24 evening (#120 step 2): PyAV
cross-builds.** `setup.py --ffmpeg-dir=<arm64 ffmpeg> build_ext --plat-name win-arm64 bdist_wheel
--plat-name win_arm64` produced `av-18.1.0-cp314-cp314-win_arm64.whl` with 49 native members, all
`0xAA64` — setuptools' `x86_arm64` vcvars spec (`Hostx86\arm64\cl.exe`) did the compiling, which
confirms the second half of the old parenthesis too: PyAV is the one consumer compiled by `cl.exe`
on both lanes, the documented PyAV-shaped hole in the clang-cl rule.

- **#123 — `llvm-ml` for the MASM-syntax assembly on amd64 (MLAS x64 kernels, IREE's
  `x86_64_msvc.asm`).** S–M · ★ (opened 2026-08-24 evening, owner's request)
  The "clang-cl everywhere" rule holds for compilers and linkers on both lanes and for every
  assembly path on arm64 (clang's integrated assembler: FFmpeg `--as=clang`, XNNPACK/MLAS `.S`,
  IREE inline `asm`). On amd64 two other assemblers are in the build: **nasm** for NASM-syntax
  kernels (FFmpeg since #119 — 154 objects, libjpeg-turbo in OpenCV, openh264 in GStreamer) and
  **MSVC's `ml64.exe`** for MASM-syntax sources — ONNX Runtime's `mlas/lib/amd64/*.asm`
  (`Building ASM_MASM object` in every ORT log; the assembler is CMake's default `ASM_MASM` search,
  `ml64` before `ml`, no `CMAKE_ASM_MASM_COMPILER` is set anywhere in this repo) and IREE's ELF
  trampoline (`add_custom_command COMMAND ml64` upstream). nasm has no LLVM replacement (LLVM
  ships no NASM-syntax assembler; dropping it means dropping the kernels). `ml64` does:
  **`llvm-ml`** is LLVM's MASM-compatible assembler and ships with the pinned LLVM. The work:
  `-DCMAKE_ASM_MASM_COMPILER=<llvm-ml.exe>` in `Invoke-CmakeConfigure` (same shape as the
  `CMAKE_AR=llvm-lib` archiver arg), an assert that the ORT configure reports `llvm-ml` as the
  ASM_MASM compiler, an amd64 ORT build proving MLAS's macro-heavy `.asm` files assemble and link
  under it, and for IREE a small patch of the `ml64` custom command (or leave that one file on
  ml64 and say so). **Unverified until built:** whether MLAS's MASM dialect is fully within
  llvm-ml's compatibility — that is the whole question this item answers. Ordering: after the
  current amd64 regression; it touches the ~50-min ORT stage.

- **#124 — the target CPython cannot start on a clean Windows-on-ARM machine: `vcruntime140.dll`
  is staged into `DLLs\`, not beside `python.exe`.** S · ★★★ (opened 2026-08-25, consumer-side audit)
  `build-target-cpython.ps1:133-138` copies `python*.exe`/`python*.dll` to the root and every
  other DLL — the CRT included — into `DLLs\`. `python314.dll` imports `vcruntime140.dll` through
  the normal loader search (exe dir, System32, PATH); `DLLs\` is a *Python* search path, not a
  loader one. On a box with the ARM64 VC redist it works by accident; on a clean box the
  interpreter dies with 0xC0000135 before any Python runs. python.org's own layout keeps the CRT
  next to the exe. **Fix:** stage `vcruntime140.dll` (+ `msvcp140*.dll` when present) beside
  `python.exe`, keep the copy in `DLLs\` for the `.pyd`s, and extend the stage's self-check; the
  whole-tree import walk of #127 is what would have caught it.
  **DONE 2026-08-25 (arm64 run 14):** `build-target-cpython.ps1` stages the target-arch CRT set —
  `vcruntime140.dll`, `vcruntime140_threads.dll` (added after run 13's import walk), `msvcp140*.dll`,
  `concrt140.dll`, `vccorlib140.dll` — from the build output or the VS ARM64 redist, PE-checked,
  beside `python.exe` **and** into `C:\runtime\bin`; throws if `vcruntime140.dll` cannot be staged.
  Measured: `staged 9 CRT DLL(s)`; the #127 walk resolves every CRT import inside the bundle.

- **#125 — no `sitecustomize` for the TARGET interpreter: every first `import` of cv2/av/ORT on the
  device fails to find its DLLs.** S · ★★★ (opened 2026-08-25)
  `Initialize-PythonPlatformTag` writes the shim into the **host** tree only
  (`WindowsSourceBuild.Common.psm1`, `$CpythonDir\Lib\site-packages` = `C:\temp\cpython`); nothing
  writes one into `C:\runtime\python\Lib\site-packages`. Python ≥ 3.8 ignores `PATH` for
  extension-module dependencies, so `cv2.pyd → opencv_videoio500.dll → avcodec-63.dll` and
  `opencv_gapi → onnxruntime.dll` cannot resolve, and the PyAV wheel (49 `.pyd`, 0 bundled DLLs) is
  built on the same assumption (`build-ffmpeg-from-source.ps1` says its DLLs "resolve via the
  sitecustomize shim"). **Fix:** emit a second shim — DLL directories only, no `get_platform`
  override (the target reports `win-arm64` itself) — into the target site-packages at the
  target-cpython stage (arch-aware paths from the same table), and assert its presence in the
  merge.
  **DONE 2026-08-25 (arm64 run 14):** the shim writer is one function
  (`Write-PythonDllDirectoryShim`, used by `Initialize-PythonPlatformTag` for the host tree);
  `build-target-cpython.ps1` calls it for `C:\runtime\python\Lib\site-packages` with the arch-aware
  DLL homes and no platform/`EXT_SUFFIX` override, after emptying the target site-packages of the
  host tree's pip/setuptools. Measured in-stage: `wrote the DLL-directory sitecustomize shim for
  the target interpreter`.

- **#126 — no runtime deps and no pip for the target: numpy (ORT `import_array`, cv2), packaging,
  flatbuffers, protobuf, sympy, coloredlogs are absent; `C:\runtime\wheels` holds only our three
  wheels.** M · ★★★ (opened 2026-08-25)
  Every pip call in the chain runs the host interpreter; the cross wheel staging (`-CrossStage`) never resolves dependencies;
  no `pip download --platform win_arm64` exists anywhere. **Fix:** a `requirements-winarm64.txt`
  resolved on the host with `pip download --only-binary=:all: --platform win_arm64
  --python-version 3.14 -d C:\runtime\wheels` (pure wheels + the `win_arm64` numpy/protobuf —
  verify each pin publishes one for cp314 before relying on it), a bundle install note (`python
  -m ensurepip` works offline — `Lib\ensurepip\_bundled` ships with the stdlib copy; install ours
  with `--no-deps` so PyPI's `onnxruntime` never shadows the staged one), and a static gate that
  every `Requires-Dist` of the staged wheels resolves inside the wheel store.
  **Implemented 2026-08-25** as `windows/scripts/build/stage-target-python-deps.ps1`, a cross-only
  merge step before the arch gate: it reads `Requires-Dist` from every wheel in `C:\runtime\wheels`
  (extras dropped, numpy added for cv2), downloads with the HOST pip
  (`--only-binary=:all: --platform win_arm64 --python-version 3.14 --abi cp314/none/abi3`) only
  what the bundle does not provide itself, then gates that every wheel is pure or `win_arm64`
  (PE-checked) and that every requirement edge resolves inside the store. **Measured on arm64
  run 12:** the first `pip download` died on `onnxruntime-directml>=v1.29.0` ("from versions:
  none") — onnxruntime-genai's `setup.py.in` derives its ORT requirement from the package name
  (`onnxruntime-genai-directml` → `onnxruntime-directml`, `-cuda` → `onnxruntime-gpu`), but this
  bundle ships its combined CPU+DML(+CUDA) ORT wheel as plain `onnxruntime` (build-onnx passes no
  `--wheel_name_suffix` on purpose). Microsoft publishes no `win_arm64` `onnxruntime-directml`, and
  on amd64 the same edge makes a consumer's `pip install` pull a *second* onnxruntime over ours (the
  2026-07-13 DmlExecutionProvider loss that the build's `-NoDeps` only papers over). **Fix, both
  lanes:** `build-onnx-genai-from-source.ps1` rewrites the configured `build\wheel\setup.py`
  mapping to `dependency = "onnxruntime"` before packing (fail-loud when the pattern is gone), so
  the wheel declares `onnxruntime>=v1.29.0` — the package the store actually holds. numpy 2.5.2
  publishes a `cp314-win_arm64` wheel; flatbuffers, packaging, protobuf resolve as pure wheels.
  **DONE 2026-08-25 (arm64 run 14):** `store holds 7 wheel(s); 0 requirement edge(s) unresolved` —
  the three bundle wheels plus `numpy-2.5.2-cp314-cp314-win_arm64` (PE-checked),
  `flatbuffers-25.12.19`, `packaging-26.3`, `protobuf-7.36.0` (pure); pip itself comes from the
  target stdlib's `ensurepip\_bundled` (asserted in-stage). Install on the device with
  `python -m ensurepip` then `pip install --no-index --find-links C:\runtime\wheels <name>`.

- **#127 — whole-tree static import walk for the arm64 bundle.** M · ★★★ (opened 2026-08-25)
  Today `Get-UnresolvedDeps` runs for the four mandatory GStreamer plugins only; every other
  shipped `.dll/.exe/.pyd` and every wheel member gets a PE-machine check and nothing else. #124 is
  exactly the class that a dependency walk catches. **Fix:** run the same `dumpbin /dependents`
  (or `llvm-readobj --coff-imports`) walk over everything under `C:\runtime` plus extracted wheel
  members, resolving against the bundle and a Windows 11 ARM64 `System32` name list; report
  unresolved imports per file, floor on the file count, fail on any unresolved non-system import.
  **Implemented 2026-08-25** as `verify-target-arch.ps1 -ImportWalk` (merge arch gate, cross lane):
  a dependency-free PE import-table parser (`Get-PeImportNames`, import + delay-load directories,
  PE32/PE32+) walks every inspected PE plus the native members of every wheel and resolves each
  name against the bundle, the loader's `api-ms-`/`ext-ms-` API sets, this container's `System32`
  list (CRT family excluded from it on cross — a clean device has no redist), a driver/toolkit
  allowlist (`-ImportAllowlist`: nvcuda, vulkan-1, opengl32, d3d12core, Qnn*) and a **client-OS
  list** (`-ClientOsPattern`: `dsound`, `mf`/`mfplat`/`mfreadwrite`/`mfcore`, `winspool.drv` —
  DLLs every Windows client SKU ships but the Server Core reference does not). **Measured, arm64
  run 13 — the first walk over 567 files found 13 unresolved imports in three classes, all real:**
  (1) 6× `libcrypto-4-arm64.dll`/`libssl-4-arm64.dll` from `gsthls`/`gstdtls`/`gstaes` and gio's
  openssl TLS module — linked against `C:\opt\openssl-arm64`'s import libs, but the DLLs were never
  installed (amd64 gets scoop's x64 OpenSSL from the image PATH, which a bundle cannot rely on);
  fix: the GStreamer cross branch now stages them, PE-checked, into `C:\runtime\bin`. (2) 6×
  client-OS names (`DSOUND.dll` ← gstdirectsound*, `MF.dll`/`MFPlat`/`MFReadWrite` ←
  gstmediafoundation, `WINSPOOL.DRV` ← tcl9tk90.dll) — present on the device, absent on Server
  Core; classified, reported, not counted. (3) 1× `VCRUNTIME140_THREADS.dll` ← LiteRT's
  `tensorflowlite_c.dll` — the one CRT member missing from #124's staging list; added.
  **DONE 2026-08-25 (arm64 run 14):** `inspected 970, violations 0; import walk: 571 file(s)
  walked, 0 unresolved import(s), 3 allowlisted external(s), 6 device-OS (client SKU) import(s)` —
  the walk is a hard merge gate on the cross lane (`Dockerfile.media-merge-builder`, `-ImportWalk`).
  On the native lane the same walk runs **report-only** (measured amd64 run 4: 203 edges, all image
  facts — 186× `python314.dll` + 8× `python3.dll` because the host interpreter lives in
  `C:\temp\cpython\PCbuild\amd64`, outside the roots, and 6× scoop's `libcrypto/libssl-4-x64.dll`
  from the image PATH); the first native run threw on them and failed the amd64 regression, so the
  throw is now cross-only and the report groups edges by DLL name first.

- **#128 — GStreamer arm64 lacks `webrtc`/`nice` and `gst-ptp-helper`; two lane-identical Meson
  bugs found on the way.** M · ★★ (opened 2026-08-25, from a log diff of the two merge stages)
  Measured (amd64 `bk-…-merge…` vs arm64 run 11): plugin lists identical except **`webrtc` only on
  amd64** (104 vs 105 in gst-plugins-bad), `gstwebrtcnice-1.0-0.dll` + libnice + gst-examples only
  on amd64. Cause: the cross file defines host `[binaries]` only, meson finds no **build-machine**
  C compiler (`Compiler for language c for the build machine not found`, 93×), the build-machine
  glib fallback dies, and libnice's by-name `subprojects/glib` lookup then fails although the host
  glib configured fine (`glib-2.0 for host machine found: YES 2.86.3 (overridden)`).
  `gst-ptp-helper` is Rust and has no `rustc --target=aarch64-pc-windows-msvc` in the cross file.
  **Fix:** a native file with the x64 compilers for the build machine (and the rust target), then
  add `nice`/`webrtc` to the plugin contract or a lane plugin-inventory diff gate. **Both lanes,
  not parity:** `-Dcairo:win32=disabled` and `-Dgst-devtools:dots-viewer=disabled` are *unknown
  options* in these versions and disable cairo, pango and gst-devtools everywhere; amd64 builds
  562 glib **test** targets (`tests: true`) that ship nothing.

- **#129 — OpenCV arm64 ships zero dispatched NEON kernels.** M · ★★ (opened 2026-08-25)
  The arm64 configure log (run of 2026-08-24 20:50) prints `Baseline: NEON` and an **empty**
  `Dispatched code generation:` — `HAVE_CPU_NEON_FP16_SUPPORT / _DOTPROD_ / _BF16_ - Failed`,
  "NEON_FP16 is not supported by C++ compiler": OpenCV's feature probe hands clang-cl GCC-style
  flags it rejects. amd64 gets `SSE4_1 SSE4_2 AVX FP16 AVX2 AVX512_SKX`. Same failure class as the
  MLAS/XNNPACK/IREE per-TU fixes, degrading silently (fp16/dotprod paths fall back to baseline
  NEON + carotene). **Fix:** on cross pass `CPU_DISPATCH=NEON_FP16;NEON_DOTPROD;NEON_BF16` with the
  `/clang:-march=armv8.2-a+…` spellings (OpenCV's `OPENCV_CPU_*` flag overrides or an inline patch
  of `OpenCVCompilerOptimizations.cmake`) and **gate on a non-empty dispatch line**.

- **#130 — bundle contract and small consumer-facing gaps.** S · ★ (opened 2026-08-25)
  (a) No file in the bundle names its own layout: all pointers are Dockerfile ENV of a
  windows/amd64 image, `PATH`'s python is the host x64 one, `C:\runtime\python` appears in no ENV —
  emit `C:\runtime\BUNDLE-ENV.cmd/.ps1` from the same table plus a bundle README. (b) GIO module
  cache absent (`gio-querymodules` skipped under DESTDIR) — document the one-time on-device run.
  (c) `Assert-WheelTargetArch` logs only a member *count* — log the names, so it is known whether
  the GenAI wheel embeds `onnxruntime.dll`. (d) Stale labels/comments: `windows\Dockerfile` LABEL
  and header still call TVM/IREE/LiteRT "empty markers on arm64", the merge Dockerfile says the
  arm64 site-packages "wait on #120", `WindowsGstPlugins.Common.psm1` says LiteRT "cannot be built
  for Windows-on-ARM", `healthcheck.ps1` says the arm64 contract drops tflite.

- **#131 — post-cross-phase cleanup (refactoring).** M · ★★ (opened 2026-08-25, owner's request) ·
  ✅ **DONE 2026-08-25 in four waves, developed in an isolated worktree, 662/662 tests, proof = the
  bundled amd64 + arm64 regression that followed.** What landed: **helpers** `Add-NinjaPerTuFlags`
  (one per-TU tagging pass with floor + idempotency marker, replacing the MLAS/XNNPACK/IREE copies),
  `Assert-PeTargetMachine` / `Assert-DirectoryTargetArch` / `Assert-PythonExtensionTag` (the static
  PE gates, in the dependency-free arch module), `Write-AbsentOnCrossMarker` (one marker convention),
  `Get-PythonCMakeHintArgs` (the FindPython trio per prefix), `Invoke-HostToolCmakeBuild` (host
  target + host LIB + retry ladder — LiteRT's flatc pass gained the LIB swap and a persistent log),
  `Invoke-PythonWheelBuild -CrossStage` (ORT/GenAI/PyAV wheels through one call),
  `Invoke-InlineRegexPatch -SkipIfMatch/-AssertGone` (the six hand-rolled verify pairs),
  `Resolve-QnnSdk` / `Copy-QnnRuntime` (the QNN block, now fixture-tested with a fake SDK zip),
  `Invoke-OnnxDmlClangClPatch` moved into the Patches module (80 lines of embedded C++ out of the
  build script). **Deleted:** the dead `Get-WindowsX86SimdFlags`/`Get-WindowsX86Avx512Flags`, the
  false "no arm64 CPython" warning, the unreachable `$crossBlockedBranches` mechanism, the cpython
  script's private PE reader and the two inline reads in the smoke test, ~120 lines of HISTORY
  comments now pointing at the docs, the stale nvcc-launcher comment. **Structure:** named
  `Gpu/Cpu/Arm64` smoke-floor columns (the calibration test parses the new shape), `$onnxCross`
  resolved once at the top of the ORT script. **Tests added:** `SourceBuild.CrossHelpers`
  (tagging, marker, hints, target python fixture, patch guards, PE asserts), `SourceBuild.NinjaTargets`,
  `SourceBuild.Qnn`, `TargetArch.CrossArgs`, `TargetArch.PeInspection`; `FindPythonPrefix` rewritten
  against the helper; the test runner now prints the assertion message under a red `FAIL` line.
  Original findings, kept for the record: **duplication** — per-TU `build.ninja` FLAGS
  tagging with a floor exists three times (MLAS `build-onnx`, XNNPACK `build-litert`, IREE ukernels
  `build-iree`) → one `Add-NinjaPerTuFlags -NinjaFile -Select -Floor -Label` helper; static PE
  gates over directories/lists exist in tvm, iree, cv2, `Assert-WheelTargetArch`, cpython (a
  private `Get-StagedPeMachine` clone of `Get-PeFileMachine`) and two inline reads in the smoke
  test → `Assert-PeTargetMachine` / `Assert-DirectoryTargetArch` in the dependency-free arch
  module; ABSENT markers written three ways → `Write-AbsentOnCrossMarker`; `Invoke-InlineRegexPatch`
  + hand-rolled "verify gone or throw" pairs (six sites) → `-AssertGone`/`-SkipIfMatch`; the
  Python CMake hint trio composed three ways → `Get-PythonCMakeHintArgs -Prefix`; the cross
  wheel build/stage/assert shape (ORT, GenAI, hand-rolled PyAV) → `Invoke-PythonWheelBuild
  -CrossStage`; the host-tool pass (IREE with the LIB swap, LiteRT's flatc **without** it — safe
  today only because that script never enters VsDevCmd) → `Invoke-HostToolCmakeBuild`.
  **Dead/false:** `Get-WindowsX86SimdFlags`/`Get-WindowsX86Avx512Flags` have no callers (comment
  mentions only); `Get-SourceBuildPython`'s "no arm64 CPython is built on this lane" warning is
  now false and fires twice per green arm64 run (via `Get-TargetBuildPython`);
  `WindowsTargetArch.Common.psm1` claims the inline PE reads were removed — they were not;
  `$crossBlockedBranches = @()` is an unreachable mechanism contradicting the "ship your own marker"
  convention (drop it); the LiteRT-LM Bazel blocker paragraph lives in five places; 36-line
  HISTORY comments in the ORT/GenAI/OpenCV scripts restate `docs/windows-cross-builds.md`.
  **Hot spots:** `build-onnx-from-source.ps1` (811 lines: DML patch fn, QNN block, python args,
  MLAS tagging → move the DML patch into the Patches module and QNN into a `WindowsSourceBuild.Qnn`
  module with a fake-zip test); the IREE cross branch; the TVM cross branch; the positional
  three-column smoke floor table (→ named `Gpu/Cpu/Arm64` keys). **Test gaps:** `Get-PeFileMachine`,
  `Assert-WheelTargetArch`, `Get-TargetBuildPython`, `-Targets`, `Get-QnnSdkLibDirName`, the QNN
  block, the tagging helper, `Get-CMakeCrossArgs`' ASM pair — all cheaply fixture-testable
  (synthetic 0x46-byte PE header, fake `build.ninja`, fake SDK zip, stub ninja). **Order:** wave 0
  deletions → wave 1 helpers + fixture tests (no call-site change) → wave 2 call-site migration
  proven by one bundled amd64 + arm64 regression against today's recorded counts (MLAS 11/25,
  XNNPACK 569 + 335, IREE 5; gates 1134/0 and 950/0; smoke 220/0/0 and 97/0/15) → wave 3
  structural extractions.

- **VERIFY RIDE — MOSTLY CLOSED 2026-08-24 by the amd64 full regression** (media all
  branches + merge + final + smoke: arch gate 1134/0, smoke 220/0/0, `[bk] Done`), **and
  re-confirmed by a second full amd64 regression the same night** (2026-08-25 01:2x, `[bk] Done in
  02:15:51`, arch gate 1134/0, smoke 220/0/0) after the evening's changes — the `Python_*`
  FindPython fix, #119 x86asm, the QNN off-path, the IREE inline patches, the `-Targets` and
  host-arch-LIB module additions. That ride
  covered, on the BuildKit lane, every risk surface the 2026-08-20/21 landings listed:
  ffmpeg/onnx trap-phase tables, litert-lm phases 5a-5e, the chain Invoke-stage shape
  (build-litert-all), Find-TensorRtZipIn newest-by-version (zip-less skip path), the checked-in
  cpython Directory.Build.props COPY, the unified SHELL guard lines, merge sccache ARG parity.
  **Still open, exactly one surface:** the **classic-lane smoke gate** (`build.ps1`, docker-run
  form with the directory mount) — only a classic ride proves it, and none has run since
  2026-08-21. Assert-Elevated at the host sites is exercised by host scripts, not by a ride.
  Follow-ups that were chained to this: re-measure the at-scale sccache hit rate (the 2026-08-24
  runs show warm hits on every rebuild — e.g. TVM's LLVM rebuild in 21 min), and the log
  forensics against the first fully-captured chain (details under Pending).
- **#132 — Windows Update inside the build container poisons a layer.** S · ★★★ (opened and
  **DONE 2026-08-25**, measured on the amd64 regression after #131)
  The `media-core-onnx` stage finished its 150 s RUN and then died in finalize, byte-identical on
  both retries: `failed to reimport snapshot: Files/Windows/SoftwareDistribution/Download/<id>/
  Windows11.0-KB5120233-x64.msu: unknown stream ID 9`. servercore ships `wuauserv` and the Update
  Orchestrator (`UsoSvc`), both trigger-started; the container has network; the client downloaded a
  cumulative update into the spool during the RUN, and BuildKit's Windows layer writer cannot carry
  that file's alternate stream. Retries cannot help — the RUN result is cached, only the finalize
  re-runs. **Fix:** `Disable-ContainerWindowsUpdate` (`WindowsSourceBuild.Common.psm1`) stops and
  disables both services and sets `NoAutoUpdate=1` as the first step of every build script
  (`Initialize-SourceBuildEnvironment`) and reports the spool count — an entry inherited from the
  parent image (1 item at RUN start on every media stage) is harmless, only a file written during
  the RUN lands in the diff. Deliberately prevention only: no script deletes under `C:\Windows`
  (protected-root rule); a poisoned layer is fixed by re-running its RUN with the guard in place
  (the module edit re-keys it). **Proven on the amd64 regression run 4:** the same
  `media-core-onnx` RUN finalized in 5:32 with the guard active at 4.7 s.
- **#31 [owner decision] registry push** — push the verified images to a
  registry instead of local-only tags. Parked until the owner wants it
  (#59 branch protection was DECLINED, #31 was not).

### STANDING DIRECTIVES (survive their archived entries — do not re-litigate)

- **NEVER trim CUDA_ARCHITECTURES** (80;86;89;90 in ALL builds, incl. dev
  iterations; pinned by Pins.CanonicalValues).
- **CUDA compiles stay BARE nvcc** — the sccache launcher-default question is
  CLOSED (miscompile is storage-independent and cold-cache; archive #99/P0b).
- **Do NOT collapse the media-core checkpoints** (#72: export is ~1.2% of the
  chain; resume granularity is worth more than ~60 s).
- **Do not re-propose** branch protection (#59) or a scheduled nightly/weekly
  chain run (#111) — DECLINED by owner 2026-08-17; manual launches are the
  verification cadence.
- **No logging-idiom sweep** (#110): chain scripts use Write-Host, gstreamer
  keeps its structured `log`, Write-BuildLog stays host-driver territory;
  enforcement is review, not a cache-busting mass edit.
- **GES `_commit` retry is DORMANT INSURANCE** (#77): re-open only if its
  retry marker reappears in a gstreamer build.
- **Restore `disk,webdav` only after WCOW cache mounts are PROVEN** (#99
  re-verification recipe in the archive; also listed under Pending).

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
- **hcsshim follow-ups still unfiled** (package README status header,
  re-checked 2026-08-21): the ISSUE.md issue and the
  Windows-Containers#547 comment for microsoft/hcsshim#2855 (the draft
  PR itself IS filed; the package's submission recipe is now marked
  HISTORICAL so nobody files a duplicate).
- **Post the upstream issues** — POSTED 2026-08-13:
  mozilla/sccache → https://github.com/mozilla/sccache/issues/2808 (nvcc
  deadlock + miscompile), google-ai-edge/LiteRT-LM →
  https://github.com/google-ai-edge/LiteRT-LM/issues/3245 (CMake-lane
  staleness, four findings). **POSTED 2026-08-24:** opencv/opencv#29788
  (dnn/ORT `char*` vs `wchar_t`, from out/upstream-issue-opencv-ort-wchar.md) —
  our `004-dnn-ort-profiling-wchar.patch` stays until it lands upstream.
  **NEW DRAFTS (2026-08-24 evening, not posted — owner's call), both found by #116's
  first cross runs:** out/upstream-issue-iree-host-bin-dir-exe.md — `IREE_HOST_BIN_DIR`
  composes host tool paths without `.exe` on a Windows host;
  out/upstream-issue-iree-elf-arch-arm64-msvc.md — `MSVC_C_ARCHITECTURE_ID MATCHES 64`
  matches `ARM64`, archiving the x64 MASM object into an ARM64 library.
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
