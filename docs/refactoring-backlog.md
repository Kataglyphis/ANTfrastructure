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

Last groomed: 2026-08-28 (removed CLOSED two-caches stub; extended verify-critical-fixes.sh gate repo-wide)

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
- **The compiler-cache abstraction is split across seven places** [L·★★,
  partially fixed 2026-08-28] compiler-cache.sh:4-8 already warns "the
  02-toolchain GCC/LLVM builds do NOT source this module ... that misread hid a
  dead ccache mount for months". The sccache switch had to touch build-gcc.sh,
  build-clang.sh, llvm-cross.sh, compiler-cache.sh, cmake-cache-linker.sh,
  build-app-wheelhouse.sh and the onnxruntime build lib SEPARATELY, and one of
  them (cmake-cache-linker.sh, a SHARED helper) would have silently overridden
  the switch for every consumer. Consolidate onto one resolver; the launcher
  helper is the seam to build on.
  Fixed in this batch: the three GPU bare-`sccache` sites (build-opencv.sh,
  30-build-native-nvidia.sh, 30-build-native-amd.sh) now resolve through
  `compiler_cache_launcher()` (sccache-class only — ccache can't wrap
  nvcc/hipcc); TVM now sets `CMAKE_C/CXX_COMPILER_LAUNCHER` explicitly; ffmpeg
  and pyav were fixed in the prior batch. The L·★★ consolidation itself
  (merging all sites onto one resolver) remains open. The repo-wide
  verify-critical-fixes.sh gate now flags any new bare `sccache` launcher
  export — the compiler-cache.sh-only check is extended to all .sh files.

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
- **LOG34 — TVM's version assert is permanently disarmed** [S·★, CLOSED 2026-08-30]
  `EXP_TVM` is now set from `TVM_REF` in versions.env, making TVM a hard assert
  (must be importable, major.minor must match). The build proved TVM ships on all
  three arches (amd64, arm64, riscv64). The version check compares major.minor
  only, since the wheel is a dev tag (0.26.dev1) that doesn't match the git tag
  (0.26.0) exactly.
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
