# Refactoring backlog — OPEN items only, ordered by execution batch

Lean working document (rewritten 2026-08-10): every item here is OPEN and
VERIFIED-current (two-agent currency audit against code + git, 2026-08-10).
Completed/obsolete items and the full observation journal live in
`refactoring-backlog-archive-2026-08-10.md` — consult it for deep evidence;
do not resurrect items from it without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Batches are grouped by REBUILD BLAST RADIUS, not theme — most items are cheap,
rebuilds are expensive. Work top to bottom; each batch ships independently.

Last groomed: 2026-08-15 (S2 ✅ SHIPPED+VERIFIED — :latest-cross now carries
FRESH digests amd64 f1a205a6 / arm64 d5ae1470 / riscv64 6024f28a, libtensorflow
CONFIRMED GONE by pulling the shipped wrapper. Root cause of the 5× stale-ship
saga was RTCACHE3, NOT RTCACHE1: `--output type=image,name=X` never creates a
local containerd tag on this rootless host, so push+manifest kept resolving the
stale pre-existing tag — FIXED by switching append_runtime_image_output to `-t`.
RTCACHE1's registry-cache theory was a red herring (media+android were always
TF-less). XC2 annotation-survival gap SUPERSEDED by the -t fix (annotations
dropped; provenance re-embed is a follow-up). New knob: RUNTIME_NO_CACHE=1.
Records of done work live in CHANGELOG.md + memory + the archive.)

**Windows items live in a SEPARATE Windows backlog** — removed from here
2026-08-15 (was Batch 4 + W3 + W1). This file is Linux/cross-lane only. A few
Windows mentions remain as CONTEXT (a protected-list rule, coverage-map prose),
not as to-do items.

## ✅ SHIPPED 2026-08-16 (the staged Batch-2 subset — validated by a full rebuild)

The 2026-08-15 staged subset SHIPPED via a full base→:latest-cross 3-arch
rebuild. Fresh manifest: amd64 `509027696e16` / arm64 `bdb46c953954` / riscv64
`28e3ded96f72` (all differ from the prior d92cc0fb/99531bbe/252ca5e8). Byte-gate
PASSED 3/3 (libtensorflow absent); manual amd64 pull confirmed GST1 resolves,
RP6 PATH clean, stripped sizes. **DONE + LIVE:** AP7 media-half, RP6, GST1 root
fix, AP4 (ffmpeg/gstreamer/libcamera), TS1 script half. The real build flushed
out TWO bugs the runtime-lane validations couldn't (they skip smoke-media):
- **numpy/cv2** (fix 0b2b306) — smoke-media native cv2 hard-failed on numpy
  being absent in the media BUILD sandbox (a /opt/venv packaging dep); now
  deferred to the runtime smoke like onnxruntime.
- **GST1 self-link** (fix 22fb812) — configure-runtime runs a 2nd time in the
  package stage; the resolver glob matched the existing lib/multiarch symlink
  and re-pointed it at itself. Fixed: rm the stale link before resolving + skip
  it in the resolver + assert downgraded to WARN (the pkg-config gate is the
  fail-loud authority — a script that runs twice must not carry a fragile
  build-breaking assert).

STILL REBUILD-WINDOW WORK (needs the mount audit / restructure DURING a rebuild,
do NOT land blind): guard-helper wiring+migration (Tier 0), opencv TWO-PASS
(Tier 1), AP4 remainder (opencv5/litert/onnxruntime/armnn), AP1 wheels (RECORD
re-hash), AP3 wheelhouse bind-mount, AP5 CPython LTO (cross-LTO is fragile —
validate), RP4 package layer reorder, TG1 (attempted+reverted — mount audit
mandatory), TG3-residual. BATCH 3 (versions.env): TS1 keys, C3, AP6,
RUFF/pyav/LLVM_COMMIT pins.

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

- **SV-residual: compose-CLI validation only** [S] nginx half CLOSED
  2026-08-11: containerized `nginx -t` (nginx:alpine + dummy certs) passed
  "syntax ok / test successful" on the post-surgery config. Remaining: run
  `docker compose config` (+ the lan override) once on a machine with a
  compose CLI, and watch the first real `compose up` (SV1 switched ollama to
  the locally built image + healthcheck ordering).

## Batch 2 — the 01-core / in-container closure window (ONE rebuild pays for all)

Precondition SATISFIED: T1-T6 harness exists. Sequence inside the batch:
guard helpers FIRST (several refactors below want them), then the rest in any
order, verify-script-copy-coverage green throughout, one full 3-arch validate.

**Priority order within Batch 2** (the batch groups by blast radius; this is the
order to actually WORK them — the item text lives in the sub-sections below):

- **Tier 0 — land FIRST (unblocks refactors):** Named guard helpers.
- **Tier 1 — correctness / real defects (★★★, do next):** GST1 (arm64 dev
  surface dangling in EVERY shipped image), opencv-builds-before-ffmpeg/gstreamer
  (HighGUI/videoIO silently degraded), TS1 (moving `continuous` tag → tamper-
  shaped build death), TG1 (13-wide GCC cache closure — REDO carefully, it was
  attempted+reverted; needs a real toolchain rebuild to validate).
- **Tier 2 — measurable size/perf (★★★/★★):** AP7 media-half FIRST (size
  observability — turns every size item below into numbers), then AP2 (byte-
  compile venv — per-start cost), AP1 (unstripped cross wheels, ~50-300 MB/arch),
  AP4 (strip media prefixes, 5-10%), AP3 (dead wheelhouse layer, 0.5-2 GB/pull),
  AP5 (cross CPython no LTO, 10-30% interp speedup).
- **Tier 3 — hygiene / robustness (★-★★):** D3+P5, A1 (gate half), P3 residual,
  Media source-cache mounts, LLVM ccache launcher, riscv64 ffmpeg skips, codec
  runtime-list convergence, cerbero/soundtouch, GCC_PARALLEL_TARGETS, Complexity-
  queue survivors, NVIDIA-lane sweep, SUDO run_priv, TG3-residual, TS4, TS8 +
  shared apt-source include, RP4, RP6, TVM cross-build.
- **Investigate / experiment (not straight code):** GEN1 (genai-on-riscv64 self-
  build), onnxruntime 1.28-vs-1.27 dedupe, gcc prereq inconsistency (forensic#6).
### New code fixes (2026-08-10 rounds, all evidence-verified)

- **D3 + P5 — smoke-media gate scaffold + SMOKE_ENV** [M·★★] extract
  smoke_resolve_bin / smoke_assert_elf_magic / smoke_component_gate (6+2+4
  duplicated sites) into smoke-common.sh and make the two-environment contract
  explicit (SMOKE_ENV=sandbox|runtime set by callers) instead of six scattered
  "functional gate is the …" branches. Extend test-smoke-arch-parity.sh.
- **A1 — env-knob registry gate** [S/M·★★] 156 cross-boundary `${VAR:-}` knobs,
  no owner. Add a verify-arg-consistency-family gate: every consumed ALL_CAPS
  knob must be set somewhere / in versions.env / in an allowlisted operator
  table (which doubles as the missing docs). Gate itself is host-side (can land
  early). Dead-alias half: UBUNTU_PORTS_MIRROR_URL DONE 2026-08-15 (removed the
  never-set, undocumented inner fallback at cross-env.sh:17). ARCHITECTURES is
  NOT dead — it is a documented operator alias (usage text in
  build-sdk-artifacts.sh + runtime-build-fns.sh) AND the live 3rd fallback in
  resolve_arch_list (artifact-common.sh:51); the "dead 3rd alias" premise was
  wrong, KEEP it.
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

- **Named guard helpers (first_match/probe/csv_each/source_vendor)** [M·★★]
  — land FIRST in this batch; several items below assume them. (~426
  find|head||true-class sites documented in archive.)
  FOUNDATION DONE 2026-08-15: `01-core/guard-helpers.sh` written + fully
  unit-tested (`test-guard-helpers.sh`, 16 assertions; each helper fixes the
  subtle bug its raw idiom repeats — `-print -quit`+`|| true`, real-status probe,
  nounset-state-restoring source, IFS-safe split). NOT yet wired into common.sh
  and NOT yet migrated to the call sites — that step bind-mounts a newly-sourced
  01-core file into every RUN that uses common.sh, so a missed mount = a multi-
  hour build break (the source_module-mount-gap lesson); it rides the next real
  rebuild window. New code can source guard-helpers.sh directly today.
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
- **opencv ⇄ gstreamer two-pass build (DECIDED — owner wants two-pass)** [M/L·★★]
  Problem: opencv builds before ffmpeg/gstreamer (opencv:416 < ffmpeg:539 <
  gstreamer:620, all FROM base), so opencv's HighGUI/videoio is silently
  degraded — but it CANNOT simply be reordered, because gstreamer ships an
  **opencv plugin** and therefore needs opencv built FIRST. Genuine two-way
  dependency (opencv wants ffmpeg/gstreamer for videoio; gstreamer wants opencv
  for its plugin). ⚠ Do NOT flip opencv after gstreamer — that breaks the
  gstreamer opencv plugin.
  **DECISION: implement the THREE-STAGE two-pass build** (this is the wanted
  design, not just one option):
  1. **opencv pass 1** — build opencv WITHOUT ffmpeg/gstreamer (a lean opencv
     that satisfies gstreamer's opencv plugin).
  2. **ffmpeg + gstreamer** — build both against opencv-pass-1; the gstreamer
     opencv plugin resolves.
  3. **opencv pass 2** — REBUILD opencv WITH ffmpeg + gstreamer present, so its
     videoio/HighGUI backends light up fully.
  Ship opencv-pass-2 as the final /opt/opencv5. Keep pass-1 as an intermediate
  (build-stage only, not in the runtime image). Add a media-stage assert that the
  shipped opencv reports the ffmpeg + gstreamer videoio backends as ENABLED
  (`cv2.getBuildInformation()` grep) so a regression to a degraded opencv fails
  loud. Cost: opencv compiles twice (heaviest media lib) — acceptable per owner.
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
- **DUP1 — build-host uname→triplet hand-rolled** [S·★★] (dup-audit 2026-08-15)
  the `uname→triplet` FALLBACK (after the `${DEB_BUILD_MULTIARCH:-}`/
  `dpkg-architecture` probe) duplicated the canonical `build_deb_multiarch_triplet`
  (platform.sh). Equivalence PROVEN on-host (`build_deb_multiarch_triplet` ==
  `uname→sed` == `x86_64-linux-gnu`; map matches all 3 arches).
  · vulkan.sh:249 ✅ DONE 2026-08-15 — SAFE because vulkan.sh already uses
    `arch_normalize` (platform.sh), so the helper adds NO new mount dependency.
    Rides a rebuild-window final-validation (toolchain closure), but it's a
    proven-equivalent + no-new-dep swap.
  · cross-apt.sh:408-412 — DEFERRED: cross-apt.sh uses NO platform.sh function
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

### Toolchain deep-sweep additions (2026-08-10, two agents; TG=build-graph, TS=scripts)

- **TG1 — GCC layer's cache closure is 13 files wide because
  setup-dependencies.sh eagerly sources everything** [M·★★★] the GCC RUN
  bind-mounts llvm*.sh/vulkan.sh/cmake.sh/… (Dockerfile.toolchain:94-106,
  "keep in sync" comment at :67); a one-line vulkan.sh edit re-runs the
  3655 s GCC build + everything downstream (~2.3 h). Fix: lazy per-command
  source_module dispatch, then trim the three mount lists to true closures.
  Also UNBLOCKS the vulkan SUDO-helper refactor cheaply.
  ⚠ ATTEMPTED + REVERTED 2026-08-12: an agent implemented the lazy dispatch
  + trimmed 17 mount lines but was killed mid-trim (Fable session limit) on
  the LLVM RUN, leaving a POSSIBLY-inconsistent per-RUN mount closure. Since
  the toolchain RUNs have NO whole-dir COPY fallback (unlike media/sdk), a
  single missed mount = a multi-hour build break with no cheap validator
  (copy-coverage.py does NOT resolve source_module-by-name — proven this
  session). Reverted setup-dependencies.sh + Dockerfile.toolchain to HEAD
  (the config that shipped :latest-cross). REDO REQUIREMENT: per-RUN mount
  audit (subcommand → lazy arm closure → transitive module deps) PLUS one
  real toolchain rebuild to validate before merging — do not land blind.
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
- **TS1 — appimagetool pinned to the MOVING `continuous` tag** [S/M·★★★]
  ✅ SCRIPT HALF STAGED 2026-08-15 (rides next rebuild). packaging-deps.sh now
  pins the IMMUTABLE versioned tag 1.9.1 (published 2025-11-18, same asset names)
  instead of `continuous`, with the 4 SHA256s updated to 1.9.1's GitHub API
  `digest` values. amd64 asset VERIFIED by real download+sha256 (the arch base
  builds actually fetch — `uname -m` on the amd64 build host); aarch64/armhf/i686
  from the authoritative server-computed digest field. URL now
  `.../download/${APPIMAGETOOL_VERSION:-1.9.1}/<asset>`. This removes the
  tamper-shaped "checksum mismatch" death that fired whenever upstream re-uploaded
  `continuous`. shellcheck-clean. REMAINING (Batch 3 rider, below): move
  APPIMAGETOOL_VERSION + the 4 SHAs into versions.env keys with a cmake.sh-style
  stale-pin guard (needs Dockerfile.base ARG plumbing to forward them).

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
- **GST1 — cross-vs-native gstreamer libdir split (ROOT fix)** ✅ STAGED
  2026-08-15 (rides next rebuild). Root cause: configure-runtime.sh:41-42
  UNCONDITIONALLY `mkdir`ed lib/<triplet> and pointed `multiarch` there, but
  cross builds pass libdir=lib (native installs to lib/<triplet>/), so the
  symlink dangled the entire pkg-config gstreamer-1.0 dev surface on
  arm64/riscv64 in EVERY shipped image (Klasse-B package gate caught it
  2026-08-11). FIX: `resolve_gstreamer_libdir` now points multiarch at whichever
  libdir actually carries gstreamer-1.0.pc (probes lib/<triplet>/pkgconfig →
  lib/*/pkgconfig → lib/pkgconfig, historical default as fallback) — which also
  makes GST_PLUGIN_PATH / GI_TYPELIB_PATH (both route through lib/multiarch/)
  correct on both layouts; ld.so.conf now registers the resolved libdir AND the
  plain lib/ root; plus a fail-loud in-step assert that
  lib/multiarch/pkgconfig/gstreamer-1.0.pc resolves when gstreamer is present
  (skips cleanly otherwise). Edits a file already in the package RUN closure → no
  new mount dep. shellcheck-clean; sandbox-tested → both NATIVE (lib/<triplet>)
  and CROSS (lib) layouts resolve. repair_gstreamer_multiarch_link stays as the
  belt-and-suspenders net. Rebuild proves it on real arm64/riscv64 gstreamer.

### Runtime/packaging + artifact-performance additions (2026-08-10 sweep, RP/AP)

- **AP7 — zero size observability** [S·★★★] runtime half ✅ DONE + REBUILD-VALIDATED
  2026-08-15 (check_size_observability in smoke-runtime-image emitted "per-prefix
  disk usage" on all 3 arches in the verify rebuild). Media half ✅ STAGED
  2026-08-15 (rides next rebuild): `report_prefix_sizes` added to
  verify-media-artifacts.sh — INFORMATIONAL-only (never touches FAILURES), called
  at the always-run `media-inputs` consolidation arm so the `du -sh /opt/* +
  /usr/local/lib/onnxruntime-* | sort -h` breakdown lands with no dedicated
  Dockerfile RUN line; also exposed as an explicit `sizes` stage. Edits a file
  already in the media RUN closure → no new mount dependency. shellcheck-clean,
  smoke-run rc=0. Turns every size item below (AP1/AP4/S2/TG4) into measured
  numbers on the next build.
- **AP1 — cross wheels ship UNSTRIPPED: host strip no-ops on target ELFs**
  [S·★★, MEASURED] media-arm64.log:20304-20347 — `cmake --install --strip`
  runs /usr/bin/strip on arm64 .so → "Unable to recognise the architecture"
  ×every lib (TVM/IREE/ORT cross wheels). CMAKE_STRIP exported (cross-env.sh:
  542) but doesn't reach the wheel step. Fix: forward <triplet>-strip into the
  wheel env or a strip_elf_tree post-pass in repair-wheels.sh. ~50-300 MB/arch.
- **AP2 — /opt/venv never byte-compiled + runtime user can't write
  __pycache__ → EVERY container start re-parses the stdlib+torch** [S·★★★]
  uv doesn't compile by default; venv is root-owned, USER kataglyphis can't
  cache .pyc → the cost recurs per start (seconds-to-tens on riscv64). Fix:
  UV_COMPILE_BYTECODE=1 or compileall -j0 at venv build. +~10% venv size.
- **AP3 — the wheelhouse is a dead layer in every shipped torch image**
  [M·★★] Dockerfile.package:75 COPYs /opt/wheels; setup-torch-venv.sh:492
  rm -rf's it ONE IMAGE LATER (whiteout reclaims nothing) → every pull
  downloads 0.5-2 GB of dead wheels per arch. Fix: bind-mount the wheelhouse
  into the venv RUN instead of COPYing (copy-media-payloads shows the pattern).
- **AP4 — no strip pass over ANY media prefix** [S·★★] ✅ PARTIALLY STAGED
  2026-08-15 (rides next rebuild). Added `strip_media_prefixes` to
  build-helpers.sh (01-core, universally mounted — no new dep): uses ${STRIP}
  (cross-env exports the target <triplet>-strip on cross, host strip on native —
  the AP1 finding that host strip no-ops on foreign ELFs), --strip-all KEEPS
  .dynsym so dynamic linking is unaffected (unit-tested: .symtab 1→0, smaller,
  nm -D still resolves; skips absent dirs; survives set -e). WIRED at end-of-
  install in the 3 scripts where STRIP is proven-live-in-mechanism (they call
  setup_linux_cross_env AND source common.sh→build-helpers): build-ffmpeg.sh,
  build-gstreamer-stage.sh, build-libcamera.sh — each guarded `MEDIA_STRIP=1`
  (default on, =0 disables) + best-effort. The rebuild's functional smokes
  (ffmpeg -version, gstreamer pipelines) are the validation net. STILL OPEN:
  opencv5 / litert / onnxruntime / armnn / acl prefixes — their cross-env
  activation pattern differs per script; wire in the rebuild window after
  confirming STRIP is live at each (helper already handles them via its default
  prefix list). Measure the drop via AP7's new per-prefix numbers. (llvm-target
  = TG4, separate.)
- **AP5 — cross-target CPython built plain -O2: no PGO, no LTO** [M·★★]
  build_python.sh:225-233 (cross configure has neither) vs :471 (native has
  PGO, no LTO). The foreign-arch venv interpreter leaves 10-30% upstream-
  documented speedup on the table. Add --with-lto both paths now; qemu-PGO =
  separate investigation.
- **RP4 — whole-dir 01-core+02-toolchain COPYs sit ABOVE the expensive
  package RUN** [M·★] Dockerfile.package:203-204 — any core-script comment
  edit re-runs the slowest packaging layer ×3 arches. Narrow to consumed
  files or move ship-only copies below the RUN. Riders: :108 COPY-then-rm
  (persists in lower layer; bind-mount instead), :100 missing --link.
- **RP6 — /root/.local/bin baked into PATH of a uid-1001 image** ✅ STAGED
  2026-08-15 (rides next rebuild) — dropped from Dockerfile.package:208 (the
  shipped-image PATH ENV) and runtime-paths.env:25 (the canonical reference);
  Dockerfile.base:77 intentionally KEPT (base builds run as root and legitimately
  install to /root/.local). The advisory verify-runtime-paths only WARNs on
  /opt|/usr/local paths so it was unaffected (rc=0); full unit suite green. Dead
  for kataglyphis (0700 /root) + a PATH-hijack precondition if /root perms ever
  loosened — now gone from the shipped image.

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
