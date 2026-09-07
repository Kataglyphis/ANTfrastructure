# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md),
[`…-archive-2026-09-02.md`](refactoring-backlog-archive-2026-09-02.md),
[`…-archive-2026-09-03.md`](refactoring-backlog-archive-2026-09-03.md),
[`…-archive-2026-09-07.md`](refactoring-backlog-archive-2026-09-07.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary (only the prefixes this OPEN file still uses): **VK**=the
foreign-arch Vulkan SDK · **EX**=the extent gates' scope · **F#**=the size and
duplication tracks. Everything else
is archive-only: **CC/CL/CS/AB/R#/YB/DISK/APP** closed on 2026-09-07,
**HT/GH** before them, **QW/TC/SMK** in the 2026-09-04 waves, and
**AP/TG/TS/GPU/DUP/PAR/SCC/BT/LOG/LB/C#/D#/P#/S#/XC#** long before that.

Last groomed: **2026-09-07 (second pass), after an audit re-derived every number
in this file from the gate that produces it.** The first pass that day claimed the
same thing and had not done it: `29` function rows and `66` cc rows were the
2026-09-05 figures carried through a wave that deleted rows underneath both (real:
**28** and **61**), `media_common_init` was quoted at cc 35 after CL7 took it to 29,
`verify_package_names main` at 34 lines when it is 30, "the nine libraries" when ten
source `log-bootstrap.sh`, and `smoke-runtime-image.sh` at "63 functions, all
`check_*`/`_probe_*`" — 91 and 45, a number true of no revision. Two entries had
outlived their evidence by a single commit: the registry-cache drop was called
uncovered after `d7fbfd39` characterised it, and CS1 was listed as the open owner
decision in the same file that links its closure. **Re-derive; do not trust a number
here, including these.**

**This file is not a record of the whole repo.** `main` moved past the first pass
23 minutes after it landed: a merge (`d6fa512f`) brought in the NAS document-AI
stream — `nas_census.py`, its suite, `nas-document-ai.md` and a 77-file document-VLM
benchmark run — and nothing in this file knew. That merge also arrived red: three
`census.*` mutations with no declared family, mutation totals left stale in
`code-quality-tooling.md`, two broken `§` links, and 68 committed benchmark files
that put 66 model-output JSONs back inside the doc-links scan. All four are fixed;
the lesson is that a grooming is only true of the commit it was written at.

## TWO ENTRIES ARE OPEN: ONE NEEDS A BUILD, ONE NEEDS A SCOPE DECISION

Read this before anything else. The validating chain
(`chain-status.json` run `20260905-120554-7b7a0d4e`, then the 2026-09-07
`runtime` run) finished green and published a 3-arch `:latest-cross`. The wave
that followed it closed **thirteen** entries — CC1, CL1, VK1, AB1, APP1, CS1,
VK3, CS2, CS3, DISK3, R1, YB and F3 — and they now live in
[`…-archive-2026-09-07.md`](refactoring-backlog-archive-2026-09-07.md) with the
evidence that closed each one.

**What is left in this file is two open entries and two standing tracks.** VK2 is
open because only a build can close it. **EX1 is new on 2026-09-07**: the extent
gates do not scan `linux/llm-stack` at all, so F1's and F2's registers have never
been able to see a fifth of the repo's Python. F1 and F2 themselves are registers of
reviewed verdicts, not queues: nothing in them is a defect, and their job is to catch
the next growth rather than to be worked off — within the scope they are given, which
is the part EX1 is about.

**Everything that wave landed is unproven by any build.** It is proven by gates
and unit suites on an idle tree, which is worth exactly what the 2026-09-05
experience says: a first rebuild attempt found two build-killing bugs (HEAD
`e109f5ad`) in minutes after a full green battery. Assume the next chain finds
more, and read **[`build-watch-list.md`](build-watch-list.md)** while it runs.

### Next up — one build, and one scope decision that needs no build at all

The 2026-09-07 chain ran green end to end and published a 3-arch `:latest-cross`
(`manifest-freshness PASS`). The wave that followed it closed every OPEN entry
this file carried. What remains is not a queue, it is a **verification**:

1. **Run a compile-heavy chain — that is the whole list.** Everything below was
   landed against a green static battery and an idle tree, and nothing here has
   been through a real build:
   * **VK2** wired four components that have never cross-built (`vulkan-profiles`
     and its two config packages, `gfxreconstruct` behind `CMAKE_LIBRARY_ARCHITECTURE`,
     `slang` behind the host generators, `vulkanCapsViewer` behind target Qt6).
     The entry stays OPEN until `<arch>/bin` shows them.
   * **VK3**'s two `>=` floors get promoted to exact counts from that run's
     `RATCHET: floor 20 -> N` line, and the four `_VK_REPORTED_TOOLS` names move
     into the required set in the same edit — once, not twice.
   * **DISK3**'s image lever has never fired in anger; the `[disk-images]` lines
     are what to read.
   * **CS3**'s prebuilt download replaces ~1900 s of QEMU on arm64 and riscv64
     keeps the source build. The runtime lane's `OK: … installed from the upstream
     … release binary` line is the proof.
   * **R1.1**'s llvm-target walk should read `0 of 142` on amd64 and `0 of 127`
     on the foreign pair.
2. **Then re-groom this file against that run**, the way the 2026-09-05 grooming
   re-derived every number from the gate that produces it. Four figures did not
   survive that exercise last time; assume some will not survive the next.

**Nothing else is open.** No entry in this file names a defect with a known
failure mode, and the two things that are genuinely not the agent's are below.

**Image sizes from this run**, which CC1 asked for at three groomings and never got:

| arch | before | after | delta |
| --- | --- | --- | --- |
| amd64 | 30.37 GB | **34.35 GB** | +3.98 |
| arm64 | 30.84 GB | **28.73 GB** | −2.11 |
| riscv64 | 29.69 GB | **25.04 GB** | −4.65 |

Read them together, as that entry asked. The foreign arches shrank because HT5's
prune drops the builder-arch prefix there; amd64 grew because nothing is pruned on
its own arch and it gained the Flatpak runtimes (~1.9 GB), the web-lane toolchain
and the nightly channel. VK1's fifteen cross-built components push the target prefix
back up, which is why arm64 landed at 28.73 rather than the ~24.9 the pre-VK1
estimate predicted. The estimate was not wrong; it was made before those components
existed.

**Honesty about the rest:** neither open entry names a defect with a known failure
mode — EX1 names a blind spot, not a bug.
What is left is **one open entry (VK2) and two registers (F1, F2)** — the same
inventory the section above gives. Earlier groomings carried a second, longer count
here ("one owner decision, two cheap wins, a ratchet, a guard that needs a lever it
does not have, and three tracks") that matched nothing in the file.

### What needs the OWNER, not the agent

**No decision is outstanding.** CS1 — whether the foreign images keep
`/opt/vulkan/<ver>/x86_64` — was the last one, and the owner decided it on
2026-09-07: keep pruning. It is closed in
[`…-archive-2026-09-07.md`](refactoring-backlog-archive-2026-09-07.md#cs1-closed--the-owner-decided-and-the-prune-stays-scharf-done-2026-09-07),
and the −2.11 GB on arm64 and −4.65 GB on riscv64 in the table above IS that prune.
This section carried it as open until 2026-09-07, in the same file that already
linked its closure. Everything below is context, not a block:

1. **`git push` is no longer yours** (2026-09-06). The agent pushes and pulls now.
   The `~/.ssh/id_ed25519` key is NOT registered with GitHub — it fails with
   `Permission denied (publickey)` — so the path is `gh auth setup-git` plus HTTPS
   remotes, which is local config and touches no account setting. Pull with
   `--rebase`, stash `chain-status.json` first (always dirty, never staged), and a
   rebase needs `-c core.hooksPath=/dev/null` because the hooks run on commit.
   The pre-push hook is no longer theoretical: it fired on real pushes and caught
   two mutations left stale by upstream refactors, which is exactly its job.
2. **Downstream consumers of `linux/scripts/lib/`.** Ten of the thirteen files in
   `lib/` source a sibling, `lib/log-bootstrap.sh` — every one but that file itself
   and the two `agentic-*` halves. Any full ContainerHub checkout satisfies that —
   which is how [`adopting-in-a-new-project.md`](adopting-in-a-new-project.md) says
   to consume them — but a consumer that copied ONE `lib/*.sh` file out on its own
   breaks on its next CI run, not here.
3. **`06-packaging/package_archive.sh` — does it have a consumer?** Nothing in this
   repo invokes it and no Dockerfile copies it, so no build will ever answer
   anything about it. `ResolvedBinary` is provably dead, but `--appdata-file`,
   `--app-id` and `--appimage-extract-and-run` are a CLI CONTRACT whose only possible
   callers live outside this repo: dropping the flags turns a silent no-op into
   `Unknown argument` plus a mis-shifted operand. If no external consumer exists,
   delete the script. Its `shellcheck-warnings.allow` row stays at 4 until someone
   answers.
4. **The Windows lane.** Six confirmed doc defects from the 2026-09-03 currency
   audit are parked in
   [`windows-refactor-backlog.md`](windows-refactor-backlog.md), verified against
   the tree only. Three of the six are wrong paths a reader would follow into a
   "file not found" (`Test-HostSetup.ps1`, `Test-Health.ps1`,
   `Dockerfile.toolchain`); the fourth is the QNN version contradiction at
   `README.md:204`. Also unresolved:
   `windows/scripts/tests/Pins.CanonicalValues.Tests.ps1` reads `CUDA_ARCHITECTURES`
   from `versions.env` via `Get-Pin` and asserts `80;86;89;90`, and that value is now
   QUOTED (it had to be — an unquoted `;` ran its own tail as commands on every plain
   `source`). `load_versions_env`, `sync_versions.py` and `bump_versions.py` all strip
   one surrounding pair and were proven byte-identical; whether `Get-Pin` does was not
   testable from this host. One PowerShell run answers it.
5. **The `version-snapshot` sub-check that has never checked anything.** The
   audit found `sync_versions.py`'s `check_script_defaults` glob matching no file:
   the PowerShell build scripts have been `windows/scripts/**/Build-*FromSource.ps1`
   since the Verb-Noun rename, so ten scripts are silently not gate subjects. It is
   recorded here and **deliberately not fixed** — the subjects are Windows-lane
   files, and the standing rule for a repo-wide gate tripping over
   `windows/` is to note it and leave it to
   [`windows-refactor-backlog.md`](windows-refactor-backlog.md).
6. **A newer QNN SDK, if you want one.** v2.49.0.260730 is pinned, hashed and
   validated end to end. Only a *newer* SDK needs a re-pin, and only you can fetch
   it (login-gated).

### VK2. WIRED — all four have a route now, and one of them is not a route [M, ★★★]

The four components that did not cross-build on 2026-09-05 are addressed in the
tree; **no chain has run since**, so this stays OPEN until one does. The routes,
and what the arm64 log actually said:

**1. `vulkan-profiles` — DONE, two table rows.** `find_package(valijson)` found
nothing because `jsoncpp` and `valijson` are built by `./vulkansdk` into
`source/<comp>/build/install` and had no row of their own. Both are rows in
`_VK_TARGET_COMPONENTS` now, ahead of `vulkan-profiles`.

**2. `gfxreconstruct` — DONE, and the cause was NOT the missing packages.** The
lane already had `libx11-dev:arm64`, `libzstd-dev:arm64` and the whole XCB set
unpacked, and CMake still reported `Could NOT find ZSTD / X11 / OpenGL / JsonCpp`:
multiarch puts them in `/usr/lib/<triplet>`, which `find_library` only searches
when `CMAKE_LIBRARY_ARCHITECTURE` says so. `_cross_build_sdk_component` passes it
for every row now. The genuinely missing half was GL — `libgl-dev`, `libglx-dev`,
`libopengl-dev`, `libegl-dev` — which goes in through
`install_optional_target_packages` so a ports arch that lacks one degrades a
component instead of the stage.

**3. `slang` — DONE, the Canadian cross this repo already does.** The build cross-
compiled its own generators and then ran them: `FAILED: [code=127]
prelude/slang-cpp-host-prelude.h.cpp`. The host `./vulkansdk` run leaves them in
`source/slang/build/generators/Release/bin`, so `_vulkan_target_dynamic_args`
points `SLANG_GENERATORS_PATH` there, with `SLANG_SLANG_LLVM_FLAVOR=DISABLE` and
`SLANG_ENABLE_DXIL=OFF` to stop the same build fetching x86_64 prebuilts.

**4. `vulkanCapsViewer` — DONE, target Qt6 + host moc.** `qt6-base-dev:${arch}`
in the optional set, `QT_HOST_PATH=/usr` and a `CMAKE_PREFIX_PATH` that carries
the sysroot's Qt.

**The `dx*` family is NOT a row, and the earlier entry was wrong about why.** It
is not "host-only", and it is not a tblgen-shaped Canadian cross either; the
measured reason and what cross-building it would actually cost are in
[`vulkan-foreign-arch-sdk.md`](vulkan-foreign-arch-sdk.md#components-that-need-a-host-tool).

**What closes this entry:** one chain. `<arch>/bin` must carry everything
`x86_64/bin` does that is not structurally host-only, and the four names above
are what the runtime smoke's `_VK_REPORTED_TOOLS` now warns about until they
arrive. docs/vulkan-foreign-arch-sdk.md

### EX1. The extent gates cannot see `linux/llm-stack` [M, ★★★]

**`verify_code_size.py:38` reads `SCAN = ("linux/scripts", "linux/host-config",
"docs/scripts")`**, and `verify_code_complexity.py`, `verify_dead_functions.py` and
`verify_trailing_conditional.py` all take their scope from it. `linux/llm-stack` is
not in that tuple and never has been. It holds **43 Python files, 19,874 lines**, it
is under active development, and a 569-line file (`nas_census.py`) landed there on
2026-09-07 without any extent gate seeing it.

What is actually over the limits there, measured 2026-09-07 and frozen nowhere:

| | count | worst |
| --- | --- | --- |
| files > 800 lines | 7 | `bench_coding.py` **2022** — second-largest .py/.sh in the repo |
| functions > 80 lines | 13 | — |
| `cc` > 15 | 25 | — |
| nesting > 5 | 1 | depth **8** |

`bench_coding.py` at 2022 lines is longer than every file in `file-size.allow` except
`smoke-runtime-image.sh`, and unlike that one it has never been reviewed for a
split-or-not verdict. **This is why F1's "no outside-the-closure candidate left" was
wrong in a second way**: the sweep was true of the scan set, and the scan set is not
the repo.

**What closes it is a decision, not a patch.** Adding one directory to `SCAN` makes
~46 rows appear at once, and this repo's convention — set on 2026-09-03, when wave 2
replaced every bare baseline with a verdict — is that an allow row states *what its
number IS*, not merely that it was there when the gate was switched on. Writing 46
honest verdicts over a benchmark harness nobody has reviewed for shape is its own
wave. The options, in the order I would take them:

1. **Widen `SCAN` and do the verdict pass.** Correct, and the only option that makes
   the register mean what it says. Costs one wave.
2. **Widen `SCAN` for files only** (the 7-row table above), leaving functions and cc
   for later. Cheap, and it catches the growth that matters most.
3. **Declare `linux/llm-stack` deliberately out of scope** and say so in
   `verify_code_size.py`'s header and in F2 — defensible if the benchmark harness is
   held to a different standard than the build closure, but it must be *written down*,
   because right now the exclusion is silent and reads as an oversight.

Not option 4: leaving it. A gate whose scope nobody stated is the shape this repo
has been bitten by twice — the `file-size.allow` header that said "Shell files" while
scanning Python, and the doc-links floor that only applied when git was absent.
[`code-quality-tooling.md`](code-quality-tooling.md#code-size--functions-and-files-code-size)

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are fully reviewed: **28** function rows over 80 lines
and **61** `cc` rows over 15, every one carrying a verdict that says what its
number IS. Read the reasons, not the numbers — and re-derive the counts from
`verify_code_size.py` / `verify_code_complexity.py`, never from this line. It
said 29 and 66 until 2026-09-07 because the 2026-09-05 figures were carried
forward through the very grooming that claimed to have re-derived them, while
the wave in between deleted rows underneath both.

**Closed 2026-09-05, both allow rows DELETED:** `verify_doc_dupes.py main` and
`slang_compile_combined_wgsl`. Evidence in the archive.

**Closed 2026-09-04:** `cmake_build_parse_args`, `verify_package_names.py`
`main`/`scan_file`. Evidence in the archive.

**Four measurement facts that decided most of the remaining verdicts**, and that a
future reader should not re-discover:

* **Heredoc payloads are not shell.** `assert_pinned_versions` is 44 lines of shell
  around a **312**-line embedded Python program — top of the size queue and the
  WORST candidate on it, because splitting the shell moves 44 lines and its `cc` is
  **7**. Same shape: `assert_app_venv_parity` (20 around 72),
  `_gst_xpy_write_config` (14 around 70), `ensure_meson_cross_file` (56 around a
  37-line Meson-ini template).
* **Much of the `cc` here is a TABLE, not tangle**: flag and subcommand parsers
  (`parse_tvm_args` 13 options, `append_tvm_cmake_args` 15, `setup-dependencies.sh`
  `main` 5 flags × 10 commands), feature tables (`_ffmpeg_probe_core_codecs` is
  sixteen `if probe; then --enable-<codec>` lines and nothing else), and two rows
  where the metric is simply literal — `dump_debug_info` (cc 23) contains no
  decision at all, just ~20 which-then-`--version` pairs each swallowed, and
  `_torch_run_setup_py` counts the size of torch's build environment.
* **Refusal matrices cost safety when flattened**: `_chain_prune_archived_logs`
  (every branch is a refusal to delete the wrong thing), `_manifest_wrapper_gate`
  (the cell that decides whether a manifest would MIX releases),
  `install_target_packages`, `override_soundtouch_codeberg_checksum`.
* **Precedence ladders where the ORDER is the contract**: `host_python_bin`,
  `install_abseil_headers`' five download/extract rungs, `_detect_gcc_cxxabi_header`,
  `configure_opencv_build_env`'s gstreamer-libdir search (the RV1-GST-PC ladder).

**The rows that WERE debt: five of six cut on 2026-09-07, one kept with its
reason.** Each had named its own seam, and each seam held:

* `_opencv_target_adjustments` (cc 33, 114 lines) — the two riscv64 workarounds
  became `_ota_riscv64_freetype` and `_ota_riscv64_png`, exactly the seams this
  row named. It is now under BOTH limits and **both allow rows are deleted, not
  re-baselined**. `test-opencv-riscv64-seams.sh` pins the two decisions that
  matter and are testable off-target: nothing staged → the named fallback with
  the four-file WARN, and no external libpng → `exit 1` rather than a silent
  `WITH_PNG=OFF` (fail-LATE there cost iree-0714a..e).
* `_chain_stage_disk_guard` (28) — closed with DISK3: one `_chain_evict_slugs`,
  cc 30 → 21.
* `_cgroup_mem_remaining_mb` (20) — the same four tests twice over cgroup v1 and
  v2 now share `_cgroup_remaining_mb_from`; the two generations differ only in
  their paths and in how each spells "no limit" (v2 the literal `max`, v1 a
  kernel-huge number or 0). Under the limit, row deleted, and the
  `parallelism.sh` self-pair fell out of `code-dupes.allow` with it. `CGROUP_ROOT`
  exists so the suite can stand a fixture in for absolute kernel paths — that is
  what made this untestable before.
* `_gst_rs_build_plugins` (25) — the five copies of the exclusion PREAMBLE (log
  the reason, prune the workspace member, exclude the family) have one owner,
  `_gst_rs_exclude`. **The cc did not move, and that is the point**: it counts the
  six predicates, and each of those is separately earned knowledge about one
  arch/plugin pair. The row stays, with that reason.
* `build-runtime-manifest.sh main` (22, 90 lines) — the build-only phases are
  `_manifest_build_and_smoke` behind ONE `BUILD_IMAGES -eq 1` test instead of the
  same test in front of three. Under both limits, both rows deleted, and the
  suite now asserts that no build-only phase has drifted back into `main()` —
  which is the thing `--manifest-only` and `--repair` exist to avoid.
* **KEPT: `media_common_init` (29, was 35 until CL7 deleted the unreachable
  `cross_build_is_active` clone)** — a module loader whose load ORDER is
  load-bearing. A table plus a loop would read shorter and say less; the
  ordering is the knowledge. Not a free win, and recorded as such.

**Closed 2026-09-05:** `smoke-cross-all-arches.sh main`, which this entry had
nominated as the best-shaped candidate left. Evidence in the archive.

**Two outside-the-closure rows survive that sweep**, and the earlier flat "none
left" was wrong. `run_agentic_loop` (95 lines) — seam named, and the coverage that
blocked it landed with F2's split, so this one is takeable today.
`bump_versions.py main` (159) — still blocked on coverage, because it WRITES
`versions.env` and checksums and nothing drives it. Every other named row is inside
the build closure — **within the scan set**, which is the qualifier the sentence
always needed: see **EX1** for the fifth of the repo's Python these gates cannot see
at all.

**Two rows carry a "do not do the obvious thing" verdict.** `verify_comment_size.blocks`
(nesting 6): the honest fix is importing `verify_code_size.scan` like every other
extent gate, but that WIDENS the scan to `docs/scripts` and NARROWS it by
`SKIP_DIRS 'patches'` — it changes the gate's scope and needs a fresh
`comment-size.allow` baseline, which is different work from a nesting trim. And
`verify_package_names.load_arch` (17): every branch is a way the gate must not
produce a FALSE verdict, the all-or-nothing partial-fetch refusal above all.

**Closed 2026-09-07: the registry-cache drop is characterised** — `d7fbfd39`, four
cases in `test-cross-stage-build-cmd.sh`. **Still open:** the optional extraction of
those lines into a named helper, now with a suite as the safety net. Archive carries
why the entry claimed the opposite for one commit too long.

**Closed 2026-09-07:** the `t_assert_fails test -f X "msg"` trap — both assertions
share `_t_assert_run` now. Evidence in the archive.

**Closed 2026-09-07:** `_chain_stage_disk_guard`'s two eviction loops, with DISK3.

### F2. Files over ~800 lines [L each, low priority]

**`file-size.allow` is the authority — do not transcribe it here.** The eleven-row
table that used to sit in this entry was wrong within a day of being written, twice.
This entry's prose then broke its own rule again on 2026-09-04 by quoting
`smoke-runtime-image.sh` at 1739 when the allow file had carried the correct number
and the reason all along. The gate prints `files: 11 over 800 lines; 11 frozen`;
read it there.

**All rows were reviewed 2026-09-04 and all but one are NOT split targets**, each with
a reason a stranger can act on. The file's own HEADER was the thing that had stopped
measuring what it claimed — it said "Shell files currently over the size limit"
while three of ten rows are `docs/scripts/*.py` and `linux/Dockerfile.media`, two of
those carrying the copy-pasted reason "newly in scope (python/Dockerfile)". Header
corrected to state `verify_code_size.py`'s actual scope.

**The one row that WAS a real split is DONE (2026-09-05).** `lib/agentic-loop.sh`
was two subjects wearing one name — engine adapters and the loop driver. It went
874 → 512 plus a 355-line `lib/agentic-engines.sh`, its `file-size.allow` row was
DELETED rather than re-baselined, and `test-agentic-loop.sh`'s pre-existing
assertions passed unchanged across the seam, which is what makes it a true
characterisation. Evidence in the archive. **No row in `file-size.allow` is a split
target today** — but see **EX1**: seven files over 800 lines in `linux/llm-stack`
have never been in this register's scan set at all, so "no split targets" is a
statement about the scan set, not the repo.

**Two verdicts worth not re-litigating.** `build-app-wheelhouse.sh` is the
near-miss: the stage suites extract blocks from it **by line range**, so a file
split silently re-aims them. And `smoke-runtime-image.sh` — which every earlier
version of this entry nominated as THE one to split — is an explicit **NO**: 91
functions, of which 45 are the `check_*` / `_probe_*` assertions and the rest is the
probe-and-verdict layer they share, all over one image through one `_rt_run` under
one `main()`. Its length is the number of assertions it makes about the shipped
bytes, and that number growing is the gate succeeding. ("63 functions, all of them
`check_*`/`_probe_*`" stood here and in `file-size.allow` until 2026-09-07 and was
never true of any revision.)

**Closed 2026-09-05:** `sync_versions.py`'s missing module docstring. Evidence in
the archive — including that the docstring it gained said *six* consumers when
`--check` runs seven, corrected 2026-09-07.

**Three rows grew by one or two lines on 2026-09-05 and are recorded as such:**
`build-gcc.sh` 880 → 881, `build-opencv.sh` 935 → 936 and
`build-app-wheelhouse.sh` 1246 → 1248, all from YB's `compiler_cache_launcher_env`
call at the launcher-resolution site. `smoke-runtime-image.sh` also moved; its own row
carries both lanes' reasons.
