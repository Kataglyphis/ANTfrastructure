<!-- Reviewer-facing catalogue of the Windows source-build patches. Keep in sync with the
     build-*.ps1 scripts and windows/scripts/modules/WindowsSourceBuild.Common.psm1. -->

# Windows source-build patches

The Windows container builds ONNX Runtime, ONNX-GenAI, OpenCV, FFmpeg, LiteRT, LiteRT-LM, TVM and
GStreamer **from source with clang-cl / lld-link**. clang-cl is stricter than MSVC in a number of
spots these upstreams rely on MSVC leniency for, so each source tree needs a few edits before it
compiles. Those edits live in two forms:

1. **Static `.patch` files** in this directory — applied by `Invoke-SourcePatch` (git-apply with a
   `patch.exe` fallback, `--ignore-whitespace`). Used where the target file + hunk are **stable across
   the pinned upstream version** and the change is expressible as a unified diff. These are the
   reviewable, upstreamable artifacts.
2. **Inline patches** in the `build-*.ps1` scripts / `WindowsSourceBuild.Common.psm1` — applied by
   `Invoke-InlineRegexPatch` (regex, guarded), `Edit-SourceFile` (arbitrary scriptblock transform),
   or `Add-FileBlockOnce` (idempotent graft). Used where a static `.patch` would **silently rot** (it
   targets a floating dep SHA / ExternalProject-fetched tree / installed toolset header), where the
   edit is **not a textual diff** (a binary byte-filter or a whole-file replacement), or where a
   **per-file conditional** is needed. Every inline patch is guarded and **warns-not-throws** on an
   anchor miss, so an upstream fix or version bump degrades to a NOTE rather than a hard failure.

**Sending one of these upstream?** The graded register of every Windows-lane
third-party change — what to file, what must stay local, and what upstream has
already fixed — is [`docs/upstream-windows-patches.md`](../../../docs/upstream-windows-patches.md).
Fourteen ready-to-send patches and their PR descriptions are under
[`windows/upstream/`](../../upstream/README.md). Do not post any of them without
the owner saying so.

Where a `.patch` could drift, the build applies it **first** and falls back to the drift-tolerant
inline form in a `try/catch` (see `002-disable-cuda-pch` and `003-dml-clangcl-compat` in
`Build-OnnxFromSource.ps1`) — best of both: a clean diff for review, a robust net for CI.

## Static `.patch` files

All paths are `-p1`, applied to the root of the named upstream checkout. Pinned versions come from
`linux/scripts/01-core/versions.env` (the single source of truth).

| Patch | Upstream @ pinned tag | What it does | git headers |
|-------|-----------------------|--------------|-------------|
| `onnxruntime/001-softmax-clangcl-keywords.patch` | microsoft/onnxruntime **v1.27.0** | `softmax.cc`: the one real ISO-646 keyword operator `or` → `\|\|` on the dispatch `if` (clang-cl in MS-compat mode treats `or` as an identifier without `<iso646.h>`). Comments left untouched. | ✅ `index` |
| `onnxruntime/002-disable-cuda-pch.patch` | microsoft/onnxruntime **v1.27.0** | `onnxruntime_providers_cuda.cmake`: comment out `target_precompile_headers(...)` — CUDA 13.x CCCL PCH breaks clang-cl interleaving. | ✅ `index` |
| `onnxruntime/003-dml-clangcl-compat.patch` | microsoft/onnxruntime **v1.27.0** | DirectML EP (5 files) under clang-cl + `USE_DML=ON`: (#1) out-of-line `AbstractOperatorDesc` special members / `GetTensors<>()` / 4 tensor accessors past `OperatorField`'s definition to break a mutual-recursion incomplete-type (llvm #57700); (#2) drop the spurious `.##Z` token-paste in `MLOperatorAuthorImpl.cpp`'s `CASE_PROTO`; (#3) widen `Dispatch<uint32_t TSize>` → `size_t` in `DmlDFT.h`/`DmlGridSample.h`. | ✅ `index` |
| `opencv/001-cmake-clang-cl-compat.patch` | opencv/opencv **5.x** | root `CMakeLists.txt` (CMP0146/CMP0148 OLD→NEW) + `cmake/FindONNX.cmake` for clang-cl/CUDA compat. | ✅ `index` |
| `opencv_contrib/001-cudev-windows-llp64.patch` | opencv/opencv_contrib **5.x** | `cudev/.../common.hpp`: add `ulong`/`longlong`/`ulonglong` typedefs for Windows LLP64. | ✅ `index` |
| `ffmpeg/001-allow-msys-builds.patch` | FFmpeg/FFmpeg **master** | `configure`: turn the `msys*` "native builds discouraged" `die` into an informational echo. | ✅ `index` |
| `gstreamer/001-ges-commit-rename.patch` | gstreamer/gstreamer **1.29.2** | `ges-validate.c`: `#define _commit ges__commit` before clang-cl's `-FIio.h` force-include exposes a colliding CRT `_commit`. | ✅ `index` |

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

To regenerate a `.patch` against its pinned tag: shallow-clone the upstream at the version above,
apply the edit, `git diff`, and verify with `git apply --check -p1 --ignore-whitespace`.

## Verifying the patches still apply (before a version bump)

`windows/scripts/tests/Test-PatchesApplyClean.ps1` automates the whole-catalogue check: for every
`.patch` above it parses the `+++ b/<path>` headers, blobless-sparse-clones the pinned upstream, and
runs the exact `git apply --check -p1 --ignore-whitespace` the build uses — no container rebuild. Run
it after bumping a version in `versions.env`; any `FAIL` means that patch must be regenerated against
the new tree.

```pwsh
pwsh -File windows/scripts/tests/Test-PatchesApplyClean.ps1
# override a pin without editing the script:
pwsh -File windows/scripts/tests/Test-PatchesApplyClean.ps1 -Versions @{ ONNXRUNTIME = 'v1.28.0' }
```

Keep the pinned refs in that script's `$defaultRefs`/`$repoMap` in sync with `versions.env`.
