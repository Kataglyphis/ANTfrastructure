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

**What is left in this file is two open entries and two standing tracks.** The
whole VK line closed over 2026-09-09/10 -- VK2, VK4, VK5, VK6 and VK7 -- and the
foreign-arch Vulkan SDK is now **measured** at parity on both:

| | amd64 | arm64 | riscv64 |
| --- | --- | --- | --- |
| `bin/` | 52 | **52** | **52** |
| `share/vulkan/explicit_layer.d` | 9 | **10** | **10** |
| `lib/` | 118 | **123** | **123** |
| entries amd64 has and the arch lacks | — | **2** | **2** |

Both remaining entries are the SAME two on both arches and both are explained:
`VulkanLoader` is a layout difference (the foreign prefixes keep `libvulkan.so*`
flat, which is what `Dockerfile.package:270` and `tvm-detect.sh:338` expect), and
`libshaderc_util.a` has no install rule and ships with no headers even on amd64,
so it is unlinkable there too. What AS1 left is two latent neighbours. **EX1 is new on 2026-09-07**: the extent
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
neighbours are latent (every cross stage builds on `linux/amd64`); VK6 and VK7 are
two owner decisions and no rebuild.


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
What is left is **two open entries (AS1 residual, EX1 is closed) and two registers (F1, F2)** — the same
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
   and the two `agentic-*` halves. Any full ANTfrastructure checkout satisfies that —
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

### AS1 (residual). Two neighbours, both latent, both cheap [S, ★]

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

### F4. The 27 extractions the 2026-09-09 PowerShell review identified and did not apply [S-M each, review]

The PowerShell lane got its first full row-by-row review on 2026-09-09: all 359
rows that had been frozen with `not yet reviewed` were judged, 319 as deliberate
twins and 40 as real extractions. **Eight were applied that day** and the rows
they emptied are gone from `code-dupes.allow`. A ninth landed right after, because
the review found it was not a style question but a live bug: `KataNativeProbe` was
`Add-Type`d twice with two different member sets, and one
`Initialize-KataNativeProbe` now owns it.

The 27 below were not applied, for one reason only: the appliers were held to
disjoint file sets so two of them could never edit the same file, and these did
not fit in one pass. Nothing here was judged not worth doing.

**`docs/scripts/code-dupes.allow` is the authority for the numbers** - each row
below still carries its budget and the measurement that set it, and the budget
stays frozen at that measurement until the extraction lands. Do not transcribe
the numbers here; the ones printed below were true at 2026-09-09 and each will
go stale the moment its extraction runs.

**Doing one of these retires its row.** A pair whose overlap drops to zero fails
the gate as a stale freeze, so the row is DELETED, not re-baselined - that is the
four-way contract working, not a regression.

**`windows/scripts/tests/SourceBuild.PinParity.Tests.ps1` (self)** - budget 235.

READ 2026-09-09, and this is real logic, not test data: Get-PinParitySite (line 90) and Get-RcivSite (line 357) share a 20-line VERBATIM run — the CommandElements walk that pairs each CommandParameterAst with its argument (attached -Name:value or the next element), plus the whole 'DefaultValue' switch arm. That block contains no domain content at all; it is PowerShell AST mechanics. The two scanners' real difference is three lines further down (-EnvironmentVariables is an array scanned with a nested-literal FindAll, -EnvironmentVariable is a single literal that must NOT be, and StripVPrefix vs TrimVPrefix), and the file already documents that difference in a comment. One owner leaves exactly those differences visible, which is what the reader wants.

*Plan:* Owner: a file-local helper `Get-CommandParameterArgumentMap` defined next to Get-PinScanAst (above line 88) in windows/scripts/tests/SourceBuild.PinParity.Tests.ps1. `param([System.Management.Automation.Language.CommandAst]$Call)` -> walks $Call.CommandElements once and returns an ordered hashtable of ParameterName -> argument Ast ($null for a bare switch), i.e. exactly the loop now at lines 102-111 and 369-378. One parameter, two callers, no mode flag. Add a second one-liner `Get-AstDefaultValue` returning @{ Value; IsLiteral } for the identical 'DefaultValue' arm (lines 117-124 and 383-390). Call sites to repoint: Get-PinParitySite (the for/switch at lines 101-135) becomes `foreach ($p in (Get-CommandParameterArgumentMap $call).GetEnumerator()) { switch ($p.Key) { ... } }` keeping only its EnvironmentVariables/StripVPrefix arms; Get-RcivSite (lines 368-407) likewise keeps only its EnvironmentVariable/TrimVPrefix arms and its comment about why the single-string parameter must not use a nested FindAll. Nothing outside this file changes — it is a self-pair. Verify with `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (baseline 815 tests, 815 passed) and re-run `wsl -d Ubuntu-26.04 --cd /mnt/d/GitHub/ANTfrastructure python3 docs/scripts/verify_code_dupes.py`. HONEST PAYOFF: this shrinks the row, it does not retire it — the next unit pair in this file measures 62 shingles (the two unknown-site guards at lines 251/499), so expect the budget to be re-trued from 235 to roughly 62 and the gate to report a shrink until the allowlist writer applies the new number.

**`windows/scripts/modules/WindowsFormatting.Common.psm1` (self)** - budget 134.

Get-ProjectCmakeFiles and Get-ProjectCppFiles share 29 lines of real logic in two contiguous runs (18 lines at 23-42 vs 68-99, 11 lines at 44-55 vs 101-112): the same git ls-files fast path with the same four-regex exclusion list, and the same Get-ChildItem -Recurse fallback with the same seven-regex exclusion list, both ending in Sort-Object -Unique. Only the pathspec list and one file predicate differ. This is exclusion POLICY, not shape, and the copies have already drifted once with a real cost: the file's own comment records that the git-path _deps regex in the C/C++ copy read -match instead of -notmatch until 2026-07-20, which kept only files under _deps/ and so silently formatted zero files.

*Plan:* Add a private (non-exported) owner Get-ProjectSourceFiles -WorkspacePath -GitPathspec [string[]] -FileFilter [scriptblock] at the top of windows/scripts/modules/WindowsFormatting.Common.psm1, holding both halves verbatim: the `git ls-files -- @GitPathspec` path with its four-regex exclusion list, and the Get-ChildItem -Recurse fallback with its seven-regex exclusion list, each ending in Sort-Object -Unique. Get-ProjectCmakeFiles becomes one call with @('CMakeLists.txt','**/CMakeLists.txt','*.cmake') and { param($f) $f.Name -eq 'CMakeLists.txt' -or $f.Extension -eq '.cmake' }; Get-ProjectCppFiles one call with the eight source globs and { param($f) $script:CppExtensions -contains $f.Extension.ToLowerInvariant() }. Two parameters beyond the workspace, both data, no mode flag. Both public functions keep their names, signatures and Export-ModuleMember entry, so NO call site changes: WindowsFormatting.Common.psm1:177/220/269 and WindowsClang.Common.psm1:88 are untouched. Get-ProjectDartFiles is deliberately NOT folded in - it has a different exclusion set (flutter, rust_builder, .git/modules) and no filesystem fallback at all. MEASURED, not estimated: an in-memory overlay of the edited file run through the gate's own indexer (docs/scripts/verify_code_dupes.py collect/_index_units/_collect_shared) puts this pair at 44, down from 134, with no new unallowlisted pair anywhere in the corpus; the overlay parses clean under [Parser]::ParseFile. The row therefore SHRINKS to 44 rather than retiring, and its reason should then say what the remaining 44 are (the three param blocks and the clang-format resolver twins). MEASURED SIDE EFFECT that must land in the same change: the three tests/ rows among Modules.Orchestrators.Tests.ps1, SourceBuild.GitCloneRetry.Tests.ps1 and SourceBuild.NinjaRetry.Tests.ps1 go 25 -> 26 each, because dropping this block pushed a family below the gate's >6-owner idiom cutoff and unsuppressed one shingle - a suppression flip, not a new copy, and the same bookkeeping several existing rows already record. Verify by running `wsl -d Ubuntu-26.04 --cd /mnt/d/GitHub/ANTfrastructure python3 docs/scripts/verify_code_dupes.py` and `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1`.

**`windows/scripts/tests/SourceBuild.VerifyTargetArch.Tests.ps1` (self)** - budget 85.

READ 2026-09-09: the ar (COFF archive) MEMBER HEADER is written out by hand four times — once inside the $script:NewArchive fixture (lines 65-69) and three more times inline, twice in the linker-member case (lines 189-193 and 198-202) and once in the malformed-size case (lines 248-252). All four are the same five `$bw.Write([System.Text.Encoding]::ASCII.GetBytes(<name>.PadRight(16)))` / PadRight(12) / PadRight(6) / PadRight(6) / '100644'.PadRight(8) lines, and those widths are the ar spec, not test data: getting one of them wrong makes the fixture silently unparseable and the case vacuously green. This is the one block in the file that has a name ("the ar member header") and exactly one correct spelling.

*Plan:* Owner: a `$script:WriteArMemberHeader` scriptblock added beside $script:NewPe / $script:NewCoffObj / $script:NewArchive inside the BeforeAll of windows/scripts/tests/SourceBuild.VerifyTargetArch.Tests.ps1 (declare it before $script:NewArchive, around line 43). `param([System.IO.BinaryWriter]$Writer, [string]$MemberName)` -> writes $MemberName.PadRight(16).Substring(0,16) then the four fixed fields ('0'.PadRight(12), '0'.PadRight(6), '0'.PadRight(6), '100644'.PadRight(8)). Two parameters, four callers, no flags. Call sites to repoint: inside $script:NewArchive replace lines 65-69 with `& $script:WriteArMemberHeader $bw $MemberName`; in the 'skips the linker members' case replace lines 189-193 with `& $script:WriteArMemberHeader $bw '/'` and lines 198-202 with `& $script:WriteArMemberHeader $bw 'foo.obj'`; in the 'malformed size field' case replace lines 248-252 with `& $script:WriteArMemberHeader $bw 'foo.obj'`. NOTE THE ONE RISK the file itself flags in its comment at line 41: Pester 5 It blocks are child scopes that do not see file-level FUNCTIONS, which is why these fixtures are $script:-scoped scriptblocks; a $script: scriptblock invoked from inside another $script: scriptblock resolves at call time and should work, but it is the one thing to confirm by RUNNING rather than by reading. Verify with `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (baseline 815/815); if the nested $script: lookup misbehaves, abandon and record KEEP. HONEST PAYOFF: shrinks, does not retire — the residual is the 5-line PadRight run the byte-level PE fixtures still share, so expect the budget to be re-trued from 85 to roughly 45.

**`windows/scripts/diagnostics/Test-LayerRename.ps1` <-> `windows/scripts/diagnostics/Test-ProcessIsolationCommit.ps1`** - budget 52.

Longest identical run 9 lines (Test-LayerRename.ps1:60-68 / Test-ProcessIsolationCommit.ps1:61-69), byte-for-byte including the comment: the docker.exe candidate walk over $env:DOCKER_EXE, D:\Stevedore\bin\docker.exe and $env:ProgramFiles\Stevedore\bin\docker.exe, then Get-Command, then a throw. This is the ONE case in the diagnostics scope where the owner already exists and the callers simply never migrated: Get-PreferredToolPath in windows/scripts/modules/WindowsScripts.Shared.psm1:618 is exactly candidate-paths-then-PATH with a -Required switch for the throwing half, and Invoke-DiagnosticProbe.ps1:98 records the migration -- 'Central candidate walk instead of the pasted Stevedore-then-PATH block that used to live in every runner (backlog #101)'. #101 converted the buildctl walks and left the docker ones behind. Nine pasted lines become one call; no new parameter, no new file, no new concept.

*Plan:* In each file replace the nine-line `if (-not $Docker) { $candidates = @(...); foreach ... }` block plus its throw with: Import-Module (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'windows\scripts\modules\WindowsScripts.Shared.psm1') -Force if (-not $Docker) { $Docker = Get-PreferredToolPath -CommandName 'docker' -Required -CandidatePaths @($env:DOCKER_EXE, 'D:\Stevedore\bin\docker.exe', "$env:ProgramFiles\Stevedore\bin\docker.exe") } Get-PreferredToolPath -Required already throws naming the tool and the paths searched, so the bespoke 'docker.exe not found. Pass -Docker <path>.' message is the only behaviour change; keep it by leaving -Required off and throwing at the call site if the existing wording is load-bearing for the .PARAMETER help both files document. Migrate the other two diagnostics pasters in the same pass -- Test-BuildCopy.ps1 and Test-GpuPassthrough.ps1 carry the identical block -- which completes backlog #101 for docker.exe and shrinks the Test-BuildCopy rows too; windows/scripts/host/Reset-ContainerStores.ps1 and windows/scripts/modules/WindowsContainerBuild.Reuse.psm1 also paste it but are outside the diagnostics scope and can follow separately. Verification: both probes drive real `docker build --isolation process` against Dockerfile.isolation-probe on the host and cannot run in CI, but the changed region is pure path resolution -- confirm with pwsh AST parse, PSScriptAnalyzer, the duplication gate, the 815-test harness, and a one-line host check that Get-PreferredToolPath returns the same path the pasted walk did.

**`windows/scripts/modules/WindowsFormatting.Common.psm1` <-> `windows/scripts/modules/WindowsWebDav.Common.psm1`** - budget 44.

Both files inline the uv delegate trio (LogInfo, LogWarning, CommandRunner) that an owner ALREADY exports and neither of them calls: New-UvBuildDelegates in WindowsBuild.Common.psm1:638, whose own comment calls itself 'the three delegates every python CI entry script hands to New-UvProjectEnvironment/Remove-UvProjectEnvironment'. Today only Initialize-CiEnvironment.ps1:79 uses it. WindowsFormatting.Common.psm1:133-144 inlines all three verbatim; WindowsWebDav.Common.psm1:59-72 inlines the two log delegates verbatim. This is the cheapest kind of extraction - repointing to an owner that exists, with no new API.

*Plan:* In windows/scripts/modules/WindowsFormatting.Common.psm1 replace lines 133-144 with `$uvDelegates = New-UvBuildDelegates -Context $Context` plus three assignments ($logInfo/$logWarning/$commandRunner from the hashtable); the owner's CommandRunner is behaviourally identical to the inlined one. In windows/scripts/modules/WindowsWebDav.Common.psm1 replace the eight log-delegate lines 59-66 the same way but KEEP its own $commandRunner: that one passes -IgnoreExitCode, which the file documents as deliberate (WebDAV bootstrap failures degrade to warnings, never abort the build), so it must not be folded into the shared runner. Add the module-load guard both files already use for their other imports - `if (-not (Get-Module -Name 'WindowsBuild.Common')) { Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1') }` - so the dependency is declared instead of ambient; both files already call Write-BuildLog/Write-BuildLogWarning/Invoke-BuildExternal from that module with no import at all today, and WindowsBuild.Common imports neither of them, so there is no cycle. MEASURED on an in-memory overlay through the gate's own indexer: this pair goes 45 -> 7, below the gate's threshold of 10 - THE ROW RETIRES. Both overlays parse clean under [Parser]::ParseFile. TWO MEASURED SIDE EFFECTS that must land in the same change: WindowsBuild.Common.psm1//WindowsWebDav.Common.psm1 goes 13 -> 15, and the three tests/ rows among Modules.Orchestrators.Tests.ps1 / SourceBuild.GitCloneRetry.Tests.ps1 / SourceBuild.NinjaRetry.Tests.ps1 go 25 -> 26 each. Both are suppression flips, not new copies: removing the inlined delegates dropped blocks below the gate's >6-owner idiom cutoff and unsuppressed one shingle. I measured the WebDav growth with AND without the added Import-Module and it is 15 either way, so the import is not the cause and should be kept for correctness. If the applier will not re-true those four rows, abandon this extraction and record KEEP here instead - do not force it through. Verify by running the gate and `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1`.

**`windows/scripts/build/Build-GstreamerFromSource.ps1` <-> `windows/scripts/host/Install-ScoopTools.ps1`** - budget 43.

Same block as the Build-GstreamerFromSource/Build-LlvmFromSource row: the aarch64 compiler-rt staging recipe, third copy. Longest shared run 9 lines (the else/warn arm plus the whole catch/finally cleanup). Retired by the same single owner.

*Plan:* Covered by the Install-AArch64CompilerRt extraction described on the Build-GstreamerFromSource <-> Build-LlvmFromSource row. No separate work.

**`windows/scripts/build/Build-LlvmFromSource.ps1` <-> `windows/scripts/modules/WindowsSourceBuild.Common.psm1`** - budget 40.

The 'verify against an optional pin, warn when unpinned' POLICY, hand-written in four places. Longest shared run 7 lines and it is the whole ladder: `if ($sha) { $actual = (Get-FileHash -Algorithm SHA256 -Path $x).Hash; if (-not [string]::Equals($actual,$sha,[StringComparison]::OrdinalIgnoreCase)) { throw ... }; Write-Host verified } else { Write-Warning unpinned }`. The gate names the family outright: 'ONE block of 25 shingle(s), held by 4 files -- Build-LlvmFromSource.ps1:53, Install-Tensorrt.ps1:111, WindowsScripts.Shared.psm1:119, WindowsSourceBuild.Common.psm1:694'. This is a download-policy decision (mismatch is fatal, absent pin is a warning) that must be identical everywhere, and four copies is how it stops being.

*Plan:* Add Assert-FileSha256 -Path -Expected [-Label] to windows/scripts/modules/WindowsScripts.Shared.psm1 -- it already contains the fourth copy inside Invoke-DownloadWithRetry (:193), so the owner lands beside the code it generalises and no caller gains a module. Repoint Build-LlvmFromSource.ps1:73-83 (inside Install-TargetCompilerRt), WindowsSourceBuild.Common.psm1:705-713 (Resolve-QnnSdk), Install-Tensorrt.ps1:116-124, and WindowsScripts.Shared.psm1:193 itself. SEQUENCING: Build-LlvmFromSource.ps1:53 is also the site the Install-AArch64CompilerRt extraction moves, so land that one FIRST and re-measure -- the Llvm copy of this ladder travels with it, and doing both blind will double-count the shrink.

**`windows/scripts/build/Build-LlvmFromSource.ps1` <-> `windows/scripts/host/Install-ScoopTools.ps1`** - budget 33.

Same block again -- the aarch64 compiler-rt staging recipe, the Llvm/ScoopTools edge of the same three-file family. Longest shared run 6 lines (catch/finally cleanup), 4 more at the verified/warn arms. Retired by the same single owner.

*Plan:* Covered by the Install-AArch64CompilerRt extraction described on the Build-GstreamerFromSource <-> Build-LlvmFromSource row. No separate work.

**`windows/scripts/host/Sync-DefenderExclusions.ps1` (self)** - budget 32.

Genuine self-duplication with a local owner and no downside: lines 32-38 and 48-54 are the SAME six-line dump of the Defender exclusion set (blank line, cyan `== <label> ==` banner, Get-MpPreference, then ExclusionPath and ExclusionProcess each sorted and indented), printed once as BEFORE and once as AFTER. Longest identical run 7 lines -- the largest true run in the whole host/ scope. The two copies exist precisely so the reader can diff them, which is the case where they MUST stay identical, and today nothing enforces that. One local helper, one parameter, two call sites, no module dependency added (the script already imports WindowsScripts.Shared). Retires the row outright: it is this pair's only unit-pair overlap, so the measurement drops to 0 and the gate reports the row as stale.

*Plan:* In windows/scripts/host/Sync-DefenderExclusions.ps1 only. Add a local helper above line 32: # BEFORE and AFTER print the SAME two lists on purpose -- the operator diffs # them. One owner is what keeps them printable as a diff. function Show-Exclusions { param([Parameter(Mandatory)][string]$Label) Write-Host '' Write-Host "== $Label ==" -ForegroundColor Cyan $pref = Get-MpPreference Write-Host ' ExclusionPath:' $pref.ExclusionPath / Sort-Object / ForEach-Object { Write-Host (' ' + $_) } Write-Host ' ExclusionProcess:' $pref.ExclusionProcess / Sort-Object / ForEach-Object { Write-Host (' ' + $_) } return $pref } Replace lines 32-38 with `$mp = Show-Exclusions 'BEFORE'` and lines 48-54 with `$null = Show-Exclusions 'AFTER'`. Write-Host emits nothing to the pipeline, so $pref is the sole output and $mp keeps its current value for the $missPath/$missProc computation at lines 42-43; $mp2 was never read after its own dump, hence $null. Line 55's trailing `Write-Host ''` stays where it is (the helper emits its blank line BEFORE the banner, matching both existing sites). No behaviour change: same calls, same order, same colours. Verify with `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (baseline 815/815, exit 0 -- no suite covers this script, so this is a no-regression check) and `wsl -d Ubuntu-26.04 --cd /mnt/d/GitHub/ANTfrastructure python3 docs/scripts/verify_code_dupes.py`, which should then report this pair as a stale row to delete.

**`windows/scripts/build/Build-LlvmFromSource.ps1` <-> `windows/scripts/host/Install-Tensorrt.ps1`** - budget 30.

Same four-file SHA256 verify-or-warn family as the Build-LlvmFromSource <-> WindowsSourceBuild.Common row (Install-Tensorrt.ps1:111 is the third holder). Longest contiguous run here is only 2 lines because the two wrap the ladder differently, but the 25-shingle block itself is identical. Retired by the same owner.

*Plan:* Covered by the Assert-FileSha256 extraction described on the Build-LlvmFromSource <-> WindowsSourceBuild.Common row. No separate work.

**`windows/scripts/modules/WindowsBuild.Common.psm1` <-> `windows/scripts/modules/WindowsCMake.Common.psm1`** - budget 30.

7 consecutive substantive lines (WindowsBuild.Common.psm1:736-744 vs WindowsCMake.Common.psm1:286-294) set exactly the same five environment variables to the resolved sccache path - CMAKE_C_COMPILER_LAUNCHER, CMAKE_CXX_COMPILER_LAUNCHER, RUSTC_WRAPPER, CC_WRAPPER, CXX_WRAPPER - and both carry the same four-line comment explaining why CMAKE_CUDA_COMPILER_LAUNCHER is deliberately absent (tried and reverted 2026-08-08; sccache-wrapped nvcc loses its per-arch .cubin files before fatbinary). The CMake copy's own comment already names the verdict: 'Near-duplicate of the wrapper wiring in Initialize-BuildCacheEnvironment (WindowsBuild.Common.psm1) ... merge candidate.' The duplication is known, flagged in the code, and has simply had no owner.

*Plan:* Add `function Enable-SccacheCompilerWrapper { param([Parameter(Mandatory)][string]$SccacheExe) ... }` to windows/scripts/modules/WindowsBuild.Common.psm1 holding the five assignments and the CUDA comment, and add it to that module's Export-ModuleMember list. WindowsCMake.Common.psm1 already imports WindowsBuild.Common at its line 12, so no new import edge is created. Call it from Initialize-BuildCacheEnvironment (replacing WindowsBuild.Common.psm1:736-744) and from Invoke-CMakeBuild's `if (-not $DisableSccache)` branch (replacing WindowsCMake.Common.psm1:286-294). ONE parameter, two callers, no mode flag: the -DisableSccache test stays at the CMake call site, the SCCACHE_MAX_JOBS default stays exactly where each file already puts it, and each call site KEEPS its own Write-BuildLog line because the two messages genuinely differ ('sccache found at: X. Enabling compiler cache.' vs 'Enabling sccache wrappers using: X'). The CUDA warning then has one home instead of two that can drift apart. MEASURED on an in-memory overlay through the gate's own indexer: this pair goes 30 -> 20, NOT ONE other pair in the corpus changes, and no new unallowlisted pair appears; both overlays parse clean under [Parser]::ParseFile. 20 is above the gate's threshold, so the row shrinks rather than retiring, and its reason should then describe what is left (the shared param-block shapes and the Write-BuildLog banner lines). Verify by running the gate and `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1`.

**`windows/scripts/build/Build-LlvmFromSource.ps1` <-> `windows/scripts/modules/WindowsScripts.Shared.psm1`** - budget 29.

Same four-file SHA256 verify-or-warn family; WindowsScripts.Shared.psm1:193 holds the copy embedded in Invoke-DownloadWithRetry. Longest run 3 lines, same 25-shingle block. Retired by the same owner, which lands in this very file.

*Plan:* Covered by the Assert-FileSha256 extraction described on the Build-LlvmFromSource <-> WindowsSourceBuild.Common row. No separate work.

**`windows/scripts/tests/SourceBuild.SccacheSession.Tests.ps1` (self)** - budget 28.

READ 2026-09-09: `$newFakeSccache` is defined TWICE in this file, character for character, 11 lines each — once at line 11 inside Describe 'Start-SccacheServerSession' and again at line 67 inside Describe 'Complete-SccacheServerSession'. There is no reason for the second copy; the two Describes want the identical fake (a sccache.cmd that appends its arguments to %WBT_SCC_LOG% and exits 0). This is not a deliberate twin, it is a copy-paste that nothing has caught because the gate froze it wholesale. The cheapest possible fix: one definition, zero parameters, zero behaviour change.

*Plan:* Owner: hoist the existing definition to file scope in windows/scripts/tests/SourceBuild.SccacheSession.Tests.ps1 — move the `$newFakeSccache = { ... }` block (lines 11-21) up to just below the header comment (before the first `Describe` at line 9), and delete the duplicate at lines 67-77. The harness's Describe is a plain `& $Body`, so the file-scope variable is visible inside both Describes; the sibling suites (SourceBuild.NinjaRetry.Tests.ps1, SourceBuild.GitCloneRetry.Tests.ps1) already declare their fakes at this level and are the precedent. No call site changes at all — every `& $newFakeSccache $dir` keeps its spelling. Nothing outside this file changes. Verify with `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (baseline 815/815) and re-run the gate. HONEST PAYOFF: small on the number — the next unit pair measures 26 shingles, so the budget re-trues from 28 to about 26 and the row stays — but it deletes 11 duplicated lines whose only possible future is to drift apart.

**`windows/scripts/diagnostics/Find-LsmEventHolder.ps1` <-> `windows/scripts/diagnostics/Get-SiloProcesses.ps1`** - budget 24.

Longest identical run 6 lines (Find-LsmEventHolder.ps1:115-120 / Get-SiloProcesses.ps1:52-57) -- the bait Dockerfile here-string and its Set-Content. Both also carry the cdb.exe walk, the OutDir default and the wininit-diff wait loop. Same single extraction.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row.

**`windows/Build-Buildkit.ps1` <-> `windows/scripts/diagnostics/Invoke-DiagnosticProbe.ps1`** - budget 20.

The block is byte-identical, 5 lines, and it is LOGIC plus a hardcoded install-layout list, not a language-mandated shape: Build-Buildkit.ps1:153-157 and Invoke-DiagnosticProbe.ps1:100-104 both read `if (-not $BuildCtl) { $BuildCtl = Get-PreferredToolPath -CommandName 'buildctl' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe') }` followed by `if (-not $BuildCtl) { throw 'buildctl.exe not found (Stevedore bin or PATH).' }`. Get-PreferredToolPath is already the shared walker; what has no owner is the CANDIDATE LIST, which is repeated in nine files (grep 'Stevedore.*buildctl'). One zero-mode-flag helper serves every caller because the Stevedore layouts are a property of the host, not of the caller. Both comments at the call sites already say the block was supposed to have one owner ('shared helper, #101' / 'Central candidate walk instead of the pasted Stevedore-then-PATH block that used to live in every runner (backlog #101)') -- the walk was extracted, the list was left behind.

*Plan:* Add `Resolve-BuildCtlPath` to windows/scripts/modules/WindowsScripts.Shared.psm1, beside Get-PreferredToolPath (which it delegates to) and add it to the Export-ModuleMember list at line 738. Body: `param([string]$BuildCtl = '') ; if ($BuildCtl) { return $BuildCtl } ; return (Get-PreferredToolPath -CommandName 'buildctl' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe') -Required)`. Use the EXISTING -Required switch for the throw rather than writing a new one; its message already names both candidate paths and PATH, a superset of the two current messages. Repoint three call sites, each of which already imports WindowsScripts.Shared (Build-Buildkit.ps1:124, Invoke-DiagnosticProbe.ps1:96, Test-CudaCache.ps1:32) and each of which collapses to `$BuildCtl = Resolve-BuildCtlPath -BuildCtl $BuildCtl`: Build-Buildkit.ps1:153-157, Invoke-DiagnosticProbe.ps1:100-104, Test-CudaCache.ps1:35-39. TWO BEHAVIOUR NUANCES TO VERIFY, NOT ASSUME: (1) Test-CudaCache passes -CommandName 'buildctl.exe' where the other two pass 'buildctl' -- on Windows `Get-Command buildctl` resolves buildctl.exe through PATHEXT, so the PATH fallback is unchanged, but confirm it before collapsing; (2) Test-CudaCache adds `-or -not (Test-Path $BuildCtl)` to its throw, which is dead weight -- Get-PreferredToolPath only returns a candidate it has already Test-Path'd and Resolve-Path'd -- so dropping it is behaviour-preserving on the candidate arm, and on the PATH arm Get-Command only returns a command that exists. Follow-on, NOT part of this change: Reset-ContainerStores.ps1:70 carries the same list through Get-PreferredToolPath, and Test-BuildCopy.ps1:123, Set-BuildkitdGcpolicy.ps1:78, Reset-ContainerLocks.ps1:47 carry it as a hand-rolled `@(...) / Where-Object { Test-Path $_ } / Select-Object -First 1`; repointing those shrinks rows 334/384/385/408 but is a separate, host-lane change. Verify with `wsl -d Ubuntu-26.04 --cd /mnt/d/GitHub/ANTfrastructure python3 docs/scripts/verify_code_dupes.py` (rows 404/461/472 must vanish, no new finding) and `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (815/815 baseline; the module-closure suites BuildKit.ModuleClosure / Modules.ScriptCallClosure / Modules.ReExport cover a new export).

**`windows/Build-Buildkit.ps1` (self)** - budget 18.

A byte-identical 6-line block pasted twice in ONE file: Build-Buildkit.ps1:743-748 and 763-768, the -NoCacheStage matched-nothing gate (`$unmatchedNoCacheStage = @($NoCacheStage / Where-Object { -not $script:NoCacheStageMatched.ContainsKey($_) })` then a three-line throw). The file's own comment at 760 explains why there are TWO SITES -- the first fires pre-export inside the `final` block, the second covers runs without 'final' where that site never executes -- and that is a reason for two CALLS, not two copies. The gate measures it at 18 shingles with a 6-line identical run, the largest self-pair run in this scope. One local function, no mode flag, both sites become one line; the next-largest unit pair in this file is 9 shingles, under the threshold of 10, so the row disappears rather than shrinks.

*Plan:* Add a script-local `function Assert-NoCacheStageMatched { param([string[]]$Requested = $NoCacheStage) ... }` to windows/Build-Buildkit.ps1 next to Set-BuildPhase (line 145) -- mid-file function definitions are this file's house style (Set-BuildPhase:145, Invoke-BkStage:271, Get-Ver:184) and 145 is inside the `try {` opened at 122 and before both call sites. Body is the current six lines verbatim, reading $script:NoCacheStageMatched (already script-scoped, set at 269 and written at 319). Replace lines 743-748 and 763-768 with `Assert-NoCacheStageMatched`, keeping each site's surrounding comment where it is -- the 760 comment explains the SECOND call and must not migrate into the helper. A `throw` inside a function propagates identically, so the fail-loud contract audit #15 asks for is unchanged. Verify with `wsl -d Ubuntu-26.04 --cd /mnt/d/GitHub/ANTfrastructure python3 docs/scripts/verify_code_dupes.py` (row 441 must vanish, not merely shrink) and `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (815/815 baseline; Driver.ClosureScope.Tests.ps1 and the BuildKit suites read this driver).

**`windows/scripts/diagnostics/Get-HostLsm.ps1` <-> `windows/scripts/diagnostics/Get-SiloProcesses.ps1`** - budget 16.

Longest identical run 8 lines (Get-HostLsm.ps1:97-104 / Get-SiloProcesses.ps1:50-57) and it is real setup logic, not shape: the bait-container block -- buildctl path check, nonce, $env:TEMP bait dir, the four-line `ARG BASE / FROM ${BASE} / ARG NONCE / RUN echo bait-$NONCE` here-string, and the eight-argument buildctl Start-Process. The two copies differ in exactly two tokens: the temp-dir prefix (hostlsm- vs silo-) and the image tag (diag-hostlsm- vs diag-silo-). One `-Tag` parameter covers both. On top of that the same two files share the cdb.exe discovery and the OutDir default verbatim. This is the densest cluster in the diagnostics scope and one module retires ten rows.

*Plan:* New module windows/scripts/modules/WindowsSiloProbe.Common.psm1 owning five functions with no per-caller mode flags: Get-CdbPath (the 3-line Get-ChildItem 'C:\Program Files\WindowsApps' -Filter cdb.exe -Recurse -Depth 3 walk filtered to *Microsoft.WinDbg*amd64*, throwing when absent; 4 callers), Initialize-LsmProbeOutDir -OutDir (the triple Split-Path repoRoot default to out\lsm-attach plus New-Item; 5 callers), Start-SiloBaitContainer -Tag [-PassThru] (the whole bait block; 3 callers -- Find-LsmEventHolder needs the process object, hence -PassThru), Wait-ForNewSilo -BaselinePid -TimeoutSec -PollSec (the deadline/while wininit diff loop; 4 callers, and the three genuinely-different values -- 900 vs 900 vs 300 vs 180 s, 3 s vs 2 s poll -- are arguments, not modes), Get-SiloSvchost -ServicesParentPid -TimeoutSec (the services.exe descent plus the CreationDate-sorted svchost poll; 3 callers). Each of the five scripts gains one repo-relative Import-Module line of the shape Test-CudaCache.ps1:32 already uses, so they stay runnable as `pwsh -File` from a bare checkout with no new install step. Get-LsmWaitstack keeps its own `Select-Object -First 3` at the call site rather than pushing a count parameter into the helper. VERIFICATION LIMIT, stated plainly: none of these five probes is covered by Invoke-Tests.ps1 and none can run here -- they need an elevated host, the WinDbg cdb package, a live buildkitd and a container inside its ~141 s hang window. Verification available is pwsh parse (AST), PSScriptAnalyzer, the duplication gate, and the 815-test harness for no collateral damage; the probe behaviour itself must be re-run by hand on the host before this is trusted. The extraction is confined to setup (finding cdb, starting bait, waiting for the silo) and touches none of the measurement -- the cdb -c command strings, the dump capture, the R10 read and the handle enumeration stay inline in each probe, which is what makes it safe to do without a live run.

**`windows/scripts/tests/SourceBuild.Chain.Tests.ps1` (self)** - budget 16.

READ 2026-09-09: this is the repeated-FIXTURE case the Linux side already solved with t_consumer_fixture. Four It blocks (lines 53, 82, 100, 130) each hand-build the SAME stage tree — the same `$body` fake-stage script that appends its own -SourceDir to a log, the same `foreach ($s in 'a','b',...) { Set-Content ... }` loop, and the same `$stages = @( @{ Name='A'; Script='a.ps1'; SourceDir='src-a' } ... )` array differing only in how many entries it has (3, 3, 4, 2). Longest shared run 10 lines, and unlike every other row in this scope those ten lines are identical as TEXT, not merely after the gate's "S"/$V folding. One fixture with a count parameter serves all four without a single mode flag, and each case shrinks to the one line that is actually its subject (-StartAt 'B' / -Until 'B' / the two-call partition / -StartAt '').

*Plan:* Owner: a file-scope scriptblock `$newStageTree` declared between the header comment and `Describe` (line 7) in windows/scripts/tests/SourceBuild.Chain.Tests.ps1 — the harness's Describe/It are plain `& $Body` invocations, so a file-scope variable is in scope inside them (this file's siblings, e.g. SourceBuild.NinjaRetry.Tests.ps1, already rely on that for $newFakeNinja). Signature `param([string]$Dir, [string]$Log, [int]$Count)`: writes a.ps1..<n>.ps1 each containing `param([string]$SourceDir,[string]$InstallDir)` + `Add-Content -LiteralPath '<Log>' -Value $SourceDir`, and returns `,@(...)` of `@{ Name = 'A'..; Script = 'a.ps1'..; SourceDir = 'src-a'.. }` (the comma is required or PowerShell unrolls the single-element case). Call sites to repoint: lines 56-62 (Count 3), 85-91 (Count 3), 103-110 (Count 4), 133-138 (Count 2) — each collapses to `$stages = & $newStageTree $dir $log 3`. LEAVE ALONE: line 10 (its fake script logs "<SourceDir>/<InstallDir>" and its SourceDirs are absolute C:\src\* — a different fixture), line 32 (three differently-behaving stage scripts, one of which exits 3), and lines 72/120 (one-stage trees whose script logs the literal 'ran'). Nothing outside this file changes. Verify with `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (baseline 815/815) and re-run the gate. Expected: the remaining unit pairs in this file are 4-5 line structural tails, so the measurement should fall under the gate's threshold of 10 and the row should disappear on its own.

**`windows/scripts/diagnostics/Find-LsmEventHolder.ps1` <-> `windows/scripts/diagnostics/Get-LsmWaitObject.ps1`** - budget 16.

Longest identical run 8 lines (Find-LsmEventHolder.ps1:133-140 / Get-LsmWaitObject.ps1:55-62), only one of them structural: the silo wait loop -- `$deadline = (Get-Date).AddSeconds($WaitForSiloSec)`, the while-poll that diffs Win32_Process wininit.exe against the baseline PID set, and its throw. The gate names it as a 35-shingle block held by four files. Beyond it the two share the cdb.exe walk, the OutDir default and the services.exe/svchost descent. Real discovery logic with one honest parameter (the timeout), not a shape.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row -- Wait-ForNewSilo and Get-SiloSvchost.

**`windows/scripts/diagnostics/Get-LsmWaitObject.ps1` <-> `windows/scripts/diagnostics/Get-LsmWaitstack.ps1`** - budget 16.

Longest identical run 8 lines (Get-LsmWaitObject.ps1:55-62 / Get-LsmWaitstack.ps1:53-60) -- the silo wait loop and the services.exe poll. Get-LsmWaitObject's own comment at line 50 already says 'Same silo detection as Get-LsmWaitstack.ps1', so the duplication is known and simply has no owner. That is the clearest possible signal to give it one.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row -- Wait-ForNewSilo and Get-SiloSvchost. The 'Same silo detection as ...' comment is replaced by the function name.

**`windows/scripts/diagnostics/Get-LsmWaitObject.ps1` <-> `windows/scripts/diagnostics/Get-SiloProcesses.ps1`** - budget 16.

Longest identical run 6 lines (Get-LsmWaitObject.ps1:55-60 / Get-SiloProcesses.ps1:67-72) -- the deadline plus the wininit-diff while loop. Both also carry the cdb.exe walk and the OutDir default. The two poll intervals differ (3 s vs 2 s), which is one argument, not a mode.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row -- Wait-ForNewSilo -PollSec, Get-CdbPath, Initialize-LsmProbeOutDir.

**`windows/Build-Buildkit.ps1` <-> `windows/scripts/diagnostics/Test-CudaCache.ps1`** - budget 16.

Same block and same extraction as row 404 -- Build-Buildkit.ps1:153-157 against Test-CudaCache.ps1:35-39, the buildctl Stevedore candidate list plus its not-found throw. Counted here as 16 shingles because Test-CudaCache writes the call on one line and spells the command 'buildctl.exe'. retires_rows is 0 only to avoid double-counting: the single Resolve-BuildCtlPath owner described on row 404 retires 404, this row, and row 472 (Invoke-DiagnosticProbe <-> Test-CudaCache, budget 16, which is the third face of the same triangle and sits in the diagnostics reviewer's scope). Do not perform this as a separate change.

*Plan:* No separate work. Covered by the Resolve-BuildCtlPath extraction on row 404; Test-CudaCache.ps1:35-39 is one of that plan's three call sites, and its two behaviour nuances (-CommandName 'buildctl.exe' vs 'buildctl', and the redundant `-or -not (Test-Path $BuildCtl)`) are called out there.

**`windows/scripts/diagnostics/Find-LsmEventHolder.ps1` <-> `windows/scripts/diagnostics/Get-HostLsm.ps1`** - budget 11.

Longest identical run 6 lines (Find-LsmEventHolder.ps1:115-120 / Get-HostLsm.ps1:99-104) -- the bait Dockerfile here-string and its Set-Content, inside the same ~20-line bait-container block described on the Get-HostLsm/Get-SiloProcesses row. Both files additionally carry the cdb.exe discovery walk and the out\lsm-attach OutDir default verbatim. Same single extraction; nothing here is language-mandated shape.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row -- Start-SiloBaitContainer -Tag, Get-CdbPath and Initialize-LsmProbeOutDir. Find-LsmEventHolder passes -PassThru because it keeps the buildctl process object; Get-HostLsm discards it with / Out-Null at the call site.

**`windows/scripts/tests/Testing.ManualExecutable.Tests.ps1` (self)** - budget 11.

READ 2026-09-09: four It blocks (lines 42-49, 56-63, 72-79, 105-112) hold the SAME ten lines character for character — `$root = New-FakeBuildRoot` / try / `$result = @(Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName 'x.exe')` / `$result.Count / Should -Be 1` / `$result[0] / Should -Be <bool>` / finally / Remove-Item. Only the expected boolean differs (and the executable name in the fourth). The file's own header says what is being pinned is "the return value must be exactly ONE boolean" — that is one assertion, written out four times, and the try/finally around it is the leak-safety the harness already owns elsewhere as Invoke-InTestDir. This is not a case where the copies carry the meaning: the meaning is entirely in the Mock lines above them, which stay.

*Plan:* Owner: `function Assert-ManualTestOutcome` added inside the existing BeforeAll of windows/scripts/tests/Testing.ManualExecutable.Tests.ps1, immediately after New-FakeBuildRoot (after line 29) — the file already proves that a function defined there is callable from its It blocks. `param([bool]$Expected, [string]$ExecutableName = 'x.exe')` -> `$root = New-FakeBuildRoot; try { $result = @(Invoke-ManualTestExecutable -Context ([pscustomobject]@{}) -BuildRoot $root -ExecutableName $ExecutableName); $result.Count / Should -Be 1; $result[0] / Should -Be $Expected } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }`. Two parameters, four callers, no mode flag. Call sites to repoint: line 42-49 -> `Assert-ManualTestOutcome -Expected $false`; 56-63 -> `Assert-ManualTestOutcome -Expected $false`; 72-79 -> `Assert-ManualTestOutcome -Expected $true`; 105-112 -> `Assert-ManualTestOutcome -Expected $false -ExecutableName 'absent.exe'`. LEAVE ALONE the fifth block at 91-97: it asserts `{ ... } / Should -Throw` instead of inspecting a return value, so it keeps its own try/finally. The Mock lines that give each case its identity stay exactly where they are. Nothing outside this file changes. Verify with `pwsh -NoProfile -File windows\scripts\tests\Invoke-Tests.ps1` (baseline 815 tests, 815 passed) and re-run the gate. Expected: each It drops to two Mock lines plus one call, which is below the gate's MIN_TOKENS for a unit, so the measurement should fall under the threshold of 10 and the row should disappear on its own.

**`windows/scripts/diagnostics/Find-LsmEventHolder.ps1` <-> `windows/scripts/diagnostics/Get-LsmWaitstack.ps1`** - budget 11.

Longest identical run 8 lines (Find-LsmEventHolder.ps1:133-140 / Get-LsmWaitstack.ps1:53-60) -- the same silo wait loop plus the `foreach ($i in 1..20)` services.exe poll. Get-LsmWaitstack uses comsvcs MiniDump instead of cdb, so these two share the discovery half only; that half is exactly what the new module owns.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row -- Wait-ForNewSilo and Get-SiloSvchost. Get-LsmWaitstack keeps its `Select-Object -First 3` at the call site.

**`windows/scripts/diagnostics/Get-LsmWaitstack.ps1` <-> `windows/scripts/diagnostics/Get-SiloProcesses.ps1`** - budget 11.

Longest identical run 6 lines (Get-LsmWaitstack.ps1:53-58 / Get-SiloProcesses.ps1:67-72) -- the deadline plus the wininit-diff while loop, the same 35-shingle block the gate reports across four files. Both also share the OutDir default.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row -- Wait-ForNewSilo and Initialize-LsmProbeOutDir.

**`windows/scripts/diagnostics/Get-HostLsm.ps1` <-> `windows/scripts/diagnostics/Get-LsmWaitObject.ps1`** - budget 11.

Longest identical run 5 lines (Get-HostLsm.ps1:35-39 / Get-LsmWaitObject.ps1:39-43) -- the OutDir default: the triple `Split-Path ... -Parent` climb to repoRoot, `Join-Path $repoRoot 'out\lsm-attach'` and the New-Item. All five LSM probes carry it byte-identically. Both files also share the cdb.exe walk. A three-deep Split-Path climb repeated five times is the kind of path arithmetic that breaks silently when a directory moves; one owner fixes that too.

*Plan:* Covered by the WindowsSiloProbe.Common.psm1 extraction described on the Get-HostLsm / Get-SiloProcesses row -- Initialize-LsmProbeOutDir -OutDir and Get-CdbPath.
