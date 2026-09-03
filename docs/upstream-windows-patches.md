<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows lane: what to send upstream, and in what shape

The Windows counterpart to
[`upstreamable-patches.md`](upstreamable-patches.md), which covers the Linux
chain. Same grading scale, same rule: a patch is written against one revision
and nothing else, so **re-diff against the branch you intend to target before
filing**.

Written 2026-09-02. Every entry marked *prepared* has a ready-to-send patch and
PR description under [`windows/upstream/`](../windows/upstream/README.md);
**none of them has been posted.**

| grade | meaning |
| --- | --- |
| **A** | Genuine upstream defect, our fix is already in the shape upstream wants. File it. |
| **B** | Genuine upstream defect, but a maintainer has a design call to make first. |
| **C** | Deliberate local deviation. Do **not** file — it would be wrong for upstream. |
| **✔** | Upstream already fixed it. We carry the workaround because our pin predates the fix; the action is a version bump, not a PR. |

Where a local change lives is one of three places, and the distinction matters
when you go to regenerate a patch — see
[`windows/scripts/patches/README.md`](../windows/scripts/patches/README.md) for
why each fix is in the form it is:

- a static `.patch` under `windows/scripts/patches/<component>/`
- an inline guarded edit in a `build-*.ps1` script
- a whole-file asset staged over the upstream one

## Prepared and ready to send (12)

Full descriptions in [`windows/upstream/`](../windows/upstream/README.md).

| # | Upstream | Branch | What | Local form | Grade |
| --- | --- | --- | --- | --- | --- |
| 1 | onnxruntime | `main` | `softmax.cc` uses the alternative token `or` | `onnxruntime/001-softmax-clangcl-keywords.patch` | **A** |
| 2 | onnxruntime | `main` | `tunable.h` vs the `ERROR` macro from `wingdi.h` | `onnxruntime/004-tunable-severity-macro-collision.patch` | **B** |
| 3 | opencv | `5.x` | MLAS forces `<cstring>` with GNU syntax under clang-cl | `opencv/002-mlas-clangcl-force-include.patch` | **A** |
| 4 | opencv | `5.x` | `mlasi.h` remaps NEON intrinsics onto MSVC aliases under clang | inline, `build-opencv-from-source.ps1` | **A** |
| 5 | opencv | **`4.x`** | `FindONNX` builds an IMPORTED target with `ocv_add_library` | part of `opencv/001-cmake-clang-cl-compat.patch` | **A** |
| 6 | opencv | **`4.x`** | NEON dotprod/fp16 probes reject clang-cl | inline, `build-opencv-from-source.ps1` (#129) | **B** |
| 7 | opencv_contrib | `5.x` | cudev uses `ulong`, which Windows does not declare | `opencv_contrib/001-cudev-windows-llp64.patch` | **A** |
| 8 | gstreamer | `main` | `have_sse`/`have_sse2` not gated on `cpu_family` | inline, `build-gstreamer-from-source.ps1` | **A** |
| 9 | gstreamer | `main` | Vulkan lib dir chosen from `build_machine` | inline, `build-gstreamer-from-source.ps1` | **A** |
| 10 | gstreamer | `main` | mediafoundation lacks the `msvc` guard GstWinRt has | inline, `build-gstreamer-from-source.ps1` | **A** |
| 11 | iree | `main` | `MATCHES 64` also matches `ARM64` | inline, `build-iree-from-source.ps1` | **A** |
| 12 | iree | `main` | s8s4s32 i8mm tile defined `inline`, referenced across TUs | inline, `build-iree-from-source.ps1` | **A** |

**Branch is not a detail for OpenCV.** A defect that exists on `4.x` is fixed
there and merged forward; `5.x` is right only when the code does not exist on
`4.x`. Entries 5 and 6 are on `4.x` because both files carry the identical
defect there. Entries 3 and 4 are on `5.x` because `3rdparty/mlas/` is 404 on
`4.x`, and entry 7 because `4.x`'s cudev has no `CV_CUDEV_MAKE_VEC_INST(ulong)`
at all. All checked 2026-09-02. OpenCV's PR template also asks automated agents
to end the title with 🤖🤖🤖 — `opencv_contrib`'s does not.

Entry 7 sends only the `ulong` declaration. Our local patch also adds
`longlong`/`ulonglong` vector traits for LLP64 64-bit elements; that is an
extension, not a fix for something upstream's own code breaks on, so it stays
local and is offered as a follow-up in the PR body.

## Superseded before filing — someone else got there first

Both were prepared, then found to duplicate an open upstream PR. The artefacts
are kept because they date the local patch and say when it can be retired.

| Upstream | Ours | Theirs |
| --- | --- | --- |
| onnxruntime | DML: `##` pasting onto nothing, and `uint32_t` as a `std::array` bound | [#29741](https://github.com/microsoft/onnxruntime/pull/29741) carries **byte-identical** hunks, down to the two spaces realigning the `CASE_PROTO` backslash |
| onnxruntime | DML: `AbstractOperatorDesc` instantiated against an incomplete `OperatorField` | [#29741](https://github.com/microsoft/onnxruntime/pull/29741), same seven special members declared and defined out of line, for the same stated reason |

[#29741](https://github.com/microsoft/onnxruntime/pull/29741) — *"Support
building ONNX runtime with clang on Windows for Windows ML"* — was opened
2026-07-16 from `microsoft:adrastogi/clang-windows` and is still open, last
touched 2026-07-23. It does **not** touch `softmax.cc` or
`core/framework/tunable.h`, so entries 1 and 2 above are unaffected. If it goes
stale, the useful move is a comment confirming an independent reproduction, not
a competing PR. When it merges, drop the matching hunks from
`onnxruntime/003-dml-clangcl-compat.patch`.

## Already filed

| Upstream | Item | Status (checked 2026-09-02) |
| --- | --- | --- |
| llvm/llvm-project | [#219275](https://github.com/llvm/llvm-project/pull/219275) count the async-EH nop after an `EH_LABEL` | PR **open** — `llvm/001-aarch64-ehlabel-size.patch` |
| llvm/llvm-project | [#219276](https://github.com/llvm/llvm-project/pull/219276) report SEH pseudos as zero-size | PR **open** — `llvm/002-aarch64-seh-pseudo-size.patch` |
| llvm/llvm-project | [#219200](https://github.com/llvm/llvm-project/pull/219200) missing `:lo12:` on the catchret address pair | PR **open** |
| microsoft/hcsshim | [#2855](https://github.com/microsoft/hcsshim/pull/2855) configurable teardown timeouts | PR **open** — package in `windows/upstream/hcsshim-teardown-timeout/` |
| google-ai-edge/LiteRT-LM | [#3245](https://github.com/google-ai-edge/LiteRT-LM/issues/3245) the CMake lane is stale vs bazel | issue **open** — covers the ~30 inline LiteRT-LM edits |
| mozilla/sccache | [#2808](https://github.com/mozilla/sccache/issues/2808) nvcc deadlock and miscompile | issue **closed**; fixed by #2722/#2811/#2816, `SCCACHE_GIT_REV` pins past them |
| opencv/opencv | [#29788](https://github.com/opencv/opencv/issues/29788) dnn/ORT `char*` vs `ORTCHAR_T` | issue **closed** — see the next section |

## ✔ Upstream already fixed it — retire on a version bump

| Local change | Upstream fix |
| --- | --- |
| `opencv/004-dnn-ort-profiling-wchar.patch` | Fixed on `5.x` by PR #29309 (`toOrtPath()`), merged 11 days **after** the 5.0.0 tag we pin. The patch is dead the moment `OPENCV_VERSION` moves past it. This is the case that produced [the pre-filing checklist](#before-filing-anything). |
| gst-libav `V308`/`V408`/`V410` codec-ID exclusions | Fixed upstream; see `upstreamable-patches.md` entry 12. Kept inline here because `FFMPEG_VERSION` floats. |

## B — genuine, but not ready to send

| Upstream | What | Why not yet |
| --- | --- | --- |
| opencv | videoio does not build against FFmpeg 8/9 (`AVCodec::pix_fmts` and `supported_framerates` removed) | Upstream fixed this on `4.x` and **not** on `5.x`. The right submission is a port of upstream's own two commits, already staged in [`docs/upstream/patches/`](upstream/patches/); see `upstreamable-patches.md` entry 2. Shared with the Linux lane — one PR covers both. Our Windows form is `opencv/ffmpeg9-avcodec-config.ps1`. |
| opencv | MLAS's vendored kernels are GAS/ELF-only, and clang-cl *is* a working GAS assembler, so `check_language(ASM)` does not spare Windows the way it spares MSVC | `opencv/003-mlas-windows-skip.patch` returns early on `WIN32`. Upstream has to choose: skip MLAS on Windows as the Android path already does, or port the kernels to MASM/COFF. Raised as a reviewer note in submission 5. |
| opencv | CUDA with a clang-cl host compiler is refused outright, and `ocv_cuda_filter_options` leaks clang-cl-only flags into nvcc's `cl.exe` host pass | The rest of `opencv/001-cmake-clang-cl-compat.patch`. This is a feature — "support clang-cl as the CUDA host compiler" — not a bug fix, and wants agreement before code. |
| iree | `add_custom_command` invokes a literal `ml64`, unoverridable and absent from a clang-only toolchain | Needs a decision on which variable should name the assembler (`CMAKE_ASM_MASM_COMPILER`). Raised as a reviewer note in submission 13. |
| iree | `IREE_HOST_BIN_DIR` composes host tool paths without `.exe` | Draft: `out/upstream-issue-iree-host-bin-dir-exe.md`. |
| gstreamer | `ges-validate.c`'s `_commit` collides with the CRT `_commit` under `-FIio.h` | `gstreamer/001-ges-commit-rename.patch`. **Dormant** — there is no collision at 1.29.2 and it is kept as insurance. Filing a fix for something that does not currently reproduce would be noise, and upstream would want a real rename rather than our `#define`. |
| graphene | `meson.build` appends `-Werror=undef` after the caller's `c_args`, so its bare `#if __GNUC__` tests fail under clang-cl | Different project (`ebassi/graphene`), not the GStreamer monorepo. Not written up. |
| moby/buildkit | WCOW cache mounts lose writes into an inherited directory | Draft: `out/upstream-buildkit-wcow-cache-mount-draft.md`. Strengthen first — reproduce with plain file writes, no sccache. |
| meson | `summary()` in a `build`-machine subproject | Draft: `out/upstream-issue-meson-summary-build-subproject.md`, verified against meson 1.12.0. |
| opencv | softfloat/NEON on Windows ARM64 | Draft: `out/upstream-issue-opencv-softfloat-neon.md`. Our fix (typedef to macro) is a hack; upstream would want a rename. |

## C — never file these

They are correct **for this build** and wrong for everyone else.

| Local change | Why it is local-only |
| --- | --- |
| `ffmpeg/001-allow-msys-builds.patch` | Turns FFmpeg's `die "Native MSYS builds are discouraged"` into a notice. Upstream means the `die`. |
| `ffmpeg/makedef` | Whole-file replacement of FFmpeg's `makedef`, not a diff. |
| `onnxruntime/002-disable-cuda-pch.patch` | Comments out `target_precompile_headers` because CUDA 13.x CCCL PCH breaks clang-cl interleaving. A build workaround, not a defect. |
| `onnxruntime/005-xqa-host-stub-sccache.patch` | Emits the XQA host stub unconditionally. Correct only because this build pins `CUDA_ARCHITECTURES` to sm80+; a pre-sm80 build would regress. The patch header says so itself. |
| ORT `onnxruntime.rc` non-ASCII strip, CUTLASS `_udiv128` | A byte-filter and a floating ExternalProject SHA. Neither is expressible as an upstream diff. |
| MSVC STL `yvals_core.h` `_EMIT_STL_ERROR` no-op | Patches an **installed MSVC toolset header**, not any upstream repo. |
| opencv CMP0146/CMP0148 `OLD` to `NEW` | A local policy choice. Upstream has its own migration to make. |
| opencv `softfloat.cpp` typedef to macro | A hack that dodges a NEON `__builtin_bit_cast` collision. The real fix is the B entry above. |
| gstreamer `cpp_std=c++11` to `c++17` sweep | A tree-wide replace across every `meson.build`. Upstream needs per-plugin judgement. |
| LiteRT-LM's ~30 CMake/source edits | They target ExternalProject-fetched trees whose tags float. Reported as issue #3245 instead. |

## Before filing anything

The 2026-08-24 lesson, in three commands. opencv#29788 reported a defect
upstream had fixed **69 days earlier**; it cost a maintainer a triage cycle, and
it is why this section exists.

```sh
# 1. Is the defect still on the branch you are targeting? Not the tag we pin -
#    the DEVELOPMENT branch, and EVERY active release branch. For OpenCV a
#    defect present on 4.x must be fixed on 4.x, not 5.x.
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/<branch>/<path>

# 2. Has somebody already sent it?
gh search prs --repo <org>/<repo> --state open '<symbol>'
gh api "repos/<org>/<repo>/commits?path=<file>&sha=<branch>"
#    GStreamer lives on GitLab and `gh` cannot see it:
curl -fsSL "https://gitlab.freedesktop.org/api/v4/projects/gstreamer%2Fgstreamer/merge_requests?state=opened&search=<term>"

# 3. Does the patch still apply?
git apply --check -p1 --ignore-whitespace <the .patch>
```

**Step 2 is not optional, and a file-name search is not enough.** Two of the
fourteen submissions prepared on 2026-09-02 turned out to duplicate
onnxruntime#29741 — an open PR from a Microsoft contributor whose hunks are
byte-identical to ours. It was found by searching for a *symbol*
(`AbstractOperatorDesc`), not for the file path. Search for the identifier the
fix touches.

If it turns out to be fixed already, the finding is *"our pin predates the
fix"* — a row in the ✔ table above and a version bump, not an issue.

`windows/scripts/tests/Test-PatchesApplyClean.ps1` runs step 3 for the whole
static-patch catalogue without a container rebuild.
