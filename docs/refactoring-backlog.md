# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md),
[`…-archive-2026-09-02.md`](refactoring-backlog-archive-2026-09-02.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**LB**=llm-stack benchmark harness ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: **2026-09-02**, during the RVA23 rebuild (media green on all three
arches, runtime lane still ahead). 526 lines of closed work moved to the
2026-09-02 archive: the whole C section, D2/D5/D7, DC–DG, AB and the AA-followup,
UB, F4, F5, F6, F7, F8, the F3 `is_truthy` item, six G items and LB1–LB9.

Two entries were **rescued from that cut**: the runtime-smoke standalone hang and
the `preflight.sh` gitleaks death sat under F7 (ArmNN), which they have nothing to
do with — they are open and now live under **F9**. Section H keeps its header for
the same reason: it says CLOSED, but LB10–LB13 are open work.

What is left is dominated by three things: **validation** (A1/A2 need a real
build), **decisions rather than code** (AA's riscv64 Python surface, F3's four
unreachable fallbacks), and a refactor queue (F1–F3) whose two biggest items are
**blocked, not deferred** — they sit in the bind-mount closure that standing
rule 1 protects, and the chain re-reads those scripts per stage.

## Standing rules (read first)

1. Never edit versions.env or the 01-core / 03-media bind-mount closure
   outside a closure window — one edit re-runs hours of media compiles.
   **MECHANISM MEASURED 2026-09-02:** the chain re-invokes *itself* as a child
   per stage (observed PPID 808173 → PID 1998054, both `build-cross-chain.sh`),
   so each stage re-reads these scripts from disk. An edit made mid-run is not
   merely a cache-key change — the NEXT stage executes the edited bytes. This is
   why F1's two remaining targets are blocked, not deferred.
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
   **ORDER MEASURED 2026-09-02: prune FIRST, then rmi — never the reverse.**
   Deleting 9 untagged ~32 GB images while the layer cache still referenced the
   same overlayfs snapshots returned **+12 G**; after several prune-safe passes
   had removed those records, deleting 18 of them returned **+97 G**. Same host,
   same command, opposite verdicts — an image frees space only when it holds the
   LAST reference. A prune pass reporting identical GB and record count before
   and after (= everything in use) is the signal to switch levers, not to prune
   harder.
   **KEEP=100 measured 2026-09-02:** mid-run, with android building and 82 G free
   falling toward the runtime lane's ~120 G need, `PRUNE_KEEP_GB=100
   prune-safe.sh` returned **+40 G** and printed `all 97 cache-mount records
   survived` — the store held 296 G `regular` against 162 G `exec.cachemount`.
   That is the whole point of the filtered prune: the 162 G of compile cache is
   what the naive hammer throws away to reach the 296 G.
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

- **D6. `install_target_packages` reports non-fatal misses in fatal-looking
  language — FIXED, verified 2026-09-02** [S·★]. `cross-apt.sh:379` now reads
  `FAILED (caller decides if fatal) — missing after apt-get (rc=…)`. The clause
  that was missing is there. ORIGINAL ENTRY: `FAILED — missing after apt-get (rc=100): <pkg>` is printed
  identically whether the caller guarded the call with `|| true` or not, which
  cost two false alarms while monitoring this run. Say which it was: a guarded
  miss is information, an unguarded one is an outage.

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
  worth optimising; it is no longer a mystery.

  **Narrowed further 2026-09-02:** `lint-secrets.sh` already scans with
  `gitleaks detect --no-git` — the WORKING TREE, not history — so the obvious
  "it walks every commit" theory is dead before it is raised. Whatever the
  170 s buys, it buys it on ~999 tracked files. Profiling it means repeated
  full scans, which is CPU-heavy: do it in a **quiet window**, not beside a
  running chain, or the measurement steals time from the build and lies about
  itself. Pairs with F9's second item — a scan that sometimes dies mid-run is
  the more urgent half of the same gate. ORIGINAL ENTRY:
  [S·★, measure before changing anything]. `make preflight` spends the bulk of
  its wall time in the secret scan, which is why it has to be run before a
  multi-hour rebuild rather than casually. The obvious hypothesis — that it
  scans the 4.9 GB of build logs under `out/` — was **tested and disproved**:
  gitleaks returns on `out/` instantly, so it does honour `.gitignore` there.
  A direct scan of `logs/` (2.3 GB, ignored by the same style of rule,
  `logs/**/*`) instead ran past 120 s. Those two results are inconsistent and
  one of the two measurements is wrong. Time the real `--source .` run per
  directory FIRST; do not narrow a security gate's scope on a guess.

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
        127  139  reconcile_local_wheels()      03-media/runtime/assemble-torch-app.sh  GREW

**`assert_pinned_versions` is not 356 lines of shell — it is ~26 lines of shell
wrapping a 312-line embedded Python program** (`"${PY}" - <<'PYEOF'` at
`smoke-torch-venv.sh:101`). Decomposing the shell would move almost nothing.
What mattered was that ruff could not see it: the extractor's interpreter
pattern hard-coded lowercase `${py}`, so `"${PY}" -` never matched and the
largest embedded program in the tree was **never linted** — silently. Fixed
2026-09-02 (see F4); the newly-visible 399 lines from this file pass the hard
gate clean. If the shell wrapper is ever split, do it for its own sake, not for
the line count.

The 2026-08-31 column was stale: four of the seven had already shrunk, one of
them to nothing. `smoke_genai_py` is now six lines calling six tier helpers —
exactly the split this entry proposed — **but see F4, because that did not make
its Python lintable.**

`reconcile_local_wheels` grew by 19 for AB's ORT-dependency install, then gave 7
back on 2026-09-02 when the misplaced optuna install moved out of it (AA-followup,
archive). Net +12 against the 2026-08-31 column; still the second-longest function
here and the next candidate after the closure window opens.

`assert_pinned_versions` at 356 is untouched and remains the clear top of the
list — more than twice the next entry.

**BLOCKED, not deferred (2026-09-02).** The two remaining targets —
`_cross_stage_build_impl` (01-core) and `reconcile_local_wheels` (03-media/runtime) —
sit inside the bind-mount closure that standing rule 1 protects, and the RVA23
rebuild is in flight with the runtime lane (the stage that publishes the manifest)
still ahead. Both are pure readability refactors: the upside is a shorter function,
the downside of a slip is a dead 2h+ build at its publishing step. They are the
first work item of the next closure window, in this order:

  1. `_cross_stage_build_impl` — decompose INTERNALLY only (do not split it back
     into two functions; that split was reverted once already). Natural seams, each
     already marked by its own comment block: the pull-flag decision, the push/
     attestation output args, the three-tier cache args, the salvage-export loop
     (~30 lines, deepest nesting → best single win), and the registry-cache drop.
  2. `reconcile_local_wheels` — 146 lines carrying 57 comment blocks; the comments
     already name the seams.

`assert_pinned_versions` stays top of the list by size but is the *worst* candidate
by value, for the reason given above: decomposing its shell moves ~26 lines.

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

- **The source-or-fallback family — the biggest one, found 2026-09-02** [M·★★★].
  Four sites carry a canonical helper plus an inline copy used when the canonical
  file is absent: host-compiler resolution, `_path_contains`/`_path_prepend_unique`,
  and host-python discovery. Evidence, sites and measurements are in F5 (that
  entry owns them); what belongs HERE is that they are one family, not three
  pairs, and that the fallbacks are **load-bearing by construction** — the same
  bootstrap paradox the `lib/*.sh` item below warns about.

  So the work is not "extract a helper". It is one question, asked once: **is any
  fallback still reachable?**

  **ANSWERED 2026-09-02: no — in every context the tree builds.** The evidence,
  because a grep of `COPY .* 01-core/<file>` says the opposite and nearly misled
  this entry: `Dockerfile.package:274` and `Dockerfile.toolchain:301` copy the
  **whole directory** (`COPY linux/scripts/01-core/ /opt/scripts/core/`), and
  `Dockerfile.media` bind-mounts it at the same path in 23 RUNs. Verified in the
  shipped image: `/opt/scripts/core/` holds 68 files including both
  `path-helpers.sh` and `compiler-resolution.sh`. So the runtime env scripts, the
  media build stages and the android preamble all take the canonical branch.

  What remains is therefore a **decision, not an investigation**: delete four
  fallbacks whose guard condition is never false, or keep them as insurance
  against a future stage that copies `01-core` per-file instead of wholesale.
  Deleting them is a behavioural change across every stage and wants one
  validating build — that is the only reason it is not already done here.

- **`chain_status_kv_json` / `chain_status_list_json` walk the same CSV**
  (`01-core/chain-lifecycle.sh:93` and `:106`, 21 shingles, 5 identical lines) —
  the item-splitting loop is the same; only the emitted shape differs. One
  walker taking an emitter callback would own it. Allowlisted 2026-09-01 with a
  budget of 25 so it cannot grow further unnoticed.
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

### F9. Gates that do not run when invoked by hand [S-M each]

Both were found on 2026-09-01 and had been filed under F7 (ArmNN), which they
have nothing to do with; they surfaced when F7 was archived on 2026-09-02.

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

- **TVM ships off-tag** [S·★, STILL TRUE — re-measured 2026-09-02: `TVM_REF=v0.26.0`
  in versions.env, `tvm.__version__` reports `0.26.dev1` on **both** amd64 and
  riscv64, so it is a tag-vs-build-metadata mismatch, not an arch split] —
  `TVM_REF=v0.26.0` but `tvm.__version__` is
  `0.26.dev1`. Excused in `advert-keys` because the ref and the version cannot
  be compared, but a build one commit off its intended tag is invisible today.
  Worth an explicit ref->commit assertion at build time.

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

## H. LLM-BENCH — the four items still open

LB1–LB12 are done and archived. **LB10 and LB12 were already implemented when
this was re-checked on 2026-09-02** — the entries had gone stale, the third
and fourth stale entries found that day. LB11's comparer existed and was
tested but **nothing ever called it**; that half is now closed too. What is
left is LB13, which needs hardware time rather than code.

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
