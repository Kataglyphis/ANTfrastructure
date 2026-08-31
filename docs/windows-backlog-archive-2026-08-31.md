<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows backlog archive — 2026-08-31

`windows/BUILD-OBSERVATIONS.md`, moved here on 2026-08-31 because its lane is
gone: every run below was driven by `windows/build.ps1`, retired 2026-08-26 and
**deleted** 2026-08-31. The one driver is now `windows/build-buildkit.ps1`, so
nothing quoted here is re-runnable — these are measurements, not instructions,
and they are kept verbatim.

Three things survive only in this file: the **Verified NOT problems** ledger
(benign signals, checked once, recorded so they are not re-investigated), the
three 2026-07-10/11 rebuild outcomes, and the gst-plugin gate's first live
pre-flight log. The four-root-cause GStreamer analysis this file used to own is
now carried in more depth by [`windows-builds.md`](windows-builds.md)
§ Mandatory GStreamer plugins — which also records the 2026-08-13 PROVEN result
that closes the "STILL UNPROVEN" list below — and by
[`changelog-archive-2026-08-13.md`](changelog-archive-2026-08-13.md). The old
header's claim that windows-builds.md "links here for the detail" was never
true: no such link ever existed.

Earlier tranches: [`2026-08-11`](windows-backlog-archive-2026-08-11.md) ·
[`2026-08-17`](windows-backlog-archive-2026-08-17.md) ·
[`2026-08-21`](windows-backlog-archive-2026-08-21.md) ·
[`2026-08-26`](windows-backlog-archive-2026-08-26.md).

## Windows build — observations to refactor later

**Build:** `build.ps1 -Gpu -Stages media,final` (all branches), 2026-07-10, log `scratchpad/rebuild-fixall-2026-07-10.log`.
**Legend:** severity 🔴 blocker · 🟠 degraded/fragile · 🟡 noise/cosmetic. Origin: `pre-existing` vs `regression` (from the 2026-07-10 refactor pass).

### Open items

#### 1. ✅ RESOLVED (2026-07-10, T3) — `002-disable-cuda-pch.patch` drifted → regenerated against pinned v1.27.0
- **Where:** media-core / ONNX Runtime configure. Log ~line 90–112.
- **Was:** `ERROR: 002-disable-cuda-pch.patch -- patch does not apply cleanly to C:\temp\onnx-src` → `falling back to inline regex` → noisy ERROR dump every build.
- **Fix:** regenerated `002-disable-cuda-pch.patch` from a shallow onnxruntime **v1.27.0** clone via `git diff` — it now carries proper `index 2c574f2..72caa32 100644` headers and real line numbers (`@@ -420,10 +420,11 @@`), and applies cleanly via `git apply -p1 --ignore-whitespace` (verified against the pinned clone). The inline-regex fallback is kept as a drift safety net. Same treatment applied to `001-softmax-clangcl-keywords.patch` (regenerated to the single real `or`→`||` fix, 47→13 lines, comment-vandalism removed) and `gstreamer/001-ges-commit-rename.patch` (was "corrupt patch" to git → now proper `index` headers, applies via git). **Confirmed by the T3 rebuild** (`rebuild-t3-final.log:83-90`): `[OK] 001/002/003 applied via git`, zero inline fallbacks — the noisy cuda-pch ERROR dump is gone.

#### 2. ✅ RESOLVED (2026-07-10) — MSVC-STL `experimental/coroutine` inline patch dropped; `yvals_core.h` now carries the load with a loud drift-assertion
- **Where:** media-core / ONNX GenAI configure (MSVC 14.51.36231 STL headers). Log ~line 193613.
- **Was:** `WARNING: experimental/coroutine: STL1009 macro matched the guard but not the replace pattern; MSVC layout may have changed. Verify ...\include\experimental\coroutine (clang static_assert errors may resurface later).` — **pre-existing** (also 1 hit in `rebuild-refactor-2026-07-10b.log`). The coroutine-file edit's single-line regex never matched this toolset's *multi-line* `STL1009` macro call, so it was a silent no-op.
- **Fix (exactly the refactor idea below):** removed the `<experimental/coroutine>`-specific edit from `build-onnx-genai-from-source.ps1`. It was (a) redundant — wrapping the single `_EMIT_STL_ERROR` define in `yvals_core.h` in `#ifdef __clang__` no-ops *every* STL error code (STL1009/1010/1011) under clang-cl — and (b) permanently broken. The remaining `yvals_core.h` patch is now followed by a **loud drift-assertion** that `throw`s if the `_EMIT_STL_ERROR` define is present but the exact patch target no longer matches (i.e. a future MSVC toolset changed the macro format), so drift fails the build loudly instead of silently resurfacing clang `static_assert`s mid-compile. Validated against MSVC 14.51.36231; the removed edit is a proven no-op on build output.

<!-- NEXT-ENTRY-ANCHOR (monitor appends below) -->

### Verified NOT problems (checked, benign)
- `001-softmax-clangcl-keywords.patch` → `[OK] applied via git` — the `Invoke-SourcePatch` scriptblock refactor applies real patches correctly (live-validated).
- gstreamer offline codec-download WARNINGs (libogg/opus/theora/vorbis "is the internet available?") — known benign; the build proceeds.
- `WARNING: The scripts pip.exe ... are installed in 'C:\temp\cpython\Scripts' which is not on PATH` — cosmetic pip note; the build invokes tools by full path. Pre-existing (prior build too).
- `Staged D3D12Core.dll (...\_deps\d3d12lib-src\...\x64\...)` — the 2nd `Copy-SidecarDll` correctly picks the x64 variant (live-validated, both call sites).
- ~24× `lld-link: warning: ... locally defined symbol imported ... [LNK4217]` while linking `litert_lm_main.exe` (LiteRtDispatch* symbols; also oldnames `_onexit`/`_HUGE`) — benign dllimport/static-mix warnings in the upstream litert link; **0 real link errors (no LNK1xxx/LNK2xxx/unresolved)** and the litert branch built + committed fine. Cosmetic; upstream-litert territory, not the build scripts.
- GStreamer/meson **subproject-configuration WARNINGs** during the merge run+commit — `Unknown generator expression '$<CONFIG:Debug>'` (gstreamer), `extract_all_objects called without setting recursive` (opus), `clang-cl does not support C++11; attempting best effort` (harfbuzz), `Subproject 'x' did not override 'y' dependency` (libpsl/gst-plugins-good/gst-plugins-bad), `Could not detect glib version, assuming 2.54` (gdk-pixbuf), `minimum meson_version` (libnice), `Deprecated features used` (win-flex-bison), `meson.exe ... not on PATH`. All standard cross-compile noise emitted by upstream gstreamer's ~40 meson subprojects; the merge built + committed and `gst-launch-1.0` + core plugins pass smoke. Upstream-gstreamer territory, not the build scripts. Excluded from the scanner's [A]/[C] lanes on 2026-07-10.

### Rebuild outcome (2026-07-10)
`build.ps1 -Gpu -Stages media,final` finished in **02:35:09** — all 3 media branches (core/litert/tvm) built via run+commit, merge+GStreamer committed, final image `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` (49.4 GB) tagged. **0 hard errors, 0 real link errors, 0 my-refactor fallback signals** across the full 584k-line log. Smoke test (process isolation): **104 passed / 0 failed / 1 skipped** — unchanged from pre-refactor baseline.

### Rebuild outcome — T3 (2026-07-10, `rebuild-t3-final.log`)
Validates the T3 patch work (#29 DirectML→`.patch`, #30 patch fixes, #25 litert `Edit-SourceFile` migration). `build.ps1 -Gpu -Stages media,final` finished in **02:36:51** (baseline 02:35:09 — no regression), final image tagged, smoke **104/0/1** (identical). In-build confirmations: `[OK] 001/002/003 applied via git` (zero inline fallbacks — cuda-pch ERROR dump gone), all 13 migrated `Edit-SourceFile` blocks logged `Patched` with **zero no-ops/fallbacks**, `litert_lm_main.exe` linked + smoke-ran OK + committed. Items #1 and #2 above both RESOLVED — no open items remain.

### Rebuild outcome — post-cleanup (2026-07-10/11, `rebuild-postcleanup.log`)
First rebuild after the code-health pass (commits `8fc1f8c` docs refresh, `5be9b1e` dead-code/CI-fix/gstreamer, `43463bb` litert-lm `#region` markers — plus the earlier `8460c38` #33–36 fixes). `build.ps1 -Gpu -Stages media,final` finished **exit 0** in **~2h18m** (media-core ONNX RT 20:53:26 → final tag 23:11:38; **faster** than the 02:35 baseline — Stevedore updated to **29.6.1** + warm base/toolchain caches). **0 failures across the entire log** (no `does not apply`, no `LNK1xxx`/unresolved, no `error Cxxxx`, no exceptions, no drift-assertion throw). In-build confirmations:
- **#33 yvals patch:** `Patched MSVC yvals_core.h for clang compat (…MSVC\14.51.36231\…)` applied cleanly; the new drift-assertion stayed **quiet** (no "patch target did not match"); the removed `<experimental/coroutine>` edit is gone and only the pre-existing `-D_SILENCE_CLANG_COROUTINE_MESSAGE` flag remains. GenAI built with `USE_DML=ON`+`USE_CUDA=ON`; `DirectML.dll` staged (DML patch `003` intact).
- **#43 gstreamer download:** `Downloading GStreamer source tarball …1.29.2.tar.gz` via `Invoke-DownloadWithRetry` (23:00:24) → extracted `gstreamer 1.29.2` (23:06:23) → merge committed. The one functional change, validated.
- **#39 doc fix:** log shows LiteRT **`vv2.1.6`** (matches the corrected docs).
- **#45 litert-lm `#region` markers:** media-litert built LiteRT-LM v0.13.1 + linked `litert_lm_main.exe` unchanged (comment-only, as designed).

Smoke test (process isolation, `smoke-postcleanup.log`): **104 passed / 0 failed / 1 skipped** — **identical** to the pre-cleanup baseline (the 1 skip = GPU/CUDA, passthrough blocked on this 26200 host). Final image `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` 49.4 GB tagged. Cleanup confirmed behaviour-preserving end-to-end.

### ✅ RESOLVED (2026-08-07) — the gst-plugin gap has three distinct root causes, now fixed and gated

Diagnosed against gstreamer **1.29.2** sources. The three plugins were missing for
three unrelated reasons, which is why the single "PKG_CONFIG_PATH" theory below
never explained it:

- **`opencv`** — `gst-plugins-bad/gst-libs/gst/opencv/meson.build` resolves
  `dependency('opencv4', version: '>= 4.0.0', required: opencv_opt)`. OpenCV's
  CMake install emits **no** `.pc` at all unless `OPENCV_GENERATE_PKGCONFIG` is
  set, and even then it would be named `opencv5.pc` — which that lookup never
  considers. Good news: upstream **dropped the old `< 4.x` upper bound**, so
  OpenCV 5 is version-acceptable. Fixed by emitting an `opencv4.pc` that
  describes the OpenCV 5 install (link names enumerated from the actual
  `x64\vc18\lib`, not hardcoded).
- **`onnx`** — `ext/onnx/meson.build` resolves
  `dependency('libonnxruntime', version: '>= 1.16.1', required: false)` and calls
  `subdir_done()` when missing. ORT ships no `.pc` on any platform. Fixed by
  emitting one (v1.28.0 clears the floor comfortably).
- **`libav`** — the real trap, and nothing to do with `.pc` files. gstreamer
  ships `subprojects/FFmpeg.wrap`, whose `[provide]` section supplies
  libavcodec/libavformat/libavutil/libavfilter pinned to **FFmpeg 7.1.1**.
  Combined with this build's `-Dwrap_mode=forcefallback`, meson was **forced**
  to use that wrap and never consulted pkg-config — so the build was trying to
  fetch and compile a second, older FFmpeg instead of using the `n9.0` it had
  just built, and dropped gst-libav when that failed. Succeeding would have been
  its own bug: gst-libav would link a different FFmpeg than the image's own
  `ffmpeg.exe` and `libav*` DLLs. Fixed by disabling the wrap so the four
  modules resolve from our install.

- **`tflite`** (added to the mandatory set 2026-08-07) — a fourth mechanism:
  it consults **no pkg-config at all**. `ext/tflite/meson.build` probes the
  compiler with `cc.find_library('tensorflowlite_c')` (fallback
  `tensorflow-lite`), `cc.has_function('TfLiteInterpreterCreate')` and
  `cc.has_header('tensorflow/lite/c/c_api.h')`. That header path is the
  **pre-rename TensorFlow** one; LiteRT v2.x ships the post-rename layout and
  `build-litert-from-source.ps1` stages headers under `include\tflite\`, so the
  probe could never succeed no matter what PKG_CONFIG_PATH said. Fixed by
  mirroring a `tensorflow\lite\` alias tree, resolving the C API library by
  name, and putting LiteRT's include/lib on `INCLUDE`/`LIB` (what
  `cc.find_library`/`cc.has_header` actually consult) plus the meson
  args/link args.

**`tensorfilter` is NOT a GStreamer plugin** — it is an NNStreamer element, and
this repo does not build NNStreamer. It only ever appeared in the probe lists
because the lying healthcheck "found" it. It is deliberately excluded from the
mandatory set; wanting it means adding an NNStreamer source-build stage.

**Gating (the actual fix).** The contract is now data —
`Get-RequiredGstPlugin`, since 2026-08-08 in `WindowsGstPlugins.Common.psm1`
(it debuted in `WindowsScripts.Shared.psm1`) — enforced at four
points that previously disagreed: a pre-flight that resolves every required
pkg-config module in seconds, meson features set to `enabled` (not `auto`, which
means *skip silently*), a post-install `gst-inspect` gate that **throws**, and
smoke-test assertions that **fail**. The healthcheck reports `[FAIL]` instead of
`[PASS]` for an absent plugin. `-SkipPluginGate` is the deliberate exception.

#### Field results — the gate's first real run (2026-08-07, 23:50Z)

The pre-flight executed for the first time in a live merge stage. What had been
reasoning is now measurement:

```text
--- mandatory plugin pre-flight ---
Wrote pkg-config file: …\opencv5\x64\vc18\lib\pkgconfig\opencv4.pc (Version 5.0.0, 64 lib(s))
Wrote pkg-config file: …\onnxruntime-source\lib\pkgconfig\libonnxruntime.pc (Version 1.28.0, 1 lib(s))
Staged tensorflow/lite/ header alias from …\litert\include\tflite
TFLite C API library: tensorflow-lite.lib in C:\runtime\lib\litert\lib
  pkg-config OK: opencv4 (5.0.0 >= 4.0.0)
  pkg-config OK: libonnxruntime (1.28.0 >= 1.16.1)
FATAL ERROR: pkg-config resolves these, but NOT at the version the consumer
  demands: libavcodec (has '..', needs >= 58.18.100); libavformat (has '..',
  needs >= 58.12.100); libavutil (has '..', needs >= 56.14.100); libavfilter …
```

CONFIRMED by this run:

- **OpenCV really ships no `.pc`** — the emitter had to author `opencv4.pc`, and
  it enumerated **64** import libraries from the actual install rather than any
  hardcoded list.
- **The tflite namespace mismatch is real** and the alias staging fixes it:
  LiteRT ships `tflite/`, gst probes `tensorflow/lite/`.
- **The C API library is `tensorflow-lite`, NOT `tensorflowlite_c`** — upstream's
  FIRST choice does not exist here, only its fallback. Listing both names in
  `NeedsLib`, in upstream's order, was load-bearing rather than redundant.
- **The FFmpeg `.pc` defect is exactly as diagnosed** (`Version: ..`) and the
  version floors catch it in **54 seconds**, naming module, found and required
  version — instead of a silently absent gst-libav in a shipped image.

STILL UNPROVEN after this run:

- Whether `gst-libav` compiles against FFmpeg **9.0** at all. The `.pc` fix
  (VERSION file + prefix rewrite) is committed but had not run when the gate
  fired, so the version check is the furthest anything has got. Upstream pins its
  wrap to 7.1.1, so 9.0 remains untested territory and API removals in FFmpeg 8/9
  are a real risk.
- Whether `gstopencv` COMPILES against OpenCV 5. The `.pc` only makes it
  *findable*; upstream dropped the old `< 4.x` upper bound, but nothing has yet
  compiled a line of it against a 5.x header tree.

> **SUPERSEDED 2026-08-13.** Both unknowns closed: all four mandatory plugins
> build AND load in the merge image — `gst-libav` against the image's own FFmpeg
> `n9.0`, `gstopencv` after an OpenCV-4→5 header port. Recorded in
> [`windows-builds.md`](windows-builds.md) § Mandatory GStreamer plugins.

<details>
<summary>Original observation (2026-07-11) — kept for context</summary>

### Observation — gst plugins opencv/libav/tensorfilter are NOT in the shipped image (2026-07-11)
Ground-truthed while fixing healthcheck.ps1's stale-`$LASTEXITCODE` false-PASS: `gst-inspect-1.0
opencv|tensorfilter|libav` all exit -1 ("No such element or plugin") in `winamd64`. The old
healthcheck printed `[PASS] gst-plugin opencv found` for all three — a lie; the fixed check now
reports `[SKIP]` (non-fatal by design). Consistent root cause: meson auto-detection never found
the deps at build time (ONNX Runtime's install ships NO .pc files at all — its PKG_CONFIG_PATH
entry pointed at a nonexistent dir and has been removed from Dockerfile.media-merge-builder; the
OpenCV/FFmpeg .pc situation for gst plugin detection is unverified). **Future work item** if these
plugins are wanted: make opencv/ffmpeg .pc files reach GStreamer's meson (and give ORT a .pc or a
cmake-based detection path), then assert the plugins in the smoke test instead of the healthcheck.
Pre-existing image state, not a regression — nothing except the (formerly lying) healthcheck ever
claimed they existed.

</details>
