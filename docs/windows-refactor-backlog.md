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

On the last known good tree (arm64 run 36 / amd64 run 8, both 2026-08-26) the
`:winarm64` cross lane reached runtime parity with `:winamd64` apart from the
exclusions listed below. **HEAD is not that tree** — see #134 for what has
landed since and why the amd64 acceptance attempt has not completed. Read the
table below as the last known good.

| | arm64 cross (`bk-20260826-122019`) | amd64 native (`bk-20260826-130136`) |
|---|---|---|
| arch gate | **992 binaries, 0 violations** | 1134, 0 |
| import walk | **606 files, 0 unresolved** (3 allowlisted externals) | — |
| target python deps | **12 wheels, 0 unresolved requirement edges** | — |
| bundle manifest | 6 DLL homes, **6 wheels**, 3 ABSENT markers | — |
| GStreamer contract plugins | **6/6** — `libav opencv onnx webrtc nice tflite` | 6/6 |
| smoke gate | **97 passed / 0 failed / 15 skipped** (floors 66/25) | **222 / 0 / 0** |
| wall clock | ~40 min (media+final) | 2 h 18 min |

**Exactly three components are ABSENT on arm64**, each marked in the bundle by an
`ABSENT-ON-ARM64.txt` (call sites: `build-tvm-from-source.ps1:525`,
`build-iree-from-source.ps1:331`, `build-litert-all.ps1:85`): the **TVM compiler**, the **IREE
compiler** (both need an LLVM cross-built for aarch64-windows) and **LiteRT-LM** (Bazel + an x86_64
prebuilt `.lib`; a CMake port exists upstream — #133(d)). Their *python packages* DO now ship
(`apache_tvm`, `apache_tvm_ffi`, `iree.runtime` — closed by #133). Also excluded by owner decision
or construction: **CUDA** (#122, no Windows-on-ARM CUDA), the **torch app stage** (`uv sync` must
execute the target interpreter), and the **QNN EP**, which is wired but needs a hand-staged SDK
(#121).

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

*(No open items remain.)*

### CLOSED (pointers — full narratives in the dated archives)

- **#121** — QNN EP: SDK STAGED 2026-08-29. QAIRT 2.31.0.250130 zip staged in
  `windows/qnn-sdk/`, `QNN_SDK_ZIP_SHA256` pinned. The scaffold's asserts will
  fire on the first build that includes the media-core `onnx` RUN. Execution
  verification still needs a Snapdragon host, but the build-time path is now
  exercisable. Archive: this entry.

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

- **#133(d)** — LiteRT-LM CMake port: CLOSED 2026-08-29 (owner decision — staying on Bazel).
- **#134** — post-#133 cleanup wave: DONE 2026-08-29. amd64 acceptance
  PASSED (smoke 192/0/1, arch gate 1134/0). Archive: `windows-backlog-archive-2026-08-26.md` § #134.
- **Layer headroom dispute** — SETTLED 2026-08-28. The final image sits at ~75
  layers (counted from the inherited chain's instructions: base 16 + nvidia 3 +
  toolchain 4 + media-merge 15 + torch 3 + final 2 = 43, + 20 ENV + ~12 servercore
  = ~75). The ~108 figure was the pre-ENV-consolidation count. Updated in
  `docs/windows-build-invariants.md`.
- **#122** — CUDA on arm64: CLOSED 2026-08-28 (owner decision). Archive: `windows-backlog-archive-2026-08-26.md` § #122.
- **#136** — VS RUN caching: SOLVED + DEPLOYED 2026-08-26. Archive: `windows-backlog-archive-2026-08-26.md` § #136.
- **#137** — sccache: DONE 2026-08-28. Needs rebuild to land.
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
