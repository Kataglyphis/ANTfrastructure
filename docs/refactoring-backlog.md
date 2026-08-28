# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in
[`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md);
everything CLOSED up to 2026-08-28 is in
[`refactoring-backlog-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-28 (removed all CLOSED stubs — open items only below)

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

## F. Refactor candidates found while switching ccache -> sccache (2026-08-26)

Collected DURING the switch and the staged rebuild, each with the evidence that
produced it. None of these blocks the current run; they are the debt the switch
either created or exposed.

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
`~/build-logs/archive/20260827-200128-a20ab922/`). All fix-now findings are
closed; only the decision-level items remain.

- **LOG12 — ArmNN ships the reference backend only; the whole ACL wiring is
  inert** [M·★★, OPEN 2026-08-28, documented] `media-arm64.log:15264-15269 "CL
  backend is disabled" / "NEON backend is disabled" / "TOSA Reference backend
  is disabled"`, and the proof that ArmNN never read the ACL variables:
  `:15283-15287 CMake Warning (unused-cli): ARMCOMPUTE_BUILD_DIR /
  ARMCOMPUTE_LIBS / ARMCOMPUTE_ROOT`. build-armnn.sh:61-73 passes no
  `-DARMCOMPUTENEON=1` / `-DARMCOMPUTECL=1`, yet ACL is rebuilt every run
  (`#33 DONE 408.6s`). The build script now carries a comment documenting this
  as reference-backend-only by design. A DECISION still owed: nothing in the
  repo consumes ArmNN (the ORT EP is gone upstream, 30-build-native.sh:89-92).
  Turn the backends on (a real ACL cross-link break may then surface — that
  would be the actual news) or drop the ACL build plus the
  `ARMNN_VERSION`/`ACL_VERSION` pins. As it stands it is 7 min/lane for an
  artifact with no consumer.
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

## A. Window inventory — needs WORK in the wave

### A1. Work items

- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; _cross_stage_build_impl;
  build_iree_wheels; parse_options 116-liner; modules.sh dir-walker.
- **TG1 residual — fuller toolchain-closure trim** [M·★★] llvm-cross/
  llvm-validate lazy + true per-RUN closures; no COPY fallback → needs a
  per-RUN mount audit + real toolchain rebuild.
- **TG3 residual — collapse the two toolchain RUNs** [S·★, NEEDS THE REBUILD] RUN-3d recompiles
  instead of reusing RUN-3 (ccache absorbs, ~97s); pairs with TG1.
- **LOG2 open half — build the wasm asyncify/jspi flavors** [S/M·★★] so
  onnxruntime-web ships its webgpu JS backend (exclusion is documented in
  versions.env since wave-3; this is the build half).
- **LOG34 — TVM's version assert is permanently disarmed** [S·★, OPEN 2026-08-28]
  `smoke-torch-venv.sh:311-322`: an absent TVM is best-effort, and the only
  remaining check is a hand-lowered ok-count floor. Action: set `EXP_TVM` and
  raise the floors — but only AFTER the in-flight rebuild proves TVM ships on all
  three arches.
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.

## C. Orchestrator lifecycle (one coherent PR)

- **--no-push OCI-layout handoff + dual-path collapse** [M·★★, PARTIALLY CLOSED
  2026-08-28] The multi-stage refusal guard is landed — `_chain_no_push_guard()`
  in `build-cross-chain.sh` refuses `--no-push` for multi-stage runs (stale
  parent risk), with `CROSS_NO_PUSH_FORCE=1` escape hatch. See
  `refactoring-backlog-archive-2026-08-27.md` § "Closed 2026-08-28 (host-only
  fixes)". The full OCI-layout export + `--build-context` handoff (which would
  make `--no-push` multi-stage actually safe) and the dual-path collapse remain
  future work.

## E. Waiting on a TRIGGER (not on work)

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS validation** — ⚠ the stated trigger has ALREADY
  passed TWICE without validating anything: the flag defaults to 0, so the
  2026-08-24 and 2026-08-25 compiler rebuilds both took the sequential path.
  It is not waiting on a rebuild, it is waiting on someone putting
  `GCC_PARALLEL_TARGETS=1` on the LAUNCH COMMAND. Do that or it will be missed
  a third time.
- **GPU-ROCM10 — verification build of the AMD GPU lane** [M·★★★] the ROCm
  10.0 / TheRock migration (2026-08-28) changed the repo format (deb822
  `.sources`), the GPG key, all package names (`amdrocm-*`), and added a
  second repo stanza for MIGraphX. None of it has been built yet. The
  post-install assertions (`hipcc`, `migraphx.hpp`, library names in
  ldconfig) are carried over from the old 7.2.4 script and may need path
  adjustments if TheRock installs differently. Build the `Dockerfile.amd`
  stage (`-TargetArch amd64`, CPU lane is enough — no GPU hardware needed
  for the install), then a downstream media+android run with
  `ENABLE_AMD=true` to exercise the MIGraphX EP build.
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
