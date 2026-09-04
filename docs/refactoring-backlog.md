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
Prefix glossary (only the prefixes this OPEN file still uses): **YB**=sccache
cache loss · **DISK**=chain disk reclaim · **HT**=host trees in foreign images ·
**GH**=gate holes and gate scope · **CL**=build-closure follow-ups the wave could
not prove statically · **F#**=size/duplication tracks. **QW/TC/SMK** are retired:
the 2026-09-04 integration wave closed them and what survived is re-filed under
**GH** and **CL**. Everything else
(**AP/TG/TS/GPU/DUP/PAR/SCC/BT/LOG/LB/C#/D#/P#/S#/XC#**) is archive-only.

Last groomed: **2026-09-04, after the eight-lane quality wave integrated.** Every
number below was re-derived from the gates on the integrated tree, not carried
forward. The wave landed 67 new mutation entries (manifest 244 → **309**, all
biting), a new `trailing-conditional` preflight slug (**34** slugs, 21 proven, 13
frozen unproven), and full `preflight.sh` green in **7m24s**. The build closure is
OPEN and stayed open: the wave edited `01-core`, `02-toolchain`, `03-media`,
`05-frameworks` and `06-packaging`, **and none of those edits has been through a
build** — that is what **CL** is for.

**Closed by that wave and living in git history rather than here:** QW3 (five dead
functions + their four allow rows + one orphaned private), QW4 (`code-size` shell
extents — the tokenizer now has one owner in `verify_code_size.py`), QW6 (the
`/tmp` hardcode), TC1 (the `trailing-conditional` gate, plus the four live defects
it found), SMK-ADV (both SKIP arms and an unhandled-verb arm now fatal), HT1's
audit (`check_manifest_tree_arch`), DISK1's in-stage half, QW7's `--baseline
--kind` footgun / census masked tier / submodule-pin wording, all fifteen of QW8's
env-knob defaults and the `MYPROJECT_` rename, QW8's hook-span assertions and the
hook joining the `shellcheck-warnings` ratchet, QW9's call-site and shell-out
ownership rules, the heredoc ruff finding names, the `versions.env` quoting and
the mutation gate's sharding, and all six QW10 items.

**Nineteen entries remain** (`grep -c '^### '` counts twenty-one; "Next up" and
"What needs the OWNER" are not entries). GH1–GH6 are gate holes the wave disclosed
rather than closed; CL1–CL5 are closure edits only a real build can confirm, plus
the judgement calls the lanes refused to guess at; DISK2 and HT2 are the halves of
DISK1 and HT1 that stayed open; YB is a defect under investigation; F1–F5 are
tracks.

* **CL1–CL5** — nothing in the closure was validated by a build. Read this
  section before the next 3-arch run and watch the named log lines.
* **GH1–GH6** — the pre-push gap, the second allow-reader, the `trailing-conditional`
  false negatives, the env-knobs owner-scan blind spot, the frozen-slug sweep and
  two dead-function gate holes.
* **YB** — sccache cache loss. Mitigated, and the mitigation was **measured and
  found weak** (~5% recovery). Root cause open.
* **F1–F5** — 29 of 36 frozen function-size rows, 69 of 72 complexity rows and
  95 of 95 shellcheck rows are frozen, not reviewed. Bookkeeping, not defects.

### Next up — the six highest value-per-effort items, in order

1. **CL1 — watch the next 3-arch build** [S, ★★★]. Not a code change: seventeen
   closure files were edited this wave with static proof only, eight of them
   changing SHAPE. The log lines to watch are named in CL1. Everything else on
   this list is cheaper *after* it.
2. **DISK2 — wire the buildkit fallback into the two `build-cross-chain.sh` call
   sites** [S, ★★★]. The in-stage watchdog (where 2026-09-03 actually bit) is
   done; a run that dies at *lane entry* still refuses instead of reclaiming.
3. **GH1 — the pre-push hook** [M, ★★]. Sharding made this affordable: the full
   309-entry gate is **1m59s** at the default `--jobs 8`. Blocked only on
   `verify_gate_registry.HOOK` being a single path.
4. **GH2 — finish the shared allow reader** [S, ★★]. Half landed;
   `verify_code_dupes.load_allow` still carries its own parse because it needs raw
   line numbers `load_rows` does not surface.
5. **CL3 — `export_clang_gcc_toolchain_env` has no production caller** [S, ★★].
   A documented operator switch on a code path nothing enters. Decide whether
   clang is ever the compiler there before writing any gate for it.
6. **GH5 — the thirteen frozen unproven slugs** [M, ★★]. `stdout-returns` shipped
   as the worked example this wave; the nine remaining tree-consistency checkers
   are the cheapest next batch.

**Honesty about the rest:** F1–F5 remain the biggest *time* items here and none
of them is a defect. The real defects with a known failure mode are DISK2, GH2,
GH3 and CL3.

### What needs the OWNER, not the agent

Nothing in the nineteen entries above is blocked on you. These are:

1. **`git push`** — `git rev-list --count origin/main..HEAD` says **2** commits
   ahead of `origin/main` as this file was groomed, before the wave's own commit.
   Re-derive it with that command rather than retyping a ref; it was wrong at
   three consecutive groomings before the command was written down.
2. **The Windows lane.** Six confirmed doc defects from the 2026-09-03 currency
   audit are parked in
   [`windows-refactor-backlog.md`](windows-refactor-backlog.md), verified against
   the tree only — no Windows host was involved. **Three** of the six are wrong
   paths a reader would follow into a "file not found"
   (`verify-host-setup.ps1`, `healthcheck.ps1`, `Dockerfile.toolchain`); the
   fourth is the QNN version contradiction at `README.md:204`. **New on
   2026-09-04:** `windows/scripts/tests/Pins.CanonicalValues.Tests.ps1` reads
   `CUDA_ARCHITECTURES` from `versions.env` via `Get-Pin` and asserts it equals
   `80;86;89;90`. That value is now QUOTED in `versions.env` (it had to be — an
   unquoted `;` ran its own tail as commands on every plain `source`).
   `load_versions_env`, `sync_versions.py` and `bump_versions.py` all strip one
   surrounding pair and were proven byte-identical; whether `Get-Pin` does was
   not testable from this host. One PowerShell run answers it.
3. **A newer QNN SDK, if you want one.** v2.49.0.260730 is pinned, hashed and
   validated end to end. Only a *newer* SDK needs a re-pin, and only you can fetch
   it (login-gated).

### CL1. Seventeen closure files changed with static proof only [S to watch, ★★★]

**Nothing the 2026-09-04 wave changed under `01-core`, `02-toolchain`, `03-media`,
`05-frameworks` or `06-packaging` has been through a build.** Every edit carries a
suite case and a mutation, and every mutation bites — but a suite cannot execute a
Dockerfile stage. Seventeen files under those five directories are modified;
`git status --porcelain | grep -E '01-core|02-toolchain|03-media|05-frameworks|06-packaging'`
is the authority, not this list. Nine of them changed only by gaining a
`: "${NAME:=default}"` line (see the two shapes at the end of this entry); the
eight below changed SHAPE, and are the watch list for the next 3-arch run. It
costs nothing to keep and closes the moment a green chain reports.

| file | change | what the log should show |
|---|---|---|
| `01-core/compiler-resolution.sh` | `derive_cxx_from_cc` now returns 0 with empty output instead of the test's status | the arm64/riscv64 SDK stages are the only paths that hit the g++-not-found fallback; a refusal there must still name the missing compiler, not die under `set -e` |
| `01-core/cross-env.sh` | `_cross_env_resolve_tools` tests the VALUE (`[ -x "${_ert_out[cxx]}" ] \|\| return 1`) | with the change above, this is the only thing stopping a stage sailing on with `CXX` empty |
| `build-cross-chain.sh` | `_chain_on_exit` is an `if`, not a trailing `&&` list | a chain that finishes GREEN must exit 0; the trap only fires at real teardown |
| `03-media/.../patch-gstreamer-sources.sh` | patch 006's guard is an `if` | a tree WITH `gst-libav` must still apply the patch — the suite proves only the absent path, and stubs `_apply_patch` |
| `01-core/cpython-dev-packages.sh`, `03-media/runtime/verify-media-artifacts.sh`, `03-media/build/ffmpeg/build-ffmpeg.sh` | five dead functions deleted | a caller that BUILDS the name at runtime (an `eval`, a `"${prefix}_optional"` nameref, a Dockerfile `RUN` assembling it) is invisible to grep; only a real base→media chain proves none exists |
| `01-core/versions.env` | `CUDA_ARCHITECTURES` quoted | the quotes are stripped by `load_versions_env` and never reach the `--build-arg` (proven, 220 args byte-identical). Only a CUDA-enabled media/nvidia stage proves they do not reach `-DCMAKE_CUDA_ARCHITECTURES=` and defeat the ONNX build's trailing `90` → `90a` rewrite. Check the cmake argv of the first nvidia build |
| `01-core/disk-guard.sh` | the buildkit-store fallback (DISK1) | see DISK2 — five separate things only a live run can answer |
| `06-packaging/smoke-runtime-image.sh` | `check_manifest_tree_arch` + fatal advert arms | see HT2 |

Two shapes that would be silent if wrong: an operator whose shell still exports
`MYPROJECT_GCC_TOOLCHAIN_PATH` is now ignored rather than erroring (the docs row
says so), and eleven of the thirteen `: "${NAME:=default}"` conversions sit at
file top level, so any Dockerfile `RUN` that *slices* a script rather than running
it whole would read an unset variable. One such case was caught statically —
`IREE_CROSS_BUILD_COMPILER` had to move INSIDE `build_iree_wheels()` because
`test-iree-wheelhouse-stages.sh` awk-extracts that block alone — and a second
would look identical.

### CL2. `build_python.sh:365` keeps a second extension-module list [S, ★★]

`local -a _optional_exts=(zlib _bz2 _lzma _ssl _hashlib _ctypes _sqlite3)` is
exactly the third truth `cpython-dev-packages.sh`'s header used to claim the
`_CPYTHON_EXT_DEV_PKG_TABLE` had absorbed. It never had: the wave deleted the
table's only two ext-module accessors as dead, so the `<ext-module>` column now
has **zero** readers, and the false "All of those sites now derive from this
table" was corrected in the header rather than by wiring line 365 up.

Wiring it is **not** mechanical: the table calls `_sqlite3` **required** while the
array treats it as **optional**, so the change flips an assert from warn to fatal
on all three arches. That needs a build, not a suite. Either wire it and take the
stricter verdict deliberately, or delete the unread column.

### CL3. `export_clang_gcc_toolchain_env` has no production caller [S, ★★]

`grep -rn export_clang_gcc_toolchain_env . --exclude-dir=.git` finds the
definition (`01-core/cross-gcc.sh:44`), its own error string, the suite written
for it on 2026-09-04 (`tests/test-cross-gcc-toolchain-knob.sh`) and the knob's
row in `docs/linux-cross-builds.md`. What it does NOT find is a caller in the
build: nothing sources this function to point clang at the source-built GCC, so
the `--gcc-toolchain` flags it exports never reach a compile.

The 2026-09-04 review refuted the entry's earlier framing. Two claims were
wrong and are not worth repeating: that the grep returns "exactly two hits"
(it returns six), and that the function is invisible to `dead-functions`
*because* it names itself in its own error string — it is invisible because the
gate is mention-based, and the suite and the doc row now mention it too, so no
change to the error string would make the gate see it.

What remains is the real question, unanswered: is clang ever the compiler on a
path where this would matter, or is the function dead weight from the
cross-clang experiment? Decide that before writing any gate — a gate that
enforces "documented operator switches must have a caller" would be worth
having, but not one derived from a repro that does not reproduce.

### CL4. `flutter_checks.sh:5` points at a page with no such content [S, ★]

`linux/scripts/05-frameworks/flutter/flutter_checks.sh:5` reads
`# Docs: docs/linux-reference.md.` — the deliberately quarantined general-Linux
cheat-sheet, which carries no repo-specific sections. It is as empty a pointer as
the one `cross-gcc.sh` carried until this wave. **`doc-links` cannot see it**
because it has no `#anchor`: the gate validates anchors, and a bare page reference
always resolves. Point it at a real section, or teach `verify_doc_links.py` that a
`docs/*.md` pointer with no anchor is worth a note.

### CL5. Two functions no extent gate had ever measured [S, ★★]

`code-size`'s brace count used to terminate early on a `{` inside a quoted `case`
pattern, so two closure functions were invisible to every extent gate until
2026-09-04:

* `build-android-from-source.sh | override_soundtouch_codeberg_checksum` — 68
  lines, **cc 16**, first measurement ever.
* `build-gstreamer-monorepo.sh | _gst_monorepo_tflite_flags` — **cc 18**, measured
  before over a 32-line truncation (its own comment about the stray-brace bug
  ended the count 19 lines early).

Both are now honest rows in `code-complexity.allow`. **Neither is a regression** —
the code is byte-for-byte unchanged — but neither has ever been reviewed either,
because nothing could see them. Both are `03-media`, so splitting them is a
build-validated change. Read them once; they may be fine.

### GH1. Nothing runs the other ~293 mutation entries between commit and CI [M, ★★]

The pre-commit hook samples at most `PRECOMMIT_MUTATION_CAP` (**16** since
2026-09-04) of the entries whose target is staged, newest first, and says so. CI
runs all 309. Between the two there is nothing.

A **pre-push hook** is the right home: `--changed`'s existing semantics
(everything committed since `origin/main`) are exactly push semantics, and a batch
pays once instead of per commit. Sharding made the price reasonable — the full
309-entry gate is **1m59s** at the default `--jobs 8` on a 32-core host, and
`--changed` over a branch is a fraction of that.

**Still blocked on one thing:** `verify_gate_registry.py`'s `HOOK` constant is a
single path, so adding `linux/host-config/git-hooks/pre-push` makes the generated
table report the `mutations` slug as CI-only — a false statement in a generated
file. Generalise `HOOK` to a list (`hook_slugs`, `hook_tier` and `hook_blocks` all
read one text today; union them), THEN add the hook, with its own case set.

**Memory note, new 2026-09-04:** the default `--jobs 8` holds eight ~200 MB
mirrors, ~1.6 GB of `TMPDIR`, and on this host `/tmp` is tmpfs. Fine for CI and
for an idle machine; a hook firing during a live cross build now peaks higher than
it used to. `--jobs 1` is the escape hatch. If it turns out to matter, lower the
default rather than dropping the sharding.

### GH2. The shared `(count, reason)` allow reader is half landed [S, ★★]

`quality_allow.load_rows(path, keys, fmt) -> {key: (count, reason)}` shipped and
`verify_shellcheck_warnings.rows()` was deleted in its favour; a malformed row is
now `ERROR: <file>:<line>: expected '<fmt>'` at exit 2 instead of a
`ValueError` traceback, and an inline `#` no longer truncates a reason.

**`docs/scripts/verify_code_dupes.load_allow()` still carries its own parse**, and
moving it needs the shared reader widened first. Two concrete blockers, both
measured:

* its duplicate-row check is intrinsically about the UNORDERED `frozenset` key, so
  `a | b` and `b | a` must collide;
* its message quotes raw line numbers (`code-dupes.allow:2: duplicate row …
  (first at line 1)`) that `load_rows` does not surface, and both a suite case and
  the `code-dupes.duplicate-row` mutation pin that wording.

The clean close is one commit: widen the reader to `{key: (count, reason, lineno)}`
and update all four call sites. Note the docs/ ↔ linux/ boundary — that file's
docstring advertises "No network, no project imports", so importing `quality_allow`
needs a `sys.path.insert` plus a corrected docstring, and `test-code-dupes.sh`'s
`_fixture` must start copying `quality_allow.py` into `${fix}/linux/scripts/`.

**Two smaller pieces of the same item.** `keys=None` is a transitional
compatibility mode that reproduces the old arity-from-the-right exactly, and it
keeps the mis-keying alive for `code-complexity.allow`, `function-size.allow` and
`file-size.allow` — a `|` in one of those reasons is now a named error rather than
a traceback, but it is still an error. Declaring `keys=3 / keys=2 / keys=1` at
those three call sites is a two-line follow-up. When complexity does declare
`keys=3`, its own `check_rows()` `len(key) != 3` branch becomes dead and the
`code-complexity.allow-row-arity` mutation becomes unkillable — delete both in the
same commit.

### GH3. `trailing-conditional`'s four false negatives [S each, ★–★★]

The gate shipped 2026-09-04 with 18 frozen predicates and four live defects fixed.
All four remaining limits are false NEGATIVES by design — a noisy gate earns an
allow row, and an allow row is cover — and are written up in
[`code-quality-tooling.md`](code-quality-tooling.md#trailing-conditional-returns-trailing-conditional):

the last-statement-only rule, the block closer, the trusted top-level `||` and the
one-line definition. Do not restate them here; that page has the shapes and the
named instance for each.

Closing the first two is real work and worth doing only if the shape kills another
build. Sitting next to them, not fixed and out of the gate's reach: the sibling
fallback at `01-core/cross-env.sh:433` is still an `a && b || c` chain
(`[ -x "${_cxx_fb}" ] && _ert_out[cxx]="${_cxx_fb}" || return 1`). Correct today,
and exactly the shape SC2015 warns about.

### GH4. The env-knobs owner scan reads no `arch-flags-*.env` [S, ★★]

Thirteen build-window knobs were re-homed to `: "${NAME:=default}"` at their
readers this wave and their registry rows deleted. **`MEDIA_SKIP_CSOUND` was
deliberately NOT converted and must not be**: its value is DATA, not an operator
choice — `03-media/core/arch-flags-riscv64.env` sets it to `1` and
`arch-flags-arm64.env` to `0`, and `media_load_arch_flags`
(`03-media/core/common.sh:65`) sources whichever matches the target arch. A
`: "${MEDIA_SKIP_CSOUND:=0}"` at a reader would be a second, competing claim.

The real gap is the gate's scope: `lint-env-knobs.sh`'s owner scan reads
`versions.env`, Dockerfile `ARG`/`ENV`, and script-side assignments in `*.sh` —
and nothing reads `03-media/core/arch-flags-*.env`. Teaching it that file set
re-homes `MEDIA_SKIP_CSOUND` and its four `MEDIA_SKIP_*` siblings properly and
shrinks the registry by five more rows.

**Two owner shapes the scan will deliberately still not count**, unchanged:
`-e "NAME=$(...)"` container-env injection (`RT_PROBE_SH`, `SMOKE_ONNX_PY`,
`RT_TREE_PY`) and `NAME=value` words passed to a test helper that later
`export "$@"`s them (`BUILD_RC`, `DISK_OK`, `HAS_PINNED_BASE`, `TRANSIENT`). Both
carry the name inside a quoted word, so counting them means un-masking string
content — the exact hole the 2026-09-04 walker closed. They are honest allow rows.

### GH5. Thirteen preflight slugs are frozen as unproven [M, ★★]

`gate-registry` reports **34 slugs; 21 proven; 13 unproven, 13 frozen in
`gate-proofs.allow`**. Two left the freeze on 2026-09-04 (`doc-dupes`, then
`stdout-returns`) and the new `trailing-conditional` shipped proven.

**The "cheap sweep" the entry this one replaces prescribed cannot be run as written, and
that prescription is now deleted.** It said to take the rows whose `mutations`
column is `—` and write a `return rc → return 0` mutation "and see whether its
suite survives". Measured: all thirteen have BOTH an empty tests list and an empty
mutations list (`verify_gate_registry.rows()` — copy-coverage, critical-fixes,
patch-integrity, arg-consistency, version-snapshot, mirror-consistency,
runtime-paths, dockerfile-lint, workflow-lint, secret-scan, android-parity,
pkg-names, sbom). There is no suite for the mutation to turn red; the experiment
has nothing to run.

What actually closes a frozen row is **writing the suite**. `stdout-returns` is the
worked example — 16 assertions over throwaway trees at the gate's own
`parents[2]` depth, four mutations, one new doc section, freeze line deleted — and
the nine remaining tree-consistency checkers are the cheapest next batch because
they share that shape.

The hollow-mention hazard the entry also named is real but lives among the 21
**proven** slugs, not these thirteen: the test half of the proof is still a
mention (`[t for t, txt in tests.items() if mentions(needle, txt)]`), so a suite
that names a gate's script and asserts nothing about it still reads `proven`. The
mutation half is no longer circular.

### GH6. Two holes in `dead-functions`, one narrow and one deep [S / L, ★★]

* **Narrow, and CL3 is the live instance:** a function that names itself in a
  `printf` reads as used, because the corpus scan strips comments and definition
  heads but not string literals. Cheap to close.
* **Deep — same-name masking:** one name table for the whole corpus, so a dead
  `log()` is kept alive by a live `log()` anywhere. Every short helper name is
  unguarded. The interim mitigation landed 2026-09-04: `--census` now has a second
  tier keyed on `(file, name)` — definitions their own file never names again
  whose name a **second file also defines** — reporting **93** of the 410
  candidates today, which is exactly the surface where the gate's verdict comes
  from a name it does not own. (The first tier is still inert: `0 of those in a
  file that sources nothing and that nothing else names`, which is why the second
  tier had to exist.) That is a watch list, not a fix. Closing it properly needs `source_module`-
  aware scoping, i.e. a real call graph.

Two smaller notes on the same gate: the census's own headline figures in
`code-quality-tooling.md` are re-typed prose that nothing derives — which is how
they came to be wrong by 11 functions and 8 rows before 2026-09-04. Deriving them
in `test-doc-numbers.sh` the way it already derives the manifest totals is the
obvious fix. And `test-dead-functions.sh`'s `_fixture` at `:23` is the original of
the tree builder extracted into `tests/gate-tree.sh` this wave; migrating it to
`gate_tree` leaves one owner for the pattern. `code-dupes` is clean either way.

### DISK2. The buildkit fallback is not wired into the two `build-cross-chain.sh` gates [S, ★★★]

DISK1 shipped where it bit: `_disk_guard_buildkit_fallback` runs
`buildctl prune --filter type==regular --keep-storage <keep×1000>` after the
cache-export trim comes up short, once per caller, and credits what it reclaimed
in the `[disk-reclaim]` line. The 2026-09-03 incident took the in-stage watchdog
path, so the defect is closed where it happened. Behaviour, log lines, the
120-vs-40 keep-storage reconciliation and the 100 GB floor are owned by
[`build-cache-tiers.md`](build-cache-tiers.md#321-the-buildkit-store-fallback-disk1).

**Two call sites in `build-cross-chain.sh` are still unwired**, and neither was
touched because another lane held the file:

* `_chain_runtime_lane_disk_gate` (~line 600) does `_disk_guard_trim_cache_export`
  → `_disk_guard_reclaim_record "runtime-lane-entry"` → `err`s the run out.
  Inserting `_disk_guard_buildkit_fallback "${bc_dir}" "${need}"` between the
  second and third lets a 415G store rescue the lane instead of refusing it.
* `_chain_stage_disk_guard` (~line 486) sets `CROSS_NO_LOCAL_CACHE_EXPORT=1` when
  its own LRU loop cannot reach the threshold; the same call belongs just before
  that give-up.

Pair the wiring with cases in `tests/test-chain-lifecycle.sh` — its lane-gate cases
stub `_disk_guard_free_gb` and would otherwise exercise a real prune.

**Five things only a live run can answer** (the suite proves the guard's shape, not
the daemon's behaviour): whether a mid-stage prune actually reclaims (buildkit
skips in-use records, so it may free far less than the 223G the between-stage
manual rescue got); whether the `exec.cachemount` records survive a prune issued
while a build holds them open; the wall-clock cost of the prune and of the
`buildctl du` reachability probe under load (36s was measured on an IDLE store,
and the watchdog runs on a 120s tick); whether `BUILDKIT_HOST` defaults correctly
for the chain's own uid in the rootless stack (only `prune-safe.sh` has ever run
that line, always from an interactive shell); and whether 120G of retained layers
is in fact enough to avoid recompile churn afterwards — the 100G floor is
inherited from a memory note, not from a reproducible measurement.

**One unresolved duplication:** `prune-safe.sh` and the guard both know the
filtered command and the GB→MB (`×1000`) keep-storage convention. No shared code
owner was extracted — `prune-safe.sh` runs `main` on load and cannot be sourced,
and it lives in `linux/host-config`. The overlap is ~3 lines and `code-dupes` does
not flag it, but the policy has one *written* owner rather than one *code* owner.
Sourcing `01-core/disk-guard.sh` from `prune-safe.sh` and calling
`_disk_guard_buildkit_prune` would close it. Worth one `buildctl prune --help`
check by a human with the daemon up: the `×1000` unit was inherited from what was
proven in anger on 2026-09-03, not re-derived against the installed flag
semantics, and a units change would silently turn 120000 into the wrong retention.

### HT2. The tree-arch exemption table is reasoned, not measured [S, ★★]

`check_manifest_tree_arch` shipped 2026-09-04 in `smoke-runtime-image.sh`: one
in-image scanner reads the ELF header of every object under each of the
**15** manifest trees and aggregates `(tree, machine) -> count`; anything that is
not the image's own machine is FATAL and names the tree plus an example path.
Design, probe-path arms and the no-vacuous-pass guards are owned by
[`artifact-copy-completeness.md`](artifact-copy-completeness.md#the-shipped-trees-must-carry-the-images-own-arch).

**The exemption table was reasoned, not measured** — that page's own
"What only a real build can tell you" subsection records which tree was ruled
in or out by reading which script, including the one tree the reading DID catch
(`/opt/vulkan` keeps the SDK's x86_64 host tools, so the gate probes
`/opt/vulkan/active`). What is open is the verification, below.

**What the first real run decides.** If any exempt tree still holds a legitimate
builder-arch helper the gate reds and names it, and the fix is one arm with a
written reason. Two trees could not be ruled out statically: `/opt/flutter`
(`bin/cache` can hold host-named engine artifacts even after the per-arch
bootstrap) and `/usr/local/rustup` (leftovers under `downloads/`). MISSING is
fatal by design — every manifest tree must exist as a directory — and no run has
confirmed all 13 non-exempt trees exist on all three arches;
`verify-artifact-copy-parity.sh` only proves the COPY line is written. The scan is
capped at 20000 files per tree with a deterministic sorted walk and reports
`TREECAP` when it hits; watch that INFO line and the added container-start cost
under QEMU.

The advertised-key half of the same file is proven the same way: static proof
covers the verdict function and the gate loop, but only a run proves the sixteen
remaining keys really are ENV-advertised and probe-readable on all three arches.
The 2026-09-04 run's own log is the evidence relied on (16 OK, `PYTHON_VERSION`
the single SKIP, zero "could not read" lines), so the new `UNSET`/`UNREAD` arms
should stay silent. If one fires, it is naming a real defect.

### YB. sccache loses thousands of cache entries per chain to an intermittent spawn ENOENT — MITIGATED 2026-09-03, root cause still open [medium]

**Read [`build-cache-tiers.md`](build-cache-tiers.md#what-was-measured-about-the-enoent-class)
first — it is the canonical record** and it already contains more than a fresh
investigation recovers: the 3062 bypasses of the 2026-09-01 run, the 2952x ENOENT
class on sccache's own `-E` pass, its intermittency in the heavily parallel steps
only, the absolute compiler path and live-build-dir cwd, the direct fallback of
the same argv succeeding right after, and the explicit instruction not to derive a
root cause from the message alone. (The launcher's own header is five lines now
and points at that section; it is no longer where the record lives.)

**Disproved by experiment 2026-09-03, so nobody repeats them:** the failing
`argv[0]` is never bare or relative; all six failing compiler paths exist and are
executable in the image; a plain sccache cross-compile returns rc=0; a
375-variable / 65 KB environment does not trigger it (and would be `E2BIG`). Two
lookalikes were reproduced and carry DIFFERENT messages: a missing `-MF` directory
is a compiler error *after* a successful spawn, and a deleted cwd gives
`Couldn't determine current working directory`. A 2026-09-03 re-derivation also
nominated `current_dir()`, which the record above had already ruled out — the cost
of not reading it first.

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
fix, and do not size the remaining work as if it were. A scheduling race or a
momentary resource shortage would recover far more than 5%, so neither is the
mechanism; something about the specific invocation fails repeatably within a short
window, which points at per-request state inside the server rather than at the
environment.

**Two things still open here.** (a) `build-cache-tiers.md` still presents the
retry as the pending experiment ("says directly whether the class is transient")
without recording that the answer came back negative — copy the 27/514 result into
that section so the next reader does not re-run it. (b) No fresh counts exist:
today's run was `--only runtime` and its log contains zero `sccache-launcher`
lines, so 27/514 is still the latest data. Defer new root-cause work until the
next compile-heavy build (media or toolchain) can produce a second sample.

Reading the log needs one caution learned here: a **cached** BuildKit step replays
its old output verbatim. The first read of the 2026-09-03 build showed 496 hits of
the pre-retry message, all from one cached step (`#30`), which would have looked
like the new launcher failing to take effect.

### F1. Functions that outgrew a screen [M each]

**`function-size.allow` is the authority — do not transcribe it here.** A
hand-copied excerpt of the top rows lived in this entry until 2026-09-04, silently
omitted four larger unreviewed functions, and pointed at the wrong next candidate;
the freezing applies to the allow file, not to a paragraph quoting it. The gate
prints `functions: 36 over 80 lines; 36 frozen` today, and **29** of those rows
still read `baseline 2026-09-03, not yet reviewed`.

**Re-derive the queue from the gate, then judge by value, not by line count.** As
of 2026-09-04 the top is `assert_pinned_versions` 356, `bump_versions.py main`
159, `verify_package_names.py main` 140, `cmake_build_parse_args` 116,
`smoke-torch-venv.sh main` 115, `_opencv_target_adjustments` 114,
`uv_sync_project` 109, `append_tvm_cmake_args` 84.

**`assert_pinned_versions` is top by size and the WORST candidate by value.** It
is not 356 lines of shell — it is **44** lines of shell wrapping a **312**-line
embedded Python program (`"${PY}" - <<'PYEOF'`, `smoke-torch-venv.sh:101`–`414`).
Splitting the shell moves 44 lines. Split the wrapper for its own sake, never for
the line count.

**Cheapest real target: `cmake_build_parse_args` (116).** It lives in `lib/`,
outside the build closure, so it can be cut at any time, and it also carries the
`cc 31` complexity row QW2 misses.

Two of the 36 rows are **first-ever measurements**, not regressions — see CL5;
they have never been reviewed because no extent gate could see them until
2026-09-04.

**The one uncovered path left inside `_cross_stage_build_impl` is the
registry-cache drop** — lines 295–317, **23** lines, not the ~16 previously
claimed. It needs a non-empty `log_file` whose tail matches
`DeadlineExceeded|httpReadSeeker`, and it mutates both `build_cmd` and
`_regcache_fails` across retry iterations. Nothing covers it:
`grep -rn DeadlineExceeded linux/scripts/tests/` returns nothing, and
`test-cross-stage-build-cmd.sh` only counts `cache-from`/`cache-to` on the
non-failing path. Write the characterisation first — fake `log_file`, assert the
counter reaches 2 and that the registry cache pairs vanish from `build_cmd` while
local cache args survive — then extract. `01-core`, so it was frozen; the window
is open now.

### F2. Files over ~800 lines [L each, low priority]

**`file-size.allow` is the authority — do not transcribe it here either.** The
ten-row table that used to sit in this entry was written on 2026-09-03 and was
already wrong by two rows the same day (`smoke-runtime-image.sh` 1502→1559,
`build-litert.sh` 975→953), each drift correctly recorded with a reason in the
allow file. It drifted again on 2026-09-04: `smoke-runtime-image.sh` is **1739**
after HT2's tree-arch audit, and three closure files each grew by 1–3 lines for
the env-knob self-defaults and the `_chain_on_exit` `if`. The gate prints `files: 10 over 800 lines; 10 frozen`; read it there.

Splitting any of the ten is still open work and still low priority. Seven of them
sit inside the build closure and could not be touched during the run that finished
at 12:24; `bump_versions.py`, `sync_versions.py` and `lib/agentic-loop.sh` never
were. If one gets split this cycle, take `smoke-runtime-image.sh`: it is the
largest file in the tree (1739), it is still growing, and its probe sections are
already named seams.

### F3. Clone families worth one owner [S-M each]

One genuinely-open observation remains. The gate reads
`3250 units in 350 files, no block over 10 shared 12-token shingles
(241 allowlisted pair(s); 891 shingle(s) suppressed as idiom at >6 owners)` on the
integrated tree — two of those budgets SHRANK on 2026-09-04 and were re-recorded
with the reason, which is the gate working. The decided/reviewed items (the
source-or-fallback KEEP decision, the lint-tool and lib/* pairs reviewed-and-kept
by measurement, and the not-actionable Dockerfile mount preambles) are in the
2026-09-03 archive. The `install-deps.sh` family bullet was **measured and closed
2026-09-04**: the shape already has an owner (`media_install_deps_init` /
`install_target_packages`) and the literal residue is a 7-line bootstrap header,
below this entry's own 11–12-line extraction threshold.

- **`lib/*.sh` share a 14-line logging-fallback preamble across 9 files** —
  `if ! declare -F info; then source …; else info() { … }; fi`, identical in
  `app-runner`, `coverage`, `ctest-run`, `cmake-build`, `rust-toolchain`,
  `code-quality`, `docs-build`, `wasm-opt` and `slang-compile`, differing only in
  the `_<NAME>_CORE_DIR` token. **`verify_code_dupes` cannot see it**: at 9 owners
  every shingle lands in the `suppressed as idiom at >6 owners` bucket
  (`MAX_OWNERS = 6`), and the `widely-copied blocks` section did not print at all
  in the 2026-09-03 run — which is precisely why this needs a backlog row rather than a
  gate finding. (Do not quote a shingle count for it; the gate no longer produces
  one. The largest family the gate *does* report today is `_path_contains`, 44
  shingles over 3 files.) **Bootstrap paradox before touching it:** the block
  exists for the case where nothing has been sourced yet, so extracting it into a
  file you must source defeats its purpose. A shared file plus a 2-line guard may
  still beat 14 lines × 9. Outside the build closure (`lib/` is in no Dockerfile),
  so it can be done any time.

### F4. The 95 frozen `shellcheck-warnings` rows are frozen, not REVIEWED [M, ★★]

`shellcheck-warnings.allow` holds 95 `(file, SCxxxx)` rows covering 177
warning-level findings in 74 files, every single one reading `baseline 2026-09-03,
not yet reviewed` — 95 of 95, no exceptions. Re-derived 2026-09-04: still 95, over
a scope that GREW to **317** files when the pre-commit hook joined the ratchet.
The hook itself contributed zero rows — the hole was coverage, not debt. The gate guarantees the number
matches reality; it says nothing about whether the warning is right. SC2034 is 85
of the 177 and is where real bugs hide — a genuinely unused variable is usually a
typo'd reference elsewhere — but most of these are sourced-library variables a
consumer reads, so expect scoped `# shellcheck disable=SC2034` with a reason
rather than deletions. SC2154 (16, all but four in `01-core/cross-env.sh`) is the
next cluster, then SC2155 19, SC2178 12, SC2046 11, SC1090 9, SC2163 8. Review per
file and put the verdict in the row's reason column. This is 74 small independent
reviews, not one big one — the largest single file is 5 findings.

### F5. The 69 unreviewed `code-complexity` rows, same [M, ★★]

69 `cc` rows and 3 `nesting` rows in `code-complexity.allow` (**72** total after
2026-09-04 added two first-ever measurements, CL5); **69 of the 72 are
unreviewed** (one has since gained a real verdict —
`build-litert.sh | _litert_wheel_cross_args | cc | 21`, "24 before the
command-position fix; the extra 3 were argument words"). That file plus
`verify_code_complexity.py` are the authority for every complexity number here —
the hand-measured figures that circulated before the gate existed were
over-counts, one of them by 7×: `assert_pinned_versions` is **cc 7**, not 52 (its
312 lines are embedded Python the shell walker never reads — the function is 356
lines today and its cc still did not move), and `_chain_stage_disk_guard` is 28,
not 29. The real top of the queue, sorted from the gate: `scan_file` and `main`
(`verify_package_names.py`) at 42, then `bump_versions.py main` **37**,
`media_common_init` 35, `_opencv_target_adjustments` 33,
`cmake_build_parse_args` **31**, `cross_stage_run` 23. Never re-measure by hand:
run the gate. The extent bug that skewed a handful of these was fixed on
2026-09-04, so the numbers the gate prints now are the honest ones.
