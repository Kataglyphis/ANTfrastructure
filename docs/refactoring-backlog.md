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

### RV. Review of the Linux chain, 2026-10-22 (re-derive before acting)

Found while the 3-arch `:latest` chain ran, from the stage logs and the layer audit. Evidence:
`build-logs/base.log`, `build-logs/compiler.log`, `linux/scripts/layer-audit.py`. Done in the same
change: the push retry policy (one helper), the status-only chain log, the `--max-parallel-archs`
usage default; see CHANGELOG 2026-10-22.

- **RV1 — every edit of `base-image.sh` re-runs the base and the toolchain [M, ★★★].** Six of the nine
  base RUNs bind-mount it (`Dockerfile.base`), so a retry-default edit re-runs them (about 8 min of
  step time in `base.log`). The compiler stage then gets a new base and its first heavy RUN (2/14,
  34 min of source build) runs again. Work: mount per RUN only the scripts that step reads.
- **RV2 — the S3 level stored 2177 objects and served none [S, ★★★, investigate first].**
  `compiler.log`: `sccache-drain| every upload done after 0 s (L1 (s3): 2177 written, 0 failed of 2177)`.
  Find which part of the cache key changed before calling it a fix.
- **RV3 — ten standalone helpers keep an output contract [decide per script].** Lint scripts print
  `ERROR:` and have tests on it; `lint-shell` draws ✓/✗; `docs-site` prints `::error` annotations;
  `probe-sccache` has its own report; `git-sync-branches` counts through a file. Six more
  (`build-hailort`, `install-litert-web`, `build-hadolint`, `install-lint-tools`, `smoke-common`,
  `uv-cache-seed`) are bind-mounted into Dockerfiles: they need `logging.sh` in those RUN mounts, which
  re-keys the stage. Do them with the next build.
- **RV4 — `check-target-toolchain.sh` is not wired into any stage [S, ★★].** The musl-loader failure
  of 2026-10-22 would have stopped at the package stage, not after the wrapper. Wiring it re-keys the
  package stage, so do it with the next package change.
- **RV5 — disk policy in three places [M].** `_chain_disk_preflight`, `_chain_stage_disk_guard`
  (`build-cross-chain.sh`) and `disk-guard.sh` (trim and watch). The DISK entries are archived as
  closed; check the consolidation against them first.
- **RV6 — environment knobs [L].** 169 knobs read on the chain path, 985 across the scripts;
  `lint-env-knobs.allow` has 491 rows. `chain-latest.env` is the first step: a profile in place of
  the operator's exported variables.
- **RV7 — `cross-android-*` tags carry every arch [M].** Thirty references in the scripts; the name
  says Android for amd64, arm64 and riscv64. Rename to `cross-artifacts-*` with a migration of the
  existing tags.
- **RV8 — masking on the chain path [L].** `|| true` (1195) and `2>/dev/null` (1478) across the tree.
  The `masked-assignments.allow` and `trailing-conditional.allow` gates cover single classes only.
  Audit per site with a verdict.

Not taken: the wrapper pair `runtime_build_wrapper_image` / `_rootfs` repeats the build, gate and
ship order. About three lines each; the overlap test pins the order, so leave it until the wrapper
changes again.

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
  `main` 5 valued flags × 11 commands), feature tables (`_ffmpeg_probe_core_codecs`
  is fifteen `if probe; then --enable-<codec>` lines and nothing else), and two rows
  where the metric is simply literal — `dump_debug_info` (cc 23) holds one decision
  (the `HOST_PYTHON` guard) and otherwise ~20 which-then-`--version` pairs each
  swallowed, and `_torch_run_setup_py` counts the size of torch's build environment.
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

**Two rows were given a "do not do the obvious thing" verdict; one is a row today.**
`verify_comment_size.blocks` (nesting 6) is not in `code-complexity.allow`:
`_walk_scan` holds the walk and `blocks` measures cc 9, nesting 4 (2026-09-25;
the one nesting row is `smoke-android.sh check_ndk`, 7). Its verdict still stands
for the walk: importing `verify_code_size.scan` would NARROW the scan by
`SKIP_DIRS 'patches'` (the gate's own `SCAN` comment says why), which changes the
gate's scope and needs a fresh `comment-size.allow` baseline. And
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
99 functions (2026-09-25; 91 on 2026-09-18) are the `check_*` / `_probe_*`
assertions and the probe-and-verdict layer they share, all over one image through
one `_rt_run` under one `main()`. Its
length is the number of assertions it makes about the shipped bytes, and that
number growing is the gate succeeding.

**`lib/app-packaging.sh` crossed 800 on 2026-09-17** (CON2's scope probe + CON6's
finish-args block, 797 → 851); the row carries the NOT-a-split reason and the seam
that kept it that way. Record in
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md).

**Standing context, not a block:** `git push` is the agent's (2026-09-06) via
`gh auth setup-git` + HTTPS remotes, and twelve of the fifteen `*.sh` files in
`linux/scripts/lib/` source a sibling `lib/log-bootstrap.sh` (2026-09-25) — a
consumer that copied ONE `lib/*.sh` file out on its own breaks on its next CI run,
not here.
