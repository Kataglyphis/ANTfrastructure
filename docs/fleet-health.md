<!--
Copyright (c) 2026 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Fleet health — one weekly verdict for the AI repos

`linux/scripts/fleet-health.py` measures AccelerANTgine, OxidANT, OrchestrANT and
OmniAccelerANT, merges their tree metrics with GitHub state, grades the result against an
earlier record and stores it. `.github/workflows/fleet-health.yml` runs it every Monday.

## The measuring tools

| Tool | What it measures | Owning page |
| --- | --- | --- |
| `quality-report.sh` | One checkout's tree metrics (Ruff, ty, duplication, size, complexity, allow rows, suppressions) and its lane artifacts | [`code-quality-tooling.md` § quality-report](code-quality-tooling.md#quality-report) |
| `security-audit.sh` | Lockfile advisories with osv-scanner; artifact `security-audit` | [`vulnerability-scanning.md`](vulnerability-scanning.md#lockfile-audit-security-auditsh) |
| `bench-history` | A benchmark result against earlier default-branch results; artifact `bench-history-<key>` | [`code-quality-tooling.md` § Benchmark history](code-quality-tooling.md#benchmark-history) |
| `quality-report.sh --perf-host` | Planned, not built yet: runs the latency commands a repo declares in `quality-report.toml` on a quiet host | — |
| `fleet-health.py` | All of the above for the four repos, plus GitHub state | this page |

## Running it

```bash
python3 linux/scripts/fleet-health.py --clone --compare previous-run
python3 linux/scripts/fleet-health.py --repos OrchestrANT --local-root ~/work --compare logs/reports/fleet-health/2026-11-02.json
```

- `--repos` takes a comma list; the default is the four repos above.
- `--clone` clones each develop tip with its direct submodules into a scratch directory (the
  same checkout the repo's own `code-quality-report.yml` job makes) and measures that.
- `--local-root DIR` measures `DIR/<repo>` as it is. It records the SHA and refuses a checkout
  that is missing, dirty (`git status --porcelain`, nested submodule edits ignored) or behind
  `origin/develop` after a fetch. Local commits ahead of `origin/develop` are measured; their
  artifact metrics are not collected, since no lane ran on them.
- `--compare` takes a record path, or `previous-run`: the newest unexpired `fleet-health-json`
  artifact of a successful develop run of `fleet-health.yml` other than the current one.
  Without `--compare`, or on a first run, nothing is graded.

Tokens: `GH_TOKEN`, `GITHUB_TOKEN` or the `gh` login reads runs, artifacts, issues and the hub
compare. The alert endpoints use `FLEET_HEALTH_TOKEN` when it is set. Without any token, or on a
401, 403 or 404 answer, a metric is not collected. The GitHub client is `develop_red.py`'s: a GET
that answers 5xx is retried four times (75 s), and one still failing is a failed measurement.

## Metrics

Per repo, under `repos.<repo>.metrics`:

| Metric | Class | Source |
| --- | --- | --- |
| Every metric of the repo's `measurements.json` | as recorded (`code` or `report`) | the checkout's `scripts/linux/quality-report.sh --offline` |
| Artifact metrics (`tests_passed.*`, `line_coverage.*`, `mutations_caught.*`, …) | `code` | the `code-quality-measurements` artifact of a run at the same SHA; else not collected |
| `ci.<workflow>.success_rate`, `ci.<workflow>.median_minutes` | external | the last 20 completed develop runs of each active workflow from push, dispatch or schedule, conclusion success or failure |
| `dependabot.open.<severity>` | external | open Dependabot alerts (a 100th alert makes it not collected: cursor pages are not followed) |
| `dependabot.high_critical_ids` | advisory | the GHSA ids of the HIGH and CRITICAL ones |
| `code_scanning.open.<severity>` | external | open code-scanning alerts by security severity, `other` when the rule has none |
| `code_scanning.open_on_absent_paths` | external | open code-scanning alerts whose path is missing from the checkout |
| `code_scanning.days_since_analysis` | external | age of the newest code-scanning analysis |
| `secret_scanning.open` | external | open secret-scanning alerts; GitHub gives them no severity |
| `develop_red.open_issues` | external | open hub issues labelled `develop-red` that name the repo |
| `hub_pin.lag_commits` | external | hub develop commits the `third_party/ANTfrastructure` gitlink lacks |
| `security_audit.verdict`, `security_audit.findings.<severity>` | external | the newest develop `security-audit` artifact |
| `security_audit.high_critical_ids` | advisory | the HIGH and CRITICAL advisory ids in it |
| `bench_history.<artifact>.verdict` | external | the newest develop artifact of each `[[output]] kind = "benchmark"` row in `quality-report.toml` |
| `ai_regression.verdict` | external | the newest completed develop run of `ai-regression.yml`; not collected where there is none |

Under `repos.fleet.metrics`, the shared-facts check is a `code` metric: `shared_facts.models_lock_deim`
compares the DEIM rows of each repo's tracked `models.lock`, and
`shared_facts.llm_lock_smollm2` the SmolLM2 rows of each `llm.lock`, across OxidANT,
AccelerANTgine and OrchestrANT. The value is the number of distinct row sets minus one, so 0
means they agree. When a repo is not in the run, or a file is absent, the metric is not
collected and the reason names what exists.

## Grades and verdict

| Grade | Meaning |
| --- | --- |
| `improved`, `held`, `regressed` | a collected `code` or `advisory` metric against the baseline's collected value; a set (members) regresses on any new member even when its count holds |
| `moved` | an `external` or `report` metric; shown with before and now, never graded |
| `new` | collected now, but the baseline has no collected value: a first run or a new metric |
| `not-collected` | no value; printed as `not-collected: <repo>/<metric> (<reason>)`, never graded held |
| `failed` | the measurement broke; printed as `failed: <repo>/<metric> (<reason>)` |

The run prints `fleet-health: verdict=<ok|regressed|incomplete> regressed=<n> improved=<n> metrics=<n>`
(`metrics` counts collected ones), a `compare:` line and one
`REGRESSED <repo>/<metric> <before> -> <now>` line per regression.

| Exit | Verdict | When |
| --- | --- | --- |
| 0 | ok | no code metric regressed and no HIGH or CRITICAL advisory id is new |
| 1 | regressed | a code metric regressed, or a HIGH or CRITICAL advisory id appeared |
| 2 | incomplete | a checkout was missing, dirty or stale, a quality-report run broke, a 5xx or timeout outlived the retry, or the compare file is malformed |

Exit 2 wins over 1, and the regressions still print.

## Storage

Each run writes `logs/reports/fleet-health/<date>.json` and `<date>.md` (ignored by Git; a
second run on the same day overwrites them). The JSON holds `schema_version` 1, `kind`
`fleet-health`, `date`, `mode`, `hub_sha`, `baseline`, `verdict`, `problems`, the `regressed`,
`improved`, `not_collected` and `failed` rows, and per repo its `sha`, checkout, quality-report
command and every metric with `value`, `unit`, `better`, `class`, `status`, `grade` and
`before`. The workflow uploads the JSON as artifact `fleet-health-json` for 90 days; that
artifact is what `previous-run` reads next week.

## The workflow

`fleet-health.yml` runs on cron `0 9 * * 1`, after consumer-inventory's Monday 07:00 UTC run,
and on workflow_dispatch. It runs `--clone --compare previous-run`, writes the Markdown to the
step summary and uploads the record. It fails only on exit 2 (or a crash), which
`develop_red.py` then reports like any red develop run. On exit 1 it opens or updates exactly
one hub issue labelled `fleet-health`, never `develop-red`, naming each regressed metric; the
next run that exits 0 closes it. An exit-2 run leaves the issue alone. The optional secret
`FLEET_HEALTH_TOKEN` is a read-only token for the alert endpoints; without it those metrics are
not collected and the run still succeeds.

## Baselines

The first `fleet-health.yml` dispatch after the tool landed is the goal's baseline; its run id
and record are named in the goal's final report. Later runs compare with the previous
successful run, so a regression is reported once, in the week it appeared; compare with an
older record by passing its JSON with `--compare`.

## Owner routine

1. On Monday, read the run's step summary or the open `fleet-health` issue.
2. For each `REGRESSED` line, find the commit with `quality-report.sh` on the commits that
   touched the metric's files, then fix it or record it in that repo's `BACKLOG.md`.
3. Read the `moved` rows for trends: a falling success rate or a growing pin lag needs no
   commit to appear.
4. A red run is a measurement failure: read its `failed:` lines, fix the cause and dispatch
   again.

## What it does not do

It does not attribute a change to a commit, rerun a lane, or follow Dependabot's cursor pages.
Report-class and external metrics are never graded. Artifact metrics exist only for SHAs whose
`code-quality-report.yml` run finished. `linux/scripts/tests/test-fleet-health.sh` replays
recorded GitHub answers and local Git fixtures; it covers neither live GitHub nor `--clone`.
