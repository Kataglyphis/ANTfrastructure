# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in `refactoring-backlog-archive-2026-08-10.md`
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

## ✅ WAVE-6 SHIPPED 2026-08-24 (the gate-truth build — three blind gates now actually work)

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

## 🎯 CLOSURE WINDOW 3 — OPEN (declared 2026-08-24): pre-build wave, then a FULL validating rebuild

The operator has committed to a fresh build, so the versions.env lock is OPEN
and build-validated items are IN SCOPE. Work the wave in this order; the
rebuild then validates everything at once (that is the whole point of a
closure window — ONE rebuild pays for all).

**Phase 0 — host prep (no-build window, do FIRST):**
- Optional BKD1 rider: upgrade buildkitd to v0.32.2 (concurrency-stress fixes
  #6916/#6955; not a session-rot fix — the restart playbook stays).
- Apply the staged buildkitd.toml gcpolicy (linux/host-config/, needs a
  buildkitd restart — this is the no-build window it has waited for).
- Disk: prune-safe to ≥150G free (full-rebuild appetite per the playbook);
  the 215G kata-buildcache trim is the operator's call, not the agent's.
- Run preflight.sh (the full gate battery incl. the GCC-literal gate).

**Phase 1 — pin-bump pass (versions.env window):**
- bump_versions.py sweep (the wave-4 ritual; BT1/BT2 guards are in).
- § B riders: AP6 (decide/flip ORT_ENABLE_LTO per-arch-gated — this rebuild
  is the measuring event), F6 (ABSEIL → decompressed-stream hash;
  cmdline-tools sha1 cross-check vs repository2-3.xml), small riders
  (RUFF_PIN → versions.env, LLVM_COMMIT opt-in key, TS1 APPIMAGETOOL keys,
  setup-package-image residual pins).
- MESON-GI probe: if meson >1.12 resolves g-i's glib subproject again, lift
  the riscv64 pin in this window; else it stays with its reason.

**Phase 2 — producer fixes (media/android lane):**
- GENAI-DRIFT producer half: make the arm64 genai wheel land; then DELETE the
  dated tolerance line in smoke-torch-venv.sh (it re-arms the assert).
- ORPHAN-PINS producer: make Dockerfile.media's `import tvm works on amd64`
  promise TRUE (the staging chain is diagnosed, loudly failing since wave 1)
  or retract the promise; PyAV: build it or DROP the orphan pin (drop =
  versions.env edit — in window).
- RV1-FREETYPE: fix the host-vs-target harfbuzz cross-link and re-enable
  `-DBUILD_opencv_freetype` on riscv64 — closing the last documented
  ARCH-PARITY exception.
- LOG2 open half: build the wasm asyncify/jspi flavors.

**Phase 3 — toolchain trims (from-base rebuild validates):**
- TG1 residual (fuller toolchain-closure trim) + TG3 residual (collapse the
  two toolchain RUNs). Both were bitten before — implement + adversarial
  review + the rebuild as the only accepted proof.

**Phase 4 — DECIDED by the operator 2026-08-24:**
- S3 registry cache mode=max: **NO** — inline stays; the design doc
  (docs/build-cache-tiers.md) remains for a future revisit. S3 moves to § D
  as decision-recorded, do not re-pitch without new evidence (e.g. another
  cold-rebuild incident).
- USE_FAST_UBUNTU_MIRROR: **YES** — the rebuild launches with the knob ON,
  which exercises the APT-HTTP https-restore for real (its validator).

**The rebuild itself:** from BASE, all three arches, --parallel-archs
--max-parallel-archs 3, launched CLEAN — it doubles as the long-owed PAR1
timing run. It auto-validates the already-landed-but-unproven set (media
source-caches, TS8, DUP2 SSOT, cerbero extra_mirrors, C3 :?-guards, TS4 llvm
keying, CERB-CACHE warm behaviour) and fires the § E triggers:
GCC_PARALLEL_TARGETS, gcc-prereq facets, post-restart base cache-miss.

**After the ship:** evidence-audit the logs (the wave-6 ritual), fold
validated items with quotes, THEN: GPU lane opt-in build (GPU1-7), first
compose up + WEBUI_SECRET_KEY rotation (user-side).

## A. Window inventory — A1 needs WORK in the wave, A2 is validated by the rebuild ALONE

### A1. Work items (all referenced by the phase plan above)

- **RV1-FREETYPE — riscv64 opencv freetype module still OFF** [S·★,
  residue of RV1-GST-PC, which is otherwise CLOSED by wave-5] riscv64 gst
  is fully recovered (cv2 GStreamer:YES on shipped bytes, libcamera gst
  element back) — what remains is `-DBUILD_opencv_freetype=OFF` in
  build-opencv.sh (harfbuzz "file in wrong format" in the cross link) and,
  only if ports gst-dev is ever wanted again, the cross pkg-config wrapper
  that sysroot-prefixes ports' empty-prefix .pc vars. Wheel smoke shows it
  as the riscv64-only `opencv-freetype` warning.
- **GENAI-DRIFT — onnxruntime-genai differs per arch and the pin assert
  says OK** [S·★★, 2026-08-23] versions.env pins v0.15.2; shipped reality is
  amd64 0.15.2 (local wheel), arm64 0.14.0 (PyPI, from the app lock), riscv64
  absent. The dual-authority union (lock ∪ pin) accepts all three, so the
  assert cannot catch it. Tighten: when versions.env carries a BUILD pin for
  a package, that pin — not the lock — is authoritative for every arch that
  builds it; then find out why arm64's genai wheel never lands.
- **ORPHAN-PINS — PyAV and TVM are pinned but built nowhere** [S·★★,
  2026-08-23] `PYAV_VERSION=18.1.0` has no build step anywhere under linux/;
  TVM is absent on ALL THREE arches although Dockerfile.media:392-394 states
  amd64 "stages a wheel + libtvm into the final image so `import tvm`
  works". Both show as permanent wheel-smoke warnings. Decide per component:
  build it, or delete the orphaned pin — as-is both read as
  intended-but-missing, and PyAV means every wrapper ships without the
  FFmpeg→Python bridge.
- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; _cross_stage_build_impl;
  build_iree_wheels; parse_options 116-liner; modules.sh dir-walker.
- **TG1 residual — fuller toolchain-closure trim** [M·★★] llvm-cross/
  llvm-validate lazy + true per-RUN closures; no COPY fallback → needs a
  per-RUN mount audit + real toolchain rebuild.
- **TG3 residual — collapse the two toolchain RUNs** [S·★] RUN-3d recompiles
  instead of reusing RUN-3 (ccache absorbs, ~97s); pairs with TG1.
- **LOG2 open half — build the wasm asyncify/jspi flavors** [S/M·★★] so
  onnxruntime-web ships its webgpu JS backend (exclusion is documented in
  versions.env since wave-3; this is the build half).
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.
- **TVM arm64/riscv64 cross-build** [L·★★] media:369 placeholder; cross path
  in tvm-python.sh never wired; do with the llvm-config pin.
### A2. Already landed, validated by the rebuild alone (watch, no work)

- Media source-cache mounts, cerbero extra_mirrors fallback, C3 `:?`
  guards, TS4 llvm checkout keying, CERB-CACHE warm/evict behaviour,
  APT-HTTP restore (only if the fast-mirror knob is ON), DUP2 SSOT +
  literal gate — each shipped and reviewed; the rebuild is their proof.
  Fold them with log quotes in the post-ship evidence audit.

- **TS8 + shared apt-source include** [S] build_python.sh hand-rolls the 4th
  apt-sources copy; one include, five consumers (nvidia/amd/android too).
- **DUP2 residual — SETTLED 2026-08-24, one operator habit remains** [S·★]
  the gate IS wired: preflight.sh:140 runs verify-arg-consistency.sh as the
  `arg-consistency` check, and with the C3 exemption it passes rc=0 with 32
  sites scanned. The evidence audit's "chain never runs it" observation is
  BY DESIGN — build-cross-chain.sh performs only the disk preflight, the
  full gate battery is the operator-run preflight.sh. Residual: nothing to
  build — just run preflight.sh before launch (AGENTS.md already says so).
  Delete on the next groom if no counter-evidence appears.
- **BKD1 — buildkitd session rot: RESEARCHED, no upstream fix exists** [M·★,
  downgraded from ★★ 2026-08-24] host runs buildkit v0.31.1 (nerdctl 2.3.4,
  containerd 2.3.2). The symptom IS a known open upstream issue —
  moby/buildkit#6422 ("no active session … context deadline exceeded", open,
  no linked PR) and #5624 (same class during cache-export registry auth) —
  and NO release through v0.32.2 (2026-08-04) mentions a session/keepalive
  fix. VERDICT: keep the restart playbook (stop chain → restart
  buildkit.service → relaunch; cachemounts survive). OPTIONAL, no-build
  window: upgrade to v0.32.2 for its concurrency-stress fixes (#6916 daemon
  crash during concurrent builds, #6955 parallel-build cache-miss) — adjacent
  to our load profile, but not a fix for the session rot itself.

## B. Next PIN-BUMP window (versions.env riders — NEVER alone)

- **AP6 — ORT_ENABLE_LTO never set/decided** [S·★★] flip per-arch-gated,
  measure in the validating rebuild, or document the decision.
- **F6 — remaining stray SHA pins: RESEARCHED, exact bump-window changes
  recorded** [S, was M] (a) ABSEIL: codeload-by-commit VERIFIED byte-stable
  (two sequential fetches, identical sha256 7f4240fe…, matches the pin at
  versions.env:194) — but GitHub only pledges byte stability "no less than a
  year", so the durable form is a STREAM hash of the decompressed tar
  (gunzip -c | sha256sum = ec28d875…); switch the pin to that at the next
  bump. (b) ANDROID_CMDLINE_TOOLS: Google DOES publish checksums —
  repository2-3.xml carries sha1 040d3996… for
  commandlinetools-linux-15859902_latest.zip; verified against the real zip,
  and our sha256 pin (versions.env:503) matches the same bytes. Bump-window
  change: cross-check the manifest sha1 when regenerating the sha256 pin.
  Both edits touch versions.env → pin-bump window only.
- Small riders [S each]: pyav dead-pin check (Windows consumer?),
  LLVM_COMMIT opt-in key, setup-package-image residual pins (:283-285),
  peripheral pins (renovate hints, ollama ALLOW_UNVERIFIED, ghcr token
  scope), TS1 APPIMAGETOOL_*_SHA256 keys, RUFF_PIN → versions.env (C4).

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
- **S5 — cargo cache ids arch-independent** [S·★] downloads duplicated 3×
  (deliberately per-lane since PAR2 — revisit as shared+non-locked).
- **SCC1 — sccache hybrid design** [M·★★] ccache stays for C/C++; sccache
  ONLY for rustc (wiring exists, flip controlled) + nvcc + the webdav
  cross-machine tier. Absorbs "ccache remote_storage" + "Rust sccache
  unblock". Full switch rejected (owner decision 2026-08-17).

## E. Waiting on a TRIGGER (not on work)

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS validation** — next compiler-stage rebuild.
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
- **NODE-RV — riscv64 ships Node v22 (pin: 26.7)** [S·★, watch] ubuntu-ports
  has no 26.x for riscv64; the install falls back fail-open with a WARN (by
  design, seen in every wave-4 smoke log). Lift when ports ships 26.x —
  check via `apt-cache policy nodejs` on the ports snapshot at each bump
  window; until then the riscv64 image runs the distro v22.
- **SV-residual — watch the first real `compose up`** — user-side.
- **riscv64 isa-spec smoke on real hardware** — needs hardware.
- **WEBUI_SECRET_KEY server-side rotation** — user action.

## Verdicts (anti-re-sweep records — do NOT re-audit without new evidence)

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
