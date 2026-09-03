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
(`bk-winarm64`, 2026-08-31). The 2026-09-02 dual-lane rebuild (post-wave
toolchain with sanitizers, rustup 1.29.1) reproduced both SMOKE columns exactly
— arm64 **97/0/15**, amd64 **222/0/0** (`bk-20260902-002412`); the other rows
below are the 2026-08-31 measurements and were not re-extracted.

| | arm64 cross (`bk-winarm64`, 2026-08-31, QNN ON) | amd64 native (`bk-20260826-130136`) |
|---|---|---|
| arch gate | **1168 binaries, 0 violations** (QNN payload rides in) | 1134, 0 |
| import walk | **793 files, 0 unresolved** (85 device-OS: FastRPC + client SKU) | — |
| bundle manifest | 7 DLL homes, **6 wheels**, 3 ABSENT markers | — |
| GStreamer contract plugins | **6/6** — `libav opencv onnx webrtc nice tflite` | 6/6 |
| smoke gate | **97 passed / 0 failed / 15 skipped** (floors 66/20) | **222 / 0 / 0** |
| QNN | EP ON in **onnxruntime only** (see #154); QAIRT 2.44.0 `aarch64-windows-msvc` runtime COPIED beside all five installs, but only ORT loads it | off (x64 CPU backend is pointless) |
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

- **#153 — the clipped-log forensics can never be re-audited; the corpus is gone.**
  INVESTIGATED 2026-08-31, and the premise I wrote was wrong. `out/windows-build-logs/`
  holds 92 `.log` files and **every one of them is from 2026-08-30/31** — 100 % post-fix.
  The 42 older run ids (bk-20260817-221952 … bk-20260829-140708) survive only as
  67-598-byte `*-manifest.txt` stubs; their step logs were pruned. So the 49-run
  analysis cannot be re-checked, only SUPERSEDED by future runs.
  What the surviving corpus does prove: the 2026-08-14 buildkitd env fix is live —
  **0 clip events in 90 logs**, and 12 individual RUN vertices now exceed the old
  2 MiB ceiling that used to truncate them. Treat every pre-2026-08-30 forensic
  conclusion in the archives as unverifiable, not as evidence.
  STILL OPEN, re-scoped 2026-09-02: the corpus now EXISTS — the two full dual-lane
  runs of 2026-09-01/02 (amd64 to 222/0/0, arm64 to 97/0/15) left complete
  per-stage logs, the first uncorrupted end-to-end set. Only the step-time /
  silent-retry sweep over them is still owed. NB for that analysis: every RUN in
  this corpus carries the ~7.5 min lost-notification lifecycle tax (441.3 s floor),
  and the two merge fan-ins each show the first-mount `ActivateLayer 0x20`
  self-heal (2 retries) — subtract both patterns before reading step times.

- **#155 — LiteRT QNN: the real flags, and why wiring them now would be a fourth
  silent no-op.** RESEARCHED 2026-08-31. DO NOT integrate before reading this.
  The genuine switches, all verified defined at v2.2.0:
  `LITERT_ENABLE_QUALCOMM` (`litert/vendors/CMakeLists.txt:330`, default OFF) and
  `QAIRT_HEADERS_DIR` (`:20`), where setting the headers dir AUTO-FORCES the former ON
  (`:331-334`). QAIRT is consumed as **headers only, at configure time** — no import
  libs, no link-time dependency; backends are `LoadLibrary`'d by name at runtime.
  NOTE `LITERT_ENABLE_NPU` (`litert/CMakeLists.txt:72`) is NOT the QNN switch: its only
  effect is a `#cmakedefine01` in `build_config.h`, and it does not gate
  `add_subdirectory(vendors)`.
  **Why it is not wired yet — five upstream defects, all Windows-specific:**
  1. The dispatch DLL **exports nothing** on Windows: the SHARED target sets no
     export macro, no `WINDOWS_EXPORT_ALL_SYMBOLS`, no `.def`. It would build green
     and be unloadable — exactly #154's failure mode, one level deeper.
  2. `-Wl,--whole-archive` / `--no-undefined` are passed on every non-Apple platform,
     Windows included; only `if(APPLE)` is carved out. GNU-driver syntax under lld-link.
  3. Both `dynamic_loading.cc` and `dynamic_loading_windows.cc` compile on Windows.
  4. The Windows branch of the vendor link lines is empty.
  5. `litert/vendors/CMakeLists.txt` does **three unconditional configure-time
     downloads** — NeuroPilot from AWS S3, and QAIRT **2.47.0.260601** from
     softwarecenter.qualcomm.com with no `EXPECTED_HASH` and no error check — whenever
     the corresponding `*_HEADERS_DIR` is empty. Two are escapable by pointing them at
     a dummy dir; the QAIRT one is escaped by setting `QAIRT_HEADERS_DIR` to our staged
     2.44 tree, which also stops the version skew.
  The `litert/` tree is also a SEPARATE top-level project (`project(LiteRT VERSION
  1.4.0)`), not a flag on the `tflite/` tree we configure — a second configure, and it
  pulls tflite in `EXCLUDE_FROM_ALL`, so `tensorflowlite_c` must be named explicitly.
  Upstream has never configured this tree for Windows: the only CMake CI is
  linux-x86_64/Android.
  **And the arch gate cannot prove any of it** — QNN backends are `LoadLibrary`'d by
  name, so a dispatch DLL adds zero static import edges. A green gate would mean
  nothing here.

- **#157 — ~2.33 GB of QNN payload ships for one consumer.** `Copy-QnnRuntime` copies
  the 35 backend DLLs (231 MB) plus seven `hexagon-v*` skel dirs (236 MB) into all FIVE
  framework install dirs. After #154 only ORT can load them. Removing the four
  redundant copies is a straight image-size win, but it moves the arch-gate binary count
  (1168) and the bundle manifest, so it needs a chain run to land. Measure first.

- **#158 — the 2026-09-01 audit wave: 13 verified defects to land AFTER the
  dual-lane run.** A 26-agent adversarially-verified audit (full narratives +
  fix sketches: CHANGELOG 2026-09-01) confirmed 17 defects; the two that could
  silently re-arm the 45 min teardown regression are already fixed
  (`apply-containerd-config.ps1` 45m default, host-setup § R1 recipe). The rest
  is DEFERRED because the container-side files are cache inputs of the running
  chain — apply them in **one closure window** so the re-key is paid once:
  - CRITICAL `build-buildkit.ps1:577` — forward `-TargetArch` to the
    `-ConcurrentAux` children (today: arm64+ConcurrentAux clobbers amd64 tags
    or merges stale trees, chain green).
  - `Dockerfile.media-merge-builder:301` — move the `DEPS_MIN_*` ARG/ENV block
    above the RUN that reads it; the wheel floors have been dead since landing.
  - `build-buildkit.ps1:751` — exempt `final-tar`/`final-push` labels from
    `-NoCache(-Stage)` matching (post-smoke export re-solves must be cache hits).
  - `build-buildkit.ps1:743` — register child-forwarded `-NoCacheStage` entries
    as matched in the parent (correct runs currently end red).
  - `build-buildkit.ps1:574` — refuse or re-plumb `-ConcurrentAux -NoSccache`
    (memory budget halving only exists via the webdav publish).
  - `build-toolchain-all.ps1:96` + `build-llvm-from-source.ps1:202` — actually
    call `Disable-ContainerWindowsUpdate` (docs promise it; the toolchain lane
    never runs it; a WU spool write kills the layer finalize).
  - `WindowsSourceBuild.Common.psm1:148` — capture the submodule-update exit
    code on the commit-pin path (TVM's real path).
  - `setup-new-host.ps1:214/249` — build from the PINNED fork branch with the
    5m env (not unpinned HEAD + the retired 45min constant patch) and assert
    the patched constant post-replace instead of failing open.
  - `rebuild-host-vhdx.ps1:253/282` — both rollback paths start services in
    stop order with swallowed errors (the measured 2026-09-01 bug, twice).
  - `Dockerfile.probe:39` / `Dockerfile.sccache-write-probe:51` — the probe
    lane mounts a deleted (#137) and an archived (9377c0ac) path; every
    `-ProbeScript` solve dies at checksum (mind `**/archive/` in .dockerignore).
  - `WindowsAgenticLoop.Common.psm1:418` — `ConcurrentBag` → `ConcurrentQueue`
    (captured output is documented API and currently LIFO).
  - Unverified majors to check while there: `build-onnx-genai-from-source.ps1:189`
    (no post-copy floor), `rebuild-host-vhdx.ps1:214` ($RECYCLE.BIN skews the
    copy-verify), `setup-new-host.ps1:351` (unguarded buildkitd restart).
  - 36 minors, dominated by fail-open error paths (nuget/scoop/git-lfs class) —
    sweep opportunistically, each with a mutate-the-guard test (standing rule).

- **#159 — archive the eight settled sccache/CUDA probes (814 lines).** Three are
  dead-by-construction (they mount the #137-deleted `sccache-nvcc-quote-fix`
  tree); none is referenced by a live doc. Move to `diagnostics/archive/`
  (pattern #127); re-point `Dockerfile.probe`'s default `PROBE_SCRIPT` and mind
  `**/archive/` in .dockerignore. Keep live: probe-onnx-tu-replay,
  repro-sccache-cuda-llm-deadlock, probe-build-copy, the write/video trios.
  Closure window — bundle with #158's probe-mount fixes.

- **#160 — compiler-rt mining recipe: contract drift across its three copies.**
  versions.env:478-483 promises verified-or-warn SHA for all three; only the
  LLVM copy implements it, and `setup-scoop-tools.ps1:311` also calls bare
  `tar.exe` (the documented GNU-tar `C:\`-as-hostname trap). Port the ~10-line
  verify+System32-tar block into the scoop and gstreamer copies (placement of
  the three copies itself is deliberate, #135 — not the finding). Closure
  window (re-keys base + merge branch).

- **#162 — versions.env full-copy couples the lanes: any Linux-only pin edit
  re-keys the ENTIRE Windows chain (~4 h machine time, measured).** base COPYs
  the whole 943-line file; toolchain consumes ~5 keys. Fix: base COPYs a
  generated Windows subset behind a sync-gate (inventory failure mode = #50's
  aftermath — helper reads like GIT_VERSION), toolchain keys become ARGs
  (#49/#103 pattern). One-time full re-key; do it as its own closure window.

- **#163 — `-ConcurrentAux` has never been used: ~24 min idle-capacity per full
  amd64 chain.** 43 manifests, zero concurrent runs; litert 3535 s + tvm
  1425 s always sequential; the 19 GB half-budget path works and no longer
  re-keys. Land AFTER #158's three ConcurrentAux fixes, then default it for
  full amd64 chains — owed measurement: litert at 19 GB must not exceed the
  hidden 1425 s (its bazel half grew 18→59 min since July).

- **#164 — patched-LLVM compile bypasses sccache (dead launcher gate).**
  `build-llvm-from-source.ps1:192` tests SCCACHE_DIR/SERVE which the
  toolchain stage never sets → every toolchain re-key pays LLVM cold
  (617 s + 1157 s within three days) while media-tvm compiles the same pin
  THROUGH sccache. Gate on `Test-SccacheRemoteConfigured`, add the
  SCCACHE ARG/ENV + logs cache-mount to the patched-llvm stage, forward
  `$sccache` from the driver. ~7-13 min per toolchain re-key. Closure window.

- **#167 — smoke gate is blind to the baked `C:\temp\scripts` surface.** The
  suite runs entirely from the bind mount; nothing exercises the shipped
  modules dir, the baked `smoke-test-container.ps1` the docs tell consumers to
  hand-run, or `healthcheck.ps1` (a lying healthcheck shipped green once,
  archive 08-31). Add a host-arch section: four baked files exist, module
  import from the in-container set works, healthcheck exits 0 (skip on
  pre-layout images). Closure window (cheap final-tail COPY re-key).

- **#168-#174 — comment-discipline wave (owner rule: 1-2 lines + doc link;
  ~170 comment lines move to docs).** Safe now: `Reuse.psm1:535` (#169 — the
  30-line transport essay in Get-Help serves consumers a fsutil form the docs
  declare broken/machine-wide; same rot in `test-layer-rename.ps1:142`),
  `Reuse.psm1:455` (#170 — dead `container-build-caching.md` link; FIRST add
  the 2026-07-20 os-error-3 diagnosis to the perf doc, THEN trim),
  `start-geniex-servers.ps1:9` (#171 — topology study duplicated and already
  drifting), `WindowsSlang.Common.psm1:16` (#173 — manifest schema defined
  twice). Closure window (cache inputs): `WindowsMeson.Common.psm1:32` (#168 —
  42-line essay fully covered by failure-modes.md),
  `normalize-tensorrt-tree.ps1:8` (#172), `build-litert-all.ps1:35` (#174 —
  lines 44-46 actively false since #128; fix the backlog's :79 line-ref in the
  same commit).

- **#175 — check while in the neighbourhood (unverified by the audit):**
  `build-opencv-gstreamer-plugin.ps1:7` (only comment find with NO docs home —
  needs a new subsection in windows-builds.md), `WindowsAgenticLoop.Common.psm1:1036`
  (executor drain-loop duplicated with exit-code drift — `-ExecutorOnly`, a
  consumer API, may report exit 0 on the build-failure cap: potential real
  bug), `build-buildkit.ps1:437` (halving formula duplicated; prework for
  #158's :574 fix). Plus the audit's low classes: driver-local structure
  cleanups (land with #158), free host-comment trims, docs staleness
  one-liners (build-lanes:789 stale ConcurrentAux deterrent, cross-builds
  status header), the genai-as-fourth-branch trade-off (4-18 min vs fan-in on
  the flakiest stage).

### Doc drift found by the LINUX-side docs audit 2026-09-03 (routed here, NOT verified on a Windows host)

A 14-agent currency audit ran over `README.md`, `AGENTS.md` and `docs/` from the
Linux side. Six confirmed findings land in Windows-lane files, so they were left
untouched there and are recorded here instead. **Each was verified only against
the repo tree — no Windows host was involved**, so re-check before acting.

- **`docs/windows-host-setup.md:12,17`** — points at
  `windows/scripts/verify-host-setup.ps1`, including a copy-pasteable
  `pwsh -File` command. The script is at `windows/scripts/host/verify-host-setup.ps1`.
  A reader following the doc gets "file not found".
- **`docs/project-info.md:46`** — locates the HEALTHCHECK script at
  `windows/scripts/healthcheck.ps1`; it is `windows/scripts/build/healthcheck.ps1`.
- **`docs/project-info.md:43`** — restates Windows media-stage versions (ORT
  1.27.0, GenAI 0.14.0, LiteRT 2.1.6, LiteRT-LM 0.13.1, TVM 0.25.0). All five are
  behind `versions.env`, and `AGENTS.md:681` says not to restate versions ahead of
  it at all — so the fix is to drop the numbers, not to refresh them.
- **`docs/project-info.md:40`** — "LLVM 22 via Scoop"; the pin is
  `LLVM_WINDOWS_VERSION=23.1.0`. Same rule: name the variable, not the number.
- **`docs/overview.md:23`** — lists `windows/Dockerfile.toolchain`; the file is
  `windows/Dockerfile.toolchain-builder`.
- **`README.md:202`** — "The Qualcomm QNN SDK (QAIRT 2.31.0)" while **the same
  sentence** says "(QAIRT 2.44.0, QNN API 2.33.0)" two lines later. A tree-wide
  grep finds `2.31.0` exactly once, here; `windows/qnn-sdk/README.md:44` and
  `docs/windows-cross-builds.md:711` both say 2.44.0.260225. This one is in the
  repo-wide README rather than a Windows file, but the fact is Windows-lane, so it
  was deliberately not "fixed" from the Linux side.

Also noted while checking: `docs/third-party-licenses.md` attributes the **Linux**
sccache patch series to `windows/upstream/sccache-nvcc-quote-fix/`. That is a
cross-lane attribution error in `docs/deps/deps.json`; the Linux sccache is the
unmodified Ubuntu apt binary. It touches a Windows path, so it is parked here too.

### CLOSED (pointers — full narratives in the dated archives)

- **#152** — the 2026-08-31 wave: PROVEN BY BUILD 2026-09-01/02. The dual-lane
  rebuild ran it for real, and the gate did its job: the wave's compiler-rt
  ride-along had set `COMPILER_RT_BUILD_SANITIZERS=OFF`, the amd64 smoke gate
  failed on exactly the ASAN probe, the fix (`=ON`) re-ran and the lane closed
  at the best recorded state **222/0/0** (`[PASS] AddressSanitizer …`,
  `clang_rt.asan_dynamic-x86_64.dll` installs verified in the toolchain log);
  arm64 closed green at its baseline **97/0/15**. The predicted re-pay was real
  (full LLVM + media on both lanes). Narrative: `CHANGELOG.md` § 2026-09-01/02.

- **#149** — the `c9586c1^` warm/materialize rollback recipe: DEAD, not stale.
  FOUR independent breakages (every script path, the missing TargetArch + Tvm
  modules, the swapped media-core order, the QAIRT pin). The restore recipe is now
  a derivation rule in `bk-warm.ps1:15-38` — derive each RUN from the stage that
  runs that script TODAY. Archive: `windows-backlog-archive-2026-08-31.md`
  § Resolved 2026-08-31 (second pass).

- **#154** — QNN is integrated in ONE framework, not five: TVM, IREE and LiteRT
  were passing CMake flags upstream never defined, so CMake dropped them silently
  while all three logged success. Flags and banners removed on both lanes; the
  class is gated by `Assert-CmakeArgsConsumed`. The surviving lead is #155.
  Archive: same page.

- **#156** — LiteRT-LM QNN: DECLINED with reasons (also a standing directive
  below). Archive: same page.

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
  copied beside all five installs — but only ORT consumes it (#154); arch gate 1168/0, smoke 97/0/15.
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
  so that would re-pay ~2 h of media compiles for one lib. Toolchain-level fix
  LANDED 2026-08-31 (`bd150ae1`, `Install-TargetCompilerRt` in
  build-llvm-from-source.ps1) and shipped with the 2026-09-01/02 toolchain
  rebuilds — the merge-stage self-heal is now the never-firing fallback.
  Nothing left here. Regression:
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
- **Do not re-propose QNN in LiteRT-LM** (#156, 2026-08-31). It is declined, not
  deferred. QNN only pays on arm64, where LiteRT-LM does not build (no windows_arm64
  Bazel config, no prebuilts, `build:windows --copt=/arch:AVX2` on every Windows
  compile, cpuinfo's `[restrict static 1]` under clang-cl). On x64 it is worse than
  pointless: **QAIRT ships no `QnnHtpV*Stub.dll` for `x86_64-windows-msvc`**, so there
  is no path to a Hexagon DSP at all. `litert_lm_main` also parses
  `--litert_dispatch_lib_dir` and never reads it, and the NPU models are EAP-gated.
  Re-open only if upstream ships a windows-arm64 target.
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
