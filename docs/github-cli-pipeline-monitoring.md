# GitHub CLI: Reading and Fixing Pipeline Status

The `gh` CLI is the supported way to read CI status for these repositories from
a Windows dev box. It replaces opening the Actions tab in a browser, and — more
importantly for an agent — it makes "is the pipeline green?" a question that can
be answered from a shell, on a schedule, without a human looking at anything.

## Install and PATH

Installed via winget:

```pwsh
winget install --id GitHub.cli
```

**A shell that was already open when `gh` was installed will not find it.**
winget adds the install directory to the user PATH, and existing processes keep
the environment they started with. This bites agents specifically, because a
long-running session's shell predates the install and reports
`gh: command not found` for a tool that is present and working.

Two ways out, in order of preference:

1. Start a new shell.
2. Call it by full path: `C:\Program Files\GitHub CLI\gh.exe`.

The Git Bash tool has its own PATH and may not see winget's user PATH at all
even in a fresh shell. **Prefer PowerShell for `gh`.**

Verify:

```pwsh
gh --version
gh auth status
```

`gh auth status` must show the account and, critically, the token scopes.
Reading Actions logs needs `repo`. A token with only `read:org` and `gist` will
list runs and then fail on `--log-failed` with a permissions error that does not
mention scopes.

## Reading pipeline status

Run from inside the repository — `gh` infers the repo from the git remote.

```pwsh
# What ran recently, and what did it conclude?
gh run list --limit 10

# Only the failures
gh run list --limit 20 --status failure

# One workflow, by FILE name: the same in every repo of the family
# (adopting-in-a-new-project.md § Workflow file names and display names)
gh run list --workflow linux-x64.yml

# Watch an in-progress run to completion
gh run watch <run-id>

# Re-run just the failed jobs
gh run rerun <run-id> --failed
```

## Finding out WHY a run failed

This is the part that is easy to get wrong, and the ordering below is the whole
point of this document.

**Do not start with `gh run view <id> --log-failed`.** It emits the entire log
of every failed job — for these builds that is tens of thousands of lines,
including the full `llvm-ar` command line for the antlr4 runtime, which alone is
a single ~15 KB line. Grepping it for `error` returns mostly the runner's own
apt-get cleanup echoes. It will fill a context window and tell you nothing.

**Start by asking which step failed:**

```pwsh
gh run view <run-id> --json jobs --jq '.jobs[] | .name + " => " + .conclusion, (.steps[] | select(.conclusion=="failure") | "   FAILED STEP: " + .name)'
```

That returns one or two lines — e.g. `FAILED STEP: Run fuzzer tests` — which is
usually enough to know where to look, and always enough to grep the full log
with a pattern that matches the actual failure rather than the word "error".

Only then go to the log, filtered:

```pwsh
$log = gh run view <run-id> --log-failed | Out-String
$log -split "`n" | Select-String "SUMMARY:|FAILED|Fatal" | Select-Object -Last 20
```

`SUMMARY:` is the useful anchor for sanitizer failures (ASan/UBSan print it as
the last line of a report). `[  FAILED  ]` is the GoogleTest anchor.

## Periodic checking

The intended cadence for an agent working this repository: **check CI after
every push, and again before starting unrelated work.** The reason is specific
to this project — the Linux lane runs configurations the Windows dev box does
not. ASan/UBSan fuzzing runs there and not here, so a class of bug exists that
is *only* observable through CI. A green local `commitTestSuite.exe` is not
evidence that the pipeline is green.

```pwsh
# Did my last push survive?
gh run list --limit 5 --json conclusion,name,headBranch,displayTitle --jq '.[] | .conclusion + "  " + .name'
```

A run reporting `skipped` is not a pass. The platform lanes carry no `if:` since
2026-09-24, but some jobs still do (a reusable workflow's input-gated jobs), and
a gated-off job reports `skipped`,
which is easy to read as success at a glance
([`ci-build-triggers.md`](ci-build-triggers.md)).

## A red develop opens an issue

`develop-red.yml` (*Develop red · watch*, at :13 and :43 every hour) reads the `develop` runs of
every family repository: the owner's own, not a fork, not archived, default branch `develop`. When
a workflow's push, dispatch or scheduled run fails, it opens one issue in this repository,
`develop is red: <repo> · <workflow>`, labelled `develop-red`, listing each red job with its run.
It updates the issue as runs come in and closes it once every listed job passed on `develop` again.

```bash
gh issue list -R Kataglyphis/ANTfrastructure -l develop-red   # empty: every develop is green
```

- Cancelled, skipped and pull-request runs decide nothing. A red run with no red job (a startup
  failure has none) lists `(the run itself)`.
- The newest run of a job decides it, so a green run of another lane through `on-request.yml` or
  `release.yml` keeps the issue open, and a re-run of an older commit never closes it.
- A red job absent, not skipped, from two green runs newer than its red one was renamed or
  removed: the watch retires it and names it in the closing comment. A nested `A / B` is retired
  only when its caller `A` ran in both, since a skipped caller hides every nested job. A closed
  issue marks the runs it covered, so the watch does not reopen it on them.
- An open issue always reads its workflow's own `develop` runs
  (`/actions/workflows/{id}/runs`), and so does a red run before it opens an issue: the
  repo-wide page holds 100 runs of all workflows and can miss or lag one. An open issue whose
  workflow is deleted or disabled (`/actions/workflows/{id}`) closes with that reason, and such a
  workflow opens no issue. The issue list is read page by page.
- An API GET that answers 5xx is tried four more times (5, 10, 20, 40 s), so a burst of bad
  gateways does not turn the watch itself red. A write is never repeated: it may have landed. A
  repository whose answers never come is named on stderr, the other repositories still settle,
  and the run exits 1.
- `develop-red-selftest.yml` concludes as its `outcome` input says: dispatch it with `failure` and
  then the watch to see an issue open, with `success` to see it close.

One hub workflow on the hub's `GITHUB_TOKEN` (every family repository is public): no file in a
consumer, no secret. Logic and cases: `linux/scripts/develop_red.py`,
`linux/scripts/tests/test-develop-red.sh`.

## The orientation AGENTS.md carried

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading, the relative links and the `skipped` bullet (the opt-in markers it named were retired on 2026-09-24). The RULES stayed there; this is the reference behind them.

**Check the pipeline after every push, and again before starting unrelated
work.** `gh` is installed (winget) and authenticated; see
[`docs/github-cli-pipeline-monitoring.md`](github-cli-pipeline-monitoring.md).

```pwsh
gh run list --limit 10
```

To go from a run id to the failing STEP, use the `--jq` recipe in
[`docs/github-cli-pipeline-monitoring.md`](github-cli-pipeline-monitoring.md)
— that page owns the query, so it is maintained in one place.

Three things that will otherwise cost you an hour:

- **A shell opened before the winget install cannot find `gh`.** Use a new
  shell, or `C:\Program Files\GitHub CLI\gh.exe`. Prefer PowerShell — Git
  Bash may not see winget's user PATH at all.
- **Never open with `gh run view --log-failed`.** It dumps every failed job's
  full log — one antlr4 `llvm-ar` line alone is ~15 KB — and grepping it for
  `error` mostly returns the runner's apt-get cleanup echoes. Ask which STEP
  failed first (command above), then grep the log for `SUMMARY:` (sanitizers)
  or `[  FAILED  ]` (GoogleTest).
- **`skipped` is not a pass.** A gated job (a reusable workflow's input-gated
  jobs) reports `skipped`, which reads as success at a glance.

Green local tests do not imply green CI: the Linux lane runs ASan/UBSan fuzzing
that the Windows dev box does not, so some bugs are only ever observable there.
Fix what failed — do not edit the workflow to silence it.

## Scope

Reading status, logs, and re-running failed jobs is routine. **Cancelling other
people's runs, editing workflow files to make a failure go away, or disabling a
workflow is not** — a failing pipeline is information, and the fix belongs in
the code that failed.

## Preserved source CI evidence

The recurring Hub evidence drivers are versioned under `linux/scripts/`. Use their explicit source,
branch and output arguments instead of recreating a dated script in `logs/`. The Python entry point
requires the sibling `source_ci/` modules and `host_commands.py`; no package installation is needed.
`--help` lists the arguments for each subcommand.

```bash
python3 linux/scripts/source-ci.py dispatch --repo Kataglyphis/ANTfrastructure \
  --head FULL_SHA --branch FEATURE_BRANCH --output logs/test-results/dispatch.json
python3 linux/scripts/source-ci.py fetch --dispatch logs/test-results/dispatch.json \
  --root . --directory logs/test-results/source-logs
```

Dispatch covers Linux, Windows, docs, Renovate and security gate mode. It checks the remote head,
reuses a single matching existing run and reserves the dispatch record exclusively. Before a new
request it persists an ambiguous/in-progress state; it never retries a workflow write. If interrupted,
resolve that run ID from GitHub and repair the record after inspection rather than dispatch again.
Multiple existing matches require inspection. Do not start a second driver with another output path.

Fetch observes those recorded runs only, requiring successful direct `workflow_dispatch` source
identity. It retains complete job metadata, original logs, the local/remote tree binding and the native
Windows test archive/API digest. Downloads preserve bytes exclusively; a failed HTTP response cannot
become a cached successful log. Reusing the directory resumes absent downloads without replacing
preserved evidence. Existing failed evidence requires a separate attempt directory.

Run `audit-linux` with `--root`, `--head`, `--run`, `--jobs`, `--tree-binding`, `--log-dir` and `--output`.
It reads the manifest from that Git revision, checks every shard's actual ID union and the
nonvacuous preflight summary. Run `audit-windows` with `--zip`, `--api`, `--prior-proof`, `--root` and
`--output`; the prior proof must be an independently audited coverage baseline. Its coverage policy
must be byte-identical to the tested revision, otherwise re-audit it before proceeding. The archive
must match its API digest and prove every native test/coverage floor without skips or broken cases.

Finally, `audit-all --dispatch RECORD --directory LOGS --linux LINUX_PROOF --windows WINDOWS_PROOF
--output PROOF` binds both subproofs to their actual runs, rechecks their logs/archive and requires all
five workflows. Only the feature-branch docs publication job may be skipped. These receipts prove
source workflows only; hardware inference, product image acceptance and packaged detector parity
remain separate. Output proof files are exclusive and historical evidence is never overwritten.

`test-source-ci.sh` uses synthetic metadata, logs and archives for failure cases; the cache command
has `test-capture-sccache-command.sh`. Their mutations must fail assertions. These fixtures do not
contact GitHub, run real compiler builds or certify GPU availability.
