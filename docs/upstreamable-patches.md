# Local patches: what to send upstream, and in what shape

Every third-party source change this repo carries, with the judgement call it
needs before it becomes an upstream contribution. Written 2026-09-02, after the
RVA23 switch; **do the RV23 verification first**, then work this list.

The patches themselves live in `linux/scripts/patches/<component>/NNN-name.patch`
and are applied by `linux/scripts/01-core/apply-patch.sh`, which is idempotent
(reverse-apply check first) and fails loudly rather than skipping. One further
change is not a `.patch` file at all — see [Not a patch file](#not-a-patch-file).

## How to read this

Each entry is graded by how much work stands between it and a merge request:

| grade | meaning |
| --- | --- |
| **A** | Genuine upstream defect, our fix is already in the shape upstream wants. File it. |
| **B** | Genuine upstream defect, but our patch is narrowed to our build. Generalize first. |
| **C** | Deliberate local deviation. Do **not** file — it would be wrong for upstream. |
| **✔** | Upstream already fixed it. We carry a backport; the action is a version bump, not a PR. |

"Applies to" is the version this repo pins in `linux/scripts/01-core/versions.env`.
A patch is written against that revision and nothing else — always re-diff against
the branch you intend to target before filing.

## Overview

| # | Patch | Project | Grade | Value |
| --- | --- | --- | --- | --- |
| 1 | [libstdc++ `-nostdinc++` for `src/c++23`](#1-libstdc--nostdinc-for-srcc23) | GCC | **A** | ★★★ |
| 2 | [OpenCV: FFmpeg 8 config API](#2-opencv-ffmpeg-8-removed-avcodecpix_fmts-and-supported_framerates) | OpenCV | **A** | ★★★ |
| 3 | [onnxruntime-genai: riscv64 target](#3-onnxruntime-genai-riscv64-is-not-a-known-target-platform) | onnxruntime-genai | **A** | ★★★ |
| 4 | [libcamera: missing libtiff dependency](#4-libcamera-apps_lib-uses-libtiff-but-does-not-depend-on-it) | libcamera | **A** | ★★ |
| 5 | [GStreamer: lame probe ignores the library](#5-gstreamer-the-lame-probe-checks-the-header-and-ignores-the-library) | gst-plugins-good | **A** | ★★ |
| 6 | [MLAS: `MlasHGemmSupported` undefined in GEMM-only builds](#6-mlas-mlashgemmsupported-is-declared-but-never-defined-in-gemm-only-builds) | OpenCV / onnxruntime | **A/B** | ★★ |
| 7 | [onnxruntime: Android Gradle Plugin 8](#7-onnxruntime-android-gradle-plugin-742-is-too-old-for-current-tooling) | onnxruntime | **B** | ★ |
| 8 | [cargo wrapper clobbers `RUSTFLAGS`](#8-gst-plugins-rs-the-cargo-wrapper-clobbers-rustflags) | gst-plugins-rs | **A/B** | ★★ |
| 9 | [cargo build target is not forwarded](#9-gst-plugins-rs-cargo_build_target-never-reaches-cargo) | gst-plugins-rs | **B** | ★★ |
| 10 | [GStreamer ↔ OpenCV 5 headers](#10-gstreamer-opencv-5-moved-symbols-into-new-headers) | gst-plugins-bad | **B** | ★★ |
| 11 | [GStreamer ↔ OpenCV 5 cascade elements](#11-gstreamer-opencv-5-dropped-the-cascade-classifier-elements) | gst-plugins-bad | **B** | ★★ |
| 12 | [gst-libav ↔ FFmpeg 8 codec IDs](#12-gst-libav-codec-ids-removed-from-ffmpeg-8) | gst-libav | **B** | ★★ |
| 13 | [LiteRT pip build script is not overridable](#13-litert-the-pip-build-script-hardcodes-what-a-cross-build-must-override) | LiteRT | **B** | ★ |
| 14 | [torchvision: staged torch paths](#14-torchvision-setuppy-cannot-be-pointed-at-a-staged-torch) | torchvision | **B/C** | ★ |
| 15 | [cerbero: drop the `m4` build-tool recipe](#15-cerbero-dropping-the-m4-build-tool-dependency) | cerbero | **C** | — |
| 16 | [libyuv: build the RVV rows with GCC](#16-libyuv-the-rvv-rows-are-clang-gated) | libyuv | **✔** | ★★★ |

---

## 1. libstdc++: `-nostdinc++` for `src/c++23`

**Not a `.patch` file** — applied as a `sed` on the pre-generated `Makefile.in` in
`linux/scripts/02-toolchain/build-gcc.sh` (~line 527), guarded by
`verify-critical-fixes.sh` as `fix10` so it cannot be silently dropped.
Applies to: the pinned `GCC_VERSION`.

**A full upstream write-up already exists: `docs/upstream-libstdcxx-c++23-nostdinc++.md`.**
It carries the root cause, the upstream bug numbers (**PR libstdc++/100017**,
**PR libstdc++/101060**), and the form upstream wants (change `src/c++23/Makefile.am`
and regenerate `Makefile.in`, rather than patching the generated file as we do).

**Why this is the highest-value item.** `src/c++17/Makefile.am` already carries
`-nostdinc++` — that *was* the PR100017 fix — and it was simply never propagated
to `src/c++23`, which builds the C++23 `std` / `std.compat` modules. In a Canadian
cross the failure is silent: the module compile fails and libstdc++ ships an
**empty** `std` module. We measured `std.cc` going from 1 byte to 113108 bytes on
native-arm64 and native-riscv64 once the flag was added.

**Before filing:** rebase onto current GCC trunk and confirm `src/c++23/Makefile.am`
still lacks the flag. Send to `gcc-patches@`, referencing both PRs.

---

## 2. OpenCV: FFmpeg 8 removed `AVCodec.pix_fmts` and `supported_framerates`

`linux/scripts/patches/opencv/002-ffmpeg8-avcodec-config-api.patch` ·
applied by `03-media/build/opencv/build-opencv.sh` · applies to **OpenCV 5.0.0**.

Touches `modules/videoio/src/cap_ffmpeg_hw.hpp` and `cap_ffmpeg_impl.hpp`. FFmpeg 8
(`LIBAVCODEC_VERSION_MAJOR >= 62`) removed the `AVCodec::pix_fmts` and
`AVCodec::supported_framerates` array members; the replacement is
`avcodec_get_supported_config()`, which returns the same terminated arrays. The
patch introduces a local pointer, fills it from the new API behind a version
guard, and keeps the old member on older FFmpeg.

**Why it is a good contribution.** It is a pure compatibility fix with a clean
version guard, it does not change behaviour on any FFmpeg that still has the
members, and OpenCV needs it regardless of us — anyone building OpenCV against
FFmpeg 8 hits this.

**Before filing:**
- **Regenerate as a git diff.** This one is a plain `diff -u` with timestamps and
  no `a/`…`b/` prefixes — usable by `patch -p1`, not by a GitHub PR.
- Check whether OpenCV already has a fix in flight on `5.x`/`4.x`; FFmpeg 8 is
  new enough that a competing PR is plausible.
- Upstream will likely want the same treatment applied to every other removed
  member in the same files, not only these two.

---

## 3. onnxruntime-genai: riscv64 is not a known target platform

`linux/scripts/patches/onnxruntime-genai/001-riscv64-target-platform.patch` ·
applied by `03-media/build/onnxruntime/build/60-build-genai.sh` ·
applies to **v0.15.2**.

Two lines in `cmake/target_platform.cmake`: add a
`CMAKE_SYSTEM_PROCESSOR MATCHES "^riscv64.*"` arm that sets
`genai_target_platform` to `riscv64`. Without it the build stops at
`message(FATAL_ERROR "Unsupported architecture")`.

**Why it is a good contribution.** It is the smallest possible change, it follows
the exact shape of the `powerpc` arm directly above it, and it cannot affect any
other architecture. This is the kind of patch that gets merged quickly and unlocks
a whole platform.

**Before filing:** be ready to say what you built and ran on riscv64 — maintainers
will ask whether the platform is actually exercised, not just configured. Our GEN1
lane is the evidence (`docs/gen1-riscv64-genai.md`).

---

## 4. libcamera: `apps_lib` uses libtiff but does not depend on it

`linux/scripts/patches/libcamera/001-riscv64-add-libtiff-dep.patch` ·
applied by `03-media/build/libcamera/build-libcamera.sh` ·
applies to **v0.7.2**.

One line in `src/apps/common/meson.build`: add `libtiff` to the `dependencies` of
the `apps_lib` static library. Upstream compiles `dng_writer.cpp` into `apps_lib`
whenever libtiff is found, but never declares the dependency, so consumers of the
static library fail to link.

**Note the filename is misleading.** It is named `riscv64` because that is the
lane where we first hit it, but the defect is architecture-independent — it is
simply masked wherever the linker happens to pull libtiff in transitively.
**Rename the patch before filing** and describe it as what it is.

**Before filing:** libcamera reviews on their GitLab / mailing list. Confirm the
bug still exists on `master` and phrase it as "static library omits a declared-use
dependency", with the link error as evidence.

---

## 5. GStreamer: the lame probe checks the header and ignores the library

`linux/scripts/patches/gstreamer/002-lame-probe-tighten.patch` ·
applied by `03-media/build/gstreamer/common/patch-gstreamer-sources.sh` ·
applies to **GStreamer 1.29.2**.

`subprojects/gst-plugins-good/ext/lame/meson.build` does:

```meson
lame_dep = cc.find_library('mp3lame', required: false)
have_lame = cc.has_header_symbol('lame/lame.h', 'lame_init')
```

`lame_dep` is looked up and then never consulted. On any system with
`lame/lame.h` present but no linkable `libmp3lame` — a very ordinary cross sysroot
— the plugin is configured and then fails at link. The fix is to require both.

**Why it is a good contribution.** One line, obviously correct, and the same
"probe the header, forget the library" shape is worth grepping for across the
other `ext/` probes while you are in there — a second patch fixing the siblings
would be welcome.

---

## 6. MLAS: `MlasHGemmSupported` is declared but never defined in GEMM-only builds

`linux/scripts/patches/opencv/001-mlas-hgemm-supported-stub.patch` ·
applied by `03-media/build/opencv/build-opencv.sh` and `.../android/build-android.sh` ·
applies to OpenCV **5.0.0**'s vendored `3rdparty/mlas`.

Adds a `MLAS_GEMM_ONLY`-guarded, `__attribute__((weak))` definition of
`MlasHGemmSupported` returning `false`. In SGEMM-only configurations the symbol is
declared and referenced but never defined; the weak attribute keeps it from
colliding where upstream MLAS *does* define it (the Android NDK's lld rejects
duplicates outright).

**Decide where this belongs before filing.** OpenCV vendors MLAS from
onnxruntime. If the same hole exists in onnxruntime's MLAS, that is the real
home and OpenCV inherits the fix. Check onnxruntime first; file there if it
reproduces, and only patch OpenCV's copy if their fork has diverged.

**Grade B caveat:** a weak stub is a workaround shape. Upstream may prefer that
the declaration itself be guarded by `MLAS_GEMM_ONLY`, so nothing references a
function that does not exist. Offer the stub, expect that counter-proposal.

---

## 7. onnxruntime: Android Gradle Plugin 7.4.2 is too old for current tooling

`linux/scripts/patches/onnxruntime/001-android-gradle-agp8-compat.patch` ·
applied by `03-media/build/onnxruntime/android/build-android.sh` ·
applies to **v1.29.0**.

Bumps `com.android.tools.build:gradle` from 7.4.2 to 8.3.1 in two build files and
adds the `buildFeatures { buildConfig = true }` that AGP 8 requires now that
`BuildConfig` generation is opt-in.

**Grade B, because the version number is a policy choice, not a fact.** Upstream
will pick their own AGP version and their own minimum Gradle. File it as "AGP 8
compatibility" and let them choose the number; the `buildConfig` opt-in is the
part that is genuinely required and version-independent.

---

## 8. gst-plugins-rs: the cargo wrapper clobbers `RUSTFLAGS`

Part of `linux/scripts/patches/gstreamer/003-cargo-wrapper-cross-rust-target.patch` ·
applies to **GStreamer 1.29.2**.

`cargo_wrapper.py` does `env['RUSTFLAGS'] = shlex_join(rust_flags)`, discarding
whatever the caller exported. For us that silently dropped the RVV target-features;
for anyone else it silently drops their entire `RUSTFLAGS`. The patch merges
instead of assigning.

**Split this patch before filing.** The merge fix is grade **A** — it is a plain
bug, it is three lines, and it needs no explanation beyond "do not discard the
caller's flags". Send it on its own. The `CARGO_BUILD_TARGET` half of the same
file is item 9 and needs different handling.

---

## 9. gst-plugins-rs: `CARGO_BUILD_TARGET` never reaches cargo

The rest of `003-cargo-wrapper-cross-rust-target.patch` plus
`linux/scripts/patches/gstreamer/004-meson-build-cargo-build-target.patch`.

`meson.build` builds an `extra_env` for cargo but never carries a target triple
into it, and `cargo_wrapper.py` never falls back to `CARGO_BUILD_TARGET`. In a
cross build cargo therefore builds for the *build* machine.

**Grade B — the mechanism is not upstream-shaped.** Two reasons:

- Our patch also honours `CROSS_RUST_TARGET`, which is **this repo's own variable**.
  Strip it; keep only `CARGO_BUILD_TARGET`, which is cargo's documented env var.
- `004` reads the environment through `run_command(python, '-c', 'import os; ...')`.
  That works, but meson will not want a python subprocess to read an env var.
  The upstream-shaped source is the Rust target from the meson cross file / the
  `rust` machine entry, with the env var as a fallback.

Rework along those lines and it becomes a genuinely useful cross-compilation fix,
because today gst-plugins-rs cross builds are quietly wrong rather than broken.

---

## 10. GStreamer: OpenCV 5 moved symbols into new headers

`linux/scripts/patches/gstreamer/005a-opencv5-segmentation-geometry-include.patch`
(adds `<opencv2/geometry.hpp>` to `gstsegmentation.cpp`) and
`005b-opencv5-cameracalibrate-objdetect-include.patch`
(adds `<opencv2/objdetect.hpp>` to `gstcameracalibrate.cpp`) ·
applies to **GStreamer 1.29.2** built against **OpenCV 5.0.0**.

One added include each.

**Grade B for one reason: verify the OpenCV 4 story.** Adding an unconditional
include of a header that does not exist in OpenCV 4 would break every OpenCV 4
build — the opposite of a compatibility fix. Before filing, check whether
`opencv2/geometry.hpp` exists in the 4.x series; if it does not, the patch needs
a `CV_VERSION_MAJOR` guard or a meson-side conditional. **This is unverified here**
— our build only ever sees OpenCV 5.

---

## 11. GStreamer: OpenCV 5 dropped the cascade-classifier elements

`linux/scripts/patches/gstreamer/005c-opencv5-remove-cascade-elements.patch` ·
applies to **GStreamer 1.29.2** with **OpenCV 5.0.0**.

Removes `faceblur`, `facedetect` and `handdetect` from the sources, headers and
`plugin_init` of `ext/opencv`, because OpenCV 5 removed the cascade classifier API
they are built on.

**Do not send this as-is.** Deleting three shipped elements is an API break for
GStreamer's users, and upstream will reject it on that basis alone. The
upstream-shaped change is *conditional*: keep the elements when building against
OpenCV 4, compile them out when the cascade API is absent, and register only what
was built. That is a larger piece of work than the other entries here, and it is
the one most worth doing properly — GStreamer will need it as OpenCV 5 spreads.

Our removal is the correct **local** call (we ship OpenCV 5 only), so this patch
stays regardless of what happens upstream.

---

## 12. gst-libav: codec IDs removed from FFmpeg 8

`linux/scripts/patches/gstreamer/006-libav-removed-codec-fallbacks.patch` ·
applies to **GStreamer 1.29.2** with **FFmpeg n9.0**.

Defines `AV_CODEC_ID_V308`, `AV_CODEC_ID_V408` and `AV_CODEC_ID_V410` to `0` when
absent, in `gstavviddec.c` and `gstavvidenc.c`.

**Do not send this as-is — it is a compile fix, not a correctness fix.** `0` is
`AV_CODEC_ID_NONE`; the mapping tables now contain entries that claim a codec ID
they do not have. It builds, and in practice those table rows are never matched,
but that reasoning is exactly what a reviewer will not accept.

The upstream-shaped change removes the affected table entries under a
`LIBAVCODEC_VERSION_MAJOR` guard rather than defining the identifiers away. Worth
doing: gst-libav has to face FFmpeg 8 eventually.

---

## 13. LiteRT: the pip build script hardcodes what a cross build must override

`linux/scripts/patches/litert/001-env-var-overrides.patch` ·
applied by `03-media/build/litert/build-litert.sh` · applies to **v2.2.0**.

Four kinds of change to `tflite/tools/pip_package/build_pip_package_with_cmake.sh`:

1. `TENSORFLOW_DIR` becomes overridable **and the default path depth changes from
   `../../../..` to `../../..`**.
2. `TENSORFLOW_VERSION` becomes overridable, and its `grep` no longer hard-fails
   when `tf_version.bzl` is absent.
3. `EXTRA_CMAKE_FLAGS` is threaded into every `cmake` invocation.
4. In the `native` case, `-march=native` is replaced with `-idirafter /usr/include`.

**Split it three ways.**

- (1) is the interesting one. From `tflite/tools/pip_package/`, three levels up is
  the repository root and four is its parent — so **upstream's default looks
  wrong**, and if it is, that is a real bug report with a one-character fix.
  **Verify against the actual LiteRT tree before claiming it**; the layout may
  have moved and our number may simply match a different vendoring.
- (2) and (3) are ordinary, well-precedented build-script hygiene: honour an
  existing environment variable instead of overwriting it. Grade **A** in shape,
  easy to justify, worth sending together.
- (4) is **ours** (grade C). Replacing `-march=native` changes upstream's meaning
  of a native build; it exists because our "native" builds are not really native.
  Keep it local.

---

## 14. torchvision: `setup.py` cannot be pointed at a staged torch

`linux/scripts/patches/torchvision/001-torch-staging-paths.patch` ·
applied by `05-frameworks/torch/build-app-wheelhouse.sh` · applies to **v0.28.0**.

Adds a `TORCHVISION_TORCH_STAGING` environment variable that, when set,
monkey-patches `torch.utils.cpp_extension.include_paths` and `library_paths` to
point at a staged torch tree instead of the installed one.

**Grade B/C — the need is real, the mechanism is not upstreamable.** Reassigning
functions on another package's module from inside `setup.py` is not something
torchvision will merge. The legitimate ask underneath it is "let me build against
a torch that is not the importable one", which is a reasonable feature request:
open an issue describing the cross/staged-build case and let them design the
knob. Do not lead with this diff.

---

## 15. cerbero: dropping the `m4` build-tool dependency

`linux/scripts/patches/cerbero/001-drop-m4-dependency.patch` ·
applied by `03-media/build/gstreamer/android/build-android-from-source.sh` ·
applies to the pinned cerbero revision.

Sets `deps = []` instead of `deps = ['m4']` on the `autoconf` and `libtool`
build-tool recipes.

**Grade C — do not upstream.** cerbero builds its own toolchain deliberately, so
that its output does not depend on whatever the host happens to have. We remove
the recipe because our image already provides a suitable `m4` and building it
again is wasted time. That trade is correct for us and wrong for cerbero.

If you want to raise anything upstream here, it is a *feature* request — "allow a
build tool to be satisfied from the system when it meets a version floor" — not
this diff.

---

## 16. libyuv: the RVV rows are clang-gated

`linux/scripts/patches/libyuv/001-rvv-build-with-gcc.patch` ·
applied by `03-media/build/libcamera/build-libcamera.sh` · applies to libyuv
`500f4565`, the revision pinned by **libcamera v0.7.2**'s `subprojects/libyuv.wrap`.

**Upstream has already fixed this — do not open a PR.** Full analysis in
`docs/riscv64-rva23-baseline.md#libyuv-rvv`. In short: `row.h` enables all 57
`HAS_*_RVV` entry points for any RVV compiler, while `row_rvv.cc` and
`scale_rvv.cc` additionally required `defined(__clang__)`, so a GCC build
referenced rows that compiled to nothing. Upstream dropped the clang gate and
rewrote the comment; our patch is that change, backported.

**The action is a version bump, not a contribution.** libcamera pins libyuv by
revision, so the fix only reaches libcamera users when *libcamera* moves its
wrap. That is the request worth making:

```sh
git clone https://chromium.googlesource.com/libyuv/libyuv
git -C libyuv log --oneline 500f4565..HEAD -- source/row_rvv.cc
```

Identify the commit that removed the gate, then ask libcamera to advance
`subprojects/libyuv.wrap` past it. When they do, delete our patch and the
`patch_libyuv_rvv_sources` call — but keep `verify_libyuv_rvv_rows`, which
proves the rows are present no matter where they come from.

---

## Not a patch file

Two upstream-facing items do not live under `patches/`:

- **The libstdc++ fix** — item 1 above, a `sed` in `build-gcc.sh`.
- **sccache `-B` handling** — `mozilla/sccache#1102`, open since 2022. We do not
  patch it; `linux/scripts/02-toolchain/probe-sccache.sh` detects the broken
  shape and avoids it. No contribution is prepared; the issue is simply tracked.

## Regenerating a patch against a newer upstream

From `linux/scripts/patches/generate-patches.sh`: patches are **not** generated
automatically. After a version bump, re-run the component build with
`APPLY_PATCH_TRACE=1` to see which patches still apply, then diff the modified
tree against a fresh upstream clone at the new pinned revision. `apply-patch.sh`
fails loudly when a patch stops applying, and prints that same instruction.
