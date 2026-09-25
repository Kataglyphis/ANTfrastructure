# CI Build Triggers: which lanes run when

**Every platform lane runs on every push and PR** (owner decision 2026-09-24,
fleet-wide). The `[build-win]` and `[build-arm]` commit-message opt-ins are
retired: no workflow in the family reads them, and no platform job carries an
`if:`. The file names changed the same day, to one file per platform and arch
([`adopting-in-a-new-project.md` § Workflow file names and display names](adopting-in-a-new-project.md#workflow-file-names-and-display-names)).

## The consumer lanes

| Lane | Workflow files | Trigger |
|---|---|---|
| Linux x64 and arm64 (build + test) | `linux-x64.yml`, `linux-arm64.yml`, most over a shared `reusable-linux.yml` (OrchestrANT: one `ubuntu-26.04-amd64-arm64.yml` for both) | every push and PR to `main`/`develop` |
| Windows x64 | `windows-x64.yml` | the same |
| Windows arm64 (cross build, then a run on `windows-11-arm`) | `windows-arm64-cross.yml` in OxidANT, AccelerANTgine and BeschleunigerBallett | the same |
| Android, web | OmniAccelerANT's `android.yml` and `web.yml` | the same |

Measured 2026-09-25 against the consumer checkouts. What is left is not a
commit-message token on a platform lane:

- **Path filters.** BeschleunigerBallett's four platform lanes ignore a push that
  touches only `**.md` or `docs/**`. Most `submodule-pins.yml` callers run only
  when `.gitmodules` or `third_party/**` changes. A workflow that a path filter
  leaves out does not start at all; it does not report `skipped`.
- **Push only.** jotrockenmitlocken's `web.yml` builds and deploys on a push, not
  on a PR.
- **One opt-in job.** OxidANT's `linux-x64.yml` carries a feature check
  (`feature-matrix`) that runs only with `[build-features]` in the HEAD commit
  message, or on `workflow_dispatch`. It is not a platform lane, and its
  `skipped` does not skip the workflow around it.

## This repository's lanes

None of them builds a container image. The image chains run on the build hosts.

| Workflow | Trigger |
|---|---|
| `linux-x64.yml` | every push and PR to `main`/`develop`: preflight, the mutation gate in four shards, the docs build |
| `windows-x64.yml` | push/PR that touches `windows/**`, `shared/windows/**`, `versions.env` or the workflow itself |
| `llm-stack-serving.yml` | push/PR that touches `linux/llm-stack/**` |
| `submodule-pins.yml` | push/PR that touches `.gitmodules`, `third_party/**` or the pin suite |
| `actions-selftest.yml` | push/PR that touches `.github/actions/**`, Mondays, and dispatch |
| `consumer-inventory.yml` | Mondays, dispatch, and push/PR that touches its own inputs |
| `ghcr-cleanup.yml` | Sundays, dispatch |
| `sbom.yml`, `stale-docs-check.yml` | Mondays, dispatch |

`build-docs.yml`, `container-ci-windows.yml`, `lint-gates.yml` and the two
`python-ci-*` workflows are `workflow_call` only: they run when a caller runs.

## A `skipped` job is still not a pass

A job with an `if:` reports `skipped` when the condition is false, and a badge or
`gh run view` shows that like a success. Such jobs remain: the feature check above,
`python-ci-windows.yml`'s build and lint jobs (each gated by an input), and
`container-ci-windows.yml`'s `windows-11-arm` run job (only with `target-arch:
arm64` and a `run-command`). Read the conclusion per job:
[`github-cli-pipeline-monitoring.md`](github-cli-pipeline-monitoring.md).

## Before 2026-09-24

The Windows lane and the Linux arm64 lane were opt-in per commit: `[build-win]` or
`[build-arm]` had to be in the pushed HEAD commit's message
(`github.event.head_commit.message`), or the workflow reported `skipped`. A
consumer note, a run log or a commit message from before that date may still
name the tokens; nothing acts on them any more.
