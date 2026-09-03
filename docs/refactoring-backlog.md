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

- **DJ. The pinned-stage cache slugs are still dead weight — DC's premise is
  true within a run and false across runs** [M·★★, measured 2026-09-02]. DC was
  archived as "FIXED DIFFERENTLY": what actually shipped is the raised entry
  threshold (`_chain_runtime_lane_is_next` → demand ~120 G before the runtime
  lane), which cures the *starvation*. The *waste* it described was never
  reclaimed. Measured live today, with media and android both pinned and the
  runtime lane about to start: `kata-buildcache` held **69 G** across five slugs
  (media amd64 16 G, riscv64 14 G, arm64 14 G; android arm64 14 G, amd64 12 G)
  while the lane's own gate wanted 120 G and the disk had 126 G free.

  **Do not implement DC's trigger as written.** Its premise — "the moment a stage
  is pinned its slug can never be read again" — holds only for the *current* run.
  Across runs those slugs are exactly what makes a rebuild warm, and media is the
  most expensive stage in the chain: deleting them at pin time buys headroom today
  and pays for it with hours of recompile on the next run. That is why the cheap
  version was not taken.

  What would actually be right is a *ranked* reclaim rather than a boolean: when
  the guard must free space, prefer the slug of a stage already pinned in THIS run
  over one it may still read, and prefer the cheapest-to-rebuild stage over the
  dearest. Today's numbers say android before media. Until that exists, the manual
  lever is the between-stage `prune-safe.sh` window — which is what kept this run
  fed (95 G → 126 G, all 97 cache-mount records surviving).

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

## W2026-09-03. Audit findings — read-only sweep run during the RVA23 runtime lane

Six independent lenses over linux/scripts/ and the Dockerfiles, every finding
then put through an adversarial verifier that started from "this is wrong" and
had to confirm it against the code. **10 findings survived, 5 were killed by
the verifier** and are not listed. Nothing was edited: the RVA23
chain was mid-flight, so this is a task list, not a change.

Two of them explain the disk fight of that same evening, and one is proved by
a line from the log of the build that was running while the audit ran.

### WA. Per-arch MEDIA_SKIP flag files are COPY'd into the shared media `base` stage, so a riscv64-only edit re-runs the whole amd64 and arm64 media stage [high]

`linux/Dockerfile.media:174`

**What breaks.**
Backlog section G queues four riscv64-only skip-flag retirements
(MEDIA_SKIP_CSOUND, MEDIA_SKIP_GUDEV, MEDIA_SKIP_GLIB_STACK,
MEDIA_SKIP_CAIRO_PANGO_PIXBUF), each a one-line edit to
linux/scripts/03-media/core/arch-flags-riscv64.env, each to be 'proven by a
real riscv64 media stage'. That file is COPY'd unconditionally (line 174, the
last of the trio at 172-174) into the `base` stage that EVERY media stage
derives from, so the edit invalidates that layer and everything after it in
all three lanes. The amd64 and arm64 media builds then re-run from `base` —
onnxruntime cpu (1452.0s), app-wheelhouse (1523.5s), tvm (1377.1s), litert
(1353.6s), gstreamer (683.7s) and the rest — even though
`media_load_arch_flags` only ever sources the flag file for the arch being
built. Measured amd64 media stage = 134.3 min of RUN time, so one riscv64-only
flag flip costs ~4.5 h of amd64+arm64 recompile for zero behavioural change on
those arches.

**Evidence.**
linux/scripts/03-media/core/common.sh:64-71 — the candidate loop tries only
"/opt/scripts/03-media/core/arch-flags-${arch}.env" and the sibling-dir
fallback for the SAME ${arch}; nothing ever reads another arch's file (tree-
wide grep for 'arch-flags' returns only these three COPYs, common.sh:65-66,
and two comment references). `ARG TARGET_ARCH` is already declared at
Dockerfile.media:124, above the COPYs, so `COPY
linux/scripts/03-media/core/arch-flags-${TARGET_ARCH}.env ...` would carry
exactly the one file the image reads. This is the identical shape F6 already
fixed for verify-media-artifacts.sh ('no longer sits in the shared base stage
(8 edits since 2026-08-01, each re-paying the whole media stage on every
arch)', archive-2026-09-02:309). git log since 2026-07-01: arch-flags-
riscv64.env 5 commits, arm64 3, amd64 2. Step timings from out/build-
logs/f2-media-validation.log (#34/#28/#30/#33/#69).

**Verifier's correction.**
The finding is real but should be restated on three points. SCOPE — it is the
trio (Dockerfile.media:172-174), not line 174 alone. An edit to arch-flags-
amd64.env (172) or arch-flags-arm64.env (173) has the same cross-arch blast
radius and is strictly worse, since it also invalidates the two COPYs below
it. The fix is ONE parameterized COPY replacing all three: `COPY --chmod=644
linux/scripts/03-media/core/arch-flags-${TARGET_ARCH}.env
/opt/scripts/03-media/core/arch-flags-${TARGET_ARCH}.env`. Caveat for whoever
does it: ARG TARGET_ARCH at :124 has NO default (the
`${TARGET_ARCH:-${TARGETARCH}}` fallback exists only in the ENV at :158, which
a COPY source cannot use), so a hand-run `nerdctl build -f
linux/Dockerfile.media` without --build-arg TARGET_ARCH would resolve to
`arch-flags-.env` and hard-fail where it works today. Give the ARG a default
(`ARG TARGET_ARCH=amd64`) or the narrowing trades a cache win for a new build
break. TIMING — the riscv64 proof build itself costs nothing on the other
lanes. build-cross-chain.sh:17-18 takes TARGET_ARCHES from
resolve_arch_list/CROSS_TARGETS, so `CROSS_TARGETS=riscv64` builds only that
lane. The wasted amd64/arm64 recompile is paid on the NEXT 3-arch chain, which
would otherwise have hit cache on those two media stages. "Re-runs the whole
amd64 and arm64 media stage" is right for a 3-arch build, not for the single-
arch proof the backlog prescribes. NUMBER — "~4.5 h" is derived, not measured.
134.3 min is the measured amd64 warm-ccache media stage (F6, out/build-
logs/f2-media-validation.log); the arm64 figure was never measured in that
log. Honest statement: ~2.2 h on amd64 plus an unmeasured arm64 stage of
similar or greater size. The ccache/sccache cache mounts survive the
invalidation, so this is already the warm number — it does not shrink further.
ALSO WORTH NAMING — the same edit re-keys the runtime lane too:
Dockerfile.package:278 COPYs the whole `linux/scripts/03-media/core/`
directory, so all three arches' runtime `package` stages rebuild as well. That
stage is cheap relative to media, but it means the blast radius is wider than
the media stage alone.

### WB. The whole linux/scripts/patches/ tree is bind-mounted into 8 media RUNs, each of which reads only its own subdirectory [high]

`linux/Dockerfile.media:648`

**What breaks.**
Backlog items UA and UC delete patches/gstreamer/{003,004,005a,005b,006}; UD
deletes patches/libyuv/001. Any of those edits changes the content digest of
the whole-directory bind mount and therefore re-runs six RUNs that never read
the touched subdirectory: app-wheelhouse (line 648, 1523.5s), litert build
(line 472, 1353.6s), ORT genai (line 344, 371.8s), opencv build (line 606,
93.8s), opencv-gst (line 1016, 127.1s) and libcamera (line 963, 72.6s). That
is ~59 min per lane on a WARM amd64 ccache — roughly 3 h across the three
arches, more on the arm64/riscv64 cross lanes — bought by deleting a
GStreamer-only or libyuv-only patch file. The reverse also holds: the queued
GEN1 riscv64 genai patch work re-pays app-wheelhouse and litert on every arch.

**Evidence.**
Each consumer names exactly one (or, for libcamera, two) subdirectories:
build-litert.sh:533 -> /opt/scripts/patches/litert; build-
opencv.sh:242,259,263 -> /opt/scripts/patches/opencv; build-app-
wheelhouse.sh:646 -> /opt/scripts/patches/torchvision; 60-build-genai.sh:117
-> /opt/scripts/patches/onnxruntime-genai; build-libcamera.sh:32,45 ->
/opt/scripts/patches/libcamera + /opt/scripts/patches/libyuv; patch-gstreamer-
sources.sh:9-11 -> /opt/scripts/patches/gstreamer. The mount is identical
(`source=linux/scripts/patches`) at Dockerfile.media:344, 472, 606, 648, 870,
912, 963, 1016. Durations from out/build-logs/f2-media-validation.log steps
#28, #33, #39, #46, #74, #73. F6 (archive-2026-09-02:309) narrowed the ORT
`--step cpu` and tvm mounts by exactly this reasoning but left the patches
mount whole-tree everywhere; no backlog or archive entry mentions
scripts/patches as a cache-key surface.

**Verifier's correction.**
CONFIRMED with a corrected blast radius. `linux/scripts/patches` is bind-
mounted whole-tree into 8 RUNs in linux/Dockerfile.media (344, 472, 606, 648,
870, 912, 963, 1016) while every consumer reads exactly one file — apply-
patch.sh:18 and android-build-preamble.sh:107-123 both take a single patch
path and never glob. BuildKit puts the whole mounted subtree in each RUN's
cache key; the repo already proved this and gated it on the Windows lane
(docs/windows-build-invariants.md:670-684, "Every file under a directory mount
is part of that RUN's cache key" — it cost a full LLVM 23.1.0 recompile and is
now enforced by BuildKit.ModuleClosure.Tests.ps1). Linux has no such gate.
Three corrections to the claim: (1) OVERCOUNTED for the UA/UC trigger.
libcamera (963, 72.6s) and opencv-gst (1016, 127.1s) are NOT recoverable waste
when a gstreamer patch is deleted: 943:FROM gstreamer and 994:FROM gstreamer,
and RUN 912 (build-gstreamer-stage.sh -> patch-gstreamer-sources.sh:9-11)
genuinely reads patches/gstreamer, so the parent stage legitimately rebuilds
and both children follow regardless of their own mounts. Recoverable there is
genai 371.8s + litert 1353.6s + opencv 93.8s + app-wheelhouse 1523.5s =
3342.7s ~= 56 min per lane on warm amd64 ccache, plus the inert re-run of
gstreamer install-deps (870) and whatever RUNs follow each invalidated one
inside its stage. (2) UNDERCOUNTED for the opposite trigger, which is the
bigger one. The gstreamer stage carries the same whole-tree mount twice (870,
912), so editing patches/libyuv/001 (UD), patches/onnxruntime-genai/001 (the
queued GEN1 work) or patches/torchvision/001 re-pays the entire gstreamer
build — the dominant RUN in that half of the file — plus libcamera and opencv-
gst downstream, on every arch. (3) MISSED INSTANCE.
linux/scripts/patches/generate-patches.sh is host-only tooling that never
executes in any image (its only in-repo reference is the error message at
apply-patch.sh:63) yet sits inside the mounted tree, so editing it re-keys all
8 RUNs on all three arches for zero build effect — the exact shape F6 already
fixed for verify-media-artifacts.sh and linux/qnn-sdk/*.md. On prior art: no
backlog or archive entry mentions scripts/patches (grep is empty), and F6's
"Still open here" list names only the genai/wasm/js script mounts.
docs/gen1-riscv64-genai.md:165-172 does discuss the patches mount as a cache-
key surface, but only for the genai RUN and only to argue it is redundant with
the already-broad 03-media/build/onnxruntime tree mount; it never considers a
patch edit in one component re-paying another component's stage, which is the
finding. Fix note: narrow each mount to the per-component SUBDIRECTORY, not to
the individual .patch file — a file-level mount source that later gets deleted
makes BuildKit fail at cache-key time ("not found"), turning every future
patch removal into a Dockerfile edit as well.

### WC. SHIPPED-TRUTH A is inert for 10 of its 16 keys: the in-image probe emits no ADV line for them, so every one is a permanent SKIP [high]

`linux/scripts/06-packaging/smoke-runtime-image.sh:665`

**What breaks.**
Bump `ARG ONNXRUNTIME_VERSION=v1.29.0` to `v1.30.0` in
linux/Dockerfile.package:175 (or let
IREE/OPENCV/LITERT/PYAV/CMAKE/NODE/UV/UBUNTU drift from what is actually
built). Dockerfile.package:180-189 turns all ten of those ARGs into ENV, so
the shipped wrapper advertises `ONNXRUNTIME_VERSION=v1.30.0` while carrying
1.29.0. `_shipped_truth_probe` has no `printf 'ADV ONNXRUNTIME_VERSION'` line,
so `adv` is empty in `_advert_verdicts` (line 817) and the gate emits `SKIP
ONNXRUNTIME_VERSION image sets no ONNXRUNTIME_VERSION -- nothing advertised to
check`. `check_advertised_versions` (line 991) only fails when ok+bad == 0,
and the six ADV-backed keys keep that count non-zero, so the gate prints `pass
"all 6 advertised version(s) match the shipped image"` and the manifest ships.
Downstream consumers read the env label; the SKIP message is itself false (the
image does set the key).

**Evidence.**
ADV printfs exist only at lines 665-671 (PYTHON_VERSION, PYTHON_MAJOR_MINOR,
GCC_VERSION, LLVM_RELEASE, GSTREAMER_VERSION, VULKAN_VERSION, PYTORCH_EXTRA).
HAVE printfs exist for 16 keys (672-704). `_ADVERTISED_VERSION_KEYS` (line
784) lists 16. I ran `_advert_verdicts` verbatim (extracted with sed, no repo
mutation) against a probe carrying deliberately wrong HAVE values -- OPENCV
4.9.0, ONNXRUNTIME 1.27.0, IREE 3.10.0, LITERT 1.0.0 -- and got: `SKIP
UBUNTU_VERSION`, `SKIP CMAKE_VERSION`, `SKIP NODE_VERSION`, `SKIP UV_VERSION`,
`SKIP OPENCV_VERSION`, `SKIP ONNXRUNTIME_VERSION`, `SKIP
ONNXRUNTIME_GENAI_VERSION`, `SKIP PYAV_VERSION`, `SKIP IREE_VERSION`, `SKIP
LITERT_VERSION` -- zero BAD rows. Only
PYTHON_MAJOR_MINOR/GCC_VERSION/LLVM_RELEASE/GSTREAMER_VERSION/VULKAN_VERSION
produced verdicts. Corroborating: docs/cross-build-verification.md:398 and
:448 still describe the gate as covering exactly the six ADV-backed keys ('the
advertised-version table only covers the six keys listed above'), and its
mutation record says 'A fails the vacuous-pass guard after six loud SKIPs' --
the table was widened to 16 without widening the probe. docs/refactoring-
backlog.md:619 records the opposite belief ('The advert-keys gate compares the
RUNTIME's numeric prefix, so this skew is currently green'), so the IREE
compiler/runtime skew entry is filed under a mechanism that never runs.

**Verifier's correction.**
The claim is real but overstated in three places and understated in one.
CORRECT AS CLAIMED: `_shipped_truth_probe` (smoke-runtime-image.sh:661-708)
emits `ADV` for only 7 names while `_ADVERTISED_VERSION_KEYS` (784) lists 16,
so ten keys can never reach the comparator's OK/BAD arms. Running the real
`_advert_verdicts` against a probe with deliberately wrong HAVE values yields
5 OK / 11 SKIP / 0 BAD. The SKIP text is factually false:
Dockerfile.package:180-189 does ENV those keys. CORRECTION 1 — it is 11 of 16,
not 10. PYTHON_VERSION also SKIPs, because Dockerfile.package:199 deliberately
does not ENV it ("nothing stages /opt/python-cross into this image"). So the
gate's success line reads `all 5 advertised version(s) match the shipped
image`, not 6. CORRECTION 2 — the proposed trigger cannot happen. Hand-bumping
`ARG ONNXRUNTIME_VERSION=v1.30.0` in Dockerfile.package is caught at preflight
by linux/scripts/01-core/verify-arg-consistency.sh:64-92 (slug `arg-
consistency`), which fails when any Dockerfile ARG literal default differs
from versions.env. The real trigger is the opposite direction: the label
agrees with versions.env while the SHIPPED ARTIFACT does not — a PyPI wheel
shadowing the source build, a `--no-deps` install, a distro binary winning
PATH, or a dev-tagged build. That is precisely the skew gate A was written
for. CORRECTION 3 — four of the ten keep a second net. `check_ml_version_pins`
(smoke-runtime-image.sh:355) delegates to smoke-torch-venv.sh
`assert_pinned_versions` (line 75), which compares ONNXRUNTIME_VERSION,
ONNXRUNTIME_GENAI_VERSION, LITERT_VERSION and OPENCV's MAJOR against the in-
image versions.env (lines 94-98). Those four would still red on a gross
mismatch. CORRECTION 4 (understated) — the genuinely unguarded set is
IREE_VERSION, PYAV_VERSION, OPENCV minor/patch, UBUNTU_VERSION, CMAKE_VERSION,
NODE_VERSION and UV_VERSION: no other gate in linux/scripts compares any of
them to anything. IREE is the live instance — docs/refactoring-backlog.md:619
records the CONFIRMED `iree-base-compiler 3.11.0` vs `iree-base-runtime
3.11.0.dev0+e4a3b04` skew as "currently green" because "the advert-keys gate
compares the RUNTIME's numeric prefix", and that comparison never executes.
Were the runtime to drift to 3.10.0, the image would ship advertising
IREE_VERSION=v3.11.0 and the smoke would print `SKIP IREE_VERSION image sets
no IREE_VERSION` then `pass all 5 advertised version(s) match`. ROOT CAUSE
(not in the claim): commit d27cdee1 fixed only the Dockerfile half; `git show
d27cdee1 -- linux/scripts/06-packaging/smoke-runtime-image.sh` is an empty
diff. The missing enforcement is in verify-advertised-keys.py:63, which
computes `checked` from the `_ADVERTISED_VERSION_KEYS` string alone and never
requires a matching `ADV <key>` printf in the probe — its own FAIL message
asks for "a HAVE probe + a row in _ADVERTISED_VERSION_KEYS" and forgets the
ADV line it depends on. tests/test-advertised-keys.sh:54 synthesizes the ADV
line, so the suite cannot see the gap either. The one-line fix is ten more
`printf 'ADV <KEY> %s\n' "${<KEY>:-}"` lines in the heredoc; the durable fix
is to make verify-advertised-keys.py grep the probe for `ADV <key>` as well as
the table.

### WD. The two guards built to prevent an unchecked version key cannot detect a missing ADV probe: one checks list membership only, the other fabricates the ADV line [medium]

`linux/scripts/verify-advertised-keys.py:64`

**What breaks.**
Delete the line `printf 'ADV GSTREAMER_VERSION %s\n' "${GSTREAMER_VERSION:-}"`
from `_shipped_truth_probe` (smoke-runtime-image.sh:669) -- a plausible edit
while reworking the probe. `verify-advertised-keys.py` builds `checked` purely
from the `_ADVERTISED_VERSION_KEYS` string (line 62-64), so preflight slug
`advert-keys` still reports 'OK: every advertised version key is checked or
excused'. `linux/scripts/tests/run-tests.sh` still passes, because test-
advertised-keys.sh:54 constructs `"ADV $1 $2\nHAVE $1 $3"` itself instead of
driving the real probe. The runtime smoke silently demotes GSTREAMER_VERSION
to a SKIP row and a wrong GStreamer label ships green. This is the mechanism
that let finding #1 happen and will let it recur after any point fix.

**Evidence.**
`verify-advertised-keys.py:62-64` builds its `checked` set by regexing
`_ADVERTISED_VERSION_KEYS="…"` out of the smoke -- nothing ever greps for the
probe line that would supply the value. Its own failure text (76-79) tells you to
add both a probe and a table row, but only the row is verified. The unit test
cannot catch it either: `tests/test-advertised-keys.sh:54` builds the probe output
by hand instead of driving the real probe. The probe's own contract is documented
in docs/cross-build-verification.md -- that page owns it; this entry only records
that nothing checks the two halves against each other.

**Verifier's correction.**
Accurate statement: neither guard verifies that the in-image probe actually
emits an `ADV <key>` line, so a key can sit in `_ADVERTISED_VERSION_KEYS` and
be reported fully covered while never being compared. This is not a latent
risk — it is the current state for 10 of the 16 keys. `_shipped_truth_probe`
(linux/scripts/06-packaging/smoke-runtime-image.sh:665-671) emits ADV for only
PYTHON_VERSION, PYTHON_MAJOR_MINOR, GCC_VERSION, LLVM_RELEASE,
GSTREAMER_VERSION and VULKAN_VERSION (plus PYTORCH_EXTRA). UBUNTU_VERSION,
CMAKE_VERSION, NODE_VERSION, UV_VERSION, OPENCV_VERSION, ONNXRUNTIME_VERSION,
ONNXRUNTIME_GENAI_VERSION, PYAV_VERSION, IREE_VERSION and LITERT_VERSION are
in the 16-key table (smoke:784-787), have working HAVE probes (smoke:692-701)
and are ENV-set in the shipped image (linux/Dockerfile.package:180-189), yet
`_advert_verdicts` (smoke:820, 825-826) sees an empty `adv` and emits `SKIP
<key> image sets no <key> -- nothing advertised to check` — a reason that
stopped being true when commit d27cdee1 added those ENVs. Gate A therefore
still asserts 5 rows, not 16. The three guards that should catch this cannot:
verify-advertised-keys.py:58-64 derives `checked` from the table string alone;
the vacuous-pass guard (smoke:1009-1010) only fires when *every* key skips;
and test-advertised-keys.sh:54 hand-writes the ADV line it tests against. The
consequence is a documentation/artefact divergence the repo already published:
docs/refactoring-backlog-archive-2026-09-02.md:432-437 says "16 keys are
checked", Dockerfile.package:169 says the SKIPs were fixed, and docs/cross-
build-verification.md:398-400 and 448-450 still describe six keys — while the
shipped gate compares five. The correct guard is to have verify-advertised-
keys.py require, for each key in `_ADVERTISED_VERSION_KEYS`, both an `ADV
<key>` and a `HAVE <key>` emitter in the probe, and/or to have the smoke fail
(not SKIP) when a key the image genuinely ENV-sets produced no ADV row. The
claim's specific illustration is the one inaccurate part: the `ADV
GSTREAMER_VERSION` line at smoke:669 still exists and is one of the rows that
does assert, so that deletion is hypothetical; the ten ENV-only keys are the
live instance.

**PARTLY CLOSED 2026-09-03.** The blind spot is gone for anything NEW:
`verify-advertised-keys.py` now extracts the `ADV <KEY>` printfs from the smoke
and fails a table row that has none, and it fails just as hard when a frozen row
gains a probe without leaving the baseline — so the freeze cannot rot into
cover for the next one. The 10 already-inert rows are frozen in
`FROZEN_UNPROBED` and reported on every run; retiring them is WC, and each
retirement must delete its baseline entry or the gate says so. Both mutations
were proven to go red (4 of 17 assertions in `test-advertised-keys.sh`), and the
fixture copies the smoke rather than touching it — that file is inside the
closure the chain was re-reading at the time.

### WE. check_healthcheck_exec runs a hardcoded copy of the HEALTHCHECK, not the image's own; check_healthcheck_config only asserts the constant Test[0] [medium]

`linux/scripts/06-packaging/smoke-runtime-image.sh:1206`

**What breaks.**
Edit linux/Dockerfile.torch:149 to `CMD /opt/venv/bin/python -c "import
orchestr_ant_ion.server" || exit 1` (a rename, a venv interpreter path change,
or a probe swap). Every shipped container then flaps `unhealthy` and
orchestrators refuse to route to it. Both healthcheck gates stay green:
`check_healthcheck_exec` executes its own hardcoded `/opt/venv/bin/python3 -c
'import onnxruntime'`, which still works, and `check_healthcheck_config` (line
141) reads `hc.get('Test',[''])[0]`, which is the OCI verb `CMD-SHELL`/`CMD`,
never the command -- so it can only distinguish 'a HEALTHCHECK exists' from
'none', not right from wrong. The runtime smoke exits 0 and build-runtime-
manifest.sh:309 publishes the index.

**Evidence.**
smoke-runtime-image.sh:1206 hardcodes `/opt/venv/bin/python3 -c 'import
onnxruntime'` under a comment claiming 'Run the ACTUAL HEALTHCHECK command,
not just parse its Test string'. linux/Dockerfile.torch:148-149 is the real
definition. check_healthcheck_config:146 prints `pass "HEALTHCHECK configured:
${healthcheck}"` where `${healthcheck}` is Test[0] -- a constant verb, so the
pass message also misreports what was checked. `inspect_image_config` is
already used elsewhere in the file (lines 22-24, 100), so reading the real
Test[1] and running it needs no new machinery. docs/refactoring-backlog-
archive-2026-08-10.md:478 records this as closed ('HEALTHCHECK now EXECUTED
not just [parsed]'), i.e. the repo believes the command is read from the
image.

**Verifier's correction.**
Accurate as stated, with two line-number/scope refinements. The hardcoded
probe is at smoke-runtime-image.sh:1207 (function opens :1202, comment :1199).
And check_healthcheck_exec is not a gate that can never fail: it does catch a
broken venv interpreter or an unimportable onnxruntime — the cases its comment
names. What it cannot catch is the change class it was added to guard against:
any edit to Dockerfile.torch:149 itself. Because the command is a hand-
maintained duplicate rather than Config.Healthcheck.Test[1] read from the
image, the smoke keeps executing the OLD command after the HEALTHCHECK
changes, so both healthcheck gates stay green while every shipped container
reports unhealthy. check_healthcheck_config's Test[0] is confirmed constant in
production logs (`PASS HEALTHCHECK configured: CMD-SHELL`, out/build-
logs/runtime-retry2.log, all three arches), so it is present-vs-absent only
and its pass message misstates what was checked. Fix is one line each: read
Test[1] via the existing inspect_image_config helper, assert it non-empty, and
run that string instead of the literal.

### WF. The app-wheel ratchet silently disarms when the ok-count cannot be parsed, falling back to the exit status the ratchet exists to distrust [medium]

`linux/scripts/06-packaging/smoke-runtime-image.sh:254`

**What breaks.**
The sibling app repo changes its summary wording (e.g. `=== 15/15 ok,` -> `===
15/15 passed,`) or the invocation gains `--json`. `sed -n 's/.*===
\([0-9]\{1,\}\)\/[0-9]\{1,\} ok.*/\1/p'` then matches nothing, `_wheel_ok` is
empty, `[ -n "${_wheel_ok}" ] && [ "${_wheel_ok}" -lt "${_wheel_floor}" ]`
short-circuits false, and control falls to the else branch which prints `pass
"app wheel smoke passed on-target (amd64, ? ok >= 15)"`. The gate is then back
to exit-status-only, which the comment at line 239-243 documents as
insufficient: the app exits 0 whenever `failures == 0` and reports a vanished
component as a WARNING. An amd64 wrapper that lost torchvision, tvm and pyav
(optional/warning results) ships as `latest-cross` with a green ratchet line
naming the floor it never enforced.

**Evidence.**
The count is produced by exactly one line in a DIFFERENT repo:
/home/bigjuicyjones/GitHub/Kataglyphis-Orchestr-ANT-
ion/orchestr_ant_ion/smoke/__main__.py:73 `f"=== {passed}/{len(results)} ok,
"`, reached only on the non---json path (line 68-74); `main` returns 0
whenever `failures` is empty (line 76), and `warnings` (optional checks) are
excluded from `failures` (line 58). ContainerHub pins that repo only by
APP_REF (linux/Dockerfile.torch:37, v0.0.27) -- nothing in ContainerHub gates
the output format, so this is an unguarded cross-repo string contract. The `?`
placeholder at smoke-runtime-image.sh:258 (`${_wheel_ok:-?}`) shows the empty
case was anticipated for the message but not for the verdict. Backlog line 84
tracks raising the riscv64 floor 12 -> 13 but not this parse hole.

**Verifier's correction.**
The mechanism is exactly as claimed, but three parts of the offered scenario
are overstated and should be restated: 1. THE HEADLINE EXAMPLE IS PARTLY
WRONG. `check_arch_parity` (smoke-runtime-image.sh:584-618) independently
asserts dist-info presence for `_PARITY_WHEELS = "torch torchvision
ai_edge_litert iree_base_compiler iree_base_runtime onnxruntime_genai"` (line
534) against a per-arch exemption list (`_parity_exempt`, line 540-553) that
grants amd64 nothing. An amd64 wrapper that LOST torchvision would therefore
fail ARCH-PARITY regardless of the ratchet. The correct blast radius is
narrower and split in two: - components absent from `_PARITY_WHEELS` — tvm,
pyav/av, pillow, opencv-python — where a vanished wheel is caught by nothing
but the ok-count; and - PRESENT-BUT-BROKEN wheels on any arch, including
torchvision, since check_arch_parity reads dist-info directories only and
never executes the wheel. That second case is precisely the failure the
ratchet was built for (archive-2026-08-10.md:425 records the app-wheel smoke
catching a broken LiteRT that imported fine). 2. "SILENTLY" NEEDS
QUALIFICATION. The app is pinned by tag (`APP_REF=v0.0.27`,
linux/scripts/01-core/versions.env:329, mirrored at
linux/Dockerfile.torch:37/102), so an upstream push cannot drift the format
into a running build. The trigger is a deliberate ContainerHub commit bumping
APP_REF to an app version whose summary wording changed. The `--json` half of
the scenario is not reachable at all: line 252 invokes `python -m
orchestr_ant_ion.smoke` as a fixed literal with no flag forwarding, so
`--json` requires editing ContainerHub. The defect is that such a bump disarms
the ratchet with nothing going red — not that the format can drift on its own.
3. IT IS INVISIBLE TO THE GATE, NOT TO A READER. Line 258 prints `? ok >= 15`
via `${_wheel_ok:-?}`, and line 253 dumps the full smoke output, so a human
reading the chain log can see the parse failed. The defect is that the verdict
is green and FAILURES is not incremented. Accurate statement: the app-wheel
ratchet's floor comparison is guarded by `[ -n "${_wheel_ok}" ]`, so an
unparseable ok-count routes to `pass` instead of `fail`. The floor is then
unenforced and the verdict reverts to the app's exit status, which is 0
whenever `failures` is empty and treats every optional check (tvm, pyav,
cv2-dnn, cv2-freetype, litert, iree) as a warning. This is reachable via an
APP_REF bump to an app whose summary wording changed, and it leaves present-
but-broken wheels and the untracked components (tvm, pyav, pillow, opencv-
python) with no gate at all. The fix matches the pattern already used 20 lines
below for the ONNX-EP sentinel: `fail` when the count cannot be parsed rather
than falling through to `pass`.

### WG. `if ! build_canadian_native_gcc_for …` disables errexit for the whole multi-hour builder run, so build-gcc.sh's exit code is discarded [high]

`linux/scripts/02-toolchain/gcc.sh:383`

**What breaks.**
During the Canadian native GCC build for arm64/riscv64, `bash
"${GCC_CROSS_BUILDER}" …` (gcc.sh:315) runs `make install-gcc install-target-
libgcc install-target-libstdc++-v3 install-target-libatomic` (build-
gcc.sh:865). `install-gcc` runs first and installs ${native_prefix}/bin/gcc
and bin/g++; if a later target then fails — ENOSPC mid-install (this repo's
recurring disk emergency), or the libstdc++ std-module breakage the tree
already has a patch for — make stops and build-gcc.sh (set -Eeuo pipefail)
exits 1. Because build_canadian_native_gcc_for is invoked as the condition of
`if !`, bash suppresses errexit for its entire dynamic extent, so that non-
zero exit does NOT abort: execution falls through to gcc.sh:326-327 `[ -x
"${native_prefix}/bin/gcc" ] || die` and `[ -x …/g++ ] || die`, which both
PASS (install-gcc already put them there), then to assert_gcc_elf_arch
(gcc.sh:332-333), which only reads the ELF header (gcc.sh:105-130 — readelf +
a Machine: string compare, it never compiles or links anything). The
function's last statement is `log "Installed native GCC …"`, so it returns 0,
the `if !` sees success and prints no warning, and the toolchain stage reports
green while shipping a target-native GCC with no target libstdc++/libatomic.
The failure resurfaces hours later in Dockerfile.android's GCC swap or in the
first C++ compile that uses it.

**Evidence.**
gcc.sh:383 `if ! build_canadian_native_gcc_for "${full_version}" "${prefix}"
"${triplet}" "${normalized_target}"; then`. The comment directly above it
(gcc.sh:380-382) states the intent: "build_canadian_native_gcc_for returns 1
(instead of dying) when the opt-in skip knob is set; keep that skip from
aborting the remaining targets even with errexit live" — i.e. the `if !` is
meant to tolerate exactly one `return 1` (gcc.sh:288,
GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE), but it also swallows every other
non-zero status inside the function, including the builder's. Note the
contrast: every OTHER failure in that function is raised with `die`
(gcc.sh:265, 266, 290, 326, 327), which calls `err` → `exit 1` (logging.sh:79)
and therefore survives the suppression; only the builder invocation at
gcc.sh:315 relies on errexit and is the one that is lost. Suppression
confirmed empirically on this host's bash 5.3.9: `set -euo pipefail; f() {
bash -c "exit 3"; echo REACHED; return 0; }; if ! f; then echo saw; fi` prints
REACHED and exits 0. Related, same file: the parallel driver's per-target
subshell (gcc.sh:475 `( JOBS=… _gcc_build_cross_target "${t}" ) > log 2>&1 &`)
routes through the same `if !`, so a parallel target build hits it too. Not
present in docs/refactoring-backlog.md or any refactoring-backlog-archive-*.md
(greps for 'canadian', 'errexit', 'GCC_CANADIAN' return only unrelated
entries).

**Verifier's correction.**
The core is real: at linux/scripts/02-toolchain/gcc.sh:383 the `if !` wrapper
— added to tolerate the single `return 1` at gcc.sh:290
(GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE) — also disables errexit for the
multi-hour `bash "${GCC_CROSS_BUILDER}"` invocation at gcc.sh:315, whose exit
code is then discarded, and the only checks that follow (gcc.sh:326-327 `[ -x
] || die`, gcc.sh:332-333 readelf-only assert_gcc_elf_arch defined at
gcc.sh:105-131) cannot detect a partially-installed toolchain. Scope nit:
errexit is suppressed for the function's dynamic extent, not "the whole
builder run" — but that extent contains the entire builder call, so the
practical effect is as claimed. Two specifics need fixing. (1) Both named
triggers are wrong. The libstdc++ std-module/fenv failure is recorded in-tree
at gcc.sh:300 as `make[3]: [Makefile:868: stamp-modules-bits] Error 1
(ignored)` — make ignores it, so build-gcc.sh never exits non-zero for it. And
any failure during the compile phase (build-gcc.sh:737 `make -j"${JOBS}" all-
gcc all-target-libgcc all-target-libstdc++-v3 all-target-libatomic`) occurs
BEFORE any install, leaving ${native_prefix}/bin/gcc absent, so gcc.sh:326 `||
die` does hard-fail. The genuine silent window is narrow: only a non-zero exit
AFTER `make install-gcc` has already placed bin/gcc, i.e. a failure in the
later targets of the single install command at build-gcc.sh:762 (`make
install-gcc install-target-libgcc install-target-libstdc++-v3 install-target-
libatomic`) — ENOSPC being the realistic case given this repo's recurring disk
pressure — or in the final unguarded `rm -rf "${BUILD_DIR}"` at build-
gcc.sh:856 (every other post-install command is `|| true`-guarded). (2) It
does not ship a broken artifact. linux/scripts/06-packaging/smoke-runtime-
image.sh:1265 check_native_compiler_battery (invoked at :1419)
compiles+links+RUNS C `-latomic` and C++ hello/exceptions+STL/std::thread/LTO
under binfmt/qemu and hard-`fail`s, and validate-compilers.sh's C link smoke
hard-fails in Dockerfile.package on a missing libgcc. So the accurate impact
is: the toolchain stage's Canadian-cross gate cannot fail for a builder
failure that happens after install-gcc, it prints "Installed native GCC …" and
goes green, and the defect only surfaces at the end-of-chain runtime smoke
hours later — note swap-native-gcc.sh:143 `_smoke_native_gcc` is warning-only,
so the android stage does not catch it either. Minimal fix: capture the status
instead of suppressing it, e.g. `local _rc=0; build_canadian_native_gcc_for …
|| _rc=$?` and treat `_rc=1` (the documented skip) as tolerable while dying on
anything else, or have the skip path set a sentinel variable rather than
returning 1.

### WH. RUST_VERSION never reaches the package stage: both rustc-pin gates are structurally inert, and the shipped image resolves rustc/cargo to Ubuntu 1.93.1 against a 1.98.0 pin [high]

`linux/scripts/06-packaging/setup-package-image.sh:463`

**What breaks.**
`report_rust_provenance()` is the HARD GATE added after the 2026-08-07
incident (its own comment at lines 456-462: "if the shipped rustc does not
match RUST_VERSION, the image is wrong and this build stops... Never again
silently"). It opens with `local want="${RUST_VERSION:-}"` and returns 0 with
a NOTE when that is empty. RUST_VERSION is empty on every single build of the
package stage: `linux/Dockerfile.package` declares no `ARG RUST_VERSION` and
no `ENV RUST_VERSION` anywhere (the only Dockerfile ARG in the Linux tree is
`Dockerfile.toolchain:229`, a different image), `linux/Dockerfile.base` never
exports it either, and `setup-package-image.sh` sources only `platform.sh` +
`package-lists.sh`, never `versions.env` (the file's own comment at line ~353
states this: "this script sources platform.sh/package-lists.sh only, not
common.sh, so nothing loads the baked versions.env into its env"). The twin
guard in `wire_cargo_symlinks()` at line 317 (`if [ -n "${RUST_VERSION:-}" ]
&& [ -x "${CARGO_HOME}/bin/rustc" ]`) is gated on the same empty variable and
is skipped as well. Net effect measured live on all three arches in the
2026-09-02 runtime build: the package image resolves `cargo` and `rustc` to
Ubuntu's debs (`/bin/rustc -> /usr/lib/rust-1.93/bin/rustc`, rustc 1.93.1)
while `linux/scripts/01-core/versions.env:113` pins `RUST_VERSION=1.98.0` —
i.e. the exact regression these gates exist for is live again and both gates
printed the skip line instead of failing. Nothing downstream catches it:
`verify-advertised-keys.py:23` EXCUSES `RUST_VERSION` with the reason "a
build-stage toolchain; rustc is not shipped in the runtime image", which is
false — `linux/Dockerfile.package:110-111` COPYs `/usr/local/rustup` and
`/usr/local/cargo` into the runtime image precisely so it is shipped — so the
smoke's advertised-vs-actual gate skips it too, and `grep -n 'rust\|cargo'
linux/scripts/06-packaging/smoke-runtime-image.sh` returns zero hits. A
consumer (the comment names Kataglyphis-RustProjectTemplate) hits an MSRV
error that blames its own dependency.

**Evidence.**
Code: setup-package-image.sh:463-466 `local want="${RUST_VERSION:-}" got` /
`if [ -z "${want}" ]; then echo " NOTE: RUST_VERSION unset; cannot verify the
toolchain matches its pin." >&2; return 0`. Same file:317 `if [ -n
"${RUST_VERSION:-}" ] && [ -x "${CARGO_HOME}/bin/rustc" ]; then`. Live proof,
/home/bigjuicyjones/GitHub/Kataglyphis-ContainerHub/out/build-logs/runtime-
retry2.log, three occurrences (lines 402047-402052 amd64, 1358864-1358869
arm64, 2046845-2046850 riscv64): `#49 60.38 cargo /bin/cargo ->
/usr/lib/rust-1.93/bin/cargo (cargo 1.93.1 ...)` `#49 60.41 rustc /bin/rustc
-> /usr/lib/rust-1.93/bin/rustc (rustc 1.93.1 ...)` `#49 60.50 NOTE:
RUST_VERSION unset; cannot verify the toolchain matches its pin.` On
arm64/riscv64 the same block also shows `rustup /usr/local/cargo/bin/rustup ->
... (no --version)` — the copied rustup is an x86_64 binary there. Secondary
observation on the mechanism: `_link_unless_rustup_provides()` at setup-
package-image.sh:298 accepts a DANGLING symlink as "rustup provides it" (`[ -e
"${link_path}" ] || [ -L "${link_path}" ]`), so its documented apt fallback
does not fire for a broken link — the log shows all six "Keeping existing
/usr/local/cargo/bin/<tool>" lines immediately before `command -v` still lands
on /bin. Backlog checked: `grep -n 'RUST_VERSION|rustc' docs/refactoring-
backlog.md docs/refactoring-backlog-archive-*.md` returns only the unrelated
meson `rustc.cmd_array()` item (UA) and a Windows-lane note; `grep -i 'rust
provenance|RUST_VERSION unset|1.93.1'` across backlog + CHANGELOG + changelog
archives returns nothing.

**Verifier's correction.**
The claim is accurate as written; two refinements. (a) Date of the live
evidence: the proof is in out/build-logs/runtime-retry2.log with mtime
2026-08-27 14:06, not the "2026-09-02 runtime build" the claim names. The line
numbers and content it cites are correct. (b) Missing mechanism detail that
sharpens the fix: the orchestrator is NOT failing to forward the value.
linux/scripts/01-core/version-forwarding.sh:26-40 forwards every versions.env
key not preceded by a `# noforward` comment, and versions.env:113
RUST_VERSION=1.98.0 carries no such marker — so `--build-arg
RUST_VERSION=1.98.0` IS passed to the package build and BuildKit discards it
because Dockerfile.package declares no matching ARG. version-forwarding.sh's
own header comment names this failure class exactly: "a build arg no
Dockerfile declares is ignored by BuildKit; forgetting to forward a consumed
variable is not". The fix is therefore a one-line `ARG RUST_VERSION` (plus an
ENV, if it should also be advertised in the image config) in
Dockerfile.package's `package` stage — not a change to the forwarding.
Additional supporting evidence for the "no gate covers this" leg: verify-arg-
consistency.sh:34-55 checks only the Dockerfile-ARG -> versions.env direction
(is every version-named ARG forwarded, and does its default match). It has no
check in the reverse direction — that a script running inside a stage which
reads ${VAR} has a corresponding ARG declared in that stage's Dockerfile — so
this whole class of "silently empty in the RUN" bug is invisible to the
preflight suite, not just this instance.

### WI. cross_stage_is_per_arch leaks its `for s` loop variable and silently corrupts the disk-guard's protected-slug list (base + compiler cache exports are never protected) [high]

`linux/scripts/01-core/stage-defs.sh:135`

**What breaks.**
`cross_stage_is_per_arch()` declares `local stage="$1"` but NOT `local s`, and
iterates `for s in "${CROSS_PER_ARCH_STAGES[@]}"`. Its only caller that
iterates its own `s` is `_disk_guard_protected_slugs`
(linux/scripts/01-core/disk-guard.sh:68 `for s in "${CROSS_STAGE_ORDER[@]}"`,
:74 `if cross_stage_is_per_arch "${s}"`). On the return-1 path (a NON-per-arch
stage: base, compiler, runtime) the callee runs its loop to completion and
leaves the caller's `s` set to `android`, so line 81 evaluates
`cross_stage_tag "${s}"` with s=android and no arch -> `<repo>:cross-android-`
instead of the stage's real tag. Concrete break: run `build-cross-chain.sh
--from-stage base` (or any full chain) and let free space fall below
CROSS_DISK_GUARD_GB right after the base stage. `_chain_stage_disk_guard base`
-> `_disk_guard_protected_slugs base` returns `..._cross-android-,..._cross-
sdk-amd64,...` with `..._cross-compiler-amd64` MISSING.
`_disk_guard_pick_victim` is oldest-mtime-first, so the compiler slug (the
oldest, written first) is the first victim and gets `rm -rf`'d minutes before
the compiler stage rebuilds LLVM/GCC with `--cache-from type=local,src=<that
dir>` -> full cold LLVM/GCC rebuild (this repo's own notes: 50 min warm vs 11
h cold). The same corruption drops BOTH `base` and `cross-compiler-amd64` from
`_disk_guard_protected_slugs ''`, which is the list used by the in-stage
watchdog (`_chain_disk_watch_start`) and the runtime-lane entry gate
(`_chain_runtime_lane_disk_gate`) — so during the multi-hour runtime lane
those two slugs are the first things trimmed. The unit suite cannot catch
this: linux/scripts/tests/test-disk-guard.sh:54 stubs
`cross_stage_is_per_arch() { [ "$1" = "sdk" ] || [ "$1" = "media" ]; }`, which
does not touch `s`, and then asserts the CORRECT list including
`repo_img_compiler`. The test passes green while production returns a
different list.

**Evidence.**
Live proof from the build running right now — out/chain-media-
runtime.log:952892: `[INFO] [disk-guard] 113G free < 120G after stage android
— LRU-pruning cache exports in /home/bigjuicyjones/.cache/kata-buildcache
(protected: ghcr.io_kataglyphis_kataglyphis_beschleuniger_cross-android-)`
After `android` the only remaining stage is `runtime`, whose tag is empty
(stage-defs.sh:152), so the correct output is `protected: none`. Instead it
printed an arch-less `cross-android-` slug that does not exist on disk. Read-
only repro (sourcing the real functions, stubbing only
arch_list_to_words/stage_enabled): after base : ..._cross-android-,..._cross-
sdk-amd64,... <- cross-compiler-amd64 ABSENT after android : ..._cross-
android- empty (watch) : ..._cross-android-,..._cross-android-,..._cross-sdk-
amd64,... <- base AND cross-compiler-amd64 ABSENT Not present in
docs/refactoring-backlog.md or any refactoring-backlog-archive-*.md (grepped
for is_per_arch / protected slug / loop variable).

**Verifier's correction.**
The mechanism, the file:line, the repro values and the "unit test cannot catch
this" analysis are all correct as stated. Three refinements to the severity
framing: 1. The live log line offered as evidence (out/chain-media-
runtime.log:952892, after stage `android`) PROVES the leak but is itself
harmless. After `android` the only remaining stage is `runtime`, whose correct
protected list is genuinely empty, so protecting a phantom slug changed
nothing — the run correctly pruned cross-media-amd64 and proceeded. The damage
lives in the other two shapes of the bug, which this run never exercised (it
was a --from-stage media run). 2. The sharp damage is the
`completed_stage=base` case: it drops `<repo>:cross-compiler-amd64` — the
single most expensive slug to regenerate — from the protected list, and
because `_disk_guard_pick_victim` is oldest-mtime-first with no keep-floor in
`_chain_stage_disk_guard` (build-cross-chain.sh:510-519), a warm cache dir
makes that slug the first victim right before the compiler stage rebuilds
LLVM/GCC. This requires three conditions to co-occur: the chain actually runs
the `base` stage, the cache dir already holds a compiler slug from a prior
run, and free space drops below CROSS_DISK_GUARD_GB at that boundary. That is
the repo's normal warm-rebuild configuration, but it is a conditional loss,
not a guaranteed one — on a genuinely cold first run there is nothing to lose.
3. For the `''` list (the in-stage watchdog `_chain_disk_watch_start` and the
runtime-lane entry gate `_chain_runtime_lane_disk_gate`), `base` and `cross-
compiler-amd64` are indeed both dropped and are indeed the first victims by
mtime — but neither slug is consumed by the runtime lane itself, so the cost
there is the NEXT run's cold LLVM/GCC, not an in-run failure. Also cosmetic:
the phantom `cross-android-` entry appears twice in that list (once from the
`compiler` iteration, once from `runtime`). The one-line fix is `local
stage="$1" s` at stage-defs.sh:134; the test at test-disk-guard.sh:54 should
stop stubbing `cross_stage_is_per_arch` and source the real stage-defs.sh, or
the stub should be written with its own `for s in ...` so it reproduces
production's scoping.

### WJ. Disk-guard's anti-spin protection appends with a space to a comma-matched list, so an undeletable slug loops forever [medium]

`linux/scripts/build-cross-chain.sh:518`

**What breaks.**
`_chain_stage_disk_guard` has two `while` loops (phase 1 free-space, build-
cross-chain.sh:509-522; phase 2 total-size cap, :543-556). Both handle an
undeletable victim with the comment "An undeletable slug stays the LRU pick
forever: without this the loop spins for the rest of the run. Protect it and
move on." and then do `protected="${protected} ${victim}"` (lines 518 and 552)
— a SPACE separator. But `_disk_guard_pick_victim`
(linux/scripts/01-core/disk-guard.sh:54) tests `case ",${protected_csv}," in
*",${name},"*`, i.e. it only recognises COMMA-delimited entries. With
protected="a,b V" the string is ",a,b V," which does not contain ",V,", so V
is never excluded. Break: any slug under BUILDKIT_CACHE_DIR that `rm -rf`
cannot fully remove (a file written by a rootful/differently-mapped buildkitd,
an EPERM inside the tree, or a slug a concurrent local cache-export
recreates). The loop picks it, fails to delete it, "protects" it
ineffectively, re-measures free space (unchanged), and picks the same victim
again — forever. The chain hangs between two stages with no timeout and no
progress, spinning `rm -rf`/`du`/`df` and emitting the same `[disk-guard]
could not remove X; skipping it` warning, until a human kills it. Neither loop
has an iteration cap or a break, unlike `_disk_guard_trim_cache_export` (disk-
guard.sh:153-156) which correctly `break`s on the same condition.

**Evidence.**
linux/scripts/build-cross-chain.sh:516-518 and :550-552 append with a space;
linux/scripts/01-core/disk-guard.sh:50-54 matches only on commas
(`_disk_guard_protected_slugs` itself builds a comma list at disk-
guard.sh:77/81). No test covers the undeletable-victim path (grep for 'could
not remove'/'undeletable' in linux/scripts/tests/ returns nothing), and it is
absent from docs/refactoring-backlog.md and all refactoring-backlog-
archive-*.md.

**Verifier's correction.**
The claim is correct as written; two refinements to its severity model. (a)
The spin needs the victim to make no *measurable* progress, not merely to
survive. A partially-deletable victim (some children removable, some not)
keeps freeing space on each pass, so the loop makes progress for a while — but
once its removable content is exhausted and free space is still under
threshold, it wedges exactly as described. The "instant hang" case is a victim
nothing can be removed from (unreadable/untraversable slug dir), which is what
an EPERM/root-owned export looks like. (b) The claim's "a slug a concurrent
local cache-export recreates" sub-case does NOT spin: recreation bumps the
slug's mtime to now, moving it to the end of `ls -1tr`, so pick_victim
advances to an older slug. Drop that one; the EPERM/undeletable case is the
real one. Two things the claim understates, both worth carrying into the fix:
* The bug is a dead fix, not an oversight — commit 5337d6c4 exists solely to
prevent this spin, so the repo believes it is protected and is not. That also
means any log line `[disk-guard] could not remove X; skipping it` appearing
more than once for the same X in a run log is a live sighting of the wedge,
which is a cheap way to check the currently-running build. * The correct fix
is one character plus a belt-and-braces stop:
`protected="${protected}${protected:+,}${victim}"` at both build-cross-
chain.sh:518 and :552 (matching the comma format `_disk_guard_protected_slugs`
produces), and ideally also a `break` in the phase-1/phase-2 loops mirroring
`_disk_guard_trim_cache_export` (disk-guard.sh:153-156) so a systematically-
undeletable cache dir cannot hang the chain even if the protected list is
later refactored. A unit test asserting `_disk_guard_pick_victim` skips a
victim added by the guard's own append expression would have caught this and
does not exist.

## X2026-09-03. Second audit sweep — angles the first round did not cover

Six fresh lenses (supply chain, a meta-audit of the 48 test suites,
concurrency, docs-vs-code, the runtime image's contract, and a completeness
critic asked what BOTH rounds would miss), with the ten W-findings handed over
as an exclusion list so a variant counted as refuted. **8 survived, 8 were
killed by the verifier** — a 50% refutation rate, which is the point of
running it.

Read-only again: the RVA23 chain was building its riscv64 wrapper while this
ran.

### XK. GCC tarball SHA512 verification is skipped silently whenever a HEAD probe to gcc.gnu.org fails — exactly the outage the ftpmirror fallback exists for [high]

`linux/scripts/02-toolchain/build-gcc.sh:481`

**What breaks.**
fetch_gcc_tarball (:469) downloads gcc-16.2.0.tar.xz from
MIRROR_TARBALL_URL=https://ftpmirror.gnu.org/gnu/gcc/gcc-16.2.0/ FIRST — a GNU
redirector that hands the request to an arbitrary volunteer mirror — with
gcc.gnu.org only as fallback. The sole unconditional integrity check on those
bytes is verify_gcc_sha512, and it is gated on `wget -q --spider "${SHA_URL}"`
against https://gcc.gnu.org/pub/gcc/releases/gcc-16.2.0/sha512.sum. That
spider is a HEAD request with NO --timeout/-t flags (every other wget in the
file passes `--timeout=20 -t 5`). Any non-200 — gcc.gnu.org unreachable or 5xx
(the single-host fragility the NET1 mirror was added for, per the comment at
:250-253), a CDN/WAF that answers HEAD with 403/405, or a DNS blip — makes the
function print `No sha512.sum found on server; continuing.` and `return 0`.
verify_gcc_gpg_signature (:381) then hits the identical spider against SIG_URL
on the same host and returns 0 the same way. Net result: the mirror's bytes
are extracted and configured/built (:520 onward) as the host GCC and all three
cross toolchains with ZERO integrity verification, and the whole 5-hour
chain's artifacts are produced by that compiler. The only trace in the log is
two innocuous 'not found on server' lines; the build exits 0 and every
downstream gate passes. This directly falsifies the in-code claim at :250-253
that the mirror is 'zero trust cost — sha512 verification below is against the
canonical server either way': the verification is conditional on the canonical
server being reachable, which is precisely what the mirror assumes it is not.

**Evidence.**
build-gcc.sh:481-484 `if ! wget -q --spider "${SHA_URL}"; then echo "No
sha512.sum found on server; continuing." >&2; return 0; fi` — contrast
:485-487, where a sha512.sum that DOES probe but fails to download is fatal
('refusing to continue unverified'), and :253 `# Try the GNU mirror redirector
first for the TARBALL (zero trust cost — sha512 verification below is against
the canonical server either way)`. MIRROR_BASE=https://ftpmirror.gnu.org/...
(:253), DOWNLOAD_BASE=https://gcc.gnu.org/... (:248),
SHA_URL=${DOWNLOAD_BASE}/sha512.sum (:256). The spider is the only wget in the
file without timeout/retry flags. Not present in docs/refactoring-backlog.md
or any docs/refactoring-backlog-archive-*.md (grepped for
gpg/sha512/spider/ftpmirror/build-gcc; the only hit, archive-2026-08-10:1511
'cache sha512.sum/.sig next', is a caching perf item).

**Verifier's correction.**
Confirmed, with three corrections and one strengthening. Accurate statement:
the GCC tarball is fetched mirror-first from the GNU redirector (build-
gcc.sh:469-472, MIRROR_TARBALL_URL) while both integrity proofs are canonical-
only (SHA_URL/SIG_URL, :256-257). Each proof is gated on an unauthenticated
availability probe of gcc.gnu.org — :481 for sha512.sum, :381 for the .sig —
and each probe failure is a `return 0` that continues the build. When
gcc.gnu.org does not answer those two probes with 200, the mirror's bytes are
extracted (:521) and built as the host GCC and all three cross toolchains with
no integrity check whatsoever, leaving only "No sha512.sum found on server;
continuing." and "No .sig found or accessible." in a log that exits 0.
Correction 1 — the "no --timeout/-t flags" argument is backwards. wget's
defaults are `--tries=20` and a 900s read timeout, so the bare spider is MORE
retry-persistent than the explicit `--timeout=20 -t 5` fetches, not less. A
momentary DNS blip is therefore not a realistic trigger. The realistic
triggers are (a) any non-2xx HTTP answer to the probe — a CDN/WAF or corporate
proxy that rejects HEAD with 403/405, a 429, a 5xx — which wget does not
retry, and (b) an outage that outlasts the default retries, i.e. precisely the
multi-minute gcc.gnu.org unavailability the NET1 mirror was added for.
Correction 2 — the GPG half is worse than described. :381-384 returns 0
WITHOUT calling `_gcc_gpg_require_or_warn` (:349), so `GCC_REQUIRE_GPG=1` —
the only knob that exists to make a skipped signature fatal, and one no file
in the repo sets — is structurally unable to fire on the unreachable-server
path. It covers only "gpg not installed" (:394) and "signer key unobtainable"
(:447). So there is no configuration of this repo, today, in which an
unreachable gcc.gnu.org fails the build. Correction 3 — scope the blast
radius. For Canadian-cross builders (HOST_TRIPLET set) a full gcc.gnu.org
outage would still abort loudly at :563-564, where
`contrib/download_prerequisites` pulls GMP/MPFR/MPC from the same host and
`die`s. The silently-unverified toolchain fully materializes in the non-
Canadian lanes (host GCC + the three cross toolchains, which use apt's
libgmp/libmpfr per :303-306) and, in the HEAD-rejection case, in every lane —
there the server is up, prerequisites download fine, and nothing anywhere in
the 5-hour chain notices. Also worth folding in: :489-491 is a second silent
skip on the same path — a downloaded sha512.sum with no matching
`gcc-<ver>.tar.xz` line warns and continues, so an upstream filename
convention change degrades to unverified as well. Finally, the realistic bad
outcome is substitution, not corruption: truncated or corrupt bytes die at
`tar -xf` (:522). What passes unnoticed is a volunteer mirror (or the
redirector) serving different-but-valid bytes, which then compiles every
artifact of the chain.

### XL. "missing cmake skips IREE with rc=1" leaves /usr/bin:/bin on PATH, so cmake is never missing — the _iree_check_prereqs skip path is never exercised and the case passes off a real host cmake failing on a stub source tree [medium]

`linux/scripts/tests/test-iree-wheelhouse-stages.sh:233`

**What breaks.**
Delete (or invert) `command -v cmake >/dev/null 2>&1 || { warn "cmake absent;
skipping IREE riscv64 runtime wheel"; return 1; }` at
linux/scripts/05-frameworks/torch/build-app-wheelhouse.sh:781. The suite stays
fully green. Reason: the case runs `( PATH="${TMP}/nocmake:/usr/bin:/bin";
build_iree_wheels )`, and this host has /usr/bin/cmake and /bin/cmake
(verified: `command -v cmake` -> /usr/bin/cmake), so `command -v cmake`
SUCCEEDS. `ninja` and `git` are stubs copied into nocmake/ at line 100 and
`wheel_platform_tag` is a shell stub, so _iree_check_prereqs returns 0 on
every run. Control flow then falls through _iree_setup_compiler_cache ->
_iree_fetch_source (stub git builds a fake tree with no CMakeLists.txt) ->
_iree_build_host_stage, which invokes the REAL /usr/bin/cmake against that
tree; cmake errors, the `|| return 1` fires and build_iree_wheels returns 1.
`t_assert_eq "1" "${_rc}"` therefore passes for a completely different reason
than the one its name and message ("prereq failure must return 1") claim.
Real-world consequence of the undetected regression: in a stage where cmake
genuinely is absent, IREE no longer degrades to the documented one-line warn-
and-skip; it wipes and re-clones the tree (`rm -rf "${src_dir}"` in
_iree_fetch_source) and then dies in a cmake-not-found configure whose log
points nowhere near the cause.

**Evidence.**
test-iree-wheelhouse-stages.sh:233 sets PATH to
`${TMP}/nocmake:/usr/bin:/bin`; line 100 copies only git+ninja into nocmake/,
never a cmake shim, and never removes /usr/bin from the search path. build-
app-wheelhouse.sh:781 is the guard the case claims to exercise. `ls -la
/usr/bin/cmake /bin/cmake` -> both present (12556296 bytes, Mar 27). This is
exactly the "right answer for the wrong reason" class the repo already fixed
for this same file's five build call sites (docs/refactoring-backlog-
archive-2026-08-31.md:217-231: "asserting rc == 1 did not discriminate ... the
right answer for the wrong reason"); the fix there added `_no_packaging_diag`
to the five build cases (test-iree-wheelhouse-stages.sh:252, 262, 270, 279)
but never revisited the prereq case, which has no discriminating assertion at
all. Not in docs/refactoring-backlog.md or any refactoring-backlog-
archive-*.md (grepped for "missing cmake", "nocmake", "check_prereqs").

**Verifier's correction.**
Real, but it is a test-coverage defect only — trim the claimed real-world
consequence. Accurate statement: the case at test-iree-wheelhouse-
stages.sh:231-234 does not exercise _iree_check_prereqs at all. nocmake/
(:100) never shadows cmake and /usr/bin is left on PATH, so build-app-
wheelhouse.sh:781 succeeds; the asserted rc=1 is produced ~140 lines later by
_iree_build_host_stage:920 running the host's real /usr/bin/cmake against the
stub-cloned tree that has no CMakeLists.txt (the case inherits STUB_CROSS=1
from the preceding QNN case, so it takes the cross branch). Both prereq guards
are affected, not just cmake: /usr/bin/ninja exists too and nocmake/ contains
a ninja stub, so :782 is equally uncovered. The correct fix is to drop
/usr/bin:/bin from that PATH (or shim a failing cmake) and add a
discriminating assertion on the "cmake absent; skipping IREE" warn line, in
the same spirit as the _no_packaging_diag assertions added to the five build
cases. Two over-claims in the submission to correct: (1) the third prereq
guard IS genuinely covered — the "missing wheel platform tag" case at :236-240
sets STUB_WHEEL_PLATFORM="" and would go red if `[ -n "${wheel_platform}" ]`
were removed (the stub cmake then succeeds and the run returns 0), so only the
cmake/ninja `command -v` lines are untested; (2) the described consequence of
a removed guard is milder than stated — with cmake genuinely absent, execution
reaches `env -u … cmake …` at :920, whose ENOENT ("env: 'cmake': No such file
or directory") is NOT redirected to a log file and lands directly in the stage
output, followed by "IREE host stage failed in both COMPILER=OFF and
COMPILER=ON modes" and a fatal err in main(); the cost is a wasted rm -rf +
full recursive clone and a slightly indirect error, not a log "pointing
nowhere near the cause". Severity is low-to-medium: cmake is present in every
stage that runs build-app-wheelhouse.sh, so no shipped artifact is at risk
today; what is real is that the suite advertises a skip-path assertion it does
not make, and a refactor of _iree_check_prereqs would be mutation-invisible.

### XM. Two test-guard-helpers.sh cases end in `t_assert_ok true` after a subshell whose exit status is thrown away — they cannot fail, so source_vendor's nounset window and first_match's missing-dir contract are unprotected [medium]

`linux/scripts/tests/test-guard-helpers.sh:57`

**What breaks.**
Rewrite `source_vendor` (linux/scripts/01-core/guard-helpers.sh:45-55) to drop
its `set +u` window — i.e. regress it to the plain `. "${_f}"` the helper
exists to replace. The case at :55-57 runs `( set -u; source_vendor
"${_tmp}/vendor.sh"; [ "${VENDOR_SAW}" = "unset-ok" ] )` where vendor.sh
references `${SOME_DEFINITELY_UNSET_VAR}`; the subshell would die with
"unbound variable" and exit non-zero — but the file sets only `set -u` (line
4), not `set -e`, so a failing subshell does not abort the suite, and the next
statement is the literal `t_assert_ok true`, which runs `true` and always
passes. Identical shape at :31-33 for `first_match` on a missing directory:
make first_match drop its trailing `|| true` (guard-helpers.sh:24) and the `(
set -e; ... )` subshell aborts, unnoticed. Both cases are the pre-migration
contract freeze for the ~426 raw call sites the module is meant to absorb (its
own header, guard-helpers.sh:6-10), and it is already sourced live at
01-core/common.sh:36 and 03-media/core/common.sh:107 — so a silent regression
here is inherited by every site the migration touches.

**Evidence.**
test-harness.sh has no facility that captures a bare subshell's status;
`t_assert_ok true` (lines 33 and 57) evaluates `true` and can only pass. The
suite's shell options are `set -u` at line 4 — no errexit — so `( ... )`
exiting non-zero is discarded silently. `grep -rn "t_assert_ok true" tests/`
returns exactly these two standalone uses plus one at :47 that IS
discriminating (it sits in the `else` arm of an `if probe sh -c 'exit 3'`,
whose `then` arm asserts a failure). guard-helpers.sh currently has ZERO
production call sites (`grep -rn -e '\bfirst_match ' -e '\bsource_vendor ' -e
'\bcsv_each ' linux/scripts --include='*.sh'` outside tests/ matches only the
doc comments in the module itself), which is why the damage is latent rather
than live today. Not recorded: grep for "guard-helpers", "source_vendor",
"first_match", "t_assert_ok" across docs/refactoring-backlog.md and every
refactoring-backlog-archive-*.md returns only the 2026-08-10 archive's plan to
CREATE these helpers, nothing about the suite.

**Verifier's correction.**
Record it in this narrowed form only: ONE case, not two, is an unprotected
contract. test-guard-helpers.sh:31-33 is the sole coverage of first_match's
missing-directory contract, and its assertion cannot fail: the `( set -e;
r="$(first_match "${_tmp}/does-not-exist" -name '*')"; [ -z "$r" ] )`
subshell's exit status is discarded (the file sets only `set -u` at :4 — no
errexit, no ERR trap — and run-tests.sh:20 runs each suite as plain `bash`),
and the next statement is the literal `t_assert_ok true`, which per test-
harness.sh:67-70 executes `true`. Deleting the `|| true` from guard-
helpers.sh:24 leaves the suite fully green. The other three first_match cases
(:19, :24, :28) all target an existing directory where find returns 0, so none
of them substitute for it. Fix: capture the status, e.g. `( set -e; ... );
t_assert_eq "$?" "0"`, or assert via `t_assert_ok bash -c '...'`. The
source_vendor half of the claim is WRONG and must be dropped. :55-57 is indeed
tautological, but the nounset window is already covered by the next case at
:59-61: under `set -u` the unbound-variable error kills that command
substitution before its `case "$-"` runs, so a source_vendor regressed to a
plain `. "${_f}"` yields an empty `_restored` and fails t_assert_eq at :61
(simulated both ways: regressed => empty, correct => "yes"). :63-65 and :67-69
cover the no-force-`-u` and rc-propagation contracts. So :55-57 is redundant,
not a hole — worth deleting or converting for tidiness, but it is not a gate
failure. Severity is LATENT, not live. guard-helpers.sh is sourced at
01-core/common.sh:36 and 03-media/core/common.sh:107, but it has zero call
sites anywhere in linux/ (every match outside tests/ is a doc comment or
prose), exactly as guard-helpers.sh:6-10 says — the ~426-site migration is
rebuild-gated and has not happened. No current build can go wrong from this;
the cost is that the pre-migration contract freeze for first_match's `|| true`
is not actually frozen.

### XN. --no-push android artifact handoff: producer writes `android-artifacts-<arch>`, consumer reads `android-artifacts/<arch>` [high]

`linux/scripts/build-cross-chain.sh:162`

**What breaks.**
Run the officially-supported full no-push validation chain: `bash
linux/scripts/build-cross-chain.sh --no-push --target-arches
amd64,arm64,riscv64` (allowed since 2026-08-30 by _chain_no_push_guard, build-
cross-chain.sh:286). The android stage exports its OCI layout via
`cross_stage_context_dir android-artifacts "${arch}"` (cross-stage-
build.sh:502), and cross_stage_context_dir (cross-stage-build.sh:109-113)
composes `${CROSS_CONTEXT_WORKDIR}/${stage}${arch:+-${arch}}` ->
`<WD>/android-artifacts-arm64`. run_runtime_stage then exports
ARTIFACT_CONTEXT_ROOT=`<WD>/android-artifacts` (build-cross-chain.sh:162), and
runtime_artifact_context_dir (context-management.sh:209) composes
`${ARTIFACT_CONTEXT_ROOT%/}/${arch}` -> `<WD>/android-artifacts/arm64`. That
directory never exists. runtime_artifact_context_ref (context-
management.sh:219) fails its `index.json`/`oci-layout` check, prints '[ERROR]
Missing OCI artifact context for arm64' and returns 1 — but
runtime_build_package_image runs under run_parallel_arch_loop's disabled-
errexit extent, so the empty capture flows straight into
`build_args+=(--build-context "runtime_artifact=")` (runtime-build-fns.sh:289)
and every arch's package build dies on a malformed build-context, hours into
the run. Net effect: the no-push lane can never reach the runtime stage, and
when the guard-rail is bypassed the package would copy from the stale
published cross-android tag instead of the image just built — exactly the
2026-08-08 stale-parent bug backlog item C claimed to close.

**Evidence.**
Simulated both helpers verbatim: producer -> /WD/android-artifacts-arm64,
consumer -> /WD/android-artifacts/arm64. The mismatch was introduced in
8c97cdd8 ('backlog sweep 2026-08-30: close F1/F2/C'); its own comment at
build-cross-chain.sh:158 asserts the exporter wrote `<cross workdir>/android-
artifacts/<arch>`, which cross_stage_context_dir does not do.
CHANGELOG.md:1322, docs/linux-cross-builds.md:175 and docs/refactoring-
backlog-archive-2026-08-30.md:64 all document the slash form, so the repo's
claim and the code disagree. test-cross-oci-handoff.sh:180-183 greps only
cross-stage-build.sh for the raw read, so it cannot see the orchestrator side.

**Verifier's correction.**
The mechanism is confirmed, but three parts of the claim need correcting. 1.
WRONG COMMIT. The break was NOT introduced by 8c97cdd8. That commit
(2026-08-30) wrote the correct slash form as a literal: `local
artifact_dir="${CROSS_CONTEXT_WORKDIR}/android-artifacts/${arch}"`, matching
its own comment and all the docs. The regression is commit 3be6b427
(2026-09-01, "cross-chain: the --no-push OCI handoff never activated"), which
replaced that literal with `artifact_dir="$(cross_stage_context_dir android-
artifacts "${arch}")"` to fix an unrelated `set -u` hazard, not noticing that
`cross_stage_context_dir` joins the arch with a DASH
(`${stage}${arch:+-${arch}}`, cross-stage-build.sh:113) while the consumer
joins with a SLASH (`${ARTIFACT_CONTEXT_ROOT%/}/${arch}`, context-
management.sh:209). The consumer side was never touched by 3be6b427. So build-
cross-chain.sh:162 is not the defect — it is the half that still matches the
documentation; the defect is at linux/scripts/01-core/cross-stage-
build.sh:502. 2. THE TEST IS WORSE THAN "BLIND". test-cross-oci-
handoff.sh:180-183 does not merely fail to see the orchestrator side; it
asserts `grep -c 'CROSS_CONTEXT_WORKDIR}/android-artifacts' cross-stage-
build.sh` equals 0, i.e. it actively forbids the correct 8c97cdd8 form and
pins the broken helper call. Restoring the slash path by reverting to the
literal turns that assertion red. 3. NO STALE-TAG PATH ANY MORE. The claim's
second half ("when the guard-rail is bypassed the package would copy from the
stale published cross-android tag") does not occur on current HEAD.
`runtime_use_local_artifact_context` is true whenever `ARTIFACT_CONTEXT_ROOT`
is non-empty, and since 3be6b427 mints `CROSS_CONTEXT_WORKDIR` eagerly in
`main()` the orchestrator always sets it under `--no-push`. So the registry-
fallback branch (runtime-build-fns.sh:290-294) is never taken; the run always
takes the hard-failure branch instead. The failure is also loud, not silent:
`[ERROR] Missing OCI artifact context for <arch>: <dir>` is printed before the
malformed `--build-context` is assembled. The real cost is a full `--no-push`
validation chain (base..android, multiple hours across three arches) dying at
its final stage, plus the wrapper-smoke gate at runtime-build-fns.sh:367-374
failing the same way. Accurate statement: on HEAD the `--no-push`
android->runtime artifact handoff is path-mismatched — the exporter writes
`<cross workdir>/android-artifacts-<arch>` while the runtime helper looks in
`<cross workdir>/android-artifacts/<arch>` — so a full `bash
linux/scripts/build-cross-chain.sh --no-push --target-arches
amd64,arm64,riscv64` cannot complete its runtime stage. One-line fix either
way: make the exporter use the slash form (and drop/invert the test at test-
cross-oci-handoff.sh:180-183), or set
`ARTIFACT_CONTEXT_ROOT="${CROSS_CONTEXT_WORKDIR}/android-artifacts"` -> a
dash-joined root the consumer can compose. The exporter side is preferable,
since CHANGELOG.md:1322, docs/linux-cross-builds.md:175-176 and
docs/refactoring-backlog-archive-2026-08-30.md:64 all document the slash
layout.

### XO. parallel_loop_harvest keys on pin.* files only, so --no-push --parallel-archs loses every *_BUILT_THIS_RUN flag [medium]

`linux/scripts/01-core/cross-stage-build.sh:521`

**What breaks.**
Run `build-cross-chain.sh --no-push --parallel-archs` (full chain from base).
Each per-arch worker is a background subshell, so its array writes are lost to
the parent; that is why the workers persist state to PARALLEL_LOOP_FLAGDIR. On
the push path the worker writes BOTH `pin.<stage>.<arch>` and
`built.<stage>.<arch>` (cross-stage-build.sh:421-422). On the push_flag=0 path
it writes ONLY `built.<stage>.<arch>` (cross-stage-build.sh:484) — there is no
pin to capture. parallel_loop_harvest's loop iterates `"${flagdir}"/pin.*.*`
and reads the built flag only from inside that loop body (line 532-536), so
with zero pin files the glob matches nothing and ANDROID_BUILT_THIS_RUN stays
empty in the orchestrator. run_runtime_stage then calls
cross_stage_ensure_parent_available runtime, whose built-this-run short-
circuit (stage-defs.sh:402-409) misses, and it executes `nerdctl pull
--platform linux/amd64 ghcr.io/.../kataglyphis_beschleuniger:cross-
android-<arch>` for all three arches — re-downloading the last PUBLISHED
android images (tens of GB each over the ~4-5 MB/s uplink noted in the push-
compression comment) and re-pointing the local cross-android-<arch> tags at
stale content, on a run whose entire purpose was to validate locally built
bytes without touching the registry. The sequential path is unaffected because
cross_stage_run writes `_local_built_flag["${arch}"]=1` directly in the parent
(cross-stage-build.sh:478-482), so the guard the comment there names ('without
it the runtime handoff pulls the STALE published parent over the image this
run just built') is silently disarmed only under --parallel-archs.

**Evidence.**
cross-stage-build.sh:483-485 writes built.* with no pin.*; cross-stage-
build.sh:521 `for f in "${flagdir}"/pin.*.*` is the sole iteration; the built-
flag harvest at 532-536 is nested inside that loop. Same loss applies to
`build-sdk-artifacts.sh --parallel-archs` without --push, which passes push=0
(build-sdk-artifacts.sh:88). Archive item R2 ('BUILT_THIS_RUN in the local
build path') added the line-478 write but never extended the harvest.

**Verifier's correction.**
Accurate statement: under `--no-push --parallel-archs`, ANDROID_BUILT_THIS_RUN
is lost, so the runtime stage pulls the last PUBLISHED android images — but it
does not ship them in the default flow. parallel_loop_harvest
(linux/scripts/01-core/cross-stage-build.sh:519-539) iterates only
`"${flagdir}"/pin.*.*` (line 521) and reads the built flag from inside that
loop (533-537). The push path writes both flag files (421-422); the
push_flag=0 path returns at 486 before _cross_stage_run_capture_pin and writes
only `built.<stage>.<arch>` (484). With zero pin files the glob never matches,
so under --no-push + --parallel-archs no built flag is harvested and
ANDROID_BUILT_THIS_RUN stays empty in the parent. The sequential path is
unaffected (478-482 writes the parent array directly). Consequence, corrected:
1. cross_stage_ensure_parent_available (stage-defs.sh:390-419), called
unconditionally at build-cross-chain.sh:141, misses its skip at 403-406 and
runs `nerdctl pull --platform linux/amd64 ...:cross-android-<arch>` (line 418)
for all three arches — re-downloading the previously published android images
on a run that build-cross-chain.sh:262-263 documents as never consulting the
registry, and clobbering the locally built `cross-android-<arch>` tags with
stale published content. That is precisely the outcome the comment at 475-476
says line 478 exists to prevent. 2. The runtime lane itself is NOT poisoned in
the default configuration: CROSS_NO_PUSH=1 sets ARTIFACT_CONTEXT_ROOT/MODE=oci
(build-cross-chain.sh:161-165), runtime_use_local_artifact_context (context-
management.sh:199-201) is true, and runtime_build_package_image passes
`--build-context runtime_artifact=<oci layout>` (runtime-build-fns.sh:284-289)
pointing at the layout exported from this run's android image (cross-stage-
build.sh:496-503) before the pull. So the package/wrapper still get locally
built bytes; the cost is wasted bandwidth/disk plus corrupted local tags, not
a wrong artifact. 3. It becomes a wrong artifact only with
CROSS_LOCAL_CONTEXT_HANDOFF=0 + CROSS_NO_PUSH_FORCE=1: the workdir is never
created, build-cross-chain.sh:166-167 unsets ARTIFACT_CONTEXT_ROOT, and
runtime-build-fns.sh:292-294 falls back to the mutable android tag the pull
just re-pointed at the previous run's image. 4. A failing pull is swallowed:
run_runtime_stage runs under `||` (build-cross-chain.sh:355) with errexit
disabled, so a non-zero `run ... pull` neither aborts nor warns. 5. Drop the
sdk half of the claim: build-cross-chain.sh:141 is the only caller of
cross_stage_ensure_parent_available, so SDK_BUILT_THIS_RUN has no consumer and
its loss under `build-sdk-artifacts.sh --parallel-archs` is harmless. Fix
shape: iterate `built.*.*` as well (or instead), or have the no-push path
write a placeholder pin file the harvest can key on.

### XP. cross-build-verification.md still calls the TVM smoke "report only" — the chain arms EXP_TVM unconditionally, so a TVM-less image now blocks the manifest [high]

`docs/cross-build-verification.md:180`

**What breaks.**
A media build ships without TVM (the code itself anticipates this: smoke-
torch-venv.sh:298 prints "not importable (best-effort; media build shipped
without it)"). The wrapper smoke instead appends "tvm NOT IMPORTABLE but
EXP_TVM set" to fails, the per-arch wrapper smoke goes red in build-runtime-
manifest.sh, and :latest-cross is never published — at the very end of a
multi-hour chain. The operator opens the escape-hatch table, reads that TVM is
"report only — best-effort by design" and that EXP_TVM is an opt-in, and goes
hunting for whoever exported it. Nobody did: the smoke sets it from
versions.env on every run. Same trap in reverse for anyone who deliberately
drops TVM from a lane expecting a warning.

**Evidence.**
DOC docs/cross-build-verification.md:180 — "| TVM presence/version per arch |
`smoke-torch-venv.sh` (report only — TVM is best-effort by design) |
`EXP_TVM=<version>` turns the report into a hard pin assertion |". CODE
linux/scripts/06-packaging/smoke-torch-venv.sh:97 — inside
assert_pinned_versions, run on every image: `EXP_TVM="$(_stv_vpin
"${versions_env}" TVM_REF)" \`, with versions.env resolved at :76 from
/opt/scripts/core/versions.env (baked into the image) and TVM_REF=v0.26.0
always present (linux/scripts/01-core/versions.env:118). The same file's own
comment at :280 already says the opposite of the doc: "# TVM is now a HARD
assert (EXP_TVM set from versions.env TVM_REF)." The reassuring best-effort
branch at :297-298 only runs when EXP_TVM is empty, which the chain never
produces. Closed as LOG34 in docs/refactoring-backlog-
archive-2026-08-27.md:733 ("EXP_TVM is now …") without updating this table.

**Verifier's correction.**
CONFIRMED, with four refinements. WHAT IS EXACTLY RIGHT: docs/cross-build-
verification.md:180 sits in a table whose stated premise is "Each hard gate
has ONE explicit, documented escape hatch". For TVM it says the gate is
"report only — TVM is best-effort by design" and lists `EXP_TVM=<version>` in
the OPT-IN column. Since LOG34 (2026-08-30) the code sets EXP_TVM itself on
every run from versions.env TVM_REF (smoke-torch-venv.sh:97), so the row is
inverted twice over: the gate is armed by default, and the column that should
name an escape hatch names the knob that arms it. There is no documented way
to ship a TVM-less image. REFINEMENT 1 — the doc is not the only stale copy,
and the second one is worse. linux/Dockerfile.media:562-565 carries the same
claim ("BEST-EFFORT on EVERY arch ... it can never break the media build.
Visibility (NOT a gate — TVM stays best-effort)") directly above the RUN at
:568-574 whose else-branch ships a TVM-less media image as a non-fatal
WARNING. Producer promises non-fatal; consumer hard-fails hours later. Fixing
only the doc leaves the more misleading of the two in place. REFINEMENT 2 —
name the real gate, not the in-build one. The blocking call is smoke-runtime-
image.sh:358-369 (check_ml_version_pins, STV_ASSERT_ONLY=1) reached from
build-runtime-manifest.sh:310; `set -euo pipefail` at :2 kills the run before
create_manifest at :315. Dockerfile.package:395 runs the same script in-build
but SKIPs (no /opt/venv there), so the failure genuinely lands at the end of
the chain, exactly as claimed. REFINEMENT 3 — a third stale statement, and one
of the two must be wrong. Dockerfile.torch:58-60 states "TVM is missing from
all three shipped images because the media stage produces no tvm wheel (tvm-
python.sh's verdict)". If that were still true, the armed assert would fail
every 3-arch build. LOG34 (archive-2026-08-27:733, closed 2026-08-30) says the
opposite was proved on all three arches. That comment predates LOG34 (ORPHAN-
PINS, 2026-08-23) and should be re-measured or deleted alongside the doc row;
whoever fixes the table should check which is current before writing "TVM
ships on all three". REFINEMENT 4 — a disarm exists but it is not the one
documented, and it is far too broad to sell as an escape hatch. Setting
VERSIONS_ENV to a path that does not exist makes assert_pinned_versions fall
back to ${_SCRIPT_DIR}/../01-core/versions.env, which is
/opt/scripts/01-core/versions.env in the image and does not exist (the file is
at /opt/scripts/core/). The SKIP guard at :80-83 needs BOTH versions.env and
uv.lock missing, and uv.lock is present, so the run continues with EVERY EXP_*
pin empty — torch, torchvision, onnx, litert, genai, opencv-major all silently
unasserted. The honest fix is a TVM-specific opt-out (e.g. STV_TVM_OPTIONAL=1,
or reverting to setting EXP_TVM only when a caller exports it) plus rewriting
the table row to say the gate is armed by default; do not document the
VERSIONS_ENV path as the hatch.

### XQ. The only gate that exercises entrypoint.sh's env sourcing asserts two variables the image ENV already sets, so "gstreamer-env.sh sourcing regressed" is undetectable [medium]

`linux/scripts/06-packaging/smoke-runtime-image.sh:133`

**What breaks.**
State: the shipped image loses its entrypoint env layer -- e.g.
Dockerfile.torch:110's `COPY ... gstreamer-env.sh /usr/local/bin/gstreamer-
env.sh` is dropped/renamed, or gstreamer-env.sh exists but aborts partway
(entrypoint.sh:13-25 `_safe_source` does `source "$f"` and then `return 0`
UNCONDITIONALLY, and it is always invoked as `_safe_source ... || echo ...`, a
`||` list, so bash suspends errexit inside the function body -- a mid-file
failure neither kills PID 1 nor trips the `|| echo "Warning: ... not found or
not sourced"` arm). Every container then starts WITHOUT
`/opt/gstreamer/share/pkgconfig` and `/opt/gstreamer/lib/pkgconfig` on
PKG_CONFIG_PATH, without `/opt/gstreamer/lib/gstreamer-1.0` on GST_PLUGIN_PATH
and without `/opt/gstreamer/lib/girepository-1.0` on GI_TYPELIB_PATH --
exactly the non-multiarch spellings the ENV block does not carry. Wrong
outcome: check_default_entrypoint_boot still prints `PASS default
ENTRYPOINT+CMD boot: BOOT uid=1001 gst=set vulkan=set`, because the probe at
line 127 reads `${GST_PLUGIN_PATH:+set}` and `${VULKAN_SDK:+set}`, and BOTH
are baked unconditionally into the image config by Dockerfile.package:235 and
:221 -- they are non-empty in every container whether or not the entrypoint
ran at all. The `2>/dev/null` on line 129 additionally discards
entrypoint.sh's own warning line, so the last observable trace is thrown away
too. Only the rc==42 half of this probe is real; the env half cannot fail for
the reason its own fail message names.

**Evidence.**
smoke-runtime-image.sh:127 `'echo "BOOT uid=$(id -u)
gst=${GST_PLUGIN_PATH:+set} vulkan=${VULKAN_SDK:+set}"'`; :129 `|
"${NERDCTL_BIN}" run --rm -i ... "${image_tag}" 2>/dev/null)`; :133-134 `elif
! printf '%s' "${out}" | grep -q "gst=set"; then fail "...the entrypoint
exported no GStreamer env ... gstreamer-env.sh sourcing regressed"`. The two
variables come from Dockerfile.package:235 `GST_PLUGIN_PATH="${GSTREAMER_PREFI
X}/lib/multiarch/gstreamer-1.0:${LIBCAMERA_PREFIX}/lib/gstreamer-1.0"` and
:221 `VULKAN_SDK=/opt/vulkan/active`. entrypoint.sh:20-22 `source "$f"` / `[
"${_ss_had_u}" = "1" ] && set -u` / `return 0`; call sites entrypoint.sh:28
and :30. Confirmed live in out/build-logs/cross-chain-wave6b.log:3273193 and
runtime-retry2.log:2952029 -- all three arches print the identical constant
`gst=set vulkan=set`. A gate that would actually see the regression must read
something the ENV does not pre-set (e.g. `${GSTREAMER_PREFIX}/lib/pkgconfig`
inside PKG_CONFIG_PATH).

**Verifier's correction.**
Accurate statement, with two overstatements in the claim trimmed: CONFIRMED
CORE: `linux/scripts/06-packaging/smoke-runtime-image.sh:133-134` is the only
assertion in the tree that claims to detect a gstreamer-env.sh sourcing
regression, and it cannot fail for that reason. It tests
`${GST_PLUGIN_PATH:+set}` (composed at :127), but GST_PLUGIN_PATH is baked
unconditionally into the image config by `linux/Dockerfile.package:235` and
inherited by the wrapper through the config-preserving OCI-layout handoff
(`linux/scripts/01-core/context-management.sh:243`), so it is non-empty in
every container whether or not `/usr/local/bin/gstreamer-env.sh` was ever
COPY'd (Dockerfile.torch:110) or sourced. The `2>/dev/null` at :129
additionally throws away entrypoint.sh's own `Warning: … not found or not
sourced` line (entrypoint.sh:29), the last observable trace. A gate that could
actually discriminate must read something only gstreamer-env.sh adds — e.g.
`${GSTREAMER_PREFIX}/share/pkgconfig` inside PKG_CONFIG_PATH — or simply
assert the file exists and is non-empty. TRIM 1 — "asserts two variables":
only one is asserted. `vulkan=set` is printed but never grepped; the sole
predicate is `grep -q "gst=set"`. (Both are ENV-constant, so neither could
discriminate, but the assertion is single.) TRIM 2 — blast radius is smaller
than "every container then starts without …". The paths gstreamer-env.sh adds
are, in this image, near-duplicates of the ENV spellings:
`${GSTREAMER_PREFIX}/lib/multiarch` is a symlink to the real libdir
(`linux/scripts/03-media/build/gstreamer/common/build-gstreamer-stage.sh:51`,
`linux/scripts/03-media/runtime/configure-runtime.sh:76-80`, repaired again at
`linux/scripts/06-packaging/setup-package-image.sh:392-398`), so the ENV's
`lib/multiarch/{gstreamer-1.0,pkgconfig,girepository-1.0}` already resolve to
the same directories gstreamer-env.sh would prepend, and ENV
PATH/LD_LIBRARY_PATH already carry `${GSTREAMER_PREFIX}/bin` and both `lib`
and `lib/multiarch`. The only genuinely unique contribution is
`${GSTREAMER_PREFIX}/share/pkgconfig` on PKG_CONFIG_PATH. So a lost sourcing
layer would likely be latent rather than immediately breaking — which is
precisely why nothing else would catch it, and why the inert gate matters: the
regression would ship green and stay invisible until a consumer needed the
non-multiarch pkgconfig spelling. Bottom line: real, but it is a "gate cannot
fail" / dead-assertion defect (correctly-worded fail message attached to a
predicate that is a constant), not an imminent runtime breakage. The rc==42
half of the probe at :131 is genuine and does its job.

### XR. The curated dependency inventory is only checked in one direction, so a shipped component with no deps.json entry is invisible to every gate — IREE and PyAV ship in :latest-cross and appear in none of deps.json, the licence pages, or the curated SBOM [medium]

`docs/scripts/deps_table.py:34`

**What breaks.**
Add a source-built component to versions.env and build it into the image
without touching docs/deps/deps.json. `resolve_dep_version` raises only for
the reverse case (a deps.json entry naming a versions.env key that no longer
exists), and every consumer — sync_versions.py's deps-table check
(docs/scripts/sync_versions.py:417), generate_sbom.py --check, generate-
website-licenses.py — is generated FROM deps.json, so a missing entry produces
no diff and all four preflight docs gates (version-snapshot, doc-links, doc-
dupes, sbom) stay green forever. This already happened twice: IREE
(versions.env:152 `IREE_VERSION=v3.11.0`, integrated 2026-07-14, riscv64
runtime built from source, iree-base-runtime/-compiler shipped and asserted by
the runtime smoke) and PyAV (versions.env:213 `PYAV_VERSION=18.1.0`, built
from source in Dockerfile.media:793 `FROM ffmpeg AS pyav` and installed into
/opt/venv; measured as `av 18.1.0` in the shipped image, backlog §G). Both are
absent from docs/deps/deps.json, from the generated table in docs/third-party-
licenses.md, from linux/webserver/license-
assets/documents/footer/openSourceLicenses{En,De}.md (the page the webserver
actually serves) and from docs/deps/sbom-curated.spdx.json — so the published
inventory and SBOM describe an image that is not the one shipped. PyAV
additionally links the FFmpeg this repo configures with --enable-gpl --enable-
version3 (docs/third-party-licenses.md:147), i.e. the omission lands on the
copyleft side the curated half exists to cover.

**Evidence.**
deps_table.py:34-45 (the only completeness contract, one-directional, with a
comment naming just the renamed/removed-var case); generate_sbom.py:8-26
states the curated half's whole purpose is source-built components an image
scanner cannot see; AGENTS.md:1690-1693 claims "A new component needs an entry
in docs/deps/deps.json … or the build fails", which no code enforces.
Verified: `grep -i iree docs/deps/deps.json` → no match; `grep -ic iree
docs/deps/sbom-curated.spdx.json` → 0; the same for pyav; a dump of all 98
deps.json entries lists ArmNN, TVM, LiteRT-LM, VVdeC, GenAI etc. but neither
IREE nor PyAV.

**Verifier's correction.**
CONFIRMED, with two overstatements trimmed. Accurate statement: the deps.json
completeness contract runs in one direction only.
`docs/scripts/deps_table.py:34` raises for a deps.json entry whose `var`
vanished from versions.env; nothing checks the reverse, so a component that
ships without a deps.json entry is invisible to `sync_versions.py:417`,
`generate_sbom.py --check`, `generate-website-licenses.py` (including its
`check_obligations_are_discharged` at line 158, which also iterates deps.json
entries only) and all four preflight docs gates, which stay green forever.
`compare_sbom.py` is the only script that reads a real scan and it always
`return 0` (line 141), so it is a report, not a gate. `AGENTS.md:1688-1690`
claims a new component needs a deps.json entry "or the build fails"; no code
enforces that. Two live instances: IREE (versions.env:152, built per-arch and
asserted by `smoke-runtime-image.sh:388`) and PyAV (versions.env:213,
`Dockerfile.media:793`, wheels collected at Dockerfile.media:1105) — absent
from deps.json, from the generated table in docs/third-party-licenses.md, from
the served `linux/webserver/license-
assets/documents/footer/openSourceLicenses{En,De}.md`, and from
docs/deps/sbom-curated.spdx.json. Correction 1 — the SBOM half of the impact
is weaker than claimed. The curated SBOM's stated scope
(generate_sbom.py:8-14) is components an image scanner *cannot* see because
they carry no package metadata. IREE and PyAV both ship as wheels installed
into /opt/venv with dist-info, so the syft half (.github/workflows/sbom.yml,
which scans `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross`
directly from the registry) does catalogue them. For these two the gap is a
curation-policy inconsistency (deps.json already lists PyTorch, TVM, ONNX
Runtime, uv, Node — all metadata-bearing) rather than a total blind spot. The
genuinely uncovered surface is the human-facing licence inventory: docs/third-
party-licenses.md and the webserver-served pages, which have no scanner-fed
counterpart at all. Correction 2 — the copyleft framing does not apply to
these two instances. PyAV is BSD-3-Clause and IREE is Apache-2.0-with-LLVM-
exception; both are attribution-only. The GPL-configured FFmpeg that PyAV
links already has its own deps.json entry with a `source` block, so no source
offer is currently missing. The mechanism would equally hide a copyleft
component (the obligations check only walks deps.json), but the two known
instances are permissive, so the omission is an attribution gap, not a
discharged-obligation gap.

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
  **`lib/{code-quality,coverage,docs-build}.sh`** — **REVIEWED AND KEPT, entry
  was stale (found 2026-09-02).** This called them "the most tractable ones",
  but the allowlist already carries all five pairs, reviewed the same day *by
  measurement*: longest shared run **11–12 lines**, verdict "a helper would cost
  more indirection than it saves", budgets pinned so growth trips the gate.
  Worth knowing they are the one clone family in this list that sits **outside
  the build closure** (`linux/scripts/lib/` is in no Dockerfile; only
  `tests/test-lib-smoke.sh` uses it, and `01-core/vulkan-env.sh` merely names
  `lib/cmake-build.sh` in a comment) — so if the verdict is ever revisited, it
  can be done during a build. The reviews say "NOT read line-by-line; revisit if
  it grows", and the pinned budgets are what makes that safe.
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

  **One lead checked and REFUTED 2026-09-02.** `systemd-oomd` is running on this
  host, and a userspace OOM kill fits the symptom exactly — a cgroup killed
  under memory pressure leaves no kernel OOM line, so the process just vanishes
  without an exit code. But the journal carries **no kill event at all** in the
  last seven days, only service start/stop. So oomd did not do it. Recorded so
  the next person does not spend the same hour on it; the memory-pressure family
  of explanations is not eliminated, only oomd's own killer.


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
