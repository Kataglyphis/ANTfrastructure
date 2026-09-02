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
| 2 | [OpenCV: port the FFmpeg 8 fixes to 5.x](#2-opencv-ffmpeg-8-removed-avcodecpix_fmts-and-supported_framerates) | OpenCV | **A** (port, not a new fix) | ★★★ |
| 3 | [onnxruntime-genai: riscv64 target](#3-onnxruntime-genai-riscv64-is-not-a-known-target-platform) | onnxruntime-genai | **A** | ★★★ |
| 4 | [libcamera: missing libtiff dependency](#4-libcamera-apps_lib-uses-libtiff-but-does-not-depend-on-it) | libcamera | **A** | ★★ |
| 5 | [GStreamer: lame probe ignores the library](#5-gstreamer-the-lame-probe-checks-the-header-and-ignores-the-library) | gst-plugins-good | **A** | ★★ |
| 17 | [cerbero: glib misses its libiconv dep](#17-cerbero-glib-does-not-declare-its-libiconv-dependency-on-android) | cerbero | **A** | ★★ |
| 10 | [~~OpenCV 5 header moves~~](#10-gstreamer-opencv-5-moved-symbols-into-new-headers--already-fixed-upstream) | gst-plugins-bad | **✔** | ★★ |
| 20 | [OpenCV: `<complex.h>` leaves `complex` defined](#20-opencv-hal_internalcpp-trusts-the-include-path-for-complexh) | OpenCV | **A** | ★★ |
| 6 | [MLAS: `MlasHGemmSupported` undefined](#6-mlas-mlashgemmsupported-is-declared-but-never-defined-in-gemm-only-builds) | OpenCV (their MLAS trim) | **B** | ★★ |
| 7 | [onnxruntime: Android Gradle Plugin 8](#7-onnxruntime-android-gradle-plugin-742-is-too-old-for-current-tooling) | onnxruntime | **B** | ★ |
| 9 | [~~cargo build target is not forwarded~~](#9-gst-plugins-rs-cargo_build_target-never-reaches-cargo--withdrawn) | gst-plugins-rs | **withdrawn** | — |
| 8 | [~~cargo wrapper clobbers `RUSTFLAGS`~~](#8-gst-plugins-rs-the-cargo-wrapper-clobbers-rustflags--withdrawn) | gst-plugins-rs | **withdrawn** | — |
| 11 | [OpenCV 5 cascade elements](#11-gstreamer-opencv-5-dropped-the-cascade-classifier-elements) | gst-plugins-bad | **B** | ★★ |
| 12 | [~~gst-libav ↔ FFmpeg 8 codec IDs~~](#12-gst-libav-codec-ids-removed-from-ffmpeg-8--already-fixed-upstream) | gst-libav | **✔** | ★★ |
| 13 | [LiteRT pip script assumes in-tree TF](#13-litert-the-pip-build-script-hardcodes-what-a-cross-build-must-override) | LiteRT | **B** (issue) | ★★ |
| 18 | [cerbero: stale soundtouch checksum](#18-cerbero-the-soundtouch-tarball-checksum-is-stale) | cerbero | **A** (issue) | ★ |
| 19 | [cerbero: dead pkg-config fallback mirror](#19-cerbero-the-pkg-config-fallback-mirror-is-gone) | cerbero | **B** (issue) | ★ |
| 14 | [torchvision: staged torch paths](#14-torchvision-setuppy-cannot-be-pointed-at-a-staged-torch) | torchvision | **B/C** | ★ |
| 15 | [cerbero: drop the `m4` recipe](#15-cerbero-dropping-the-m4-build-tool-dependency) | cerbero | **C** | — |
| 16 | [libyuv: RVV rows are clang-gated](#16-libyuv-the-rvv-rows-are-clang-gated) | libyuv | **✔** | ★★★ |

Sorted by how ready each one is, not by number. Seven are ready to write today;
the rest need the rework named in their entry.

**Eight entries carry a ready-to-send message; the others deliberately do not.**
9, 11, 12 and 14 need the patch itself reshaped before any message would be
honest — writing the text now would only make a diff look sendable that is not.
15 is grade C and 16 is already fixed upstream, so neither gets one.

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

**PR message**

```
libstdc++: add -nostdinc++ to src/c++23 (PR100017 parity with src/c++17)

In a Canadian cross (build != host == target) the host g++'s libstdc++ headers
are on the include path. <cfenv> reaches the target <fenv.h> wrapper, whose
#include_next then finds the *host* wrapper; both share the _GLIBCXX_FENV_H
guard, so the host wrapper is skipped and libc's <fenv.h> is never included.
fenv_t and every fe* are undeclared and the C++23 std module fails to compile.

src/c++17/Makefile.am already carries -nostdinc++ for exactly this reason
(PR100017). src/c++23 never got it. The failure is silent: the recipe ships an
empty std module instead of erroring out.

With the flag the generated std module goes from 1 byte to 113108 for both an
aarch64 and a riscv64 Canadian cross.
```

**Before filing:** rebase onto current GCC trunk and confirm `src/c++23/Makefile.am`
still lacks the flag. Change `Makefile.am` and regenerate `Makefile.in` — do not
send our `sed`-on-the-generated-file form. Send to `gcc-patches@`, referencing
both PRs.

---

## 2. OpenCV: FFmpeg 8 removed `AVCodec.pix_fmts` and `supported_framerates`

`linux/scripts/patches/opencv/002-ffmpeg8-avcodec-config-api.patch` ·
applied by `03-media/build/opencv/build-opencv.sh` · applies to **OpenCV 5.0.0**.

FFmpeg 8 removed the `AVCodec::pix_fmts` and `AVCodec::supported_framerates`
array members; the replacement is `avcodec_get_supported_config()`. Our patch
adds version-guarded code paths in `cap_ffmpeg_hw.hpp` and `cap_ffmpeg_impl.hpp`.

**Verified 2026-09-02: upstream already fixed this on `4.x`, and `5.x` did not
get it.** `avcodec_get_supported_config` appears once in 4.x's
`cap_ffmpeg_impl.hpp` and zero times in 5.x's. The two upstream commits are:

| commit | date | file |
| --- | --- | --- |
| `700cd32ffd` | 2026-07-16 | `cap_ffmpeg_hw.hpp` — *videoio: support FFmpeg after AVCodec::pix_fmts removal* |
| `83ed22ca28` | 2026-08-04 | `cap_ffmpeg_impl.hpp` — *videoio(ffmpeg): use avcodec_get_supported_config for framerates on FFmpeg 9* |

**So do not send our diff — port theirs.** Ours reimplements the same fix in two
worse ways, and a reviewer will say so:

- We guard on `LIBAVCODEC_VERSION_MAJOR >= 62`; OpenCV's house idiom is
  `LIBAVCODEC_BUILD >= CALC_FFMPEG_VERSION(61, 13, 100)`.
- We iterate to the `{0,0}` terminator. Upstream uses the **count** the new API
  returns (`ret >= 0 && supported_framerates && num_supported_framerates > 0`),
  which is the documented contract — the returned array is not guaranteed to be
  terminated.

**PR message**

```
videoio: port the FFmpeg 8 config-API fixes to 5.x

5.x still reads AVCodec::pix_fmts and AVCodec::supported_framerates, which
FFmpeg 8 removed, so videoio does not compile against it. 4.x already handles
both in 700cd32ffd and 83ed22ca28; this ports them unchanged.

Built against FFmpeg n9.0.
```

**Before filing:** cherry-pick the two commits onto 5.x rather than hand-porting,
resolve whatever conflicts the 5.x videoio refactor causes, and check the file
for any *other* removed member the two commits did not cover. Then replace our
patch with the cherry-picked form so we stop carrying a divergent fix.

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

**PR message**

```
Add riscv64 to target_platform.cmake

CMAKE_SYSTEM_PROCESSOR is riscv64 on a riscv64 build and no branch matches it,
so configure stops at "Unsupported architecture". This adds the arm in the same
shape as the powerpc one above it.

Built and smoke-tested on riscv64.
```

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

**PR message**

```
apps: add libtiff to apps_lib dependencies

apps_lib compiles dng_writer.cpp whenever libtiff is found, but does not list
libtiff in its dependencies. Linking against the static library then fails on
the TIFF* symbols. It only builds where the linker happens to pull libtiff in
for some other reason.
```

**Before filing:** libcamera reviews on their GitLab / mailing list. Confirm the
bug still exists on `master`. Rename our patch file first — it is called
`001-riscv64-add-libtiff-dep.patch` and the defect has nothing to do with riscv64.

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

**PR message**

```
lame: require the library, not just the header

have_lame is set from cc.has_header_symbol() alone; lame_dep is looked up and
then never consulted. On a sysroot that carries lame/lame.h but no linkable
libmp3lame the plugin is configured and fails at link.
```

---

## 6. MLAS: `MlasHGemmSupported` is declared but never defined in GEMM-only builds

`linux/scripts/patches/opencv/001-mlas-hgemm-supported-stub.patch` ·
applied by `03-media/build/opencv/build-opencv.sh` and `.../android/build-android.sh` ·
applies to OpenCV **5.0.0**'s vendored `3rdparty/mlas`.

Adds a `MLAS_GEMM_ONLY`-guarded, `__attribute__((weak))` definition of
`MlasHGemmSupported` returning `false`. The symbol is declared and referenced but
never defined; the weak attribute keeps it from colliding where MLAS *does*
define it (the Android NDK's lld rejects duplicates outright).

**Verified 2026-09-02: this belongs to OpenCV, not onnxruntime.** `MLAS_GEMM_ONLY`
is OpenCV's own define — `3rdparty/mlas/CMakeLists.txt` sets `MLAS_GEMM_ONLY=1`
(line ~246) and its header comment says parts of the vendored source are `#if 0`'d
out, pointing at that same name. It is a vendoring artifact of OpenCV's trim, so
there is nothing to report upstream of them.

**PR message**

```
mlas: define MlasHGemmSupported in MLAS_GEMM_ONLY builds

3rdparty/mlas sets MLAS_GEMM_ONLY=1 and #if 0's out the half-precision GEMM
sources, but MlasHGemmSupported stays declared and referenced, so linking fails
on an undefined symbol. This adds a weak definition returning false; weak
because the Android NDK's lld rejects the duplicate where MLAS does define it.

Guarding the declaration instead would be cleaner if you prefer that shape --
happy to redo it that way.
```

**Grade B caveat:** a weak stub is a workaround shape. Given they already trim by
`#if 0`, the maintainers may well prefer the declaration be guarded too. Offer the
stub, expect that counter-proposal — the PR message above says so up front.

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

**PR message**

```
java: build with Android Gradle Plugin 8

AGP 7.4.2 does not work with current Gradle/JDK combinations. This moves the
two build files to 8.3.1 and adds the buildFeatures { buildConfig = true } that
AGP 8 needs now that BuildConfig generation is opt-in.

Pick whichever 8.x you want to standardise on -- the buildConfig opt-in is
required either way.
```

---

## 8. gst-plugins-rs: the cargo wrapper clobbers `RUSTFLAGS` — WITHDRAWN

Part of `linux/scripts/patches/gstreamer/003-cargo-wrapper-cross-rust-target.patch`.

**Do not file this. The premise is wrong — checked against the source
2026-09-02.** This entry claimed `cargo_wrapper.py` assigns `RUSTFLAGS` and
discards what the caller exported. It does not:

```python
rustc_target = None
if 'RUSTC' in env:
    rustc_cmdline = shlex.split(env['RUSTC'], ...)
    # grab target from RUSTFLAGS
    rust_flags = rustc_cmdline[1:] + shlex.split(env.get('RUSTFLAGS', ''))  # <- caller's flags
    ...
    env['RUSTFLAGS'] = shlex_join(rust_flags)                               # <- written back merged
```

Line 249 already folds the caller's `RUSTFLAGS` into `rust_flags`, so the
assignment on 254 preserves them. Identical in `gstreamer-1.29.2` (our pin) and
in `main`, so there is no version skew to appeal to either.

**This also makes our own patch redundant**, and slightly wrong: it prepends
`env['RUSTFLAGS']` to a list that already contains it, duplicating every flag.
Harmless in practice, but it should come out of our tree — a backlog item, not
an upstream one.

**The lesson.** This entry was written from the diff, not from the file the diff
applies to. A patch that "fixes" clobbering looks obviously correct until you
read the four lines above it.

---

## 9. gst-plugins-rs: `CARGO_BUILD_TARGET` never reaches cargo — WITHDRAWN

`003-cargo-wrapper-cross-rust-target.patch` (second half) and
`004-meson-build-cargo-build-target.patch`.

**Do not file this either. Checked against the source 2026-09-02: upstream has a
working mechanism and we bypass it.**

`gst-plugins-rs/meson.build:719` forwards meson's own compiler command:

```meson
extra_env += {'RUSTC': ' '.join(rustc.cmd_array())}
```

and `cargo_wrapper.py` then pulls the triple back out of it:

```python
rust_flags = rustc_cmdline[1:] + shlex.split(env.get('RUSTFLAGS', ''))
if '--target' in rust_flags:
    ...
    rustc_target = rust_flags.pop(rustc_target_idx)
```

In a meson cross build `rustc.cmd_array()` carries `--target <triple>`, so cargo
gets it without anyone passing `CARGO_BUILD_TARGET`. Our build never benefits
because `cross-meson.sh` writes `rust = '<wrapper script>'` — a single wrapper
that adds `--target` *inside itself*. `cmd_array()` is then just the wrapper
path, the triple is invisible to meson and to `cargo_wrapper.py`, and cargo
falls back to the build machine.

**So the fix is ours, and it deletes two patches instead of sending them.** Meson
accepts a list for a binary, so `rust = ['<rustc>', '--target', '<triple>']`
puts the triple where upstream already looks. Do that, confirm the cross build
still picks the right target, then drop `003` and `004` entirely.

Tracked as a backlog item — it is a build change, not an upstream one.

---

## 10. GStreamer: OpenCV 5 moved symbols into new headers — ALREADY FIXED UPSTREAM

`005a-opencv5-segmentation-geometry-include.patch` and
`005b-opencv5-cameracalibrate-objdetect-include.patch`.

**Both are already in upstream `main` — checked 2026-09-02. Nothing to file.**

`gstsegmentation.cpp` carries the include *with the version guard* this entry
previously said was missing:

```c
#include <opencv2/imgproc.hpp>
#if CV_MAJOR_VERSION >= 5
#include <opencv2/geometry.hpp>
#endif
```

and `gstcameracalibrate.cpp` has `#include <opencv2/objdetect.hpp>` outright.
Upstream reached the same two conclusions we did, including that `objdetect.hpp`
needs no guard because OpenCV 4 has it and `geometry.hpp` does because OpenCV 4
does not.

**Action: a version bump, not a PR.** When the GStreamer pin moves past these,
drop both patches. If we want to align sooner, take upstream's `CV_MAJOR_VERSION
>= 5` form rather than our unguarded include — ours would break an OpenCV 4
build, theirs would not.

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

## 12. gst-libav: codec IDs removed from FFmpeg 8 — ALREADY FIXED UPSTREAM

`006-libav-removed-codec-fallbacks.patch`.

**Already in upstream `main` — checked 2026-09-02. Nothing to file.**

This entry said the right fix was to drop the affected table entries behind a
version guard rather than define the identifiers to `0`. Upstream did exactly
that, in both files, guarding on `< 63` rather than the `62` we would have
guessed:

```c
        || in_plugin->id == AV_CODEC_ID_R210
#if LIBAVCODEC_VERSION_MAJOR < 63
        || in_plugin->id == AV_CODEC_ID_V308
        || in_plugin->id == AV_CODEC_ID_V408
        || in_plugin->id == AV_CODEC_ID_V410
#endif
```

`gstavviddec.c:3004` and `gstavvidenc.c:1037`, alongside an older
`< 61` guard for `AV_CODEC_ID_AYUV` — so this is a pattern they maintain, not a
one-off.

**Action: a version bump, not a PR.** Our `#define … 0` fallbacks can come out
as soon as the GStreamer pin includes these commits. Until then keep them, but
note that our version is semantically wrong (`0` is `AV_CODEC_ID_NONE`) where
upstream's simply removes the comparisons.

---

## 13. LiteRT: the pip build script hardcodes what a cross build must override

`linux/scripts/patches/litert/001-env-var-overrides.patch` ·
applied by `03-media/build/litert/build-litert.sh` · applies to **v2.2.0**.

Four kinds of change to `tflite/tools/pip_package/build_pip_package_with_cmake.sh`:

1. `TENSORFLOW_DIR` becomes overridable, and the default depth changes from
   `../../../..` to `../../..`.
2. `TENSORFLOW_VERSION` becomes overridable, and its `grep` no longer hard-fails
   when the file it reads is absent.
3. `EXTRA_CMAKE_FLAGS` is threaded into every `cmake` invocation.
4. In the `native` case, `-march=native` is replaced with `-idirafter /usr/include`.

**Verified 2026-09-02, and it is worse upstream than we recorded.** The script
lives at `tflite/tools/pip_package/` in the LiteRT tree, so upstream's
`../../../..` points **outside the checkout**; and the file it then greps,
`${TENSORFLOW_DIR}/tensorflow/tf_version.bzl`, **does not exist anywhere in the
LiteRT repository**. The script still assumes LiteRT is vendored inside a
TensorFlow checkout. `TENSORFLOW_VERSION` therefore comes out empty for anyone
building from the standalone repo.

That makes (1) and (2) a genuine bug report rather than a preference. (3) is
ordinary build-script hygiene. (4) is **ours** (grade C) — replacing
`-march=native` changes upstream's meaning of a native build; it exists because
our "native" builds are not really native. Keep it local, do not send it.

**Issue text**

```
pip build script still assumes the in-tree TensorFlow layout

tflite/tools/pip_package/build_pip_package_with_cmake.sh sets

    TENSORFLOW_DIR="${SCRIPT_DIR}/../../../.."

which points outside the checkout, and then reads

    "${TENSORFLOW_DIR}/tensorflow/tf_version.bzl"

which does not exist anywhere in this repository. TENSORFLOW_VERSION ends up
empty and the version arithmetic below it silently works on nothing.

It would also help cross builds if TENSORFLOW_DIR, TENSORFLOW_VERSION and the
cmake flags could be overridden from the environment instead of being computed
unconditionally. Happy to send a patch for either part.
```

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

## 17. cerbero: glib does not declare its libiconv dependency on Android

Not a `.patch` file — a named `sed` in
`03-media/build/gstreamer/android/build-android-from-source.sh`
(`override_glib_libiconv_dep`, marker `CERB-ICONV`), which restores the recipe
from a backup and warns loudly if upstream's text has moved.

`recipes/glib.recipe` declares the libiconv dependency only below Android API 28.
Other Android recipes install GNU libiconv's renaming `iconv.h` regardless, and
nothing orders them against glib. Lose that race and glib is configured against
the renaming header but linked without `-liconv`, failing on
`undefined symbol: libiconv_open`. Declaring the dep unconditionally is
deterministic and adds no recipe to the build.

**Grade A** — a missing dependency edge, the same class as entry 4.

**PR message**

```
glib: declare the libiconv dependency on Android regardless of API level

glib.recipe declares the libiconv dep only below API 28, but other Android
recipes install GNU libiconv's renaming iconv.h anyway and nothing orders them
against glib. When glib configures after that header appears it picks up the
libiconv_* names but still links without -liconv, and fails with

    undefined symbol: libiconv_open

Declaring the dep unconditionally is deterministic and pulls in no new recipe.
```

---

## 18. cerbero: the soundtouch tarball checksum is stale

Not a `.patch` file — `build-android-from-source.sh` pre-fetches the archive,
hashes it, and rewrites `tarball_checksum` in the recipe when it differs
(leaving the recipe alone, with a warning, if it cannot fetch or hash).

The recipe pins a checksum the live Codeberg archive no longer matches, so a
clean bootstrap dies at the checksum gate.

**This is a bug report, not a patch.** Our fix re-pins dynamically, which is
exactly what a source-integrity gate must never do — upstream needs the correct
static hash instead.

**Hashes captured from a live build, 2026-09-02, soundtouch 2.4.1:**

| | sha256 |
| --- | --- |
| recipe pins | `e07abf20ce8f95850c280132e1f61ad400fc1f4011b7fac698a503de6aab6733` |
| Codeberg serves | `35d404e6e8c2ebd12fb4000da6fadd75c99e37eed2126a04721828c11c0377ec` |

**Issue text**

```
soundtouch 2.4.1: pinned tarball_checksum no longer matches the archive

recipes/soundtouch.recipe pins

    e07abf20ce8f95850c280132e1f61ad400fc1f4011b7fac698a503de6aab6733

but the Codeberg archive for 2.4.1 now hashes to

    35d404e6e8c2ebd12fb4000da6fadd75c99e37eed2126a04721828c11c0377ec

so a clean bootstrap fails at the checksum gate. Re-fetched and verified
2026-09-02.
```

Say plainly in the report that you did **not** verify the new tarball is
legitimate, only that it is what the server returns — a checksum mismatch is
exactly the shape a supply-chain problem takes, and it is upstream's call, not
ours, to decide which hash is right.

---

## 19. cerbero: the pkg-config fallback mirror is gone

Not a `.patch` file — `build-android-from-source.sh` rewrites the pkg-config
source URLs in every recipe that carries them.

**Check what you claim here — measured 2026-09-02:**

| URL | status |
| --- | --- |
| `pkgconfig.freedesktop.org/releases/…` | **HTTP 200 — alive** |
| `gstreamer.freedesktop.org/src/mirror/pkg-config-…` | **HTTP 404** |
| `distfiles.macports.org/pkgconfig/…` (ours) | HTTP 200 |

So "the pkg-config URLs are dead" would be a **false** bug report. The primary
works. What is actually broken is cerbero's own fallback mirror, which matters
precisely when the primary is down — and freedesktop outages are why our
override exists at all.

**Issue text**

```
pkg-config: the src/mirror fallback copy is missing

Recipes fall back to

    https://gstreamer.freedesktop.org/src/mirror/pkg-config-0.29.2.tar.gz

which returns 404. The freedesktop primary is up, so this only bites during a
freedesktop outage -- which is the one moment the fallback exists for.
```

Our redirect of the *primary* to macports is a local availability choice, not
something to send upstream.

---

## 20. OpenCV: `hal_internal.cpp` trusts the include path for `<complex.h>`

Not a `.patch` file — `build-opencv.sh` writes a `complex.h` shim beside the
source tree and prepends it with `-I`. Full analysis in
`docs/failure-modes.md#opencv-stdcomplex-breaks-on-a-shadowed-complexh`.

`modules/core/src/hal_internal.cpp` includes the **C** `<complex.h>` under
`HAVE_LAPACK`, and relies on it reaching libstdc++'s wrapper — the wrapper being
the thing that removes glibc's `#define complex _Complex` again. Any build where
`/usr/include` precedes the compiler's C++ directories (a `-isystem
/usr/include` from any CMake package will do it) gets glibc's header instead,
and every later `std::complex` use fails to parse. We hit it on riscv64.

**Grade A as a hardening PR, small and defensible.** The C++ standard says
`<complex.h>` must not leave the `complex` macro defined, so dropping it after
the include costs nothing and makes the file independent of include-path order.

**PR message**

```
core: do not let <complex.h> leave the `complex` macro defined

hal_internal.cpp includes the C <complex.h> under HAVE_LAPACK and relies on it
resolving to libstdc++'s wrapper, which is what removes glibc's
`#define complex _Complex` again. If anything puts /usr/include ahead of the
compiler's C++ directories -- a -isystem /usr/include from any package does it
-- glibc's header wins, the macro survives, and every later std::complex use
fails:

    error: expected unqualified-id before '_Complex'
      540 | int ldsrc1 = (int)(src1_step / sizeof(std::complex<fptype>));

The macro is not allowed to be defined in C++ anyway, so dropping it after the
include makes the file independent of include order.
```

**Before filing:** confirm the same include shape still exists on `5.x` and
`4.x`, and check whether other files under `modules/` take the same C header. Our
shim stays either way — it also protects the third-party C code in the same
build.

---

## Warning waivers — candidates for a report, not patches

Four places demote an upstream `-Werror` rather than fixing the code. Each is a
potential upstream report, and none is written up yet — **capture the exact
diagnostic from a build log before filing any of them.**

| where | waiver | likely owner |
| --- | --- | --- |
| `03-media/build/gstreamer/common/install-vvdec.sh` | `-Wno-error=unused-but-set-variable`, `-Wno-error=maybe-uninitialized` | SIMDe or vvdec — the warnings appear under GCC 16 once RVV optimisation is on |
| `03-media/build/libcamera/build-libcamera.sh` | `-Wno-error=array-bounds` | GCC — a false positive on libcamera's shared `std::mutex` teardown / logger path. If it reproduces standalone this is a GCC bug report. |
| `03-media/build/onnxruntime/build/lib/common.sh` | `-Wno-error=invalid-constexpr` | Dawn |
| `02-toolchain/vulkan.sh` | compiler shims appending `-Wno-error` to every invocation | Vulkan-SDK build scripts |

The libcamera one is the most interesting: a compiler false positive that only a
minimal reproducer can settle, and GCC maintainers act on those.

## Not a patch file

Five upstream-facing changes do not live under `patches/`: the libstdc++ `sed`
(entry 1), the three cerbero `sed`s (entries 17–19), and the warning waivers
above. One further item is tracked without any local change at all —
**sccache `-B` handling**, `mozilla/sccache#1102`, open since 2022:
`02-toolchain/probe-sccache.sh` detects the broken shape and avoids it rather
than patching it.

## What is left to prepare

Ordered so the cheap, unblocking work comes first.

1. **Nothing here is blocked on the RV23 rebuild except entry 3.** The genai
   riscv64 patch wants "built and smoke-tested on riscv64" in the PR body, and
   that sentence should be true when you write it. Everything else can go now.
2. **Regenerate entry 2 as a cherry-pick.** Ours is a hand-written
   reimplementation of `700cd32ffd` and `83ed22ca28`. Cherry-pick both onto 5.x,
   resolve conflicts, and replace our patch with that — then the PR is a port and
   we stop carrying a divergent fix.
3. **Split three patches that are currently two changes in one file.**
   Entry 8 from entry 9 (`003-…`), and entry 10a from 10b (`005a`/`005b` are
   already separate files — just do not send them together).
4. **Rename `001-riscv64-add-libtiff-dep.patch`.** The defect is not riscv64.
5. **Capture evidence for the two issue-only items and the waivers.** Entry 18
   needs the two soundtouch hashes out of a build log; the four waivers each need
   their exact diagnostic. Do not file any of them from memory.
6. **Decide the shape for entries 11 and 12** — both are compile fixes today and
   both need to become version-conditional before they are sendable.
7. **Check for competing work before each PR.** Entry 2 is the cautionary tale:
   upstream had already fixed it on another branch and we did not look.
8. **After libcamera bumps its libyuv wrap** (entry 16), delete our patch and the
   `patch_libyuv_rvv_sources` call — but keep `verify_libyuv_rvv_rows`.

Accounts you will need: GCC (bugzilla + `gcc-patches@`), GitHub for OpenCV,
onnxruntime, onnxruntime-genai, LiteRT and torchvision, and
`gitlab.freedesktop.org` for GStreamer, cerbero and libcamera — note that
freedesktop's GitLab now gates new-account permissions behind a wiki request, so
start that early if you do not already have access.

## Regenerating a patch against a newer upstream

From `linux/scripts/patches/generate-patches.sh`: patches are **not** generated
automatically. After a version bump, re-run the component build with
`APPLY_PATCH_TRACE=1` to see which patches still apply, then diff the modified
tree against a fresh upstream clone at the new pinned revision. `apply-patch.sh`
fails loudly when a patch stops applying, and prints that same instruction.
