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

Last groomed: 2026-08-28 (§ G + § H + § I: the maximality audit of the same
from-base run — features, optimizations, smoke coverage, doc claims; CLOSURE WINDOW 3 still declared — see the 🎯 plan). LIVE
`:latest-cross` = index `a26bf2f4dbc8`, children amd64 `a0d1a144` / arm64
`2d354459` / riscv64 `7e0ed041`, run id `20260827-073226-d491cb10` — see
§ SHIPPED 2026-08-27. Re-verified against the registry 2026-08-28. (This line
said WAVE-6 `a25a38c5/…` until 2026-08-28 — one ship stale, and contradicting
§ SHIPPED in this same file. Re-check it against the registry when grooming,
not against memory.) A from-base rebuild is IN FLIGHT as of 2026-08-28.
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

STATUS as of 2026-08-28: the pre-build wave is worked through and the
validating rebuild is running. 27 unit suites / 677 assertions green, shellcheck
clean over 263 files plus the new SC2215 pass. Preflight is 31/32: the one red
check is `docs cross-references`, and all three of its findings are Windows-lane
(they belong to the separate Windows backlog — do not "fix" them here). The
backlog went 46 → 30 in the pre-build wave, then back to 39 when the 2026-08-27/28
run was mined (§ G, § F LOG19, § B LOG17/LOG18). versions.env stays OPEN until
the rebuild finishes.

Two fixes in this wave are proven by EXECUTION, not inspection: TVM now
compiles and stages its arm64 wheels (four stacked causes, each only visible
once the one before it was fixed), and `PartOf=containerd.service` was tested
against a real `systemctl --user restart containerd`.

CORRECTED 2026-08-28: that PartOf claim was HALF the fix and the sentence
"now self-heals" was wrong. Both reboots that night lost the emulators anyway.
PartOf did fire — the unit re-ran in the same second — but it then FAILED with
`cat: /run/user/1000/containerd-rootless/child_pid: No such file`. `After=`
orders the UNIT start only; containerd-rootless still has to unshare and write
child_pid afterwards, so on a cold boot the binfmt unit wins the race. A manual
re-run always succeeds because containerd is warm by then, which is exactly why
the restart test looked green while every boot stayed broken. Fixed for real in
afefdfc (`wait_for_namespace()` polls for the pid file and a joinable namespace,
plus `Restart=on-failure`). LESSON: a unit that is `active` proves nothing —
prove emulation with a real foreign-arch run.

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

- **LOG20 — FFmpeg ships no `drawtext` filter on any arch** [S·★★, OPEN 2026-08-28]
  libharfbuzz is never enabled anywhere in the tree, so the single most-used
  overlay filter is missing on all three arches. Action: add the harfbuzz dev
  package to `ffmpeg_extra_feature_packages` (same shape as the libwebp/libvmaf
  fix of 2026-08-28) and assert `drawtext` in the per-feature ffmpeg smoke.
- **LOG21 — OpenCV on arm64/riscv64 ships with NO highgui window backend**
  [S·★★, OPEN 2026-08-28] `GUI: NONE` on both cross arches vs `GTK3` on amd64,
  so `cv2.imshow()` raises at runtime on two of three shipped images. Decide
  whether the cross images are headless BY DESIGN — if yes, write that down and
  assert it; if no, the GTK dev packages have to reach the cross lanes.
- **LOG22 — FFmpeg enables Vulkan but ships zero `*_vulkan` filters**
  [S·★, OPEN 2026-08-28] no SPIR-V compiler is available at ffmpeg configure
  time, although the sdk stage cross-builds `libglslang.a` for EVERY arch. The
  pieces exist and never meet. Action: wire glslang into the ffmpeg stage, or
  drop the Vulkan enable and say why.
- **LOG23 — the shipped Pythons have no readline (all arches) and no curses
  (cross arches)** [S·★, OPEN 2026-08-28] both are single dev-package rows in
  `_CPYTHON_EXT_DEV_PKG_TABLE`. readline is what makes an interactive `python3`
  in the image usable at all. Same table-gap class as LOG18 (libmpdec) — do them
  in one pass.
- **LOG24 — OpenCV's ONNX Runtime DNN backend is OFF on all three arches**
  [S·★★, OPEN 2026-08-28] in an image that ships a source-built ONNX Runtime.
  `cv2.dnn` therefore cannot use the very runtime the image is built around.
  Action: turn the backend on and assert it in the cv2 smoke; the library it
  needs is already in the image.
- **LOG25 — LiteRT is built with the GPU delegate and NPU support hard-off, with
  no rationale comment** [S·★, OPEN 2026-08-28] every other deliberate exclusion
  in these scripts carries a why. Either enable, or write the reason down so the
  next audit stops re-finding it.
- **LOG26 — three single-row OpenCV gaps and two riscv64 torch gaps, all
  undocumented** [S·★, OPEN 2026-08-28] OpenCV: AVIF, HDF5 and the non-free
  algorithms are absent. riscv64 PyTorch is built feature-minimal AND with
  `USE_OPENMP=0` (build-app-wheelhouse.sh:525) while arm64/amd64 are not, with
  no written rationale for either. FFmpeg additionally has no PulseAudio device.
  Action: one pass — enable what is cheap, document what stays off.

## H. Smoke & gate coverage (one coherent PR — 2026-08-28 maximality audit)

The audit's sharpest finding: what runs is deep and genuinely functional, but
several gates cannot fail, and one whole smoke STAGE has never been built.

- **LOG29 — the `wrapper-smoke` package stage has never been built, in any run**
  [M·★★★, OPEN 2026-08-28, DO IMMEDIATELY AFTER THE RUNNING BUILD]
  `PACKAGE_DOCKERFILE_TARGET` occurs exactly ONCE in the whole repo — as its own
  default in `runtime-build-fns.sh:317` (`--target "${PACKAGE_DOCKERFILE_TARGET:-package}"`).
  So `--target package` is always used and `Dockerfile.package:346`
  (`FROM package AS wrapper-smoke`) is pruned by BuildKit: **0 occurrences of
  `wrapper-smoke` in either chain log** (20260827-220128 and 20260828-083002).
  Consequence: the four smokes in that stage — including the ENTIRE FFmpeg codec
  battery — have never executed. No externally linked codec (x264, x265, vpx,
  dav1d, svtav1, opus, webp, aom) is functionally proven in shipped bytes on any
  arch; the only runtime check is `ffmpeg -version | head -1`. This re-arms
  ~1150 lines of already-written, already-reviewed test code. Blocked while the
  chain runs (needs Dockerfile.package + 01-core/runtime-build-fns.sh).
- **LOG30 — nothing anywhere asserts an OPTIMIZATION property** [S·★★★, OPEN
  2026-08-28] this is WHY both -O defects of 2026-08-28 (riscv64 torchvision
  built with no `-O` at all, cross CPython at `-O2` instead of `-O3`) survived 27
  unit suites, 31 preflight checks and every runtime smoke. Action: one assertion
  on shipped bytes per arch — e.g. the torchvision `_C` extension and the
  interpreter must not be unoptimized. Cheapest high-value gate in the list.
- **LOG31 — three gates report every failure class as a WARNING and never exit
  non-zero** [M·★★, OPEN 2026-08-28] `validate-media-runtime.sh:265,279,286`
  (unresolved deps, unmappable, and the new DENIED class), `smoke-android.sh`
  (five presence checks with no failing branch — a missing NDK clang or apksigner
  passes), and two preflight checks that are structurally incapable of failing.
  Action: start with the DENIED class, which is meant to be empty by
  construction; the broader `.so` sweep needs the vendor trees excluded first.
- **LOG32 — 3.3 GB of shipped Android artifacts and 1.8-5.7 GB of Vulkan SDK
  carry no gate that can fail** [M·★★, OPEN 2026-08-28] together ~7 GB of a
  16-17 GB image. The Vulkan smoke that would test it is disabled on a premise
  worth re-checking (`Dockerfile.package:368-373`). Action: lift the three
  cheapest checks into the runtime smoke — `active` resolves,
  `vulkan/vulkan.h` present, one `glslangValidator` invocation.
- **LOG33 — `verify-shipped-wrapper.sh`, the ONLY gate on shipped bytes, has
  exactly two hard assertions** [S·★★, OPEN 2026-08-28] everything else it prints
  is advisory. Given the owner rule "verify shipped BYTES, never trust the push",
  this is the highest-leverage script in the repo and the thinnest.
- **LOG34 — TVM's version assert is permanently disarmed** [S·★, OPEN 2026-08-28]
  `smoke-torch-venv.sh:311-322`: an absent TVM is best-effort, and the only
  remaining check is a hand-lowered ok-count floor. Action: set `EXP_TVM` and
  raise the floors — but only AFTER the in-flight rebuild proves TVM ships on all
  three arches.
- **LOG35 — smaller gate gaps, one pass** [S·★, OPEN 2026-08-28] vvdec (VVC/H.266)
  is built and shipped with no smoke of any kind; the shipped-image `.so` closure
  is capped and silently truncates; `/opt/cmake` ships unasserted;
  `verify-media-artifacts.sh`'s media-inputs lib→lib64 fallback is the exact
  broken idiom the same file fixed elsewhere; the app-wheel-smoke ratchet added
  for one incident is narrower than the class it was meant to catch.
- **LOG36 — `libtvm*.so` is dropped at the media→package COPY** [S·★★, OPEN
  2026-08-28] built in the media stage (`Dockerfile.media:1049`), not in the
  package COPY set. Verify whether the python wheel carries its own copy; if not,
  TVM is shipped broken and the disarmed assert (LOG34) is why nobody noticed.

## I. Doc claims that drifted (one coherent PR — 2026-08-28 maximality audit)

Every version NUMBER in the docs is machine-gated and green. Every sentence about
BEHAVIOUR is ungated, and that is where all of these sit.

- **LOG37 — the docs say the "strict" packaging smoke set closed the
  orphaned-smoke class; it lives in a stage nothing builds** [M·★★, OPEN
  2026-08-28] `docs/cross-build-verification.md`, `docs/linux-cross-builds.md`.
  Same root cause as LOG29 — fix together, and make the doc state which target
  the smokes run under.
- **LOG38 — AGENTS.md still carries the `PartOf` binfmt claim the backlog
  corrected on 2026-08-28** [S·★★, OPEN 2026-08-28] the real fix is
  `wait_for_namespace()` + `Restart=on-failure` (afefdfc); `After=` orders only
  the unit start, so a cold boot loses the race. AGENTS.md § Prerequisites still
  describes the superseded understanding.
- **LOG39 — the only written NVIDIA/AMD build recipes are broken** [M·★★, OPEN
  2026-08-28] `docs/linux-accelerator-images.md`, `docs/overview.md`. A reader
  following them fails. Either repair or mark them explicitly unsupported.
- **LOG40 — license/SBOM docs have drifted from the generator** [M·★★, OPEN
  2026-08-28] `docs/third-party-licenses.md`, `docs/deps/deps.json`,
  `docs/deps/sbom-curated.spdx.json`. These are the documents an external
  consumer would actually rely on.
- **LOG41 — `:latest` was deleted from the registry, the docs still reference
  it** [S·★, OPEN 2026-08-28] `docs/overview.md`, `AGENTS.md`,
  `docs/linux-cross-builds.md`. Plus four coverage tables that each declare more
  than they cover, and the `KNOWN_DRIFT` carve-out that
  `docs/cross-build-verification.md:236-240` says "survives" but does not.

### What the 2026-08-28 maximality audit found ALREADY MAXIMAL (anti-re-sweep)

Recorded so a future sweep does not re-litigate settled ground:

- **FFmpeg is feature-identical across all three arches.** The `External
  libraries` block is byte-identical on amd64/arm64/riscv64 (45 libraries), and
  so is the hwaccel block. A riscv64 cross build that loses ZERO codecs against
  amd64 is rare — do not "improve" this.
- **Runtime SIMD dispatch is maximal and justifies the conservative `-march`
  baselines**: FFmpeg reaches AVX-512ICL (amd64), SVE/SVE2/SME/SME2 (arm64) and
  `RISC-V Vector enabled yes` + CBO prefetch (riscv64), each with runtime CPU
  detection. OpenCV dispatches to AVX512_SKX / NEON_BF16.
- **Declarative optimization is clean**: 41× `CMAKE_BUILD_TYPE=Release` and 0×
  Debug/RelWithDebInfo across all three media logs; meson `Optimization: 3`,
  `Debugging: false`; stripping centralized and proven on shipped bytes;
  `--gc-sections --as-needed -z now`; amd64 CPython is PGO+LTO.
- **GStreamer is the full monorepo on all three lanes**, Rust plugins included
  (riscv64 builds them in 3m44s), 220/229/222 plugins, amd64−arm64 difference
  empty.
- **The smokes that DO run are functional, not cosmetic**, and run per-arch under
  QEMU on the real shipped bytes: a real `InferenceSession` on a generated ONNX
  protobuf, `iree-compile` + `iree-run-module` with result checking, cv2
  GStreamer appsink with frame shape, torch forward+backward, torchvision
  `ops.nms` through the `._C` extension, an 8-case compiler battery.
- **The anti-fake-green discipline is first-rate**: scan-done stamps, EP
  sentinels, CMDOK markers, SIGPIPE fixes, and parity tables that fail when a
  documented exception STOPS applying.

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
