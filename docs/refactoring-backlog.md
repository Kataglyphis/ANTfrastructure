# Refactoring backlog — OPEN items only, ordered by execution batch

Lean working document (rewritten 2026-08-10): every item here is OPEN and
VERIFIED-current (two-agent currency audit against code + git, 2026-08-10).
Completed/obsolete items and the full observation journal live in
`refactoring-backlog-archive-2026-08-10.md` — consult it for deep evidence;
do not resurrect items from it without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Item-prefix glossary (grown from the sweeps that found them): **AP**=artifact
performance · **RP**=runtime/packaging · **TG**=toolchain build-graph ·
**TS**=toolchain scripts · **GPU**=GPU lanes · **POS**=shipped-image posture ·
**PROV**=provenance · **SMK**=smoke-test gaps · **DUP/DUPN**=duplication
(N=new-code) · **PAR**=parallelism · **MON**=monitoring · **SCC**=sccache/cache
tiers · **S#/C#/D#/P#/A#/F#**=legacy sweep rounds (see archive) ·
**GEN/GST/SV**=genai/gstreamer/services one-offs.
Batches are grouped by REBUILD BLAST RADIUS, not theme — most items are cheap,
rebuilds are expensive. Work top to bottom; each batch ships independently.

Last groomed: 2026-08-18 (post WAVE-3 ship). LIVE `:latest-cross` = the
2026-08-18 wave-3 ship (digests amd64 `fd0d8d74` / arm64 `6153d76b` / riscv64
`549789b8`, byte-gate 3/3, cv2 GStreamer:YES on shipped bytes) — Batch-2 big
wave (AP1/2/4/5, opencv two-pass, TG1) AND the parallel-archs hardening
(PAR2/PAR3/PUSH1/CACHE1 shipped+validated; PAR4 fix staged, validates next
parallel run). Completed items deleted per lean OPEN-only rule; ship records
live in CHANGELOG.md + memory + the archive.

**Windows items live in a SEPARATE Windows backlog** — removed from here
2026-08-15 (was Batch 4 + W3 + W1). This file is Linux/cross-lane only. A few
Windows mentions remain as CONTEXT (a protected-list rule, coverage-map prose),
not as to-do items.

## 🔨 CLOSURE-WINDOW WAVE-4 STAGED 2026-08-18 (validating full rebuild IN FLIGHT)

One window, maximal bundle (user call): **B3 version bumps** (7 SAFE + 14
REPORT keys incl. ONNXRUNTIME 1.29/LITERT 2.2/LM 0.16.1/TVM 0.26/ABSEIL —
SHAs re-derived), **RV1** (all riscv64 exceptions lifted — target GStreamer:
YES ×3), **NET1 top-3+** (gcc ftpmirror, ffmpeg mirror-vars wired, gstreamer
gitlab fallback, nv-codec github fallback), **DF1-4** (dead cargo mounts,
sdk 86-line RUN → materialize-llvm-target.sh, package soname loop →
copy-media-payloads.sh, --link/stray-mount), **AP3 correct** (wheels-source
stage in Dockerfile.torch, package stops baking /opt/wheels),
**LLVM-ccache-launcher** (nested tablegen build). Re-triaged KEEP: SH1
(deliberately different retry semantics), SH2 (documented-deliberate),
DF4c (cosmetic). DEFERRED to the NEXT window (M-effort each; this bundle's
blast radius is already maximal): D3+P5 smoke scaffold, cerbero checksums
table + soundtouch TOFU, codec-map convergence, SUDO run_priv helper,
NVIDIA-lane helper sweep, complexity survivors, DUP2-SSOT-default,
media-source-cache mounts, TVM-cross, SH3 sourced-lib sites.

## Carry-over from the shipped waves (still OPEN)

- **OCV-FF1 — opencv videoio FFMPEG backend NO: opencv-5.0.0 FindFFMPEG probe
  quirk** [M·★★, ROOT-CAUSED 2026-08-18] Byte-verified on the wave-3 shipped
  amd64 wrapper: /opt/ffmpeg/lib HAS libswresample.so AND pkgconfig/
  libswresample.pc, yet opencv's probe reports avcodec/avformat/avutil/swscale
  YES and never emits a swresample line → HAVE_FFMPEG=NO. ffmpeg side is
  CLEAN; fix on the opencv side (patch/hint FindFFMPEG, e.g. OPENCV_FFMPEG_*
  hints or probe patch) in the next media closure window. SMK1's FFMPEG check
  stays advisory until then.

## Next up (recommended order, 2026-08-18 post-ship)

1. **GPU lane validation build** [★★★, cheap] — the staged GPU1-7 fixes,
   validated by ONE opt-in nvidia (+amd) build; independent of the main chain.
2. **PAR4 validation** [rides the next --parallel-archs run] — divisor ×
   PAR_INTRA_STEP_BUDGET staged+function-tested; the next clean parallel run
   from base is ALSO the real PAR1 full-chain measurement.
3. **OCV-FF1 opencv-side fix + AP3 correct re-implementation** — next media
   closure window.
4. **Batch 3 riders** — bundle with the next planned pin bump.

## Standing rules (survived 3 sweep rounds + a currency audit — read first)

1. Never edit versions.env or anything in the 01-core / 03-media bind-mount
   closure outside a Batch 2/3 window — one edit re-runs hours of media compiles.
2. "Guard with tests first" is literal — Batch 1 is DONE (2026-08-10), so
   Batch 2 is unlocked.
3. Respect the protected lists (deliberate dedup, standalone bundling,
   load-bearing case arms, ARG sprawl, LiteRT-LM patch stack, Windows lane
   structure) — three sweep rounds re-verified them as intentionally so.
4. After an aborted chain: `buildctl prune` is part of aborting.
5. Per-arch out/build-logs/*.log persist across runs — stale-log watchers
   false-fire; rm or mtime-check before re-arming (retired for good by O2).

---

## Batch 0 remainder — essentially CLOSED (one investigate item left)

- **post-restart base cache-miss root cause** [M, investigate] one unexplained
  full-miss after a host reboot (archive: 2026-08-08 section). Only actionable
  at the next reboot+run — keep until observed again or absolved.

## Batch S — services lane (llm-stack / webserver; OUTSIDE the chain closure, no unlock needed)

- **SV-residual: watch the first real `compose up`** [S, user-side] the
  compose-CLI validation half CLOSED 2026-08-17: `nerdctl compose` (v2.3.4, was
  overlooked) ran full `config` — schema + interpolation + merge — on ALL FOUR
  combos (base / base+lan / base+gpu / base+gpu+lan): VALID. The
  WEBUI_SECRET_KEY required-var fail-loud fired exactly as designed (validated
  with a dummy value). nginx half closed 2026-08-11. ONLY remaining: watch the
  first real `compose up` (SV1 switched ollama to the locally built image +
  healthcheck ordering) — user-side.

## Batch 2 — the 01-core / in-container closure window (ONE rebuild pays for all)

The high-value Tier 0-2 work (guard-helper wiring, GST1, opencv two-pass, TS1,
TG1, AP1-5) is DONE + staged for the in-flight validating rebuild — see the top
**"Batch-2 BIG WAVE staged"** section. What remains below is the OPEN Tier-3
hygiene items + the investigate items; each still rides a closure-window rebuild.
### New code fixes (2026-08-10 rounds, all evidence-verified)

- **D3 + P5 — smoke-media gate scaffold + SMOKE_ENV** [M·★★] extract
  smoke_resolve_bin / smoke_assert_elf_magic / smoke_component_gate (6+2+4
  duplicated sites) into smoke-common.sh and make the two-environment contract
  explicit (SMOKE_ENV=sandbox|runtime set by callers) instead of six scattered
  "functional gate is the …" branches. Extend test-smoke-arch-parity.sh.
- **GEN1 — (optional experiment) source-build onnxruntime-genai for riscv64**
  [L·★] verified 2026-08-12: the skip is upstream-consistent, NOT our bug —
  PyPI 0.15.2 ships linux wheels only for manylinux_2_28_x86_64 (no riscv64
  in ANY version), genai has no riscv CI/build-docs (unlike core ORT's
  --rv64), and upstream closed the one RISC-V field report (#594, nonsense
  output on LicheePi4A) as "not planned". BUT its CMake is arch-neutral C++
  that dlopens libonnxruntime — which we already source-build on riscv64. An
  IREE-style self-build (runtime wheel via emulated-native or cross) is
  plausible; would retire the STV1/smoke exemption. Risks: no upstream
  test surface on riscv64, #594-class silent-quality failures → needs a real
  generate() smoke, not just import. Do only if genai-on-riscv64 has a user.

- **P3 residual** [S·note] the vulkan Multi-Arch force-overwrite drop-in is
  gstreamer-local by design (cache blast radius); if ANOTHER Multi-Arch: same
  dev package skews on 26.04, generalize into cross-apt.sh.

### Legacy items folded in (verified OPEN by the currency audit)

- **Media source-cache mounts** [S/M·★★] no version-keyed src mounts for
  opencv/gstreamer/ffmpeg/onnx clones — every rebuild re-clones. Pairs with R3.
  (STILL OPEN — S4's 2026-08-12 pass did only the per-file install-deps mount
  narrowing, not the src-clone caches; deferred as its own half.)
- **TVM arm64/riscv64 cross-build** [L·★★] Dockerfile.media:369 is a
  self-described no-op placeholder; cross path in tvm-python.sh:78 never
  wired. Do together with: **TVM builds against distro llvm-config**
  (tvm.sh:198-234 auto-detect, no pin).
- **LLVM nested-build ccache launcher** [S·★] llvm-cross.sh:232
  CROSS_TOOLCHAIN_FLAGS_NATIVE launcher-less; toolchain RUNs emit no ccache
  stats (media does).
- **gcc prereq inconsistency** [M] (forensic#6, archive). SOURCE TRIAGE
  2026-08-15: the headline "inconsistency" (Canadian-cross passes pull in-tree
  gmp/mpfr/mpc/isl via `contrib/download_prerequisites` while native passes use
  the system `lib{gmp,mpfr,mpc,isl}-dev`) is DELIBERATE and documented at
  build-gcc.sh:513-524 — the foreign host can't link amd64 -dev libs, so it must
  build them in-tree; NOT a bug, do not "unify". The genuinely-open facets all
  need a real build to observe/measure, not a source edit: (a) cache the
  sha512.sum/.sig next to the tarball (the 5× refetch caused 3/4 transient
  retries); (b) LIBRARY_PATH possibly leaking into NATIVE sub-build links;
  (c) verify step never exercises the C/ASM cross paths; (d) the #12-vs-#15
  duplicate-compile overlap worth measuring once ccache stats exist. Keep as a
  rebuild-window measurement item; the "make the two prereq paths consistent"
  reading is CLOSED (they're correctly different).
- **DUP1 residual — build-host uname→triplet in cross-apt.sh** [S·★] (vulkan.sh:249
  half done). cross-apt.sh:408-412 — DEFERRED: cross-apt.sh uses NO platform.sh function
    today, so calling build_deb_multiarch_triplet would add a NEW mount dependency
    on platform.sh into every cross-apt RUN. If platform.sh is not mounted there
    the helper returns empty and the pkgconfig candidate is silently dropped (a
    behaviour change, not a crash). Keep the self-contained inline until it's
    confirmed platform.sh is mounted in every cross-apt.sh RUN (Dockerfile.toolchain
    / media / …) — or route it through the guard-helpers migration instead.
  Minor same-family echo fallbacks (unchanged): vulkan.sh:157,
  validate-media-runtime.sh:36.
- **DUP2 — `/opt/gcc-${GCC_VERSION:-16.2.0}` prefix + `16.2.0` literal sprawl
  ~25× across ~11 files** [M·★★] (dup-audit 2026-08-15) the GCC install prefix
  and its magic `16.2.0` default are reconstructed inline instead of via the SSOT
  `gcc_toolchain_prefix()` (cross-gcc.sh:15): validate-compilers.sh (8×: 71/81/
  84/112/129/220/257/593), runtime-paths.env (6×: 9/23/38/39/57/58),
  Dockerfile.media (180/181/762), media-env.sh:31, configure-runtime.sh:50,
  build-gstreamer-stage.sh:84, llvm.sh:297, setup-torch-venv.sh:389-390,
  smoke-cross-all-arches.sh:20, cross-env.sh:405. DRIFT HAZARD — a GCC bump must
  change every `:-16.2.0` in lockstep or a subset silently points at a
  nonexistent prefix (bit before: 16.1.0→16.2.0, archive:2118). Route script-side
  sites through `gcc_toolchain_prefix()`; the `16.2.0` default belongs in ONE
  place. NB: the existing "verify-arg-consistency literal gate" item covers
  CATCHING drift, not this DEDUP — complementary, not a duplicate item. Rides a
  rebuild window (touches media/toolchain closure + Dockerfile.media).
  SCOPE INVESTIGATION (2026-08-15) — this is NOT a clean function-substitution;
  the sites split three ways: (a) NOT in helper scope — validate-compilers.sh
  (220/257 plain) does NOT source cross-gcc.sh, so routing through the helper
  needs a NEW source+bind-mount (the mount-gap hazard) → do it via the
  common.sh/guard-helpers wiring, not a lone source; (b) NOT the same value —
  validate-compilers.sh:129 is `/opt/gcc-…-native-${arch}` (native suffix,
  distinct from the cross prefix) and :146 is a comment; (c) deliberate literal
  FALLBACK for the helper — llvm.sh:297 is the `[ -n "$gcc_prefix" ] ||
  gcc_prefix="/opt/gcc-…"` safety net right after :296 `gcc_toolchain_prefix`
  itself → replacing it is circular, KEEP. So the real fix is SSOT-of-the-default
  (`16.2.0` in ONE spot the fallbacks read) tied to the common.sh sourcing pass,
  not a site-by-site call swap. No safe code-only subset exists standalone.
- **onnxruntime 1.28-vs-1.27 dedupe + CPython decision** [S, investigate]
  (forensic#7). SOURCE-LEVEL RESOLVED 2026-08-15: the git-tag version is
  CONSISTENTLY `v1.28.0` across every authority (versions.env:79 + all script
  defaults `${ONNXRUNTIME_VERSION:-v1.28.0}`). The only `1.27` in source is a
  historical COMMENT (30-build-native.sh:80, about v1.27's build.py rejecting
  --use_armnn) and unrelated pycairo==1.27.0 — NOT an onnx version. The
  "1.28-vs-1.27" is a RUNTIME quirk (the v1.28.0 branch self-reports __version__
  1.27.0) and it is ALREADY HANDLED: smoke-torch-venv.sh:81 asserts against the
  UNION (1.27 source-built lib vs 1.24.4 locked wheel). So there is NO source
  dedup to do. Residual (rolls into C3 below, NOT separate): the two inline
  `:-v1.28.0` fallbacks (onnxruntime/android/build-android.sh:15,
  onnxruntime/build/lib/common.sh:70) mask a broken ARG-forward → convert to
  `:?must be set` with the other android inline fallbacks. Image inspection only
  still needed if the CPython-ABI decision (which py the built .so targets) is
  ever revisited — not blocking.
- **riscv64 ffmpeg network/codec skips** [S/M] TLS via --enable-openssl never
  attempted (build-ffmpeg.sh:202 skip list).
- **codec runtime-list + so-package-map convergence** [M] hand-maintained
  lists in 03-media/runtime/install-deps.sh:53+ and so-package-map.txt vs the
  ffmpeg manifest (third truth source). D4 gives the substrate.
- **cerbero checksums.env class fix** [M] the forge auto-archive re-pin
  (soundtouch override at build-android-from-source.sh:94-111) needs the
  general table; + **soundtouch TOFU re-hash** [S]. (litert-web npm
  dist.integrity verification DONE 2026-08-15: _fetch_npm_package now verifies
  each downloaded tarball against the registry's published `dist.integrity`
  sha512 — mismatch refuses the package, so a tampered/corrupted npm tarball can
  no longer be vendored; metadata-unavailable warns + proceeds. Validated vs the
  live registry: real @litertjs/core@2.5.3 matches, a 1-byte-tampered tarball is
  refused.)
- **GCC_PARALLEL_TARGETS validation** [S] landed gated default-0 (gcc.sh:
  404-494), never validated/enabled.
- **Complexity-queue survivors** [S-M each] tvm-config append_tvm_cmake_args
  15 positionals; vulkan.sh/llvm-cross.sh long stanzas; _cross_stage_build_impl
  (cross-stage-build.sh:12+); build_iree_wheels (build-app-wheelhouse.sh:775);
  parse_options 116-liner (base-image.sh); modules.sh dir-walker unification.
- **NVIDIA-lane helper sweep** [S] install-tensorrt/verify-cuda-stack
  find|head sites, Dockerfile.nvidia:88, smoke-cross-all-arches cross_gpp,
  verify-patch-integrity:59, lint-shell empty-array.

- **SUDO run_priv helper** [M·★] the lint half landed (test-invocation-lints);
  the helper half (append --preserve-env only when sudo is real; ~32 sites in
  vulkan.sh alone) is closure-bound.

### Parallel-archs residuals (from the 2026-08-17/18 hardening saga; shipped parts in CHANGELOG)

- **PAR4-hard — a TRUE memory cap for parallel builds** [M·★★, residual] The
  shipped divisor fix (× PAR_INTRA_STEP_BUDGET) is a heuristic; worst-case
  alignment of heavy TUs can still overcommit. Real cap options: systemd-run
  MemoryHigh per arch build, or a global compile-job governor (jobserver)
  across lanes. Revisit only if a divisor-6 parallel run OOMs again.

### Outage-resilience audit (2026-08-17; motivated by the live GitHub outage)

- **NET1 — github.com is the chain's dominant SPOF; FFmpeg's mirror is DEAD
  code** [S-M·★★★] full fetch-map done (see below). Headline: `FFMPEG_GIT` /
  `FFMPEG_GIT_MIRROR` (build-ffmpeg.sh:60-61) are never used — fetch_ffmpeg()
  downloads ONLY the github archive tarball → falsely-mirrored SPOF. Nearly
  every media/framework fetch (onnxruntime, opencv, armnn/acl, litert, iree,
  tvm, pytorch/vision, abseil, rice, vvdec, llvm-source, gstreamer-github)
  single-homes on github. TOP-3 CHEAPEST fixes (ride the next closure window):
  1. GCC → try ftpmirror.gnu.org first, gcc.gnu.org fallback (sha512 already
     verified — zero trust cost; protects the earliest highest-blast stage).
  2. FFmpeg → wire the dead mirror vars: tarball → clone_or_update_repo
     $FFMPEG_GIT → $FFMPEG_GIT_MIRROR fallback (~5 lines, helpers exist).
  3. GStreamer + nv-codec-headers → second-URL fallback to their canonical
     homes (gitlab.freedesktop.org / git.videolan.org), libcamera-pattern.
  Also cheap: cmake.sh → apt.kitware.com fallback (already wired as a repo);
  CPython → github/python/cpython tag mirror; tvm → git.apache.org [M].
  Vendor-locked (accept): lunarg, dl.google, nvidia, radeon, rustup.
  ALREADY MIRRORED (don't re-audit): libcamera (git.libcamera.org→github),
  libpng (3 sources), cross_compile_cmake_lib_from_source pipe-mirrors,
  apt.llvm.org→source-build fallback, Ubuntu apt (fast-mirror+retries).

### Bump-tool gaps (2026-08-19, found by wave4b's sdk x3 checksum death)

- **BT1 — spec_vulkan must refresh VULKAN_SDK_SHA256** [S·★★] the SAFE write
  bumped the version but the manually-paired SHA (versions.env "bump
  together" recipe) sits outside the tool's refresh net → all 3 sdk lanes
  died on checksum verify. Fold the SHA fetch into spec_vulkan.
- **BT2 — REPORT tier reports git TAGS, not artifacts** [S·★★]
  TENSORFLOW_C's "2.21 available" was a tag; the C tarball stopped shipping
  after 2.18.1 (404). Artifact-existence probe (HEAD request) belongs in the
  report for artifact-based pins. ALSO the empty-download trap: sha256 of a
  silent curl failure is e3b0c442... (= sha256("")) — any SHA-derive helper
  must reject that fingerprint.

### Batch-3 planning data (2026-08-17 freshness snapshot; api.github.com live)

- **B3-PLAN — available pin bumps for the next versions.env window** [ref,
  REFRESHED 2026-08-18 live]: SAFE tier: UV 0.12.3→0.12.5, VULKAN
  1.4.357.0→.1, FLUTTER 3.44.9→3.47.0, OLLAMA 0.32.6→0.32.14 (llm-stack
  only), UBUNTU_DIGEST refresh (full-chain), pandoc/binaryen host-side.
  REPORT tier (one at a time, patch entanglement): ONNXRUNTIME
  v1.28.0→v1.29.0, LITERT v2.1.6→v2.2.0 (+LM 0.15→0.16.1; PROTOC slaved —
  re-derive: new tag still wants 31.1), TVM v0.25→v0.26, PYAV 18.0→18.1,
  ABSEIL 20260526→20260817, TENSORFLOW_C 2.18→2.21 (only if
  FFMPEG_ENABLE_TF=1). NEW via F7 coverage: auditwheel 6.7→6.8.1, meson
  1.11.2→1.12.0, setuptools 83→84, wheel 0.47→0.48. Everything else
  up-to-date (GCC/LLVM/Python/Rust/GStreamer/Node/CMake/IREE/OpenVINO/
  ArmNN/libcamera…). F7 CLOSED same day: all 18 formerly-unclassified keys
  now in REPORT (10 PyPI + libcamera-gitlab) or MANUAL (LT82/FLATPAK-branch/
  SCCACHE_GIT_REV + 4 Windows-lane pins) — freshness report is complete.

### CI-workflow sweep verdict (2026-08-17): CI1-3 all fixed same day (timeouts, ollama digest-pin, env-var login) — commits 814e60f; sweep otherwise CLEAN

CI1: timeout-minutes added to all 5 Linux workflows (python-ci 60 / ubuntu24.04
45 / build-docs 30 / ghcr-cleanup 20 / stale-docs 15). CI2: llm-stack ollama
service digest-pinned (sha256:9d30908e…; bump deliberately, not implicitly).
CI3: registry login secret moved to env-var pattern. actionlint OK. Original
findings kept below for context:


### Idempotency audit verdict (2026-08-17; the GST1 runs-twice class — CLEAN)

Traced the true DOUBLE-RUN set (media final RUN → package re-invocation via
setup-package-image.sh): only **install-deps.sh** and **configure-runtime.sh**
run twice; both are second-run-safe by construction (symlink-guarded mv/ln,
truncate-not-append `write_conf`, idempotent apt/ldconfig; the GST resolver has
its rm-before-resolve + self-match skip). collect-artifacts / repair-wheels /
verify-wheels / validate-media-runtime run once; apply-patch.sh is
reverse-apply-guarded; copy-media-payloads uses `cp -aT`. **No remaining live
sibling of the GST1 bug class** — do not re-sweep without a new double-run path
being added (if one is added, THIS is the checklist to run it against).

### Stale-arch-exception audit (2026-08-17; LIVE-verified against resolute ports)

- **RV1 — the riscv64 availability-exceptions are STALE; ports has caught up**
  [M·★★★] live `apt-cache policy :riscv64` against resolute ports (2026-08-17):
  libgstreamer1.0-dev 1.28.2 ✅, libglib2.0-dev 2.88 ✅, libsdl2-dev ✅,
  libssl-dev ✅, libgnutls28-dev ✅ — all AVAILABLE. Stale exceptions to lift
  (each needs a rebuild-validate; co-installability in the cross sysroot must
  be proven, availability ≠ coinstallable):
  · opencv build-opencv.sh:236-237 `WITH_GSTREAMER=OFF` on riscv64 ("Ports
    cannot satisfy the GStreamer/GLib dev chain" — no longer true; AND the
    two-pass makes it doubly obsolete: pass-2 links OUR source-built
    /opt/gstreamer, which riscv64 builds — lifting this = `GStreamer: YES` on
    ALL THREE arches, full two-pass parity).
  · ffmpeg `--disable-sdl2 --disable-ffplay` on riscv64 (libsdl2-dev now on
    ports) — re-enable + probe.
  · the "riscv64 ffmpeg network/codec skips" item (TLS via --enable-openssl
    never attempted): libssl-dev:riscv64 now exists — unblocked.
  · ffmpeg gnutls skip (:202, "configure probe does not pass") — package now
    exists; re-test the probe (may have been availability all along).
  Rider: riscv64 `WITH_PNG` static-libpng workaround + Node.js lag are NOT
  availability-class (compiler probe / upstream) — unchanged.

### Refactor sweep additions (2026-08-17; Dockerfile idioms + bash patterns + parallel-readiness — all rebuild-window)

- **DF1 — Dockerfile.media:237-238+252-253: dead cargo mounts on the onnxruntime
  RUNs** [S·★★] no ORT build script touches cargo/rust (verified) — 4 mounts
  widen the cache closure of the two most expensive media RUNs (TG1 class). Drop.
- **DF2 — Dockerfile.sdk:72-157: 86-line inline RUN** [M/L·★★] the llvm-target
  materialization (self-copy + symlink repair + DT_NEEDED walk) as one string —
  extract to a COPY'd materialize-llvm-target.sh (toolchain:332 heredoc idiom).
- **DF3 — Dockerfile.package:120-159: ~40-line inline llvm soname-repair loop**
  [M·★★] bolted onto the copy-media-payloads RUN whose script is already COPY'd —
  move the loop into it.
- **DF4 — small Dockerfile hygiene** [S·★ each]: package:111 lone COPY without
  --link (siblings have it); media:671 stray gstreamer-env.sh mount on the
  install-deps RUN (only the build RUN reads it); package:255-264 printf-list →
  heredoc; media:120-155 + :883 readability extractions.
- **SH1 — android-sdk.sh:160+183: identical retry-skeleton ×2** [S·★★] extract a
  local _sdk_retry (canonical retry() in logging.sh:157 doesn't fit the
  grep-success shape).
- **SH2 — packaging-deps.sh:33 error() shadows logging.sh** [S·★] it sources
  common.sh at :27 first — drop the local copy, use err/warn.
- **SH3 — host-side mktemp without trap-cleanup** [M·★] leak-on-error class in 5
  host-run scripts (setup-rootless-binfmt.sh:96, verify-critical-fixes.sh:296,
  cross-env.sh:635, downloads.sh:64, cmake.sh:44) — shared _mk_scratch/trap
  idiom; in-container sites are fine (layer discarded).
  Clean per sweep: version-ARG mirrors (20 checked, zero drift), no dead stages,
  torch USER/HEALTHCHECK ordering, no copy-then-overwrite beyond the deliberate
  two-pass, error-handling/arg-parsing/py-heredocs largely canonical.

### Build-log mining additions (2026-08-17; from the REAL Batch-2 rebuild logs)

- **LOG1 — libfuse3-3 has no install candidate on resolute** [S·★★] requested by
  package-lists.sh:75 + packaging-deps.sh:107, dropped with only a WARN
  (`append_available_packages: requested-but-absent packages dropped`). AppImages
  need libfuse at RUNTIME — if resolute renamed it (libfuse3-4?), the shipped
  image may quietly lack AppImage support. Find the resolute name + update both
  lists; add a smoke that an AppImage actually mounts.
- **LOG2 — onnxruntime-web ships WITHOUT the webgpu JS backend despite
  ORT_ENABLE_WEBGPU=true** [S/M·★★] 50-build-js.sh:87 "Skipping ort.webgpu JS
  outputs: asyncify WASM artifacts are unavailable" (+ jspi) — the wasm build
  flavor that produces asyncify artifacts isn't built. Either build it or
  document the web-webgpu exclusion next to the toggle in versions.env.
- **LOG3 — ffmpeg swscale SPIR-V backend unavailable (spirv-headers missing)**
  [S·★] one-line dep add in ffmpeg install-deps enables a real backend.
- **LOG4 — uv "Failed to hardlink; falling back to full copy" ×32** [S·★] the
  uv cache mount and target sit on different fs views → every venv op pays a
  full copy. Set `UV_LINK_MODE=copy` explicitly (silences the warn, same cost)
  or align the cache mount to kill the copy.
- **LOG5 — libatlas-base-dev has no apt candidate ×3** [S·★] dead request in
  the opencv/media dep lists (OpenBLAS is used anyway) — drop it.
- **LOG6 — `jsonschema` missing → sdk-stage schema validation silently skipped
  ×4** [S·★] (sdk-arm64/riscv64 logs; external tool emits it) — pip-install
  jsonschema in the sdk stage so the validation actually runs.
- **LOG7 — Android `sdkmanager` CLI deprecated ×6** [S·★, watch] upstream says
  "use Android CLI instead" — bit-rot watch for the android stage before Google
  removes it.

### Self-review of the Batch-2 wave code (2026-08-17; new-code dup + smoke gaps)

- **SMK1 — the opencv two-pass has NO functional gate** [S·★★★] the ORIGINAL
  two-pass design called for asserting the shipped opencv reports the
  ffmpeg+gstreamer videoio backends ENABLED — never implemented. Today the
  runtime cv2 smoke checks only import + version major (smoke-torch-venv.sh:253);
  if pass-2 silently produced a gstreamer-less opencv (e.g. the .pc probe
  regresses), everything stays green. Fix: in the runtime torch-venv smoke,
  `cv2.getBuildInformation()` must contain `GStreamer:` YES + `FFMPEG:` YES on
  amd64/arm64 (riscv64 exempt — gstreamer OFF there by design).
- **SMK2 — nothing asserts the AP4/AP1 strips actually happened** [S·★★] the
  size numbers are informational only. Cheap gate: verify-shipped-wrapper
  already tars the rootfs — extract one known lib (libavcodec.so) and
  `readelf -S | grep -c .symtab` == 0 host-side (advisory first).
- **SMK3 — nothing asserts AP2's .pyc exist** [S·★] runtime smoke: assert
  `/opt/venv/lib/python*/site-packages/**/__pycache__/*.pyc` non-empty.
- **DUPN1 — MEDIA_STRIP gate copy-pasted ×9** [S·★] the 3-line
  `[ "${MEDIA_STRIP:-1}" = "1" ] && declare -F …` block is in 9 build scripts.
  Move the MEDIA_STRIP check INSIDE strip_media_prefixes/strip_media_libs/
  strip_cross_wheels (call sites keep only the declare -F guard + `|| true`).
- **DUPN2 — opencv-gst RUN duplicates the opencv stage's build args**
  [accepted·note] deliberate (pass-2 needs the same invocation FROM gstreamer);
  drift risk: an arg added to one build-opencv.sh call must be added to BOTH
  (Dockerfile.media, 2 sites). Keep in sync or single-source via ARG.

### Shipped-image posture additions (2026-08-17 sweep; fresh angles)

- **POS1 — app clone ships WITH its `.git` in the final image** [M·★★]
  assemble-torch-app.sh:39 clones /opt/Kataglyphis-Orchestr-ANT-ion, setup-torch-
  venv.sh:511 pip-installs it — but nothing removes the tree or its `.git`
  (packed objects, remote URL, history) from the shipped uid-1001 image; on
  riscv64 a stray pytorch `torch/` source tree can persist too (comment at
  :466). Attack-surface/hygiene + size + provenance leak. Fix: `rm -rf
  "${APP_DIR}/.git"` (or the whole tree post-install) at the end of
  assemble-torch-app.sh.
- **POS2 — Dockerfile.torch:115 `image.version` label = "Release"** [S·★]
  wired to BUILD_TYPE, not a version. Point at APP_REF/tag; move build-type to a
  custom label. (POS-provenance half — BUILD_DATE/VCS_REF — is Batch 5, pairs
  with the RTCACHE3 follow-up.)
  Clean per sweep: secrets/creds, entrypoint robustness (set -euo + exec),
  USER/permissions (chown, PYTHONDONTWRITEBYTECODE, no world-writable).

### Toolchain deep-sweep additions (2026-08-10, two agents; TG=build-graph, TS=scripts)

- **TG1 residual — fuller toolchain-closure trim** [M·★★] the bounded TG1
  (lazy cmake/vulkan + trimmed their mounts) is done; the fuller trim (llvm-cross/
  llvm-validate lazy, 01-core narrowing to true per-RUN closures) stays deferred —
  the toolchain RUNs have NO whole-dir COPY fallback, so a missed mount = a
  multi-hour break with no cheap validator (copy-coverage.py doesn't resolve
  source_module-by-name). Needs a per-RUN mount audit + a real toolchain rebuild.
- **TG3-residual — RUN-3d does not skip the recompile** [S·★] the TG3/TG4/TG7
  REDO landed + validated 2026-08-14 (wave-2 compiler stage: one unified
  LLVM+clang build/arch, libLLVMSupportLSP installed to both prefixes,
  --strip, minimal profile + clang-tools-22 for clang-tblgen — all confirmed
  live). Residual: the target-clang Dockerfile RUN (3d) still recompiles
  instead of reusing RUN-3's install (the reuse-check doesn't fire across the
  two separate RUNs). ccache absorbs it (~97s vs ~1500s), so the cost is
  small — but to fully realize "one compile per arch" collapse the two
  toolchain RUNs into one (a Dockerfile.toolchain mount-closure change,
  deliberately deferred from the redo to avoid mount risk). Pairs with TG1.
- **TS4 — build-clang.sh reuses an UNVERSIONED cached llvm-project checkout**
  [S·★★] :162/:214 — since the LLVM_CROSS_SOURCE_ROOT fix the checkout
  SURVIVES builds; an LLVM bump silently rebuilds the OLD tag for hours
  (llvm-cross.sh version-keys, this one doesn't). Version-key the dir or
  assert the tag. Fires exactly on the next LLVM bump → also a Batch 3 rider.
- **TS8 — 4th hand-rolled apt-sources copy** — build_python.sh:139-157
  (deletes .sources, hardcodes mirrors + `resolute`, `apt-get update || warn`
  right before TS2's dev-install). Fold into the shared apt-source include
  item below, don't fix standalone.
- **Shared apt-source/mirror include (carried from archive P3-2026-07-17):**
  [S] media+package covered; Dockerfile.nvidia/amd/android + now
  build_python.sh (TS8) still hand-roll. One include, five consumers.


## Batch G — GPU lanes (opt-in; OWN build trigger — needs no chain-closure window)

**GPU1-7 ✅ ALL FIXED 2026-08-17 (e51a0da) — awaiting ONE nvidia-lane validation
build.** GPU1 TensorRT-silent-skip (apt-get update added to install-tensorrt's
NVIDIA-repo path), GPU2/3 fail-open verify → `CUDA_STACK_STRICT=1` (matches
AMD's hard contract), GPU4 both in-cache-mount `rm -rf lists/*` dropped, GPU5
ROCm amd64-guard enforced up front, GPU6 COPY --link, **GPU7 (found during the
fix, worse than GPU1)**: `_trt_deb="$(find …|head -1) || true)"` had the
`|| true` OUTSIDE the substitution — with no staged EULA deb the value was the
literal `" || true)"` → mv failed → set -e killed the RUN: the default nvidia
build couldn't get past deb-staging at all. Validation: build the nvidia lane
once — the now-strict verify asserts nvcc/cuDNN/TensorRT presence itself; also
build the amd lane once (arch-guard + lists-rm change). Clean per sweep:
version-ARG↔versions.env, GPG sha256 verification, per-arch cache ids,
ENABLE_* gating, script mount coverage.

## Batch 3 — versions.env riders (NEVER alone; next planned pin bump)

- **C3 — android inline version fallbacks → `:?must be set`** [S·★★] litert/
  onnx/iree/opencv/gstreamer android scripts carry dead fallbacks that mask a
  broken ARG forward as a silent stale-pin build.
- **pyav dead pin removal** [S] PYAV_VERSION consumed by no Linux consumer
  (Windows ffmpeg uses it — verify before deleting; may be rename-to-clarify).
- **LLVM_COMMIT opt-in key** [S] TVM_COMMIT exists, LLVM_COMMIT absent.
- **setup-package-image residual pins** [S] bare `cmake` + numpy/packaging at
  setup-package-image.sh:283-285.
- **Peripheral pins** [S each] renovate hints, ollama ALLOW_UNVERIFIED,
  ghcr-cleanup token scope (archive: periphery section).
- **TS1 keys** [S] APPIMAGETOOL_<arch>_SHA256 family into versions.env
  (script half is in Batch 2 above).
- **TS4 rider** [S·★★] version-key build-clang.sh's cached llvm-project
  checkout ON the next LLVM bump — that is precisely when the stale-reuse
  bug fires (details in Batch 2).
- **AP6 — ORT_ENABLE_LTO exists, defaults false, NOTHING ever sets it**
  [S·★★] onnxruntime common.sh:453 gates --enable_lto; versions.env has no
  key and no decision comment (never-considered, not deliberate). Flip
  per-arch-gated in the next window, measure inference delta + .so size in
  the validating rebuild; add a DOC1-style comment either way.

- **F6 — triage the stray SHA pins** [M·★★] `bump_versions.py --audit-sha-pairs`
  (opt-in, rc 1 on strays). Progress 2026-08-15: **13 → 3 strays** (10 covered,
  each SHA-VERIFIED against the live upstream BEFORE writing the spec — the
  discipline that caught ABSEIL's non-determinism). Done:
  · TENSORFLOW_C + ROCM_GPG_KEY → `bump:hold` (frozen: last upstream C build / a
    GPG signing key — no version to bump with).
  · RUSTUP_INIT + UV_INSTALL_SH + SCOOP_INSTALLER → audit `allow` set
    (unversioned always-latest installer scripts, hand-reviewed).
  · BINARYEN_LINUX_AARCH64 → spec_binaryen extras (asset verified on version_131).
  · SHELLCHECK_LINUX_X86_64 + SHELLCHECK_WINDOWS → new spec_shellcheck (both SHAs
    verified vs v0.11.0's release assets; download-hash, no sums file upstream).
  · FLUTTER_SDK → spec_flutter now reads `sha256` from the releases JSON it
    already fetches (verified match for 3.44.9).
  · GSTREAMER_ANDROID_UNIVERSAL → new spec_gstreamer (moved from a REPORT lambda);
    reads the `.tar.xz.sha256sum` sidecar freedesktop publishes (verified 1.29.2).
  **REMAINING 3 — genuinely hard, no cheap auto-track:**
  · ABSEIL_TARBALL — pin is a GitHub ARCHIVE tarball (`archive/refs/tags/X.tar.gz`)
    whose SHA is NON-deterministic (GitHub regenerates it — verified the current
    pin already mismatches a fresh fetch). Needs a commit-pinned codeload or a
    content-based verify, not sha256_of_url.
  · ANDROID_CMDLINE_TOOLS — dl.google.com zip, NO published checksums + version
    detection goes through sdkmanager/repository2.xml, not a tag.
  · VULKAN_SDK — LunarG; spec_vulkan gets the version from lunarg.com but the
    ~1GB tarball SHA is in no JSON/sums file (config.json carries only build repo
    config) → would need a full download-and-hash on every bump (heavy).
  Co-locate the scattered pairs (OLLAMA :198 vs :540) when doing them.

## Batch 5 — orchestrator lifecycle (one coherent PR)

- **RTCACHE3 follow-up — re-embed ancestry provenance** [S·★★] the root-cause
  fix shipped 2026-08-15 (runtime-build-fns.sh → plain `-t`; see CHANGELOG +
  memory [[rtcache3-output-tag-bug-2026-08-15]]). The `-t` fix dropped the XC2
  `--output …,annotation.*` exporter that never persisted its annotations to the
  registry anyway (SUPERSEDES the old XC2 annotation-survival gap item). Re-add
  provenance via a locally-tagging method: `nerdctl annotate` / `image convert`
  post-`-t`, or annotate the pushed multi-arch manifest. Correctness of shipped
  bytes came first; this is the cosmetic/provenance rider.
  (The automated post-manifest byte gate — the OTHER follow-up — is DONE:
  `verify-shipped-wrapper.sh`, wired into build-runtime-manifest.sh's per-arch
  loop before the manifest is assembled; asserts the shipped /opt/ffmpeg lib set
  matches the versions.env toggles. Tested: PASS on fresh, FAIL on TF-present-
  with-toggle-off and on broken ffmpeg. WRAPPER_CONTENT_GATE=0 → advisory.)
- **--no-push OCI-layout handoff + dual-path collapse** [M·★★] --no-push
  builds resolve parents against the REGISTRY (two runs lost historically);
  export local stages as OCI layout + --build-context override; couples with
  collapsing the dual local/push paths.
- **PAR1 — validate `--parallel-archs` (the single biggest wall-clock lever)**
  [M·★★★, MEASURED 2026-08-17] the full Batch-2 rebuild ran the per-arch stages
  SEQUENTIALLY: media = 2h18 (amd64) + 3h28 (arm64) + 2h42 (riscv64) ≈ 8.5h,
  sdk ≈ 1h, android ≈ 2h — while the host (32 cores / 60G RAM) sat largely idle
  (runtime lane measured avg 1% / peak 9% CPU; per-stage mem peaks well under
  20G). `--parallel-archs` (+ `--max-parallel-archs`, default 4) already exists
  and BUILD_MEM_DIVISOR is wired for exactly this — it has just never been
  VALIDATED. Potential: full chain ~15h → ~8-9h (slowest arch dominates each
  stage instead of the sum). Do a supervised validation run (watch mem + the
  interleaved logs); riders: the runtime lane builds its 3 wrappers sequentially
  too (same lever, build-runtime-manifest.sh).
- **PROV1 — OCI created/revision labels ship EMPTY** [S·★★] (posture sweep
  2026-08-17; the concrete half of the RTCACHE3 provenance follow-up above)
  runtime-build-fns.sh append_wrapper_build_args never passes BUILD_DATE/VCS_REF,
  so Dockerfile.torch's `org.opencontainers.image.created`/`.revision` fall back
  to their empty ARG defaults on every shipped image. Fix: add
  `--build-arg BUILD_DATE=$(date -u +%FT%TZ)` + `VCS_REF=$(git rev-parse HEAD)`
  in append_wrapper_build_args. (`source`/`licenses`/`title` are fine.)
(XC2 PIN-THREADING + XC3 EXECUTED 2026-08-14: XC2 threads the android pin
digest into the runtime helper (RUNTIME_ANDROID_PIN_<arch>) so the package
build prefers the immutable digest over the mutable tag + a runtime-graph
table (RUNTIME_STAGE_PARENT_MAP) so the ancestry walkers cover the
android→wrapper→package edges — validated: the wave-2 wrapper built FROM the
correct new android digest. XC3's create_manifest coherence gate is LIVE and
validated (warned on the absent-annotation set, passed the same-run check,
did NOT break the push). REMAINING = the "XC2 annotation-survival gap" item
above: the run-id annotation set via buildkit --output does not persist to
the pushed tag, so the provenance-verification half of XC2/XC3 is inert until
that emit path is fixed.)

## Batch 6 — CI / infra ramps (independent — but each residual has its OWN trigger)

- **C4 residual** [S] (a done 2026-08-13: continue-on-error flipped to false
  with a green-run evidence trail). Remaining: move RUFF_PIN=0.14.4 from
  lint-python.sh into versions.env as RUFF_VERSION (Batch 3 rider).
- **S3 — per-stage registry cache refs** [M·★★] inline cache covers only the
  exported image's own layers; framework stages (COPY --from vertices) never
  warm-start from registry → full recompile after any local prune. Per-stage
  mode=max refs dodge the ghcr 400 blob limit; needs testing.
- **S5 — shared cargo cache ids** [S·★] cargo registry/git caches keyed
  per-TARGETARCH duplicate arch-independent downloads 3×.
- **ccache remote_storage tier** [M] evaluate for Linux (comment-only today);
  couples with the user's cross-OS sccache question.
- **Rust sccache unblock** [S] RUSTC_WRAPPER="" pinned empty at
  Dockerfile.toolchain:58 + Dockerfile.package:157; ENABLE_SCCACHE_RUST
  wiring exists and is validated-off — flip in a controlled build.
- **MON1 — resource-monitor stage detection broken** [S·★] (observed 2026-08-17)
  the run summaries show `stage=?` on every sample and the `context` column is
  full of buildkitd stderr spam (`(*service).Write failed…`) — the stage/context
  scrape no longer matches the current log format, so the per-stage attribution
  (the point of the monitor) is blind. Re-derive stage from the per-stage
  `*.log.run` markers or chain-status.json instead of log-grepping.
- **SCC1 — sccache-webdav design (owner question, 2026-08-17)** [M·★★] hybrid
  by compiler, NOT a full switch: keep ccache for gcc/clang C/C++ (direct-mode
  faster locally, mature, already wired), add sccache ONLY where it wins —
  rustc (ENABLE_SCCACHE_RUST exists) and nvcc CUDA kernels (ccache's nvcc
  support is weak; only matters for the opt-in ENABLE_NVIDIA lane), plus the
  shared webdav tier for cross-machine/CI warm-starts (mirrors the Windows
  lane's setup). Absorbs/couples: "ccache remote_storage tier" + "Rust sccache
  unblock" + S5 above. Full-switch rejected: slower per-compile locally
  (mandatory preprocess + network RTT), weaker PCH/edge-case caching, new
  endpoint-down failure mode, re-validation burden across 3 arches.

## Coverage map (2026-08-10) — what "swept" means, and the honest thin spots

SIX sweep rounds + toolchain deep-dive + currency audit have covered: bash
dedup, caching/speed, orchestration/DX, error-masking, test gaps, docs drift,
Windows lane, CI/android/python, architecture/layering, 02-toolchain scripts +
build graph, services lane, runtime/packaging security, artifact performance,
docs pipeline, versions.env structure, base+sdk stages (2026-08-11), and the
cross-stage contract surface (FROM/digest handoffs, ARG forwarding, manifest
tail — 2026-08-11). The chain is swept END-TO-END, base → :latest-cross. Deliberately THIN (sampled, not
exhaustive — re-sweep only with a concrete reason):
- GPU lanes (Dockerfile.nvidia/amd + the 5 CUDA/ROCm scripts): only the
  helper-sweep item exists; opt-in lanes, dedicated sweep never ran.
- Windows psm1 modules (30+): one agent sampled; verdict "better than Linux
  pre-audit", CI-gated — accepted.
- lib/ content beyond source-smoke (slang-compile/code-quality internals):
  unconsumed code, smoke-tested only.
- benchmark-viewer src/: 3 JSX files — trivial.
THE REMAINING DISCOVERY CHANNEL IS RUNS, not more static sweeps: the classes
that matter now (cache-bust latents, foreign-arch-only paths, timing/OOM)
only surface in real rebuilds — which is what the smokes, fix-guards, and
monitors built this session are for.

## Standalone (not batchable)

- riscv64 isa-spec smoke on real hardware (shellcheck-only so far).
- WEBUI_SECRET_KEY server-side rotation (user action).
