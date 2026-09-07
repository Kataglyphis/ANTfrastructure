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
foreign-arch Vulkan SDK · **F#**=the size and duplication tracks. Everything else
is archive-only: **CC/CL/CS/AB/R#/YB/DISK/APP** closed on 2026-09-07,
**HT/GH** before them, **QW/TC/SMK** in the 2026-09-04 waves, and
**AP/TG/TS/GPU/DUP/PAR/SCC/BT/LOG/LB/C#/D#/P#/S#/XC#** long before that.

Last groomed: **2026-09-07, after the wave that answered the chain landed and the
thirteen entries it closed were moved to the archive.** Every number below was
re-derived from the gate or the log that produces it, never carried forward from
a lane's own report.

## ONE ENTRY IS OPEN, AND A BUILD DECIDES IT

Read this before anything else. The validating chain
(`chain-status.json` run `20260905-120554-7b7a0d4e`, then the 2026-09-07
`runtime` run) finished green and published a 3-arch `:latest-cross`. The wave
that followed it closed **thirteen** entries — CC1, CL1, VK1, AB1, APP1, CS1,
VK3, CS2, CS3, DISK3, R1, YB and F3 — and they now live in
[`…-archive-2026-09-07.md`](refactoring-backlog-archive-2026-09-07.md) with the
evidence that closed each one.

**What is left in this file is one open entry and two standing tracks.** VK2 is
open because only a build can close it. F1 and F2 are registers of reviewed
verdicts, not queues: nothing in them is a defect, and their job is to catch the
next growth rather than to be worked off.

**Everything that wave landed is unproven by any build.** It is proven by gates
and unit suites on an idle tree, which is worth exactly what the 2026-09-05
experience says: a first rebuild attempt found two build-killing bugs (HEAD
`e109f5ad`) in minutes after a full green battery. Assume the next chain finds
more, and read **[`build-watch-list.md`](build-watch-list.md)** while it runs.

### Next up — everything above is landed; what is left is ONE build

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

**Honesty about the rest:** no OPEN entry names a defect with a known failure mode.
What is left is one owner decision, two cheap wins, a ratchet, a guard that needs a
lever it does not have, and three tracks.

### What needs the OWNER, not the agent

**One real decision, and it is CS1** (see Next up 1): whether the foreign images
keep `/opt/vulkan/<ver>/x86_64`. The bytes are unrunnable there and the prune ships
wired, but the owner has twice said not to remove Vulkan payload, so it stays until
they say otherwise. Everything else below is context, not a block:

1. **`git push` is no longer yours** (2026-09-06). The agent pushes and pulls now.
   The `~/.ssh/id_ed25519` key is NOT registered with GitHub — it fails with
   `Permission denied (publickey)` — so the path is `gh auth setup-git` plus HTTPS
   remotes, which is local config and touches no account setting. Pull with
   `--rebase`, stash `chain-status.json` first (always dirty, never staged), and a
   rebase needs `-c core.hooksPath=/dev/null` because the hooks run on commit.
   The pre-push hook is no longer theoretical: it fired on real pushes and caught
   two mutations left stale by upstream refactors, which is exactly its job.
2. **Downstream consumers of `linux/scripts/lib/`.** The nine libraries source a
   sibling, `lib/log-bootstrap.sh`. Any full ContainerHub checkout satisfies that —
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
5. **A newer QNN SDK, if you want one.** v2.49.0.260730 is pinned, hashed and
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

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are fully reviewed: **29** function rows over 80 lines
and **66** `cc` rows over 15 on the 2026-09-05 integrated tree, every one carrying a
verdict that says what its number IS. Read the reasons, not the numbers.

**Closed 2026-09-05, and both allow rows DELETED rather than re-baselined:**
`verify_doc_dupes.py main` 81 → 47 lines, cc 23 → under the limit, decomposed into
`_index_paragraphs` / `_collect_shared` / `_print_report` / `_print_findings` /
`_print_bookkeeping` — mirroring `verify_code_dupes.py`'s helper names rather than
inventing a second vocabulary, and proven BYTE-IDENTICAL over the whole docs tree in
all four output shapes (`--report` at thresholds 8, 12 and 20 plus the plain run,
i.e. the findings, clean and stale-allowlist exit paths). And
`slang_compile_combined_wgsl` 87 → 45, with the `while read` body now
`_slang_emit_one_wgsl` returning 0 copied / 1 emit failed / 2 rejected by the
varying validator / **3 source absent** — a fourth outcome the entry had not counted.
Its `dead-functions.allow` row for `slang_compile_main` went stale in the same change
and is gone, because the new suite drives the real entry point. The suite is a true
characterisation: it passes UNCHANGED against `git show HEAD:…/slang-compile.sh`.

**Closed 2026-09-04:** `cmake_build_parse_args` 116 → 60 lines and cc 31 → 24 (the
Vulkan flag > env > caller-default chain is now `_cmake_build_resolve_vulkan`, with
its precedence written up in
[`shared-script-libraries.md`](shared-script-libraries.md) and three mutations
holding it); `verify_package_names.py` `main` 140 → 34 and `scan_file` 93 → 7, both
from **cc 42** to 7-and-gone, with `--list` output over the whole tree proven
byte-identical before and after.

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
* **KEPT: `media_common_init` (35)** — a module loader whose load ORDER is
  load-bearing. A table plus a loop would read shorter and say less; the
  ordering is the knowledge. Not a free win, and recorded as such.

**CLOSED 2026-09-05 — `smoke-cross-all-arches.sh main`**, which this entry had
nominated as the best-shaped candidate left. 96 → 22 lines, cc 23 → under the limit,
four `_smoke_probe_*` helpers plus `_smoke_clang_match_arch`, and **both** allow rows
DELETED rather than re-baselined. Two things from how it went are worth keeping. The
output was proven **byte-identical to HEAD, with equal exit codes, over 20 input
shapes** — five arch-list forms and five clang triples × three arch lists — which is
what a characterisation of a shipped probe should look like. And the clang section's
"matches none of" branch, the one this entry asked for, **did not exist at all**: a
target clang built for the wrong arch shipped green. Pinning it meant writing the arm
first. `SMOKE_TARGET_CLANG` exists so a host suite can drive the real probe instead of
a rewritten copy; it self-defaults in the script, so nothing in the image sets it and
the env-knob registry needs no row.

**With that closed there is no outside-the-closure candidate left on the size queue.**
Every remaining named row is inside the build closure.

**Two rows carry a "do not do the obvious thing" verdict.** `verify_comment_size.blocks`
(nesting 6): the honest fix is importing `verify_code_size.scan` like every other
extent gate, but that WIDENS the scan to `docs/scripts` and NARROWS it by
`SKIP_DIRS 'patches'` — it changes the gate's scope and needs a fresh
`comment-size.allow` baseline, which is different work from a nesting trim. And
`verify_package_names.load_arch` (17): every branch is a way the gate must not
produce a FALSE verdict, the all-or-nothing partial-fetch refusal above all.

**The one uncovered path left inside `_cross_stage_build_impl` is the
registry-cache drop** — lines 295–317, **23** lines. It needs a non-empty
`log_file` whose tail matches `DeadlineExceeded|httpReadSeeker`, and it mutates
both `build_cmd` and `_regcache_fails` across retry iterations. Nothing covers it:
`grep -rn DeadlineExceeded linux/scripts/tests/` returns nothing, and
`test-cross-stage-build-cmd.sh` only counts `cache-from`/`cache-to` on the
non-failing path. Write the characterisation first — fake `log_file`, assert the
counter reaches 2 and that the registry cache pairs vanish from `build_cmd` while
local cache args survive — then extract. Re-checked 2026-09-05: still uncovered.

**CLOSED 2026-09-07 — the harness now catches that trap.** `t_assert_ok` and
`t_assert_fails` take a COMMAND and no message, so `t_assert_fails test -f X "msg"`
ran `test -f X msg`, which exits **2** — "not zero", i.e. the failure the case
asked for, for entirely the wrong reason. Four of those were written and caught by
review in one wave. Both assertions now share `_t_assert_run`, which fails the case
BY NAME when the command is `test`/`[` and the rc is 2. The guard is deliberately
narrow: a real command that exits 2 is still judged on its exit code, and a
mutation widening it to every rc 2 is caught. `test-harness-guards.sh` is the suite
(12 assertions), and the whole corpus was re-run against the stricter harness —
no existing case relied on the old behaviour.

**`_chain_stage_disk_guard`'s two eviction loops CLOSED 2026-09-07** with DISK3:
one `_chain_evict_slugs` owner, cc 30 → 21.

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

**One row IS a real split, and it is NO LONGER BLOCKED.** `lib/agentic-loop.sh` is
two subjects wearing one name — engine adapters and the loop driver — and it is
outside the build closure, so it can be cut at any time. The blocker this entry named
("nothing covers it") is gone: `test-agentic-loop.sh` landed 2026-09-05 with **24
assertions** and six mutations, covering exactly the three cases the row asked for —
engine-config precedence, `invoke_agent`'s retry ladder with both engine adapters
faked, and one drain of the executor queue — plus the blocked-task case that pins why
blocked work is deliberately not queue depth.

The split itself was deliberately NOT made in the same wave: a second lane held the
file that session (a `trailing-conditional` fix inside `invoke_agent`'s retry loop),
and a two-file split would have destroyed their edit on merge. The seam is clean and
the next pass is a straight move — adapters (`load_engine_config`,
`agent_timeout_for_role`, `agent_stream_passthrough`, `claude_stream_render`,
`invoke_opencode`, `invoke_claude`, `usage_limit_wait_seconds`, `invoke_agent`;
roughly lines 89–420) into `lib/agentic-engines.sh`, sourced the way
`lib/log-bootstrap.sh` already is, leaving the loop driver from line 423 on. The new
suite covers both halves across the seam. **DONE 2026-09-05** — the split landed
exactly as described (874 → 512 plus a 355-line `lib/agentic-engines.sh`), the
`file-size.allow` row was DELETED rather than re-baselined, and the 24 pre-existing
assertions passed unchanged across the seam, which is what makes it a true
characterisation. The `&&`-shape defect found in this file while writing that suite
closed with CL7; note its correction, though — the failure mode did NOT reproduce,
because bash exempts every command of an AND-OR list but the last.

**Two verdicts worth not re-litigating.** `build-app-wheelhouse.sh` is the
near-miss: the stage suites extract blocks from it **by line range**, so a file
split silently re-aims them. And `smoke-runtime-image.sh` — which every earlier
version of this entry nominated as THE one to split — is an explicit **NO**: 63
functions, all `check_*` / `_probe_*` over one image through one `_rt_run` under one
`main()`. Its length is the number of assertions it makes about the shipped bytes,
and that number growing is the gate succeeding.

**Closed 2026-09-05:** `docs/scripts/sync_versions.py` had NO module docstring at all
— shebang straight into `from __future__` — despite being the authority for the
version-propagation ritual. It now states its six consumers, why `--write` does the
Dockerfiles FIRST (the snapshot reads its numbers back out of them, so the other
order needs two passes), and that a malformed marker fails BOTH modes; it ends at
`cross-build-verification.md#pre-flight`, which is where the `version-snapshot` slug
is actually documented — the honest anchor the row said did not exist. Its
`file-size.allow` row moved 849 → 873. The not-a-split verdict above it is unchanged.

**Three rows grew by one or two lines on 2026-09-05 and are recorded as such:**
`build-gcc.sh` 880 → 881, `build-opencv.sh` 935 → 936 and
`build-app-wheelhouse.sh` 1246 → 1248, all from YB's `compiler_cache_launcher_env`
call at the launcher-resolution site. `smoke-runtime-image.sh` also moved; its own row
carries both lanes' reasons.
