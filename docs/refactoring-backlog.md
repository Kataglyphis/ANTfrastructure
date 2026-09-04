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
**SMK**=smoke gaps · **TC**=trailing-conditional gate · **QW**=quality-gate wave
follow-ups · **F#**=size/duplication tracks. Everything else
(**AP/TG/TS/GPU/DUP/PAR/SCC/BT/LOG/LB/C#/D#/P#/S#/XC#**) is archive-only.

Last groomed: **2026-09-04 12:30**, right after the `--only runtime` relaunch
(`20260904-054734-bc9164a0`) shipped a green 3-arch `:latest-cross`
(amd64 `0e0d33db`, arm64 `5a4fd8e3`, riscv64 `a8901549`; all runtime smokes green,
`PASS all 16 advertised version(s) match the shipped image` on all three arches).
**The build closure is therefore OPEN** — `01-core`, `02-toolchain`, `03-media`,
`05-frameworks`, `06-packaging` and the Dockerfiles are editable again, and every
entry that used to end in "waits for the running build" is now actionable. Closed
today and living in git history rather than here: FL1 (the per-arch Flutter
bootstrap, proven live on all three arches) and HT1's rust-toolchain member.

**Eighteen entries remain** (`grep -c '^### '` counts twenty; two of those
headings — "Next up" and "What needs the OWNER" — are not entries): DISK1, HT1,
SMK-ADV, TC1 and the ten QW rows are open work; YB is a defect under
investigation; F1/F2/F3 are tracks.

* **QW1–QW10** — what the 2026-09-03 gate wave left behind and what the
  2026-09-04 Q7, Q8 and Q9 waves deliberately did NOT fix: two
  frozen-but-unreviewed baselines, five dead functions to delete, the shared allow
  reader, the ownership shapes the gate registry cannot express, and the limits
  the gates disclose rather than close.
* **DISK1** — the chain's in-stage disk reclaim ignores the buildkit store. Cost
  a full runtime run on 2026-09-03. Newly actionable.
* **YB** — sccache cache loss. Mitigated, and the mitigation was **measured and
  found weak** (~5% recovery). Root cause open.
* **F1 / F2** — oversized functions and files, both frozen by the `code-size`
  gate instead of hand-measured. 29 of the 36 frozen function rows are still
  unreviewed.
* **F3** — down to one genuinely-open clone family; everything else there is
  reviewed-and-KEPT on purpose.

### Next up — the eight highest value-per-effort items, in order

1. **QW3 — delete the five dead functions** [S, ★★]. The build that froze them
   finished at 12:24; the gate still calls all five dead today. Pure subtraction,
   four allow rows go with them.
2. **DISK1 — buildctl fallback in the in-stage disk guard** [M, ★★★]. The only
   entry here that has already cost a whole runtime run. Its file was frozen for
   the build; it no longer is.
3. **QW9's `versions.env` quoting** [S, ★]. One line
   (`CUDA_ARCHITECTURES` at `versions.env:407`), removes three `command not found`
   lines from stderr on every hook run. `01-core`, so it was frozen; it is not now.
4. **TC1 — the trailing-conditional gate** [S, ★★]. Two silent build deaths in
   two days shared this shape and shellcheck has no check for it. A live instance
   is sitting in `01-core/compiler-resolution.sh` today.
5. **QW4 — fix the raw brace count in `code-size`** [S, ★★]. Four gates inherit
   the wrong function extents; the fix is one `strip_line` call plus exactly one
   new allow row.
6. **QW8's twelve build-path env-knob defaults** [M, ★★]. Also unblocked by the
   finished build; shrinks the registry and puts each default where it is read.
7. **QW9's per-entry suite re-run** [M, ★★★]. Highest ceiling on the list — 244
   mutant processes over 33 distinct suites is what keeps `PRECOMMIT_MUTATION_CAP`
   at 6.
8. **SMK-ADV — make both SKIP arms fatal** [S, ★★]. A row that can only ever SKIP
   is the same hole that hid eleven ARG-only keys for months.

**Honesty about the rest:** QW1 (95 shellcheck rows) and QW2 (69 complexity rows)
are the biggest *time* items in this file and neither is a defect — they are
bookkeeping, reviewing rows a gate already freezes. Real defects with a known
failure mode are DISK1, TC1, QW4, QW5, QW6, QW7's `--baseline --kind` footgun and
QW10's `mirror_tree` escape.

### What needs the OWNER, not the agent

Nothing in the eighteen entries above is blocked on you. These are:

1. **`git push`** — one local commit is ahead of `origin/main`: `764a18a1`
   (the hook's own refusals + the doc-dupes proof). Everything earlier tonight,
   including the rust-toolchain fix `09b1e6e2` and the whole Q1–Q6 wave, is
   already on the remote. Re-derive this line at grooming time with
   `git rev-list --count origin/main..HEAD` rather than retyping a ref — it was
   wrong at the last two groomings.
2. **The Windows lane.** Six confirmed doc defects from the 2026-09-03 currency
   audit are parked in
   [`windows-refactor-backlog.md`](windows-refactor-backlog.md), verified against
   the tree only — no Windows host was involved. **Three** of the six are wrong
   paths a reader would follow into a "file not found"
   (`verify-host-setup.ps1`, `healthcheck.ps1`, `Dockerfile.toolchain`); the
   fourth is the QNN version contradiction at `README.md:204`.
3. **A newer QNN SDK, if you want one.** v2.49.0.260730 is pinned, hashed and
   validated end to end. Only a *newer* SDK needs a re-pin, and only you can fetch
   it (login-gated).

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

### DISK1. The chain's in-stage disk reclaim never looks at the buildkit store [M, ★★★]

**Not a gate item — this came out of a build.** The in-stage disk reclaim only
trims `~/.cache/kata-buildcache` and then reports `NOTHING was reclaimable`,
while `~/.local/share/buildkit` holds hundreds of GB of `type==regular` layer
cache it never inspects. `disk-guard.sh` says so in its own words: *"It touches
ONLY that host directory — never the buildkit store."* On 2026-09-03 that cost a
full runtime run: the riscv64 torch stage hit ENOSPC at **4G free** while **415G**
sat in the buildkit store. `PRUNE_KEEP_GB=120 linux/host-config/prune-safe.sh`
then freed **223G in 36s** with all **97** cache-mount records surviving.

Today's numbers make the case sharper than the original write-up did:
`~/.local/share/buildkit` is **292G**, `/` has **123G** free, and
`~/.cache/kata-buildcache` holds 50G in exactly **three** slugs — with `keep_n`
defaulting to 3, the trim would log `keeping the newest 3 slug(s); stopping` and
free **literally nothing**.

The disk guard should fall back to that filtered `buildctl prune` before declaring
defeat — and **never** to `nerdctl builder prune -f`, which eats the cachemounts
(1.5–2 h of cold LLVM to rebuild; see the rebuild-disk-management memory).
`prune-safe.sh` already has the shape (`PRUNE_KEEP_GB`,
`buildctl prune --filter type==regular --keep-storage`, and a cachemount-survival
count); it is simply not wired into the guard. `grep -rn buildctl linux/scripts/`
finds no invocation anywhere in the chain, only a hint string.

**Actionable now** — the guard's file was frozen for the cross build that finished
at 12:24. Ship: the filtered fallback, a cachemount-survival assertion, and an
amendment to `tests/test-disk-guard.sh` (53 assertions today), one of which
currently pins the `NOTHING was reclaimable` give-up as correct behaviour.

### HT1. Host trees copied from `artifact-source` — the builder's arch ships in foreign images [M, ★★]

`Dockerfile.package`'s `artifact-source` is the **amd64 host** cross image. Every
`COPY --from=artifact-source` of a tree that was *installed on the host* (not
cross-built for the target) puts x86_64 binaries into the arm64/riscv64 runtime
image. Both known members are fixed and both are now proven on shipped bytes, so
what remains is the general audit — there is still no gate that would catch a
third member.

`runtime-artifacts.manifest` lists **14** COPY'd trees. `check_arch_parity`
asserts only that `/opt` prefixes and dist-info names are PRESENT, never the ELF
machine of anything inside them; `check_native_so_closure` gives partial,
incidental coverage of `/opt/ffmpeg`, `/opt/opencv5`, `/opt/libcamera` and
`/opt/vulkan/active/lib` by `ldd`. That leaves `/opt/gcc-${GCC_VERSION}` (a
builder-hosted cross toolchain shipped verbatim into foreign images),
`/opt/android-sdk`, `/opt/android`, `/opt/llvm-target`, `/opt/armnn` and
`/opt/acl` with **no arch assertion at all**. The only ELF-machine reads in the
runtime smoke are the Flutter dart check and the riscv64 ISA-attribute check.

Ship a manifest-driven gate in `smoke-runtime-image.sh` next to
`check_native_so_closure`: `readelf -h` one executable per manifest tree, compare
the machine against `dpkg --print-architecture`, with an explicit exemption arm
for the trees that are *intentionally* the builder's arch (the `/opt/gcc-*` cross
toolchain, host-side android SDK tooling). Exemptions must name the tree, not the
arch, so a new host-installed tree fails by default.

### SMK-ADV. Two `_advert_verdicts` SKIP arms are non-fatal, and one row can only ever SKIP [S, ★★]

**Re-aimed 2026-09-04 against a completed run.** The original write-up asked for a
per-`<arch>:<key>` exemption table for keys the probe cannot read; the relaunch
supplies the data and that table would be born **empty** — `could not read the
actual value` occurs **zero** times across all three arches. The design has also
moved past exemptions: per-arch `<KEY>_<ARCH>` overrides in `versions.env` solved
the riscv64 CMAKE/NODE divergence instead, and the header above
`_ADVERTISED_VERSION_KEYS` now states there is no exemption arm because a label
that contradicts the artefact is never a documented state.

What is real is the *other* arm. Every arch printed the same three lines:
`SKIP PYTHON_VERSION: image sets no PYTHON_VERSION -- nothing advertised to check`
followed by `PASS all 16 advertised version(s) match the shipped image` — 16 OK of
17 keys. `PYTHON_VERSION` is ARG-only in `Dockerfile.package` (deliberately not
advertised as ENV), while `verify_advertised_keys.py` matches ENV *or* ARG and so
forces the key into `_ADVERTISED_VERSION_KEYS`, producing a row that can only ever
SKIP. That is exactly the shape `verify_advertised_keys.py` emptied
`FROZEN_UNPROBED` to abolish — *"adding an entry here accepts a row that cannot
fail"* — re-entering through the runtime side, and it is the hole that let
`d27cdee1`'s eleven ARG-only keys SKIP unnoticed for months.

Fix both arms: make `could not read the actual value` **BAD** outright (that is
the rust-defect shape — `rustc --version` failed on arm64 for months and the gate
said SKIP), and either ENV-declare `PYTHON_VERSION` or excuse it in
`verify_advertised_keys.py` so no key sits in a permanently-SKIPping row. Ship
with `tests/test-runtime-image-gates.sh` cases plus a mutation that flips the
BAD arm back to SKIP.

### TC1. Static gate for the trailing-conditional return [S, ★★]

Two silent build deaths in two days had the same shape: a function whose **last
statement** is `cond && action`, returning 1 when `cond` is false, killing the
caller under `set -e` with no message (`reconcile_local_wheels` 2026-09-03; the
2026-09-02 `logging.sh` ERR-trap case was the mirror image). shellcheck has no
check for it. A small `verify_trailing_conditional.py` over `linux/scripts/**/*.sh`
— last non-comment statement of a function body matches `&&` without a trailing
`|| true`/`|| return 0`, or is a bare `[ … ]` — with the usual four-way allowlist.

**Nothing blocks it:** the Q1–Q6 wave landed, so the `preflight.sh` /
`mutations.json` / `code-quality-tooling.md` seams it shares are free; ship it as
the eight-part set every gate there ships as (script + allowlist + tests + two
mutations + docs + slug, registered last so `gate-registry` sees it).

A prototype scan finds **34** hits, ~25 of them outside test fixtures. Most are
intentional predicates that will need the allowlist (`cross_mode_requested`,
`best_effort_mode`, `smoke_is_elf`, `ancestry_run_ids_coherent`), but at least one
is the live defect shape and must be **fixed, not allowlisted**:
`01-core/compiler-resolution.sh:105` `derive_cxx_from_cc()` ends on
`[ -x "${cxx}" ] && printf '%s' "${cxx}"`, returning 1 whenever the derived `c++`
is not executable. `build-cross-chain.sh:724` `_chain_on_exit()` ends on an `&&`
continuation line and is an EXIT trap — check it by hand.

Characterisation suites for F1 extractions should also run the function under
`set -eu` and assert 0 on every early-return path. Only one suite does so far:
`tests/test-reconcile-local-wheels.sh` ("a non-torch wheel set returns 0 under
`set -e`"), added with the hotfix.

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
allow file. The gate prints `files: 10 over 800 lines; 10 frozen`; read it there.

Splitting any of the ten is still open work and still low priority. Seven of them
sit inside the build closure and could not be touched during the run that finished
at 12:24; `bump_versions.py`, `sync_versions.py` and `lib/agentic-loop.sh` never
were. If one gets split this cycle, take `smoke-runtime-image.sh`: it is the
largest file in the tree (1559), it is still growing, and its four probe sections
are already named seams.

### F3. Clone families worth one owner [S-M each]

One genuinely-open observation remains. The decided/reviewed items (the
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
  in today's run — which is precisely why this needs a backlog row rather than a
  gate finding. (Do not quote a shingle count for it; the gate no longer produces
  one. The largest family the gate *does* report today is `_path_contains`, 44
  shingles over 3 files.) **Bootstrap paradox before touching it:** the block
  exists for the case where nothing has been sourced yet, so extracting it into a
  file you must source defeats its purpose. A shared file plus a 2-line guard may
  still beat 14 lines × 9. Outside the build closure (`lib/` is in no Dockerfile),
  so it can be done any time.

### QW1. The 95 frozen `shellcheck-warnings` rows are frozen, not REVIEWED [M, ★★]

`shellcheck-warnings.allow` holds 95 `(file, SCxxxx)` rows covering 177
warning-level findings in 74 files, every single one reading `baseline 2026-09-03,
not yet reviewed` — 95 of 95, no exceptions. The gate guarantees the number
matches reality; it says nothing about whether the warning is right. SC2034 is 85
of the 177 and is where real bugs hide — a genuinely unused variable is usually a
typo'd reference elsewhere — but most of these are sourced-library variables a
consumer reads, so expect scoped `# shellcheck disable=SC2034` with a reason
rather than deletions. SC2154 (16, all but four in `01-core/cross-env.sh`) is the
next cluster, then SC2155 19, SC2178 12, SC2046 11, SC1090 9, SC2163 8. Review per
file and put the verdict in the row's reason column. This is 74 small independent
reviews, not one big one — the largest single file is 5 findings.

### QW2. The 69 unreviewed `code-complexity` rows, same [M, ★★]

67 `cc` rows and 3 `nesting` rows in `code-complexity.allow`; **69 of the 70 are
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
run the gate, and note that the numbers of a handful of functions are wrong for
the reason in QW4.

### QW3. Delete five dead functions — the build is over, take it now [S, ★★]

**Re-confirmed against the gate 2026-09-04.** Four sit in `dead-functions.allow`
under a **DEAD** heading only because their files were inside the running build
closure, which ended at 12:24: `cpython_ext_dev_packages_optional`,
`cpython_ext_modules_optional` and `cpython_ext_modules_required`
(`01-core/cpython-dev-packages.sh`, all one-line wrappers over
`_cpython_dev_pkgs_by_class` / `_cpython_ext_modules_by_class`), and
`verify_shared_lib_optional` (`03-media/runtime/verify-media-artifacts.sh:112`).
A whole-repo grep across `*.sh`/`*.py`/Dockerfiles/`*.md` finds only the
definition and this file's prose for each — no caller. The gate reports
`1839 shell functions; 39 named nowhere else; 39 frozen` and all four are in that
set today.

The fifth, `cleanup()` at `03-media/build/ffmpeg/build-ffmpeg.sh:716`, is the only
occurrence of that string in its own file but is invisible to the gate (same-name
masking: 7 live `cleanup()` definitions elsewhere under `linux/`). Driving the
gate's own `dead(mentions(texts()))` returns 39 keys and ffmpeg is not among them,
so a row for it **would fail as STALE the moment it was written** — do not write
one.

**Delete all five functions and the four allow rows in one commit.**

### QW4. `code-size` measures shell function extents with a raw brace count [S, ★★]

The brace-counting defect is written up under
[Known limits](code-quality-tooling.md#shell-complexity-code-complexity); the
work item is the fix, not the description. `verify_code_size.py` does
`depth += body.count("{") - body.count("}")` over raw lines, with no comment or
quote blanking, so `generate_pkgconfig_file` reads **5** lines instead of 37 — it
terminates on the `${libdir}` inside its own explanatory comment about the
stray-brace bug. **Four** gates inherit those extents, not three:
`code-complexity`, `dead-functions` and `gate-registry` (which imports
`shell_functions` too).

Blast radius, measured by re-walking every `.sh` with `strip_line` applied first:
exactly **five** functions change extent tree-wide — `generate_pkgconfig_file`
5→37, `_opencv_write_cxx_compat_shim` 17→**132**, `_gst_monorepo_tflite_flags`
32→51, `test-runtime-image-gates.sh _extract` 2→22, `test-pkgconfig-file.sh
_stray_braces` 2→3.

**Correction to the old prescription:** none of those five holds a row in any of
the four allow files, so "re-freeze the three allow files, expect movement in
every one of them" is wrong — nothing moves. The actual consequence is one **new**
violation: `_opencv_write_cxx_compat_shim` at a corrected 132 lines crosses
`FUNCTION_SIZE_LIMIT=80` and fails `code-size` until it gets a row or is split.
Fix by blanking comments and quotes with `verify_code_complexity.strip_line`
before counting, and add that single `function-size.allow` row in the same commit.

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
The `#` half is quieter and worse: a reason containing `#` parses, the count
survives and the reason is silently truncated. Three call sites, all
reason-bearing: `verify_code_complexity.py` (`code-complexity.allow`) and
`verify_code_size.py` twice (`function-size.allow`, `file-size.allow`).
`verify_shellcheck_warnings.rows` keys positionally from the LEFT and is immune —
that is *why* the ratchet works, not luck — and `verify_code_dupes.load_allow`
already does the right thing, printing `ERROR: <file>:<n>: expected 'a | b |
budget | reason'` and exiting 2. One `load_rows(path) -> {key: (count, reason)}`
in `quality_allow.py` that keys from the left and names the offending line,
shared by `check_counts` and every `--write-baseline`, deletes both copies.

### QW6. `test-vulkan-target-decomposition.sh` hardcodes `/tmp` [S, ★]

Its normalising `sed` (line 68) matches `/tmp/[A-Za-z0-9._]+/` literally while the
fixture root at line 27 is `mktemp -d`, which honours `TMPDIR`. Proven live, not
by inspection: the suite passes 35 assertions by default and fails **5 of 35**
under a non-`/tmp` `TMPDIR`, with un-normalised paths visible in the diff. Derive
the pattern from the harness's own temp root.

### QW7. Gate limits disclosed but not closed [S each, ★–★★]

Each is written up in the gate's own section of
[`code-quality-tooling.md`](code-quality-tooling.md); none has an owner.

* **`dead-functions` same-name masking** — one name table for the whole corpus,
  so a dead `log()` is kept alive by a live `log()` anywhere. Every short helper
  name is unguarded. **`--census` is inert on this tree** (re-measured 2026-09-04:
  `429 definition(s) their own file never names again; 0 of those in a file that
  sources nothing and that nothing else names`), so the mitigation reports
  nothing and the masking is entirely unwatched — the known-dead
  `03-media/build/ffmpeg/build-ffmpeg.sh:716 cleanup()` of QW3 is invisible to
  both the gate and the census. Closing it properly needs `source_module`-aware
  scoping, i.e. a real call graph; the cheap interim worth taking now is a census
  tier keyed on `(file, name)` rather than on the file's reachability, which would
  surface the ffmpeg `cleanup()` today.
* **`gate-registry` mention-based TEST proof** — narrowed 2026-09-04, not closed.
  The mutation half is no longer circular (an entry is credited only to the gate
  its `<slug>.` id prefix names, and only over that gate's own or imported files,
  with off-convention ids failing loudly), but the *test* half is still a
  mention: `[t for t, txt in tests.items() if mentions(needle, txt)]` asks nothing
  of the suite, so a suite that names a gate's script and asserts nothing about it
  still reads `proven`. **14** of 33 slugs remain frozen as unproven (tonight's
  `764a18a1` closed one; `gate-proofs.allow`'s own header still says 15 and needs
  the same correction). The cheap sweep nobody has run: for each of the 14 rows
  whose `mutations` column in [`code-quality-gates.md`](code-quality-gates.md) is
  `—` — stdout-returns, copy-coverage, critical-fixes, patch-integrity,
  arg-consistency, version-snapshot, mirror-consistency, runtime-paths,
  dockerfile-lint, workflow-lint, secret-scan, android-parity, pkg-names, sbom —
  write the `return rc` → `return 0` mutation and see whether its suite survives.
  That experiment is exactly what exposed `python-lint`, `comment-size` and
  `masked-decls` as hollow.
* **`code-dupes --baseline --kind X`** rewrites the whole allow file from that
  kind's pairs only, dropping every other kind's row. `--kind` scopes the stale
  check correctly; `_write_baseline` never sees the rows it is about to discard.
  Measured on today's file — 241 rows: 229 shell, 7 docker, 5 md — so
  `--baseline --kind md` would silently delete **236** curated rows and their
  reasons. Cheapest fix: refuse `--baseline` when `--kind` is given. [★★, not ★ —
  re-rated 2026-09-04 once the blast radius was counted.]
* **`preflight.sh`'s submodule-pin warning names two causes and omits the
  likeliest.** [S, ★★] The 2026-09-03 alarm on
  `external/Kataglyphis-DocumANTation` was a false positive: the pin **is** an
  ancestor of the remote's `main` and the local `origin/main` ref was simply
  stale, which a plain `git fetch` in the submodule cleared. The message still
  reads *"unpushed local commit or upstream rewrite"* — a **stale
  remote-tracking ref** is the third and likeliest cause and is the one the
  wording does not name. Add it (with the `git fetch` remedy) and pin the string
  with an assertion so it cannot drift back.

### QW8. What the 2026-09-04 Q7 honesty wave left open [S each, ★–★★]

Seven follow-ups the wave surfaced and deliberately did not take (two of the
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
  default greppable where it is read; 84 distinct knobs already use that shape.
  Three are reachable in any window — `PREFLIGHT_ONLY` and `PREFLIGHT_SKIP`
  (`preflight.sh`) and `SKIP_REAL_TREE` (`tests/test-shellcheck-warnings.sh`).
  The other twelve live under
  `01-core`/`02-toolchain`/`03-media`/`05-frameworks`/`06-packaging` and were
  frozen for the cross build; **that build shipped at 12:24, so take all fifteen
  in one commit** and delete their allow rows with them.
* **`MYPROJECT_GCC_TOOLCHAIN_PATH` is a template leftover, documented rather than
  renamed.** [S, ★] It is a real operator override — the GCC root clang is pointed
  at via `--gcc-toolchain`, read once at `01-core/cross-gcc.sh:45` with
  `gcc_toolchain_prefix()` as the default — and on 2026-09-04 it was given a
  `lint-env-knobs.allow` row saying, in as many words, that renaming it needs a
  build window. **That window is open.** Rename it to a project-appropriate name
  (`CROSS_GCC_TOOLCHAIN_PATH`), give it a `: "${NAME:=$(gcc_toolchain_prefix)}"`
  at its single reader, and delete the allow row in the same commit. Grep first:
  the only two occurrences in the tree today are the reader and the allow row, so
  the rename is a two-line change plus whatever an operator has in their shell.
* **`crlf-guard` flags `w/-text` wholesale with no escape hatch.** A tracked
  `*.sh` that was legitimately binary or held a NUL byte would fail the gate and
  there is no allowlist — `check_crlf_guard()` simply prints any `w/crlf`,
  `w/mixed` or `w/-text` row and returns 1. Census today is **316/316** `i/lf
  w/lf` over `*.sh`+`*.sh.tpl` (the gate's own file set is **319**), and a binary
  `*.sh` has no honest use here, so this is a shape to remember, not a fix to
  make.
* **The two `:NN-MM` offsets `cross-build-verification.md` quotes into the
  pre-commit hook are prose, not gated.** Two, not three — `:64-67` (the
  `_FAST_SLUGS` assignment) and `:78-95` (the staged-shell block); the third
  apparent hit is a `smoke-torch-venv.sh` reference. Both are accurate today and
  nothing re-derives them: grep for either span across `*.sh`/`*.py` finds
  nothing, and `tests/test-lint-shell-scope.sh` asserts existence and
  `--print-bin` facts only. The offsets into `preflight.sh` (the `KNOWN_SLUGS`
  span) now ARE gated, by `tests/test-preflight-slugs.sh` plus three mutations —
  that is the drift that actually recurred. Extending
  `tests/test-lint-shell-scope.sh` to re-derive the hook's two spans the same way
  is the cheap symmetric fix.
* **The pre-commit hook itself is outside the `shellcheck-warnings` ratchet.**
  `verify_shellcheck_warnings.py --files linux/host-config/git-hooks/pre-commit`
  answers `outside the lint-shell.sh scope, skipped` and exits 0. The hook is
  linted at `-S error` when passed explicitly, so warning-level regressions in the
  one file every commit runs are watched by nothing. Q8 located the asymmetry
  exactly: `lint-shell.sh` admits extension-less shebang scripts only for
  EXPLICITLY passed paths, so
  `git ls-files -z | xargs -0r lint-shell.sh --list-files` answers **319** files
  (hook included — that is how `crlf-guard` now reaches it) while the
  argument-less default sweep is **312** `*.sh` and the ratchet asks that one
  (`0 of 312 file(s)` in its own header). Give the ratchet the explicit-path set,
  or pass the hook explicitly from CI.
* **`tests/test-code-complexity.sh` still measures twice per legacy case.** **20**
  cases now use `_pins`, one gate run for both numbers; **eight** of the 15 older
  hand-built cases still call `_measure` twice for one fixture. Converting those
  eight halves the suite's remaining runtime but touches assertions existing
  mutations depend on; the other seven are single-metric and can stay.
* **`env-knobs` trailing-comment strip is not quote-aware — on the CONSUMERS side
  only.** `_scan()` strips with a flat `sed -E 's/[[:space:]]+#.*$//'`, so a knob
  read to the right of a ` #` inside a quoted string would be missed. The OWNERS
  side is **not** affected the way this bullet used to claim: owner shape (c) is
  the quote-aware awk `_Walker`, which only breaks on `#` while `S[top]=="code"`;
  only the small `: "${X:=}"` owner probe reuses the naive `_scan`. Zero such
  lines in the tree today (653 distinct tokens before the strip, 653 after), and
  the failure mode is a loud false-stale or a loud UNOWNED, not a silent pass.

### QW9. What the 2026-09-04 Q8 gate-scope wave left open [S–M each, ★–★★]

Ten follow-ups, all verified on the live tree at integration time. Nothing here
blocks the batch; every one is a gate that is honest about a limit rather than a
gate that lies.

* **The registry cannot express "a call site in the orchestrator".** [M, ★★]
  FOUR frozen ids now sit on this shape, not two — Q9's widened id rule made the
  two over the pre-commit hook visible as well
  (`mutations.hook-callsite-isolated`, `mutations.hook-runs-the-gate`,
  `mutations.preflight-callsite-isolated`, `mutations.preflight-runs-the-gate`).
  The names and the reasoning are owned by
  [`code-quality-tooling.md`](code-quality-tooling.md#the-allowlist); what is open
  is the RULE — `mutation_ids()` credits an entry only when its `target` is one of
  the slug's own files, never by its `test` command. Repro: delete a
  `mutation-id:` line and `verify_gate_registry.py` prints `mutations does not own
  linux/scripts/preflight.sh -- owned by crlf-guard`. Fix: credit an entry to the
  slug whose registered suite is its `test` command when the target is a shared
  orchestrator or a hook, and delete all four freeze lines in the same commit.

* **`own_files()` does not follow a `.sh` gate's shelled-out helper.** [S, ★★]
  It is `[rel] + imported_modules(rel)`, and `imported_modules` returns `[]` for a
  shell gate, so `linux/scripts/extract_embedded_python.py` belongs to no row:
  `python-lint.heredoc-python-decision` is a proven mutation credited to nobody.
  Q9's widened id rule at least made it LOUD — it is now reported off-convention
  and frozen under `mutation-id:` rather than passing unexamined. Repro: grep the
  `python-lint` row of [`code-quality-gates.md`](code-quality-gates.md) — it lists
  five ids, the manifest carries a sixth, and the freeze line is in
  `gate-proofs.allow`. Fix: let `own_files` follow a `.sh` gate's
  `python3 <x>.py` / `bash <x>.sh` invocations; that deletes the freeze and gives
  `python-lint` a sixth credited mutation. Deferred in Q9 only because it
  re-credits files other lanes were editing mid-wave — that wave is over, so the
  objection has expired.

* **The mutation gate re-runs a whole suite per entry.** [M, ★★★]
  One `subprocess.run(entry["test"])` per mutant inside a throwaway `mirror_tree`
  copy, capped at `PRECOMMIT_MUTATION_CAP:-6` and sampled newest-first. The half
  of the fix that says "one baseline per suite" **already landed** in `9a5bf8dd`
  (`baseline_ok()` caches per command string); what remains is process reuse for
  the mutants themselves. The ratio is the argument: **244** manifest entries over
  only **33** distinct suites. A one-file commit of a GATE script is not cheaper —
  staging only `verify_gate_registry.py` matches 21 entries whose six newest are
  all `test-gate-registry.sh` runs, more expensive than a 17-file commit whose six
  newest are cheap `test-doc-numbers.sh` runs; the sampling is newest-first, not
  cost-aware. **Re-measure before quoting timings here** — the 7.2 s / 2 m 45.9 s
  / 8 m 18.6 s figures were taken at 233 entries and are now stale-low. Repro:
  `PRECOMMIT_MUTATION_CAP=0 bash linux/host-config/git-hooks/pre-commit` with a
  diff staged.

* **Nothing runs the other ~238 entries between commit and CI.** [M, ★★]
  A pre-push hook is the right home — `--changed`'s existing semantics (everything
  committed since `origin/main`) are exactly right there, and a batch pays once
  instead of per commit. `linux/host-config/git-hooks/` holds exactly one file
  today. Blocked on `verify_gate_registry.py`'s `HOOK` constant being hard-coded
  to the pre-commit path: add a pre-push hook first and the generated table
  reports the `mutations` slug as CI-only, which is a false statement in a
  generated file. Generalise `HOOK` to a list, then add the hook.

* **The shell tokenizer now exists twice, in two languages.** [M, ★]
  `verify_code_complexity.py` (`shell_code` + `_Walker`) and the awk filter inside
  `lint-env-knobs.sh` both strip comments, quotes and heredoc bodies and both
  answer "is this token in command position". Not code duplication —
  `docs/scripts/verify_code_dupes.py` is clean (3206 units in 346 files, no block
  over 10 shared shingles) — but duplication of idea across a language boundary,
  kept because the env-knobs gate is a 0.4 s bash gate with no Python process to
  spare. Leave it; extract one owner only if a third consumer appears.

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
  already prints the exact `<tmpfile>\t<src>:<line>` table — verified again
  2026-09-04, e.g. `verify-manifest-freshness__29.py` → `…freshness.sh:29` — and
  `lint-python.sh` throws it away with `>/dev/null 2>&1`. Capture it and rewrite
  the prefix on a gate failure; it needs its own suite case plus a mutation
  because it changes the gate's output.

* **`extract_embedded_python.py | main | cc 16` is frozen "not yet reviewed".**
  [S, ★] Baseline 2026-09-03, untouched since. The file is now doubly
  load-bearing — it is the `python-lint` target set's discovery step and the
  target of the sixth `python-lint` mutation two bullets up — so promote it out of
  the freeze into the complexity queue. Nothing blocks it, and the two bullets
  above land in the same file.

* **`*.sh.tpl` is in no shell gate's scope, and a CRLF template generates a CRLF
  wrapper.** [S, ★] `lint-shell.sh` classifies the tree's one such file,
  `qemu-binary-wrapper.sh.tpl`, as "some other extension", so neither `shellcheck`
  nor `crlf-guard` (which derives its set from the same `--list-files`) sees it.
  It is `i/lf w/lf` today. Admitting it would also send an `@PLACEHOLDER@`
  template to shellcheck (it happens to parse today) — a call for the
  `lint-shell` owner, not something `crlf-guard` should answer differently.

* **`versions.env` cannot be sourced quietly.** [S, ★]
  Every `lint-python.sh` run prints `versions.env: line 407: 86: command not
  found` (three times) because `CUDA_ARCHITECTURES=80;86;89;90` is unquoted and
  sourcing it runs `86`, `89`, `90` as commands. Cosmetic, but it is stderr noise
  on a gate that runs in every hook. Quoting the value is the one-line fix, and
  the `01-core` freeze that deferred it ended with the 12:24 build — **do it in
  the next commit that touches `01-core`.**

### QW10. What the 2026-09-04 Q9 gate-hole wave left open [S–M each, ★–★★]

Six follow-ups. The wave itself closed the id-convention hole over non-gate
files, the env-knobs heredoc/env-prefix tokenizer holes, the unpinned SAMPLED
notice, the git-hook half of the embedded-Python target set, the mutation gate's
symlink write path, and the hand-typed doc numbers; `764a18a1` then closed the
four unpinned hook abort paths.

* **A fifth `exit 1` in the pre-commit hook is still undriven.** [S, ★]
  `764a18a1` pinned four abort paths (fast preflight, `shellcheck -S error`, the
  warning ratchet, `verify_doc_dupes.py`) with a case each plus a mutation each,
  and added an all-green case asserting rc 0 so the negatives prove something.
  The `no pinned shellcheck` refusal at `pre-commit:83` — the
  `lint-shell.sh --print-bin` failure path — is the one left: stub `--print-bin`
  to rc 1, one case, one mutation.

* **`mirror_tree` still copies escaping symlinks INTO the workspace.** [S, ★★]
  Refusing a symlink TARGET closes the write path, but the copy is made with
  `copy2(..., follow_symlinks=False)` and `COPY_EXCLUDES` does not list
  `docs/.venv`, so a test running inside the copy can still read or write through
  `docs/.venv/bin/python` → `/usr/bin/python3`. Exactly four symlinks exist in the
  copied tree, all under `docs/.venv`, and exactly one of them escapes. Skipping
  links whose resolved target falls outside `src` closes it (adding `docs/.venv`
  to `COPY_EXCLUDES` also works); nothing depends on `docs/.venv` outside the venv
  itself, but it changes mirror semantics, so it wants its own case in
  `test-mutation-gate.sh` rather than a drive-by. Repro: `ls -l` the
  `docs/.venv/bin` of any run's throwaway copy.

* **`$(( x << SHIFT ))` still reads as a heredoc delimiter.** [S, ★]
  Known limit of the env-knobs owner tokenizer, unchanged from the pre-2026-09-04
  regex: an unquoted delimiter only has to start `[A-Za-z_]`, which is what keeps
  `<<<` and `$(( a << 2 ))` out but cannot tell a NAMED shift apart. Probed
  2026-09-04 on a two-file fixture: `v=$(( 1 << SHIFT ))` swallows the rest of the
  file and its knobs lose their owner, while `v=$(( 1 << 2 ))` is fine. Nothing in
  the tree hits it — the only `<< name` shifts live inside
  `test-code-complexity.sh`'s own `<<'EOF'` fixtures, and an END-rule probe over
  all 296 scripts the owner scan reads finds no unterminated heredoc at EOF.
  Distinguishing it needs arithmetic-context tracking; left at parity rather than
  grown for a case with no instance.

* **Eleven `env-knobs` allow rows are REDUNDANT, not stale.** [S, ★]
  `APP_UV_LOCK`, `ARTIFACT_CONTEXT_MODE`, `ARTIFACT_CONTEXT_ROOT`,
  `BUILDKIT_CACHE_DIR`, `CROSS_CONTEXT_ROOT`, `CROSS_DISK_GUARD_GB`,
  `CROSS_LOCAL_CONTEXT_HANDOFF`, `CROSS_NO_PUSH_FORCE`, `NO_COLOR`,
  `SHELLCHECK_CACHE_DIR`, `UBUNTU_SOURCES_ROOT` are each consumed AND owned by a
  script assignment, so the gate calls them redundant and stays green. Still
  exactly eleven after `764a18a1` added five unrelated rows. All eleven were
  redundant before Q9 too, so this is a curation call, not fallout — and for most
  of them the "owner" is a test fixture setting the knob for one case, which is
  exactly why the documenting row is worth keeping. Decide, then delete or
  annotate; do not leave it implicit.

* **The per-suite ASSERTION counts in `code-quality-tooling.md` are not pinned,
  and one is already wrong.** [S, ★★] `test-doc-numbers.sh` derives the manifest
  totals and families, the hook's fast-slug count and its line span; no check
  reads a per-suite assertion count. Re-run on 2026-09-04: six of the seven still
  match, and `test-env-knobs.sh` reports **94** where the page says **90**. (The
  same page's dated census line — `643 | versions.env=174 | scripts=946 |
  allowlist=225` — also trails the live `644 / 176 / 948 / 226`, though that one
  reads as a snapshot.) The two honest options are the same two: drop the seven
  counts and let `run-tests.sh`'s aggregate speak — already the stated policy for
  the tree-wide totals in `cross-build-verification.md` — or teach
  `test-doc-numbers.sh` to derive them. Fix the 90→94 either way.

* **Five mutation ids stay frozen because two ownership rules are missing.** [S, ★]
  Renaming them is available and was deliberately NOT done: `mutations.hook-*` →
  `pre-commit.*` and `python-lint.heredoc-python-decision` → an `embedded-python`
  family would each drop a freeze, but a rename without deleting its
  `mutation-id:` line reports STALE and a deletion without the rename reports a
  prefix that cannot own the target — so the two halves must land together in one
  commit. The `pre-commit` family is now **12** ids over the same file (the four
  aborts of `764a18a1` included) and is already declared in `gate-proofs.allow`,
  which strengthens the rename. The `mutations.preflight-*` pair has no good
  family at all and waits on the call-site ownership rule in QW9.

**Two shapes to remember, not fix.** `test-mutation-gate.sh` pins two call-site
strings it does not own (`run_check mutations` in `preflight.sh`, and the hook's
`verify_mutations.py "${_only[@]}" ||` line) — reformatting either call site turns
the suite red with no behaviour change; that already happened once during this
wave and is the price of pinning a call site by reading it. And
`windows/scripts/patches/ffmpeg/makedef` entered the `crlf-guard` scope as a side
effect of the shared classifier: it is LF today, and a future CR there is a
Windows-backlog item, not a Linux-lane regression.
