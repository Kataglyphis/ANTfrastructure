<!--
  Build-observation tracker — suspicious signals seen during the Windows media+final rebuild.
  NOT source; safe to delete. Each entry is a candidate for a FUTURE refactor/cleanup, with a
  severity, whether it is a regression from the recent refactor pass or pre-existing, and a fix idea.
  Generated/maintained by the build monitor on 2026-07-10 (rebuild-fixall-2026-07-10.log).
-->

# Windows build — observations to refactor later

**Build:** `build.ps1 -Gpu -Stages media,final` (all branches), 2026-07-10, log `scratchpad/rebuild-fixall-2026-07-10.log`.
**Legend:** severity 🔴 blocker · 🟠 degraded/fragile · 🟡 noise/cosmetic. Origin: `pre-existing` vs `regression` (from the 2026-07-10 refactor pass).

## Open items

### 1. ✅ RESOLVED (2026-07-10, T3) — `002-disable-cuda-pch.patch` drifted → regenerated against pinned v1.27.0
- **Where:** media-core / ONNX Runtime configure. Log ~line 90–112.
- **Was:** `ERROR: 002-disable-cuda-pch.patch -- patch does not apply cleanly to C:\temp\onnx-src` → `falling back to inline regex` → noisy ERROR dump every build.
- **Fix:** regenerated `002-disable-cuda-pch.patch` from a shallow onnxruntime **v1.27.0** clone via `git diff` — it now carries proper `index 2c574f2..72caa32 100644` headers and real line numbers (`@@ -420,10 +420,11 @@`), and applies cleanly via `git apply -p1 --ignore-whitespace` (verified against the pinned clone). The inline-regex fallback is kept as a drift safety net. Same treatment applied to `001-softmax-clangcl-keywords.patch` (regenerated to the single real `or`→`||` fix, 47→13 lines, comment-vandalism removed) and `gstreamer/001-ges-commit-rename.patch` (was "corrupt patch" to git → now proper `index` headers, applies via git). **Confirmed by the T3 rebuild** (`rebuild-t3-final.log:83-90`): `[OK] 001/002/003 applied via git`, zero inline fallbacks — the noisy cuda-pch ERROR dump is gone.

### 2. ✅ RESOLVED (2026-07-10) — MSVC-STL `experimental/coroutine` inline patch dropped; `yvals_core.h` now carries the load with a loud drift-assertion
- **Where:** media-core / ONNX GenAI configure (MSVC 14.51.36231 STL headers). Log ~line 193613.
- **Was:** `WARNING: experimental/coroutine: STL1009 macro matched the guard but not the replace pattern; MSVC layout may have changed. Verify ...\include\experimental\coroutine (clang static_assert errors may resurface later).` — **pre-existing** (also 1 hit in `rebuild-refactor-2026-07-10b.log`). The coroutine-file edit's single-line regex never matched this toolset's *multi-line* `STL1009` macro call, so it was a silent no-op.
- **Fix (exactly the refactor idea below):** removed the `<experimental/coroutine>`-specific edit from `build-onnx-genai-from-source.ps1`. It was (a) redundant — wrapping the single `_EMIT_STL_ERROR` define in `yvals_core.h` in `#ifdef __clang__` no-ops *every* STL error code (STL1009/1010/1011) under clang-cl — and (b) permanently broken. The remaining `yvals_core.h` patch is now followed by a **loud drift-assertion** that `throw`s if the `_EMIT_STL_ERROR` define is present but the exact patch target no longer matches (i.e. a future MSVC toolset changed the macro format), so drift fails the build loudly instead of silently resurfacing clang `static_assert`s mid-compile. Validated against MSVC 14.51.36231; the removed edit is a proven no-op on build output.

<!-- NEXT-ENTRY-ANCHOR (monitor appends below) -->

## Verified NOT problems (checked, benign)
- `001-softmax-clangcl-keywords.patch` → `[OK] applied via git` — the `Invoke-SourcePatch` scriptblock refactor applies real patches correctly (live-validated).
- gstreamer offline codec-download WARNINGs (libogg/opus/theora/vorbis "is the internet available?") — known benign; the build proceeds.
- `WARNING: The scripts pip.exe ... are installed in 'C:\temp\cpython\Scripts' which is not on PATH` — cosmetic pip note; the build invokes tools by full path. Pre-existing (prior build too).
- `Staged D3D12Core.dll (...\_deps\d3d12lib-src\...\x64\...)` — the 2nd `Copy-SidecarDll` correctly picks the x64 variant (live-validated, both call sites).
- ~24× `lld-link: warning: ... locally defined symbol imported ... [LNK4217]` while linking `litert_lm_main.exe` (LiteRtDispatch* symbols; also oldnames `_onexit`/`_HUGE`) — benign dllimport/static-mix warnings in the upstream litert link; **0 real link errors (no LNK1xxx/LNK2xxx/unresolved)** and the litert branch built + committed fine. Cosmetic; upstream-litert territory, not the build scripts.
- GStreamer/meson **subproject-configuration WARNINGs** during the merge run+commit — `Unknown generator expression '$<CONFIG:Debug>'` (gstreamer), `extract_all_objects called without setting recursive` (opus), `clang-cl does not support C++11; attempting best effort` (harfbuzz), `Subproject 'x' did not override 'y' dependency` (libpsl/gst-plugins-good/gst-plugins-bad), `Could not detect glib version, assuming 2.54` (gdk-pixbuf), `minimum meson_version` (libnice), `Deprecated features used` (win-flex-bison), `meson.exe ... not on PATH`. All standard cross-compile noise emitted by upstream gstreamer's ~40 meson subprojects; the merge built + committed and `gst-launch-1.0` + core plugins pass smoke. Upstream-gstreamer territory, not the build scripts. Excluded from the scanner's [A]/[C] lanes on 2026-07-10.

## Rebuild outcome (2026-07-10)
`build.ps1 -Gpu -Stages media,final` finished in **02:35:09** — all 3 media branches (core/litert/tvm) built via run+commit, merge+GStreamer committed, final image `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` (49.4 GB) tagged. **0 hard errors, 0 real link errors, 0 my-refactor fallback signals** across the full 584k-line log. Smoke test (process isolation): **104 passed / 0 failed / 1 skipped** — unchanged from pre-refactor baseline.

## Rebuild outcome — T3 (2026-07-10, `rebuild-t3-final.log`)
Validates the T3 patch work (#29 DirectML→`.patch`, #30 patch fixes, #25 litert `Edit-SourceFile` migration). `build.ps1 -Gpu -Stages media,final` finished in **02:36:51** (baseline 02:35:09 — no regression), final image tagged, smoke **104/0/1** (identical). In-build confirmations: `[OK] 001/002/003 applied via git` (zero inline fallbacks — cuda-pch ERROR dump gone), all 13 migrated `Edit-SourceFile` blocks logged `Patched` with **zero no-ops/fallbacks**, `litert_lm_main.exe` linked + smoke-ran OK + committed. Items #1 and #2 above both RESOLVED — no open items remain.

## Rebuild outcome — post-cleanup (2026-07-10/11, `rebuild-postcleanup.log`)
First rebuild after the code-health pass (commits `8fc1f8c` docs refresh, `5be9b1e` dead-code/CI-fix/gstreamer, `43463bb` litert-lm `#region` markers — plus the earlier `8460c38` #33–36 fixes). `build.ps1 -Gpu -Stages media,final` finished **exit 0** in **~2h18m** (media-core ONNX RT 20:53:26 → final tag 23:11:38; **faster** than the 02:35 baseline — Stevedore updated to **29.6.1** + warm base/toolchain caches). **0 failures across the entire log** (no `does not apply`, no `LNK1xxx`/unresolved, no `error Cxxxx`, no exceptions, no drift-assertion throw). In-build confirmations:
- **#33 yvals patch:** `Patched MSVC yvals_core.h for clang compat (…MSVC\14.51.36231\…)` applied cleanly; the new drift-assertion stayed **quiet** (no "patch target did not match"); the removed `<experimental/coroutine>` edit is gone and only the pre-existing `-D_SILENCE_CLANG_COROUTINE_MESSAGE` flag remains. GenAI built with `USE_DML=ON`+`USE_CUDA=ON`; `DirectML.dll` staged (DML patch `003` intact).
- **#43 gstreamer download:** `Downloading GStreamer source tarball …1.29.2.tar.gz` via `Invoke-DownloadWithRetry` (23:00:24) → extracted `gstreamer 1.29.2` (23:06:23) → merge committed. The one functional change, validated.
- **#39 doc fix:** log shows LiteRT **`vv2.1.6`** (matches the corrected docs).
- **#45 litert-lm `#region` markers:** media-litert built LiteRT-LM v0.13.1 + linked `litert_lm_main.exe` unchanged (comment-only, as designed).

Smoke test (process isolation, `smoke-postcleanup.log`): **104 passed / 0 failed / 1 skipped** — **identical** to the pre-cleanup baseline (the 1 skip = GPU/CUDA, passthrough blocked on this 26200 host). Final image `ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64` 49.4 GB tagged. Cleanup confirmed behaviour-preserving end-to-end.

## Observation — gst plugins opencv/libav/tensorfilter are NOT in the shipped image (2026-07-11)
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
