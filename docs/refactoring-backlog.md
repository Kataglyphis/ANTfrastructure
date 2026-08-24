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

Last groomed: 2026-08-23. LIVE `:latest-cross` = WAVE-5 ship (54ab7f01/
7bb70a4b/fb701200) — see § WAVE-5 SHIPPED.
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

- **RV1-FREETYPE — riscv64 opencv freetype module still OFF** [S·★,
  residue of RV1-GST-PC, which is otherwise CLOSED by wave-5] riscv64 gst
  is fully recovered (cv2 GStreamer:YES on shipped bytes, libcamera gst
  element back) — what remains is `-DBUILD_opencv_freetype=OFF` in
  build-opencv.sh (harfbuzz "file in wrong format" in the cross link) and,
  only if ports gst-dev is ever wanted again, the cross pkg-config wrapper
  that sysroot-prefixes ports' empty-prefix .pc vars. Wheel smoke shows it
  as the riscv64-only `opencv-freetype` warning.
- **BKD1 — buildkitd session rot under multi-hour parallel load** [M·★★]
  sessions die after ~1-2h ("no active session", grpc cancels at export,
  DeadlineExceeded on cache reads) — cost ~6 retry cycles across the wave-4
  saga; cure each time = daemon restart. Investigate buildkit v0.31.1
  issue trackers / upgrade; interim playbook: restart between chain rounds
  (cachemounts provably survive).

## Next up (recommended order, 2026-08-24)

1. **APT-HTTP** [★★★] — the only open finding with a security dimension.
   VERIFY first (which sources file ends up on which scheme, at which stage),
   then decide. No build needed to establish the facts.
2. **GPU lane validation build** [★★★, cheap, anytime] — the staged GPU1-7 set
   still awaits its one opt-in build.
3. **Full rebuild from MEDIA** — wave-6 validated only android→runtime, so the
   wave-3 media/toolchain work (DUP2 SSOT + drift gate, TS8, media source
   caches) is still unproven by a real build.
4. **Next pin-bump window** — § B riders (+ GENAI-DRIFT producer half,
   ORPHAN-PINS).
5. **Clean PAR1 timing run** — one undisturbed full parallel rebuild.

> **Editing note (learned the hard way 2026-08-24):** deleting an item with a
> script that seeks the next `- **` will SWALLOW a following `## ` section
> header — that is how all of § B silently vanished for four commits. When
> removing a validated item, bound the deletion at the next item OR the next
> header, whichever comes first, and re-count the sections afterwards.

---

## A. Next CLOSURE WINDOW (01-core / 03-media / Dockerfile closure — ONE rebuild pays for all)

- **APT-HTTP — the base image may fetch packages over plaintext http** [S/M·★★★,
  FOUND 2026-08-23, NOT fixed — needs a decision] base-image.sh:221
  deliberately rewrites the fast-mirror URL `https://…` → `http://…` because a
  fresh Ubuntu image has no trusted CA bundle yet ("bootstrap the archive over
  HTTP first"). The standalone RUN in Dockerfile.base that is positioned to
  restore https afterwards was found INERT during the wave-2 review (the
  preceding bootstrap-ca RUN has already applied the mirror, so the later RUN
  has nothing left to do). If that holds, the base image — and every stage
  FROM it — ships apt sources on http, so package integrity rests on apt's
  signature checking alone with no transport security. VERIFY first (which
  sources file ends up with which scheme, at which stage), then decide:
  re-point to https once ca-certificates is installed, or document that
  signature verification is considered sufficient. Do not fold this into an
  unrelated change — it is the one finding of this sweep with a security
  dimension.
- **SMOKE-DEPTH — the runtime smokes never execute anything real** [M·★★★,
  2026-08-23] three gaps found while verifying wave-5, all "green line, no
  proof": (a) media support is read from `cv2.getBuildInformation()`
  STRINGS — compile-time linkage only; a manual one-frame
  videotestsrc→appsink + FFmpeg roundtrip passed on all 3 shipped arches,
  so promote that pipeline into the smoke instead of the string grep;
  (b) the image ENTRYPOINT is never run (every check overrides it with
  `--entrypoint /opt/venv/bin/python`) — a broken entrypoint.sh would ship
  green; (c) no inference is ever executed and `onnx` is not even installed,
  so no EP can be claimed working — ship a tiny .onnx fixture and run one
  InferenceSession per arch.
- **MIRROR-KNOB — USE_FAST_UBUNTU_MIRROR is a silent no-op at 2 build
  sites** [S·★★] `ubuntu-mirror.sh:21` calls `is_truthy`, which lives in
  platform.sh — not bind-mounted in Dockerfile.base:62 or
  Dockerfile.package:281, so the log shows `is_truthy: command not found`
  6× per run (2× per arch) and the fast-mirror path silently never
  activates. Fix = add the platform.sh bind-mount at both sites (or inline
  the helper). Pure build-time; no effect on shipped bytes.
- **ARCH-PARITY — three per-arch gaps nobody gates** [S/M·★★, 2026-08-23]
  verified live in the shipped images: (a) riscv64 has NO `/opt/cmake-4.4.2`
  (amd64 207M, arm64 130M) and falls back to distro cmake 4.2.3;
  (b) arm64's gtk4 GStreamer plugin cannot load (`libgtk-4.so.1: undefined
  symbol: vkCreateWaylandSurfaceKHR` — distro GTK vs shipped Vulkan loader,
  arm64 only); (c) `onnxruntime-webgpu` ships on arm64+riscv64 but not
  amd64, and is untested everywhere. Add a cheap prefix/component parity
  assert to the runtime smoke (the set of /opt/* prefixes + optional wheels
  should match across wrappers modulo a documented exception list).
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
- **D3+P5 — smoke-media gate scaffold + SMOKE_ENV contract** [M·★★] extract
  smoke_resolve_bin/assert_elf_magic/component_gate (6+2+4 dup sites) into
  smoke-common.sh; SMOKE_ENV=sandbox|runtime set by callers. Extend
  test-smoke-arch-parity.sh.
- **Media source-cache mounts** [S/M·★★] version-keyed src mounts for
  opencv/gstreamer/ffmpeg/onnx clones — every rebuild re-clones today.
- **DUP2 — GCC-prefix `16.2.0` literal sprawl (~25× / 11 files)** [M·★★]
  NOT a site-by-site call swap (scope investigation 2026-08-15: mount-gap
  hazard, native-suffix variants, deliberate fallback at llvm.sh:297) — fix
  = SSOT-of-the-default tied to the common.sh sourcing pass.
- **DUP1 residual — uname→triplet inline in cross-apt.sh** [S·★] keep the
  self-contained inline UNTIL platform.sh is confirmed mounted in every
  cross-apt RUN, or route via the guard-helpers migration.
- **codec runtime-list + so-package-map convergence** [M] two hand lists vs
  the ffmpeg manifest (third truth); D4 gives the substrate.
- **cerbero checksums.env class fix + soundtouch TOFU re-hash** [M+S] the
  forge auto-archive re-pin needs the general table. (litert-web npm
  dist.integrity verification is DONE and validated.)
- **SUDO run_priv helper** [M·★] append --preserve-env only when sudo is
  real; ~32 sites in vulkan.sh alone (lint half landed).
- **NVIDIA-lane helper sweep** [S] find|head sites, Dockerfile.nvidia:88,
  cross_gpp, verify-patch-integrity:59, lint-shell empty-array.
- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; _cross_stage_build_impl;
  build_iree_wheels; parse_options 116-liner; modules.sh dir-walker.
- **SH3 residual — mktemp trap in 3 SOURCED libs** [S·★] cross-env.sh:635,
  downloads.sh:64, cmake.sh:44 — needs a collision-safe idiom (EXIT-trap
  clobbering in sourced contexts = the RETURN-trap lesson class).
- **TG1 residual — fuller toolchain-closure trim** [M·★★] llvm-cross/
  llvm-validate lazy + true per-RUN closures; no COPY fallback → needs a
  per-RUN mount audit + real toolchain rebuild.
- **TG3 residual — collapse the two toolchain RUNs** [S·★] RUN-3d recompiles
  instead of reusing RUN-3 (ccache absorbs, ~97s); pairs with TG1.
- **TS8 + shared apt-source include** [S] build_python.sh hand-rolls the 4th
  apt-sources copy; one include, five consumers (nvidia/amd/android too).
- **LOG2 open half — build the wasm asyncify/jspi flavors** [S/M·★★] so
  onnxruntime-web ships its webgpu JS backend (exclusion is documented in
  versions.env since wave-3; this is the build half).
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.
- **TVM arm64/riscv64 cross-build** [L·★★] media:369 placeholder; cross path
  in tvm-python.sh never wired; do with the llvm-config pin.
- **P3 note** [S] generalize the vulkan Multi-Arch drop-in into cross-apt.sh
  only if a SECOND dev-package skew appears.
- **STALE-LOG — the two log-hygiene guards exist but are INERT** [S·★★★,
  re-filed + sharpened 2026-08-23] not "namespacing is unwritten": both
  `cross_stage_log_redirect()`'s truncate-on-new-run-marker
  (cross-stage-build.sh:31-48) and `_chain_archive_prev_logs()` are gated
  behind an opt-in `LOG_DIR` that defaults EMPTY, so in practice lane logs
  are `tee -a`-appended forever — wave5j's 10/6/6 errors were still in
  android-*.log when wave5k launched and tripped a watcher into false NEW-
  error alarms. Fix: default LOG_DIR to out/build-logs (archiving on), or
  per-run subdirs. Watchers then need no baseline hack.
- **EIGEN-NET — litert-android's eigen FetchContent single-homes on
  gitlab.com** [S·★★, BIT 2026-08-21] a momentary gitlab outage
  ('fatal: expected flush after ref listing') killed all three android
  lanes in one window. NET1-class fix: mirror fallback (github
  eigen-mirror / codeload tarball) for the eigen dep in the litert android
  build; also covers the media-lane litert eigen fetch.
- **FD-OUTAGE — cerbero's fallback mirrors are PERMANENTLY dead, not just
  outage-prone** [M·★★★, SHARPENED 2026-08-23 with direct evidence] measured
  during wave6a: a recipe's PRIMARY url
  (`gstreamer.freedesktop.org/data/src/mirror/<name>/<file>`) returns **200**,
  while cerbero's DEFAULT_MIRRORS path for the same artifact
  (`gstreamer.freedesktop.org/src/mirror/<name>/<file>`, no `/data/`) returns
  **503 unconditionally** — the same upstream restructure that killed
  pkg-config. So the fallback is not "single-homed on the same infra", it is
  ALWAYS dead: any transient blip on a primary kills the lane outright, with
  nothing behind it. That is what took android down twice today (pixman,
  gst-plugins-bad) and again in wave6a (pkg-config-dist).
  FIX OPTIONS, in order of value: (a) point cerbero's `extra_mirrors` at a
  mirror base that actually resolves (`.../data/src/mirror` answers 200 — a
  one-line config override, and it is the mirror cerbero itself serves from);
  (b) pre-seed hot tarballs into the cerbero sources dir, which now SURVIVES a
  failure thanks to CERB-CACHE. Option (a) is cheap and testable with curl
  before any build. NOTE the earlier seed-cache attempt was reverted for being
  inert and for deriving wrong filenames — read that history before retrying it.
- **CERB-ICONV — cerbero riscv64-android cold link-order RACE** [S/M·★,
  CONFIRMED NONDETERMINISTIC 2026-08-23] it bit for real in wave5l
  (`ld.lld: error: undefined symbol: libiconv_open` while linking
  glib/libglib-2.0.so) and then PASSED in wave5m with the same
  glib-before-libiconv ordering and NO code change — so it is a scheduling
  race in cerbero's cold dependency order, not a deterministic bug. The
  real fix is a declared recipe dep (glib ← libiconv) in our overlay; until
  then a retry can mask it and a cold run can lose ~1h.
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
- **C3 — android inline version fallbacks → `:?must be set`** [S·★★] incl.
  the two onnxruntime `:-v…` fallbacks (masks broken ARG-forwards).
- **AP6 — ORT_ENABLE_LTO never set/decided** [S·★★] flip per-arch-gated,
  measure in the validating rebuild, or document the decision.
- **TS4 — version-key build-clang.sh's cached llvm-project checkout** [S·★★]
  fires exactly on the next LLVM bump (stale-tag rebuild for hours).
- **F6 — remaining stray SHA pins: 2** [M] (was 3 — VULKAN_SDK solved by
  BT1's spec_vulkan stream-hash 2026-08-19): ABSEIL_TARBALL (github archive
  SHA non-deterministic → needs codeload-by-commit or content verify),
  ANDROID_CMDLINE_TOOLS (no published checksums). Co-locate scattered pairs.
- Small riders [S each]: pyav dead-pin check (Windows consumer?),
  LLVM_COMMIT opt-in key, setup-package-image residual pins (:283-285),
  peripheral pins (renovate hints, ollama ALLOW_UNVERIFIED, ghcr token
  scope), TS1 APPIMAGETOOL_*_SHA256 keys, RUFF_PIN → versions.env (C4).

## B. Next PIN-BUMP window (versions.env riders — NEVER alone)

- **C3 — android inline version fallbacks → `:?must be set`** [S·★★] incl.
  the two onnxruntime `:-v…` fallbacks (masks broken ARG-forwards).
- **AP6 — ORT_ENABLE_LTO never set/decided** [S·★★] flip per-arch-gated,
  measure in the validating rebuild, or document the decision.
- **TS4 — version-key build-clang.sh's cached llvm-project checkout** [S·★★]
  fires exactly on the next LLVM bump (stale-tag rebuild for hours).
- **F6 — remaining stray SHA pins: 2** [M] (was 3 — VULKAN_SDK solved by
  BT1's spec_vulkan stream-hash 2026-08-19): ABSEIL_TARBALL (github archive
  SHA non-deterministic → needs codeload-by-commit or content verify),
  ANDROID_CMDLINE_TOOLS (no published checksums). Co-locate scattered pairs.
- Small riders [S each]: pyav dead-pin check (Windows consumer?),
  LLVM_COMMIT opt-in key, setup-package-image residual pins (:283-285),
  peripheral pins (renovate hints, ollama ALLOW_UNVERIFIED, ghcr token
  scope), TS1 APPIMAGETOOL_*_SHA256 keys, RUFF_PIN → versions.env (C4).

## C. Orchestrator lifecycle (one coherent PR)

- **--no-push OCI-layout handoff + dual-path collapse** [M·★★] --no-push
  builds resolve parents against the REGISTRY (two runs lost historically).

## D. CI / infra / cache tiers (own triggers)

- **S3 — per-stage registry cache refs (mode=max)** [M·★★→★★★, BIT
  2026-08-21] the system-prune wiped local caches and the inline (mode=min)
  registry cache covers only final-image layers → the wave5h relaunch
  COLD-REBUILT all media intermediates (~18 h: torch/IREE/litert ×3).
  Per-stage mode=max refs would have made that a fast-forward. Dodge the
  ghcr 400 blob limit; test.
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
