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
[`…-archive-2026-09-17.md`](refactoring-backlog-archive-2026-09-17.md),
[`…-archive-2026-10-23.md`](refactoring-backlog-archive-2026-10-23.md).
This file shows OPEN work only + CHANGELOG.md + memory — do not resurrect
without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary (only the prefixes this OPEN file still uses): **RV#**=the chain review,
**F2**=the remaining file-size register. Image gaps (**CON7** onwards) live in the root
[`BACKLOG.md`](../BACKLOG.md).
Everything else is archive-only: **CON1–CON6** closed 2026-09-17/18 (the consumer
issues, the last one measured and aligned at Flutter 3.47.4), **EX** closed on
2026-09-07/09 (the extent gates scan `linux/llm-stack` and froze its rows),
**VK/AS** closed on 2026-09-17, **CC/CL/CS/AB/R#/YB/DISK/APP** on 2026-09-07,
**HT/GH** before them, **QW/TC/SMK** in the 2026-09-04 waves, and the rest long
before that.

Last groomed: **2026-10-23**, against merged source `657f2803` and its recorded gates.
F1 is complete and archived; the chain review and file-size work remain open.
Earlier grooming's warning still applies: **re-derive; do not trust a number here.**

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

### F2. Files over ~800 lines [L each]

**`file-size.allow` is the authority; re-run the gate before choosing a target.** The wheelhouse,
Vulkan driver, chain driver and runtime test driver now fit below the limit. Their libraries
remain in the scan. Explicit sourcing, SDK COPY wiring and behavioral suites cover the splits.

The remaining rows are the media Dockerfile and runtime smoke driver. Earlier
KEEP verdicts record the constraints a split must preserve; they do not prohibit improvements.
The smoke must still call every assertion, and Dockerfile changes must preserve narrow
build-input closures and cache order.

**Standing context, not a block:** `git push` is the agent's (2026-09-06) via
`gh auth setup-git` + HTTPS remotes, and twelve of the fifteen `*.sh` files in
`linux/scripts/lib/` source a sibling `lib/log-bootstrap.sh` (2026-09-25) — a
consumer that copied ONE `lib/*.sh` file out on its own breaks on its next CI run,
not here.
