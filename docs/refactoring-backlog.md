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

Last groomed: **2026-09-03** (twice — see the archive). 1656 lines of closed work
moved out first: **A1**, **A2**, the **WA–WJ** and **XK–XR** rounds, **F1**'s
closed rows. Then **YA** and **YC** were opened, fixed and archived the same day.

**Four entries remain, and they are honestly of three kinds:**

* **One real defect, still unsolved** — **YB**. sccache silently loses thousands
  of compiles per chain. Six hypotheses are now recorded as *disproved by
  experiment* so nobody re-derives them; what is left needs a real build with
  `SCCACHE_LOG=debug`, which is why it is not closed.
* **Two long-running quality tracks** — **F1** (oversized functions) and **F2**
  (oversized files). Both are now *frozen by the `code-size` gate* rather than
  re-measured by hand, which is what kept letting their tables go stale. **F3**
  is down to items that are either reviewed-and-KEPT on purpose or need a
  validating build to delete safely.
* **One entry kept only as a record** — **F9**. Both its failures were retested
  on 2026-09-03 and neither reproduces. It stays because the 2026-09-01
  observations were real, so the honest status is "intermittent, cause unknown",
  not "fixed".

Nothing here is blocked on a decision from the owner.

### YB. sccache fails to spawn its preprocessor on thousands of compiles per chain (`os error 2`) — narrowed 2026-09-03, root cause still OPEN [medium]

**Pre-existing**, 3373 occurrences in the 2026-09-03 chain. The launcher falls
through to a real compile, so builds stay green and nothing gates on it — the
cache is just silently lost for those units. This repo's build time is dominated
by compiler caching (CCACHE_COMPILERCHECK=content took LLVM from 11 h to 50 min),
so a thousands-of-units miss is the same class of loss.

```
sccache: error: failed to spawn Command { std: cd "<builddir>" && env -i … "<compiler>" "-x" "c++" "-E" "-P" … }
sccache: caused by: No such file or directory (os error 2)
```

**What it is, precisely** (2026-09-03): sccache's own preprocessor pass, run to
compute the cache key. One decomposed failure: cwd
`/opt/onnxruntime/build_native_cpu/Release/_deps/abseil_cpp-build/absl/debugging`,
**289** environment variables, 39 argv elements, carrying CMake's `-MD -MF` with
a **relative** dep-file path.

**Spread** — not one component: 1536 `/tmp/opencv-1`, 342 + 233 + 153
onnxruntime/`_deps`/dnnl, 274 litert/abseil, plus genai, ffmpeg, pyav, armnn. By
program: 2987 `riscv64-linux-gnu-g++`, 1915 plain `g++`, 685/506/388/194 the rest.

**SIX hypotheses formed and DISPROVED. Do not re-derive them:**

1. `env -i` strips `LD_LIBRARY_PATH`, so the `/opt` GCC cannot start —
   `env -i /opt/gcc-16.2.0/bin/aarch64-linux-gnu-g++ --version` prints `(GCC) 16.2.0`.
2. The server is in another mount namespace — a namespace mismatch would fail
   *every* compile; the same chain reports `Cache hits` 2732/2636/2159/1059.
3. The program is a bare/relative name that `env -i` cannot resolve — **every**
   failing argv[0] parsed out of the log is an absolute path.
4. The compiler binary is missing — all six failing paths exist and are
   executable in `cross-media-arm64` (`g++`, `gcc`, both cross triplets, `/usr/bin/g++`).
5. A plain sccache cross-compile reproduces it — it does not: `sccache
   /opt/gcc-16.2.0/bin/aarch64-linux-gnu-g++ -c …` returns rc=0, one cache miss.
6. The 289-variable environment overflows `execve` — reproduced with **375**
   variables / 65 KB and rc=0. (It would also be `E2BIG`, not `ENOENT`.)

**Two adjacent errors were reproduced and are NOT this one** — useful, because
their messages look similar in a log skim:
* `-MF` into a missing directory → `<built-in>: fatal error: opening dependency
  file …` (a *compiler* error, after a successful spawn).
* cwd deleted under the client → `sccache: Couldn't determine current working
  directory` (a *different* sccache message).

So it really is `Command::spawn` returning ENOENT with an existing program — which
leaves the **`current_dir()` the server is handed** as the last standing
candidate, since that is the only other thing `spawn` resolves.

**Next step, and it needs a real build:** run one media stage with
`SCCACHE_LOG=debug` / `SCCACHE_ERROR_LOG` and capture, for a single failure, the
cwd the *server* was given and whether it exists **at that instant** — a
`_deps/<x>-build` subdir being created or moved by CMake while a sibling compile
is in flight would explain both the ENOENT and why it never reproduces standalone.

### F1. Functions that outgrew a screen [M each] — RE-MEASURED 2026-09-03

Sizes come from `function-size.allow`, which the `code-size` gate freezes, so this
table cannot silently go stale between rounds the way it kept doing.

        lines  function                       file
          356  assert_pinned_versions()      06-packaging/smoke-torch-venv.sh
          128  reconcile_local_wheels()      03-media/runtime/assemble-torch-app.sh
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

**Next candidate: `reconcile_local_wheels` (128).** 57 comment blocks already name
its seams. The method that worked on `_cross_stage_build_impl` applies unchanged:
characterisation net FIRST, then cut one seam at a time, re-running the net after
each. It is in the 03-media closure, so it needs a window with no build running —
which is now the normal state, not the exception it was on 2026-09-02.

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
