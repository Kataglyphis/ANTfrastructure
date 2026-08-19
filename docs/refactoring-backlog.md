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

Last groomed: 2026-08-19. LIVE `:latest-cross` = wave-3 ship (fd0d8d74/
6153d76b/549789b8). **wave-4 validating rebuild IN FLIGHT** (see § Staged).
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
4. Per-arch out/build-logs/*.log persist across runs — mtime-check before
   re-arming watchers.

## 🔨 STAGED — validating in the IN-FLIGHT wave-4 rebuild

One maximal closure window (2026-08-18/19, user call): **B3 bumps** (21
Linux keys: ONNXRUNTIME 1.29, LITERT 2.2+LM 0.16.1, TVM 0.26, VULKAN
.357.1, ABSEIL, UBUNTU_DIGEST …, SHAs re-derived ×2 after the vulkan/TF
incidents), **RV1** (all riscv64 exceptions lifted → target GStreamer:YES
×3 + TLS/SDL), **NET1** (gcc ftpmirror, ffmpeg mirror-vars, gstreamer
gitlab-fallback, nv-codec github-fallback), **DF1-4** (dead cargo mounts,
materialize-llvm-target.sh, soname-loop → copy-media-payloads.sh), **AP3
correct** (wheels-source stage at the READER), **LLVM-ccache-launcher**,
**PAR4 + amend** (divisor × intra-budget for per-arch stages, 1 for shared)
and **CCACHE_COMPILERCHECK=content** (proven: LLVM 50 min vs 11h projected).
This run IS the **PAR1 full-chain parallel measurement** and the **PAR4
no-OOM validation**. On green: delete this section, record in CHANGELOG.

**Batch G (GPU lanes) — GPU1-7 ✅ ALL FIXED 2026-08-17 (e51a0da), awaiting
ONE opt-in nvidia (+amd) validation build** — independent of the chain;
GPU7 alone made the default nvidia build unbuildable. The now-strict verify
asserts nvcc/cuDNN/TensorRT itself.

## Next up (recommended order, 2026-08-19)

1. **wave-4 Endabnahme** (auto, on chain end): byte-gates ×3, RV1 check
   (cv2 GStreamer ×3?), PAR1 numbers, PAR4 verdict, then backlog/CHANGELOG/
   memory fold.
2. **GPU lane validation build** [★★★, cheap, anytime].
3. **Next closure window** — § A below (OCV-FF1 first).
4. **Next pin-bump window** — § B riders.

---

## A. Next CLOSURE WINDOW (01-core / 03-media / Dockerfile closure — ONE rebuild pays for all)

- **OCV-FF1 — opencv FindFFMPEG probe quirk** [M·★★, ROOT-CAUSED] shipped
  /opt/ffmpeg HAS libswresample.so+.pc, but opencv-5.0.0's probe never emits
  a swresample line → HAVE_FFMPEG=NO. Fix opencv-side (OPENCV_FFMPEG_* hints
  or probe patch). SMK1's FFMPEG check stays advisory until then. NOTE:
  check the wave-4 result first — new env may have changed the probe.
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

- **S3 — per-stage registry cache refs (mode=max)** [M·★★] framework stages
  never warm-start from registry; dodge the ghcr 400 blob limit; test.
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
