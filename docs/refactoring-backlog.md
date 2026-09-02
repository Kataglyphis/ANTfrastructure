# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**LB**=llm-stack benchmark harness ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-31, after the A1 closure window. **The entire A1 work
section is CLOSED** (ERR-trap bug, complexity queue, modules.sh refuted) and so
is **GEN1**, which was built and wired ON. What that left open is not more
refactoring — it is **validation**: two lanes (QNN-LINUX and the new riscv64
GenAI) are wired but have never been proven by a real build, and one of them is
deliberately gate-red until that build happens. The LLM-BENCH group (2026-08-31, § D) is
also CLOSED — kept for one wave so its measured numbers stay beside the
code that produced them.

## Standing rules (read first)

1. Never edit versions.env or the 01-core / 03-media bind-mount closure
   outside a closure window — one edit re-runs hours of media compiles.
2. Respect the protected lists (deliberate dedup, standalone bundling,
   load-bearing case arms, ARG sprawl, LiteRT-LM patch stack, SH1 retry
   semantics, SH2 non-exiting error(), DUPN2 two-pass arg mirror) —
   re-verified intentional across five sweep rounds. **modules.sh's candidate
   ORDER and its dir-walker join this list (2026-08-31, closed by refutation).**
3. Disk reclaim mid-run: prune-safe.sh → targeted rmi of pushed tags →
   NEVER system/image prune while a chain runs (removes TAGGED locals).
   SHARPENED 2026-08-21: `nerdctl system prune` ALSO wipes the buildkit
   store INCLUDING exec.cachemount records (35→1 observed) — even with no
   chain running it costs the compile caches. It is the last-resort hammer
   ONLY; prune-safe + rmi + kata-buildcache/archive-log trims come first.
4. Per-arch out/build-logs/*.log persist across runs — mtime-check before
   re-arming watchers.
5. **A test that cannot fail is worse than no test.** Two 2026-08-31 findings
   were gates that looked green while proving nothing (see the archive: the
   ugrep `--`-as-option bug, and `rc==1` passing for the wrong reason). When you
   add a regression test, MUTATE the thing it guards and confirm the test goes
   red. State in the header exactly what is and is not covered.

## A. Needs a real BUILD to close (not more code)

**AUDITED 2026-09-02.** A2 is unchanged (still blocked on the login-gated SDK —
nothing here can move it). A1 splits into three, and only one of the three is
what the section title says:
- token sanity needs a **model**, not a build — mount one and set `GENAI_MODEL_DIR`
- the app-wheel floor 12 → 13 needs a run that PRINTS `13/… ok`; the previous
  run's chain log was overwritten before it could be read, so the **in-flight
  build is the first chance to settle it**
- the genai NEEDED scan has still never run against a real image on any arch

### A1. GEN1 — riscv64 GenAI: BUILD PROVEN, token sanity still open [★★]

The 2026-08-31 rebuild ran it for real. What was unknown is now measured, and
only one question survives.

**PROVEN by the media-riscv64 stage (run r4, image pinned sha256:32114d…):**
the upstream patch applies (`APPLIED: onnxruntime-genai riscv64 …`); it COMPILES
under the GCC 16 riscv64 cross toolchain (`Built target onnxruntime-genai`);
`cross_target_python_dev_ready` was true; llguidance/Corrosion LINKED (**zero**
`dropping --use_guidance` — the parity-divergence no gate can see did not
happen); and the wheel `onnxruntime_genai-0.15.2-cp314-cp314-linux_riscv64.whl`
was produced with the correct platform tag, i.e. it passed the wheel-must-exist
gate, `assert_elf_arch` and the target `EXT_SUFFIX` assert.

**STILL OPEN — the only one a build cannot answer:** does `generate()` emit sane
tokens on riscv64? Upstream #594 is a RISC-V build that compiled, imported and
produced nonsense; smoke tiers 1-3 pass in exactly that state. Arm tier 4 by
mounting a small model and setting `GENAI_MODEL_DIR`. Until then the lane is
"builds and imports", not "works".

Also unresolved and cheap to settle on the next run: raise the riscv64 app-wheel
floor 12 → 13 once a run PRINTS 13, and confirm the new
`validate-media-runtime.sh` genai NEEDED scan behaves on a real image (it has
never run against one on any arch).

### A2. QNN-LINUX — fan-out validation, BLOCKED on the login-gated SDK

- **CORRECTED 2026-08-31 — three of the four fan-out flags were invented.** The
  wiring "mirrors Windows #121 exactly", and Windows #154 established that
  `TFLITE_ENABLE_QNN`, `USE_QNN` and `IREE_TARGET_BACKEND_QNN` are not upstream
  options: CMake drops an undeclared `-D` silently and exits 0, so all three logged
  success and did nothing. Only ORT's `onnxruntime_USE_QNN` was ever real. TVM and
  IREE have no Qualcomm path at all and their flags are gone. LiteRT's IS real but
  under a different name — `LITERT_ENABLE_QUALCOMM`, auto-forced ON by
  `QAIRT_HEADERS_DIR` — and this lane already configures the right tree (`litert/`),
  so it is now correctly wired for the first time.
  **A second defect fell out of the same reading, and it is live on every build:**
  `litert/vendors/CMakeLists.txt` `file(DOWNLOAD)`s QAIRT 2.47.0.260601 from
  softwarecenter.qualcomm.com whenever `QAIRT_HEADERS_DIR` is empty — ~1.5 GB, **no
  `EXPECTED_HASH`, no `STATUS` check**, and NOT gated on `LITERT_ENABLE_QUALCOMM`, so
  it fired on every LiteRT configure including builds that want no NPU. It cannot be
  dodged with a stub path (any non-empty value force-enables Qualcomm with headers we
  do not have), so `_litert_disable_qairt_header_download` short-circuits the guard
  when no SDK is staged. MediaTek's NeuroPilot fetch from AWS S3 and the Samsung
  LiteCore fetch are suppressed with stub header dirs — both gate on the header
  EXISTING, so a stub is safe there.
  **Still unvalidated by a build** — see below; this corrects the wiring, it
  does not prove it.

Wiring is LANDED and fail-safe (no zip = byte-identical behaviour on every arch,
validated by the 2026-08-30 media rebuilds). ORT was PROVEN on real QAIRT
v2.49.0.260730. What is unproven is the OPPOSITE direction: with a REAL zip
staged on arm64, do the two builds that really have a QNN path (ORT, LiteRT)
stay GREEN and do the staged libs land? That one run also answers LiteRT's
QNN-manager header fetch and the wheel-staging question.

**Owner action — smaller than previously written.** `QNN_SDK_LINUX_ZIP_SHA256`
is already IMPLEMENTED and POPULATED with the v2.49.0.260730 hash, so
re-staging **that exact version needs NO re-pin** — the existing hash validates
it and a mismatch means a different build was downloaded. Only a NEWER SDK needs
`sha256sum <zip>` + a versions.env update in the same commit. Steps: download
the Linux AArch64 SDK from qpm.qualcomm.com (Qualcomm ID + EULA), drop the zip
in `linux/qnn-sdk/`, rebuild media-arm64, remove the zip afterwards (README
discipline). `QNN_SDK_LINUX_LIBDIR` (default `aarch64-oe-linux-gcc11.2`) is the
single knob if a newer SDK renames the lib subdir. Corrected README: 2026-08-31.

## B. Flagged, deliberately NOT fixed (blast radius > value right now)

**VERIFIED 2026-09-02:** still true — the genai RUN in `Dockerfile.media` carries
zero cargo mounts, so the deliberate choice below stands unchanged.

Found during the 2026-08-31 GEN1 review. The two RISK-REDUCING ones were fixed
the same day (see the archive); this is what deliberately remains.

- **The genai RUN in Dockerfile.media mounts no cargo registry/git cache** [S·★],
  so llguidance's crates are fetched from crates.io on every uncached build
  behind only `retry 3 10`. Already true for arm64, so fixing it changes that
  lane's cache behaviour — it is risk-NEUTRAL for correctness and would re-key
  the arm64 genai layer, which is why it was left out of the 2026-08-31 window.
  Note it if the riscv64 genai stage flakes on the network.

## C. Pre-existing, found while auditing 2026-08-31

- **`test-preflight-slugs.sh` feeds `comm` unsorted input — FIXED, and the last
  other call site closed 2026-09-02** [S·★★]. The test now runs
  `LC_ALL=C comm` over two `LC_ALL=C sort` inputs and carries a comment naming
  this bug; no "not in sorted order" warning remains.

  This entry's instruction — *"grep for other call sites while fixing"* — was
  audited 2026-09-02. `build-runtime-manifest.sh:140` and
  `test-codec-so-map-convergence.sh` were already correct. `lint-env-knobs.sh:58`
  was **not**: both its inputs are produced with `LC_ALL=C sort -u`, but `comm`
  itself ran in the ambient locale. `comm` checks sortedness in ITS OWN
  collation, so on a host that collates differently it would disagree with files
  this script sorted in C and report a wrong set difference — silently, since the
  gate prints only counts. Now `LC_ALL=C comm`; the gate still passes (635
  consumed knobs, all owned). ORIGINAL ENTRY:
  prints `comm: file 1 is not in sorted order` (×2) and still reports
  `5 assertion(s) passed`. `comm` on unsorted input does not compute a correct
  set difference, so its `_missing` / `_orphan` assertions may be passing
  VACUOUSLY. Not touched by the 2026-08-31 window (the file is unmodified), but
  it is exactly the toothless-gate class standing rule 5 is about. Sort both
  inputs, then re-check that the assertions still pass for the right reason.
  REINFORCED 2026-08-31: the same bug bit THREE times in one day while auditing
  (measuring ORT clone overlap, and twice while checking package lists), each
  time turning a real answer into a wrong one — `LC_ALL=C` changed "0 shared"
  into "36 shared" and "12 packages missing" into "1". Any `comm` in this tree
  wants `LC_ALL=C sort` on both inputs; grep for other call sites while fixing.

## D. Build infrastructure — found live in the 2026-08-31 rebuild

Ordered by what actually costs a run. The first two each destroyed an entire
arch's media stage.

- **D1. The batch apt install fails wholesale, and the per-package sweep does
  not always recover** [M·★★★, RECURRING — cost r4 the whole arm64 lane].
  `install_target_packages` runs one batch `apt-get`; on cross arches it exits
  100 with **every** package reporting `Depends: X:<arch> (= <version>) but it
  is not going to be installed`. The documented per-package retry then rescues
  most names, but not all — and which one is left behind varies by run
  (`libpulse-dev` in r4, nothing in r3 with the same scripts two hours earlier).
  The exact-version dependency shape points at a version skew between the cached
  apt lists and the live ports archive rather than at bad package names: every
  name in every `install-deps.sh` was checked against the live ports indices for
  arm64 and riscv64 and only the two in D2 are actually gone. Root-cause the
  batch failure; a `|| true` on ffmpeg's list would only hide it.

- **D2. Two package names are dead on Ubuntu 26.04 ports — RESOLVED, verified
  2026-09-02** [S·★]. `install-deps.sh:191` now calls `libopenexr-dev`, the
  correct name; the dead first attempt is gone. `libvvdec-dev` stays on purpose —
  the comment above it records that the package does not exist on ports at all,
  so the guard is deliberate and vvdec builds from source. Nothing left to do.
  ORIGINAL ENTRY:
  `libopenexr-3-dev` (renamed `libopenexr-dev`) and `libvvdec-dev` (gone
  entirely), both in `03-media/build/gstreamer/install-deps.sh:183,186`.
  Neither breaks a build — both already carry `|| …|| true` fallbacks, and vvdec
  falls through to a full source build — so this is cleanup, not an outage. But
  every run pays a failed apt round-trip and, for vvdec, an entire compile.
  NB the openexr fallback to the new name is already there; only the dead first
  attempt needs removing.

- **D3. Builds are not reproducible: the base digest changes every run**
  [M·★★]. `db544a8e` (r3) → `82ecfee4` (r4) → `c85cc424` (r5), same tree.
  Consequence for anyone assembling a manifest from more than one run: the
  arches then sit on DIFFERENT base layers. Functionally probably harmless,
  historically the exact shape of defect this repo has paid for twice (stale
  `:latest-cross`). Either make base reproducible or make the chain refuse to
  publish a manifest whose arches disagree on their base digest.

- **D4. `kata-buildcache` grows without bound — MECHANISM EXISTS, verified
  2026-09-02; the NUMBER is the open part** [S·★★★]. `build-cross-chain.sh:533`
  caps it at `CROSS_CACHE_MAX_GB` (default **250 G**) and LRU-prunes down to the
  cap, which is what this entry asked for. It did not help on 2026-09-02 because
  the cache only reached ~108 G while the *runtime lane* wanted 120 G free — the
  cap never fired. So the retention policy is real; 250 G is simply far above the
  point where the chain starts starving. Tune the number against
  `CROSS_RUNTIME_LANE_GB`, do not re-add the mechanism. ORIGINAL ENTRY: Observed within ONE session: 62 GB → 110 GB, and back to 55 GB after
  a manual wipe, purely from repeated runs. It is a regenerable cache EXPORT, so
  wiping it is safe (`prune-safe` cannot touch it — different store). It was the
  direct cause of the r3 disk emergency that forced a controlled chain stop.
  Needs a retention policy, or a size cap wired into the disk preflight so the
  chain trims it instead of asking a human at 19 GB free.

- **D5. Failed stages still write their cache exports — FIXED, verified
  2026-09-02** [S·★★]. `_cross_salvage_disk_ok` (`cross-stage-build.sh:44`) now
  gates the salvage on free space via `SALVAGE_MIN_FREE_GB`, falling back to
  `CROSS_DISK_GUARD_GB`, exactly as this entry proposed — "conditional on free
  space rather than on the operator remembering". ORIGINAL ENTRY:
  `cross-stage-build.sh:206` salvages local cache exports for all 15 named media
  stages after a FAILED build — burning disk on stages that will be rebuilt
  anyway, at exactly the moment disk is scarce. `SALVAGE_CACHE_EXPORT=0` already
  disables it; consider making it conditional on free space rather than on the
  operator remembering.

- **D6. `install_target_packages` reports non-fatal misses in fatal-looking
  language — FIXED, verified 2026-09-02** [S·★]. `cross-apt.sh:379` now reads
  `FAILED (caller decides if fatal) — missing after apt-get (rc=…)`. The clause
  that was missing is there. ORIGINAL ENTRY: `FAILED — missing after apt-get (rc=100): <pkg>` is printed
  identically whether the caller guarded the call with `|| true` or not, which
  cost two false alarms while monitoring this run. Say which it was: a guarded
  miss is information, an unguarded one is an outage.

- **D7. Warning audit 2026-08-31 — do not repeat it** [closed, recorded so it
  is not re-done]. Every warning in a full 3-arch run was classified. ~12,700 are
  compiler warnings inside UPSTREAM sources (ONNX Runtime's
  `lifetime_capture_by`, glslang array-bounds, LLVM `PointerType::get`
  deprecations, Dawn) — not our code, not fixable here. ~50 more are upstream
  TOOLING noise: the Vulkan SDK's own profile parser (`jsonschema` module
  missing) and GStreamer `.gir` parsing. Exactly ONE was ours, and it is fixed
  (the OpenCV build-stage cv2 import check could never succeed; commit
  b3dbd32a). Counting warnings by grepping the log OVERCOUNTS badly: BuildKit
  echoes each RUN's command text, so warning strings inside a Dockerfile command
  are matched as if they had fired. Count only real output lines
  (`^#N <time> WARNING`) — that is the difference between "TVM build failed 23×"
  and "TVM built fine".

- **D8. Feature parity is in good shape — the table is the source of truth**
  [reference, VERIFIED 2026-09-02 — and there is now a SECOND registry]. The
  claim below is exact: `_parity_exempt` still carries precisely two arms,
  `riscv64:cmake` and `riscv64:iree_base_compiler`.

  What changed on 2026-09-02: `_venv_pkg_exempt`, in the same file, gained
  riscv64 arms for `scipy` / `scikit-learn` / `pandas` (AA). Two exemption
  registries now exist in one file and only this entry documents either of them.
  Anyone auditing "what is riscv64 allowed to be missing?" must read both. `_parity_exempt` in `06-packaging/smoke-runtime-image.sh` carries
  exactly TWO documented exceptions after GEN1: `riscv64:cmake` (Kitware
  publishes no riscv64 archive, distro cmake 4.2.3 is used) and
  `riscv64:iree_base_compiler` (the IREE compiler cannot be cross-built and
  upstream ships no riscv64 wheel, so that lane is runtime-only). Everything
  else that differs is deliberate and correct rather than a gap: the ORT flavour
  split (`onnxruntime_dnnl` on amd64 because oneDNN is x86-only,
  `onnxruntime_webgpu` on arm64/riscv64) and QNN being arm64-only (it is a
  Snapdragon NPU). Feature toggles are already at maximum —
  `ORT_ENABLE_WEBGPU`, `ORT_WEBGPU_ALLOW_CROSS` and `GENAI_ALLOW_RISCV64` are
  all on; the two that are off are off on purpose (`ORT_ENABLE_LTO` costs build
  time for no feature, `FFMPEG_ENABLE_TF` was removed deliberately, −500 MB).

## D2026-09-02. Found live in the RVA23 media rebuild

- **DA. sccache cannot spawn the compiler in the genai/extensions build**
  [S·★★, non-fatal — costs cache, not correctness]. The `media-amd64` lane logs
  **962** occurrences of `sccache: error: failed to spawn Command { std: cd
  ".../_deps/onnxruntime_extensions-build" && env -i ... }` ending in
  `No such file or directory (os error 2)`. The build continues (sccache falls
  back to compiling directly) and no step fails, so this has been invisible —
  but every one of those translation units is compiled uncached. The `env -i`
  in the spawned command line is the thing to look at: the launcher rebuilds a
  clean environment and the compiler is then no longer on `PATH`. Distinct from
  the Rust wrapper that was already switched off (see the wave-4 notes).

- **DB. The gitleaks stage dominates preflight — MEASURED 2026-09-02: 170 s**
  [S·★]. A full `--source .` run over the repo takes **170 seconds**. Neither
  earlier hypothesis was the story: gitleaks honours `.gitignore` at the repo
  root (999 tracked files, 5738 ignored), and the ">2 min on `logs/`" reading
  came from pointing `--source` INTO an ignored directory, where the root
  `.gitignore` no longer applies — a different question, not a contradiction.
  170 s for the real invocation is simply what it costs. Decide whether that is
  worth optimising; it is no longer a mystery. ORIGINAL ENTRY:
  [S·★, measure before changing anything]. `make preflight` spends the bulk of
  its wall time in the secret scan, which is why it has to be run before a
  multi-hour rebuild rather than casually. The obvious hypothesis — that it
  scans the 4.9 GB of build logs under `out/` — was **tested and disproved**:
  gitleaks returns on `out/` instantly, so it does honour `.gitignore` there.
  A direct scan of `logs/` (2.3 GB, ignored by the same style of rule,
  `logs/**/*`) instead ran past 120 s. Those two results are inconsistent and
  one of the two measurements is wrong. Time the real `--source .` run per
  directory FIRST; do not narrow a security gate's scope on a guess.

- **DC. A pinned stage's cache-export slug is dead weight, and nothing reclaims
  it — FIXED DIFFERENTLY 2026-09-02** [M·★★★, cost SIX manual interventions]. `kata-buildcache`
  is keyed per stage slug (`..._cross-media-riscv64`, `..._cross-android-amd64`,
  …). The moment `[stage X] pinned <digest>` is logged, that stage is built,
  pushed and will not be rebuilt in this run — its slug can never be read again,
  yet it sits on disk until the end. Measured 2026-09-02 in one `media..runtime`
  run: the three media slugs held **83 G** and the three android slugs **39 G**,
  all of it dead, while the runtime lane was starving.

  `_chain_stage_disk_guard` does prune this directory, but only below
  `CROSS_DISK_GUARD_GB` (40 G) — far too late for a lane whose own entry gate
  wants ~120 G, so the run either stops at the gate or needs a human. In that
  one run the free-space curve went 154 G → 78 G → (prune) → 191 G → 61 G →
  (prune) → 143 G, with every recovery manual.

  The fix is not a lower threshold, it is a *trigger*: reclaim a slug when its
  stage is pinned, not when the disk is nearly full. The chain already knows
  the moment (it logs it) and already knows the mapping (the slug is derived
  from the tag). Guard rails worth keeping: never touch the slug of a stage in
  the current build set, and keep the LRU path as the emergency backstop for
  everything the trigger does not cover. See [[rebuild-disk-management]] for why
  `nerdctl builder prune` must never be the answer here.

- **DD. riscv64 Node.js is FOUR majors behind the pin — CORRECTED, and it is a
  decision, not a defect** [S·★★, owner call]. The original wording here said the
  pin is "silently dropped". That was wrong on both counts, and reading
  `base-image.sh` corrected it: the fallback is deliberate, documented, scoped
  and has an escape hatch (`NODE_RISCV64_MAJOR_REQUIRED=1` restores a hard
  failure), and it warns **loudly** — the major-lag warning fired 5 times.

  What is worth an owner's attention is the *size*: pin `26.8.1`, installed
  `v22.22.1`. Four major versions, because ubuntu-ports lags and there is no
  official Node tarball for riscv64. The code's justification is that Node there
  only backs optional JS/web tooling (litert-web / onnx-web) that the Python and
  native runtime never import. That justification is sound **if it is still
  true** — so the question is whether that tooling works on Node 22, not whether
  the fallback should exist.

  No code change made. The mechanism is right; only this entry was wrong.

- **DE. `IREE_BUILD_COMPILER=OFF` does not produce `iree-tblgen` — FIXED 2026-09-02** [M·★★, costs a
  full host compiler build]. `[WARN] IREE host stage (IREE_BUILD_COMPILER=OFF)
  left /tmp/app-wheelhouse/iree-build-host/install/bin missing: iree-tblgen —
  retrying with the full host compiler`, twice in one run. The two-stage build
  in `docs/iree-two-stage-build.md` exists precisely to avoid that compiler
  build; the fallback works, so the cost is invisible in the exit code. Either
  the OFF stage needs `IREE_BUILD_TOOLS` (or whatever now gates tblgen) or the
  two-stage split should be retired as ineffective.

- **DF. The media ELF gate guesses whether a foreign-arch .so is a vendor blob — FIXED 2026-09-02**
  [S·★★]. It prints `MISMATCH (advisory, may be vendor): libpython3.14.so.1.0
  ELF machine=Advanced Micro Devices X86-64 != expected RISC-V` and then
  `NOTE: 3 advisory .so ELF mismatch(es) (likely bundled vendor SDKs; not
  failing)`. It logs **basenames only** and the word is *likely* — the script
  already carries a list of directories that legitimately hold foreign-arch
  vendor binaries (QNN, SNPE, NeuroPilot), so it could classify by path and fail
  on anything outside them. As written, a genuine x86-64 leak into a riscv64
  image would print exactly the same line as a MediaTek blob. (The three
  libpython hits are almost certainly the amd64 build container's own Python and
  therefore harmless — but the gate cannot tell you that, which is the point.)

- **DG. The media stage's qemu functional check has never passed on a foreign
  arch — REMOVED 2026-09-02** [S·★★]. `WARN: /usr/bin/qemu-riscv64 gst-launch-1.0 --help failed (may
  be expected for cross builds without full sysroot)` — 4× for riscv64 and 3×
  for arm64 in one run, for `gst-launch-1.0`, `cam` and `ffmpeg`, every one
  excused by the same clause. A check that always fails and is always excused is
  not a check; it is training to ignore WARN lines. Real functional coverage
  does exist later (the runtime-image smoke boots the actual image), so either
  give this one a sysroot or delete it.

- **DH. sccache spawn failures grew to 1560 in one run — NOT LOCALLY FIXABLE**
  [see DA]. Same defect as DA, measured across the whole chain rather than one
  lane. Every one of those translation units compiled uncached, and the launcher's
  bypass kept the build correct. See DA for why the obvious lead is refuted.

- **DI. `install_target_packages` batch apt failure fired 4× in this run** [see
  D1]. The per-package sweep recovered every time and nothing was left behind,
  so the run stayed green — but D1 is still open and still costing a retry pass
  per occurrence.

## A2026-09-02. The riscv64 venv gate: SIX real failures, manifest correctly withheld

The `media..runtime` run of 2026-09-02 built and pushed all three per-arch images
and then **failed the runtime gate on riscv64 with 6 failures**, so
`create_manifest` never ran and `:latest-cross` still points at the previous
release. amd64 and arm64 passed with `0 failure(s)`.

**Not a regression from that day's work** (libyuv RVV patch, the OpenCV
`complex.h` shim, the delete guard, docs — none touch the venv). The VENV-SET
gate is new, and the previous manifest attempt died earlier on the soname gate,
so **this is the gate's first complete riscv64 run**: these are pre-existing
defects becoming visible, which means the riscv64 image has been shipping an
incomplete `ml-ai` extra unnoticed.

Measured against the SHIPPED images afterwards (`pip list` inside each), the gap
is far larger than the six failures suggest: **amd64 carries 153 venv packages,
riscv64 carries 94** — 76 missing, 14 extra.

- **AA. 76 packages are absent from the riscv64 venv — DECIDED 2026-09-02,
  partially fixed** [L·★★★]. `optuna` and the two ORT deps are now installed;
  `scipy`, `scikit-learn` and `pandas` are exempted on riscv64 with the reason
  recorded in `_venv_pkg_exempt`. The remaining ~70 are the pure-Python packages
  that sit above the compiled roots and were never separately investigated —
  reopen this entry if any of them is actually wanted on riscv64. The six the gate names are the ones the app declares; the
  rest are missing silently. They cluster:

  | cluster | examples |
  | --- | --- |
  | scientific / ml-ai | `scipy`, `scikit-learn`, `pandas`, `optuna`, `joblib`, `threadpoolctl`, `captum`, `skops` |
  | MLflow + storage | `mlflow`, `mlflow-skinny`, `alembic`, `SQLAlchemy`, `pyarrow`, `boto3`, `botocore`, `databricks-sdk` |
  | web / API | `fastapi`, `starlette`, `uvicorn`, `pydantic`, `pydantic_core`, `anyio`, `h11` |
  | crypto / auth | `cryptography`, `cffi`, `pycparser`, `google-auth`, `pyasn1` |
  | ORT deps | `flatbuffers`, `protobuf` |
  | expected | `iree-base-compiler` (riscv64 is deliberately runtime-only) |

  **Measured against PyPI 2026-09-02, and the gap is NOT one problem but two.**
  The original wording here guessed that almost every root needs a compiled
  wheel. Only five do:

  | genuinely blocked (no `any`, no riscv64 wheel) | installable today |
  | --- | --- |
  | `scipy`, `pandas`, `scikit-learn`, `pyarrow`, `cryptography` | `optuna`, `mlflow`, `fastapi` (pure Python) |
  | | `flatbuffers`, `protobuf` (pure-Python `any` wheel exists) |
  | | `pydantic-core` (**publishes a riscv64 wheel**) |

  So the expensive part is a handful of compiled roots, and most of the 76 are
  pure-Python packages that fell out *transitively* behind them. That changes the
  decision from "build the whole stack from source or ship nothing" into two
  separable questions: (1) are the five compiled roots worth a source build on
  riscv64, and (2) independently of that, why did the pure-Python packages that
  do not depend on them — `flatbuffers`, `protobuf`, `optuna` — not install?

  The decision is about scope, not mechanics: does the riscv64 image promise the
  same Python surface as the other two? If yes, the compiled roots must be built
  from source (BLAS/LAPACK + Fortran for the scientific stack — hours per run).
  If no, say so once, record it, and make the app's own environment markers stop
  claiming riscv64 needs them.

- **AB. `onnxruntime-webgpu`'s dependency edges are dangling on riscv64 — FIXED 2026-09-02**
  [S·★★★]. `flatbuffers` and `protobuf` are declared requirements of the
  installed wheel and absent from the venv, so an import can fail in the user's
  process rather than in our build.

  Root cause is deliberate and must not be reverted: `assemble-torch-app.sh`
  installs every local wheel with `--no-deps --force-reinstall`, and its comment
  names this exact hazard — *"without it uv re-resolves the wheels' deps to
  LATEST and floats the venv off the lock (numpy, protobuf MAJOR)"*. The run
  bears the comment out: `protobuf==6.33.6` was installed twice and
  `protobuf==7.36.1` once across the three arches.

  **Correction:** an earlier draft of this entry called `PROTOBUF_VERSION=6.31.1`
  "a pin nothing honours". That was wrong — it is the **C++** protobuf runtime
  for LiteRT-LM, deliberately slaved to that project's internal pin, and
  versions.env says so. It has nothing to do with the Python package.

  Both packages publish a pure-Python `any` wheel, so neither is blocked on
  riscv64 and the fix is cheap: install them explicitly next to the local ORT
  wheel at the version the app lock already uses on amd64 (`protobuf 6.33.6`,
  `flatbuffers 25.12.19`). Do **not** drop `--no-deps`.

- **AC. The riscv64 runtime venv ships build tooling the other arches do not**
  [S·★★]. 14 packages exist only there, and several have no business in a
  runtime image: `meson`, `wheel`, `gcovr`, `gyp-next`, `Cython`-adjacent
  `jaraco.*`/`autocommand`/`typeguard`/`inflect`/`more-itertools`, plus `lxml`
  and `Markdown`. amd64 carries none of them. They are almost certainly the
  residue of building packages from source on the arch where wheels were
  unavailable — i.e. a side effect of AA. Whatever AA is decided, this list
  should not survive into the shipped image.

**Keep the gate exactly as strict as it is.** It did the one thing this repo
keeps asking of its gates: it stopped a broken image from being published, and
it named the six packages instead of saying "smoke failed".

## U2026-09-02. Patches we can DELETE (from the upstream verification round)

Four of our patches turned out to be redundant or already fixed upstream. Each
one removed is one less thing to carry forward across version bumps. Full
evidence per item in `docs/upstreamable-patches.md`.

- **UA. Drop `003` and `004` by fixing the meson cross file instead**
  [M·★★★, deletes two patches]. `gst-plugins-rs/meson.build:719` forwards
  `rustc.cmd_array()`, which carries `--target` in a cross build, and
  `cargo_wrapper.py` extracts the triple from it. We never benefit because
  `cross-meson.sh` writes `rust = '<wrapper script>'` and the wrapper hides
  `--target` inside itself, so `cmd_array()` is just a path. Meson accepts a
  list for a binary: write `rust = ['<rustc>', '--target', '<triple>']` and the
  triple lands exactly where upstream already looks.

  **But this is NOT the one-liner it looks like — inspected 2026-09-02.** The
  wrapper is conditional on purpose:

  ```sh
  --target|--target=*)  have_target=true    # caller already chose: pass through
  */target/*)           cargo_managed=true  # cargo owns this one: pass through
  ```

  It injects the triple only when neither holds, and its header says why:
  *"Meson's Rust cross sanity checks do not reliably infer the target triple from
  the linker alone. Inject it only when the invocation does not already specify
  --target so cargo-backed subprojects keep working."* An array binary line would
  append the triple **unconditionally** and remove exactly that cargo exemption.
  That may still be right — upstream's flow wants the triple in `cmd_array()` —
  but it cannot be settled without building.

  **Needs a real build to close.** Watch the gst-plugins-rs subprojects, which is
  where the exemption earns its keep, and do not delete `003`/`004` until that
  build is green.

  **The one safe half is DONE 2026-09-02.** `003` was *actively wrong*: it
  prepended `env['RUSTFLAGS']` to a list that already contained it (line 249
  folds it in), duplicating every flag it claimed to preserve. Regenerated
  against the pinned `gstreamer-1.29.2` source with only the
  `CARGO_BUILD_TARGET` fallback left, and the `CROSS_RUST_TARGET` arm dropped —
  safe because `_cross_env_export_all` exports both (`_export_arch_vars` line
  586, `_export_cargo_vars` line 592), so the cargo-documented variable is always
  set when ours is. Verified: APPLIED then SKIP through `apply-patch.sh`, and the
  result still parses as Python.

- **UB. Replace our OpenCV FFmpeg-8 patch with the upstream commits — DONE 2026-09-02**
  [S·★★★]. Upstream fixed this on `4.x` in `700cd32ffd` and `83ed22ca28`; `5.x`
  did not get it. Both are saved in `docs/upstream/patches/` and were verified
  to apply to `5.x` with **no conflicts**, after which our own patch no longer
  applies at all. Ours also guards on the wrong idiom
  (`LIBAVCODEC_VERSION_MAJOR >= 62` vs their `LIBAVCODEC_BUILD >=
  CALC_FFMPEG_VERSION(61, 13, 100)`) and trusts a `{0,0}` terminator where the
  new API returns a count. Swap ours out for theirs.

- **UC. Drop `005a`, `005b` and `006` when the GStreamer pin moves**
  [S·★★]. All three are already in upstream `main` — the OpenCV 5 header moves
  (with the `CV_MAJOR_VERSION >= 5` guard our version lacks) and the FFmpeg 8
  codec-ID guards (`LIBAVCODEC_VERSION_MAJOR < 63`). Nothing to file; just stop
  carrying them once the pin includes the commits. Until then note that our
  `006` is semantically wrong where upstream's is not: we `#define` the removed
  IDs to `0`, which is `AV_CODEC_ID_NONE`, rather than removing the comparisons.

- **UD. Drop the libyuv RVV patch once libcamera advances its wrap revision**
  [S·★★]. The trigger, the removal steps and the one thing that must survive the
  removal are spelled out in `docs/upstreamable-patches.md` entry 16 — that page
  owns this one.

## F. Code cleanliness — the refactor queue (measured 2026-08-31)

Numbers, not opinions: function lengths from an AST-free line count, duplication
from `docs/scripts/verify_code_dupes.py`. Nothing here breaks a build; this is
the "I want clean code" queue. Ordered by value, not size.

### F1. Functions that outgrew a screen [M each] — RE-MEASURED 2026-09-02

        was  now  function                       file
        356  356  assert_pinned_versions()      06-packaging/smoke-torch-venv.sh
        196    8  smoke_genai_py()              06-packaging/smoke-common.sh   DONE
        168  170  _cross_stage_build_impl()     01-core/cross-stage-build.sh
        147  114  _opencv_target_adjustments()  03-media/build/opencv/build-opencv.sh
        136   84  append_tvm_cmake_args()       05-frameworks/tvm-config.sh
        127  109  uv_sync_project()             01-core/python_uv.sh
        127  146  reconcile_local_wheels()      03-media/runtime/assemble-torch-app.sh  GREW

The 2026-08-31 column was stale: four of the seven had already shrunk, one of
them to nothing. `smoke_genai_py` is now six lines calling six tier helpers —
exactly the split this entry proposed — **but see F4, because that did not make
its Python lintable.**

`reconcile_local_wheels` GREW by 19, of which 12 are the ORT-dependency install
added for AB on 2026-09-02. It is now the second-longest function here and the
next candidate.

`assert_pinned_versions` at 356 is untouched and remains the clear top of the
list — more than twice the next entry.

### F2. Files over ~800 lines [L each, low priority] — RE-MEASURED 2026-09-02

        was   now  file
        1013  1429  06-packaging/smoke-runtime-image.sh          +416
        1371  1243  05-frameworks/torch/build-app-wheelhouse.sh  -128
         957   966  03-media/build/litert/build-litert.sh
         935   934  03-media/build/opencv/build-opencv.sh
         874   874  lib/agentic-loop.sh
         853   861  02-toolchain/build-gcc.sh

`smoke-runtime-image.sh` grew **40% in two days** and is now the largest file in
the tree — it absorbed the prevention gates (2026-09-01) and the riscv64 venv
exemption (2026-09-02). Length is weak evidence on its own, but a file that
gains 416 lines while being the thing that decides whether a release ships is
worth a look for F1 candidates.

### F3. Clone families worth one owner [S-M each]

- **`chain_status_kv_json` / `chain_status_list_json` walk the same CSV**
  (`01-core/chain-lifecycle.sh:93` and `:106`, 21 shingles, 5 identical lines) —
  the item-splitting loop is the same; only the emitted shape differs. One
  walker taking an emitter callback would own it. Allowlisted 2026-09-01 with a
  budget of 25 so it cannot grow further unnoticed.
- **`verify-shipped-wrapper.sh` carries a private `_is_truthy`** (`:50`) — it
  runs standalone from `build-runtime-manifest.sh`, but `REPO_ROOT` is available
  there, so it could source `01-core/platform.sh` and use the canonical
  definition. The test stubs (`test-chain-lifecycle.sh`, `test-parallel-loop.sh`,
  `test-ffmpeg-dnn-contract.sh`) must keep their own copies — a test that sourced
  the real one could no longer prove the shipped copy behaves.
- **`lib/*.sh` share a 14-line logging-fallback preamble across 9 files**
  (56 shingles) — the single largest copied block in the tree. It is
  `if ! declare -F info; then source …; else info() { … }; fi`. NOTE the
  bootstrap paradox before touching it: the block exists precisely for the case
  where nothing has been sourced yet, so extracting it into a file you must
  source defeats its purpose. A shared file plus a 2-line guard may still beat
  14 lines × 9.
- **`lint-{shell,workflows,dockerfiles}.sh` pinned-tool bootstrap** (3 copies) —
  reviewed and KEPT on 2026-08-31 because hadolint fetches a raw binary while
  the others untar/unzip, so a shared helper needs a strategy argument. Revisit
  if a FOURTH tool appears; three is the threshold where the parameter earns
  itself.
- **`lib/{app-runner,cmake-build,ctest-run}.sh`** and
  **`lib/{code-quality,coverage,docs-build}.sh`** — two 3-file families in the
  same directory, so no cross-flow coupling risk. The most tractable ones.
- **`install-deps.sh` family (6 files)** — cross-apt, gstreamer, litert, opencv,
  pre-setup, assemble-torch-app. Shares the target-package install shape.
- **Dockerfile RUN mount preambles (4-9 files)** — NOT actionable: Dockerfiles
  have no include or function mechanism. Recorded so nobody re-opens it.

### F4. The duplication gate's own defects [S each]

- **Clone-family clustering degenerates.** Union-find over shared files
  transitively collapses most of the tree into one meaningless "88 files"
  family. Cluster on the shared BLOCK, not on file adjacency.
- **The genai Python is STILL unlinted — FIXED 2026-09-02 in the EXTRACTOR, not
  the source** [was: re-measured 2026-09-02]. `extract-embedded-python.py` now
  assembles `cat`ed fragment FAMILIES (two or more sharing a marker prefix) in
  file order and emits them only when the result parses, so the 217 lines reach
  ruff without touching the runtime path or the four Dockerfiles that copy
  `smoke-common.sh`.

  Two defects surfaced while doing it, and the second was invisible: the marker
  class `[A-Z_]*` **excluded digits**, so `GENAI_PY_T1..T4` — four of the six
  fragments — were skipped silently and no message said so. Both are now
  mutation-tested. A lone fragment is still never extracted: `ast.parse` catches
  syntax errors but not undefined names, so linting one alone reports bogus
  findings — the original rule was right about that. ORIGINAL ENTRY: `smoke_genai_py` went from one 196-line
  heredoc to six `_smoke_genai_py_tier*` helpers totalling **217 lines**, each
  emitting its fragment with `cat <<'GENAI_PY_T*'`. `extract-embedded-python.py`
  handles only **directly-executed** heredocs and says so; run against
  `smoke-common.sh` it reports *"no directly-executed heredocs found"*. So ruff
  sees none of it — and assembled fragments are harder to extract than the single
  heredoc was. Satisfying F1's length metric and F4's lintability goal pulled in
  opposite directions here; a real `.py` file that the smoke pipes in still
  settles both.

### F8. libyuv's RVV rows are dispatched but never compiled — FIXED 2026-09-02 [DONE]

Enabling the vector baseline made libcamera's bundled libyuv fail to link on
riscv64:

```
ld.lld: error: undefined symbol: ARGBBlendRow_RVV
ld.lld: error: undefined symbol: BlendPlaneRow_RVV
```

The first diagnosis written here was wrong. `row_rvv.cc` IS compiled — it sits in
`libyuv.a` as `source_row_rvv.cc.o`. It compiles to *nothing*, because the file
guards itself on `defined(__clang__)` while `row.h` enables all 57 `HAS_*_RVV`
entry points for any RVV compiler. Upstream has since dropped that clang gate;
`patches/libyuv/001-rvv-build-with-gcc.patch` backports exactly that change to
libcamera's pinned revision, and `verify_libyuv_rvv_rows` in `build-libcamera.sh`
fails the build if the rows are ever absent again.

Measured with our own cross GCC 16.2.0: 0 -> 54 (`row_rvv.cc`) and 0 -> 25
(`scale_rvv.cc`) RVV symbols, both previously-undefined symbols now defined. The
`-DLIBYUV_DISABLE_RVV` workaround is gone — vector stays on.
docs/riscv64-rva23-baseline.md#libyuv-rvv

The general shape to expect from the rest of the vector switch is recorded in
docs/riscv64-rva23-baseline.md#libyuv-rvv.

### F7. ArmNN + ACL — DECIDED 2026-09-01: ship them [DONE]

They were cross-compiled, stripped and verified on every arm64 chain and then
dropped at the package boundary: `Dockerfile.package` named them zero times, the
shipped image had neither directory, `libarmnn*` existed nowhere in it, and the
only `libarm_compute.so` present came with PyTorch's own wheel.

Owner decision: **ship them.** `Dockerfile.package` now copies `/opt/armnn` and
`/opt/acl` from `artifact-source` (safe on every arch — the media stage creates
empty dirs on non-arm64), and `configure-runtime.sh` writes `000-armnn.conf` so
they win their lookup like every other `/opt` tree.

Note the same shape is CORRECT for `/opt/tvm`, `/opt/pyav` and `/opt/app-wheels`:
their content is installed into `/opt/venv` (tvm and av are importable in the
shipped image). ArmNN had no such path.

- **The runtime smoke does not reach its own shipped-truth gates when run
  STANDALONE** [S·★★] — measured 2026-09-01 against the published
  `latest-cross-arm64`: the run stops after "Functional: ML version-pin
  assertion", with `nerdctl` logging "force cleanup timed out for container".
  The gates run fine inside the build (their PASS/FAIL lines are in the
  runtime-repair2 log), so this is specific to invoking the script by hand — the
  exact way an operator would verify a published image. Find what hangs there.

- **`preflight.sh` dies at the gitleaks secret scan** [S·★★] — 2026-09-01, twice
  in a row: the process disappears mid-scan and never writes its exit code, so
  the suite cannot report. It completed earlier the same day, so something about
  the current tree or host state kills it. `PREFLIGHT_SKIP=secret-scan` is the
  workaround; find why it dies before relying on the full suite again.

### F6. Cache-key blast radius in Dockerfile.media — FIXED 2026-09-02, awaiting build proof [M each, measured]

Numbers from `out/build-logs/f2-media-validation.log` (2026-08-31, amd64, warm
ccache): the media stage is 134.3 min of RUN time across 90 steps, dominated by
app-wheelhouse 1523.5s, ORT `--step cpu` 1452.0s, tvm 1377.1s, litert 1353.6s.
The waste is not compute — it is over-broad mounts above that work.

Two are FIXED (2026-09-01): `verify-media-artifacts.sh` no longer sits in the
shared `base` stage (8 edits since 2026-08-01, each re-paying the whole media
stage on every arch), and `linux/qnn-sdk/*.md` is out of the build context (a
README-only dir mounted into the five heaviest RUNs).

**Both narrowings DONE 2026-09-02, pending build validation:**
- **ORT `--step cpu`** now mounts three paths instead of the whole
  `build/onnxruntime` tree: `build-onnxruntime.sh`, `30-build-native.sh` and
  `build/lib/`. Derived, not guessed — the `cpu|native)` arm dispatches to
  `30-build-native.sh` and nothing else, that script sources only
  `lib/common.sh` plus `source_build_acceleration_helpers` (which loads from
  `/opt/scripts/core`, already mounted), and it references neither
  `30-build-native-amd.sh` nor `-nvidia.sh`.
- **tvm** now mounts its five `tvm*.sh` files instead of all of
  `05-frameworks`. `tvm.sh` sources exactly four siblings, and none of them
  sources anything further in that directory — the rest of the tree is `torch/`
  and `flutter/`.

Still open here: the genai / wasm / js RUNs have the same over-broad shape and
were left alone, because unlike the two above they are not on the critical path
that the next build will exercise.

**The next media build is the proof.** A missed transitive `source` fails hours
in, so treat a green media stage as the close condition for this entry.

### F5. The duplication baseline is frozen, not reviewed [L, measurable]

`verify_code_dupes.py` reports OK, but that means **no NEW or GROWING** copy —
not "no duplication". Re-measured 2026-09-02: `docs/scripts/code-dupes.allow` now
holds **260** pairs (was 251), of which **236 still say "baseline 2026-08-31, not
yet reviewed"**. So nine pairs were added since the baseline and the unreviewed
tail has not moved at all — every pair reviewed so far was a NEW one.

Work the tail from the top; each line deleted or shrunk is real progress and the
gate enforces the new, lower budget automatically:

| shingles | pair |
| ---: | --- |
| 199 | `build-runtime-artifacts.sh` ↔ `build-runtime-manifest.sh` |
| 179 | `iree/android/build-android.sh` ↔ `litert/android/build-android.sh` |
| 95 | `lint-shell.sh` ↔ `lint-workflows.sh` |
| 90 | `smoke-runtime-image.sh` (same file, two blocks) |
| 88 | `tests/test-tvm-cmake-args.sh` (same file, two blocks) |

Two pairs alone are 378 shingles — 6% of the whole baseline. Reviewing an entry
means one of: shrink the twin and lower the budget, or replace "not yet reviewed"
with the reason it is deliberate. Both are improvements; leaving it is not.

## G. Shipped-truth findings, measured in the arm64 image 2026-09-01

Every item here was read out of the SHIPPED bytes
(`ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross-arm64`), not from a
build log. See docs/cross-build-verification.md.

- **IREE ships a release compiler against a dev runtime** [M·★★★] — CONFIRMED:
  `iree-base-compiler 3.11.0` but `iree-base-runtime
  3.11.0.dev0+e4a3b0405d7d23554da26403658d0e8c3c5ecf25`. The two halves of IREE
  come from different builds; a dev runtime can drift from the release
  compiler's VM format. `IREE_VERSION=v3.11.0` in versions.env pins only what
  the tag claims. Decide which half is authoritative and pin both to it. The
  `advert-keys` gate compares the RUNTIME's numeric prefix, so this skew is
  currently green and would stay invisible without this entry.

- **The advertised-version gate covered 6 of 31 keys** [DONE 2026-09-01] —
  `verify-advertised-keys.py` (preflight slug `advert-keys`) now fails when any
  version-shaped `ENV`/`ARG` in `linux/Dockerfile.*` is neither checked by the
  smoke nor excused with a reason, and when an excuse goes stale. 16 keys are
  checked, 16 excused. Probes were measured against the shipped image, and each
  mutation was proven to go red (`test-advertised-keys.sh`).

- **`VULKAN_VERSION` could not disagree with itself** [DONE 2026-09-01] — its
  HAVE side parsed the version out of `/opt/vulkan/active`, a directory named by
  the ARG under test. Now measured from the loader (`vulkaninfo`), falling back
  to `VK_HEADER_VERSION`. The class matters more than the instance: any HAVE
  probe that re-reads the advertisement is a gate that cannot fail.

- **An absent `PYTORCH_EXTRA` silently shrank the venv gate** [DONE 2026-09-01] —
  the empty case was folded in with the `none` sentinel, so an image that failed
  to advertise the extra had it dropped from the checked set. Now `NOADV` fails;
  only the literal `none` is a torch-less image.

- **TVM ships off-tag** [S·★, STILL TRUE — re-measured 2026-09-02: `TVM_REF=v0.26.0`
  in versions.env, `tvm.__version__` reports `0.26.dev1` on **both** amd64 and
  riscv64, so it is a tag-vs-build-metadata mismatch, not an arch split] —
  `TVM_REF=v0.26.0` but `tvm.__version__` is
  `0.26.dev1`. Excused in `advert-keys` because the ref and the version cannot
  be compared, but a build one commit off its intended tag is invisible today.
  Worth an explicit ref->commit assertion at build time.

- **`pkg-names` treated a partial index fetch as authoritative** [DONE
  2026-09-01] — one failed component (`universe`, say) truncated the name set,
  cached it, and would then report live packages as dead. Now all-or-nothing
  with an honest SKIP. Also: the vendor-repo exemption covered whole FILES, so
  the plain Ubuntu packages `setup-rocm-repo.sh` installs before adding the
  vendor repo (`curl`, `gpg`, `ca-certificates`) were unfailable; it is now
  name-scoped. And `apt_install_available` was in no installer table at all —
  6 cross-toolchain packages were extracted nowhere (118 -> 121 call sites,
  522 -> 529 names).

- **riscv64 now builds at RVA23 (RVV ON)** [DONE 2026-09-01] — the earlier entry
  here had the risk INVERTED and is corrected: the shipped image's own glibc and
  loader already require RVV 1.0 (997 `vsetvli` in apt's `libc.so.6`), so a
  board without a vector unit could never run this image. Our binaries were the
  only sub-baseline objects in it. The cross GCC now defaults to
  `rva23u64_zifencei`/`lp64d` — the exact string apt's libc carries — with
  OpenCV, ORT, Rust and the gst-plugins-rs cargo wrapper wired separately
  because they gate vector paths on their own switches. A new smoke gate reads
  `Tag_RISCV_arch` off the shipped objects. See docs/riscv64-rva23-baseline.md.
  OPEN: TVM and IREE emit code at RUNTIME, so they need a codegen-target change
  (`-mattr=+v,+zvl128b` / `--iree-llvmcpu-target-cpu-features`), not a compile
  flag. Also budget a COLD riscv64 build — this invalidates the warm cache.

- **GStreamer: riscv64 ships 282 plugins, arm64 290 — root-caused** [M·★★★] —
  measured with `gst-inspect-1.0` in both shipped images. None of the eight is
  an upstream RISC-V arch guard; all reduce to three mechanisms:
  - **Missing target -dev packages** that a `MEDIA_SKIP_*` flag removes, with
    meson's `auto` features skipping silently and `--wrap-mode=nofallback`
    (`build-gstreamer-monorepo.sh:333`) blocking the subproject fallback:
    `codec2json` (needs `libjson-glib-dev`, dropped with the whole GLib dev
    stack by `MEDIA_SKIP_GLIB_STACK`), `uvch264`/`uvcgadget` (`libgudev-1.0-dev`,
    `MEDIA_SKIP_GUDEV`), and `gtk`/`gtkwayland` (`libgtk-3-dev`,
    `MEDIA_SKIP_GTK_DEV`).
  - **`colormanagement` needs `liblcms2-dev`, which this repo never installs on
    ANY arch.** arm64 only gets it by accident, transitively via
    `libgdk-pixbuf-2.0-dev → libglycin-2-dev → liblcms2-dev`; riscv64 loses that
    path with `MEDIA_SKIP_CAIRO_PANGO_PIXBUF`. Install it explicitly for all
    arches — it has no GLib dependency, so no skip flag touches it.
  - **`csound` and `skia` are explicitly disabled** for riscv64 at
    `build-gstreamer-monorepo.sh:296` (`-Dgst-plugins-rs:{csound,skia}=disabled`).
    `skia` stays; the csound half rests on a comment ("Ports has no
    libcsound64") that is **false** — `libcsound64-dev` exists on resolute
    riscv64 and the runtime image already ships `libcsound64.so.6.0`.
  Note the `-Dgtk=disabled` top-level option is a RED HERRING: it selects
  GStreamer's "build GTK4 as a subproject" mode and arm64 sets it too.

- **FIVE of the eight missing riscv64 GStreamer plugins have ONE cause: the RV1
  `libglib2.0-dev` ban** [L·★★★] — established 2026-09-01 by reading the live
  resolute riscv64 ports index. Every package that would restore them Depends on
  `libglib2.0-dev`:

  | package | plugins it would restore | `Depends: libglib2.0-dev` |
  | --- | --- | --- |
  | `libjson-glib-dev` | codec2json | yes |
  | `libgtk-3-dev` / `libgtk-4-dev` | gtk, gtkwayland | yes |
  | `libgudev-1.0-dev` | uvch264, uvcgadget | yes |
  | `liblcms2-dev` | colormanagement | **no** — fixed, shipped |

  So "the package resolves on ports" (which all of them do) is NOT the question;
  the question is whether `libglib2.0-dev:riscv64` may enter the sysroot at all.
  `MEDIA_SKIP_GLIB_STACK`, `MEDIA_SKIP_GTK_DEV` and `MEDIA_SKIP_GUDEV` are three
  spellings of the same ban. Do not retire them one at a time — settle RV1 once.

  **What makes this actionable:** RV1's stated mechanism is REFUTED. The comments
  claimed ports' riscv64 `glib-2.0.pc` expands an EMPTY prefix; on resolute that
  `.pc` ships in `libgio-2.0-dev` and is byte-identical to arm64's modulo the
  triplet. The five 2026-08 failures were real, their explanation is not. Next
  step is a single riscv64 media build with `MEDIA_SKIP_GLIB_STACK=0` that
  captures the ACTUAL failure — one build settles five plugins.
  CAUTION unchanged: `gir1.2-gstreamer-1.0` drags distro GStreamer 1.28.2 into
  the sysroot, so drop that one entry from the list before testing.

  NOTE 2026-09-01: `MEDIA_SKIP_GUDEV` was briefly flipped to 0 on the evidence
  that libgudev installs cleanly, then reverted on this finding — installing it
  would have pulled `libglib2.0-dev` in through the back door.

- **riscv64 RVV / GStreamer glib items** — the only genuinely build-blocked work
  left; see the entries below. Everything from the 2026-09-01 semantics passes is
  now fixed in-tree.

- **The destructive-delete guard now works on Linux** [DONE 2026-09-01] — it was
  PowerShell-only and `pwsh` is absent on this build host, so the answer to the
  2026-08-21 host wipe was INERT exactly where the incident happened, and the
  second registration it claimed in the user-level settings did not exist.
  `.claude/hooks/guard-destructive-deletes.py` is a Linux port with the same
  protocol, wired ahead of the PowerShell one. It denies the filesystem root,
  system directories, `$HOME`/`~` roots, credential dirs, the containerd and
  buildkit stores, block devices and package removals, while
  `linux/host-config/prune-safe.sh`, `nerdctl rmi` and
  `rm -rf ~/.cache/kata-buildcache/*` still pass. Pinned by
  `test-delete-guard.sh`; emptying the rule table turns 7 assertions red.

- **The remaining riscv64 items, NOT fixed and why** [★★] —
  - **`csound`** — `libcsound64-dev` resolves, the image already ships
    `libcsound64.so.6.0`, and the "Ports has no libcsound64" comment is corrected
    in-tree. Not flipped because one gst-plugins-rs plugin whose native dep fails
    hard-fails the ENTIRE set — risking the 8 Rust plugins riscv64 ships today
    for one. Unlike the five above it is NOT blocked by RV1
    (`libcsound64-dev` has no glib dependency), so it is independently testable.
  - **`MEDIA_SKIP_CAIRO_PANGO_PIXBUF` / `MEDIA_SKIP_LIBCXX_DEV`** — the named
    packages install today, so the stated reasons are stale, but neither buys a
    plugin directly and cairo/pango sit on the same glib chain as RV1.
  - **TVM and IREE** emit code at RUNTIME, so RVV needs a codegen-target change
    (`-mattr=+v,+zvl128b`, `--iree-llvmcpu-target-cpu-features`), not a compile
    flag. No such target string exists in the tree yet.

- **The riscv64 skip flags are largely frozen workarounds** [M·★★★] — every
  package named in `03-media/core/arch-flags-riscv64.env` exists on the live
  resolute riscv64 ports index at the same version as amd64/arm64, and a REAL
  (not simulated) cross-install of all 13 inside the tree's own base image
  returns rc=0 with all 13 "install ok installed" — but only with the host amd64
  source constrained to `Architectures: amd64`, which `cross-apt.sh:188` does do.
  `MEDIA_SKIP_GUDEV` and `MEDIA_SKIP_CSOUND` look outright stale;
  `MEDIA_SKIP_CAIRO_PANGO_PIXBUF` and `MEDIA_SKIP_LIBCXX_DEV` have inaccurate
  COMMENTS whose flags may still be justified for other reasons. Do NOT flip
  `MEDIA_SKIP_GLIB_STACK` wholesale: `gir1.2-gstreamer-1.0:riscv64` drags distro
  GStreamer 1.28.2 into the sysroot, which is a separate hazard. Retire them one
  at a time, each proven by a real riscv64 media stage, not by an apt simulation.

- **numpy differs between arm64 and riscv64** [S·★★, STILL TRUE — re-measured
  2026-09-02] — `numpy 2.5.1` on amd64 (the uv.lock wheel) vs `2.5.2` on riscv64
  (built locally against versions.env). Unchanged from the 2026-09-01 reading;
  the amd64 side matches what arm64 showed then. The two authorities disagree by a
  patch release. Harmless today, but it is the same class as the torch/vision
  split and means "the venv is pinned" is only true per-arch. See
  docs/riscv64-venv-parity.md.

- **Parity itself is in good shape (measured, not assumed)** [note] — arm64 vs
  riscv64 on 2026-09-01, read out of the shipped images: identical versions for
  cv2 5.0.0, onnxruntime 1.29.0, onnxruntime_genai 0.15.2 (GEN1 IS on riscv64),
  av 18.1.0, tvm 0.26.dev1, tflite_runtime 2.2.0; cv2 reports GStreamer 1.29.2 /
  FFMPEG / OpenCL / Vulkan YES on BOTH; ORT exposes the same three providers
  (CPU, WebGpu, Xnnpack) on both — WebGPU now ships, having been excluded in the
  2026-07-20 build. The only differences are torch/torchvision (PyPI wheel vs
  source build) and the numpy patch skew above.

**AUDIT NOTE 2026-09-02.** This whole section had never been re-checked since it
was written. Two entries were re-measured against the shipped images and both
still hold (numpy split, TVM off-tag). The remaining open ones — the IREE
release-compiler/dev-runtime pairing, the riscv64 GStreamer plugin gap, the
frozen riscv64 skip flags, and the "remaining riscv64 items" list — were NOT
verified: the plugin-count claim needs the entry's own `gst-inspect` metric on
an arm64/riscv64 pair, and a raw `.so` count on amd64/riscv64 (598 vs 288)
answers a different question. Do not treat those four as confirmed-current.

## H. LLM-BENCH — GenieX session harvested into `linux/llm-stack` (CLOSED 2026-08-31)

All nine items implemented and validated live against GenieX lanes on the same
day they were filed. Kept here (not archived) for one wave so the measured
numbers stay next to the code that produced them.

- **LB1 — correctness probe** [DONE] `--correctness` / `--correctness-only`
  (exit non-zero on a wrong answer); `run_benchmarks.sh` gates the sweep on it
  (`BENCH_SKIP_CORRECTNESS=1` bypasses). Validated: Qwen3-4B `Q4_0` 6/6,
  `IQ3_XXS` 0/6 BROKEN — the case every speed metric rated as a good run.
- **LB2 — TTFT/prefill** [DONE] `ttft_s`, `prefill_tok_per_sec`,
  `decode_tok_per_sec` (the pre-existing `tokens_per_sec` divides by the whole
  request and so hides prefill inside what reads as a decode rate).
- **LB3 — time to a finished answer** [DONE] `wall_s_to_answer` +
  `thinking_char_share`. A live run showed **77–86 % of output was `<think>`**.
- **LB4 — multi-endpoint + concurrent aggregate** [DONE] new `bench_lanes.py
  --lanes`. Reproduced the manual finding within 0.5 %: NPU **+0 %** when a CPU
  lane joins, CPU **−18 %**, aggregate 39.9 tok/s = 1.57x the best single lane.
- **LB5 — batching probe** [DONE] `bench_lanes.py --batching`. Verdict
  `SERIALISED` on GenieX: second request's TTFT 74.27 s vs the first's 74.10 s
  total.
- **LB6 — GGUF introspection** [DONE] new `inspect_gguf.py`: header-only read,
  tensor-type histogram, OK / LIKELY OK / RISKY verdict, exit 1 on RISKY.
  Correctly separates the broken `IQ3_XXS` (97.6 % sub-4-bit i-quants) from the
  working 27B `UD-Q4_K_M` (0.8 %).
- **LB7 — de-Ollama'd** [DONE] `LLM_BASE_URL` (old name still honoured);
  `detect_model_via_api` asks `/v1/models` first and takes a `base_url`. The
  hardcoded `"gemma4:26b"` probe is gone — it returned that name on any 200,
  mislabelling every non-gemma host.
- **LB8 — worker vs listener** [DONE] `top_cpu_processes()` primes before and
  reads after each request, so the summary names the PID that actually burned
  CPU. Encodes the trap: GenieX's port owner read 11 % of 800 % while its
  worker sat at 752 %.
- **LB9 — cross-platform hardware info** [DONE] `platform`/`psutil` fallback
  after the `/proc` reads, plus an explicit `incomplete` list so a gap is
  visible instead of silent.

**Viewer + test debt closed 2026-08-31 (second pass).** The first pass wired
the new metrics into the result JSON but not into the React viewer, although
LB2/LB3 explicitly said "and the viewer" — the data flowed in and surfaced
nowhere. Now: a correctness banner above every speed number, time-to-answer as
the leading column, TTFT/decode/prefill/thinking-share in the comparison and
drill-down tables, the busiest process per request, and legacy runs degrading
to `-` (charts drop them rather than drawing a `0` that would claim an instant
first token). `bench_lanes.py` and `inspect_gguf.py` gained 15 unit tests
(synthetic GGUFs, an in-process SSE server), taking the suite to 30 unit tests
that need no running stack. A server-side smoke render (`npm run smoke`)
renders every component against the real manifest, because `vite build` only
proves the JSX compiles — it caught a silently-failed edit that made the
comparison table render empty cells.

**Probe calibration fix:** truncation is now reported apart from wrongness
(exit 2 = INCONCLUSIVE, exit 1 = genuinely wrong). A model cut off mid-thought
was not wrong, it was unmeasured, and scoring it as a failure made a healthy
model look degraded. The arithmetic probe also moved 847*293 -> 23*17: a
healthy 4B could not finish the former inside 4000 thinking tokens, so the
check cried wolf on good models.

**Two pre-existing bugs found while doing this**, both fixed:
- the SSE parser matched `"data: "` **with** the space (optional per spec).
  GenieX omits it → nothing parsed, 0 tok/s reported, no TTFT possible. The
  harness was effectively blind to every non-Ollama server.
- servers ignoring `stream_options.include_usage` yielded 0 tokens; now falls
  back to a counted chunk total flagged `tokens_estimated`.

**Closed since the original harvest:** context-length quality scaling
(`bench_coding.py --context-tokens`, § 1e of the GenieX page) and tool/function
calling correctness (`bench_tools.py`, § 1f) — the latter found the one result
that does not crown the coding winner.

**Still open for a general LLM toolkit** (listed so it is not forgotten):

- **LB10 — embedding benchmarks** [M·★★] `tests/test_v1_api.py` exercises the
  embedding endpoints but nothing measures them. Relevant the moment a RAG or
  code-search path is added.
- **LB11 — run-to-run regression comparison** [S·★★] Every tool writes a JSON
  report and nothing diffs two of them. Without it a model swap or a runtime
  bump can silently cost accuracy or speed. Probably the highest-value item
  left: it turns a pile of one-off measurements into a tripwire.
- **LB12 — energy per token** [M·★] The interesting axis on a battery device,
  and the NPU's real argument over the CPU lane (165 % vs 752 % of 800 % CPU
  says something about power but does not measure it).
- **LB13 — measurements not yet run on this host** [S·★] hybrid lane on coding
  tasks, `nctx` scaling below 16384, `--ngl` on the GPU lane, and the model
  candidates never tried: `Qwen3-8B` W4A16 (the winner's direct competitor —
  same fast prefill, same 4096 ceiling, twice the parameters), a
  code-specialised GGUF such as `Qwen2.5-Coder-7B`, and the other QAIRT bundles
  (`Ministral-3-3B-Instruct`, `Gemma-4-E2B-it`). **Every model measured so far
  is from one family (Qwen3/Qwen3.8)** — that is the largest gap in the
  ranking's authority.

**Explicitly NOT for llm-stack:** `windows/scripts/host/start-geniex-servers.ps1`
stays where it is — Windows-host lane management, not benchmarking.

## E. Waiting on a TRIGGER (not on work)

**READ IN FULL 2026-09-02:** all six are genuinely trigger-bound (a host reboot,
a full push chain, upstream bit-rot). None is actionable without its trigger, and
none has drifted.

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS on a full push chain** — validated locally 2026-08-30
  (green, ~30 % GCC-RUN saving); the next full chain that wants the parallel
  GCC must pass `GCC_PARALLEL_TARGETS=1` on its command line (it now reaches
  the container — the plumbing fix 92fb9646).
- **gcc-prereq measurement facets** (sig-cache, LIBRARY_PATH leak, verify
  coverage, dup-compile overlap) — needs ccache stats from a real build;
  the "unify prereq paths" reading is CLOSED (deliberately different).
- **post-restart base cache-miss** — observe at the next host reboot.
- **LOG7 — sdkmanager CLI deprecated** — bit-rot watch before Google
  removes it.
- **MESON-GI — meson 1.12 breaks gobject-introspection's glib-subproject
  resolution (riscv64 cross gst)** [S·★, WATCH]. Pin in place:
  `setup-gstreamer.sh` installs `meson==1.11.2` for riscv64 cross only
  (amd64 native + arm64 no-introspection are fine on 1.12).
  **RE-PROBED 2026-08-31: still 1.12.0.** `git ls-remote mesonbuild/meson`
  shows no 1.12.x point release and no 1.13 — so no released meson fixes it yet
  and the pin stays. (Note: the repo pins `GOBJECT_INTROSPECTION_VERSION=1.86.0`;
  earlier notes here said "g-i 1.84", which was stale.) Retest by removing the
  pin in a closure window once meson moves.
- **NODE-RV — riscv64 ships Node v22 (pin: 26.8.1)** [S·★, WATCH].
  ubuntu-ports has no 26.x for riscv64; the install falls back fail-open with a
  WARN (by design, seen in every wave-4 smoke log).
  **RE-PROBED 2026-08-31: ports `resolute` (26.04) riscv64 universe still ships
  `nodejs 22.22.1+dfsg+~cs22.19.15-1ubuntu1`** — no 26.x, so the fallback stays
  correct. Re-check at each bump window.
  NB (2026-08-27): the pin moved 26.8.0 → 26.8.1 because the OFFICIAL v26.8.0
  tarball self-reports `26.8.0-alpha.0.0.0` and its own bundled npm then refuses
  it (semver puts a prerelease outside `>=22.9.0`). Re-check the REPORTED
  version, not just the tarball name, at every bump — the gate that missed it
  compared a PREFIX and has since been tightened to an exact match.
- **SV-residual — watch the first real `compose up`** — user-side.
- **riscv64 isa-spec smoke on real hardware** — needs hardware.
- **WEBUI_SECRET_KEY server-side rotation** — user action.
