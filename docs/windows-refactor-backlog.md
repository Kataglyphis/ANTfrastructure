<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows container chain — refactor backlog

Open work, standing directives and pending host/upstream actions for the
Windows container chain. Settled items are archived under
`docs/windows-backlog-archive-*.md`.

The Linux-side equivalent is [`refactoring-backlog.md`](refactoring-backlog.md).

> **COUNTING NOTE:** item numbers are HISTORICAL and never reused — the highest
> number is not the item count. Resolved narratives move to the dated archives
> (`windows-backlog-archive-*.md`); a bare "#N" that is not in this file
> resolves there. Lean-OPEN-only is the owner''s standing policy.

## OPEN

### ARM64 parity (opened 2026-08-23)

The `:winarm64` cross lane reached runtime parity with `:winamd64` apart from the
exclusions listed below, and **2026-08-31 reran the FULL chain with the QNN EP
enabled** (#121 build-time path proven; the earlier acceptance gap — HEAD vs the
2026-08-26 tree — was two dead-on-arrival GStreamer cross-lane fixes that are now
landed: see #135 follow-up below). Read the table as the last fully green run
(`bk-winarm64`, 2026-08-31).

| | arm64 cross (`bk-winarm64`, 2026-08-31, QNN ON) | amd64 native (`bk-20260826-130136`) |
|---|---|---|
| arch gate | **1168 binaries, 0 violations** (QNN payload rides in) | 1134, 0 |
| import walk | **793 files, 0 unresolved** (85 device-OS: FastRPC + client SKU) | — |
| bundle manifest | 7 DLL homes, **6 wheels**, 3 ABSENT markers | — |
| GStreamer contract plugins | **6/6** — `libav opencv onnx webrtc nice tflite` | 6/6 |
| smoke gate | **97 passed / 0 failed / 15 skipped** (floors 66/20) | **222 / 0 / 0** |
| QNN | EP ON, QAIRT 2.44.0, `aarch64-windows-msvc` backends staged beside all five frameworks | off (x64 CPU backend is pointless) |
| wall clock | ~40 min (media+final) | 2 h 18 min |

**Exactly three components are ABSENT on arm64**, each marked in the bundle by an
`ABSENT-ON-ARM64.txt` (LiteRT-LM, the default name) or a `COMPILER-ABSENT-ON-ARM64.txt`
(the two compilers, which pass `-FileName` explicitly) — the manifest globs both
families. Call sites: `build-tvm-from-source.ps1:341`,
`build-iree-from-source.ps1:340`, `build-litert-all.ps1:79`: the **TVM compiler**, the **IREE
compiler** (both need an LLVM cross-built for aarch64-windows) and **LiteRT-LM** (Bazel + an x86_64
prebuilt `.lib`; a CMake port exists upstream — #133(d)). Their *python packages* DO now ship
(`apache_tvm`, `apache_tvm_ffi`, `iree.runtime` — closed by #133). Also excluded by owner decision
or construction: **CUDA** (#122, no Windows-on-ARM CUDA) and the **torch app stage** (`uv sync` must
execute the target interpreter). The **QNN EP is PRESENT and PROVEN 2026-08-31** (build-time path;
runtime execution still needs a Snapdragon host — see #121 below).

**The honest caveat, unchanged:** nothing the arm64 lane produces has ever been *executed*. Its
wheels ship staged, not installed, and every verdict above is a static check — PE machine type,
import resolution, exported symbols. The 15 skipped smoke assertions are the ones that would have
to run the aarch64 payload on an x64 host.

**Permanently out of reach — do not re-litigate without new upstream facts:** classic TensorRT
(genuinely x64-only — NVIDIA's support matrix has no ARM64 row), and the `torch` app stage (`uv
sync` must **execute** the target interpreter — uv can cross-RESOLVE into a directory, but the
synced venv is the stage's contract — and PyTorch builds no `win_arm64` wheel for **Python 3.14**,
this repo's cp314 pin).

---

### Open items

- **#149 — the `c9586c1^` warm/materialize rollback recipe is DEAD, not merely
  stale.** Note repaired 2026-08-31 (`bk-warm.ps1:15-22`); THE RESTORE ITSELF IS
  STILL OPEN. All ten retired RUNs mount the same five modules and neither module
  the tree has needed since:
  1. `WindowsTargetArch.Common.psm1` — `WindowsSourceBuild.Common` **throws at
     import** without it (`:37`, a deliberate throw rather than a stub), so every
     restored RUN dies before executing a line. This is what makes the recipe dead
     rather than partial, and it is not TVM-specific.
  2. `WindowsTvm.Common.psm1` — `build-tvm-from-source.ps1:27` throws without the
     `tvmmods` mount (#134), so TVM still fails once the import is fixed.
  AND THE MOUNT PATHS THEMSELVES ARE STALE: all sixteen `source=windows/scripts/
  <name>.ps1` sources in those RUNs predate the `scripts/build/` reorganisation, so
  a verbatim restore fails at solve time before any of the above even runs. Treat
  the recipe as a SHAPE to re-derive, not a patch to apply.

- **#152 — the wave of 2026-08-31 is UNPROVEN BY A BUILD.** Everything in #147 was
  verified statically (773/773 suite, doc-links, doc-dupes, EOL). No chain has run.
  The wave edited `Dockerfile.toolchain-builder` (the DEFAULT `patched-llvm` target)
  and `linux/scripts/01-core/versions.env` (COPY'd into `Dockerfile.base`), so the
  next build re-pays a full LLVM 23.1.0 compile and the media lanes below it —
  the repo's own recorded figure for a toolchain-layer change is ~2 h of media
  compiles, on top of the LLVM build. Budget for it; do not discover it. Until that
  run is green, "gate-green is not usable" applies to this whole wave.

- **#153 — re-run the log forensics against a captured corpus.** The buildkitd
  step-log env fix landed 2026-08-14 and the first fully-captured full chain ran
  2026-08-18, so the analysis that produced the 49-run corpus (28 logs with real
  clip events, the green reference run 49 % blind in its merge step) can now be
  redone against logs that are not truncated. Not started.

### CLOSED (pointers — full narratives in the dated archives)

- **#147 / #148 / #150 / #151** — the 2026-08-31 wave: classic driver deleted, the
  `patched-llvm` whole-dir module mount narrowed (and gated), TVM + GStreamer
  helpers moved to their leaf modules, `Set-StrictMode` plus the four latent bugs it
  exposed, the deliberate declines, the dead `build.ps1` permission entries, and the
  CHANGELOG archive split. Seven commits, `7cc2e95f..a5eac0dd`. Full narratives:
  [`windows-backlog-archive-2026-08-31.md`](windows-backlog-archive-2026-08-31.md)
  § Backlog wave #147-#151. Its declines are also a standing directive below.

- **#121** — QNN EP: BUILD-TIME PATH PROVEN 2026-08-31 on the full `:winarm64`
  cross run — SDK qairt-2.44.0.260225 (SHA-pinned), `onnxruntime_USE_QNN=ON`
  with the `aarch64-windows-msvc` backend set, QNN provider built, QNN runtime
  staged beside all five frameworks (arch gate 1168/0, smoke 97/0/15).
  Execution verification still needs a Snapdragon host. Archive: this entry.

- **`-ResumeStage` BK equivalent** — CLOSED 2026-08-29 (no BK equivalent needed).
  The classic lane's `-ResumeStage` preserved a stopped container (hours of
  compile state), injected a fix via `docker cp`, committed to a partial image,
  and re-ran from a specific stage. BuildKit has no intermediate containers to
  preserve — but it caches completed RUN vertices, so re-running `buildctl`
  automatically resumes from the last cached step. Script fixes land via bind
  mounts (re-read at solve time), so the "inject a fix and re-run" case is
  covered natively. No BK equivalent is needed.

- **#135** — LLVM 23.1.0 AArch64 codegen: DONE 2026-08-29. `BUILD_PATCHED_LLVM=1`
  is now the DEFAULT (Dockerfile ARG + driver default), workarounds removed from
  `build-opencv-from-source.ps1`. `-StockLlvm` is the opt-out. Items 1+3 closed;
  item 2 (NINJA_KEEP_GOING census) is now unnecessary (root cause fixed); item 4
  filed as llvm#219200. Archive: `windows-backlog-archive-2026-08-26.md` § #135.
- **#135 follow-up — patched toolchain lacks the aarch64 compiler-rt** — DONE
  2026-08-31. The source-built `C:\llvm-patched` ships `clang_rt.builtins-x86_64.lib`
  only, so the arm64 GStreamer link died on `__udivti3` (2026-08-30 cross run,
  merge stage). The merge stage now self-heals: `build-gstreamer-from-source.ps1`
  § 5d mines `clang_rt.builtins-aarch64.lib` from the LLVM release archive on the
  cross lane (same recipe as setup-scoop-tools.ps1). Chosen over adding the lib to
  the toolchain layer because the media branches derive FROM `bk-windows-toolchain`,
  so that would re-pay ~2 h of media compiles for one lib. Toolchain-level fix stays
  a follow-up for the next natural toolchain rebuild. Regression:
  `SourceBuild.GstreamerCompilerRt.Tests.ps1`. Docs:
  `docs/windows-cross-builds.md` § aarch64 compiler-rt.
  Second unmasked failure fixed in the same window: the speculative cross-lane
  opus intrinsics enablement (2026-08-30) is REVERTED to the proven disabled
  state — under clang-cl aarch64 the RTCD path applies `-mfpu=neon` (ARM32-only
  flag) and its CPU probe uses MSVC's `__emit` (absent from clang-cl). Working
  enablement recipe for a future TESTED window: `-Dopus:intrinsics=enabled
  -Dopus:rtcd=disabled` (presumes NEON+dotprod; needs a real-device smoke).
  Final gate fix in the same window: the arch-gate import walk gained the
  Qualcomm FastRPC pair `libcdsprpc.dll`/`libadsprpc.dll` as device-OS
  allowances (imported by the QAIRT HTP stub DLLs staged by `Copy-QnnRuntime`;
  they ship in every Windows-on-Snapdragon OS image, never in the SDK zip).

- **#133(d)** — LiteRT-LM CMake port: CLOSED 2026-08-29 (owner decision — staying on Bazel).
- **#134** — post-#133 cleanup wave: DONE 2026-08-29. amd64 acceptance
  PASSED (smoke 192/0/1, arch gate 1134/0). Narrative: `CHANGELOG.md`
  § 2026-08-29 — amd64 acceptance build GREEN, and
  [`changelog-archive-2026-08-28.md`](changelog-archive-2026-08-28.md) § #134
  acceptance run. NOT in `windows-backlog-archive-2026-08-26.md` — that archive
  (line 490) names #134 among the entries that deliberately stayed live.
- **Layer headroom dispute** — SETTLED 2026-08-28. The final image sits at ~75
  layers (counted from the inherited chain's instructions: base 16 + nvidia 3 +
  toolchain 4 + media-merge 15 + torch 3 + final 2 = 43, + 20 ENV + ~12 servercore
  = ~75). The ~108 figure was the pre-ENV-consolidation count. Updated in
  `docs/windows-build-invariants.md`.
- **#122** — CUDA on arm64: CLOSED 2026-08-28 (owner decision). Archive: `windows-backlog-archive-2026-08-26.md` § #122.
- **#136** — VS RUN caching: SOLVED + DEPLOYED 2026-08-26. Archive: `windows-backlog-archive-2026-08-26.md` § #136.
- **#137** — sccache: DONE 2026-08-28, **LANDED**. `SCCACHE_GIT_REV=8ab39266` is in
  `versions.env:557` and in the built base image (the `setup-rust-toolchain` RUN is a
  cache hit at that rev from the 2026-08-30 solve on); the full arm64 chain rebuilt
  green through it on 2026-08-31. No rebuild is owed.
- **#134 free follow-ups** — ALL DONE 2026-08-28: smoke floor recalibrated (85→66),
  §19 PROVISIONAL marker removed, pin parity updated for `TVM_COMMIT`, TVM
  fixtures fixed (single-quoted `` `n `` → real newlines), three merge-stage
  test suites added (39 tests), resource sampler wired into `build-buildkit.ps1`.
- **#133 (a)+(b)+(c)** — DONE 2026-08-26. Archive: `windows-backlog-archive-2026-08-26.md`.
- **#128, #129** — DONE 2026-08-25/26. GStreamer webrtc/nice, OpenCV NEON dispatch.
- **#124, #125, #126, #127** — DONE 2026-08-25. vcruntime140, sitecustomize, staged deps, import walk.

- **#31 [owner decision] registry push** — push the verified images to a
  registry instead of local-only tags. Parked until the owner wants it
  (#59 branch protection was DECLINED, #31 was not).

## STANDING DIRECTIVES (survive their archived entries — do not re-litigate)

- **NEVER trim CUDA_ARCHITECTURES** (80;86;89;90 in ALL builds, incl. dev
  iterations; pinned by Pins.CanonicalValues).
- **CUDA compiles go THROUGH sccache** — `SCCACHE_CUDA_LAUNCHER` is DEFAULT ON
  since 2026-08-18 (`Dockerfile.media-builder:327`; the OpenCV stage via
  `OPENCV_CUDA_LAUNCHER:421`). **Do not flip it off silently** — the onnx stage
  then re-pays ~25 min of CUDA compiles per rebuild. Opt out per run with
  `-BuildArg SCCACHE_CUDA_LAUNCHER=`.
  CORRECTED 2026-08-31: this directive read "CUDA compiles stay BARE nvcc" and had
  been wrong since 2026-08-18. The 2026-08-10 miscompile it rested on was
  root-caused to sccache's dryrun quote-collapse and fixed upstream
  (mozilla/sccache#2811, merged 2026-08-19); patch 006 is retired
  (`build-onnx-from-source.ps1:147`). A directive is the worst place for a stale
  rule — acting on this one would have cost ~25 min per rebuild against an
  explicit Dockerfile warning.
- **Do NOT collapse the media-core checkpoints** (#72: export is ~1.2% of the
  chain; resume granularity is worth more than ~60 s).
- **Do not re-propose** branch protection (#59) or a scheduled nightly/weekly
  chain run (#111) — DECLINED by owner 2026-08-17; manual launches are the
  verification cadence.
- **Do not re-propose #147's declines** (#148): deleting `Get-LlvmMasmCmakeArg`
  or narrowing the `WindowsSourceBuild.Common` re-exports (external-consumer
  API), `Set-StrictMode` on the two consumer modules or the two dot-sourced
  scripts, or moving the handoff helpers off the facade.
- **No logging-idiom sweep** (#110): chain scripts use Write-Host, gstreamer
  keeps its structured `log`, Write-BuildLog stays host-driver territory;
  enforcement is review, not a cache-busting mass edit.
- **Do not re-propose #147's declines** (#148, 2026-08-31). Each was considered and
  refused with a reason: deleting `Get-LlvmMasmCmakeArg` or narrowing the
  `WindowsSourceBuild.Common` re-exports (the modules are external-consumer API — a
  zero-references audit is not evidence of zero consumers); `Set-StrictMode` on
  `WindowsFlutter.Common` / `WindowsContainerLog.Common` (same rule, and a module does
  not inherit its caller's strict mode), on `Initialize-CiEnvironment.ps1` or
  `litert-lm-export-bridge.ps1` (dot-sourced — it leaks, or is a no-op); moving
  `Export-`/`Import-BuildHandoff` off the hot facade (they are the #149 rollback
  payload). Full reasoning in the 2026-08-31 archive § Backlog wave.
- **GES `_commit` retry is DORMANT INSURANCE** (#77): re-open only if its
  retry marker reappears in a gstreamer build.
- **Restore `disk,webdav` only after WCOW cache mounts are PROVEN** (#99
  re-verification recipe in the archive; also listed under Pending).

## Pending host/upstream actions (not refactors — do not let these evaporate)


> The elevated between-runs window (buildkitd step-log env restore, GC-budget
> deploy = #34, poisoned probe-chain prune, diagnostic tag cleanup) and the dufs
> SYSTEM-service migration were APPLIED by the owner 2026-08-13 — see the archive
> addendum. Sanity-check the GC deploy with `buildctl debug workers -v` — the
> output says `Reserved space: 161.0612736GB` for a healthy 150 GiB pin, NOT
> "150GB": the toml takes GiB and buildctl prints GB, and the labels differ too.

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
     CUDA was launcher-off by default only between 2026-08-10 and 2026-08-18
     and has been launcher-ON since (post-#2811); the repro is explicit either
     way — `repro-sccache-cuda-llm-deadlock.ps1:108` passes
     SCCACHE_CUDA_LAUNCHER=1 itself.
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
- **REGISTRY of unfiled drafts under `out/` (added 2026-08-31 — the section title
  says "do not let these evaporate", and four of these were named nowhere):**
  `upstream-buildkit-wcow-cache-mount-draft.md` (item 1 above; its own header records
  the one strengthening step still open), `upstream-sccache-2808-addendum.md` (item 2),
  `upstream-issue-iree-host-bin-dir-exe.md`, `upstream-issue-iree-elf-arch-arm64-msvc.md`,
  `upstream-issue-meson-summary-build-subproject.md` (DRAFT, not filed; verified against
  meson 1.12.0), `upstream-issue-opencv-softfloat-neon.md`,
  `upstream-comment-for-win-14977.md` (a comment for docker/for-win#14977), and
  `upstream-llvm-aarch64-seh-instsize.md` — that last one is **not** llvm#219200: two
  commits are written, built and green on branch `aarch64-instsize-verify`, UNPUSHED.
  Already posted and needing no entry: `upstream-issue-sccache-nvcc.md` (#2808),
  `upstream-issue-litert-lm-cmake.md` (#3245), `upstream-issue-opencv-ort-wchar.md` (#29788).
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
  What remains here — RE-AUDITED 2026-08-31, and only item (2) is still open:
  (1) **CLOSED 2026-08-18/19.** The exact-TU replay exists and ran
  (`probe-onnx-tu-replay.ps1`, `bias_softmax_impl.cu`): it root-caused the
  miscompile to sccache's dryrun quote-collapse (verified bare 3189 == wrapped
  3189 symbols; mozilla/sccache#2811 merged 2026-08-19), and the nvcc/CUDA crash
  proved to be #99 collateral, gone under a healthy backend. #75's `-j` ladder is
  no longer silent either — it warns before and after (archive 2026-08-21:150).
  (2) **STILL OPEN:** one `probe-build-copy.ps1 -Heavy` smoke after the
  poisoned-chain prune.
  (3) **CLOSED.** The at-scale hit rate was measured twice on real media builds:
  the 2026-08-18 base ride (100.00 % CUDA/PTX/CUBIN, 207/816 hits) and the
  2026-08-19 opencv run (99.97 % overall; opencv stage ~13 → ~4.3 min).
  VERIFIED 2026-08-14: the buildkitd service env now really does carry
  `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `..._MAX_SPEED=-1` (checked at the service
  registry key, and today's base build no longer emits the clip warning) — so
  the next full chain would be the FIRST fully-captured one. That chain has since
  run (the 2026-08-18 full-chain green), so a re-run of the forensics against a
  captured corpus is now possible and has not been done. The 49-run corpus
  analysed above predates this: 28 of those logs contain real clip events, the
  green reference run is 49 % blind in its merge step, and historical ONNX
  steps are 83 % blind. Re-run the forensics against a full captured chain.
