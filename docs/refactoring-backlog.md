# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document. Every item here is OPEN. Completed/obsolete items and the
observation journal live in the archives:
[`…-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md),
[`…-archive-2026-08-27.md`](refactoring-backlog-archive-2026-08-27.md),
[`…-archive-2026-08-30.md`](refactoring-backlog-archive-2026-08-30.md),
[`…-archive-2026-08-31.md`](refactoring-backlog-archive-2026-08-31.md),
[`…-archive-2026-09-02.md`](refactoring-backlog-archive-2026-09-02.md),
[`…-archive-2026-09-03.md`](refactoring-backlog-archive-2026-09-03.md),
[`…-archive-2026-09-07.md`](refactoring-backlog-archive-2026-09-07.md),
[`…-archive-2026-09-09.md`](refactoring-backlog-archive-2026-09-09.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary (only the prefixes this OPEN file still uses): **VK**=the
foreign-arch Vulkan SDK · **AS**=the apt sources invariants · **EX**=gate scan
extent · **F#**=the size and duplication tracks. Everything else
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

## VK2 IS CLOSED; WHAT IS LEFT IS SMALL

Read this before anything else. The validating chain
(`chain-status.json` run `20260905-120554-7b7a0d4e`, then the 2026-09-07
`runtime` run) finished green and published a 3-arch `:latest-cross`. The wave
that followed it closed **thirteen** entries — CC1, CL1, VK1, AB1, APP1, CS1,
VK3, CS2, CS3, DISK3, R1, YB and F3 — and they now live in
[`…-archive-2026-09-07.md`](refactoring-backlog-archive-2026-09-07.md) with the
evidence that closed each one.

**What is left in this file is four open entries and two standing tracks.** VK2
closed on 2026-09-09 — 20/20 on both foreign arches, proven on the shipped bytes —
and left three successors behind it: **VK4** (the 15 tarball-only binaries),
**VK5** (aarch64 never ran on the current tree) and **AS1** (the apt sources still
assume an amd64 build host). **EX1 is new on 2026-09-07**: the extent
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

### Next up — VK2 is settled; the rest still needs one compile-heavy chain

The 2026-09-07 chain ran green end to end and published a 3-arch `:latest-cross`
(`manifest-freshness PASS`). Two sdk-only runs on 2026-09-08/09 then closed VK2 —
`sdk-20260908-132426` (aarch64 20/20) and `sdk-rv64-20260908-211949`
(riscv64 20/20, pushed `@sha256:09a4d255`). **Those runs covered the `sdk` stage
only.** Everything downstream of it is still landed-but-unbuilt:

1. **VK2 — DONE.** Its four named defects are fixed, and the fifth nobody had
   named (the host/target apt pocket asymmetry) is fixed, gated and documented.
   Evidence in [`…-archive-2026-09-09.md`](refactoring-backlog-archive-2026-09-09.md).
   It left VK4, VK5 and AS1 behind it, all small.
2. **Still waiting on a chain that reaches `media`, `android` and `runtime`** —
   none of these has been through a real build:
   * **VK3**'s two `>=` floors get promoted to exact counts from that run's
     `RATCHET: floor 20 -> N` line, and the four `_VK_REPORTED_TOOLS` names move
     into the required set in the same edit — once, not twice. The sdk runs now
     give the count those floors should carry: **20** on both foreign arches.
   * **DISK3**'s image lever has never fired in anger; the `[disk-images]` lines
     are what to read.
   * **CS3**'s prebuilt download replaces ~1900 s of QEMU on arm64 and riscv64
     keeps the source build. The runtime lane's `OK: … installed from the upstream
     … release binary` line is the proof.
   * **R1.1**'s llvm-target walk should read `0 of 142` on amd64 and `0 of 127`
     on the foreign pair.
3. **Then re-groom this file against that run**, the way the 2026-09-05 grooming
   re-derived every number from the gate that produces it. Four figures did not
   survive that exercise last time, and two did not survive this one: the
   `x86_64/bin` count and the composition of its delta were both quoted before
   either directory had been listed. Assume some will not survive the next.

**No entry in this file names a defect with a live failure mode.** AS1's three
neighbours are latent (every cross stage builds on `linux/amd64`); VK4 and VK5 are
a decision and a confirming run.


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

**Honesty about the rest:** the one open entry names no defect with a known failure
mode. What F1 and F2 now carry from `linux/llm-stack` is real, named, seam-bearing
debt — but it is a register, not a queue, and none of it blocks a build.
What is left is **four open entries (VK4, VK5, AS1, EX1) and two registers (F1, F2)** — the same
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

### VK4. The 15 binaries no arch builds — is `vkconfig` one of them? [S, ★★]

**Measured on the pushed `@sha256:09a4d255`, both directories listed in a
container:** `x86_64/bin` 52 entries, `riscv64/bin` 37, riscv64 a strict subset.
The 15-entry delta is exactly `dxa dxa-3.7 dxc dxc-3.7 dxl dxl-3.7 dxopt
dxopt-3.7 dxr dxr-3.7 dxv dxv-3.7 llvm-tblgen vkconfig vkconfig-gui`.

They were absent because `vulkan.sh` never named them — 0 hits for `vkconfig`,
`Vulkan-Configurator` or `dxc`. **Not** because they are prebuilt-only: the
vendor script builds both from a checkout, and the tarball's x86_64 binaries are
that script's own output. So this is not a regression VK2 left behind; it is a
question that had never been asked.

Three answers, and only one needs a decision:
* `llvm-tblgen` is structurally host-only. Nothing to do.
* The 12 DXC entries are a large LLVM fork LunarG ships prebuilt for x86_64.
  Building it per-target is out of proportion to any use this image has.
* **`vkconfig`/`vkconfig-gui` is the open one.** It is a Qt6 GUI app, and Qt6
  cross-compilation only started working on 2026-09-09 — so the reason it was
  never in `_VK_TARGET_COMPONENTS` no longer applies. **What closes this:** an
  owner decision, then either an 18th table row or a line in
  `vulkan-foreign-arch-sdk.md` saying it is deliberately host-only.

`spirv-remap` is in neither tree, so `-DENABLE_SPVREMAPPER=OFF` on the cross
glslang costs no parity — checked because it was the one concrete reason to doubt
subset-ness.

### VK5. aarch64 has never run on the current tree [S, ★★]

aarch64 reached `Vulkan cross-targets aarch64: 20/20 component(s) built`
(`out/build-logs/sdk-20260908-132426/sdk-arm64.log:21316`, a real 3710 s build) —
but that run predates every file the riscv64 closure touched: `vulkan.sh`
(HEAD `68d4cd1d`, 21:30), `build_python.sh` (23:01) and `cross-apt.sh` (00:31)
were all written after it ended at 16:39, and `find out -name '*arm64*' -newermt
'2026-09-08 16:45'` returns nothing at all.

The lanes are demonstrably symmetric — one component table, one apt path, and the
single substantive arch conditional (`slang`'s prebuilt-Dawn flags,
`vulkan.sh:659-666`) is a **no-op on aarch64** by construction — so the expected
result is an unchanged 20/20. **What closes this:** one `--only sdk
--target-arches arm64` run reprinting that line. Cheap, and the alternative is
carrying a number that was true of a different tree.

### AS1. The apt sources still assume the build host is amd64 [M, ★★]

Found by sweeping every writer of `/etc/apt/sources.list*` after the VK2 pocket
fix landed. The fixed defect is closed — all three `ubuntu_write_deb822_source`
call sites now agree on `-security`, and `Components:` has one hardcoded source of
truth in `ubuntu-mirror.sh:104` used by both halves. Three neighbours survive it,
all **latent today** because every cross stage builds on `linux/amd64`:

1. **`Dockerfile.media:204` and `build_python.sh:159` hardcode the literal
   `amd64`** for the host stanza, while `cross-apt.sh:199` uses
   `$(cross_build_arch)`. On a non-amd64 build host no stanza lists the host's own
   arch, and deb822 `Architectures:` is an absolute override, not an intersection.
2. **An amd64 (or i386) cross TARGET gets an architecture but no archive.**
   `cross_target_uses_ubuntu_ports` (`cross-apt.sh:75-80`) answers yes only for
   arm64/riscv64, so `cross_prepare_foreign_arch` runs `dpkg --add-architecture`
   at :223 and then writes nothing — and the new pocket repair never fires.
   Reachable since `b720f17b` made non-amd64 build hosts supported.
3. **`use-fast-ubuntu-mirror.sh:45,57-64`**: with the fast mirror on and
   `FAST_UBUNTU_REWRITE_SECURITY` at its default `false`, the host's `-security`
   stays on `security.ubuntu.com` while the target's comes from the fast ports
   mirror. Same pocket, two archives — a lagging mirror reproduces the identical
   `Multi-Arch: same` skew, and `cross_align_host_apt_pockets` cannot see it
   because it compares suite names, never URIs.

**What closes this:** (1) and (2) are small and mechanical. (3) is a decision —
either rewrite the security URI with the archive URI, or document that a fast
mirror must serve `-security` for the host too. None is worth a rebuild on its
own; fold them into the next stage that touches apt.

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are fully reviewed: **41** function rows over 80 lines
and **86** `cc` rows over 15 (plus 4 nesting), every one carrying a verdict that says what its
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

**`file-size.allow` is the authority — do not transcribe it here.** The table
table that used to sit in this entry was wrong within a day of being written, twice.
This entry's prose then broke its own rule again on 2026-09-04 by quoting
`smoke-runtime-image.sh` at 1739 when the allow file had carried the correct number
and the reason all along. The gate prints `files: 18 over 800 lines; 18 frozen`;
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
