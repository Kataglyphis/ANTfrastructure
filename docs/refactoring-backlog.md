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

Last groomed: **2026-09-03**. 1656 lines of closed work moved to the
2026-09-03 archive: **A1** and **A2** (both validated by real builds that day),
the whole **WA–WJ** and **XK–XR** rounds, and **F1**'s closed rows.

What is left is six entries, and they are honestly of two kinds:

* **Three defects found on 2026-09-03 and deliberately NOT fixed on the spot** —
  **YA** (the unhashed 1.5 GB QAIRT download is still live in the android lane),
  **YB** (sccache loses thousands of compiles per chain to a spawn ENOENT; root
  cause NOT determined, and two plausible theories are recorded as *disproved* so
  nobody re-derives them), **YC** (a dead `.githooks/pre-commit` that live docs
  pointed at). YA and YC were found mid-build, inside the 03-media closure, which
  is precisely when that closure must not be edited.
* **Three long-running quality tracks** — **F1** (oversized functions),
  **F2** (oversized files, now frozen by the `code-size` gate rather than
  re-measured by hand), **F3** (clone families), plus **F9**'s two
  invoke-by-hand gate failures.

### YB. sccache fails to spawn its preprocessor on thousands of compiles per chain (`os error 2`) — a silent partial cache miss across most of the media stage [medium]

**Observed 2026-09-03**, and **pre-existing**: 3373 occurrences in the
2026-09-03 chain log, 190 within the first four minutes of the A2 media-arm64
run. Not a regression from the QNN staging.

```
sccache-launcher:   sccache: error: failed to spawn Command { std: cd "<builddir>" && env -i … "/opt/gcc-16.2.0/bin/aarch64-linux-gnu-g++" "-x" "c++" "-E" "-P" … }
sccache-launcher:   sccache: caused by: No such file or directory (os error 2)
```

That is sccache spawning the **preprocessor** to compute a cache key. When it
fails, the launcher falls through to a real compile, so the build stays correct
and green — it just silently loses the cache for that unit. Nothing gates on it.

**Spread** — this is not one component (counts from the 2026-09-03 chain, by
build dir):

| count | tree |
|---|---|
| 1536 | `/tmp/opencv-1` |
| 342 | `/opt/onnxruntime/.../_deps` |
| 274 | `/tmp/litert-1/.../abseil-cpp-build` |
| 233 + 153 | `/opt/onnxruntime/.../dnnl` |
| — | also `/opt/onnxruntime-genai`, `/tmp/ffmpeg-1`, `/tmp/pyav-1`, armnn |

**What is NOT the cause — two hypotheses formed and then disproved, recorded so
nobody re-derives them:**

1. **`env -i` strips `LD_LIBRARY_PATH`, so the `/opt`-installed cross GCC cannot
   start.** Disproved directly: `env -i /opt/gcc-16.2.0/bin/aarch64-linux-gnu-g++
   --version` inside the shipped image prints `(GCC) 16.2.0` and exits 0.
2. **The sccache server daemon lives in a different mount namespace, so the
   `cd` target does not exist for it.** Disproved by the counter-evidence below:
   a namespace mismatch would fail *every* compile, and it plainly does not.

**The counter-evidence that makes this a PARTIAL failure, not a broken cache:**
the same chain reports real hits — `Cache hits 2732`, `2636`, `2159`, `1059`,
`345`, … So sccache works, and only a subset of invocations ENOENT. Any theory
has to explain why these coexist *within the same component* (onnxruntime shows
both).

**Root cause: NOT DETERMINED.** Next steps, cheapest first: log the exact failing
`argv[0]` and cwd for one failure and check both for existence *at that moment*
(a `_deps` build dir being cleaned mid-build is the leading remaining guess);
then compare a failing and a succeeding invocation of the same compiler in the
same RUN. `SCCACHE_SERVER_UDS=/tmp/sccache-$(id -u).sock` (`01-core/compiler-cache.sh:73`)
puts the socket on the per-RUN `/tmp` tmpfs, which is worth re-checking as part
of that.

**Why it matters:** this repo's build time is dominated by compiler caching
(CCACHE_COMPILERCHECK=content took LLVM from 11 h to 50 min). A silent
thousands-of-units cache miss on every media stage is the same class of loss,
and nothing reports it — the only symptom is stderr noise that looks benign.

### YC. `.githooks/pre-commit` is a dead gate that four live docs still named as the current one [medium]

**Found 2026-09-03 by the docs-currency audit.** `git config core.hooksPath` is
`linux/host-config/git-hooks`, set by `make hooks` (`Makefile:60`). Nothing
executes `.githooks/pre-commit`: a tree-wide grep finds only prose mentions plus
one special case in `lint-shell.sh:123,136` that exists purely so the
extension-less file still gets shellchecked. CI does not run it either —
`ubuntu24.04.yml:48` runs `bash linux/scripts/preflight.sh` directly.

It is also **stale**: last touched 2026-08-25 (`928e7451`), while the live hook
was updated 2026-09-03 (`c0dc4de2`). The two run genuinely different gate sets,
so following the dead one gives a weaker check than the repo actually enforces.

The documentation references are fixed (`AGENTS.md`, `cross-build-verification.md`
×2, `project-info.md`, `shared/config/README.md`, and the comments in
`ubuntu24.04.yml` / `build-docs.yml`). **What is NOT done: the file itself.**

**Decide and act:** either delete `.githooks/pre-commit` — and then remove the
`lint-shell.sh` special case that only exists for it — or, if it is kept
deliberately as a lighter opt-in gate, say so in a header comment inside the
file, because nothing currently records why a second, unreachable pre-commit
script lives in the tree.

**Left alone on purpose:** the `.githooks` mentions in `docs/*archive-2026-*.md`
are historical records of when that path *was* current, and
`docs/windows-host-setup.md:277,291` is a Windows-lane file.

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

**DONE 2026-09-03. `_cross_stage_build_impl` is 170 → 91 lines**, four seams
extracted: `_cross_build_pull_flag` (10), `_cross_build_append_push_output` (25),
`_cross_build_append_cache_args` (29) and `_cross_build_salvage_exports` (36).

Order was the whole method. The function drives every stage of every build and
had **zero** coverage, so the net came first and grew in two rounds: 16
assertions pinning the assembled argv (dry-run path), then 8 more reaching past
the dry-run return — retry counts and the salvage pass, the latter needing a real
Dockerfile with named stages and a fake `nerdctl` that records its `--target`s.
Only then was each seam cut, and all 24 stayed green.

**Two traps worth recording.** `cross-stage-build.sh` defines
`_cross_stage_push_error_is_transient`, `_cross_salvage_disk_ok` and
`cross_stage_log_redirect` itself, so a stub set BEFORE the source is silently
replaced — the first retry harness read "4 attempts for a non-transient error",
which looked like a real defect and was my own inert knob. Those three are
re-stubbed after the source now. And the salvage body was never reached by the
first net (`Dockerfile.x` has no named stages, so the loop ran empty), which is
why it got its own characterisation before being extracted rather than after.

**What is left is the registry-cache drop** (~16 lines), the one path still
uncovered: it needs a non-empty `log_file` holding a `DeadlineExceeded` line, and
it mutates both `build_cmd` and a counter across loop iterations. Characterise
first, as above.

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
