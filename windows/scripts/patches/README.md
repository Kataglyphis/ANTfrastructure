<!-- Reviewer-facing catalogue of the Windows source-build patches. Keep in sync with the
     windows/scripts/build/Build-*.ps1 scripts and windows/scripts/modules/WindowsSourceBuild.Common.psm1. -->

# Windows source-build patches

The Windows container builds ONNX Runtime, ONNX-GenAI, OpenCV, FFmpeg, LiteRT, LiteRT-LM, TVM,
IREE, HailoRT, GStreamer and its own patched clang/LLVM (plus MIGraphX on the rocm lane)
**from source with clang-cl / lld-link**. clang-cl is stricter than MSVC in a number of
spots these upstreams rely on MSVC leniency for, so each source tree needs a few edits before it
compiles. Those edits live in two forms:

1. **Static `.patch` files** in this directory — applied by `Invoke-SourcePatch` (git-apply with a
   `patch.exe` fallback, `--ignore-whitespace`). Used where the target file + hunk are **stable across
   the pinned upstream version** and the change is expressible as a unified diff. These are the
   reviewable, upstreamable artifacts.
2. **Inline patches** in the `Build-*.ps1` scripts / `WindowsSourceBuild.Common.psm1` — applied by
   `Invoke-InlineRegexPatch` (regex, guarded), `Edit-SourceFile` (arbitrary scriptblock transform),
   or `Add-FileBlockOnce` (idempotent graft). Used where a static `.patch` would **silently rot** (it
   targets a floating dep SHA / ExternalProject-fetched tree / installed toolset header), where the
   edit is **not a textual diff** (a binary byte-filter or a whole-file replacement), or where a
   **per-file conditional** is needed. Every inline patch is guarded and **warns-not-throws** on an
   anchor miss, so an upstream fix or version bump degrades to a NOTE rather than a hard failure.

**Sending one of these upstream?** The graded register of every Windows-lane
third-party change — what to file, what must stay local, and what upstream has
already fixed — is [`docs/upstream-windows-patches.md`](../../../docs/upstream-windows-patches.md).
Twelve ready-to-send patches and their PR descriptions, plus two superseded ones,
are under [`windows/upstream/`](../../upstream/README.md). Do not post any of them
without the owner saying so.

Where a `.patch` could drift, the build applies it **first** and falls back to the drift-tolerant
inline form in a `try/catch` (see `002-disable-cuda-pch` and `003-dml-clangcl-compat` in
`Build-OnnxFromSource.ps1`) — best of both: a clean diff for review, a robust net for CI.

## Static `.patch` files

All paths are `-p1`, applied to the root of the named upstream checkout. Pinned versions come from
`linux/scripts/01-core/versions.env` (the single source of truth).

| Patch | Upstream @ pinned ref | What it does | git headers |
|-------|-----------------------|--------------|-------------|
| `onnxruntime/001-softmax-clangcl-keywords.patch` | microsoft/onnxruntime **`ONNXRUNTIME_VERSION`** | `softmax.cc`: the one real ISO-646 keyword operator `or` → `\|\|` on the dispatch `if` (clang-cl in MS-compat mode treats `or` as an identifier without `<iso646.h>`). Comments left untouched. | ✅ `index` |
| `onnxruntime/002-disable-cuda-pch.patch` | microsoft/onnxruntime **`ONNXRUNTIME_VERSION`** | `onnxruntime_providers_cuda.cmake`: comment out `target_precompile_headers(...)` — CUDA 13.x CCCL PCH breaks clang-cl interleaving. | ✅ `index` |
| `onnxruntime/003-dml-clangcl-compat.patch` | microsoft/onnxruntime **`ONNXRUNTIME_VERSION`** | DirectML EP (5 files) under clang-cl + `USE_DML=ON`: (#1) out-of-line `AbstractOperatorDesc` special members / `GetTensors<>()` / 4 tensor accessors past `OperatorField`'s definition to break a mutual-recursion incomplete-type (llvm #57700); (#2) drop the spurious `.##Z` token-paste in `MLOperatorAuthorImpl.cpp`'s `CASE_PROTO`; (#3) widen `Dispatch<uint32_t TSize>` → `size_t` in `DmlDFT.h`/`DmlGridSample.h`. | ✅ `index` |
| `onnxruntime/004-tunable-severity-macro-collision.patch` | microsoft/onnxruntime **`ONNXRUNTIME_VERSION`** | `tunable.h`: `#undef ERROR` / `#undef VERBOSE` after the includes, so `wingdi.h`'s `ERROR` no longer expands inside `LOGS_DEFAULT` (CUDA EP). | ✅ `index` |
| `onnxruntime/005-xqa-host-stub-sccache.patch` | microsoft/onnxruntime **`ONNXRUNTIME_VERSION`** | `xqa_impl_gen.cuh`: emit the XQA host stub unconditionally, because sccache's nvcc decomposition can drop the `HAS_SM80_OR_LATER` define in the host pass. Correct only for an sm80+ `CUDA_ARCHITECTURES`. | ✅ `index` |
| `opencv/001-cmake-clang-cl-compat.patch` | opencv/opencv **`OPENCV_VERSION`** | root `CMakeLists.txt` (CMP0146/CMP0148 OLD→NEW) + `cmake/FindONNX.cmake` + `cmake/OpenCVDetectCUDA{Language,Utils}.cmake` for clang-cl/CUDA compat. | ✅ `index` |
| `opencv/002-mlas-clangcl-force-include.patch` | opencv/opencv **`OPENCV_VERSION`** | `3rdparty/mlas/CMakeLists.txt`: an MSVC-frontend branch that force-includes `<cstring>` as `/FIcstring` instead of the GNU `-include cstring` pair. | ✅ `index` |
| `opencv/003-mlas-windows-skip.patch` | opencv/opencv **`OPENCV_VERSION`** | `3rdparty/mlas/CMakeLists.txt`: skip the GAS-only MLAS on `WIN32`. The reviewable form only: the build inserts the same guard inline, because `002` already edits that file. | ✅ `index` |
| `opencv/004-dnn-ort-profiling-wchar.patch` | opencv/opencv **`OPENCV_VERSION`** | `net_impl_backend.cpp`: widen the ORT profiling path to `ORTCHAR_T` on Windows. Fixed upstream on `5.x` after the pinned tag. | ✅ `index` |
| `opencv_contrib/001-cudev-windows-llp64.patch` | opencv/opencv_contrib **`OPENCV_VERSION`** | `cudev/.../common.hpp` + `util/vec_traits.hpp`: add `ulong`/`longlong`/`ulonglong` typedefs for Windows LLP64. | ✅ `index` |
| `opencv_contrib/002-arm64-cudafilters-popcount.patch` | opencv/opencv_contrib **`OPENCV_VERSION`** | `wavelet_matrix_2d.cuh`: a software popcount under `_M_ARM64`, where the x86 `_mm_popcnt_u64` does not exist (#176). | ✅ `index` |
| `opencv_contrib/003-gapi-fluid-clangcl-setr-epi64x.patch` | opencv/opencv_contrib **`OPENCV_VERSION`** | `gfluidcore_simd_sse41.hpp`: the five `_mm_setr_epi64x` branches only for real MSVC (`!defined(__clang__)`). clang-cl defines `_MSC_VER` but has no such intrinsic, and it takes the portable `_mm_setr_epi64` branch instead. It first broke the default `:winamd64` build (`CPU_BASELINE=AVX2`) on 2026-09-30. | ✅ `index` |
| `llvm/001-aarch64-ehlabel-size.patch`, `llvm/002-aarch64-seh-pseudo-size.patch` | llvm/llvm-project **`llvmorg-<LLVM_WINDOWS_VERSION>`** | `AArch64InstrInfo.cpp`: the instruction-size fixes of the patched toolchain (llvm#219275, llvm#219276). Applied by `Build-LlvmFromSource.ps1`. | ✅ `index` |
| `hailo/001` … `hailo/004` | hailo-ai/hailort **`v<HAILORT_VERSION>`** | The HailoRT clang-cl and ARM64 fixes: the `_MSC_VER` guard on x86 rounding intrinsics, `template<>` on two `nullptr_t` specialisations, the missing `LockedFile` destructor, and `_ARM64_` for an ARM64 target. Applied by `Build-HailortFromSource.ps1`, each with an inline fallback. | ✅ `index` |
| `ffmpeg/001-allow-msys-builds.patch` | FFmpeg/FFmpeg **`FFMPEG_VERSION`** | `configure`: turn the `msys*` "native builds discouraged" `die` into an informational echo. | ✅ `index` |
| `gstreamer/001-ges-commit-rename.patch` | gstreamer/gstreamer **`GSTREAMER_VERSION`** | `ges-validate.c`: `#define _commit ges__commit` before clang-cl's `-FIio.h` force-include exposes a colliding CRT `_commit`. | ✅ `index` |

`cpython/001-short-clang-compiler-id.patch` was dropped with CPython 3.14.8, whose `PC/pyconfig.h`
names clang by `major.minor.patch` itself (`_Py_CLANG_COMPILER`); `Build-ToolchainAll.ps1` still refuses
a `sys.version` without `AMD64`.

`ffmpeg/makedef` is **not** a patch — it is a replacement `makedef` script staged over FFmpeg's (a
whole-file swap, not a diff).

## Deliberately kept inline (NOT `.patch` files) — and why

These are documented here so a reviewer knows the omission is intentional, not an oversight:

| Fix | Where | Why not a `.patch` |
|-----|-------|--------------------|
| `onnxruntime.rc` non-ASCII strip | `Build-OnnxFromSource.ps1` | Binary byte-filter (`byte -le 127`) — **not a textual diff**. |
| CUTLASS `_udiv128` | `Build-OnnxFromSource.ps1` | Targets onnxruntime's `cutlass-src` **ExternalProject SHA** — a fixed diff would rot. |
| mlas `<cstring>` include | `Build-OpencvFromSource.ps1` | **Per-file conditional** loop over every `3rdparty/mlas/*.cpp` (add only if absent) — a static diff can't express the guard. |
| GenAI `RESTORE_PACKAGES` drop | `Build-OnnxGenaiFromSource.ps1` | Small guarded regex on genai's `CMakeLists.txt`; kept as drift-tolerant `Invoke-InlineRegexPatch`. |
| MSVC STL `yvals_core.h` `_EMIT_STL_ERROR` no-op | `Build-OnnxGenaiFromSource.ps1` | Patches an **installed MSVC toolset header**, not an upstream repo — version-specific, floats with the toolchain. Wrapping the one `_EMIT_STL_ERROR` define in `#ifdef __clang__` no-ops **every** STL error code (STL1009/1010/1011) under clang-cl, so no per-header (e.g. `<experimental/coroutine>`) patch is needed. Guarded by a loud drift-assertion that fails fast if a future toolset changes the macro's format. |
| ~30 LiteRT-LM CMake/source edits | `Build-LitertLmFromSource.ps1` | Target **ExternalProject-fetched trees** (protobuf / sentencepiece / tflite / re2 / tokenizers) and LiteRT-LM's own `*_patcher.cmake` hooks; the tags float and the anchors move between releases. Applied via `Edit-SourceFile` / `Invoke-InlineRegexPatch` / `Add-FileBlockOnce`, each guarded + warn-on-miss. |

To regenerate a `.patch` against its pinned tag: shallow-clone the upstream at the version above
with `core.autocrlf=false`, apply the edit, and write the patch with `git diff`. Do not hand-edit
the result. A placeholder `index 0000000..0000000` line makes GNU patch treat the target as a new
file ("which already exists!"), and a hunk with less trailing than leading context is anchored at
end of file. `git apply` forgives both, which is how the four HailoRT patches stayed dead until
2026-10-08. Tarball sources are not git repos, so `Invoke-SourcePatch` applies their patches with
GNU patch (Git for Windows' `usr\bin\patch.exe` in the image).

## Verifying the patches still apply (before a version bump)

`windows/scripts/tests/Test-PatchesApplyClean.ps1` automates the whole-catalogue check: for every
`.patch` above it parses the `+++ b/<path>` headers, blobless-sparse-clones the pinned upstream, and
runs the exact `git apply --check -p1 --ignore-whitespace` the build uses on a git source, then GNU
patch's `--dry-run` it uses on a tarball — no container rebuild. It takes Git for Windows' GNU patch,
not the first `patch.exe` on `PATH`: Strawberry Perl's patch 2.5.9, first on the dev host's
`PATH`, asserts on every patch (`Assertation failed!`). Run
it after bumping a version in `versions.env`; any `FAIL` means that patch must be regenerated against
the new tree.

```pwsh
pwsh -File windows/scripts/tests/Test-PatchesApplyClean.ps1
# override a pin without editing the script:
pwsh -File windows/scripts/tests/Test-PatchesApplyClean.ps1 -Versions @{ ONNXRUNTIME = 'v1.28.0' }
```

The script reads the pinned refs from `versions.env`; its `$defaultRefs` are only the fallback
when that file is absent. A new patch directory needs a `$repoMap` entry, or the check reports
FAIL for it. CI runs the same check as the `patch-drift` job of
`.github/workflows/windows-x64.yml`, on every change under `windows/` or to `versions.env`.
