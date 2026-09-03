# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md),
[`…-archive-2026-09-02.md`](refactoring-backlog-archive-2026-09-02.md),
[`…-archive-2026-09-03.md`](refactoring-backlog-archive-2026-09-03.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**LB**=llm-stack benchmark harness ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: **2026-09-03**, third pass. Everything closed that day is in the
2026-09-03 archive: A1, A2, YA, YC, the WA–WJ and XK–XR rounds, F1's
`_cross_stage_build_impl` and `reconcile_local_wheels` rows, and F3's
chain-status walker.

**Eight entries remain: FL1 (relaunch pending), HT1, SMK-ADV and TC1 are open
work; YB is a defect under investigation; F1/F2/F3 are tracks.**

* **YB** — sccache cache loss. Mitigated, and the mitigation was **measured and
  found weak** (~5% recovery). Root cause open.
* **F1 / F2** — oversized functions and files, both now frozen by the `code-size`
  gate instead of hand-measured. Two unreviewed F1 candidates left.
* **F3** — down to items that are reviewed-and-KEPT on purpose. Its
  source-or-fallback question was DECIDED (keep) on evidence.
* **F9** — kept as a record only: both failures were retested 2026-09-03 and
  neither reproduces.

### What needs the OWNER, not the agent

Nothing in the five entries above is blocked on you. These are:

1. **`git push`** — origin/main is at `a8ab5e01` (pushed 2026-09-03). Local
   `main` carries the rust-toolchain fix `09b1e6e2` and this grooming commit; the
   Q1–Q6 gate wave will add more.
2. ~~The submodule pin.~~ **RESOLVED 2026-09-03 — it was a false alarm, and not
   yours.** Preflight warned that `external/Kataglyphis-DocumANTation` pin
   `287365636` was "not reachable on its remote (unpushed local commit or upstream
   rewrite)". It was neither: the commit **is an ancestor** of the remote's
   current `main` (`8bf3ccfa`), and the local `origin/main` ref was simply stale.
   A plain `git fetch` in the submodule cleared it. Worth improving the gate's
   message — "stale remote-tracking ref" is the third and likeliest cause, and it
   is the one the wording does not name.
3. **The Windows lane.** Six confirmed doc defects from the 2026-09-03 currency
   audit are parked in
   [`windows-refactor-backlog.md`](windows-refactor-backlog.md), verified against
   the tree only — no Windows host was involved. Two are wrong paths a reader
   would follow into a "file not found".
4. **A newer QNN SDK, if you want one.** v2.49.0.260730 is pinned, hashed and now
   validated end to end. Only a *newer* SDK needs a re-pin, and only you can fetch
   it (login-gated).

### FL1. Flutter — bootstrap design landed; SHIP BUILD PENDING RELAUNCH 2026-09-03 [high]

`189aeae4` put `/opt/flutter` back into the runtime image (COPY + manifest +
completeness gate + `check_flutter`). The `flutter-arm64-probe` then showed why
that alone would still have shipped a broken arm64 Flutter: the sdk stage runs on
the amd64 host for every arch, so whatever `flutter` caches there is the host's
Dart SDK, stamped current and never replaced on arm64. The design that fixes it is
in the tree (uncommitted until this note lands with it):

* sdk stage ships the checkout **bare** (`setup-flutter.sh` removes `bin/cache`;
  `Dockerfile.sdk`'s cache-restore branch too);
* the package stage runs `bootstrap_flutter_sdk` on the target arch (QEMU on arm64,
  measured 2m48s), asserts the cached dart ELF is the target machine, and hands
  `bin/cache` to the runtime uid; `Dockerfile.package` COPYs the tree with
  `--chown=${RUNTIME_UID}` because `flutter` writes into its own cache — as root's
  tree the runtime user died with `engine.stamp.tmp.NNNN: Permission denied`;
* `check_flutter` runs `flutter --version` **offline as the image user** and reads
  the dart ELF machine, since an x86-64 dart executes fine on this host.

Everything is in [`artifact-copy-completeness.md`](artifact-copy-completeness.md#bootstrapping-flutter-in-the-package-stage);
guarded by `test-setup-package-image.sh`, `test-runtime-image-gates.sh` and the
`flutter.*` mutations.

**Run 1 (`20260903-161323`):** amd64 died in the torch stage (`reconcile_local_wheels`,
hotfix `6ccb2f68`), arm64 in the package stage on the builder-arch rust toolchain
(`09b1e6e2`, HT1). riscv64 ran on after both fixes and **proved the rust reinstall
live**: `Rust toolchain in /usr/local/rustup is not riscv64gc-unknown-linux-gnu:
1.98.0-x86_64-unknown-linux-gnu … -- reinstalling natively` → `rustup-init: OK`.
Its package image predates the Flutter bootstrap edits (riscv64 ships Flutter
absent anyway).

**Next:** when run 1 ends, pin `useradd -m -u 1001` in `Dockerfile.torch` (the
COPY chown assumes it; today it is only the first free uid) and relaunch
`--only runtime` for all three arches. Expected on arm64: package stage
`OK: Flutter bootstrapped for arm64, bin/cache owned by uid 1001`, smoke
`PASS flutter 3.47.1 runs offline as the image user on a AArch64 Dart SDK`. Then
`flutter --version` + `rustc --version` on the shipped images, and close.

### YB. sccache loses thousands of cache entries per chain to an intermittent spawn ENOENT — MITIGATED 2026-09-03, root cause still open [medium]

**Read `01-core/sccache-launcher.sh`'s header first — it is the canonical record**
and it already contains more than a fresh investigation recovers. In particular it
states, from the 2026-09-01 run (3062 bypasses):

* the class is **intermittent, ~10–40% of compiles, in the heavily parallel steps
  only**;
* the compiler path is absolute and **the cwd is a live build dir**;
* **the direct fallback of that same argv succeeds immediately after**;
* and, explicitly: *"do NOT re-derive one \[a root cause\] from this message alone."*

**A correction to this entry's own earlier text.** On 2026-09-03 it concluded that
`current_dir()` was "the last standing candidate". That is **wrong** — the header
above had already ruled the cwd out. The re-derivation did add value (six
hypotheses disproved by experiment, listed below) but it also reproduced work that
was already written down, which is exactly what the header warns against.

**Disproved by experiment 2026-09-03, so nobody repeats them:** the failing
`argv[0]` is never bare or relative; all six failing compiler paths exist and are
executable in the image; a plain sccache cross-compile returns rc=0; a
375-variable / 65 KB environment does not trigger it (and would be `E2BIG`). Two
lookalikes were reproduced and carry DIFFERENT messages: a missing `-MF` directory
is a compiler error *after* a successful spawn, and a deleted cwd gives
`Couldn't determine current working directory`.

**MITIGATION SHIPPED 2026-09-03: the launcher retries once** before giving up the
cache entry. Behaviour, bounds and log lines are owned by
[`build-cache-tiers.md`](build-cache-tiers.md#the-single-retry-2026-09-03) — do
not restate them here. Guarded by `tests/test-sccache-launcher.sh` (14 assertions)
and mutation `sccache.retry-once`.

**MEASURED on the 2026-09-03 media-arm64 build, and the result is NEGATIVE:**

| outcome | count |
|---|---|
| `retry succeeded (cache kept)` | **27** |
| `failed twice` | **514** |

**~5% recovery.** So the honest answer to "is this class transient?" is **mostly
no** — a retry issued immediately does not get a different result. Keep the retry
(it is nearly free and 27 entries is 27 entries) but do **not** treat it as the
fix, and do not size the remaining work as if it were.

Two things this rules out and one it suggests: a scheduling race or a momentary
resource shortage would recover far more than 5%, so neither is the mechanism.
Something about the specific invocation is failing repeatably within a short
window. That points at per-request state inside the server rather than at the
environment.

Reading the log needs one caution learned here: a **cached** BuildKit step replays
its old output verbatim. The first read of this build showed 496 hits of the
pre-retry message, all from one cached step (`#30`), which would have looked like
the new launcher failing to take effect.

### HT1. Host trees copied from `artifact-source` — the builder's arch ships in foreign images [high]

`Dockerfile.package`'s `artifact-source` is the **amd64 host** cross image. Every
`COPY --from=artifact-source` of a tree that was *installed on the host* (not
cross-built for the target) puts x86_64 binaries into the arm64/riscv64 runtime
image. Two members so far:

* `/usr/local/{rustup,cargo}` — **FIXED 2026-09-03** (`09b1e6e2`): replaced by a
  native install in the package stage; `check_rust_toolchain` proves the triple on
  the shipped image. Accepted skew: cargo-c comes from apt there (0.10.16 vs the
  0.10.25 pin) because `cargo install cargo-c` under QEMU is a ~1 h build. Revisit
  only if a consumer needs a cargo-c feature newer than 0.10.16.
* `/opt/flutter` on arm64 — **FIXED in tree 2026-09-03** (see FL1): the sdk stage
  ships the bare checkout and `bootstrap_flutter_sdk` fetches the target-arch Dart
  SDK in the package stage; `check_flutter` reads the dart ELF machine on the
  shipped image. Awaiting the relaunch for live proof.

**Audit the rest:** walk `runtime-artifacts.manifest` and classify each path as
cross-built-for-target or host-installed; `file -b` one binary per tree inside the
shipped arm64 image. A one-line gate is possible — `find <tree> -type f -executable
| head` + `readelf -h` machine check against `dpkg --print-architecture` — and would
belong in `smoke-runtime-image.sh` next to `check_native_so_closure`.

### SMK-ADV. `_advert_verdicts` SKIPs an advertised key it cannot read [medium]

The ADV/HAVE table (`smoke-runtime-image.sh`) prints `SKIP … could not read the
actual value` when the probe for an advertised key fails. That is exactly the
shape of the rust defect: `rustc --version` failed on arm64 for months and the
gate said SKIP, not BAD. Tighten to **BAD by default** with a per-`<arch>:<key>`
exemption table for keys that legitimately cannot be read on an arch (riscv64 has
several). Needs the per-arch SKIP list from a completed run of the current tree
first — the arm64/riscv64 smokes of the relaunch will print it. Ship as: table +
`tests/test-runtime-image-gates.sh` cases + a mutation that blanks the exemption
check.

### TC1. Static gate for the trailing-conditional return [S, ★★]

Two silent build deaths in two days had the same shape: a function whose **last
statement** is `cond && action`, returning 1 when `cond` is false, killing the
caller under `set -e` with no message (`reconcile_local_wheels` 2026-09-03; the
2026-09-02 `logging.sh` ERR-trap case was the mirror image). shellcheck has no
check for it. A small `verify_trailing_conditional.py` over `linux/scripts/**/*.sh`
— last non-comment statement of a function body matches `&&` without a trailing
`|| true`/`|| return 0`, or is a bare `[ … ]` — with the usual four-way allowlist.
Build **after** the Q1–Q6 gate wave lands (it edits the same `preflight.sh` /
`mutations.json` / `code-quality-tooling.md` seams). Characterisation suites for
F1 extractions should also run the function under `set -eu` and assert 0 on every
early-return path — the `reconcile_local_wheels` suite did not until the hotfix.

### F1. Functions that outgrew a screen [M each] — RE-MEASURED 2026-09-03

Sizes come from `function-size.allow`, which the `code-size` gate freezes, so this
table cannot silently go stale between rounds the way it kept doing.

        lines  function                       file
          356  assert_pinned_versions()      06-packaging/smoke-torch-venv.sh
          114  _opencv_target_adjustments()  03-media/build/opencv/build-opencv.sh
          109  uv_sync_project()             01-core/python_uv.sh
           91  _cross_stage_build_impl()     01-core/cross-stage-build.sh
           84  append_tvm_cmake_args()       05-frameworks/tvm-config.sh

**`assert_pinned_versions` is top by size and the WORST candidate by value.** It
is not 356 lines of shell — it is ~26 lines of shell wrapping a 312-line embedded
Python program (`"${PY}" - <<'PYEOF'`, `smoke-torch-venv.sh:101`). Splitting the
shell moves ~26 lines. What actually mattered there was that ruff could not see
the Python at all — fixed 2026-09-02, and those 399 newly-visible lines pass the
hard gate clean. Split the wrapper for its own sake, never for the line count.

**Next candidate: `_opencv_target_adjustments` (114) or `uv_sync_project` (109).**
Both unreviewed. Measure the value before cutting.

**The one uncovered path left inside `_cross_stage_build_impl` is the
registry-cache drop** (~16 lines). It needs a non-empty `log_file` holding a
`DeadlineExceeded` line and it mutates both `build_cmd` and a counter across loop
iterations, so it wants its own characterisation before extraction — the same
order that caught the salvage body running empty last time.

`_opencv_target_adjustments`, `uv_sync_project` and `append_tvm_cmake_args` are
unreviewed. Measure the value before cutting: the lesson from
`assert_pinned_versions` is that line count alone picks the wrong target.

### F2. Files over ~800 lines [L each, low priority]

**RE-MEASURED 2026-09-03 from `file-size.allow`, which is now the authority** —
the `code-size` gate freezes every one of these and refuses silent growth, so
this table cannot drift between rounds the way it kept doing. Splitting any of
them is still open work, and still low priority.

         1502  linux/scripts/06-packaging/smoke-runtime-image.sh
         1243  linux/scripts/05-frameworks/torch/build-app-wheelhouse.sh
         1162  linux/Dockerfile.media
         1121  docs/scripts/bump_versions.py
          975  linux/scripts/03-media/build/litert/build-litert.sh
          934  linux/scripts/03-media/build/opencv/build-opencv.sh
          881  linux/scripts/build-cross-chain.sh
          880  linux/scripts/02-toolchain/build-gcc.sh
          874  linux/scripts/lib/agentic-loop.sh
          849  docs/scripts/sync_versions.py

Ten files, not the seven this entry used to claim: the 2026-09-03 gate widened
its scope to **Python and Dockerfiles**, which pulled in `bump_versions.py`,
`sync_versions.py` and `Dockerfile.media` — none of which any size gate had ever
looked at.

`smoke-runtime-image.sh` is the one to watch: it is the largest file in the tree
and it GREW today (probe split into four parts, `_boot_verdict` extracted). The
growth is recorded with a reason in the allow file, which is the contract — the
gate does not care that a file is big, only that it grows without saying why.

### F3. Clone families worth one owner [S-M each]

Two genuinely-open observations remain. The decided/reviewed items (the
source-or-fallback KEEP decision, the lint-tool and lib/* pairs reviewed-and-kept
by measurement, and the not-actionable Dockerfile mount preambles) are in the
2026-09-03 archive.

- **`lib/*.sh` share a 14-line logging-fallback preamble across 9 files**
  (56 shingles) — the single largest copied block in the tree,
  `if ! declare -F info; then source …; else info() { … }; fi`. **Bootstrap
  paradox before touching it:** the block exists for the case where nothing has
  been sourced yet, so extracting it into a file you must source defeats its
  purpose. A shared file plus a 2-line guard may still beat 14 lines × 9. Outside
  the build closure (`lib/` is in no Dockerfile), so it can be done any time.
- **`install-deps.sh` family (6 files)** — cross-apt, gstreamer, litert, opencv,
  pre-setup, assemble-torch-app share the target-package install shape.
  Unreviewed; measure the longest shared run before deciding, as the lib/* pairs
  showed 11–12 lines is below the extract-a-helper threshold.

