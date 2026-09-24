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
[`…-archive-2026-09-09.md`](refactoring-backlog-archive-2026-09-09.md),
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary (only the prefixes this OPEN file still uses): **F#**=the size and
duplication registers. Image gaps (**CON7** onwards) live in the root
[`BACKLOG.md`](../BACKLOG.md).
Everything else is archive-only: **CON1–CON6** closed 2026-09-17/18 (the consumer
issues, the last one measured and aligned at Flutter 3.47.4), **EX** closed on
2026-09-07/09 (the extent gates scan `linux/llm-stack` and froze its rows),
**VK/AS** closed on 2026-09-17, **CC/CL/CS/AB/R#/YB/DISK/APP** on 2026-09-07,
**HT/GH** before them, **QW/TC/SMK** in the 2026-09-04 waves, and the rest long
before that.

Last groomed: **2026-09-18, after CON4's Windows half was measured, the
dependency wave landed and the two owner questions were answered** — every closed
narrative moved to
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md) and the
CHANGELOG. What stays here is **two registers**. Every
earlier grooming's warning still applies: **re-derive; do not trust a number
here, including these.**

## OPEN

### F1. The extent queues — what is left after every row got a verdict [M each]

**`function-size.allow` and `code-complexity.allow` are the authority — do not
transcribe them here.** Both are fully reviewed: **24** function rows over 80 lines
and **59** `cc` rows over 15 (plus 1 nesting), every one carrying a verdict that says what its
number IS. Read the reasons, not the numbers — and re-derive the counts from
`verify_code_size.py` / `verify_code_complexity.py`, never from this line.

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

**One row still carries a KEEP verdict worth keeping:** `media_common_init` (29) —
a module loader whose load ORDER is load-bearing. A table plus a loop would read
shorter and say less; the ordering is the knowledge.

**The last outside-the-closure row closed on 2026-09-18.** `bump_versions.py
main` (160) is now 32: `linux/scripts/tests/test-bump-versions.sh` — 40
assertions over fake specs, in-process — was the coverage it was blocked on,
then the split into `_parse_args` / `_lookup` / `_sweep` / `_safe_row` /
`_report_row` / `_write_phase` and the reporting helpers. Its
`function-size.allow` and `code-complexity.allow` rows were deleted rather than
re-baselined. Every named row left in the two registers is inside the build
closure.

**Two rows carry a "do not do the obvious thing" verdict.** `verify_comment_size.blocks`
(nesting 6): the honest fix is importing `verify_code_size.scan` like every other
extent gate, but that WIDENS the scan to `docs/scripts` and NARROWS it by
`SKIP_DIRS 'patches'` — it changes the gate's scope and needs a fresh
`comment-size.allow` baseline, which is different work from a nesting trim. And
`verify_package_names.load_arch` (17): every branch is a way the gate must not
produce a FALSE verdict, the all-or-nothing partial-fetch refusal above all.

### F2. Files over ~800 lines [L each, low priority]

**`file-size.allow` is the authority — do not transcribe it here.** The gate
prints `files: 13 over 800 lines; 13 frozen`; read it there. All rows were
reviewed and all but the one historical split are NOT split targets, each with a
reason a stranger can act on.

**Two verdicts worth not re-litigating.** `build-app-wheelhouse.sh` is the
near-miss: the stage suites extract blocks from it **by line range**, so a file
split silently re-aims them. And `smoke-runtime-image.sh` — which every earlier
version of this entry nominated as THE one to split — is an explicit **NO**: its
91 functions are the `check_*` / `_probe_*` assertions and the probe-and-verdict
layer they share, all over one image through one `_rt_run` under one `main()`. Its
length is the number of assertions it makes about the shipped bytes, and that
number growing is the gate succeeding.

**`lib/app-packaging.sh` crossed 800 on 2026-09-17** (CON2's scope probe + CON6's
finish-args block, 797 → 851); the row carries the NOT-a-split reason and the seam
that kept it that way. Record in
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md).

**Standing context, not a block:** `git push` is the agent's (2026-09-06) via
`gh auth setup-git` + HTTPS remotes, and ten of the thirteen files in
`linux/scripts/lib/` source a sibling `lib/log-bootstrap.sh` — a consumer that
copied ONE `lib/*.sh` file out on its own breaks on its next CI run, not here.
