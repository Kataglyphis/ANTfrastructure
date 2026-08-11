# Changelog

## 2026-08-11 (morning) - run 15 fell in media-litert: LiteRT-LM v0.15.0's cmake lane is DOUBLY stale upstream; two shims added, run 16 launched

- media-litert died at 1757 s with two independent missing-header classes,
  both root-caused to UPSTREAM cmake staleness at v0.15.0 (their cmake lane
  clearly lags their bazel truth and is not CI-covered): (1) the proto list
  in cmake/packages/litert_lm/CMakeLists.txt enumerates only the v0.13-era
  protos - embedding_metadata/embedding_model_type/executor_metadata/
  litert_lm_metrics are MISSING while 0.15.0 sources include their pb.h
  (verified against the tag's runtime/proto listing); (2) their absl pin
  20260107.1 predates absl/status/status_macros.h, which 0.15.0's own
  sources include (header exists from 20260526.0 - verified against
  abseil-cpp tags). Fixes in build-litert-lm-from-source.ps1, port style:
  proto-list append after token.proto + absl GIT_TAG bump to the repo-wide
  ABSEIL_VERSION (scope: absl_external only; tflite/litert fetch their own).
  Fourth genuine upstream bug of the night (sccache, opencv, 2x litert-lm) -
  upstreamable to google-ai-edge/LiteRT-LM.

## 2026-08-11 (morning) - run 15: MEDIA-CORE FULLY GREEN for the first time since the 2026-08-03 bump

- The whole media-core branch is green end-to-end: ONNX (5th consecutive
  bare-CUDA link), OpenCV (2nd green, patches 001-004), **FFmpeg n9.0
  (.version pre-generation PROVEN: configure 73 s, .pc guard passed,
  vertex committed)**, and **ONNX GenAI 0.15.2 (Neuland, green in 339 s;
  CUDA 80/86/89/90, nvcc bare via the opt-in gate)**. Remaining chain:
  media-litert + media-tvm branches, GStreamer merge, torch, final.
- New P0 discovered along the way (**backlog item 34**): stage re-exports
  mint fresh manifest digests every run (zero digest overlap between runs
  14/15 even for byte-identical base/sdk/toolchain), so downstream FROMs
  cache-miss chain-wide — the partitioned chain currently has NO cross-run
  caching. Fix directions recorded (SOURCE_DATE_EPOCH clamp / skip-export
  on hit / FROM-by-digest). Plus item 35: a transient ~120-min stall in
  the ffmpeg stage's VsDevCmd/scoop section (self-recovered, bracketed in
  the log).

## 2026-08-11 (night) - run 14: OpenCV GREEN FOR THE FIRST TIME (patch 004 proven); FFmpeg n9.0 died in the NEW .version machinery -> PowerShell pre-generation; run 15 launched

- **OpenCV vertex COMMITTED green** - first time ever since the 5.0.0 bump:
  the full patch cascade 001 (cmake) -> 002 (mlas C++) -> 003 (mlas skip,
  proven in run 13) -> 004 (dnn/ORT wchar, proven this run: compile sailed
  past run 13's 435 s death point, 1862 TUs, ninja + link complete).
- **Run-14 stats sealed the caching mystery** (dossier 2.7): 1498 (ONNX) /
  1862 (OpenCV) compile requests, 0 hits, and **write errors == misses —
  EVERY cache write of every real vertex fails**, both levels. The whole
  caching apparatus has been a silent no-op all along. Config-matrix probes
  exonerate every single-compile combination INCLUDING multilevel+cache-
  mount, leaving concurrency or mount history; the chain's own error log
  (1498 plain-text lines on the -2 mount) is the final witness, readable
  once the mount unlocks.
- **FFmpeg n9.0 (Neuland) died at our own .pc guard - correctly**: since
  n9.0, .pc Version fields come from GENERATED libX.version files
  (library.mak -> ffbuild/libversion.sh awk/eval); under the Git-Bash port
  that chain emitted empty MAJOR/MINOR/MICRO -> 'Version: ..' in every .pc
  (the guard existed because the OLD version of this failure shipped
  silently once). Fix: build-ffmpeg-from-source.ps1 pre-generates all eight
  libX/libX.version files from the version(.major).h macros (LF, no BOM -
  make -includes them for LIBVERSION/LIBMAJOR = DLL naming), hard-throwing
  if the macros are not found. Run 15 resumes at FFmpeg.

## 2026-08-11 (early) - run 13: patch 003 PROVEN (MLAS passed), OpenCV died one layer deeper in an UPSTREAM OpenCV bug -> patch 004; run 14 launched

- Run 13's OpenCV vertex applied 003 cleanly and got PAST the vendored MLAS
  entirely (run 12's killer) - died at 435 s in
  `modules/dnn/src/net_impl_backend.cpp:99`: dnn's ORT profiling call
  passes `char*` to `Ort::SessionOptions::EnableProfiling`, but ORTCHAR_T
  is `wchar_t` on Windows. **Genuine upstream OpenCV 5.0.0 bug**: the
  model-path call four lines below is properly `#ifdef _WIN32`-widened,
  the profiling call is not - upstream Windows CI never compiles dnn with
  ORT enabled. **004-dnn-ort-profiling-wchar.patch** mirrors the existing
  widening (generated via the git-diff method, apply-check green;
  upstreamable to opencv/opencv as-is). Patch gate 12/12 OK, lint clean;
  run 14 resumes at OpenCV (ONNX again cached-green from run 13's commit).
- Also this run: ONNX linked green bare a SECOND time (runs 5/12/13 vs
  wrapped 10/11 - the attribution A/B is now 5 runs deep).

## 2026-08-11 (early) - fault-attribution round: CUDA class sealed as sccache-side; L2 mystery attributed to OUR dufs task lifecycle; idle-timeout stats artifact fixed

- **Attribution dossier** (`out/sccache-fault-attribution.md`), built on the
  owner's challenge "beweise, dass der Fehler bei mir oder bei sccache
  liegt": Class 1 (nvcc crash + silent instantiation loss) = sccache-side
  beyond reasonable doubt (7/8 evidence rows closed; only the internal
  mechanism awaits the exact-TU replay). Class 2 (L2 never fed) = sccache
  EXONERATED by a three-phase probe FROM the chain image: raw PUT/GET OK,
  webdav-only write OK (+1 remote), multilevel READ+backfill OK (accidental
  cross-phase hit - comment nonces don't survive preprocessing, round-2
  nonce moved into a symbol), multilevel WRITE-THROUGH OK (+1 remote,
  +1 local, 0 errors). Leading OUR-side theory (2.8): dufs is an ONLOGON
  session-bound task - alive at launch (endpoint gate passes), killable by
  a mid-run logoff, and multilevel fails OPEN (policy l0) with zero L2
  entries as the only symptom. Seal pending: error-log timestamps from the
  cache mount after run 13. Durable fix queued: dufs as a
  session-independent service + single-instance guard.
- **All-zero end-of-vertex stats (runs 12+13) root-caused as a measurement
  artifact**: the build server idle-exits (600 s default) during the long
  bare-CUDA tail, so the stats query talks to a fresh server.
  `SCCACHE_IDLE_TIMEOUT=0` baked into both media Dockerfiles - run 14
  delivers the first REAL per-vertex counters (and the async write-through
  tail no longer dies with the server).
- Run 13: ONNX vertex GREEN again (second consecutive bare-CUDA link);
  OpenCV solve running with the full new closure incl. patch 003 - MLAS
  verdict pending.

## 2026-08-10 (night, review round 2) - two-agent audit over the night's diff: 1 confirmed design flaw + 3 plausible bugs fixed, 2 doc/config gaps closed

- **CUDA launcher flipped to OPT-IN at the wiring site** (confirmed find:
  build-onnx's process-wide `SCCACHE_NO_CUDA_LAUNCHER=1` leaked into later
  same-process stages on the classic lane while the BK lane kept wrapping
  OpenCV/GenAI CUDA through the miscompile-disqualified path - the lanes
  disagreed). `Invoke-CmakeConfigure` now adds the CUDA launcher only under
  `SCCACHE_CUDA_LAUNCHER=1` (three-canary bar in the comment); the
  per-script opt-out env var is gone. Landed BEFORE run 13's OpenCV solve,
  so its CUDA compiles run bare too.
- **cachetest.ps1 per-run nonce**: byte-identical source false-failed the
  `writes>=1` assertion on the second-ever run against a warm WebDAV L2
  (first compile = L2 hit, nothing stored). **onnx-ninja.log rotation** now
  Copy+Remove instead of Move-Item (cache mount is rename-hostile - probed
  for dirs, same wcifs family for files). **A/B layer-lock**: `$disabled`
  set when the disable is ISSUED, not after the 2 s post-state check - a
  slow driver teardown could previously strand the host dGPU-off with the
  finally-guard skipped.
- Doc/config gaps from the consistency agent: pending-cleanup tag list now
  names the orphaned pre-rename `probe-build-copy[-heavy]` tags (the
  `findstr diag-` one-liner cannot find them); new backlog item 33
  (Test-PatchesApplyClean silently SKIPs patch dirs without a repo
  mapping); windows/buildkitd.toml comment updated for the `-2` mount id
  incl. the transient 168h over-budget window of the orphaned `-1` mount.
- Verified-clean list from the agents (for the record): $LASTEXITCODE
  through all new Tee pipelines, every new export/caller contract, StrictMode
  hardening, stall-guard job mechanics, patch-ladder idempotency, CI
  patch-drift trigger paths. Gates after fixes: lint 141 0/0 + AST traps
  clean, tests 457/457.

## 2026-08-10/11 - Linux lane: media 3/3 GREEN after 5 chain fixes; backlog program (6 sweep rounds, ~50 items executed); 2 new gates

- **base->latest-cross chain rebuilt to media-3/3-pinned** (amd64+arm64+riscv64
  smokes all 0 failures; android/runtime/manifest in flight). Five fixes to
  get there, each found the hard way: (1) ffmpeg libtensorflow — the global
  `--extra-libs=-ltensorflow` broke FFmpeg's EXECUTED configure sanity binary;
  fix = `-lstdc++` only (the ONNX pattern) + `bundle_tensorflow_runtime_lib`
  copying the SDK .so out of the cache mount; (2-4) three latent smoke-media
  bugs newly exposed by the 08-08 smoke-hardening: genai import deferred to
  the torch-venv gate, LiteRT symbol check pointed at `libtensorflowlite_c.so`
  AND un-broken from the `nm | grep -q` SIGPIPE-under-pipefail false-stub,
  gst-libav gated on ffmpeg-executability; (5) libvulkan-dev Multi-Arch: same
  mirror skew on arm64 — cross-scoped dpkg `--force-overwrite` drop-in.
  Plus: parallel-arch OOM root-caused to INTRA-arch BuildKit DAG overcommit.
- **Refactoring-backlog program**: 6 agent sweep rounds + toolchain deep-dive +
  currency audit (36 legacy items proven already-fixed, 1 REGRESSION exposed:
  live buildkitd.toml lost gckeepstorage) -> lean batch-ordered backlog
  (docs/refactoring-backlog.md, journal archived), ~50 items executed same
  day. Tree now gated by 22 unit suites / 311 assertions (was 13/150), fix10
  (PR100017 -nostdinc++ static guard), and two NEW gates: `python-lint`
  (ruff; gate=real-error classes) and `secret-scan` (gitleaks, enforcing,
  2 public-trust-anchor FPs triaged into .gitleaksignore).
- **Ops/infra**: `linux/host-config/` — canonical buildkitd.toml (gc 500GB +
  max-parallelism 4) + apply/verify scripts (the anti-regression answer);
  `logs/` excluded from build contexts (2.38 GB/stage transfer, measured);
  services lane hardened (loopback bindings + lan override, compose pins +
  healthchecks, nginx security-header include validated via containerized
  `nginx -t`, benchmark runner atomic writes + JSONL persistence + the
  _manifest.json KeyError that killed every suite run's final comparison);
  llm-stack contract tests wired into CI (ollama service + micro model).
- **Docs**: AGENTS.md Windows tables deduped into windows-builds.md (46 rows,
  0 droppable, 1 real drift fixed), gate-list enumerations replaced by
  KNOWN_SLUGS pointers everywhere, GCC 16.1.0-era stragglers + TensorRT/cuDNN
  examples corrected, IREE + versions.env-toggle + smoke-deferral sections
  written, doc-literal scan added to `sync_versions.py --check`.

## 2026-08-10 (late) - sccache forensics round: poisoning excluded on BOTH cache levels, minimal repros clean, issue draft rewritten to the honest evidence state

- Owner challenge ("ist es wirklich upstream?") audit: binary confirmed
  VANILLA mozilla/sccache main @ the #2722 merge (cargo install --git);
  SCCACHE_MULTILEVEL_CHAIN is an upstream feature (src/cache/multilevel.rs).
  Upstream prior art found: #1098/#1186 (our 10054 Windows crash family,
  open, no root cause), #2299 (arch-guard x host-preprocessor correctness
  bug, NVIDIA-reported, fixed pre-our-pin - proves the bug class), #2726.
- The audit EXPOSED an overclaim in our own draft: run 11 only had a fresh
  L0 - the WebDAV L2 was never reset. Follow-up killed that worry from the
  other side: the L2 store contains just 9 entries (all from micro-probes) -
  the chain's multilevel write-through silently never fed WebDAV (separate
  puzzle, error-log dig pending post-run-13; until then cross-run CUDA
  caching rests on the L0 mount alone). Consequence: runs 10/11 compiled
  for REAL through the decomposition -> the miscompile happened at compile
  time, not via cache hits.
- Minimal wrapped-vs-bare discriminators (fresh disk-only cache, llvm-nm
  symbol diff, toolchain-image solves): define-guard and __CUDA_ARCH__-guard
  instantiation TUs x {plain, ORT-ish (4 gencode, -t2, -Xcompiler,
  extended-lambda), --options-file rsp} - ALL CLEAN. The instantiation loss
  requires real-ORT invocation complexity; next candidates -MD/-MF depgen,
  -forward-unknown-to-host-compiler, quoted rsp defines, concurrency. Next
  step: replay one affected TU's exact generated command line (post-run-13).
- Issue draft + AGENTS failure row rewritten to exactly this evidence state
  (controls a-d, prior-art links, no overclaims). Post still awaiting owner
  go-ahead. Learned-the-hard-way note: nvcc response files are
  `--options-file`, not cl-style `@file`.


## 2026-08-10 (night) - run 12: ONNX vertex GREEN (bare-CUDA verdict confirmed); OpenCV died one layer deeper in MLAS -> patch 003; run 13 launched

- **Run 12's ONNX vertex went green at ~76 min INCLUDING the lld-link** that
  killed runs 10/11 - the sccache-nvcc miscompile verdict is now
  triple-confirmed (run 5 bare green, 10/11 wrapped red, 12 bare green) and
  patches 004/005/006 are exonerated as link suspects. The vertex is
  committed as bk-windows-media-core-onnx; later solves FROM it.
- **OpenCV vertex failed at 520 s in vendored MLAS - one layer past run 5's
  failure** (002's force-include fix held): the bundled kernels are GAS/ELF
  `.S` only (`.type sym,@function`), and clang-cl IS a working GAS
  assembler, so the `check_language(ASM)` guard that protects MSVC does not
  fire - the integrated assembler then rejects ELF directives for a COFF
  target ("expected absolute expression", SgemmKernelSse2.S). No MASM port
  exists upstream. **003-mlas-windows-skip.patch** skips MLAS on Windows
  (dnn falls back to its built-in SGEMM, the same fallback upstream uses on
  Android; inference runs on ORT/DirectML anyway). Patch regenerated from a
  real `git diff` after a hand-written hunk mis-counted its header;
  Test-PatchesApplyClean green across all 11 mapped patches.
- The elevated buildkitd-env restore was DECLINED at the UAC prompt, so the
  new 0a gate got a targeted `-SkipStepLogGate` override (same philosophy as
  `-SkipRdna4Gate`: disk/shim gates stay armed) and run 13 launched with it
  - the 2 MiB step-log clip remains active until the restore happens
  between runs. Console logs now one timestamped file per launch (#30).

## 2026-08-10 (night, backlog execution part 2) - W1/W2 rest + 0b CI half: the Windows backlog is now closed except 27/28-analysis/31/0b-human

- **#21**: ArgQuoting AST detectors moved to `modules/WindowsLint.Common.psm1`;
  Invoke-Lint now runs them inside its single parse pass (violations FAIL the
  gate) over a fully recursive `windows\` walk — which also brought
  `windows\upstream` into lint scope (141 files). The test suite keeps the
  positive controls only.
- **#9/#29**: probe-build-copy's three lanes collapsed into one
  `Invoke-ProbeLane` runner; diagnostic tags adopted the `diag-` prefix
  (cleanup one-liner documented). Not yet live-smoked — one
  `probe-build-copy.ps1 -Heavy` after run 12's media-core is the last check.
- **#8/#30**: `Get-DiagnosticLogPath` + `Limit-DiagnosticLogs` own the
  diagnostics' log path/retention (driver keeps newest 80 stage logs,
  diagnostics newest 60).
- **#14**: verify-cuda-cache's 21-statement RUN line became a COPY'd,
  lintable `cachetest.ps1`. **#15**: renamed to `sync-defender-exclusions.ps1`.
- **#2 finish**: reset-container-stores + verify-cuda-cache resolve tools via
  `Get-PreferredToolPath`; fixed reset-container-stores' hardcoded `D:\GitHub`
  repo path and a latent `Test-Path $null` throw on missing buildctl.
- **0b (CI half)**: new `patch-drift` job in windows-scripts.yml runs
  Test-PatchesApplyClean on every windows/versions.env trigger; also repaired
  a pre-existing `#requires` line lodged INSIDE that script's comment help.
  **#32**: answered — CI is hosted `windows-latest`, no containers, no AMD
  dGPU → RDNA4-immune; gate/toggle stay local-only.
- **#28 groundwork**: 15 s fleet sampler captured per-process WorkingSet/CPU
  through run 12's ONNX compile (`out\build-logs\onnx-tu-memory-samples-*.csv`).
- Gates: lint 141/0/0 + AST-traps clean; tests 457/457.

## 2026-08-10 (night, backlog execution) - W3 media-closure batch + W2 preflight architecture + W1 quick wins, 457 tests green

- **W3 (landed inside run 12's already-busted closure window — the
  morning's Dockerfile edits had already invalidated every downstream
  vertex, so these were cache-free):** stall-guard v2 (#16: timed
  `sccache --show-stats` client probe is the verdict, CPU delta only a
  pre-filter; #20: no guard without a remote; #11: marker is the single
  print channel), attempt-scoped retry ladder (#17, +regression test;
  the run-10 "poisoned L0" paragraph RETRACTED — run 11's fresh-mount
  control proved miscompile, not poisoning), `$invokeNinja` append flag
  removed (#10), `Invoke-SourcePatchWithFallback` with `-Fatal` 006 rung
  (#7+#19, all six build-onnx stanzas collapsed, 4 tests),
  `Write-SccacheStatsToStderr` called by all six source builds (#3),
  onnx ninja log persisted on the cache mount with one `.prev`
  generation (#4), `SCCACHE_ERROR_LOG` into `C:\sccache\logs\` with
  early dir creation (#23).
- **W2/0a:** `Assert-BuildkitdStepLogEnv` — non-admin registry read that
  REFUSES to launch while the buildkitd service env lacks
  `BUILDKIT_STEP_LOG_MAX_SIZE=-1` (the drift that hid verdicts all day);
  wired into build-buildkit.ps1. **0c:** `Driver.PreflightParity.Tests.ps1`
  owns lane parity (shared contract + reasoned allowlists + catch-all for
  new gates; caught `Assert-ImageExists` classification on first run).
- **W1/#1+#6+#18+#5:** RDNA4 hazard set single-sourced
  (`Get-Rdna4HazardDevice`) and the toggle primitive lifted into the module
  (`Set-Rdna4DeviceState`, post-state-verified); toggle script resolves all
  hazard SKUs by default, gained `-NoPrompt`/exit-1-on-failure; the A/B
  delegates its lanes to `probe-build-copy.ps1 -Heavy`; both drivers offer
  gate-specific `-SkipRdna4Gate`. **#24:** `#requires -Version 7.0` across
  all 40 remaining test files, per-file EOL preserved.
- Gates after every sub-batch: Invoke-Lint 139 files 0/0, test suite grew
  438 → **457 passed / 0 failed**.

## 2026-08-10 (late night) - run 11 falsified L0 poisoning: the sccache nvcc path SILENTLY MISCOMPILES → CUDA launcher off, final for this pin

- Run 11 (fresh `sccache-winamd64-2` mount) failed the providers_cuda link
  **byte-identically** to run 10 (`QkvToContext<*, __nv_fp8_e4m3>`,
  `BiasSoftmaxImpl<double>` undefined) — cache poisoning is falsified. The
  consistent explanation across all eleven runs: **run 5 (bare nvcc) is the
  only run that ever linked green**; runs 6/7 (wrapped) died before the
  link; 10/11 (wrapped) reached it first and lack the same arch-guarded
  instantiations. The pinned sccache's nvcc decomposition drops
  device-conditional code — silent wrong code, disqualifying regardless of
  hit rate. (It also explains the `Severity::k0` phantom: run 5 compiled
  triton_kernel.cu green with the WRONG 004 variant, bare — the macro
  collision only ever manifested through sccache preprocessing.)
- `SCCACHE_NO_CUDA_LAUNCHER=1` is back in build-onnx — now as the FINAL
  state for this pin, with the three-canary re-enable bar (verify probe +
  fused_moe compile + full LINK canary) encoded at the call site, in the
  AGENTS failure row (rewritten from the falsified poisoning attribution),
  and in the upstream issue draft (now carrying both failure classes).
  Patch 006 stays: inert while unwrapped, load-bearing on any future retry.
- C/CXX caching remains on and proven; run 12 relaunched in the run-5
  configuration plus all of today's fixes (mlas patch, GenAI 0.15.2 ahead).

## 2026-08-10 (night) - backlog batch W1 round 2: #2 + #26 closed

- **#2 closed with a scope correction**: the "10+ single-candidate files"
  claim was an over-count (the grep matched files that already carry
  candidate lists). The truly single-candidate set was six sites — all now
  resolve the Program Files + `D:\Stevedore` candidates
  (reset-container-stores ×2, collect-host-docker-state, plus the three
  same-day diagnostics). `deploy-shim-patch`/`verify-host-setup` keep their
  overridable Program-Files param defaults deliberately: a shim DEPLOY
  target must not silently follow a stale `D:\` layout (that path vanished
  on this host once before).
- **#26 closed**: both probe Dockerfiles take `ARG BASE`;
  `probe-build-copy.ps1` pins it to versions.env's `WINDOWS_BASE_DIGEST`
  (dependency-free parse — no module import in the first script a new host
  runs) on all three lanes. Smoke-verified live: probe green with
  `probe base pinned: ...@sha256:d5bbb830…`. The RDNA4 A/B keeps the tag
  default until #5 (probe reuse) lands.
- Gates green after each step (lint 137/0/0, tests 430/430).

## 2026-08-10 (night) - backlog batch W1 (host-only, zero cache impact, worked while run 11 compiled)

- Backlog items closed/advanced with gates green (lint 137/0/0, tests
  430/430): **#12** ArgQuoting manual case-loop → `-notcontains`; **#13**
  fake-ninja double-guard folded; **#22** verify-cuda-cache no longer mints
  a throwaway image per run (solve-only); **#25** A/B verdict variables
  StrictMode-safe; **#2 partial** — the three 2026-08-10 diagnostics
  (probe-build-copy, verify-cuda-cache, test-rdna4-layer-lock) resolve
  buildctl/docker from the supported candidate list (`Program Files` +
  `D:\Stevedore`) instead of a single hardcoded path (7 legacy files
  remain); **#6 partial** — `toggle-rdna4-gpu.ps1 -GpuName` closes the
  wrong-SKU dead end (gate names a remedy that can now act on RX 9060/
  R9700 hosts). Media-closure items (#10/#11/#16/#17) deliberately deferred
  until run 11 finishes — editing bind-mounted modules mid-chain would
  redefine later vertices in flight.

## 2026-08-10 (night) - run 10: link failure from POISONED sccache L0 → cache-mount id bumped

- Run 10 compiled all ~1891 ONNX objects but died at the DLL link with
  undefined template instantiations (`QkvToContext<*, __nv_fp8_e4m3>`,
  `BiasSoftmaxImpl<double>`). Root-cause hypothesis with the best fit: the
  persistent sccache L0 cache mount (`id=sccache-winamd64`) holds objects
  from runs 6/7, whose sccache server was KILLED mid-write (guard kills /
  manual unwedge) — truncated objects have been served as L0 hits ever
  since, and the mount survives every retry, so the failure could never
  self-heal. Fix: cache-mount id bumped to `sccache-winamd64-2` in BOTH
  media Dockerfiles (fresh empty L0; the old one ages out via the
  20GB/168h exec.cachemount GC tier). Non-admin, deterministic.
- Follow-up encoded in the backlog (#16/#17 guard redesign): a guard kill
  must be assumed to poison in-flight L0 writes — either verify the
  multilevel fork's atomic-write behavior or purge/quarantine on kill.
- Note: the next run also picks up the owner's GenAI v0.15.2 +
  LiteRT-LM 0.15.0 bumps already present in the Dockerfiles — backlog item
  0b (bumps must ride the Windows lane) is live, not theoretical.

## 2026-08-10 (review) - 8-angle code review of windows/: 10 same-day fixes + refactor backlog

- Owner asked "is my chain clean code, what should I refactor" → systematic
  8-finder review over `windows/`. Verified correctness findings were FIXED
  immediately (each with the failure it prevents): probe zero-lane
  false-green; `repair-windows-componentstore.ps1` still on the retired
  `type=local` probe shape (false-red on healthy hosts); classic lane
  `build.ps1` missing the RDNA4 gate (isolation-probe verdict does not key
  on dGPU state); **`Get-SccacheStatsText` not re-exported from
  WindowsSourceBuild.Common — the stderr stats line would have thrown
  CommandNotFound AFTER the multi-hour ONNX build** (run 9 was stopped
  mid-flight over this); `Dockerfile.heavy`'s trailing-backslash COPY dest
  (Dockerfile escape char eats the newline); RDNA4 A/B now Tee's full lane
  logs and VERIFIES the dGPU re-enable; hazard regex survives
  `Radeon(TM)`-style renames (test added, 430 total); opencv/001 patch EOL
  flip reverted (byte content is a layer-cache key); `SCCACHE_ERROR_LOG`
  parity for Dockerfile.media-merge-builder; stale launcher-opt-out comment
  in Invoke-CmakeConfigure rewritten to the shipped design.
- Everything not correctness-critical went to the new **"Refactor Backlog
  (Windows container chain)"** section at the end of this file's sibling
  docs/windows-builds.md — 25 prioritized items (P1 drift/correctness-adjacent,
  P2 reuse, P3 hygiene), each with its failure scenario.

## 2026-08-10 (late) - sccache CUDA launcher: deterministic server crash scoped to the cuda_llm target → bare nvcc THERE, launcher (and CUDA caching) stays ON everywhere else

- Runs 6 and 7 died at **~4910 s (±2 s) on the same TU family**
  (`fused_moe_gemm_sm80_{bf16,f16}.generated.cu`, `os error 10054` on every
  client): the pinned source-built sccache's nvcc decomposition crashes the
  server deterministically there — this is NOT the earlier 0%-CPU stall
  shape, and no retry ladder can pass a deterministic crash point. The
  identical run-over-run timeline (despite a hot L0) additionally shows the
  **CUDA hit-rate at this commit is ~zero** — the launcher cached nothing.
- **NEW `patches/onnxruntime/006-cuda-llm-bare-nvcc.patch`** (owner
  requirement: CUDA must cache — a blanket opt-out was rejected): the crash
  source is exactly ONE OBJECT library (`onnxruntime_providers_cuda_llm`,
  where all `fused_moe_gemm_*.generated.cu` live), so the patch clears that
  target's `CUDA_COMPILER_LAUNCHER` property; every other CUDA target stays
  sccache-wrapped and cacheable. Applied with an inline-regex fallback.
  `SCCACHE_NO_CUDA_LAUNCHER=1` remains only as the emergency full opt-out.
- **sccache stats now go to STDERR after the ONNX build**
  (`sccache-stats|` prefix, `-Advanced`) — stderr survives the 2 MiB
  step-log clip, so per-run CUDA hit/miss/error rates are finally visible
  (they were never observable before; the ~zero-hit-rate claim can now be
  confirmed or retired with data). Candidate-sccache re-enable criteria for
  the cuda_llm target stay encoded at the versions.env pin:
  `verify-cuda-cache.ps1` + an ONNX canary through the fused_moe launchers.
- Stall guard + full-speed retry ladder stay armed for the whole wrapped set.
- **Never-swallow-logs sweep (owner directive)**: the buildkitd service env
  was found EMPTY — the repo-required `BUILDKIT_STEP_LOG_MAX_SIZE=-1`
  (unlimited step logs, `setup-new-host.ps1` applies it) had been wiped by
  the 2026-08-09 Stevedore/repair work, and the default 2 MiB clip hid the
  stall-guard verdicts and sccache stats for three runs (re-apply + buildkitd
  restart pending the next between-runs window). `SCCACHE_ERROR_LOG` now
  persists inside the sccache cache mount (server postmortems survive the
  container). `probe-build-copy.ps1` and `verify-cuda-cache.ps1` Tee their
  FULL lane output to `out\build-logs\` and print the path (display keeps
  showing tails only). New AGENTS.md invariant bullet pins the principle.

## 2026-08-10 (resolution) - RUN-layer finalize 0x20: root cause is the ENABLED RDNA4 dGPU; build with it disabled

- **Same-boot A/B on the RX 9070 XT host: disable the dGPU → tiny AND heavy
  RUN-layer finalize green on the first try; enable → red** (upstream
  docker/for-win#14977 — AMD RDNA3.5/4 + Adrenalin lock freshly-written
  container layer files on process-isolated layer ops; issue open). Severity
  tracks the Windows patch level: pre-KB5101684 only heavyweight RUN layers
  tripped (light probes green — the host looked healthy while the chain died);
  post-KB5101684 (installed 2026-08-10) even 10-byte RUN layers fail.
  COPY-only layers are unaffected (no container involved). The full falsified
  list from the hunt: Defender (exclusions verified live; realtime-off blocked
  by tamper protection), WSearch/SysMain, daemon bounces, vmcompute restart,
  minifilter detaches (zero third-party filters on C:), `--no-cache` fresh
  IDs, settle delays, reboots, nanoserver base, split solves.
- **Failed finalizes WEDGE hcs state**: after one, even tiny RUN layers fail
  until a reboot (survives service restarts and vmcompute) — this cascade is
  why every earlier debugging round produced contradictory verdicts, and why
  the old probe (which crashed its own export on every run) kept hosts
  looking broken. The 2026-08-09 "Adrenaline reinstall fixed it" and
  "in-place repair fixed it" root-cause claims are SUPERSEDED: they coincided
  with patch-level/reboot changes that moved the trigger threshold.
- **Lint-scope gap closed**: `Invoke-Lint.ps1` never covered
  `windows\diagnostics\` — its scripts (GPU/isolation probes, now the RDNA4
  A/B) were silently unlinted. Added recursively; 136 files, all clean.
- **NEW diagnostic `windows/diagnostics/test-rdna4-layer-lock.ps1`**
  (elevated): the RDNA4 A/B as a durable ~2-min tool — probes RUN-layer
  finalize with the dGPU enabled then disabled (finally-guarded re-enable),
  verdicts GONE / PRESENT / INCONCLUSIVE. Re-run after every
  Adrenalin/Windows update; GONE = retire the toggle workflow + gate.
- **NEW preflight gate `Assert-NoActiveRdna4Gpu`** (WindowsBuildDriver.Common,
  wired into `build-buildkit.ps1` after `Assert-ShimPatch`; `-SkipHostChecks`
  overrides; 7 tests in BuildDriver.HostGates): refuses to start a chain that
  would die on its first RUN commit while an RDNA4 dGPU is enabled, and names
  the workflow — elevated `toggle-rdna4-gpu.ps1 -Disable` → build (display
  falls back to the iGPU; DirectML-on-host unavailable during the window) →
  re-enable. `toggle-rdna4-gpu.ps1`'s "obsolete" header is retracted.
- Chain relaunched with the dGPU disabled: base stage committed the
  previously-failing COPY and the VS Build Tools layer on the first attempt.
- **Run 5 milestone: the ONNX vertex went GREEN end-to-end** (compile, link,
  export, commit — first of the day; patches 001-005 all production-proven)
  and died one partition later in OpenCV 5.0.0's newly bundled MLAS:
  **NEW `patches/opencv/002-mlas-clangcl-force-include.patch`** — mlas cmake
  treats clang-cl as GNU-Clang and passes `-include` + `cstring`, which the
  CL dialect parses as an input file; the patch adds an MSVC-frontend branch
  (`/FIcstring` + `/w`). 10/10 patches validate.
- **NEW diagnostic `windows/diagnostics/verify-cuda-cache.ps1`** — proves the
  sccache→nvcc(decomposed)→WebDAV path end to end: a tiny buildctl solve FROM
  the local toolchain image compiles one `.cu` twice; asserts the recompile
  HIT and that objects reached the store. First run verified 2026-08-10:
  4/4 component hits (CUDA/Device/PTX/CUBIN), 4 objects + check-marker written
  to the dufs root (which was EMPTY before — no prior run had ever populated
  the CUDA cache). Traps encoded: sccache's nvcc parser needs the `-ccbin=`
  (equals) form, and bare in-container compiles need INCLUDE assembled from
  the MSVC root + Windows SDK (the images bake no VS env).
- **sccache's nvcc launcher DEADLOCKED mid-ONNX (run 4): NEW
  `Start-SccacheStallGuard` watchdog** in `Invoke-NinjaBuildWithRetry`
  (WindowsSourceBuild.Common) — CUDA caching STAYS ON (owner requirement).
  Symptom: sccache server + 9 clients all at 0 % CPU, zero backend
  connections (dufs healthy), compile crawl/stall for 40 min; killing the
  server alone is NOT enough (clients block forever on the dead pipe). The
  guard samples the compiler fleet every 60 s from a background job; three
  consecutive ~zero-CPU samples with sccache alive → kill ALL sccache
  processes → in-flight compiles fail fast → the retry ladder resumes with
  cache hits for everything already compiled. Guard is inert when sccache is
  not on PATH (unit tests unaffected). Emergency escape:
  `SCCACHE_NO_CUDA_LAUNCHER=1` (honored by `Invoke-CMakeConfigure`) drops
  only the CUDA launcher, C/CXX caching stays.
  **Run-6 hardening:** the deadlock recurs (~40-80 min apart) and a guard
  kill is NOT OOM-shaped, so the single `-j<RetryJobs>` retry lost the run
  (in-flight compiles die with `os error 10054`, and the guard's console
  verdict sat beyond the 2 MiB step-log clip). The guard now appends every
  kill to a marker file IMMEDIATELY, and `Invoke-NinjaBuildWithRetry` gives
  marker-confirmed guard-kill failures up to 3 FULL-`-j` retries (compiled
  objects are L0 hits) before the incremental attempt. 2 new tests pin the
  ladder (429 total). Also learned: `C:\sccache` (the L0 tier) is a
  persistent BuildKit cache mount (`id=sccache-winamd64`) — L0 hits make no
  WebDAV traffic, so a quiet L2 store during a mostly-cached vertex is
  normal, not a defect (the multilevel `disk,webdav` write-through itself
  was probe-verified against the live endpoint).
- **NEW `patches/onnxruntime/005-xqa-host-stub-sccache.patch`** — ORT 1.28.0's
  XQA (paged-attention) kernels are the only ORT sources with host/device-
  divergent include guards (host pass keys on the cmake define
  `HAS_SM80_OR_LATER`); sccache's nvcc decomposition can drop target `-D`
  defines in the host sub-step, so the host namespace lacks
  `smemSize`/`kernelType`/`cacheVTileSeqLen` and the generated stub dies with
  C2039/C2065 in `x_?.cudafe1.stub.c` (the synthetic `x_?.cu` name is the
  sccache fingerprint). Since this build pins `CUDA_ARCHITECTURES=80;86;89;90`,
  the patch emits the host stub unconditionally (documented as
  not-upstreamable-as-is). Found at ~1295 s of run 3 — one whack-a-mole past
  the tunable.h fix, which run 3 proved good (triton_kernel.cu compiled).
- **Two media-lane source patches for the 2026-08-03 version bumps** (first
  Windows build attempt since): **NEW
  `patches/onnxruntime/004-tunable-severity-macro-collision.patch`** — ORT
  v1.28.0 + CUDA 13.3: `wingdi.h`'s classic `#define ERROR 0` (reached
  despite `-DNOGDI` when a header in `triton_kernel.h`'s chain includes
  wingdi directly) pre-expands through the `LOGS_DEFAULT` forwarding macro
  into the nonexistent `Severity::k0` in `tunable.h` (nvcc: `enum ... has no
  member "k0"` at the `LOGS_DEFAULT(ERROR)` line, first TU
  `triton_kernel.cu`); fixed with guarded `#undef ERROR`/`#undef VERBOSE`
  after the header's includes, applied in `build-onnx-from-source.ps1`'s CUDA
  branch with an inline-regex fallback. (First fix attempt undef'd only
  VERBOSE — a summarizer misreported which `LOGS_DEFAULT(...)` sat on the
  error line; the moved-but-identical error exposed it. Read the line, not
  the expectation.) **REGENERATED
  `patches/opencv/001-cmake-clang-cl-compat.patch` against OpenCV 5.0.0** —
  the old hunk context still named the `CMP0218` policy block that 5.0.0
  removed, so the patch (applied with NO fallback) would have thrown an hour
  into media-core. `Test-PatchesApplyClean.ps1` (which reads pins from
  versions.env): all 8 patches OK.

## 2026-08-10 - build probe was lying: two pwsh bugs fixed (probe verdicts trustworthy again; the same day's RESOLUTION entry above tells where "green" actually ended)

- **`probe-build-copy.ps1` carried two bugs since its introduction that made a
  healthy BuildKit lane read as broken.** (1) The unquoted
  `--output type=local,dest=$outDir` reached buildctl as VERBATIM SOURCE TEXT —
  pwsh passes a bareword comma-attribute argument to native commands with no
  variable expansion (measured on pwsh 7.6.4) — so the export wrote into a
  directory literally named `$outDir` and then died in the receiver. (2) The
  docker-classic lane assigned `$docker = "...\docker.exe"`, which IS the
  `[switch]$Docker` parameter variable (names are case-insensitive), throwing
  `Cannot convert ... String to ... SwitchParameter` — that lane had never
  executed at all.
- **The probe's BK lane now exports `type=image,name=docker.io/local/
  kataglyphis:probe-build-copy,unpack=true`** — the same output path
  `build-buildkit.ps1` uses — so a green probe covers layer commit AND the
  finalize/export/unpack reimport. It also exits non-zero naming each failing
  lane (previously it could end green-looking with a failed lane). Never use a
  `type=local` export of a Windows image as a health signal: the local
  exporter dies client-side (`error from receiver: write ...\Boot\Fonts\
  <font>.ttf: file already closed`) even on a healthy host — new
  AGENTS.md Common Failure Modes row.
- **Verdict with the fixed probe on the discovered host (RX 9070 XT/26200):
  light lanes green on buildkit (commit + export + unpack) — but NOT
  chain-green.** The real chain's first COPY after the heavy pwsh-install RUN
  dies deterministically (`ActivateLayer 0x20` at child finalize/reimport,
  FRESH snapshot IDs under `-NoCache` — not poisoned cache). Minimal repro
  isolated and committed as the probe's **new `-Heavy` lane**
  (`Dockerfile.heavy`: RUN writing 2×100 MB, then a one-file COPY — fails in
  ~1 min while a plain nested multi-file COPY on servercore commits fine): the
  child's finalize fails while the fresh heavy parent layer stays held.
  Ruled out live: Defender (full exclusion set verified, incl. MsMpEng),
  daemon state (elevated containerd+buildkitd bounce), poisoned cache (fresh
  IDs under `--no-cache`), and time (a 90 s settle layer's own commit fails
  identically) — host-level hcs/filter hold. Next levers: reboot → `-Heavy`
  re-probe → clean Adrenaline reinstall → shim A/B → healthy host
  (`Dockerfile.heavy` doubles as a 60 s upstream repro).
  docker-classic legacy `COPY` still fails there
  (`mkdir \\?\Volume{...}\C:.`). Chain launches also fail-fast at preflight
  when the dufs sccache endpoint is down — its ONLOGON task does not re-fire
  after repair reboots; `Start-ScheduledTask dufs-sccache` cures it (done
  today). README / host-setup / AGENTS.md updated.
- **NEW `windows/scripts/tests/Native.ArgQuoting.Tests.ps1`** (8 tests, in the
  pre-build gate): AST sweep of every `windows/` script for both trap classes —
  bareword comma-attribute args referencing variables, and non-boolean
  assignments to `[switch]` parameter variables in their own scope — plus
  positive controls pinning the detectors themselves. Both sweeps are clean
  repo-wide after the probe fix. New AGENTS.md § Windows Build Invariants
  bullet documents the traps.

## 2026-08-09 (resolution) - Windows COPY-commit failure: root cause was a faulty AMD Adrenaline install, NOT the RDNA GPU — **SUPERSEDED by the 2026-08-10 resolution above (the enabled RDNA4 dGPU IS the holder; this entry is kept as history)**

- **The 'AMD RDNA3.5/RDNA4 GPU breaks Windows-container layer commits'
  hypothesis (upstream microsoft/Windows-Containers#623) is RETRACTED as a
  root cause (corrected 2026-08-09).** On the discovered host (Ryzen 9 9950X
  + RX 9070 XT, 25H2/26200) the build-COPY failure - `hcsshim::ActivateLayer
  0x20` on buildkit and `mkdir \\?\Volume{<GUID>}\C:.` on docker legacy,
  both lanes, every COPY layer, surviving `-NoCache`, restarts, Defender
  exclusions, a full store reset and a reboot - was caused by a **FAULTY AMD
  ADRENALINE installation**. A clean **reinstall fixed it** (probe:
  `windows/scripts/probe-build-copy.ps1`). GPU-disable never cured it;
  `toggle-rdna4-gpu.ps1` is now obsolete as a fix. The Linux cross lane and
  all repo gates were never affected. Docs updated (superseding the night
  entry below): `AGENTS.md` Common Failure Modes + script table,
  `docs/windows-host-setup.md` gate, `docs/windows-builds.md` diagnostic
  section, `README.md`.

## 2026-08-09 - LLM stack: GPU mode override + Qwen3-Coder deploy

- **NEW `linux/llm-stack/docker-compose.gpu.yml`** — a compose overlay that
  gives the Ollama service all NVIDIA GPUs
  (`deploy.resources.reservations.devices`, driver `nvidia`) and raises the
  default context via `OLLAMA_CONTEXT_LENGTH`. The base `docker-compose.yml`
  stays CPU-only; GPU hosts run
  `docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d` after
  installing the `nvidia-container-toolkit` (install commands in the llm-stack
  README). `OLLAMA_KV_CACHE_TYPE=q8_0` and flash attention remain the defaults.
- **Deployed `qwen3-coder:30b` (30.5B A3B MoE, Q4_K_M, ~18 GB) on a 2× NVIDIA
  host (12 GB + 16 GB)**: 100 % GPU placement (9.9 GB / 12.4 GB per card),
  warm decode ~137 tok/s, ~47 s cold load, context tuned to 64K. Perf measured
  via the `/api/generate` metrics.
- **Docs:** `linux/llm-stack/README.md` gained a GPU-mode section (toolkit
  install + override usage + `ollama ps` GPU check) and a VRAM/context sizing
  table (~104 KB/token q8_0 KV ⇒ 28 GB total = ~64K cap; 256K needs >45 GB).
  The "CPU-only inference" architecture note is now "CPU-only by default, GPU
  optional". Repo `README.md` and `AGENTS.md` Quick Reference now point to the
  LLM stack (previously undiscoverable from either).

## 2026-08-09 (night) - Windows lane on a 25H2 host: platform COPY regression found; sccache source build proven host-side

The base->final GPU verification run that motivated the sccache source build hit
a wall that turned out to be the HOST OS, not the repo.

- **SUPERSEDED 2026-08-09 — root cause corrected above: FAULTY AMD ADRENALINE install (reinstall fixed it), NOT the RDNA GPU. Historical entry kept verbatim below.** Originally claimed: Windows 11 build 26200 (25H2 line) `COPY`-into-layer failure — isolated to a
  AMD RDNA3.5/RDNA4 GPU defect (upstream microsoft/Windows-Containers#623), NOT a blanket build break and NOT the ISO (corrected 2026-08-09).** buildkitd: `failed to reimport snapshot: hcsshim::ActivateLayer 0x20` (`file used by another process`), deterministic across fresh chain-IDs, survives `-NoCache`, service restarts, vmwp kills, Defender exclusions, a full store reset AND a reboot. docker-classic fallback: mkdir \\?\Volume{<GUID>}\C:. invalid directory name, under process AND Hyper-V isolation. A minimal 3-layer probe isolates it: `FROM servercore` + `RUN` commits fine, the first `COPY` layer never does. Root cause is the AMD GPU: on this box (Ryzen 9 9950X + Radeon RX 9070 XT, RDNA4) hcsshim layer VHD mounting breaks at COPY commit; the upstream issue's own matrix proves RDNA3.5/RDNA4 = broken while RDNA1/RDNA2 iGPU/Intel = fine. NOT the OS: a same-build 26200 machine builds fine, `sfc`/`DISM` report 0 components corrupt, and even projfs.sys is absent on the working machine too. Fix (reproducer-verified): disable the AMD GPU in Device Manager (RDP survives via the Remote Display Adapter). On the discovered host (2026-08-09) GPU-disable did NOT cure it - real upstream, persisted here; root cause on that box remains undetermined FINAL-verdict-update: FINAL 2026-08-09: BK build lane unusable on that host UPDATED after the in-place Windows repair (same build 26200): the layer-COMMIT wall is FIXED (all layers incl. existing-dir writes commit on buildkit); only the final EXPORT reimport 0x20 persists, and the Defender engine is unkillable by design so that lever stays untestable - residual host hcs export behavior. The full base->final chain is one export step from green on this host. - the reimport 0x20 persists on buildkit 0.32.0 AND a throwaway v0.32.2 (instrumented A/B), i.e. host-level, not engine-version; classic lane (dockerd) builds the same shapes fine there; heavy/GPU chain goes on the working host.. 
  Docs updated: `docs/windows-host-setup.md` OS gate + AGENTS.md Common Failure
  Modes carry the corrected row. The Linux cross lane and all repo gates are
  unaffected.
- **sccache source build verified HOST-SIDE** (the part that needs no image):
  the pinned `SCCACHE_GIT_REV = e9b15a3` is confirmed from upstream to BE the
  mozilla/sccache#2722 merge ("Fix nvcc dryrun parsing for CUDA 13.3", carries
  `test_group_nvcc_subcommands_with_simt_only_cicc_input`); the EXACT command
  `setup-rust-toolchain.ps1` runs (`cargo install sccache --locked --git
  https://github.com/mozilla/sccache --rev <rev>`) compiles, links and installs
  cleanly (exit 0, 3m25s, sccache.exe in CARGO_BIN, `--version` = 0.17.0 exactly
  as the commit documented). The wiring itself remains covered by the 412-test /
  0-lint gates (verify-toolchain CARGO_BIN assert, CMAKE_CUDA_COMPILER_LAUNCHER).
  The one thing still pending is a real ONNX CUDA kernel cache-hit in an image
  build - which needs a supporting (non-25H2) host.
- New-host bring-up (setup-new-host.ps1 + verify-host-setup fix + magic-constant
  purge, this morning's entry) proved out on this fresh host: verify-host-setup
  all-green, patched shim deployed and hash-recorded, CNI confs on the live
  subnet, dufs L2 up with logon task. Host-side probe toolchain (rustup gnu via
  Strawberry's bundled mingw linker) installed for the verification above -
  throwaway, not part of any image.

## 2026-08-09 (late) - Windows lane: one-script new-host bring-up + magic-constant purge + verify crash fix

Verified live while bringing up a brand-new host (this one) for the sccache
source-build verification run; every fix below is what a fresh Stevedore box
actually trips over.

- **NEW `windows/scripts/setup-new-host.ps1`** - the scriptable half of
  `docs/windows-host-setup.md` Phases A5+C as ONE elevated, idempotent run
  (`-ReportOnly` safe, refuses while a build is live): authors the CNI
  `.conflist` from the LIVE `vEthernet (nat)` subnet (derived network/prefix+GW
  at runtime - **the magic subnet literals are gone from the docs**), then
  orchestrates the canonical per-concern scripts (apply-containerd-config ->
  `.conf` derive + debug flags + teardown env + Defender; apply-buildkitd-gcpolicy
  + the `BUILDKIT_STEP_LOG_*` env; deploy-shim-patch - BUILDING the 45min/100min
  fixed-constant shim from hcsshim source when no `-ShimPath` is given, Go via
  scoop; dufs install/start/ONLOGON-task/machine endpoint env).
  Every sub-script is called with a HASHTABLE splat - the first draft used
  array splats and hit the documented position-binding trap in `-ReportOnly`
  (`-ReportOnly` arriving as `$ServiceName`), exactly the AGENTS array-splat rule.
- **`verify-host-setup.ps1` line-212 crash fixed**: `(Get-ItemProperty ...).Environment`
  on a service whose `Environment` value does not exist threw PropertyNotFound,
  which under StrictMode surfaced as an unset-variable error and CRASHED the
  script mid-run on the common drifted host - silently skipping the teardown-env
  and debug-flag checks and under-counting the verdict (reported 2 warnings
  instead of 3). Registry values that do not exist now degrade to honest WARNs
  (`.PSObject.Properties.Name -contains` reader), matching the Defender check's
  degrade-to-UNKNOWN contract.
- **Docs purge of stale example values**: `docs/windows-host-setup.md` A5 and
  `docs/windows-builds.md` section Getting it going no longer hand out the
  reference host's `172.31.32.0/20` subnet as copy-paste gospel - both now say
  "derive" and point at `setup-new-host.ps1`; README's fresh-machine pointer
  gains the one-run path.

## 2026-08-09 (early) — Linux lane: validator split + a locale bug the split's own probe caught

- **validate_compiler_for_target decomposed** (complexity item 9): the
  108-line monolith is now five independently-callable checks
  (_cc_check_{dumpmachine,binary_elf,object,loader,qemu_exec}) with explicit
  args — deliberately NOT the _VCS_* implicit-global convention.
- **Locale bug found by the split's verification probe**: every readelf
  parser in the tree matched the ENGLISH "Machine:"/"interpreter:" strings —
  on a non-C-locale host (this one is de_DE) readelf localizes ("Maschine:")
  and the ELF-machine checks failed spuriously; inside containers (LC=C) the
  bug was invisible but latent. All parsed `readelf -h/-l/-d` calls across 7
  files now run under LC_ALL=C. Host probe: 6/6 PASS.

## 2026-08-08 (night) — Linux lane: complexity F-G + TVM shallow/commit-pin clone

- **setup-package-image's 102-line dual-purpose function split** (audit F-G):
  select_dev_packages / install_dev_packages / clang_embedded_deb_version
  (the previously function-nested, globally-leaking `_clang_ver`) /
  pin_clang_alternatives — the old name remains as its caller's 4-line
  sequence. All load-bearing comments preserved.
- **TVM clone hardened**: shallow `--depth 1 --branch <tag>` instead of the
  old bare recursive clone (which pulled the whole default branch + all
  submodules unpinned before ever checking out), plus a `TVM_COMMIT` opt-in
  pin (commit beats tag; v0.25.0's commit recorded in versions.env) —
  completing the `*_COMMIT` convention for the second compiler-class clone.
- Repo hygiene sweep came back clean: no build artifacts tracked,
  .gitignore already covers resource-monitor outputs and out/.

## 2026-08-08 (night) — Linux lane: supply-chain round 3 — build executors frozen

- **Round-3 completion**: Vulkan SDK and GStreamer-Android-universal tarball
  sha pins landed once their streamed hashes finished — the audit's entire
  class-(d) (completely unverified fetch) list is now EMPTY.

- **The ~20-site unpinned `uv pip install` surface is closed for every
  binary-shaping package**: meson, ninja, cython, pybind11, setuptools,
  wheel, scikit-build-core, setuptools-scm — and auditwheel/patchelf, which
  REWRITE the shipped wheels' ELF headers — are pinned via a new
  `PY_*_VERSION` family in versions.env (frozen to what builds were already
  resolving; the torch wheelhouse keeps its documented setuptools<82 ceiling
  via a dedicated pin). Pure-python data deps stay floating by design.
  Wired at 8 install sites with the inline-default safety-net convention.
- **abseil headers now fetch the immutable `/archive/<commit>.tar.gz`** form,
  sha-verified (ABSEIL_COMMIT + ABSEIL_TARBALL_SHA256) — the tag-tarball form
  is movable and not byte-stable.
- **verify-parity.sh main() decomposed** (complexity F-F, zero blast radius):
  five responsibilities → five functions matching the file's own check_*
  shape; behavior verified (--help, missing-args, exit codes).
- AGENTS.md: supply-chain discipline codified in Linux Build Rules; a
  16.1.0/16.2.0 GCC version drift in the rules text fixed.

## 2026-08-08 (night) — Linux lane: supply-chain hardening round 2 — pins for every trust anchor

All computed from upstream (streamed sha256, gzip/manifest-verified) and
wired with the warn-if-unset pattern:

- **CUDA apt keyring deb pinned** (x86_64 + sbsa) — the apt trust anchor for
  the whole NVIDIA lane was fetched with no hash; **ROCm apt signing key
  pinned** (was TOFU via wget|gpg); **Android commandlinetools zip pinned**
  (sdkmanager bootstraps the NDK cross compiler from it); **Flutter SDK
  pinned** with Google's official sha256 from releases_linux.json;
  **rustup/uv installer pins populated** (the fail-closed mechanism existed
  with EMPTY keys — both effectively ran unverified remote scripts as root).
- **TensorFlow C SDK: the pin was fiction.** Upstream stopped publishing
  libtensorflow C builds after **2.18.0 (x86_64 only)** — the pinned 2.21.0
  never existed as an artifact, the GitHub URL has 404'd since 2.19, and a
  `2>/dev/null` swallowed it: ffmpeg silently shipped WITHOUT its TF DNN
  backend while versions.env claimed otherwise. Now: 2.18.0 from the GCS
  mirror, sha-pinned, aarch64 says loudly that no upstream build exists, and
  the do-not-bump constraint is documented in versions.env.

## 2026-08-08 (night) — Linux lane: supply-chain round 1 + safe complexity refactors

(See commit 68bc11e: TLS redirect/wget hardening, CPython fail-closed,
NodeSource/npmjs pipe-to-shell removal, npm ci lockfile-exact, verified
Kitware/LLVM host-repo helpers, cerbero tag pinning, meson wrap-update
removal; lib/ prelude drift + clang-extractor + cross-fallback parity with
two new test suites.)

## 2026-08-08 (night) — Linux lane: smoke-depth round (audit round 3, lens 2)

A capability×depth audit of every smoke layer found the deepest ML coverage
living in an EXTERNAL repo's app smoke — torch, torchvision, onnxruntime
inference and OpenCV imencode had zero in-repo functional coverage, and
several capabilities had none anywhere. Presence checks upgraded to real
execution (all device-less, no network, seconds each):

- **GStreamer mandatory plugins** (libav/opencv/onnx/tflite) now GATE in the
  runtime smoke on the real target arch under qemu, and in smoke-media's
  native branch — a present-but-unloadable plugin (the observed
  webrtcbin2/gtk4 class) was previously only a WARN-count. Plus a data
  roundtrip (videoconvert!jpegenc → 4 real JPEG frames) beyond the
  registry-only fakesink pipeline.
- **Python stdlib battery** (ssl/sqlite3/lzma/bz2/zlib/hashlib/ctypes,
  exercised not just imported) in smoke-toolchain — the textbook from-source
  CPython failure; `_sqlite3` was checked NOWHERE in linux/ and joins
  build_python.sh's staging warn-list too.
- **torch forward+backward, torchvision nms/._C + v2.Resize, and a real
  onnxruntime InferenceSession** (model generated in-process via
  torch.onnx.export — no fabricated bytes) in smoke-torch-venv, gated
  STV_COMPUTE=1 (default on).
- **ffmpeg codec depth**: buildconf-vs-registration consistency for
  x265/dav1d/svtav1/vpx/opus (build-ffmpeg probe-gates --enable-*, so a
  silently-missed probe DROPS a codec while the build stays green) + real
  encode/decode roundtrips for libx265/libvpx-vp9 — all inside the
  binary-executes guard.
- **Cross-compiler loader assertion**: the emitted ELF's PT_INTERP must
  request the TARGET's dynamic loader (wrong-sysroot links succeed and only
  die on target); opportunistic static-binary qemu-run (exit-42 proof) when
  qemu-user is present.
- **Rust**: version pinned against RUST_VERSION (the old check asserted
  "rustc" appears in `rustc --version` — could never fail), host
  compile+RUN, and per-target emit-obj (rustup lists targets whose std rlibs
  are missing). **node/npm**: first coverage at all (version pin + JS
  execution) — the LiteRT-web WASM gate silently self-disables without node.
- **LiteRT**: `nm -D` symbol check (TfLiteInterpreterCreate/TfLiteModelCreate)
  — works on foreign-arch ELF, so the cross branch gets it too; a 12-byte
  stub used to pass `[ -f ]`. **nvcc**: device-less __global__ kernel
  compile + the fail-open hole closed (ENABLE_NVIDIA=true with no nvcc now
  fails). **GenAI**: shipped-but-unimportable is now FAIL, absent stays INFO.
  **Vulkan runtime**: real vkEnumerateInstanceVersion call (works with zero
  ICDs; a healthy loader cannot fail it). **Android NDK**: the compile smoke
  its header promised since creation (per-target object + ELF-machine
  assertion; the NDK clang is a host binary, runs on every branch).
- Fail-open holes closed: absent cross-Python staging dir now FAILS for
  requested foreign arches (ran zero checks before); smoke-media's hardcoded
  "torch not installed" INFO replaced with a real venv probe (it was false in
  the package image); smoke-vulkan's `vkvia | head` rc swallow fixed.

## 2026-08-08 (night) — Linux lane: orphan sweep (audit round 3, lens 1)

A dedicated dead-weight audit (things wired to nothing), with every dynamic
script-dispatch mechanism enumerated first so glob/variable-built paths could
not produce false orphans:

- **Real arm64 bug**: `wasm-opt.sh` built the aarch64 binaryen asset name but
  versions.env pinned no `BINARYEN_LINUX_AARCH64_SHA256` — the download died
  "No pinned SHA256" on any arm64 host. Pinned (sha computed from the
  upstream `version_131` tarball, gzip verified).
- **Dead legacy alias** `TVM_VULKAN_KEEP_SDK_LIBS` removed from vulkan.sh
  (sole occurrence repo-wide; the canonical knob is VULKAN_KEEP_SDK_LIBS).
- **Legacy flutter shims** (`setup-flutter-{arm64,x86-64}.sh`, kept for
  external ExternalLib consumers) no longer carry a hardcoded `3.44.8`
  fallback that had already drifted from the 3.44.9 pin — they now require
  the versions.env value they load anyway.
- **Deleted**: `02-toolchain/rust/Build-Linux.sh` (zero references AND a
  duplicate re-implementation of its five cargo_* siblings) and
  `06-packaging/package_archive.sh` (zero references, zero docs; its Windows
  "twin" is equally unreferenced, so no parity obligation).
- **Documented as consumer surface** (shipped into images, invoked by
  external repos, previously invisible): `lib/{ctest-run,docs-build,
  rust-toolchain}.sh` (now in the AGENTS.md + linux-build-basics.md
  inventories alongside their already-documented siblings),
  `02-toolchain/rust/cargo_*`, `02-toolchain/python/ci_*.sh`,
  `01-core/setup-host-deps.sh`.
- `make lint-workflows` target added (preflight ran it; the Makefile only
  exposed lint-dockerfiles).
- Clean bill elsewhere: zero dead Dockerfile ARG/ENVs, zero unreferenced
  patches/data files (verify-patch-integrity already gates patches), zero
  dead Makefile targets/workflow steps.

## 2026-08-08 (night) — Linux lane: audit round 2 leftovers cleared

The verified-but-queued remainder of the four audit reports:

- **Orphan verify branches wired** (Dockerfile.media): `onnxruntime-gpu` runs
  after the GPU EP build (GPU-enabled images had NO gate on those artifacts)
  and `armnn` runs after the arm64 ACL/ArmNN build (a failed build left empty
  /opt/armnn + /opt/acl shipping unexamined). Both branches had existed
  caller-less since creation.
- **`make verify-chain` can now fail**: STALE links are counted and the
  explicit `--verify-chain` path exits 2 when any exist — it used to warn and
  exit 0, an explicit verification that could not fail. The automatic
  partial-run protection (_chain_assert_ancestry, hard-fail) is unchanged.
  Makefile help text updated.
- **verify-parity.sh judges by rc, not sentinel**: `|| echo "FAILED"`
  appended AFTER the captured traceback, so the first-word parse read
  "Traceback" and an ImportError could never increment failures.
- **Runtime Vulkan check three-way**: ctypes.CDLL of the loader does NOT need
  an ICD/GPU — a load failure means the library is missing/broken, and the
  runtime image always ships the Vulkan runtime files. Missing/unloadable is
  now a FAIL; only container-infra errors stay WARN.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse C — test gaps closed

- **Zero-assertion suites now FAIL**: `t_summary` treats `_T_RUN=0` as a
  failure (a gutted suite used to print "0 assertion(s) passed" and stay
  green), and run-tests.sh aggregates the per-suite counts — the final line
  now reads "N suites, M assertions", so a coverage collapse is visible in
  every log.
- **Four new/extended suites** (7→11 suites, 68→120 assertions):
  - `test-parallelism.sh` — pins mem_capped_jobs' RAM/cores formula, the ≥1
    floor, and the new PARALLEL_JOBS validation (**fix included**: the
    override was emitted unvalidated — `PARALLEL_JOBS=0` went straight into
    `ninja -j0`; now rejected with a warning).
  - `test-cli-parsers.sh` — pins the new central two-arg value guard (**fix
    included** in dispatch_parsed_args: a trailing `--target-arches` or one
    that swallowed the next flag used to assign ""/"--push" silently and fall
    through to CROSS_DEFAULT_ARCHES — building all three arches).
  - `test-stage-defs.sh` — the REAL cross_stage_tag/cross_build_mem_divisor/
    graph-validation (test-disk-guard/test-ancestry stub these; until now no
    test executed the real ones). Also asserts the Klasse-B ENABLE_NVIDIA
    forwarding.
  - `test-smoke-arch-parity.sh` — asserts smoke-common.sh's inline fallback
    maps agree with the canonical platform.sh/arch-mapping.sh for all three
    arches (this file had already caused two silent-skip bugs).
  - Extended: riscv64→RISCV LLVM backend assert (a tempting "consistency
    rename" would break the compiler stage), runtime_artifact_platform/
    _image_ref (wrong-arch artifact COPY class), version-forwarding negative
    asserts (an unset var must NOT become `--build-arg FOO=` overriding the
    Dockerfile default with empty; `# noforward` must hold).
- **IFS bug class killed by construction**: `arch_list_to_words` and
  `smoke_arch_words` now emit NEWLINE-separated words — `for x in $(...)`
  splits under both the default and the strict `IFS=$'\n\t'`, retiring the 16
  latent for-loop sites the audit found (all consumers verified compatible:
  for-loops, `wc -w`, unquoted argv). Parity suite pins the property.
- **Gates that could not fail, now real**: smoke-torch-venv fails when
  `STV_REQUIRE_VENV=1` and /opt/venv is absent (the package wrapper-smoke
  sets it — the venv gate used to SKIP+pass exactly when setup-torch-venv
  failed hardest); the SDK image asserts a non-empty /opt/vulkan and (except
  riscv64) an executable /opt/flutter/bin/flutter (both shipped with ZERO
  verification); smoke-torch-venv reports TVM presence/version per-arch with
  EXP_TVM as opt-in hard pin (Dockerfile.media's comment claimed an
  `import tvm` runtime gate that never existed — comment corrected);
  `cross_stage_validate_graph` (pure, sub-second) now runs in preflight
  (slug `stage-graph`) instead of only at build kickoff.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse D — convention bugs

- **`USE_CCACHE`/`USE_SCCACHE`/`USE_LLD` now accept both truthiness
  spellings** (0/false/no/off, any case). Previously only the literal string
  `"false"` disabled them — `USE_CCACHE=0`, the convention half the fleet
  uses (and what `ENABLE_SCCACHE_*` expects), was silently ignored. Fixed in
  compiler-cache.sh (+ shared `_flag_disabled` helper), cmake-cache-linker.sh,
  build-ffmpeg.sh, onnxruntime lib/common.sh, ffmpeg-probe-framework.sh
  (inline case in the standalone-bundled files, per bundling policy).
  Verified live: `USE_CCACHE=0` now prints "ccache disabled".
- **Bare `sudo` in the ONNX AMD/NVIDIA steps** (30-build-native-amd.sh,
  30-build-native-nvidia.sh) replaced with the CPU sibling's guarded pattern
  (command -v probe + SKIP_DEP_INSTALL honor) — they died rc 127 on images
  without sudo while the CPU step degraded gracefully.
- **common.sh's sudo fallback now sets `SUDO_WRAP` too** (it set only `SUDO`;
  a `${SUDO_WRAP}` consumer reaching that path aborted under `set -u`).
- verify-arg-consistency.sh no longer mixes `WARN:` and `WARNING:` prefixes.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse B — contract drift

- **`CUDA_ARCHITECTURES` carried literal quote characters into CMake**: the
  only quoted value in versions.env, and `load_versions_env` exports values
  verbatim — CMake received `"80` and `90"`, and the documented Hopper
  `90→90a` suffix transform was a silent no-op (the string ends in `"`).
  Value dequoted in versions.env (the file format is unquoted inert data, as
  the loader header documents) AND the loader now strips one pair of
  surrounding quotes — defense in depth for the class. Verified live: the
  transform now yields `…;90a`.
- **Android OpenCV built a different OpenCV than the chain**:
  `OPENCV_VERSION="${1:-5.x}"` — the dispatcher passes no arguments and the
  env was ignored, so every android image cloned the MOVING 5.x branch while
  the chain ships tag 5.0.0. Now env-first with the 5.0.0 inline default
  (sibling pattern), and Dockerfile.media's final stage exports
  `ENV OPENCV_VERSION` so the android stages inherit the pin the same way
  they already inherit GSTREAMER_VERSION.
- **`Dockerfile.media` still fell back to `/opt/gcc-16.1.0`** in three
  places — a path that no longer exists since the 16.2.0 bump (every
  script-side fallback had been bumped; the Dockerfile inlines were invisible
  to verify-arg-consistency, which only parses `ARG NAME=` lines).
- **Stale nested fallbacks** (all invisible to the checker's `$`-containing
  literal guard): GenAI `v0.15.0`→`v0.15.2`, VVdec `v3.1.0`→`v3.2.0`,
  Python `3.14.6`→`3.14.7` ×2 (build_python.sh would have died on the 3.14.7
  checksum with a misleading error) + the same stale 3.14.6 on the Windows
  side (build-opencv-from-source.ps1).
- **`ENABLE_NVIDIA`/`ENABLE_AMD` now reach the cross lane**: the runtime lane
  honored them, `cross_stage_build_args` dropped them — a GPU-configured
  runtime could sit on CPU-only media artifacts with no warning. Forwarded
  (only when set) for the media stage.
- **`install_vulkan_sdk` zero-arg call aborted "unbound variable"**: the
  fallback referenced setup-dependencies.sh's flag-local
  `VULKAN_VERSION_DEFAULT`; the chain now ends in the canonical
  `VULKAN_VERSION` pin.
- Four comments whose stated contract had drifted from the code they sit on
  (abseil default, three GCC-16.1.0 claims) corrected.

## 2026-08-08 (night) — Linux lane: audit round 2, Klasse A — error-path masking

Four-perspective audit (error paths, contracts, tests, conventions); this
entry is the error-path class. Every fix below closes a path where a real
failure was reported as success:

- **ELF wrong-arch gate was dead code** (`validate-media-runtime.sh`): the
  clean-scan `exit 0` sat BEFORE the ELF architecture validation; NEEDED
  sonames resolve by name, so a wrong-arch binary scanned clean and the gate
  never ran. Now an `else` branch — ELF validation runs on every path.
- **Stale-rootfs export on failed builds**: `_build_one_artifact`
  (build-runtime-artifacts.sh) and `_sdk_arch_build` (build-sdk-artifacts.sh)
  ran under `if !`-suppressed errexit with no `|| return 1` — a failed
  `runtime_build_chain`/`cross_stage_run` fell through to
  `export_rootfs_from_image`, which exported the previous run's tag and
  reported green. Guards added.
- **parallel-loop lost workers that die via `exit`**: `err()` terminates the
  background subshell before `|| touch failed-flag` runs, and the join
  discarded `wait`'s rc — a dead lane read as green under PARALLEL_ARCHS=1.
  A nested `( )` layer now absorbs the exit into a return code.
- **app-wheels gate was vacuous**: the Dockerfile's `.placeholder` (written
  exactly when the wheelhouse build failed) satisfied "dir not empty". The
  riscv64 verify now requires a real `*.whl`; `ALLOW_EMPTY_APP_WHEELS=1` is
  the explicit escape hatch.
- **verify-media-artifacts could not fail for litert / genai / opencv-core**:
  litert checked `/usr/local/{include,lib}` (already filled by base's
  CPython); genai checked dirs its own producer `mkdir -p`'s on every skip
  path; opencv-core used INFO-only optional checks. All three now require
  stage-specific artifacts (new side-effect-free `probe_lib`/`verify_any_lib`
  helpers also fix the `verify_A || verify_B` idiom that counted A's failure
  even when B passed). genai verify mirrors its producer's legitimate
  cross-build skip instead of "verifying" pre-created empty dirs.
- **smoke-media masking**: a non-executable ffmpeg/gst-inspect was a PASS
  ("will work at runtime") — now INFO + ELF-magic assertion, with the
  functional gate named; the OpenCV cvtColor roundtrip and GStreamer pipeline
  checks had no else-branch (could not fail) — now fail when execution
  demonstrably works; ffmpeg encode failure fails when the binary executes
  and advertises libx264; onnxruntime import-failure now proves the library
  exists instead of claiming presence unchecked.
- **verify-cuda-stack.sh rewritten**: ` || true)` pasted inside three command
  substitutions made the "not found" branches unreachable and hard-failed
  healthy images under `set -e`. Now honest warn-only (stderr, no `-e`) with
  `CUDA_STACK_STRICT=1` as the real gate for complete-stack images.
- **base-image bootstrap fails fast**: the apt-update retry loop `break`ed
  away its terminal failure and continued; ca-certificates install failure
  was a log line. A broken mirror/CA store now aborts the bootstrap with the
  culprit named instead of surfacing hours later as an opaque TLS error.

## 2026-08-08 (evening) — Linux lane: IREE tblgen Exec-format failure, and the binfmt registration that silently died

### media-arm64 failed: IREE's NATIVE tblgen was cross-compiled

The app-wheelhouse IREE cross build died with `Exec format error` on
`llvm-project/NATIVE/bin/llvm-min-tblgen`: LLVM's CrossCompile.cmake defaults
the NATIVE sub-build's compilers to the **outer cross compilers**, so the
tblgen that must run on the amd64 build host was built for arm64. Fix:
`build-app-wheelhouse.sh` now passes `-DCROSS_TOOLCHAIN_FLAGS_NATIVE` pinning
the true host compilers (+ ccache launchers — closing the nested-sub-build
caching item from the backlog in the same stroke). riscv64 never hit this only
because qemu binfmt silently emulated the wrong-arch tblgen — slowly.

### Which exposed: binfmt registrations die on containerd restart

The morning's shim-failure `systemctl --user restart containerd` silently wiped
the rootlesskit-namespace qemu registrations (they are namespace-lifetime, not
host-lifetime). Re-registered for arm64+riscv64 and installed the
`rootless-binfmt.service` --user unit so login/boot re-registers automatically.
Two bugs fixed in `setup-rootless-binfmt.sh` itself along the way: it claimed
"pulling" but never pulled (image save fails "not found" on a fresh host), and
its blob-detection pipeline `tar -tf | grep -q` self-destructed under pipefail
(SIGPIPE — shell bug class 2) so extraction skipped every blob. AGENTS.md's two
stale recommendations of the non-working rootless
`tonistiigi/binfmt --install` container corrected to the helper script.

The foreign chain marked arm64 failed and moved on to media-riscv64 (by
design); media-arm64 + android-arm64 re-run after the chain with the fix.

## 2026-08-08 (evening) — Linux lane: structural round 1 (cache-key closure + drift bugs + dead code)

### Dockerfile.base no longer cache-keys on ~120 files (A1)

base's six RUNs bind-mounted **all of 01-core + 02-toolchain**, so editing any
of ~120 files — including host-only orchestrator modules the image never
executes — busted base and cascaded a rebuild through the entire chain,
undoing the toolchain stage's careful per-file mount lists one tier up. The
mounts are now the traced 15-file transitive closure of base-image.sh (mirror
RUN: 2 files). Validated with a real from-scratch base build; the first
attempt failed exit 127 because the static trace missed
`use-fast-ubuntu-mirror.sh`, which bootstrap-ca **exec**s rather than sources
— closure tracing must follow exec/`bash` edges, not just `source` lines.
Marginal cost of a future 01-core edit drops from "full chain rebuild" to
near zero.

### Three drift bugs between intentional clones (A2, A4, A5)

- `cross_build_is_active` existed 5× with 3 semantics; the documented
  arch-normalization fix had reached 1 of 5 copies. The raw copies compared
  OCI names against `uname -m` machine names and reported "cross active" on
  native arm64 hosts. All fallbacks now normalize via `arch_normalize`.
- `compiler-resolution.sh` never shipped to the android stages, so
  IREE-android's fallback `command -v gcc` resolved the **custom cross GCC**
  from the inherited toolchain PATH as its *host* compiler (live bug, masked
  by best-effort gating). Dockerfile.android now COPYs the canonical script;
  the fallback prefers explicit /usr/bin compilers like the litert copy.
- Dockerfile.package hand-rolled the ports-mirror sed: it ignored the
  `USE_FAST_UBUNTU_MIRROR` gate and never derived ports-from-archive. It now
  runs the canonical `use-fast-ubuntu-mirror.sh`.

### Dead code out (B1–B4, B6)

smoke-wrapper.sh (orphaned; two docs falsely claimed wrapper-smoke runs it —
both corrected), `create_deb()` (104 lines, zero callers, positioned after
the script's outputs were written), `run_quiet()` (zero callers), the
vestigial smoke-runtime-image.sh COPY in Dockerfile.package, and AGENTS.md's
claim of a `media_build_preamble_init` alias that does not exist.

Deferred to the post-chain batch (they touch files the running foreign chain
bind-mounts): A3 parse-table, A6 dir-walker unification, B5 smoke-runtime
decomposition. Full status in docs/refactoring-backlog.md.

## 2026-08-08 (afternoon) — Linux lane: the --no-push hole, and a forensic audit of "green"

### `--no-push` full-chain handoffs never worked on this host

The BuildKit **OCI worker keeps its own image store**: `nerdctl build -t`
loads results into containerd, which the next build's `FROM` never consults —
the mutable parent tag resolves against the **registry**. Every downstream
stage of a `--no-push` chain silently built on the last PUSHED parent. Proof:
a freshly built compiler shipped `/opt/gcc-16.2.0` while the sdk built "from"
it contained `/opt/gcc-16.1.0` (a months-old ghcr image); `FROM
repo@<containerd-digest>` errors "not found". Two full validation runs were
lost to this before the digest trail exposed it. Interim: push mode is the
only correct full-chain flow (docs updated, a warning fires at `--no-push`
parse time); real fix (OCI-layout build-context handoff, the runtime lane's
existing mechanism) is specced in the backlog. The manifest is protected by
running `--to-stage android` + the runtime lane with `--skip-manifest` until
all arches exist.

### A fifth shell bug class, found by auditing the helper scripts

Functions whose **last statement** is `[ cond ] && action` return 1 in the
healthy case; under `set -e` the guard tool kills itself. The flagship victim:
`verify-critical-fixes.sh` — the script guarding the Five Critical Fixes —
aborted after fix 1 **whenever the fixes were actually present**, silently
skipping fixes 2–9 and the summary. It only ever looked green because hosts
don't carry the staged payloads. Fixed there, in `smoke-common.sh` (the
"Unknown arch" guard was unreachable), and lint/preflight/NVIDIA-lane guards
in the same sweep.

### Forensic audit of the build logs: what "21/21 PASS" was hiding

Two-agent sweep over ~12 MB of logs, each claim re-verified:

- **Built 0.15.2, shipped 0.14.0**: the app's `uv.lock` outvoted the chain's
  freshly built `onnxruntime-genai` wheel (`--find-links` only OFFERS).
  Fixed (pre-install + `--no-install-package`), and genai added to the
  version-pin smoke so this class cannot recur unnoticed.
- **The libcamera pin was undercut at the finish line**: the media validator
  did not know meson's `lib/<multiarch>` install dirs, declared the build's
  own libs missing, and apt-installed Ubuntu's older libcamera as a shadow
  copy — a false-positive "repair". Fixed (multiarch dirs in the scan path).
- **ccache delivers zero in LLVM's nested sub-builds** (189 identical objects
  compiled twice, second pass 1.9% slower): `CROSS_TOOLCHAIN_FLAGS_NATIVE`
  forwards no compiler launcher. Plus: no ccache statistics are emitted
  anywhere — and the 2MiB step-log clip truncates **stdout only**, so stats
  (and anything that must survive) belong on stderr. Both queued.
- Still open, prioritized in the backlog: TVM ships import-broken (built
  against distro LLVM 22.1.2, not the pinned 22.1.8 — the telltale line
  prints at INFO), pyav is pinned but never installed, FFmpeg's TF/OpenVINO
  DNN backends died silently, OpenCV links distro GStreamer/FFmpeg due to
  stage ordering, three assertion-free fallback-PASSes, inner smoke warnings
  invisible to the outer verdict.
- Verified NON-issues (do not chase): "missing NVENC" is `ENABLE_NVIDIA`-gated
  by design; runtime Python 3.14.4 is Ubuntu's distro CPython as venv base
  (a decision, not a stale layer); "is not a commit!" clone warnings are
  annotated-tag peeling.

### Also — periphery audit (workflows, hooks, tooling)

A dedicated sweep over the never-audited edges. The flagship: the pre-commit
hook's sphinx gate pointed at a nonexistent `docs/source/` with the real error
swallowed — every commit on a hook-enabled clone failed; fixing the path then
exposed 12 real docs warnings under `-W` (10 orphaned pages now in an
"Operations & Reference" toctree, 2 unknown-lexer blocks) — the strict gate is
green end-to-end for the first time. Also fixed: deps.json's libcamera entry
now bound to `LIBCAMERA_VERSION` (the public license pages published
"git master" past yesterday's pin), the install-deps action's
dirname-of-empty-string putting `.` on GITHUB_PATH, a benchmark-viewer build
that reported success over a failed `npm build`, three unreachable FAIL
branches in the webserver flutter smoke, least-privilege `permissions:` on the
two unpinned workflows, SHA-pins for the last two mutable action refs, rename
coverage (`--diff-filter=ACMR`) and a loud git-grep failure mode in the hook,
and the license generator now fails on unknown versions.env vars and defaults
to check mode. Remaining periphery items are in the backlog.

### Also

- Owner priorities codified: AGENTS.md § Project priorities (speed AND
  stability AND tests, docs always in the same work unit), README
  § Engineering principles.
- buildkitd GC budget pinned (`~/.config/buildkit/buildkitd.toml`,
  gckeepstorage 500GB) + step-log-size drop-in (both effective at the next
  between-runs restart). Unexplained: base cache-missed after the first
  restart despite unchanged mounts and a surviving store — under
  investigation before cross-restart layer reuse is trusted.
- versions.env: 11 bumps (checksums from official sources), libcamera pinned
  for the first time (`v0.7.2` — the only media library that tracked master),
  OpenCV moved to the immutable `5.0.0` tag; ROCm deliberately HELD (new
  "TheRock" releases 404 on the old apt path); LiteRT-LM 0.15.0 verified to
  keep the protobuf 6.31.1 coupling.
- `latest-cross-amd64` shipped: full from-base chain in push mode with
  digest-pinned handoffs + live ancestry annotations; runtime smoke 21/21
  after a host containerd-shim failure was diagnosed (every `nerdctl run`
  died; builds unaffected) and the services restarted. The ancestry guard and
  the annotation-based `--verify-chain` verdicts had their first real-world
  successes the same day.

## 2026-08-08 — Windows lane: backlog cleared before the from-toolchain rebuild

The remaining four items, closed so the chain restarts against a tree with no
known open work. Two of them turned out to be blocked only by a third.

- **Warning floods cut at the source.** 16 % of a chain log (72 864 of 459 061
  lines) was four upstream constructs repeated thousands of times, which matters
  because buildkitd clips a RUN step's log at 2 MiB and then *deadlocks* it.
  Targeted suppressions, never a blanket `-w`: `-Wno-deprecated-copy` (OpenCV
  `matx.hpp`), `/clang:-Wno-unused-value` (ONNX), `-Wno-documentation-unknown-command`
  (TVM), and — because STL4037 is emitted by the MSVC STL headers themselves and
  no clang group can switch it off — `_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING`
  for IREE/MLIR, at directory scope where it survives LLVM's `HandleLLVMOptions`
  stripping. OpenCV's is safe for the CUDA path because the repo's own patch
  strips `-W*` before nvcc's `cl.exe` host compiler sees it (verified against the
  patch, not the comment above it). New `Measure-BuildWarnings.ps1` reports each
  family against its pre-suppression baseline, so the next run PROVES each flag
  still earns its place rather than it becoming folklore.
- **Smoke test split**, 1 573 → 1 386 lines, harness into
  `WindowsSmokeTest.Common.psm1` (no Dockerfile change — the final image already
  COPYs the whole modules dir). The move had one hazard and both halves of it
  fail silently: `Assert-Test` read `$ExitOnFirstFailure` out of the *calling
  script's* scope, which a module cannot see (the switch would have quietly
  stopped working), and the summary read `$script:passed`, which across a module
  boundary would have reported 0 passed / 0 failed and exited 0 on any run.
  Both are explicit state now. An AST inventory of every assertion call site is
  194 before and 194 after, identical as a set; 11 new tests, suite at 412.
- **Pre-commit hooks are enabled**, and the reason they were not is gone:
  `preflight.sh` used bare `python3`, which on this host is the Microsoft Store
  stub, so every commit would have failed for reasons unrelated to the commit.
  It now probes for an interpreter that can actually execute code.
- **Submodule pin drift** (`Kataglyphis-DocumANTation`, `UV_VERSION` 0.12.1 vs
  0.12.3) kept the version-snapshot check red, which is what blocked the hooks.
  Fixed and committed in that submodule; it still needs a push there plus a
  pointer bump here, left explicit because it is a different repository.

## 2026-08-08 — Windows lane: three gaps that could not fail loudly

Landed in the window a concurrent `versions.env` pin bump opened: `PYTHON_VERSION`
3.14.7 invalidates `Dockerfile.base` from its `COPY versions.env` down and every
media stage under the toolchain, so these changes cost no rebuild that was not
already owed. Each one is the same shape as the rest of this week's work — a
check that was structurally incapable of reporting the failure it existed for.

- **The FFmpeg `.pc` gate could not fail in its worst case.** It sat inside
  `if (Test-Path $ffPkgConfigDir)`, so a *missing* `lib\pkgconfig` — the most
  complete failure available — skipped every assertion without a word. Extracted
  to `Assert-FfmpegPkgConfig`, which treats an absent directory as fatal, and
  called outside that guard. Five unit tests, one per failure mode, reaching the
  function by AST extraction so it stays out of the three media branches'
  compile closure (the reason `Remove-MakefileShowIncludes` moved out of the
  shared module on 2026-08-03).
- **The base image's PATH had two dead entries and was missing a live one.**
  `SCOOP_HOME`/`SCOOP_GLOBAL` are scoop app *roots* and hold no executables.
  Meanwhile flutter is installed `--global`, so `C:\ProgramData\scoop\shims`
  exists and was on no PATH entry at all — a 2026-07-14 comment had removed it
  as a "never-created dir", which stopped being true the moment anything was
  installed globally. Invisible only because `FLUTTER_BIN` is baked separately;
  any future global package would have been unresolvable by name. Restored (user
  shims keep priority) and asserted by the smoke test.
- **An unresolved merge conflict had been committed** into
  `docs/refactoring-backlog.md` and survived several commits: two sections were
  appended concurrently and never merged. Markdown and shell lint both pass a
  conflict marker, because it is valid text. Resolved (content verified
  identical modulo the markers), and `.githooks/pre-commit` now greps the
  *staged* content for `<<<<<<< ` / `>>>>>>> ` — verified to fire on the exact
  commit that carried the bug. A bare `=======` is deliberately not matched: it
  is a legitimate Markdown setext underline, and real conflicts carry the others.
- **Nothing was linting the git hooks.** Writing that guard surfaced a live
  `SC1072`/`SC1073` parse error already sitting in `.githooks/pre-commit`: a
  comment starting with the word "shellcheck" reads as a malformed directive and
  aborts ShellCheck's parse of the whole file. It survived because
  `lint-shell.sh` filters to `*.sh` and a git hook cannot carry that suffix.
  Comment reworded, and `lint-shell.sh` now also accepts explicitly-passed
  extension-less files with a shell shebang — default sweep unchanged (223
  files), staged-file coverage gained, and the hook now lints itself.

Note: `core.hooksPath` is **unset** on the primary dev clone, so none of these
hooks have been running there — the documented one-time
`git config core.hooksPath .githooks` (AGENTS.md) is still pending, and is left
to the owner because it changes commit behaviour for every process writing to
that tree.

## 2026-08-08 — Linux cross lane: four bug classes, machine-checked ancestry, live caching

Driven by a from-base amd64 rebuild of `:latest-cross`, fixing every failure as
the chain hit it. The theme mirrors yesterday's: silent failure made loud.

### Four bash bug classes found live, fixed repo-wide, and lint-gated

1. **`trap … RETURN` leaks to the caller** — a RETURN trap set inside a
   function fires again when the CALLER returns, where the function's locals
   are gone; under `set -u` this killed `build-cross-chain.sh` AFTER every
   stage had succeeded. Three instances (parallel-loop, context-management).
2. **Unguarded pipelines under `set -euo pipefail`** — `du` on a
   not-yet-created cache dir aborted the orchestrator on FIRST runs; `readelf`
   on linker scripts, `dpkg -S` on unowned files, `find | head` SIGPIPE and
   friends would have killed the media validators mid-stage. ~10 sites.
3. **Comma-split loops break under `IFS=$'\n\t'`** — `for x in ${list//,/ }`
   runs ONCE with the whole list as one bogus element in strict-IFS scripts.
   Broke the GCC GPG key import AND would have killed the compiler stage's
   multi-target Python staging. New lint suite (`test-ifs-safety.sh`) bans the
   idiom; safe pattern is `IFS=',' read -r -a`.
4. **Vendor scripts sourced under `set -u`** — LunarG's Vulkan `setup-env.sh`
   reads `$1` unguarded and is sourced with explicitly cleared args; killed the
   sdk stage's TVM step. Vendor sourcing now suspends nounset and restores it.

### Cross-invocation ancestry is machine-checked now

Digest pinning only ever protected a SINGLE run. Every pushed cross stage now
records its parent's digest as an OCI manifest annotation
(`org.kataglyphis.parent-digest`); partial runs (`--from-stage` after base)
walk the recorded chain against the registry and hard-fail on a stale ancestor
(`linux/scripts/01-core/ancestry.sh`). `--verify-chain` gives real FRESH/STALE
verdicts from the same annotations. The old "after a compiler push start from
sdk" rule is enforced by the machine, not the reader.

### The GCC GPG failure was a key-rotation, not tampering

gcc-16.2.0 is signed by Richard Biener's key; the script pinned only Jakub
Jelinek's and reported the missing public key as possible tampering (with
SHA512 already OK). Now: accepted key SET, verdict via `gpg --status-fd`
(NO_PUBKEY → warn/skip per policy; BADSIG → fatal), signer checked against the
set so an arbitrary imported key cannot pass.

### Toolchain caching went from decorative to real

The ccache wiring was inverted: the GCC RUN mounted the cache but never exec'd
ccache; the LLVM RUN exec'd ccache but never mounted the cache. Fixed both,
plus `CCACHE_BASEDIR`/`SLOPPINESS` (without which per-target build dirs made
identical TUs never hit) and a multi-word-`CC` PATH fix for the Canadian path.
`--with-build-config=bootstrap-ccache` was PROPOSED and REJECTED — GCC 16
ships no such config (verified against the tarball). Per-target GCC builds can
now run concurrently behind `GCC_PARALLEL_TARGETS=1` (serial apt pre-pass,
divided JOBS, per-target logs; default off).

### Version pins: complete and current

`versions.env` audited for completeness (libcamera was the ONLY unpinned
media library — now `LIBCAMERA_VERSION=v0.7.2`, and the generated wheel stops
lying about its version) and currency (11 bumps incl. Python 3.14.7,
Node 26.7.0, OpenCV `5.x`→`5.0.0` tag = last non-reproducible media pin
closed; ROCm deliberately HELD — the new upstream releases 404 on the old apt
path). All checksums fetched from official sources; a new checker section
catches the case-mapped version literals the ARG checks could not see.

### Also

- `--no-push` validation runs no longer validate STALE registry images: the
  wrapper smoke pulled the published tag over the freshly built one, and the
  runtime handoff pulled `cross-android-<arch>` over the local build
  (BUILT_THIS_RUN now set on the local path too). Runtime chain failures
  propagate instead of reporting success.
- Disk preflight measures the cache dir's own filesystem (not its parent's)
  and survives first runs; `--final-image` is no longer silently overridden.
- apt.llvm.org 5xx no longer kills a multi-hour layer (falls back to source).
- Regression suites: `test-ancestry.sh`, `test-parallel-loop.sh`,
  `test-ifs-safety.sh` — auto-discovered by the pre-commit `script-tests` gate.

## 2026-08-07 — Windows lane: reproducibility, mandatory plugins, honest gates

The theme is less the repairs than what they have in common: several things had
been failing **silently** for months, so most of this work is about making
failure loud and early.

### Mandatory GStreamer plugins are a contract now

`libav`, `opencv`, `onnx` and `tflite` were absent from the published
`winamd64` image and nothing was ever red — meson's `auto` feature state means
*skip silently*, and the healthcheck printed `[PASS]` for plugins that did not
exist. Four **unrelated** root causes, diagnosed against gstreamer 1.29.2:

- **opencv** — OpenCV ships no `.pc` at all (confirmed: zero files in the built
  image). One is now authored, enumerating the import libraries from the real
  install (64 of them) instead of a hand-kept list that would rot.
- **onnx** — ONNX Runtime ships no `.pc` on any platform; one is emitted.
- **libav** — `subprojects/FFmpeg.wrap` *provides* the libav\* modules pinned to
  FFmpeg 7.1.1, and `-Dwrap_mode=forcefallback` **forced** meson onto it, so
  pkg-config was never consulted: the build fetched a second, older FFmpeg
  instead of the `n9.0` it had just built. The wrap is disabled before configure.
- **tflite** — consults no pkg-config at all. It probes the compiler for
  `tensorflow/lite/c/c_api.h`, the *pre-rename* path, while LiteRT ships the
  post-rename `tflite/` layout; an alias tree is staged. Confirmed in the field
  that upstream's first library name (`tensorflowlite_c`) does not exist here —
  only its fallback `tensorflow-lite`.

The set lives in `Get-RequiredGstPlugin` and is enforced at four points that
previously disagreed: a pkg-config pre-flight (checking version **floors**, not
just presence), meson features set to `enabled`, a post-install `gst-inspect`
gate that throws, and smoke-test assertions. `tensorfilter` is deliberately
excluded — it is an NNStreamer element this repo never builds.

### FFmpeg's .pc files were unusable

Found by probing the built image rather than waiting for the merge stage:
`Version: ..` (configure found neither a VERSION file nor git tags, because the
source is a GitHub auto-tarball) and MSYS-style `prefix=/c/…` paths that
clang-cl cannot resolve. The empty version alone kept gst-libav out,
independently of the wrap. Both fixed, and gated at the end of the FFmpeg stage.

### Reproducibility

- **LLVM, ninja and nasm pinned** (`LLVM_WINDOWS_VERSION`, …). The OS base was
  digest-pinned while the very next layer installed whatever scoop served that
  day — and five patches in this tree are written against a specific clang-cl.
  Asserted at base-build time.
- **`C:\toolchain-manifest.json`** records every pinned input as a pin/resolved
  pair plus the floating ones, so *which compiler built this image* is answerable
  from the artifact. It captures the MSVC toolset (14.51.36231) that floats
  inside VS major 18 and was previously recorded nowhere.
- **`versions.env` no longer invalidates the whole media chain.** It was COPY'd
  into the stage all three branches descend from, so three Windows-only pins
  re-ran all six media compiles (~90 min of ONNX among them). Versions now travel
  as build-args; the file is demoted to a gap-filler by a precedence rule that
  distinguishes a real build-arg override from a value merely inherited from the
  base image's machine environment.

### Gates that stop lying

- **Disk** is checked per stage, with floors calibrated against measured
  consumption, on every drive the build uses (not just `C:`), in **both** lanes.
- **The runhcs shim** is identified by the SHA256 recorded at install time
  instead of by file size; `deploy-shim-patch.ps1 -RecordCurrent` arms that
  without a redeploy.
- **The CNI conf must exist as BOTH `.conf` and `.conflist`** — buildkitd reads
  one, nerdctl the other, and "converting" between them cost a launched chain.
  The `.conf` is now *derived* from the `.conflist`.
- **Retries** stop immediately when a failure repeats byte-for-byte (a poisoned
  snapshot, whose remedy is `-NoCache` on that stage) but still retry
  snapshot-mount contention, which repeats verbatim and clears anyway. The merge
  stage's `-MaxAttempts 5` had been dead code, because its failure signature was
  never in the transient pattern.

## 2026-07-30 — Agentic loop: backlog-driven planner skip + completed-task pruning

- **Skip planner when tasks are pending** (`backlog.skipPlannerWhenTasksPending`,
  default `true`): while `BACKLOG.md` still has unchecked tasks, iterations go
  straight to the executor instead of paying for a planning pass.
- **Completed tasks are deleted from the backlog**
  (`backlog.deleteCompletedTasks`, default `true`): executor prompts now
  instruct deleting the finished entry (summary goes into the commit message),
  and a deterministic pruner (`remove_checked_tasks` /
  `Remove-CheckedBacklogTasks`) removes any lingering `- [x]`/`- [X]` blocks
  (title + indented body) before each auto-commit and at drain start.
  Completed work stays visible in git history instead of growing the file.

## 2026-07-30 — Agentic loop: live streaming output

- **Claude engine streams by default**: `claude -p` now runs with
  `--output-format stream-json --verbose` (config
  `engines.claude.streamOutput`, default `true`) and both libraries render
  the events live to console + log: session start, one line per tool call,
  assistant text per turn, tool errors, and a final
  `turns / duration / cost` summary. Set `streamOutput: false` to return to
  the silent text mode.
- **Bash opencode invocation streams too**: output is echoed line-by-line to
  console + log as it arrives instead of being buffered until exit (the
  PowerShell module already streamed).

## 2026-07-30 — Agentic loop: Claude Code engine + robustness

- **Engine abstraction** in both agentic-loop libraries
  (`linux/scripts/lib/agentic-loop.sh`,
  `windows/scripts/modules/WindowsAgenticLoop.Common.psm1`): `opencode` and
  `claude` (Claude Code CLI, headless `claude -p`) backends behind a single
  dispatcher (`invoke_agent` / `Invoke-AgenticAgent`). Selection via config
  `engine`, `AGENTIC_ENGINE`, or runner flag; model overrides via
  `AGENTIC_PLANNER_MODEL` / `AGENTIC_EXECUTOR_MODEL`.
- **Claude engine**: role system prompts via `--append-system-prompt-file`,
  planner sandboxed with `--allowed-tools`, executor permission mode
  configurable (default `bypassPermissions`), planner `--fallback-model`
  support.
- **Robustness**: retry with linear backoff per agent invocation, per-role
  timeouts (`plannerTimeoutSeconds` / `executorTimeoutSeconds`), build-failure
  fixer phase (executor-tier model gets the build log tail, then one rebuild),
  consecutive-build-failure cap that stops the loop, dry-run stall guard.
- **Shared loop features moved into the libraries**: planner-only /
  executor-only modes, max-iteration override, default phase prompts.
- PowerShell module: new exports `Resolve-AgenticEngine`, `Invoke-ClaudeCode`,
  `Invoke-AgenticAgent`, `Invoke-AgentProcess`, `Invoke-BuildFixer`,
  `Get-AgenticConfigValue`, `Get-AgentTimeoutForRole`; module version 1.1.0.
  Fixed the refactor planning cycle erroneously reusing the executor prompt.
- Pester suite extended to 38 tests (engine resolution, dispatcher, claude
  dry-run, engine-override loop smoke tests).
