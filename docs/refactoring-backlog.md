# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in
[`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md);
everything CLOSED up to 2026-08-28 is in
[`refactoring-backlog-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md);
the 2026-08-30 round is in
[`refactoring-backlog-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-30 (cleanup after the rebuild window). Everything the
2026-08-30 waves closed is in the archive — this file holds only what is still
open: the A1 closure-window style debt (incl. the logging.sh ERR-trap bug found
2026-08-30), GEN1, the QNN-LINUX fan-out validation (blocked on a login-gated
SDK re-stage), and the E-section trigger watches.

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

## A. Window inventory — needs WORK in the wave

### A1. Work items (all need a closure window — edits to 01-core/03-media
invalidate compiler/media cache)

- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; build_iree_wheels; parse_options
  116-liner; modules.sh dir-walker. (`_cross_stage_build_impl` is already a
  single impl behind two thin wrappers — part of C, closed 2026-08-30; do not
  re-add it.)
- **logging.sh ERR-trap dynamic-scope bug** [S·★, found live 2026-08-30]
  `_install_trap`'s `on_err` reads `${action}` under `set -u`; when the ERR trap
  fires outside the function's dynamic scope the var is unbound and prints
  `action: unbound variable` — REPLACING the real error (it masked the parallel
  GCC apt-lock failure). Fix: capture the handler name in the trap string so it
  is self-contained (e.g. `trap 'on_err "..." ...' ERR` with the action baked
  in), and add a regression test. logging.sh is in the base/compiler/media
  closures, so batch with A1 in a closure window.
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.

### A2. QNN-LINUX — Qualcomm QAIRT/QNN SDK on the Linux ARM64 lane (Snapdragon)

Mirror the Windows QNN EP (#121, `windows/qnn-sdk/`) onto the Linux `arm64`
lane for Snapdragon NPU inference. Same opt-in contract (login-gated zip
dropped by hand, build skips gracefully when absent), **different SDK**:
Linux AArch64 extracts to `qairt/<version>/lib/aarch64-oe-linux-gcc11.2/`
(not `aarch64-windows-msvc`).

**What is DONE (2026-08-30, all in the archive):** drop dir + .gitignore,
versions.env pin, the shared `01-core/qnn-sdk.sh` resolve/stage helper (moved
out of ORT's lib), ORT build wiring PROVEN on real SDK v2.49.0.260730, the
Dockerfile.media mounts, artifact verification, and the framework fan-out
wiring (GenAI/LiteRT/TVM/IREE) — every flag mirrors Windows #121 exactly.

- **Fan-out validation build — BLOCKED on the login-gated SDK.** The wiring is
  in place and fail-safe (no zip = byte-identical behavior on every arch; that
  path was validated by the 2026-08-30 media rebuilds). What is still unproven
  is the OPPOSITE direction: with a REAL QAIRT zip staged on arm64, do all five
  builds stay GREEN and do the staged libs land? (Storm the open items —
  LiteRT's own QNN-manager header fetch, the wheel-staging question — are
  answered by that same run.) The real zip is NOT on the host (removed after
  the PROVEN build per the qnn-sdk README discipline; the buildkit `/tmp` tmpfs
  discarded the in-RUN extraction). **Owner action required:** re-stage from
  qpm.qualcomm.com (Qualcomm ID + EULA), then re-pin `QNN_SDK_LINUX_ZIP_SHA256`
  in versions.env — a fake/round-tripped zip hard-fails the sha check by
  design. QNN_SDK_LINUX_LIBDIR (default `aarch64-oe-linux-gcc11.2`) is the
  single knob if a newer SDK changes the lib subdir.

## E. Waiting on a TRIGGER (not on work)

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS on a full push chain** — validated locally 2026-08-30
  (green, ~30 % GCC-RUN saving); the next full chain that wants the parallel
  GCC must pass `GCC_PARALLEL_TARGETS=1` on its command line (it now reaches
  the container — the plumbing fix 92fb9646).
- **gcc-prereq measurement facets** (sig-cache, LIBRARY_PATH leak, verify
  coverage, dup-compile overlap) — needs ccache stats from a real build;
  the "unify prereq paths" reading is CLOSED (deliberately different).
- **post-restart base cache-miss** — observe at the next host reboot.
- **LOG7 — sdkmanager CLI deprecated** — bit-rot watch before Google
  removes it.
- **MESON-GI — meson 1.12 breaks g-i-1.84 glib-subproject resolution
  (riscv64 cross gst)** [S·★, WATCH] Pin is in place:
  `setup-gstreamer.sh` installs `meson==1.11.2` for riscv64 cross only
  (amd64 native + arm64 no-introspection are fine on 1.12). Re-bump when
  upstream meson/g-i fix the `subproject('glib')` resolution — retest by
  removing the pin in a closure window.
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
