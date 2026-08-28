# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in
[`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md);
everything CLOSED up to 2026-08-27 is in
[`refactoring-backlog-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md).
This file shows OPEN work only
+ CHANGELOG.md + memory — do not resurrect without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-28 (§ G + the § B riders added from the 2026-08-27/28
from-base run; CLOSURE WINDOW 3 still declared — see the 🎯 plan). LIVE
`:latest-cross` = WAVE-6 ship (a25a38c5/bd9953a9/d3710282, run id
20260823-223111-d0336283) — see § WAVE-6 SHIPPED.
**Windows items live in the SEPARATE Windows backlog** — this file is
Linux/cross-lane only.

## Standing rules (read first)

1. Never edit versions.env or the 01-core / 03-media bind-mount closure
   outside a closure window — one edit re-runs hours of media compiles.
2. Respect the protected lists (deliberate dedup, standalone bundling,
   load-bearing case arms, ARG sprawl, LiteRT-LM patch stack, SH1 retry
   semantics, SH2 non-exiting error(), DUPN2 two-pass arg mirror) —
   re-verified intentional across four sweep rounds.
3. Disk reclaim mid-run: prune-safe.sh → targeted rmi of pushed tags →
   NEVER system/image prune while a chain runs (removes TAGGED locals).
   SHARPENED 2026-08-21: `nerdctl system prune` ALSO wipes the buildkit
   store INCLUDING exec.cachemount records (35→1 observed) — even with no
   chain running it costs the compile caches. It is the last-resort hammer
   ONLY; prune-safe + rmi + kata-buildcache/archive-log trims come first.
4. Per-arch out/build-logs/*.log persist across runs — mtime-check before
   re-arming watchers.

## ✅ SHIPPED 2026-08-27 — and the audit that followed it

`:latest-cross` = index `a26bf2f4dbc8`, children amd64 `a0d1a144` / arm64
`2d354459` / riscv64 `7e0ed041`, run id `20260827-073226-d491cb10`. Freshness
VERIFIED against the registry: every index child matches its per-arch tag and
all three share this run's id.

The ship itself needed two rescues. The chain died after 5.5 hours on a QEMU
binfmt registration that the 2026-08-26 daemon restart had silently taken with
it — the guard for exactly that existed but sat AFTER the builds it protects.
Resumed with `--only runtime`, it then died again on an ARCH-PARITY arm that
correctly reported the IREE compiler wheel the same day's IREE fix had removed.

**Then two audits read the result rather than the code, and between them found
24 defects** — of which 22 were fixed, one refuted, and one retracted as my own
measurement error. The ones that had SHIPPED: Dockerfile.package expanded two
prefixes to empty inside their own ENV, so PATH carried `/bin` twice and
GST_PLUGIN_PATH pointed at `/lib/gstreamer-1.0`; the Android ONNX Runtime
carried Microsoft's 1DS telemetry because only the native lane passed
`--no_telemetry`; amd64 alone shipped a setuid-root gst-ptp-helper; Node.js was
an alpha its own npm refuses; and TVM had been missing from both cross arches
behind four stacked causes.

Three gates were reporting success over things they never tested, and are
fixed: `check_ffmpeg` fell back to an absolute path exactly when PATH
reachability broke, the app-wheel smoke printed one identical PASS over 15/15,
14/15 and 12/15, and the shipped-content byte gate hid behind a boot smoke so
riscv64's wrapper reached the index unchecked.

### The previous entry, for the record

**WAVE-6 SHIPPED 2026-08-24** (the gate-truth build — three blind gates now actually work)

`:latest-cross` = amd64 `a25a38c5` / arm64 `bd9953a9` / riscv64 `d3710282`.
Run id `20260823-223111-d0336283` — and for the FIRST time that is a
verifiable statement: all three wrappers carry it as an image LABEL, read back
from the REGISTRY (not the local store). cv2 GStreamer:YES + FFMPEG:YES holds
on the new bytes. Runtime smokes 0 failures x3.

**What this build proved** (each had been silently broken for months):
  - **XC3** — provenance is written and READ. `per-arch wrapper generation check:
  OK` with NO "carry no run-id" warning (it was 3/3 in every prior run), and
  `[ancestry] android→wrapper (<arch>): OK` with real digests on all three.
  The label also says *android*, confirming the XC2-STAGE fix: the writer
  stamped android while the check resolved "package", which would have thrown a
  false STALE ANCESTOR on every run the moment provenance returned.
  - **AP4** — `AP4 strip verified: libavcodec.so.63.1.100 has no .symtab`.
  Every previous ship printed `check skipped (could not extract ...)` while the
  wrapper gate said PASS: `tar --occurrence=1` exits early, SIGPIPEs the
  exporter, and pipefail turned that into a failure.
  - **SMK1** — the cv2 media assert is hard on all three arches.
  - **CERB-CACHE** — validated the hard way. wave6a lost all three lanes to five
  freedesktop 503/404 flaps, but the cerbero state survived (15.7 GB / 14.5 GB
  on the cachemounts); wave6b restarted WARM (`HIT: resuming ... 13G / 20G`)
  and completed with ZERO fetch failures. Before this, wave5k and 5l discarded
  the full ~50-minute bootstrap on every flap.

**Wave-5 (2026-08-23, superseded):** amd64 `54ab7f01` / arm64 `7bb70a4b` /
riscv64 `fb701200` — first ship with cv2 GStreamer+FFMPEG on 3/3 arches, and
the ship whose post-audit found the three gates above.

## 🎯 CLOSURE WINDOW 3 — PRE-BUILD WAVE DONE 2026-08-27, rebuild still owed

STATUS as of 2026-08-27: the pre-build wave is worked through. Preflight is
32/32 with a real exit code of 0, 27 unit suites / 677 assertions green,
shellcheck clean over 263 files, and the backlog is down from 46 open entries
to 30. versions.env stays OPEN until the validating rebuild runs.

Two fixes in this wave are proven by EXECUTION, not inspection: TVM now
compiles and stages its arm64 wheels (four stacked causes, each only visible
once the one before it was fixed), and `PartOf=containerd.service` was tested
against a real `systemctl --user restart containerd` — the unit re-ran in the
same second and both emulators still answered, so the failure that cost this
morning 5.5 hours now self-heals.

What the rebuild still has to prove is everything static analysis cannot: today
showed three separate times that a defect only becomes visible after the one in
front of it is gone.

### Original declaration (2026-08-24)

The operator has committed to a fresh build, so the versions.env lock is OPEN
and build-validated items are IN SCOPE. Work the wave in this order; the
rebuild then validates everything at once (that is the whole point of a
closure window — ONE rebuild pays for all).

**Phase 0 — host prep (no-build window, do FIRST):**
## F. Refactor candidates found while switching ccache -> sccache (2026-08-26)

Collected DURING the switch and the staged rebuild, each with the evidence that
produced it. None of these blocks the current run; they are the debt the switch
either created or exposed.

- **LOG19 — the media lane reports zero cache telemetry, and the report is
  truncated where it counts** [S·★★, from the 2026-08-27/28 run; BLOCKED until
  the running runtime stage ends — compiler-cache.sh is inside its live
  bind-mount closure, DO IT FIRST once it does] All 72 sccache stats blocks
  across the three media logs say `Compile requests 0`: they are printed at
  t≈0.165 s as the last act of `setup_ccache` (01-core/compiler-cache.sh:191-203),
  i.e. before the first object. On top of that, `head -12` (:201, likewise
  build-gcc.sh:737, probe-sccache.sh:141, 03-media/core/common.sh:147) cuts off
  exactly the lines that matter (`Non-cacheable compilations`, `Unsupported
  compiler calls`) — positional slicing over a variable-length report. Action:
  a post-build `--show-stats` at the end of each media step (the seam exists at
  03-media/core/common.sh:147), select lines with `grep -E` instead of `head`,
  and WARN on `requests > 0 && hits == 0`. Until this exists, both the entry
  below and the documented Rust re-enable (build-cache-tiers.md:455: "judge it
  by the stats line") stay undecidable.
- **sccache caches NOTHING in the OpenCV step** [M·★★★, OPEN 2026-08-26] The
  TryCompile root cause is fixed and the guarded launcher keeps the build alive
  (1451 saves, 0 aborts), but in the opencv step sccache fails on EVERY compile
  — now with the main build dir `/tmp/opencv-1/build` as cwd, not a deleted
  scratch dir. So OpenCV builds fully UNCACHED while every other step caches
  normally. The guard makes this survivable and VISIBLE; it does not fix it.
  Do not re-run these nine disproven hypotheses: missing compiler; dangling
  update-alternatives (never ran in that stage); apt reinstalling sccache
  (it did not); the two sccache versions (0.13 apt vs 0.17 pinned — both work,
  PATH prefers the pinned one); our own `rm -rf` (targets iree-build-HOST);
  a cleared environment; the custom-prefix GCC without LD_LIBRARY_PATH; a
  214-variable environment plus a 120-flag command line; memory or disk
  pressure. Also note an out-of-band `nerdctl run` repro is NOT faithful — it
  cannot recreate BuildKit cache mounts and produced a phantom google-benchmark
  regex failure that appears in no real chain log.
- **The compiler-cache abstraction is split across seven places** [L·★★]
  compiler-cache.sh:4-8 already warns "the 02-toolchain GCC/LLVM builds do NOT
  source this module ... that misread hid a dead ccache mount for months". The
  sccache switch had to touch build-gcc.sh, build-clang.sh, llvm-cross.sh,
  compiler-cache.sh, cmake-cache-linker.sh, build-app-wheelhouse.sh and the
  onnxruntime build lib SEPARATELY, and one of them (cmake-cache-linker.sh, a
  SHARED helper) would have silently overridden the switch for every consumer.
  Consolidate onto one resolver; the launcher helper is the seam to build on.
  Three more call sites, from the 2026-08-27/28 run: build-ffmpeg.sh:381-390
  and build-pyav.sh:169-176 hardcode `ccache ${CC}`, so sccache is never asked
  (`media-amd64.log:111146 "Using ccache for faster compilation"`); three
  places write bare `sccache` instead of the launcher and go live the moment
  someone flips the switch (build-opencv.sh:591-593,
  30-build-native-nvidia.sh:195-197, 30-build-native-amd.sh:65-67 — all under
  `ENABLE_SCCACHE_CUDA`, default 0); and TVM's step exports NO launcher at all,
  so upstream's `USE_CCACHE=AUTO` decides (`media-amd64.log:1670`). Also:
  verify-critical-fixes.sh:220-237 checks compiler-cache.sh only — pull that
  pattern repo-wide. (The earlier "TVM/XNNPACK/vvdec cost 1.9 h" theory is
  refuted: they are cache hits, just in the wrong cache.)
- **Two compiler caches are now installed and mounted** [M·★★] ccache stays as
  the fallback for invocations sccache refuses, so every stage carries both
  mounts (5/5, 1/1, 13/13, 3/3) and the ~27 GB warm ccache still occupies disk
  while contributing nothing. DECIDE after the switch is proven: drop ccache and
  delete the fallback branches, or keep it and document why. Do not leave it
  ambiguous -- ambiguous is how the dead mount survived months last time.

## G. Mined from the 2026-08-27/28 from-base run (media + android lanes)

Post-ship audit of run `20260827-200128-a20ab922` (per-stage logs under
`~/build-logs/archive/20260827-200128-a20ab922/`). Its seven fix-now findings
are fixed; LOG8-LOG18 are what was left, in the post-mortem's B1-B12 order
minus B8, which is appended to the § F compiler-cache entry instead of being
duplicated here. Nearly all of these sit in the 03-media / android bind-mount
closure, so they are ONE closure window's work.

- **LOG8 — the locked apt mounts serialize the entire intra-lane fan-out**
  [M·★★★, OPEN 2026-08-28] Seven media head vertices are scheduled together and
  then run strictly one after another; riscv64 handover chain `opencv
  0.2→106.3 · onnxruntime →159.0 · app-wheelhouse →1718.3 · ffmpeg →2070.1 ·
  litert →2172.3 · armnn →2172.4 · tvm →3259.4`. litert, the longest downstream
  chain, got the lock LAST — ~33 min of pure waiting on the critical path;
  android has the same shape. NOT max-parallelism=4: onnxruntime 2/9 and opencv
  2/3 ran concurrently, and neither mounts apt. Action: (i) shorten the hold —
  tvm and app-wheelhouse do apt AND a 15-25 min compile in ONE RUN (`#28 94.14
  apt … #28 DONE 1030.2s`) while litert/opencv/ffmpeg have split them for
  ages; (ii) per-STAGE mount ids (leaves PAR2 alone, that is the lane axis).
  The cheap slice is already taken — the armnn no-op now has its own ids
  (Dockerfile.media:654-655). ⚠ The lock has been doing PAR4's job unnoticed:
  peak was 43.6 GB used / 18.5 GB free with only tvm+litert live. Needs a
  memory plan, not just the lock removed.
- **LOG9 — arm64 GStreamer builds without introspection although its qemu
  wrappers exist and are generated** [M·★★, OPEN 2026-08-28]
  `media-arm64.log:194734 "ARM cross build: disabling introspection
  (g-ir-compiler needs qemu exe_wrapper)"` → `:196446 introspection :
  disabled`; artifact proof is the `.typelib` count 47 / **0** / 38.
  build-gstreamer-monorepo.sh:296 disables unconditionally for `aarch64*|arm*`,
  while pre-setup.sh creates the four arm64 wrappers (:254-260) and qemu-user
  for arm64 AND riscv64 — the riscv64 block (:252-282) lifted exactly this on
  2026-08-21. Action: mirror that block, `[ -x … ]`-gated, and measure success
  by the `.typelib` count, not by the flag.
- **LOG10 — riscv64 OpenCV ships with no RVV at all, and the only written
  statement in the repo claims the opposite** [M·★★, OPEN 2026-08-28]
  `media-riscv64.log:1719-1722 "HAVE_CPU_RVV_SUPPORT - Failed"` directly after
  `"HAVE_CXX_MARCH_RV64GC_V - Success"`, then `:1916 "RVV HAL: RVV is not
  available, disabling RVV HAL"`, seven `Excluding … *.rvv.cpp` DNN kernels,
  `Custom HAL: NO`, `Baseline:` empty / `requested: DETECT` (DETECT detects
  nothing in a cross build). The Linux path sets neither CPU_BASELINE nor
  WITH_HAL_RVV; the only mention anywhere is opencv/android/build-android.sh:39,
  whose reasoning ("the Linux riscv64 OpenCV keeps RVV under GCC") is simply
  false. Action: DECIDE the hardware posture (V or not) and write it down
  first, then `-DCPU_DISPATCH=RVV` + `-DWITH_HAL_RVV=ON` (baseline stays
  rv64gc). The flag is untested — the decision is the deliverable. Fix the
  false comment either way.
- **LOG11 — OpenCV gets TBB on amd64 only; arm64/riscv64 fall back to
  pthreads** [S·★★, OPEN 2026-08-28] `-DWITH_TBB=ON` is unconditional
  (build-opencv.sh:433), but `libtbb-dev` lives in `install_deps_preamble`
  (host) instead of `target_packages`, so the cross lanes visibly pull the
  **amd64** package: `media-arm64.log:20439 "Get:6 … amd64 libtbb-dev amd64
  2022.3.0-2"` → `Parallel framework: TBB` vs `pthreads` ×2. The presence gate
  iterates `target_packages` only and therefore reports "all 14 requested
  target dev packages present". Action: either into `target_packages` (via
  `install_optional_target_packages`, then re-check the new `libtbb.so.12`
  closure) or set WITH_TBB per-arch and log the pthreads choice out loud —
  every other cross exclusion in that file is commented and logged. Assert
  `Parallel framework` in the runtime smoke.
- **LOG12 — ArmNN ships the reference backend only; the whole ACL wiring is
  inert** [M·★★, OPEN 2026-08-28] `media-arm64.log:15264-15269 "CL backend is
  disabled" / "NEON backend is disabled" / "TOSA Reference backend is
  disabled"`, and the proof that ArmNN never read the ACL variables:
  `:15283-15287 CMake Warning (unused-cli): ARMCOMPUTE_BUILD_DIR /
  ARMCOMPUTE_LIBS / ARMCOMPUTE_ROOT`. build-armnn.sh:61-73 passes no
  `-DARMCOMPUTENEON=1` / `-DARMCOMPUTECL=1`, yet ACL is rebuilt every run
  (`#33 DONE 408.6s`). Action: a DECISION, not a flag — nothing in the repo
  consumes ArmNN (the ORT EP is gone upstream, 30-build-native.sh:89-92). Turn
  the backends on (a real ACL cross-link break may then surface — that would be
  the actual news) or drop the ACL build plus the `ARMNN_VERSION`/`ACL_VERSION`
  pins. As it stands it is 7 min/lane for an artifact with no consumer.
- **LOG13 — the android stage does not know sccache exists; android-iree caches
  nothing** [M·★, OPEN 2026-08-28] 0× `COMPILER_LAUNCHER` in all four android
  logs, and "sccache" appears only as the mount declaration
  (Dockerfile.android:207,234,261,288,317) — android-build-preamble.sh:7-27
  never sources compiler-cache.sh. Four of the five libs still cache anyway,
  because `CCACHE_DIR=/var/cache/ccache` is inherited (Dockerfile.base:86) and
  the vendored projects find `/usr/bin/ccache` themselves; genuinely uncached
  is only **android-iree** (524 s amd64 / 386 s arm64). Action: export
  `compiler_cache_launcher` from `android_build_preamble_init` — the five RUN
  blocks must stay byte-identical (verify-android-stage-parity.sh,
  Dockerfile.android:41-42).
- **LOG14 — the cross SDK lanes build host x86_64 Vulkan components nobody
  consumes** [M·★, OPEN 2026-08-28] `sdk-arm64.log #17` runs `68.4 → 657.3`
  before `"[INFO] Cross-building Vulkan loader for aarch64"` appears, with 345
  `Installing: /opt/vulkan/1.4.357.0/x86_64/…` lines (riscv64 identical; amd64
  `#17 DONE 44.1s`). Part of it is required — the clones fill
  `source/SPIRV-Tools|glslang|Vulkan-Loader` that `_build_vulkan_targets`
  needs. Actually trimmable: ValidationLayers (153 s), shaderc (109 s),
  SPIRV-Cross (57 s), Profiles (26 s), ExtensionLayer/volk/VMA/SPIRV-Reflect
  (~45 s) ≈ **390 s/lane, ~13 min/run**. Action: those components into the
  `_vulkan_skip` map under `cross_build_enabled` (vulkan.sh:290-297). The proof
  that is still missing first: diff the amd64 image's `/opt/vulkan/<ver>/x86_64/`
  against a trimmed arm64 image.
- **LOG15 — android OpenCV: `-DBUILD_JAVA=ON` produces no Java wrappers**
  [S·★, OPEN 2026-08-28] `android-amd64.log:2493 "Unavailable: java python3
  ts"`, `:2553-2554 "ant: NO" / "Java wrappers: NO"` — because
  opencv/android/build-android.sh:57 `BUILD_JAVA=ON` sits directly above `:58
  BUILD_ANDROID_PROJECTS=OFF`, and android consumers reach OpenCV through
  JNI/Java. Action: make one of the two sides true and assert on `Java
  wrappers:`. (NOT "a JDK installed for nothing" — the JDK comes from the
  inherited android-sdk stage; what is wasted is 2.1 MB of `ant`.)
- **LOG16 — `CMAKE_POLICY_VERSION_MINIMUM=3.5` as eight literals in six files
  while the floor keeps moving** [S·★, OPEN 2026-08-28] Only the ONNX lane
  parametrizes it (onnxruntime/build/lib/common.sh:98); the other eight are
  hard: build-litert.sh ×4, litert/android/build-android.sh,
  iree/android/build-android.sh, cross-env.sh, build-app-wheelhouse.sh. The
  logs already carry 109× `Compatibility with CMake < 3.10 will be removed`.
  Action: `CMAKE_POLICY_FLOOR` in versions.env, one helper, eight
  replacements, a lint-shell tripwire on bare literals. Breaks loudly, not
  silently — hence low priority.
- **GCC_HOST_BOOTSTRAP — not new, but now quantified** [decision owed] NOT a
  new item: an update to the "NOT TAKEN this round (offered, user deferred) —
  still open" toolchain-speed line in
  [`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md).
  The bootstrapped host GCC is the chain's largest uncacheable block: first
  stats snapshot `compiler.log:30686-30692` = **6.63 % hit rate** (110 hits /
  1548 misses), after all five GCCs `:84500-84509` = **88.56 %** — the miss
  count never moves again after the native build, the four cross GCCs are 100 %
  hits. `#10 DONE 2352.3s`, of which ~1231 s is stage2+stage3. The proposal
  (`GCC_HOST_BOOTSTRAP=0` for validating rebuilds, `=1` only when the GCC pin
  moves) has sat there since 2026-08-10; only the number is new. Decide it or
  strike it there.

## A. Window inventory — A1 needs WORK in the wave, A2 is validated by the rebuild ALONE

### A1. Work items (all referenced by the phase plan above)

- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; _cross_stage_build_impl;
  build_iree_wheels; parse_options 116-liner; modules.sh dir-walker.
- **TG1 residual — fuller toolchain-closure trim** [M·★★] llvm-cross/
  llvm-validate lazy + true per-RUN closures; no COPY fallback → needs a
  per-RUN mount audit + real toolchain rebuild.
- **TG3 residual — collapse the two toolchain RUNs** [S·★, NEEDS THE REBUILD — see phase 3: "implement + adversarial review + the rebuild as the only accepted proof"] RUN-3d recompiles
  instead of reusing RUN-3 (ccache absorbs, ~97s); pairs with TG1.
- **LOG2 open half — build the wasm asyncify/jspi flavors** [S/M·★★] so
  onnxruntime-web ships its webgpu JS backend (exclusion is documented in
  versions.env since wave-3; this is the build half).
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.
### A2. Already landed, validated by the rebuild alone (watch, no work)

**Added 2026-08-26 (pre-rebuild wave + its adversarial review, commit 9a86d2f
— static review only, NO build has exercised these):**

- **BKD1 — buildkitd session rot: RESEARCHED, no upstream fix exists** [M·★,
  downgraded from ★★ 2026-08-24; host figures refreshed 2026-08-26] host runs
  buildkit **v0.31.2** (nerdctl 2.3.5, containerd 2.3.3) since the 2026-08-26
  upgrade — see Phase 0. The session rot is UNAFFECTED by that upgrade. The symptom IS a known open upstream issue —
  moby/buildkit#6422 ("no active session … context deadline exceeded", open,
  no linked PR) and #5624 (same class during cache-export registry auth) —
  and NO release through v0.32.2 (2026-08-04) mentions a session/keepalive
  fix. VERDICT: keep the restart playbook (stop chain → restart
  buildkit.service → relaunch; cachemounts survive) — this is still the cure
  and the upgrade did not change that. The concurrency rider is now PARTLY
  taken: #6916 (daemon crash under concurrent builds) came with v0.31.2;
  **#6955 (parallel-build cache miss) did not** — it needs v0.32.0, which no
  nerdctl-full bundle ships. Do NOT chase it by installing buildkit outside
  the bundle: the pieces are version-matched. Re-open when a nerdctl-full
  carries 0.32.x.

## B. Next PIN-BUMP window (versions.env riders — NEVER alone)

- **LOG17 — lift the Android AGP/Gradle versions into versions.env** [S·★,
  watch, from the 2026-08-27/28 run] `android-arm64.log:5996 "Deprecated Gradle
  features were used in this build, making it incompatible with Gradle 9.0."`
  (+ a `docs.gradle.org/8.7/` link). The AGP version lives inside
  patches/onnxruntime/001-android-gradle-agp8-compat.patch:10,37
  (`com.android.tools.build:gradle:8.3.1`), so `grep -i gradle versions.env` is
  empty and `bump_versions.py --check` can never see it. Action:
  `ANDROID_AGP_VERSION` / `ANDROID_GRADLE_VERSION` into versions.env; run once
  with `--warning-mode all` so the log names WHICH features. No silent break —
  apply-patch.sh:60-68 fails loudly.
- **LOG18 — CPython falls back to bundled libmpdec on all three arches** [S·★,
  rider, from the 2026-08-27/28 run] `compiler.log:121643-121644 "no system
  libmpdec found; falling back to bundled libmpdec (deprecated and scheduled
  for removal in Python 3.16)"`, three times (host/arm64/riscv64).
  `_CPYTHON_EXT_DEV_PKG_TABLE` (01-core/cpython-dev-packages.sh:31-49) has no
  `libmpdec-dev` row — the same gap the table was built for after the
  libsqlite3-dev incident. Harmless today (3.14.7 pinned, 3.16 is ~Oct 2027)
  and the row is NOT free: it flips all three arches from bundled-static to a
  dynamic `libmpdec.so`, i.e. a byte change with so-package-map consequences.
  Hence a rider, and the file is inside the 01-core closure.

## C. Orchestrator lifecycle (one coherent PR)

- **--no-push OCI-layout handoff + dual-path collapse** [M·★★] --no-push
  builds resolve parents against the REGISTRY (two runs lost historically).

## D. CI / infra / cache tiers (own triggers)

- **S3 — per-stage registry cache refs: operator DECLINED 2026-08-24**
  [decision recorded] design stays at docs/build-cache-tiers.md (DESIGN ONLY
  banner); cost ~12-13 GB registry upload per run was judged not worth it
  while prune-safe + local caches hold. Re-open ONLY on new evidence (another
  cold-rebuild loss). v1 implementation history: reverted twice (fix7 gate
  token; inert-by-default with no coverage) — read the doc before any retry.
## E. Waiting on a TRIGGER (not on work)

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS validation** — ⚠ the stated trigger has ALREADY
  passed TWICE without validating anything: the flag defaults to 0, so the
  2026-08-24 and 2026-08-25 compiler rebuilds both took the sequential path.
  It is not waiting on a rebuild, it is waiting on someone putting
  `GCC_PARALLEL_TARGETS=1` on the LAUNCH COMMAND. Do that or it will be missed
  a third time.
- **gcc-prereq measurement facets** (sig-cache, LIBRARY_PATH leak, verify
  coverage, dup-compile overlap) — needs ccache stats from a real build;
  the "unify prereq paths" reading is CLOSED (deliberately different).
- **post-restart base cache-miss** — observe at the next host reboot.
- **LOG7 — sdkmanager CLI deprecated** — bit-rot watch before Google
  removes it.
- **MESON-GI — meson 1.12 breaks g-i-1.84 glib-subproject resolution
  (riscv64 cross gst)** [S·★, watch] falsified the RV1-poison theory in
  wave5: reproduces with a clean sysroot. Scoped pin meson==1.11.2 in
  setup-gstreamer.sh for riscv64 cross only. Re-bump when upstream
  meson/g-i fix the `subproject('glib')` resolution — retest by removing
  the pin in a closure window.
- **NODE-RV — riscv64 ships Node v22 (pin: 26.8.1)** [S·★, watch] ubuntu-ports
  has no 26.x for riscv64; the install falls back fail-open with a WARN (by
  design, seen in every wave-4 smoke log). Lift when ports ships 26.x —
  check via `apt-cache policy nodejs` on the ports snapshot at each bump
  window; until then the riscv64 image runs the distro v22.
  NB (2026-08-27): the pin moved 26.8.0 -> 26.8.1 because the OFFICIAL
  v26.8.0 tarball self-reports `26.8.0-alpha.0.0.0` and its own bundled npm
  then refuses it (semver puts a prerelease outside `>=22.9.0`). Re-check the
  reported version, not just the tarball name, at every bump — the gate that
  missed it compared a PREFIX and has since been tightened to an exact match.
- **SV-residual — watch the first real `compose up`** — user-side.
- **riscv64 isa-spec smoke on real hardware** — needs hardware.
- **WEBUI_SECRET_KEY server-side rotation** — user action.

## Verdicts (anti-re-sweep records — do NOT re-audit without new evidence)


- **S5 — shared cargo cache ids: DECLINED, premise falsified 2026-08-26.** The
  entry claimed "cargo cache ids arch-independent". They are not: the media
  lane uses `id=cargo-registry-${TARGET_ARCH}` / `id=cargo-git-${TARGET_ARCH}`
  (Dockerfile.media:857-858), i.e. already per-lane BY DESIGN since PAR2. The
  3x crate duplication is the accepted cost of lane isolation. Re-open only
  with new evidence that cargo guards a shared store safely.
- **PAR5 — a lone surviving lane stays throttled; the obvious fix is
  DISPROVEN** [S/M·★★, tried and REVERTED 2026-08-23] symptom unchanged: a
  single remaining wheelhouse crawls at 1-2 jobs for HOURS while the host
  idles (wave4f arm64, wave5h riscv64). DO NOT re-attempt the flag-dir
  live-lane-count approach that this entry used to propose — it was built,
  reviewed and reverted: BUILD_MEM_DIVISOR is a build-arg consumed as
  `ENV BUILD_MEM_DIVISOR` when the container build STARTS, so it cannot
  change while that build runs; the clamp could not fire at all in the
  shipped topology (all lane markers exist before any lane retires), and
  where it could fire it made the divisor depend on sibling timing and
  could drop the intra-step multiplier entirely (6→1) — an overcommit in
  exactly the direction PAR4 exists to prevent. A tripwire in
  test-stage-defs.sh now fails if flag-dir state is wired back into the
  divisor. Achievable options only: PAR4-hard (a host-level memory
  governor: systemd-run MemoryHigh per build, or a global compile-job
  server), or re-sizing at container-build/STAGE boundaries. Full verdict
  in docs/build-parallelism-memory-tuning.md.


- **Nondeterministic file-picks (2026-08-22, PKGCFG-MIRROR post-mortem)**:
  any `grep -rl … | head -1 / grep -m1` that CHOOSES a file to patch is
  readdir-order dependent — it can pick a different file inside the
  container than on the host and still echo success. The v1 pkg-config
  mirror override did exactly that (patched a stray .patch file, cold
  bootstraps kept 404ing) while the host reproduced "correct". Rule: patch
  the KNOWN path explicitly, treat the grep as a supplement, and echo the
  RESULT (the patched line) as proof, never the intent.

- **CI sweep (2026-08-17)**: CI1-3 fixed same day (timeouts, ollama
  digest-pin, env-var login); otherwise CLEAN.
- **Idempotency / GST1 runs-twice class (2026-08-17)**: CLEAN — only
  install-deps + configure-runtime run twice, both second-run-safe; this
  section is the checklist for any NEW double-run path.
- **Bump-tool (2026-08-19)**: BT1+BT2 fixed same day (spec_vulkan SHA,
  artifact-gating, empty-download rejection).
- **A1 allowlist (2026-08-18)**: 148/148 knobs have live readers.
- **onnxruntime 1.28-vs-1.27 (2026-08-15)**: NO source dedupe to do —
  runtime __version__ quirk, already asserted as a union in the smoke;
  residual folded into C3.
- **Version-ARG mirrors / dead stages / USER-ordering (2026-08-17 sweep)**:
  zero drift, clean.
- **Coverage map (2026-08-10, unchanged)**: chain swept end-to-end across
  six rounds; thin spots = GPU lanes, Windows psm1 (sampled), lib/ beyond
  smoke, benchmark-viewer. THE REMAINING DISCOVERY CHANNEL IS RUNS — the
  classes that matter (cache-bust latents, foreign-arch paths, timing/OOM)
  only surface in real rebuilds.

## Reference

- **B3-PLAN**: CONSUMED by wave-4 (all listed bumps applied 2026-08-18,
  incl. the F7-coverage PY_* set; TENSORFLOW_C landed at 2.18.1 — last
  version with a published C tarball). Next refresh at the next window via
  `bump_versions.py --check` (now artifact-aware).
