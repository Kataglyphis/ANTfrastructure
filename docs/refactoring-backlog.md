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

## ✅ WAVE-5 SHIPPED 2026-08-23 (closure window 2 — cv2 media stack complete on 3/3)

`:latest-cross` = amd64 `54ab7f01` / arm64 `7bb70a4b` / riscv64 `fb701200`.
**GOAL MET, verified on SHIPPED BYTES (registry-side digest match, not the
push log): cv2 5.0.0 with GStreamer:YES (1.29.2) AND FFMPEG:YES
(avcodec/avformat 63.1.100) on ALL THREE arches** — riscv64 included, which
had been at wave-3 parity (gst: NO). Independently re-verified by executing
real GStreamer + FFmpeg pipelines in the shipped images, not just reading
`getBuildInformation()` strings. Runtime smokes 0 failures ×3; wheel smokes
13/15, 13/15, 11/15 (riscv64 delta = genai + freetype, both documented).
ORT version-shadow FIXED and proven: exactly ONE onnxruntime distribution
per image (dnnl on amd64, webgpu on arm64/riscv64 — by design), no PyPI
1.27 alongside. Landed this window: OCV-FF1 (try_compile link dirs +
FFmpeg-8 avcodec_get_supported_config backport patch), RV1 riscv64 gst
re-lift (+ MESON-GI meson pin), PKGCFG-MIRROR v2, ORT dnnl wheel-family
fix. Mines survived: freedesktop-wide 503 outage, a readdir-nondeterministic
override, an ENOSPC death. Full story in CHANGELOG.

**Wave-4 (2026-08-21, superseded):** amd64 `73927a45` / arm64 `345096db` /
riscv64 `da763dc3`, cv2 GStreamer:YES on amd64+arm64 only. PAR4 verdict:
ONE isolated OOM across ~12 media rounds — heuristic adequate, PAR4-hard
stays trigger-gated. PAR1 verdict: sdk 2.9× stands; a clean full-chain
timing still needs one undisturbed run.

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

## Next up (recommended order, 2026-08-23)

1. **Gate-truth pass** [★★★, no build to author, ONE build to validate] —
   the three gates that currently lie: SMK1-3ARCH (riscv64 exemption on a
   false premise), AP4-SIGPIPE (strip check never runs, prints PASS),
   XC3-INERT (provenance never written). Fixing these before anything else
   means the NEXT build's green is trustworthy.
2. **GPU lane validation build** [★★★, cheap, anytime] — the last staged
   set (GPU1-7) still awaiting its one opt-in build.
3. **Next closure window** — § A, led by CERB-CACHE (the wall-clock lever:
   wave5k/5l discarded a full cold cerbero each) + SMOKE-DEPTH.
4. **Next pin-bump window** — § B riders (+ GENAI-DRIFT, ORPHAN-PINS).
5. **Clean PAR1 timing run** — one undisturbed full parallel rebuild.

---

## A. Next CLOSURE WINDOW (01-core / 03-media / Dockerfile closure — ONE rebuild pays for all)

- **SMK1-3ARCH — promote the cv2 media gate to a HARD assert on ALL
  THREE arches** [S·★★★, EARNED 2026-08-23] OCV-FF1 is CLOSED (FFMPEG:YES
  on 3/3 shipped bytes; fix = try_compile link dirs + the FFmpeg-8
  avcodec_get_supported_config backport patch). Two gate bugs remain, and
  both make a green line lie:
  (a) smoke-torch-venv.sh:275-281 exempts riscv64 from the cv2/GStreamer
      assert and PRINTS "riscv64: gstreamer OFF by design" on the very same
      line where the probe reports `GStreamer=YES FFMPEG=YES` — the premise
      is now false. Delete the exemption (or gate it on the probe) so all
      three arches take the hard assert.
  (b) the FFMPEG check is still advisory — make it a hard assert too.
  Bonus (same file family): build-opencv.sh:146 finds the gstreamer libdir
  via `find … -name 'libgstreamer-1.0.so*' | head -1`, which matches the
  gdb auto-load helper first, so the OCV-FF1 gstreamer -L/-rpath-link half
  is a silent no-op (benign today — pkg-config finds gst anyway).
- **AP4-SIGPIPE — the strip gate has NEVER executed and still reports PASS**
  [S·★★★, 2026-08-23] verify-shipped-wrapper.sh's `nerdctl export | tar
  --occurrence=1` runs under `set -o pipefail`: tar exits after the first
  match, SIGPIPEs the exporter, the pipeline returns non-zero and the check
  self-reports "AP4 strip check skipped (could not extract …)" — on 3/3
  arches — while the wrapper gate still prints PASS. It masks a real
  defect: the shipped amd64 image carries ~1.9 GB of UNSTRIPPED foreign
  cross-compiler binaries (`/opt/gcc-16.2.0/libexec/gcc/{aarch64,riscv64}
  -linux-gnu/16.2.0/cc1plus` 444M/534M with symtab=1, vs 294M/558M total
  for the other arches' whole /opt/gcc). Fix the SIGPIPE swallow FIRST
  (cheap, turns a fake green into a real verdict), then extend the strip
  pass to every triplet under libexec/gcc + /usr/libexec/gcc.
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
- **CERB-ICONV — cerbero riscv64-android cold link-order RACE** [S/M·★,
  CONFIRMED NONDETERMINISTIC 2026-08-23] it bit for real in wave5l
  (`ld.lld: error: undefined symbol: libiconv_open` while linking
  glib/libglib-2.0.so) and then PASSED in wave5m with the same
  glib-before-libiconv ordering and NO code change — so it is a scheduling
  race in cerbero's cold dependency order, not a deterministic bug. The
  real fix is a declared recipe dep (glib ← libiconv) in our overlay; until
  then a retry can mask it and a cold run can lose ~1h.
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

- **XC3-INERT — provenance annotations are never written; the coherence
  gate is permanently blind** [S·★★★, CONFIRMED ON SHIPPED BYTES
  2026-08-23] `append_runtime_image_output()` reduces to `-t "${tag}"` and
  its own comment admits args 3-5 (will_push/parent_pin/parent_stage) are
  "accepted for call-site compatibility but inert" — so every wave-5 image
  shipped WITHOUT run-id or parent-digest, and the manifest step logged
  `3/3 wrapper tag(s) carry no run-id annotation` + `records no parent
  digest` ×3. The gate cannot ever fail, which is worse than not having it.
  It is not hypothetical: this very manifest mixes TWO source revisions —
  amd64 `org.opencontainers.image.revision=58e6c325`, arm64+riscv64
  `5105da8f` (the ORT-fix commit) — visible only because I read the labels.
  FIX: stamp run-id + parent digest as plain `--label`s on the `-t` path
  (labels survive `-t`, unlike the `--output type=image` annotations that
  caused RTCACHE3), and have the manifest gate read labels. Then a
  mixed-generation ship is caught instead of inferred.
- **--no-push OCI-layout handoff + dual-path collapse** [M·★★] --no-push
  builds resolve parents against the REGISTRY (two runs lost historically).

## D. CI / infra / cache tiers (own triggers)

- **S3 — per-stage registry cache refs (mode=max)** [M·★★→★★★, BIT
  2026-08-21] the system-prune wiped local caches and the inline (mode=min)
  registry cache covers only final-image layers → the wave5h relaunch
  COLD-REBUILT all media intermediates (~18 h: torch/IREE/litert ×3).
  Per-stage mode=max refs would have made that a fast-forward. Dodge the
  ghcr 400 blob limit; test.
- **LABEL-REPO — image labels still point at the old repository** [S·★]
  all three shipped images carry
  `org.opencontainers.image.source/url = …/Kataglyphis-DockerHub` while the
  repo is Kataglyphis-ContainerHub — provenance links 404 for anyone
  following them from the registry.
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
