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

Last groomed: 2026-08-24 (CLOSURE WINDOW 3 declared — see the 🎯 plan). LIVE `:latest-cross` = WAVE-6 ship (a25a38c5/
bd9953a9/d3710282, run id 20260823-223111-d0336283) — see § WAVE-6 SHIPPED.
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
- **Two compiler caches are now installed and mounted** [M·★★] ccache stays as
  the fallback for invocations sccache refuses, so every stage carries both
  mounts (5/5, 1/1, 13/13, 3/3) and the ~27 GB warm ccache still occupies disk
  while contributing nothing. DECIDE after the switch is proven: drop ccache and
  delete the fallback branches, or keep it and document why. Do not leave it
  ambiguous -- ambiguous is how the dead mount survived months last time.
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
