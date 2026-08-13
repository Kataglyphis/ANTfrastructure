# Refactoring backlog — OPEN items only, ordered by execution batch

Lean working document (rewritten 2026-08-10): every item here is OPEN and
VERIFIED-current (two-agent currency audit against code + git, 2026-08-10).
Completed/obsolete items and the full observation journal live in
`refactoring-backlog-archive-2026-08-10.md` — consult it for deep evidence;
do not resurrect items from it without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Batches are grouped by REBUILD BLAST RADIUS, not theme — most items are cheap,
rebuilds are expensive. Work top to bottom; each batch ships independently.

Last groomed: 2026-08-13 (post VALIDATING-REBUILD cleanup: :latest-cross
re-shipped 3-arch, digest 8d1538b1, all keeper changes PROVEN live. Removed
every executed closure note — Batch 0, all of Batch 2's code fixes (R1-5,
C1-2, D2-4/P4, BS1-6, XC4-7, A3, S4, wheel_family, setup_gi, cpython TS2/3),
TG3/TG4/TG7 (reverted, re-opened), BS3b glob, ORT-WEB1, BS5-followup, noise
riders, verify-media orphans. What remains below is genuinely OPEN. Records
of the done work live in CHANGELOG.md + memory + the archive.)

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

### New code fixes (2026-08-10 rounds, all evidence-verified)


- **D3 + P5 — smoke-media gate scaffold + SMOKE_ENV** [M·★★] extract
  smoke_resolve_bin / smoke_assert_elf_magic / smoke_component_gate (6+2+4
  duplicated sites) into smoke-common.sh and make the two-environment contract
  explicit (SMOKE_ENV=sandbox|runtime set by callers) instead of six scattered
  "functional gate is the …" branches. Extend test-smoke-arch-parity.sh.
- **A1 — env-knob registry gate + dead-alias deletion** [S/M·★★] 156
  cross-boundary `${VAR:-}` knobs, no owner. Delete dead aliases ARCHITECTURES
  (resolve_arch_list 3rd alias) + UBUNTU_PORTS_MIRROR_URL (cross-env.sh:17);
  add a verify-arg-consistency-family gate: every consumed ALL_CAPS knob must
  be set somewhere / in versions.env / in an allowlisted operator table
  (which doubles as the missing docs). Gate itself is host-side (can land
  early); the deletions are closure-bound.
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
  (STILL OPEN — S4's 2026-08-12 pass did only the per-file install-deps mount
  narrowing, not the src-clone caches; deferred as its own half.)
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
- **codec runtime-list + so-package-map convergence** [M] hand-maintained
  lists in 03-media/runtime/install-deps.sh:53+ and so-package-map.txt vs the
  ffmpeg manifest (third truth source). D4 gives the substrate.
- **cerbero checksums.env class fix** [M] the forge auto-archive re-pin
  (soundtouch override at build-android-from-source.sh:94-111) needs the
  general table; + **soundtouch TOFU re-hash** [S] and **litert-web npm
  dist.integrity verification** [S].
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
- **TG3 — LLVM core cross-compiled TWICE per target arch** [M·★★] ⚠ ATTEMPTED
  + REVERTED 2026-08-12: llvm-cross.sh was collapsed to ONE superset build
  installed to both prefixes, but the FULL validating rebuild caught it — the
  unified configure carried the OLD target-llvm-only flags (LLVM_BUILD_UTILS=
  OFF, LLVM_INCLUDE_UTILS=OFF, LLVM_INCLUDE_TESTS=OFF, LLVM_TOOL_LLVM_SHLIB_
  BUILD=ON) that are fine for a core-only build but, combined with
  clang-tools-extra, leave libLLVMSupportLSP.a UNBUILT while `cmake --install`
  still references it → "file INSTALL cannot find libLLVMSupportLSP.a" +
  "[ERROR] Target LLVM CMake package missing after install for arm64" (arm64,
  ~134s in; riscv64 identical). HEAD's target-clang configure had none of
  those flags and shipped. Reverted llvm-cross.sh to HEAD (drops TG3 + TG4 +
  the TG2 ccache-stats-in-that-file). REDO: match HEAD's proven target-clang
  flag set exactly for the unified build (drop the utils/tests-restricting
  flags), keep `cmake --install` WITHOUT --strip unless separately validated,
  and re-run a real toolchain rebuild before merging. TG4 (strip) + TG2
  (ccache stats) ride the same redo.
- **TG7 — host-LLVM apt profile defaults to `full`** [S, investigate] ⚠
  ATTEMPTED + REVERTED 2026-08-12: flipped full→minimal after a repo-wide
  audit of flang/bolt/mlir/libclc/clangd/clang-tidy consumers — but the
  validating rebuild caught the audit's blind spot: `clang-tblgen` (shipped by
  the clang-tools package the minimal profile drops) is a BUILD-TIME tool the
  cross target-clang build consumes via CMake's `CLANG_TABLEGEN=`, not a
  runtime binary any grep would find. Result: `ninja: error:
  '/usr/lib/llvm-22/bin/clang-tblgen' ... missing and no known rule to make
  it` in the arm64 target-clang RUN. Reverted llvm.sh to HEAD (full profile).
  REDO: keep minimal BUT explicitly add the clang-tblgen-providing package
  (clang-tools-<major>) to the minimal set, then a real toolchain rebuild.
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

- **GST1 — cross-vs-native gstreamer libdir split (ROOT fix)** [S/M·★★★]
  found live 2026-08-11: native meson installs to lib/<triplet>/ but the
  cross builds pass libdir=lib (cargo_wrapper invocation, media-arm64 log
  :92779), so configure-runtime's `multiarch -> lib/<triplet>` symlink points
  at an EMPTY dir on arm64/riscv64 — the arm64 dev surface (pkg-config
  gstreamer-1.0) has been dangling in EVERY shipped image; the Klasse-B
  package gate caught it on its first cross-arch run. HOTFIX landed same
  night (repair_gstreamer_multiarch_link in setup-package-image.sh, proven on
  both layouts). Root fix here: make configure-runtime resolve the REAL
  pc-carrying libdir (same probe logic) — or force the cross meson builds to
  libdir=lib/<triplet> for native parity — and add a media-stage assert that
  `${GSTREAMER_PREFIX}/lib/multiarch/pkgconfig/gstreamer-1.0.pc` resolves.

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
- **W1 first-run watch** [S] SourceBuild.PinParity.Tests.ps1 has not yet
  executed on a real pwsh (none on this host) — watch the first Windows
  Invoke-Tests.ps1 run.

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
