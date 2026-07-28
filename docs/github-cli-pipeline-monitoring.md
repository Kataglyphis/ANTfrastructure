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

# One workflow
gh run list --workflow "Linux build + test + coverage on Ubuntu 24.04 x86"

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

A run reporting `skipped` is not a pass. Several workflows here are gated (the
Windows container build is gated on `[build-win]` appearing in the commit
message), and a gated-off workflow reports `skipped`, which is easy to read as
success at a glance.

## Scope

Reading status, logs, and re-running failed jobs is routine. **Cancelling other
people's runs, editing workflow files to make a failure go away, or disabling a
workflow is not** — a failing pipeline is information, and the fix belongs in
the code that failed.
