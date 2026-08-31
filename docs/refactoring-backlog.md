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
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-31, after the A1 closure window. **The entire A1 work
section is CLOSED** (ERR-trap bug, complexity queue, modules.sh refuted) and so
is **GEN1**, which was built and wired ON. What that left open is not more
refactoring — it is **validation**: two lanes (QNN-LINUX and the new riscv64
GenAI) are wired but have never been proven by a real build, and one of them is
deliberately gate-red until that build happens.

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

Found during the 2026-08-31 GEN1 review. The two RISK-REDUCING ones were fixed
the same day (see the archive); this is what deliberately remains.

- **The genai RUN in Dockerfile.media mounts no cargo registry/git cache** [S·★],
  so llguidance's crates are fetched from crates.io on every uncached build
  behind only `retry 3 10`. Already true for arm64, so fixing it changes that
  lane's cache behaviour — it is risk-NEUTRAL for correctness and would re-key
  the arm64 genai layer, which is why it was left out of the 2026-08-31 window.
  Note it if the riscv64 genai stage flakes on the network.

## C. Pre-existing, found while auditing 2026-08-31

- **`test-preflight-slugs.sh` feeds `comm` unsorted input** [S·★★] — every run
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

- **D2. Two package names are dead on Ubuntu 26.04 ports** [S·★].
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

- **D4. `kata-buildcache` grows without bound and is the disk-filler**
  [S·★★★]. Observed within ONE session: 62 GB → 110 GB, and back to 55 GB after
  a manual wipe, purely from repeated runs. It is a regenerable cache EXPORT, so
  wiping it is safe (`prune-safe` cannot touch it — different store). It was the
  direct cause of the r3 disk emergency that forced a controlled chain stop.
  Needs a retention policy, or a size cap wired into the disk preflight so the
  chain trims it instead of asking a human at 19 GB free.

- **D5. Failed stages still write their cache exports** [S·★★].
  `cross-stage-build.sh:206` salvages local cache exports for all 15 named media
  stages after a FAILED build — burning disk on stages that will be rebuilt
  anyway, at exactly the moment disk is scarce. `SALVAGE_CACHE_EXPORT=0` already
  disables it; consider making it conditional on free space rather than on the
  operator remembering.

- **D6. `install_target_packages` reports non-fatal misses in fatal-looking
  language** [S·★]. `FAILED — missing after apt-get (rc=100): <pkg>` is printed
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
  [reference]. `_parity_exempt` in `06-packaging/smoke-runtime-image.sh` carries
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

## E. Waiting on a TRIGGER (not on work)

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
