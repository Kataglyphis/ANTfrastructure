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
**LB**=llm-stack benchmark harness · **QW**=quality-gate wave follow-ups ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: **2026-09-04**, after the Q9 gate-hole wave was integrated (the
env-knobs heredoc-before-quote tokenizer and its env-prefix chains, the pre-commit
hook driven end to end, the git-hook half of the embedded-Python target set, the
mutation gate's two symlink properties, doc numbers derived instead of retyped,
and the id-convention rule widened to judge the ID rather than the target). Q9
closed QW9's "the id-convention check is silent over NON-gate files" row.
Everything closed 2026-09-03 is in the 2026-09-03 archive: A1, A2, YA, YC, the
WA–WJ and XK–XR rounds, F1's `_cross_stage_build_impl` and `reconcile_local_wheels`
rows, and F3's chain-status walker.

**Nineteen entries remain: FL1 (relaunch pending), DISK1, HT1, SMK-ADV, TC1 and
the ten QW rows are open work; YB is a defect under investigation; F1/F2/F3 are
tracks.**

* **QW1–QW10** — what the 2026-09-03 gate wave left behind and what the
  2026-09-04 Q7, Q8 and Q9 waves deliberately did NOT fix: two
  frozen-but-unreviewed baselines, five deletions waiting on the running build,
  the shared allow reader, the ownership shapes the gate registry cannot express,
  four unpinned hook abort paths, and the limits the gates disclose rather than
  close.
* **DISK1** — the chain's in-stage disk reclaim ignores the buildkit store. Cost
  a full runtime run on 2026-09-03; blocked on the running build.

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

### DISK1. The chain's in-stage disk reclaim never looks at the buildkit store [M, ★★★]

**Not a gate item — this comes from tonight's build.** The in-stage disk reclaim
only trims `~/.cache/kata-buildcache` and then reports `NOTHING was reclaimable`,
while `~/.local/share/buildkit` holds hundreds of GB of `type==regular` layer
cache it never inspects. On 2026-09-03 that cost a full runtime run: the riscv64
torch stage hit ENOSPC at **4G free** while **415G** sat in the buildkit store.
`PRUNE_KEEP_GB=120 linux/host-config/prune-safe.sh` then freed **223G in 36s**
with all **97** cache-mount records surviving.

The disk guard should fall back to that filtered `buildctl prune` before declaring
defeat — and **never** to `nerdctl builder prune -f`, which eats the cachemounts
(1.5–2 h of cold LLVM to rebuild; see the rebuild-disk-management memory).

Repro: watch a stage hit ENOSPC and read the guard's own log line — it says
nothing was reclaimable while `buildctl --addr … du` reports hundreds of GB of
regular records. BLOCKED: the guard lives in a build-closure file, so the fix
waits for the running cross build to end.

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
**Unblocked 2026-09-03:** the Q1–Q6 gate wave has landed, so the `preflight.sh` /
`mutations.json` / `code-quality-tooling.md` seams it shares are free; ship it as
the eight-part set every gate there ships as, and register the slug last so
`gate-registry` sees it. Characterisation suites for
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

### QW1. The 95 frozen `shellcheck-warnings` rows are frozen, not REVIEWED [M, ★★]

`shellcheck-warnings.allow` holds 95 `(file, SCxxxx)` rows covering 177
warning-level findings in 74 files, every one reading `baseline 2026-09-03, not
yet reviewed`. The gate guarantees the number matches reality; it says nothing
about whether the warning is right. SC2034 is 85 of the 177 and is where real
bugs hide — a genuinely unused variable is usually a typo'd reference elsewhere —
but most of these are sourced-library variables a consumer reads, so expect
scoped `# shellcheck disable=SC2034` with a reason rather than deletions. SC2154
(16, all but four in `01-core/cross-env.sh`) is the next cluster. Review per
file and put the verdict in the row's reason column.

### QW2. The 70 frozen `code-complexity` rows, same [M, ★★]

67 `cc` rows and 3 `nesting` rows in `code-complexity.allow`, all unreviewed.
That file plus `verify_code_complexity.py` are now the authority for every
complexity number here — the hand-measured figures that circulated before the
gate existed were over-counts, one of them by 7×: `assert_pinned_versions` is
**cc 7**, not 52 (its 312 lines are embedded Python the shell walker never
reads), and `_chain_stage_disk_guard` is 28, not 29. The real top of the queue is
`scan_file` and `main` at 42, then `media_common_init` 35,
`_opencv_target_adjustments` 33, `cross_stage_run` 23. Never re-measure by hand:
run the gate, and note that the numbers of a handful of functions are wrong for
the reason in QW4.

### QW3. Delete five dead functions once the 2026-09-03 build ends [S, ★★]

Four sit in `dead-functions.allow` under a **DEAD** heading only because their
files are inside the running build closure: `cpython_ext_dev_packages_optional`,
`cpython_ext_modules_optional` and `cpython_ext_modules_required`
(`01-core/cpython-dev-packages.sh`), and `verify_shared_lib_optional`
(`03-media/runtime/verify-media-artifacts.sh`). The fifth, `cleanup()` at
`03-media/build/ffmpeg/build-ffmpeg.sh:716`, is invisible to the gate (same-name
masking: many live `cleanup()` definitions elsewhere) and must NOT be frozen — a
row for it would fail as STALE the moment it was written. Delete all five in one
commit and drop the four allow rows with them.

### QW4. `code-size` measures shell function extents with a raw brace count [S, ★★]

The brace-counting defect is written up under
[Known limits](code-quality-tooling.md#shell-complexity-code-complexity); the
work item is the fix, not the description. `code-complexity` and
`dead-functions` inherit those extents, so all three gates measure the wrong text
for the handful of functions it hits (`generate_pkgconfig_file` reads 5 lines).
Fix in `verify_code_size.py` by blanking comments and quotes with
`verify_code_complexity.strip_line` before counting, then re-freeze the three
allow files in the same commit — expect movement in every one of them.

### QW5. A shared `(count, reason)` allow reader belongs in `quality_allow.py` [S, ★★]

`load_counts` takes the count as the *second field from the right*, so a
hand-written row whose reason contains `|` raises `ValueError` before the gate
can report anything, and an inline `#` is stripped before the split. Confirmed
again 2026-09-04, pasteable from the repo root:

```
printf 'linux/scripts/x.sh | 3 | baseline 2026-09-03 | not yet reviewed\n' > /tmp/qw5.allow
python3 -c "import sys; sys.path.insert(0,'linux/scripts'); import quality_allow; quality_allow.load_counts('/tmp/qw5.allow')"
# ValueError: invalid literal for int() with base 10: 'baseline 2026-09-03'
```

The crash is a traceback, not a gate verdict, so the reader never learns which
row is malformed — and every reason column in the tree is one `|` away from it.
`verify_shellcheck_warnings.rows` and `verify_code_dupes.load_allow` are already
parallel parsers that carry reasons, and the ratchet works around the crash by
not calling `load_counts` at all. One `load_rows(path) -> {key: (count, reason)}`
in `quality_allow.py`, shared by `check_counts` and every `--write-baseline`,
deletes both copies.

### QW6. `test-vulkan-target-decomposition.sh` hardcodes `/tmp` [S, ★]

Its normalising `sed` (line 68) matches `/tmp/[A-Za-z0-9._]+/` literally, so under
a `TMPDIR` override the fixture paths never collapse to `TMP/` and every
comparison in the suite fails. Derive the pattern from the harness's temp dir.

### QW7. Gate limits disclosed but not closed [S each, ★]

Each is written up in the gate's own section of
[`code-quality-tooling.md`](code-quality-tooling.md); none has an owner.

* **`dead-functions` same-name masking** — one name table for the whole corpus,
  so a dead `log()` is kept alive by a live `log()` anywhere. Every short helper
  name is unguarded. **`--census` is inert on this tree** (re-measured 2026-09-04:
  `428 definition(s) their own file never names again; 0 of those in a file that
  sources nothing and that nothing else names`), so the mitigation reports
  nothing and the masking is entirely unwatched — the known-dead
  `03-media/build/ffmpeg/build-ffmpeg.sh:716 cleanup()` of QW3 is invisible to
  both the gate and the census. Closing it properly needs `source_module`-aware
  scoping, i.e. a real call graph; a cheaper interim is a census tier keyed on
  `(file, name)` rather than on the file's reachability.
* **`gate-registry` mention-based TEST proof** — narrowed 2026-09-04, not closed.
  The mutation half is no longer circular (an entry is credited only to the gate
  its `<slug>.` id prefix names, and only over that gate's own or imported files,
  with off-convention ids failing loudly), but the *test* half is still a
  mention: a suite that names a gate's script and asserts nothing about it still
  reads `proven`. 15 of 33 slugs remain frozen as unproven. The cheap sweep
  nobody has run: for every slug whose `mutations` column in
  [`code-quality-gates.md`](code-quality-gates.md) is `—`, write the
  `return rc` → `return 0` mutation and see whether its suite survives — that
  experiment is exactly what exposed `python-lint`, `comment-size` and
  `masked-decls` as hollow.
* **`code-dupes --baseline --kind X`** rewrites the whole allow file from that
  kind's pairs only, dropping every other kind's row. `--kind` scopes the stale
  check correctly; `_write_baseline` ignores it. Cheapest fix: refuse `--baseline`
  when `--kind` is given.

### QW8. What the 2026-09-04 Q7 honesty wave left open [S each, ★–★★]

Five follow-ups the wave surfaced and deliberately did not take (two of the
original seven were closed by the 2026-09-04 Q8 integration). None blocks the
batch; all were verified on the live tree the day they were written.

* **Sixty `env-knobs` allow rows want a real default, not a registry row.**
  The 2026-09-04 owners-side comment filter re-homed 15 live `${NAME:-default}`
  operator switches that nothing in the repo assigns, and the Q8 owner tokenizer
  re-homed 45 more whose only "owner" was quoted text — 36 of those are real
  operator escape hatches named in exactly one place each, an error message
  (`FORCE_LOW_DISK`, `DISK_PREFLIGHT`, `GCC_REQUIRE_GPG`, `RUNTIME_*`,
  `OPENCV_ALLOW_NO_PNG`, `WHEEL_SOABI_STRICT`, the `ALLOW_*`/`KEEP_*` family).
  A `: "${NAME:=0}"` at the reader would shrink the registry AND make the
  default greppable where it is read. Three are reachable today —
  `PREFLIGHT_ONLY` and `PREFLIGHT_SKIP` (`preflight.sh`) and `SKIP_REAL_TREE`
  (`tests/test-shellcheck-warnings.sh`) — and would be better as a
  `: "${NAME:=…}"` at their reader. The other twelve live under
  `01-core`/`02-toolchain`/`03-media`/`05-frameworks`/`06-packaging`, frozen for
  the running cross build. Next no-build window.
* **`crlf-guard` flags `w/-text` wholesale with no escape hatch.** A tracked
  `*.sh` that was legitimately binary or held a NUL byte would fail the gate and
  there is no allowlist. Census today is 303/303 `i/lf w/lf`, and a binary `*.sh`
  has no honest use here, so this is a shape to remember, not a fix to make.
* **The three `:NN-MM` offsets `cross-build-verification.md` quotes into the
  pre-commit hook are prose, not gated.** The offsets into `preflight.sh` (the
  `KNOWN_SLUGS` span) now ARE gated, by `tests/test-preflight-slugs.sh` plus
  three mutations — that is the drift that actually recurred. Extending
  `tests/test-lint-shell-scope.sh` to re-derive the hook's spans the same way is
  the cheap symmetric fix.
* **The pre-commit hook itself is outside the `shellcheck-warnings` ratchet.**
  `verify_shellcheck_warnings.py --files linux/host-config/git-hooks/pre-commit`
  answers `outside the lint-shell.sh scope, skipped`. The hook is linted at
  `-S error` when passed explicitly, so warning-level regressions in the one file
  every commit runs are watched by nothing. Q8 located the asymmetry exactly:
  `lint-shell.sh` admits extension-less shebang scripts only for EXPLICITLY passed
  paths, so `git ls-files -z | xargs -0r lint-shell.sh --list-files` answers 315
  files (hook included — that is how `crlf-guard` now reaches it) while the
  argument-less default sweep is 309 `*.sh` and the ratchet asks that one.
* **`tests/test-code-complexity.sh` still measures twice per legacy case.** The
  18 cases added 2026-09-04 use `_pins`, one gate run for both numbers; the 15
  older hand-built cases still call `_measure` twice. Converting them halves the
  suite's remaining runtime but touches assertions existing mutations depend on.

* **`env-knobs` trailing-comment strip is not quote-aware** — a knob read to the
  right of a ` #` inside a quoted string would be missed. As of 2026-09-04 the
  same filter runs on the OWNERS side too, so an *assignment* hiding to the right
  of a quoted ` #` would lose its owner as well. Zero such lines in the tree
  today (measured), and the failure mode is a loud false-stale or a loud UNOWNED,
  not a silent pass.

### QW9. What the 2026-09-04 Q8 gate-scope wave left open [S–M each, ★–★★]

Eleven follow-ups, all verified on the live tree at integration time. Nothing here
blocks the batch; every one is a gate that is honest about a limit rather than a
gate that lies.

* **The registry cannot express "a call site in the orchestrator".** [M, ★★]
  FOUR frozen ids now sit on this shape, not two — Q9's widened id rule made the
  two over the pre-commit hook visible as well. The names and the reasoning are
  owned by [`code-quality-tooling.md`](code-quality-tooling.md#the-allowlist);
  what is open is the RULE. Repro: delete a `mutation-id:` line and
  `verify_gate_registry.py` prints `mutations does not own
  linux/scripts/preflight.sh -- owned by crlf-guard`. Fix: credit an entry to the
  slug whose registered suite is its `test` command when the target is a shared
  orchestrator or a hook.

* **`own_files()` does not follow a `.sh` gate's shelled-out helper.** [S, ★★]
  It is `[rel] + imported_modules(rel)`, and `imported_modules` returns `[]` for a
  shell gate, so `linux/scripts/extract_embedded_python.py` belongs to no row:
  `python-lint.heredoc-python-decision` is a proven mutation credited to nobody.
  Q9's widened id rule at least made it LOUD — it is now reported off-convention
  and frozen under `mutation-id:` rather than passing unexamined. Repro: grep the
  `python-lint` row of [`code-quality-gates.md`](code-quality-gates.md) — the
  entry is absent, and the freeze line is in `gate-proofs.allow`. Fix: let
  `own_files` follow a `.sh` gate's `python3 <x>.py` / `bash <x>.sh` invocations;
  that deletes the freeze and gives `python-lint` a sixth credited mutation.
  Deliberately NOT done in Q9: it re-credits files other lanes were editing
  mid-wave and could turn unrelated freezes STALE in the same run.

* **The mutation gate re-runs a whole suite per entry.** [M, ★★★]
  Re-measured 2026-09-04 after the Q9 wave, on this wave's own 17-file diff
  (233 entries in the manifest): the hook is **7.2 s** capped at 6 and
  **2 m 45.9 s uncapped** for its 65 matched entries; the full manifest is
  **8 m 18.6 s**. A one-file commit of a GATE script is not cheaper — staging only
  `verify_gate_registry.py` matches 21 entries and the six newest are all
  `test-gate-registry.sh` runs, so that hook takes **19.1 s**, more than the
  17-file commit whose six newest are cheap `test-doc-numbers.sh` runs. The
  sampling is newest-first, not cost-aware. The cost is one suite process
  per entry; one baseline and one process reused per suite would let
  `PRECOMMIT_MUTATION_CAP` rise a lot for free. Repro:
  `PRECOMMIT_MUTATION_CAP=0 bash linux/host-config/git-hooks/pre-commit` with the
  current diff staged.

* **Nothing runs the other ~227 entries between commit and CI.** [M, ★★]
  A pre-push hook is the right home — `--changed`'s existing semantics (everything
  committed since `origin/main`) are exactly right there, and a batch pays once
  instead of per commit. Blocked on `verify_gate_registry.py`'s `HOOK` constant
  being hard-coded to the pre-commit path: add a pre-push hook today and the
  generated table reports the `mutations` slug as CI-only, which is a false
  statement in a generated file.

* **The shell tokenizer now exists twice, in two languages.** [M, ★★]
  `verify_code_complexity.py` (`shell_code` + `_Walker`) and the awk filter inside
  `lint-env-knobs.sh` both strip comments, quotes and heredoc bodies and both
  answer "is this token in command position". Not code duplication —
  `verify_code_dupes.py` is clean — but duplication of idea across a language
  boundary, kept because the env-knobs gate is a 0.4 s bash gate with no Python
  process to spare. If a third consumer appears, extract one owner and call it.

* **Two owner shapes the env-knobs scan deliberately will not count.** [S, ★]
  `-e "NAME=$(...)"` container-env injection (`RT_PROBE_SH`, `SMOKE_ONNX_PY`) and
  `NAME=value` words passed as arguments to a test helper that later
  `export "$@"`s them (`BUILD_RC`, `DISK_OK`, `HAS_PINNED_BASE`, `TRANSIENT`).
  Both carry the name inside a quoted word, so teaching the scan about them means
  un-masking string content — the exact hole the wave closed. They are honest
  allow rows; the alternative is a real assignment at the reader.

* **A heredoc ruff finding is named `probe__2.py:1:`.** [S, ★★]
  Opener line in the shell file, then line WITHIN the extracted body: reading a
  real finding needs the two numbers added by hand. `extract_embedded_python.py`
  already prints the exact `<tmpfile>\t<src>:<line>` table; `lint-python.sh`
  discards it. Surfacing it on a gate failure is the fix, and it needs its own
  suite case plus a mutation because it changes the gate's output.

* **`extract_embedded_python.py | main | cc 16` is frozen "not yet reviewed".**
  [S, ★] Baseline 2026-09-03. The file became load-bearing for the `python-lint`
  target set on 2026-09-04, so it is the next candidate for the complexity queue
  rather than a permanent freeze.

* **`*.sh.tpl` is in no shell gate's scope, and a CRLF template generates a CRLF
  wrapper.** [S, ★] `lint-shell.sh` classifies `qemu-binary-wrapper.sh.tpl` as
  "some other extension", so neither `shellcheck` nor `crlf-guard` sees it.
  Admitting it would also send an `@PLACEHOLDER@` template to shellcheck (it
  happens to parse today) — a call for the `lint-shell` owner, not something
  `crlf-guard` should answer differently.

* **`versions.env` cannot be sourced quietly.** [S, ★]
  Every `lint-python.sh` run prints `versions.env: line 398: 86: command not
  found` (three times) because `CUDA_ARCHITECTURES=80;86;89;90` is unquoted and
  sourcing it runs `86`, `89`, `90` as commands. Cosmetic, but it is stderr noise
  on a gate that runs in every hook. Quoting the value is the one-line fix, and it
  is frozen for the duration of the running cross build (`01-core`).

### QW10. What the 2026-09-04 Q9 gate-hole wave left open [S–M each, ★–★★]

Six follow-ups. The wave itself closed the id-convention hole over non-gate files,
the env-knobs heredoc/env-prefix tokenizer holes, the unpinned SAMPLED notice, the
git-hook half of the embedded-Python target set, the mutation gate's symlink write
path, and the hand-typed doc numbers.

* **Four `|| exit 1` blocks in the pre-commit hook are still not driven end to
  end.** [S, ★★] Q9 built the rig — a stub `git` plus a stub gate whose rc the
  case chooses — and used it to pin only the mutation step. The hook's
  `shellcheck -S error`, the warning ratchet, the fast-preflight block and
  `verify_doc_dupes.py` each abort through the same shape, and each exit could be
  flipped to `0` with every suite, the registry and preflight staying green — the
  exact class Q9 just closed one instance of. Repro: change the mutation step's
  `exit 1` to `exit 0` on the pre-2026-09-04 suite and nothing goes red. Fix:
  four more cases in `tests/test-precommit-hook.sh` (stub the tool in the sandbox,
  run it with rc 1) plus a mutation each.

* **`mirror_tree` still copies escaping symlinks INTO the workspace.** [S, ★★]
  Refusing a symlink TARGET closes the write path, but a test running inside the
  copy can still read or write through `docs/.venv/bin/python` →
  `/usr/bin/python3`. Skipping links whose resolved target falls outside `src`
  would close that too; nothing depends on `docs/.venv` (grep for it outside the
  venv returns nothing), but it changes mirror semantics, so it wants its own case
  rather than a drive-by. Repro: `ls -l` the `docs/.venv/bin` of any run's
  throwaway copy.

* **`$(( x << SHIFT ))` still reads as a heredoc delimiter.** [S, ★]
  Known limit of the env-knobs owner tokenizer, unchanged from the pre-2026-09-04
  regex: an unquoted delimiter only has to start `[A-Za-z_]`, which is what keeps
  `<<<` and `$(( a << 2 ))` out but cannot tell a NAMED shift apart. Nothing in
  the tree hits it — the only `<< name` shifts live inside `test-code-complexity.sh`'s
  own `<<'EOF'` fixtures, and an END-rule probe over all 310 scripts finds no
  unterminated heredoc at EOF. Distinguishing it needs arithmetic-context
  tracking; left at parity rather than grown for a case with no instance.

* **Eleven `env-knobs` allow rows are REDUNDANT, not stale.** [S, ★]
  `APP_UV_LOCK`, `ARTIFACT_CONTEXT_MODE`, `ARTIFACT_CONTEXT_ROOT`,
  `BUILDKIT_CACHE_DIR`, `CROSS_CONTEXT_ROOT`, `CROSS_DISK_GUARD_GB`,
  `CROSS_LOCAL_CONTEXT_HANDOFF`, `CROSS_NO_PUSH_FORCE`, `NO_COLOR`,
  `SHELLCHECK_CACHE_DIR`, `UBUNTU_SOURCES_ROOT` are each consumed AND owned by a
  script assignment, so the gate calls them redundant and stays green. All eleven
  were redundant before Q9 too, so this is a curation call, not fallout — and for
  most of them the "owner" is a test fixture setting the knob for one case, which
  is exactly why the documenting row is worth keeping. Decide, then delete or
  annotate; do not leave it implicit.

* **The per-suite ASSERTION counts in `code-quality-tooling.md` are not pinned.**
  [S, ★] `test-doc-numbers.sh` derives the manifest counts and the hook's
  fast-slug list, but a count like "90 assertions in `test-env-knobs.sh`" is only
  checkable by running that suite. All were verified by hand on 2026-09-04 and one
  was wrong (62 → 63). They will drift again. The two honest options are the same
  two: drop them, or let `run-tests.sh`'s aggregate speak — which is already the
  stated policy for the tree-wide totals in `cross-build-verification.md`.

* **Five mutation ids stay frozen because two ownership rules are missing.** [S, ★]
  Renaming them is available and was deliberately NOT done: `mutations.hook-*` →
  `pre-commit.*` (that family already holds four ids over the same file) and
  `python-lint.heredoc-python-decision` → an `embedded-python` family would each
  drop a freeze, but a rename without deleting its `mutation-id:` line reports
  STALE and a deletion without the rename reports a prefix that cannot own the
  target — so the two halves must land together. The `mutations.preflight-*` pair
  has no good family at all and waits on the call-site ownership rule above.

**Two shapes to remember, not fix.** `test-mutation-gate.sh` pins two call-site
strings it does not own (`run_check mutations` in `preflight.sh`, and the hook's
`verify_mutations.py "${_only[@]}" ||` line) — reformatting either call site turns
the suite red with no behaviour change; that already happened once during this
wave and is the price of pinning a call site by reading it. And
`windows/scripts/patches/ffmpeg/makedef` entered the `crlf-guard` scope as a side
effect of the shared classifier: it is LF today, and a future CR there is a
Windows-backlog item, not a Linux-lane regression.
