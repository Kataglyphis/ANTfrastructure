# Refactoring backlog — OPEN items only, ordered by execution batch

Lean working document (rewritten 2026-08-10): every item here is OPEN and
VERIFIED-current (two-agent currency audit against code + git, 2026-08-10).
Completed/obsolete items and the full observation journal live in
`refactoring-backlog-archive-2026-08-10.md` — consult it for deep evidence;
do not resurrect items from it without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Batches are grouped by REBUILD BLAST RADIUS, not theme — most items are cheap,
rebuilds are expensive. Work top to bottom; each batch ships independently.

Last groomed: 2026-08-11 (~45 items executed across 2026-08-10; final sweeps
covered base/sdk stages + cross-stage contracts — the chain is now swept
END-TO-END, base through :latest-cross. Every remaining item is blocked on
its batch's unlock condition; XC1 logs/-context fix landed immediately).

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

## Batch 0 remainder — unlock condition: NO chain running

(The free half of Batch 0 + all of Batch 1 was executed 2026-08-10 evening:
21 test suites / 306 assertions now gate the tree. See archive for the list.)

- **S1 — salvage-cache-export on stage failure** [M·★★★] `--cache-to
  type=local,mode=max` only materializes on SUCCESS (cross-stage-build.sh:
  164-168); ~8 h of completed arm64 work exported ZERO cache when a later
  stage failed, and recompiled next run. Fix: on failure re-invoke the same
  build (completed vertices cache-hit in seconds) so the export lands.
  Blocked now: 01-core closure + the file is sourced by the running chain.
- **buildkitd toml pair** [S·★★★] (a) ⚠ REGRESSION: `gckeepstorage=500GB`
  recorded DONE 2026-08-08 is GONE from ~/.config/buildkit/buildkitd.toml
  (only the registry mirror remains); (b) add `max-parallelism` to bound
  intra-arch DAG concurrency (the 2026-08-10 opencv OOM: tvm+opencv+IREE+Dawn
  compiling at once, each ninja sized as if alone). Needs daemon restart.
- **BUILDKIT_STEP_LOG_MAX_SIZE** on the buildkit systemd unit [S] — causal
  WARNs die under the 2 MiB clip. Unit edit + restart.
- **O3 — chain-status.json** [S·★★] workers already persist pin/fail facts
  into PARALLEL_LOOP_FLAGDIR and the join DELETES them (parallel-loop.sh:37,
  47,84). Emit ${LOG_DIR}/chain-status.json (atomic tmp+mv) at stage
  start/pin/fail. Blocked now: edits the running orchestrator.
- **B5 — smoke-runtime-image main() split** [M·★★] ~490 of 524 lines; runs
  host-side so no cache impact, but it is the publish gate — do not refactor
  while a chain is heading toward it. D1 (_rt_run) already landed.
- **kata-buildcache size cap** [S] slugs are unbounded mode=max exports; the
  LRU disk-guard prunes between stages but nothing caps total.
- **CCACHE_MAXSIZE concurrent-arch sizing** [S, investigate] default 10G
  (compiler-cache.sh:38); 3 arches share the mount id per arch — verify hit
  rates justify more.
- **post-restart base cache-miss root cause** [M, investigate] one unexplained
  full-miss after a host reboot (archive: 2026-08-08 section).
- **HC1 — Linux host config as code** [S/M·★★★] windows/buildkitd.toml IS
  checked in; the LINUX buildkitd.toml + systemd drop-ins + nerdctl/containerd
  mirror configs exist only in ~/.config + prose (project-info.md:118,136) —
  which is EXACTLY how the gckeepstorage=500GB regression happened (recorded
  DONE, silently gone, nothing in git). Fix: linux/host-config/ with the
  canonical buildkitd.toml + override.conf + an apply script, AND a preflight
  check diffing the live ~/.config copies against the repo (warn on drift).
  Fold the Batch-0 toml re-do INTO this so it can't regress a third time.

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

### New code fixes (2026-08-10 rounds, all evidence-verified)

- **R1 — TF SDK extraction failure masks as success** [S·★★]
  ffmpeg-dnn-backends.sh:107-120: `tar … 2>/dev/null || true`, then
  generate_pkgconfig_file + return 0 sit OUTSIDE the layout guard → truncated
  tarball = "installed" + live .pc pointing at an empty dir → amd64 silently
  ships without the TF backend (same shape as the fixed download-404 mask one
  line above). Also `mv include … || true` can half-cache the SDK.
- **R2 — TF bundle copy is `|| true` but exec-fatal downstream** [S·★★]
  build-ffmpeg.sh:465-472; neither in-stage gate can see a failed bundle
  (smoke resolves the .so from the CACHE MOUNT via LD_LIBRARY_PATH;
  validate-media-runtime WARNs rc 0 on unresolved NEEDED). 3-line post-assert:
  when _FFMPEG_TF_EXTRA_LDFLAGS set → `[ -f ${FFMPEG_PREFIX}/lib/libtensorflow.so.2 ]`.
- **R3 — clone_or_update_repo returns 0 with NO HEAD** [S·★★] downloads.sh:
  115-140; retry launders a crashed first clone into tolerated-stale rc 0.
  One-line severity split: `_have` empty → return 1. Land WITH the
  source-cache-mounts item below (which arms this class tree-wide).
- **R4 — torch/vision drop CMAKE_TOOLCHAIN_FILE on failure** [S·★★]
  build-app-wheelhouse.sh:522/:647 `|| true`-swallow vs the IREE guard at
  :924 (warn + return 1). Cross-only code → empty toolchain file is never
  legitimate; documented outcome: cmake configures NATIVE x86_64 with a
  riscv64 compiler. Mirror the IREE guard + `|| return 1` on the `cat >`.
- **R5 — opencv install discards stderr from both fallbacks** [S·★]
  build-opencv.sh:571-575 — dies correctly but the WHY (ENOSPC/perms) never
  reaches the log, ~1 h in. Capture + print on failure.
- **D2 — promote retag_directory_wheels to 01-core** [M·★★] 3 hand-rolled
  copies (repair-wheels.sh:22, tvm-python.sh:108, build-app-wheelhouse.sh:379)
  around the shared cross_wheel_platform_tag; 3 skip-filters, 3 python
  launchers. GUARDED by the new T4 assertions.
- **D3 + P5 — smoke-media gate scaffold + SMOKE_ENV** [M·★★] extract
  smoke_resolve_bin / smoke_assert_elf_magic / smoke_component_gate (6+2+4
  duplicated sites) into smoke-common.sh and make the two-environment contract
  explicit (SMOKE_ENV=sandbox|runtime set by callers) instead of six scattered
  "functional gate is the …" branches. Extend test-smoke-arch-parity.sh.
- **D4 — elf_needed_sonames / elf_unresolved_needed primitive** [M·★★] 3
  independent NEEDED-walks (validate-media-runtime.sh:89/:145,
  emit_runtime_apt_manifest, setup-torch-venv.sh:209 ldd variant). Two other
  open items (manifest convergence, P4) want exactly this substrate. Check
  verify-script-copy-coverage before landing (standalone-bundled consumers).
- **P4 — NEEDED-driven bundling** [S·★] generalize bundle_tensorflow_runtime_lib:
  derive "non-apt NEEDED libs to bundle" from the objdump walk (D4) instead of
  naming TF explicitly. TF is the only case today.
- **A1 — env-knob registry gate + dead-alias deletion** [S/M·★★] 156
  cross-boundary `${VAR:-}` knobs, no owner. Delete dead aliases ARCHITECTURES
  (resolve_arch_list 3rd alias) + UBUNTU_PORTS_MIRROR_URL (cross-env.sh:17);
  add a verify-arg-consistency-family gate: every consumed ALL_CAPS knob must
  be set somewhere / in versions.env / in an allowlisted operator table
  (which doubles as the missing docs). Gate itself is host-side (can land
  early); the deletions are closure-bound.
- **A3 — drop abseil-headers.sh from the artifact-common loop** [S·★] dead-
  loaded into every orchestrator (install_abseil_headers has no host-side
  caller; verify-critical-fixes sources the file directly). Optional polish:
  move the CUDA/ROCm five out of 01-core (gpu/ or 02-toolchain).
- **S4 — per-file deps mounts** [M·★★] component install-deps RUNs mount the
  whole component dir (Dockerfile.media:552-557 ffmpeg; same for opencv/
  gstreamer/libcamera) → every build-script edit re-pays apt (10-20 min/arch).
  Precedent: the per-file 01-core COPYs at Dockerfile.media:114-117.
- **C1 — Cerbero apt install is `|| true`** [S·★★] build-android-from-source.sh:
  354-364, ~40 packages; mirror outage = inscrutable bootstrap failure hours
  later. Drop `|| true`; cross-apt retry pattern if tolerance wanted.
- **C2 — android-sdk.sh success-detection** [S·★★] :122-146 "Done." grep
  overrides rc≠0 (partial installs print it per package); :149/:170 licenses
  downgraded to echo; :151-167 duplicated 7-package list. Direct
  sdkmanager_install + fatal licenses + NDK-dir postcondition.
- **T1 contract surprises** (from writing test-cross-apt.sh): rename/re-comment
  cross_package_files_present (checks dpkg ${Status}, NOT files — name and
  caller comment both stale); give _CROSS_ENV_APT_UPDATED a `:-` default
  (standalone sourcing under set -u crashes); surface per-package apt rc in
  the retry loop (diagnosability).
- **P3 residual** [S·note] the vulkan Multi-Arch force-overwrite drop-in is
  gstreamer-local by design (cache blast radius); if ANOTHER Multi-Arch: same
  dev package skews on 26.04, generalize into cross-apt.sh.

### Legacy items folded in (verified OPEN by the currency audit)

- **Named guard helpers (first_match/probe/csv_each/source_vendor)** [M·★★]
  — land FIRST in this batch; several items below assume them. (~426
  find|head||true-class sites documented in archive.)
- **Media source-cache mounts** [S/M·★★] no version-keyed src mounts for
  opencv/gstreamer/ffmpeg/onnx clones — every rebuild re-clones. Pairs with R3.
- **NDK/SDK shared download cache** [M·★★] android-sdk stage re-downloads
  per arch (Dockerfile.android:8,70-76; android-sdk.sh:156).
- **TVM arm64/riscv64 cross-build** [L·★★] Dockerfile.media:369 is a
  self-described no-op placeholder; cross path in tvm-python.sh:78 never
  wired. Do together with: **TVM builds against distro llvm-config**
  (tvm.sh:198-234 auto-detect, no pin).
- **LLVM nested-build ccache launcher** [S·★] llvm-cross.sh:232
  CROSS_TOOLCHAIN_FLAGS_NATIVE launcher-less; toolchain RUNs emit no ccache
  stats (media does).
- **opencv builds before ffmpeg/gstreamer exist** [M/L·★★] stage order
  (opencv:416 < ffmpeg:539 < gstreamer:620, all FROM base) — opencv's
  HighGUI/video IO capabilities silently degraded; reorder or two-pass.
- **gcc prereq inconsistency** [M] (forensic#6, archive) — unchanged.
- **onnxruntime 1.28-vs-1.27 dedupe + CPython decision** [S, investigate]
  (forensic#7) — needs image inspection.
- **riscv64 ffmpeg network/codec skips** [S/M] TLS via --enable-openssl never
  attempted (build-ffmpeg.sh:202 skip list).
- **opencv cross packages all-optional** [S] opencv/install-deps.sh:50-56
  routes everything through install_optional_target_packages on arm64/riscv64
  — a ports outage silently strips features.
- **codec runtime-list + so-package-map convergence** [M] hand-maintained
  lists in 03-media/runtime/install-deps.sh:53+ and so-package-map.txt vs the
  ffmpeg manifest (third truth source). D4 gives the substrate.
- **wheel-family classifier** [M] the same glob verbatim ×3 in
  assemble-torch-app.sh:130/154/325; rides D2/T4.
- **csound-sys patch-retry** [S] build-gstreamer-monorepo.sh:556 expected-
  failure-then-patch-then-retry; convert to patch-first.
- **cerbero checksums.env class fix** [M] the forge auto-archive re-pin
  (soundtouch override at build-android-from-source.sh:94-111) needs the
  general table; + **soundtouch TOFU re-hash** [S] and **litert-web npm
  dist.integrity verification** [S].
- **setup_gi_cross_wrappers decomposition** [M·★★★] still one ~220-line
  function (pre-setup.sh:190); its own recorded plan: dedicated sub-pass with
  generated-wrapper content-diff.
- **base/toolchain noise riders** [S] update-alternatives man-skip spam;
  MAKEINFO=true (or texinfo) for the "Makeinfo is missing" warnings.
- **GCC_PARALLEL_TARGETS validation** [S] landed gated default-0 (gcc.sh:
  404-494), never validated/enabled.
- **Complexity-queue survivors** [S-M each] tvm-config append_tvm_cmake_args
  15 positionals; vulkan.sh/llvm-cross.sh long stanzas; _cross_stage_build_impl
  (cross-stage-build.sh:12+); build_iree_wheels (build-app-wheelhouse.sh:775);
  parse_options 116-liner (base-image.sh); modules.sh dir-walker unification.
- **NVIDIA-lane helper sweep** [S] install-tensorrt/verify-cuda-stack
  find|head sites, Dockerfile.nvidia:88, smoke-cross-all-arches cross_gpp,
  verify-patch-integrity:59, lint-shell empty-array.
- **verify-media-artifacts orphan branches** [S] armnn/onnxruntime-gpu
  branches (:184/:304) reference artifacts no stage produces.
- **SUDO run_priv helper** [M·★] the lint half landed (test-invocation-lints);
  the helper half (append --preserve-env only when sudo is real; ~32 sites in
  vulkan.sh alone) is closure-bound.

### Base/SDK + cross-stage-contract additions (2026-08-10/11 sweep, BS/XC)

- **BS1 — Dockerfile.sdk whole-dir 01-core+02-toolchain COPY above the two
  ~14-min RUNs** [M·★★★] :53-54 above Vulkan (859 s arm64) + TVM (846 s)
  RUNs; editing ANY of ~120 files re-runs both ×3 arches + cascades. Base got
  the traced closure (A1 DONE), toolchain has TG1, package has RP4 — sdk is
  the uncovered link of the same class. Rider: :119 whole-dir 05-frameworks.
- **BS2 — SDK-stage TVM compiled 3× per chain (~40 min), zero ccache reuse,
  against distro llvm-config** [M·★★] all three sdk builds run amd64-native
  tvm.sh with per-TARGET ccache ids → nothing shared; archive already flagged
  "built then wiped by media uv venv --clear". Drop the RUN or hoist to one
  shared stage — ONE decision together with the two open TVM items.
- **BS3 — /opt/llvm-target 'verification' is decorative on cross arches**
  [S·★★] Dockerfile.sdk:94 `clang --version || true` — the 2026-08-10 logs
  show it FAILING on arm64+riscv64 (target ELF can't exec on amd64); only mv
  existence is really gated. Replace with `test -x` + elf_machine_name assert
  vs TARGET_ARCH. Verify-only edit = cheap.
- **BS4 — base-image.sh stale third-channel fallbacks incl. FIVE dead SHAs**
  [S·★★] :23 node 26.5.1 (pin 26.7.0), :24 uv 0.12.1 (0.12.3), SHA fallbacks
  :304/:308/:371/:375/:379 all ≠ versions.env — a half-load regression
  surfaces as a tamper-shaped checksum failure. Delete the SHA fallbacks
  (`:?`) — a SHA fallback is NEVER legitimate divergence; promote *_SHA256 to
  fatal in the drift checker (that half rides TS5, host-side).
- **BS5 — riscv64 nodejs silently unpins** [S·★] base-image.sh:314 exact-pin
  `|| apt_install nodejs` falls through to ANY version, no warning; :315
  `npm || true` contradicted by :317 under set -e. Loud fallback + major
  assert.
- **BS6 — install_os_packages: ~90-pkg root layer, zero postcondition,
  silent availability-drops** [S·★★] append_available_packages drops
  apt-cache misses without a log (clang/lld/valgrind droppable!); the
  opencv-all-optional class at the ROOT of every image. Requested-but-absent
  summary + must-have assert (git/ninja/ccache/python3/pkg-config).
- **XC4 — ONNX_PACKAGE / PYTORCH_EXTRA documented as operator overrides but
  DEAD at the seam** [S·★★] runtime-build-fns.sh:299-300 advertises them;
  append_wrapper_build_args forwards neither; Dockerfile.torch declares no
  ARG (bakes CPU values). The documented GPU path silently builds a CPU venv
  — and smoke-torch-venv validates against the BAKED env, so it can't catch
  it. Wire (ARG→ENV + forward) or delete the doc lines. THIRD dead name found
  by the new class-guard test (2026-08-11): TORCH_DOCKERFILE_PATH is
  documented but the build consumes WRAPPER_DOCKERFILE_PATH (:200). The
  class-guard test (test-env-contract.sh) carries all three as KNOWN_DEAD —
  it turns red if you fix this without pruning that list.
- **XC5 — wrapper-smoke stage is manual-only; two Dockerfile comments
  disagree about smoke-vulkan** [S·★] Dockerfile.android:222-224 claims it
  runs in wrapper-smoke; Dockerfile.package's tail note says it is wired
  NOWHERE (package is right). Fix the android comment (window rider);
  optional opt-in orchestrator flag to build --target wrapper-smoke per arch
  (coordinate with B5, Batch 5).
- **XC6 — Dockerfile.package BASE_IMAGE default = amd64-only :base** [S·★]
  the one wrong default on the FROM graph (all five cross-lane defaults
  verified correct); Dockerfile.torch:3-7 shows the TARGETARCH-parameterized
  fix pattern. Manual arm64 package builds FROM the wrong arch today.
- **XC7 — VULKAN_VERSION double-forwarded (hand + auto)** [S] stage-defs.sh:
  262 duplicates append_version_build_args' auto-forward — a drift seed
  (marker edits change which copy wins). Delete the hand-forward + a
  verify-arg-consistency rule: no literal --build-arg X= for auto-forwarded X.

### Toolchain deep-sweep additions (2026-08-10, two agents; TG=build-graph, TS=scripts)

(TG6 — a static gate for the PR100017 -nostdinc++ patch — was landed same-day
as fix10 in verify-critical-fixes.sh, 3 assertions green. TG5 confirmed the
monolithic GCC RUN is acceptable: ccache absorbs retries; the real lever is
the already-listed GCC_PARALLEL_TARGETS validation.)

- **TG1 — GCC layer's cache closure is 13 files wide because
  setup-dependencies.sh eagerly sources everything** [M·★★★] the GCC RUN
  bind-mounts llvm*.sh/vulkan.sh/cmake.sh/… (Dockerfile.toolchain:94-106,
  "keep in sync" comment at :67); a one-line vulkan.sh edit re-runs the
  3655 s GCC build + everything downstream (~2.3 h). Fix: lazy per-command
  source_module dispatch, then trim the three mount lists to true closures.
  Also UNBLOCKS the vulkan SUDO-helper refactor cheaply.
- **TG3 — LLVM core is cross-compiled TWICE per target arch** [M·★★]
  target-llvm (~9 min/arch, for TVM's llvm-config) then target-clang rebuilds
  the same core (llvm-cross.sh:209-236, only ENABLE_PROJECTS differs).
  Collapse to one build per arch; COORDINATE with the TVM llvm-config pin
  item above (same consumer).
- **TG4 — target LLVM installs never stripped, shipped wholesale** [S·★★]
  `cmake --install` without `--strip` (llvm-cross.sh:294; CMAKE_STRIP is
  already set at :253) while build-gcc.sh strips everything; /opt/llvm-target
  is COPY'd into the runtime image (Dockerfile.package:100). Compiler-image
  push alone took 1479 s. One flag; measure du in the next build.
- **TG2 — zero ccache observability in the compiler stage** [S·★] 1526
  launcher invocations, zero stats blocks (media prints full stats). Add
  `ccache -z`/`-s` per phase in build-gcc.sh/llvm-cross.sh — makes the
  Batch-0 CCACHE_MAXSIZE item decidable with data.
- **TG7 — host-LLVM apt profile defaults to `full`** [S, investigate]
  flang/bolt/mlir/libclc/lldb ride every downstream image (llvm.sh:440-456);
  a `minimal` profile exists but no consumer audit does. Audit, then flip or
  document.
- **TS1 — appimagetool pinned to the MOVING `continuous` tag with 4 in-script
  SHA256s** [S/M·★★★] packaging-deps.sh:144-176, required-mode in the BASE
  stage → upstream re-uploads its continuous assets ⇒ next cache-miss build
  dies with a tamper-shaped "checksum mismatch". Pin a dated asset or vendor;
  move pins to APPIMAGETOOL_*_SHA256 in versions.env (keys = Batch 3) with a
  cmake.sh-style stale-pin guard.
- **TS2 — cross-target CPython dev packages: one raw atomic apt || warn;
  extensions warn-only; smoke checks host only** [M·★★★] build_python.sh:
  162-170 bypasses install_target_packages (no per-package fallback → the
  libxml2-16 class silently drops ALL 8 dev packages); _ssl/_sqlite3/zlib…
  classified OPTIONAL at :350-356; smoke-toolchain's fatal stdlib battery
  runs on the HOST interpreter only (:190-203). Fix: port the fallback loop,
  promote explicitly-installed exts to fatal, add lib-dynload .so asserts to
  the cross-staging smoke block. (Also: the bare `libbz2-dev` at :168
  installs the BUILD-arch package — qualify it.)
- **TS3 — no structural CPython dev-package parity: the 2026-08-09
  libsqlite3-dev fix was a point patch** [M·★★★] three independent truths
  (host package-lists.sh:77, cross list build_python.sh:164-168, the two
  ext-assert lists) — host closure otherwise rests on TRANSITIVE pulls from
  GUI dev packages. One CPYTHON_EXT_DEV_PKGS table in 01-core consumed by all
  three; a PYTHON_VERSION bump then cannot desync host and target.
- **TS5 — three version-fallback literals escaped verify-arg-consistency**
  [S·★] cross-gcc.sh:15 + llvm.sh:297 (`gcc-16.2.0`), smoke-toolchain.sh:35
  (`22.1.8`) — a GCC/LLVM bump makes the smoke gate FAIL the correct build.
  Add to the checker's literal diff. (Checker lives in 01-core → closure-
  bound, despite being host-run.)
- **TS6 — vulkan cross-targets: no aggregate verdict; header-staging cp is
  `2>/dev/null || true`** [S·★★] loader/SPIRV/glslang each tolerated by
  design (vulkan.sh:419-523) but all-3-failed (one env-shaped cause) still
  exits 0; :440-443 masks real cp failures as "source absent". Add a summary
  line + all-failed die; split the cp guard. Rides the vulkan T2 stanza item.
- **TS7 — configure-gcc-env.sh does unanchored sed surgery on
  /etc/environment** [S·★] :12-20 substring-strips values (prefix-nesting
  corrupts sibling entries; unescaped pattern) and masks the delete step
  (`|| true` → duplicate lines). Rebuild by exact-entry filtering.
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
- **Batch-1 leftovers (folded here — the harness batch closed without them):**
  cross-wheel SOABI/default-triple assert [M] (verify-wheels checks filename
  tags only — a wrong-SOABI wheel installs and fails at import on-target);
  forensic#3 smoke inner-warning propagation [S] (smoke-media:266
  assertion-free "(import failed in build sandbox)" PASS).

### Runtime/packaging + artifact-performance additions (2026-08-10 sweep, RP/AP)

- **AP7 — zero size observability FIRST** [S·★★★] the 42.66 GB media image
  has no per-prefix breakdown anywhere. One `du -sh /opt/* …|sort -h` block in
  verify-media-artifacts.sh + smoke-runtime-image turns every size item below
  (and S2/TG4) into measured numbers on the very next build. Do before the
  others.
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
- **AP4 — no strip pass over ANY media prefix** [S·★★] strip_elf_tree has
  exactly 2 callers (gcc, clang); /opt/ffmpeg, /opt/opencv5, gstreamer,
  litert, onnxruntime, armnn, libcamera all ship symbol tables. One pass per
  prefix (cross <triplet>-strip). Inferred 5-10% of .so payload. (llvm-target
  = TG4, separate.)
- **AP5 — cross-target CPython built plain -O2: no PGO, no LTO** [M·★★]
  build_python.sh:225-233 (cross configure has neither) vs :471 (native has
  PGO, no LTO). The foreign-arch venv interpreter leaves 10-30% upstream-
  documented speedup on the table. Add --with-lto both paths now; qemu-PGO =
  separate investigation.
- **RP1 — final image ships a setuid sudo NOBODY can use** [S·★★ security]
  package-lists.sh:76 installs it; Dockerfile.torch:79-85 removes only the
  FAKE shim; no sudoers/group grants exist → pure LPE attack surface (sudo
  CVE stream). Purge in the final stage + a setuid-inventory assert in
  smoke-runtime-image (cheap wrapper-layer rebuild only).
- **RP2 — cleanup scripts wipe the SHARED apt cache mounts, contradicting the
  Dockerfile's own comment** [S·★] setup-package-image.sh:402-403 +
  setup-torch-venv.sh:219/240/273 `apt-get clean; rm -rf /var/lib/apt/lists`
  inside sharing=locked cache mounts (Dockerfile.package:262-264 explicitly
  says not to). Zero size benefit (mounts never commit); parallel arches
  re-download metadata. Guard with `mountpoint -q || …`.
- **RP3 — HEALTHCHECK timeout 5s too tight for cold ORT import** [S·★]
  Dockerfile.torch:94-95 — cold import of a multi-hundred-MB .so on riscv64/
  qemu plausibly >5 s → unhealthy-flapping. Raise timeout ~30 s (only bounds
  the failure path).
- **RP4 — whole-dir 01-core+02-toolchain COPYs sit ABOVE the expensive
  package RUN** [M·★] Dockerfile.package:203-204 — any core-script comment
  edit re-runs the slowest packaging layer ×3 arches. Narrow to consumed
  files or move ship-only copies below the RUN. Riders: :108 COPY-then-rm
  (persists in lower layer; bind-mount instead), :100 missing --link.
- **RP6 — /root/.local/bin baked into PATH of a uid-1001 image** [S·★]
  Dockerfile.package:168 + canonicalized in runtime-paths.env:25. Dead for
  kataglyphis (0700 /root); PATH-hijack precondition if /root perms ever
  loosen. Drop from both.

## Batch 3 — versions.env riders (NEVER alone; next planned pin bump)

- **DOC1** [S·★] toggle comments contradict values: :81 WebGPU "(default
  off)" above `=true`; :112 x265 "kept off" above `=1`.
- **S2 — FFMPEG_ENABLE_TF gate** [S·★★★] TF backend ungated → ~500 MB
  (libtensorflow 447MB + framework 50MB) in every amd64 media+runtime image
  for one optional DNN backend; mirror FFMPEG_ENABLE_X265 exactly (default
  off). Also removes the R1/R2 failure surface from the default lane.
- **C3 — android inline version fallbacks → `:?must be set`** [S·★★] litert/
  onnx/iree/opencv/gstreamer android scripts carry dead fallbacks that mask a
  broken ARG forward as a silent stale-pin build.
- **W3 — sha-pins for the thin Windows download sites** [S·★★] vcpkg tag zip,
  get-pip.py (+ ExpectSignature everywhere); rustup floating by decision.
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
- **F5 — THIRD stale versions.env comment (beyond DOC1's two)** [S] :115-117
  claims OPENCV tracks "a live BRANCH (non-reproducible)" directly
  contradicting :103-106 (pinned tag 5.0.0); header :7-9 still describes the
  pre-enforcement ARG-default era (sync_versions now ENFORCES them). Fold
  both into the DOC1 edit.
- **F6 — triage the 13 stray SHA pins the new audit found** [S/M·★★] the
  checker LANDED (`bump_versions.py --audit-sha-pairs`, opt-in, rc 1 on
  strays) and its first run lists exactly which pins have NO refresh spec,
  NO bump:hold, NO allowlist: ABSEIL_TARBALL, ANDROID_CMDLINE_TOOLS,
  BINARYEN_LINUX_AARCH64, FLUTTER_SDK, GSTREAMER_ANDROID_UNIVERSAL,
  ROCM_GPG_KEY, RUSTUP_INIT, SCOOP_INSTALLER, SHELLCHECK_LINUX_X86_64,
  SHELLCHECK_WINDOWS, TENSORFLOW_C, UV_INSTALL_SH, VULKAN_SDK (_SHA256 each).
  Per key: add to the owning bump spec's extras, `bump:hold`-annotate
  (TENSORFLOW_C is documented do-not-bump but never annotated!), or allowlist
  with justification — all versions.env edits → THIS window. Then co-locate
  the scattered pairs (OLLAMA :198 vs :540 etc.) in the same pass.

## Batch 4 — Windows rebuild-window riders (lane rule: script edits ride pin bumps)

- **W2 — -Require classification for inline patches** [M·★★★] 37 sites
  warn-and-continue on anchor miss, 25 discard the boolean; two recorded
  "cost one container run" incidents. Load-bearing sites get -Require.
- **W1b remainder — fix the 3 drifted defaults** [S·★★] GIT_VERSION '2.54.0'
  → 2.55.0 (setup-scoop-tools.ps1:105); WIX_UI_EXT_VERSION '4.0.4' → 4.0.6
  (setup-scoop-tools.ps1:128 + verify-toolchain.ps1:122). The PinParity suite
  tracks them as [pend] — fixing WITHOUT removing them from
  $script:KnownDriftAwaitingRebuildWindow turns it red. Adjacent:
  windows/Dockerfile.nvidia:53 is a third shadow-default (in sync today).
- **🔴 nv/target.h host-only stub** [S·★★] setup-cuda.ps1:103-122 writes an
  NV_IS_HOST=1 stub whenever target.h is absent — including over a REAL
  extensionless `nv/target` (the reported case). Forwarding include instead.
- **W4 — Invoke-ShieldedNative migration** [M·★] ~25 hand-rolled pairs left;
  continue only inside scheduled rebuild windows (their own plan).
- **Test-CniHealth unification** [S] the two check fns remain separate after
  the .conf derivation fix.

## Batch 5 — orchestrator lifecycle (one coherent PR)

- **O1 — TERM/INT trap + child reaping + stop-cross-chain.sh** [M·★★★] the
  chain has NO trap; pkill orphans nerdctl/buildctl (4× on 2026-08-10).
  EXIT/TERM only — never RETURN (parallel-loop.sh:21-32 corpse).
- **O2 — run-id + pidfile + eager log archiving** [M·★★★] CROSS_RUN_ID
  consumed in 3 places with 3 defaults, generated by NOBODY; `.run` markers
  truncate lazily → the stale-watcher class. Absorbs the archive's ★★★
  namespacing residual. `--takeover` semantics for a live sibling.
- **O4 — PARALLEL_LOOP_FAIL_FAST toggle** [S·★★] sequential loop grinds
  remaining arches for hours after one fails; keep keep-going for CI. Design
  together with the stage-barrier abort interplay (archive P1-c).
- **O5 — per-script flag allowlist** [S·★] `--push` parsed-but-inert in the
  chain (sink var _chain_push_enabled); `--parallel-archs` silently ignored
  by build-cross-stage. Warn or reject unimplemented shared flags.
- **--no-push OCI-layout handoff + dual-path collapse** [M·★★] --no-push
  builds resolve parents against the REGISTRY (two runs lost historically);
  export local stages as OCI layout + --build-context override; couples with
  collapsing the dual local/push paths.
- **XC2 — digest/ancestry discipline ENDS at android→runtime** [M·★★★] the
  runtime lane pushes plain (no parent annotations), chain-verify explicitly
  `continue`s on runtime, and the artifact handoff is a MUTABLE tag (the
  captured ANDROID_PIN digest is never handed to the runtime helper) — the
  stale-ancestor class ancestry.sh was built to kill, alive one lane later:
  a --repair/standalone manifest run cannot detect a wrapper predating its
  android. Fix: thread the pin digests into the helper + annotate wrapper/
  package pushes + a small runtime-graph table so the existing walkers cover
  the edges.
- **XC3 — per-arch wrapper tags go LIVE before the smoke gate; --repair can
  ship a mixed-generation :latest-cross** [M·★★★] wrappers push inside the
  build loop; only the MANIFEST is smoke-gated ("already pushed" comment
  admits it). 2-of-3 success → per-arch tags are the new generation while
  :latest-cross is old; a later --repair indexes whatever the mutable tags
  hold — silently mixing releases. Fix: run-id/parent-digest cross-check in
  create_manifest (refuse --repair on mismatch without --force), better:
  staging tags + post-smoke retag. Pairs with XC2.

## Batch 6 — CI / infra ramps (independent — but each residual has its OWN trigger)

- **C4 residuals** [S] (a) flip llm-stack-tests.yml `continue-on-error` to
  false after the FIRST GREEN run on a real runner (advisory-ramp rule);
  (b) move RUFF_PIN=0.14.4 from lint-python.sh into versions.env as
  RUFF_VERSION (Batch 3 rider).
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
- **W1 first-run watch** [S] SourceBuild.PinParity.Tests.ps1 has not yet
  executed on a real pwsh (none on this host) — watch the first Windows
  Invoke-Tests.ps1 run.
- **F7 residual** [S, optional] DocumANTation pointer confirmed PUSHED
  (2a5007a = remote HEAD — the standalone item is closed); remaining gap is
  only future-unpushed-SHA detection: a warn-only `git ls-remote` containment
  probe in preflight (network-dependent → warn, never fail).
- **SEC1 — no secret-scanning gate** [S·★★] shell/Dockerfiles/workflows/PS/
  Python all have lint gates; secrets have NONE (no gitleaks/trufflehog in
  workflows, preflight, or hooks). The .env pattern is correct today — the
  gate keeps it that way. Pinned-bootstrap gitleaks (the hadolint pattern) as
  a preflight slug + CI; advisory-first ramp on the existing history (a full
  history scan may surface old noise — triage before enforcing).

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
