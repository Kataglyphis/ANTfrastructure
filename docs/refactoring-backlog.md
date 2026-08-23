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

Last groomed: 2026-08-21. LIVE `:latest-cross` = WAVE-4 ship (73927a45/
345096db/da763dc3, manifest 98d90db6) — see § WAVE-4 SHIPPED.
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

## ✅ WAVE-4 SHIPPED 2026-08-21 (validating rebuild survived 9 real mines)

`:latest-cross` = amd64 `73927a45` / arm64 `345096db` / riscv64 `da763dc3`
(manifest `98d90db6`), byte-gate PASS ×3, **cv2 GStreamer:YES verified on
shipped amd64 AND arm64 bytes**. Everything from the closure window is LIVE:
21 version bumps (ORT 1.29 incl. --no_telemetry, LITERT 2.2, TVM 0.26 …),
NET1 mirrors, DF1-4, AP3-correct, PAR2/PAR4(+amend), ccache-content,
prune-safe (12 flawless uses, ~1 TB reclaimed total). Full mine list +
lessons in CHANGELOG. PAR4 verdict: ONE isolated OOM kill across ~12 media
rounds, absorbed by retries — heuristic adequate; PAR4-hard stays
trigger-gated. PAR1 verdict: sdk 2.9× stands; media-parallel WORKS post-PAR2
but a clean full-chain timing needs one undisturbed run (next rebuild).

- **RV1-GST-PC — riscv64 cross pkg-config .pc expansion defect** [M·★★★ →
  LARGELY DISSOLVED 2026-08-21, re-lift validating in wave5c: the
  introspection break was actually MESON-GI (meson 1.12, reproduced with
  clean sysroot — pin 1.11.2 scoped); with introspection back our
  /opt/gstreamer exports working glib .pcs again and pass-2 gst SUCCEEDED
  on riscv64 (videoio links gst libs). Remaining original scope = only the
  ports-.pc wrapper IF ports gst-dev is ever wanted again + freetype-OFF.] ports' riscv64 glib-2.0.pc expands
  prefix/libdir EMPTY in cross pkg-config contexts and POISONS every glib
  lookup once installed (opencv imported targets, libcamera gst element
  compile+link). Additionally our introspection-less /opt/gstreamer exports
  no usable glib .pc for foreign consumers (headers repaired via
  glibconfig-symlink; LIBS unreachable). Current shipped state on riscv64:
  cv2 GStreamer NO (wave-3 parity), libcamera WITHOUT gst element (small
  regression vs wave-3, documented), opencv freetype module OFF. FIX = cross
  pkg-config wrapper that sysroot-prefixes ports .pc vars (or a
  prefix-clean shim set) + optionally re-export glib .pcs from our
  gstreamer install; then re-lift the three scoped OFFs + RV1-GI
  (introspection) in one validated pass.
- **BKD1 — buildkitd session rot under multi-hour parallel load** [M·★★]
  sessions die after ~1-2h ("no active session", grpc cancels at export,
  DeadlineExceeded on cache reads) — cost ~6 retry cycles across the wave-4
  saga; cure each time = daemon restart. Investigate buildkit v0.31.1
  issue trackers / upgrade; interim playbook: restart between chain rounds
  (cachemounts provably survive).

## Next up (recommended order, 2026-08-19)

1. **GPU lane validation build** [★★★, cheap, anytime] — the last staged
   set (GPU1-7) still awaiting its one opt-in build.
2. **Next closure window** — § A below (OCV-FF1 + RV1-GST-PC first).
3. **Next pin-bump window** — § B riders.
4. **Clean PAR1 timing run** — one undisturbed full parallel rebuild.

---

## A. Next CLOSURE WINDOW (01-core / 03-media / Dockerfile closure — ONE rebuild pays for all)

- **OCV-FF1 — opencv FFMPEG try_compile link-dir gap** [M·★★, TRUE ROOT
  FOUND 2026-08-21 → FIX STAGED, validating in wave5c] The swresample-probe
  theory was WRONG (5.0.0 doesn't probe it): the wave-4 logs show
  `WARNING: Can't build ffmpeg test code` — detect_ffmpeg's try_compile
  gets the four -l names but no link dir for the custom /opt/ffmpeg prefix
  → test link dies on transitive libswresample → HAVE_FFMPEG=FALSE. Fix:
  LDFLAGS -L/-rpath-link (ffmpeg AND gstreamer libdirs) + a deterministic
  last-wins -DCMAKE_EXE_LINKER_FLAGS (helpers' own -D beat env). On green:
  promote SMK1's FFMPEG check from advisory to hard (amd64/arm64).
- **D3+P5 — smoke-media gate scaffold + SMOKE_ENV contract** [M·★★] extract
  smoke_resolve_bin/assert_elf_magic/component_gate (6+2+4 dup sites) into
  smoke-common.sh; SMOKE_ENV=sandbox|runtime set by callers. Extend
  test-smoke-arch-parity.sh.
- **CERB-CACHE — cerbero state cachemount (android lanes)** [M·★★★,
  2026-08-22] the whole cerbero bootstrap+package run is ONE Dockerfile
  RUN: any failure (PKGCFG 404, FD-OUTAGE 503, CERB-ICONV) discards ALL
  progress and the next attempt restarts COLD — today that repeated the
  ~40-60 min bootstrap ×3 lanes ×3 waves for zero progress. Give
  /opt/cerbero/sources (+ build-tools prefix) a per-arch cachemount like
  ccache; cerbero's own checksums make reuse safe, and a failed attempt
  then resumes in minutes. Biggest single wall-clock lever for the
  android stage's failure path.
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
- **PKGCFG-MIRROR — cerbero pkg-config bootstrap 404, VALIDATING in
  wave5l** [S·★★, fix ed0ea64] pkgconfig.freedesktop.org is dead and the
  src/mirror fallback 404s → every cold android bootstrap died on
  curl (22). Fix = macports redirect in recipes/pkg-config.recipe
  (byte-identical tarball, recipe checksum still guards). v1 (7047558)
  was a HEISENBUG: file picked via `grep -rl | grep -m1` — readdir order
  is filesystem-dependent, in-container it sed'd a stray patch-file and
  still echoed success. v2 patches the known recipe explicitly + all
  other dead-host refs and echoes the patched url line as proof (echo
  CONFIRMED ×2 in wave5k/5l; bootstrap passed the 404 point). DELETE
  after android ×3 ships. LESSON for reviews: any `grep -rl | head/-m1`
  file-pick is nondeterministic across filesystems.
- **STALE-LOG — per-run log namespacing (re-filed; lost in the July
  restructure)** [S/M·★★★, BIT again 2026-08-22] lane logs are opened
  with `tee -a` and NEVER truncated between waves: android-*.log still
  carried wave5j's 10/6/6 errors when wave5k launched → watcher raised
  false NEW-error alarms; historically also caused stale-green reads.
  Fix: namespace per run (out/build-logs/<run-id>/) or truncate at lane
  start; watchers then need no baseline hack.
- **EIGEN-NET — litert-android's eigen FetchContent single-homes on
  gitlab.com** [S·★★, BIT 2026-08-21] a momentary gitlab outage
  ('fatal: expected flush after ref listing') killed all three android
  lanes in one window. NET1-class fix: mirror fallback (github
  eigen-mirror / codeload tarball) for the eigen dep in the litert android
  build; also covers the media-lane litert eigen fetch.
- **FD-OUTAGE — cerbero's mirror fallback single-homes on freedesktop
  infra** [S·★★, BIT 2026-08-22] a freedesktop-WIDE 503 window (www.x.org
  redirects included) killed all 3 android lanes on the pixman fetch —
  and cerbero's DEFAULT_MIRRORS live on gstreamer.freedesktop.org, i.e.
  the SAME infra as most primaries: zero redundancy, and the gst source
  tarballs themselves come from there too (mirror-patching can't help).
  Wave5k evidence: pkg-config macports override worked (v2 echo ×2),
  pixman then 503'd on primary AND both mirror composions. Options:
  pre-seed hot tarballs via cerbero's cached_sources dir
  (`<checkout>/sources/<name>-<version>/<tarball>`, checksum-verified,
  skips network entirely) for the top-N cold-bootstrap fetches; or just
  accept + wait out outages (they're rare; this was the first).
- **CERB-ICONV — cerbero riscv64-android cold-path link order** [S/M·★,
  BIT 2026-08-22] with NO cerbero cache, android-riscv64's glib links
  before the (lib)iconv product is staged → `undefined symbol:
  libiconv_open` (the lane only ever passed from warm cache before).
  Verify recipe deps (glib ← libiconv) in our cerbero overlay; a worker
  retry resuming cerbero state may mask it — cold-validate explicitly.
- **PAR5 — divisor is static per launch; surviving lanes stay throttled**
  [S/M·★★] BUILD_MEM_DIVISOR is computed at launch (n_arch × budget) and
  never adapts when lanes finish — observed repeatedly: a single remaining
  wheelhouse crawled at 1-2 jobs for HOURS while the host idled (wave4f
  arm64, wave5h riscv64). Options: per-stage divisor from LIVE lane count
  (flag-dir heartbeat), or accept + document. Pairs with PAR4-hard.

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

- **RTCACHE3 provenance rider — re-embed ancestry annotations** [S·★★] the
  `-t` fix dropped the exporter annotations (which never persisted anyway);
  re-add via nerdctl annotate / manifest annotation. XC2/XC3's
  verification half is inert until this emit path works.
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
