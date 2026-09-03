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

**Five entries remain. Only one is a defect; the rest are tracks.**

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

1. **`git push`** — 28 commits sit on local `main`. Nothing leaves this
   environment without you.
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

### FL1. Flutter fix is COMMITTED and GATE-PROVEN but not yet SHIPPED — needs a runtime rebuild [high]

The COPY, the PATH, the git safe.directory fix, the completeness gate + manifest,
the runtime-smoke `check_flutter`, and the tests/mutation all landed in 189aeae4
and pass every static gate. But `:latest-cross` still lacks Flutter until the
runtime stage is rebuilt — the fix lives in `Dockerfile.package` /
`setup-package-image.sh`, which only build in the runtime/package stage, not the
media stage.

**Blocked on disk, not on code.** Free is ~38G; the chain's own disk preflight
wants ~60G for one arch, and the artifact-source (android) images are not local,
so shipping means a base→…→runtime run. The last media build (2026-09-03) already
flaked once under disk pressure on `glslangValidator --version` (a qemu exec that
fails when the host is starved — binfmt was healthy at rest; see
docs/failure-modes.md binfmt-boot-race). Free disk to ≥80G with
`linux/host-config/prune-safe.sh` before launching.

Ship it with: `bash linux/scripts/build-cross-chain.sh` (full 3-arch), or a
narrower runtime-only run once the android images exist. Then confirm with the
new `check_flutter` smoke on the shipped `:latest-cross-amd64`/`-arm64`.

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

**`reconcile_local_wheels` DONE 2026-09-03: 128 → 43**, four seams extracted
(`_wheel_families_present`, `_partition_wheels_by_install_group`,
`_install_wheel_groups`, `_backfill_torch_runtime_deps`). It is off this table
entirely — details in the 2026-09-03 archive.

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

- **The source-or-fallback family — DECIDED 2026-09-03: KEEP. Do not delete.**
  [M·★★★] Four sites carry a canonical helper plus an inline fallback:
  host-compiler resolution (`ffmpeg-probe-framework.sh`), `_path_contains` /
  `_path_prepend_unique` (`04-runtime/gstreamer-env.sh`, `libcamera-env.sh`), and
  host-python discovery (`onnxruntime/build/lib/common.sh`).

  **This entry previously recorded "ANSWERED 2026-09-02: no fallback is reachable"
  and proposed deleting all four. That answer was WRONG, and acting on it would
  have broken the build.** It reasoned from the whole-directory provisioning
  (`Dockerfile.package:276`, `Dockerfile.toolchain:301`, and the ~25 media RUNs
  that bind-mount `01-core` entire) and concluded `/opt/scripts/core/` always holds
  all 68 files. It never looked at the **per-file** provisioning, which is
  widespread:

  | context | 01-core files provided |
  |---|---|
  | `Dockerfile.android:79-88` | **3** — `compiler-resolution.sh`, `downloads.sh`, `platform.sh` |
  | `Dockerfile.media:448-454` | **7** — the cross-* set, `platform.sh`, `ubuntu-mirror.sh` |
  | `Dockerfile.media:177-180` | **4** |
  | `Dockerfile.sdk:60,111` | **2** |
  | `Dockerfile.base` (each RUN) | ~13 |
  | `Dockerfile.toolchain:91-109` etc. | ~19 |

  `path-helpers.sh` is in **none** of those lists. So the fallbacks are not
  insurance against a hypothetical future stage — several stages are already in
  exactly the state they exist for, today.

  **Reachability is per-RUN, not per-tree**, which is why a grep of either shape
  alone gives the wrong answer: the ffmpeg probe happens to run under a
  whole-directory mount (`Dockerfile.media:752`), so *that* fallback is indeed
  dead, while the android lane's 3-file COPY makes others live. Anyone reopening
  this must check the specific RUN that sources the specific file — and say which
  RUN in the entry.

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

### F9. Gates that do not run when invoked by hand — BOTH RETESTED 2026-09-03, NEITHER REPRODUCES [S·★★]

Both were filed 2026-09-01 (rescued from the F7/ArmNN cut on 2026-09-02, which
they had nothing to do with). Both were **retested on 2026-09-03 and did not
reproduce.** They are kept, not deleted: each failure was really observed, so
what changed is the diagnosis — from "broken" to "intermittent, cause unknown".

- **The runtime smoke standalone hang** — 2026-09-01 it stopped after
  "Functional: ML version-pin assertion" with `nerdctl` logging "force cleanup
  timed out for container".
  **2026-09-03 retest**, same command, same published image
  (`smoke-runtime-image.sh …:latest-cross-arm64 arm64`): it ran straight past
  that point — app-wheel smoke, ONNX InferenceSession, ffmpeg, the /opt `.so`
  closure, GStreamer core + mandatory plugins, application import, HEALTHCHECK —
  to completion: **31 PASS, `=== Results: 0 failure(s) ===`**. The "force cleanup timed out" warnings still appear on
  nearly every container teardown, so that message is NOT the hang; it is normal
  noise on this host and should not be trusted as the symptom next time.

- **`preflight.sh` dies at the gitleaks secret scan** — 2026-09-01, twice in a
  row: the process disappeared mid-scan and never wrote its exit code.
  **2026-09-03 retest** (`PREFLIGHT_ONLY=secret-scan`): gitleaks **8.30.1**
  scanned ~2.42 GB in **2m49s**, "no leaks found", `secret scan: clean`, and the
  suite reported `All preflight checks passed` with **rc=0**.

**What to do with this entry:** do not "fix" either one — there is nothing
failing to fix today. Re-open with fresh evidence if it recurs, and when it does,
capture the host state (free memory, running containers, disk) at the moment of
death, because that is what neither 2026-09-01 observation recorded and what
would separate an OOM kill from a real defect.

A second observation also fell out of the retest: the arm64 app-wheel count
printed **15** again. That is a second *run*, not a second *build* — same image,
same wheels — so the floor stays at 14. See
`docs/gen1-riscv64-genai.md#the-app-wheel-floor`.
