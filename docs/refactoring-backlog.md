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

Last groomed: 2026-08-17. LIVE `:latest-cross` = the 2026-08-16 re-ship (digests
amd64 `509027696e16` / arm64 `bdb46c953954` / riscv64 `28e3ded96f72`) which
shipped RP1-3 + AP7-runtime + GST1 + RP6 + AP4(ffmpeg/gst/libcamera) + TS1. A
FULL Batch-2 rebuild is IN FLIGHT validating the staged big wave (AP1-5, opencv
two-pass, TG1, guard-helper wiring — see the top section). Completed items were
deleted from this file 2026-08-17 (lean OPEN-only); done-work records live in
CHANGELOG.md + memory + the archive.

**Windows items live in a SEPARATE Windows backlog** — removed from here
2026-08-15 (was Batch 4 + W3 + W1). This file is Linux/cross-lane only. A few
Windows mentions remain as CONTEXT (a protected-list rule, coverage-map prose),
not as to-do items.

## 🔨 Batch-2 BIG WAVE staged 2026-08-16 (awaiting the bundled 3-arch rebuild)

Owner chose "alles inkl. TG1 + guard-Migration → 1 Rebuild". Implemented + tested
(shellcheck + unit suite 396 + copy-coverage all green), pending the validating
rebuild:
- **AP4 complete** — opencv/litert/onnxruntime/armnn/acl now stripped too (added
  `_resolve_media_strip_bin` self-deriving the cross `<triplet>-strip`, and
  `strip_media_libs` for the shared /usr/local libs).
- **AP5** — CPython `--with-lto` cross+native, `PYTHON_LTO=0` escape hatch.
- **AP3 — ❌ REVERTED 2026-08-17 (80a81eb), re-filed as OPEN.** The bind-mount
  into the package RUN was misplaced: /opt/wheels is COPY'd into the package
  image so Dockerfile.torch (FROM package) inherits it — THAT is where
  setup-torch-venv.sh reads it (`--find-links /opt/wheels`), and torch has no
  artifact-source stage to mount from → all 3 wrappers failed, runtime stage
  re-run with the revert. CORRECT approach for a future attempt: make the
  wheelhouse reachable in Dockerfile.torch's RUN (add an artifact-source-style
  stage/mount THERE), or restructure so the venv assembles in the package image.
  The `rm` mountpoint-guard in setup-torch-venv.sh is harmless and stays.
- **AP2** — `/opt/venv` byte-compiled at build (target python under qemu),
  `VENV_COMPILE=0` gate.
- **AP1** — cross wheels stripped via RECORD-safe `wheel unpack→strip→pack` in
  repair-wheels.sh (corruption-safe: original removed only after a good repack).
- **opencv two-pass** — new `opencv-gst` stage (`FROM gstreamer`) rebuilds OpenCV
  with the source-built /opt/gstreamer (FORCE_REBUILD=1); `final` COPYs it over
  the pass-1 tree. riscv64 reproduces pass-1 (gstreamer OFF upstream).
- **TG1 (bounded)** — cmake.sh + vulkan.sh made lazy in setup-dependencies.sh +
  their dead mounts trimmed from all 3 toolchain RUNs (verified: gcc/eager-set/
  verify never source them; the subcommands invoked here don't install them). A
  cmake/vulkan edit no longer re-runs the 3655s GCC build. The fuller closure
  trim (llvm-cross/validate, 01-core narrowing) stays deferred — higher risk.
- **Guard-helper wiring** — sourced into both common.sh files (guarded);
  layer-order test updated. The 426-site call-site migration stays incremental
  (cosmetic, per-site + mount-gap risk; not worth 426 hand-edits pre-rebuild).
- **RP4 + DUP2 — DEFERRED, no safe form.** RP4: the core/toolchain scripts are
  BOTH consumed by the package RUN AND shipped (can't move below; bind-mount
  split is risky for a ★ cache win). DUP2: no safe code-only subset
  (native-suffix/out-of-scope/deliberate-fallback).

## Next up (recommended order, 2026-08-17)

1. **GPU1+GPU2** [★★★, cheap] — 2-line fixes, validated by ONE opt-in nvidia
   build; independent of the main chain (Batch G).
2. **SMK1-3 + DUPN1 + POS1** [small, coherent] — the Batch-2-wave follow-ups
   (functional gates + tiny dedup + .git cleanup); next closure window.
3. **PAR1** [★★★, big lever] — supervised `--parallel-archs` validation run
   (~15h → ~8-9h full chain).
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

- **SV-residual: compose-CLI validation only** [S] nginx half CLOSED
  2026-08-11: containerized `nginx -t` (nginx:alpine + dummy certs) passed
  "syntax ok / test successful" on the post-surgery config. STRUCTURAL check DONE
  2026-08-16 (no compose CLI on this host): all llm-stack compose files
  (base/gpu/lan) + linux/docker-compose.yml are valid YAML; the lan override's
  !override/!reset tags parse; its overridden services (ollama/open-webui/glances)
  all exist in base and touch only `ports` (the expected LAN-exposure change);
  gpu override (ollama) likewise valid. Remaining (needs a compose CLI): the full
  `docker compose config` schema/interpolation validation (+ the lan override
  merge), and watching the first real `compose up` (SV1 switched ollama to the
  locally built image + healthcheck ordering).

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

First dedicated sweep 2026-08-17 found real defects. Validate with ONE opt-in
nvidia/amd lane build — independent of the main chain.

- **GPU1 — TensorRT silently SKIPPED in the shipped :*-nvidia image** [S·★★★]
  install-cuda-stack.sh:49 `rm -rf /var/lib/apt/lists/*` wipes the indices inside
  the SHARED `id=apt-lib-*` cache mount; the next RUN (install-tensorrt.sh) does
  NO `apt-get update` on its default NVIDIA-apt path (update exists only in the
  local-deb branch, :21) and `2>/dev/null` swallows the "no candidates" error →
  `tensorrt-dev tensorrt-libs` install silently no-ops. Default nvidia images
  likely ship WITHOUT TensorRT despite the LABEL advertising it. Fix: `apt-get
  update` at the top of install-tensorrt.sh's non-local path (and see GPU4).
  Validate by building the nvidia lane once and asserting trtexec/libnvinfer.
- **GPU2 — CUDA verify is fail-open** [S·★★] verify-cuda-stack.sh:70 gates on
  `CUDA_STACK_STRICT` (default 0) and Dockerfile.nvidia:129-131 never sets it →
  a build with nvcc/cuDNN/TensorRT ALL missing still goes green (and would have
  masked GPU1 forever). Fix: `CUDA_STACK_STRICT=1` in the verify RUN.
- **GPU3 — NVIDIA-vs-AMD verify contract mismatch** [M·★★] AMD verifies HARD
  (setup-rocm-repo.sh:74-76 exit 1 on missing hipcc/migraphx) while NVIDIA only
  warns (GPU2). One contract: NVIDIA should match AMD's hard gate.
- **GPU4 — in-cache-mount `rm -rf lists/*` is useless + harmful** [S·★]
  install-cuda-stack.sh:49 + setup-rocm-repo.sh:70 — the mount isn't in the
  layer (real cleanup happens unmounted at Dockerfile.nvidia:110), so the rm
  only defeats caching for later RUNs (and caused GPU1). Drop both.
- **GPU5 — ROCm arm64 guard is a comment** [S·★] setup-rocm-repo.sh:38-45
  promises "fail loudly" on non-amd64 but has no check → generic apt error
  instead. Add `[ "$(dpkg --print-architecture)" = amd64 ] || die`.
- **GPU6 — Dockerfile.nvidia:86 COPY lacks --link** [S·★] (main lane has it).
  Clean per sweep: version-ARG↔versions.env consistency, keyring/GPG sha256
  verification, per-arch cache ids, ENABLE_* gating, script mount coverage.

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
