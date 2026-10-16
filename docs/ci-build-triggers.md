# CI Build Triggers: which lanes run when

**The rule is [`branch-and-release-strategy.md`](branch-and-release-strategy.md)**
(owner, 2026-10-15): a push to `develop` runs the Linux x64 lane, every other lane
runs when a commit message asks with `[ci <lane>]` or when started by hand, and a
push to `main` runs every lane and releases only when all are green. The
repositories move to it one at a time, so this page says what each one does today.
The file names are one per platform and arch since 2026-09-24
([`adopting-in-a-new-project.md` § Workflow file names and display names](adopting-in-a-new-project.md#workflow-file-names-and-display-names)).

## The consumer lanes

| Repository | On every push to `develop` | On request, and on `main` |
|---|---|---|
| OmniAccelerANT (since 2026-10-15) | `linux-x64.yml`; `submodule-pins.yml` when a pin moves | `linux-arm64`, `windows-x64`, `windows-arm64`, `android`, `web` through `on-request.yml`; all of them through `release.yml` on `main` |
| OxidANT (since 2026-10-15) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` when a pin moves | `linux-arm64`, `linux-riscv64` (also weekly), `windows-x64`, `windows-arm64-cross` through `on-request.yml`; all five through `release.yml` on `main` (since 2026-10-16; the version is `Cargo.toml`'s) |
| AccelerANTgine (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` when a pin moves | `linux-arm64`, `linux-riscv64`, `windows-x64`, `windows-arm64-cross` through `on-request.yml`; all five through `release.yml` on `main` (since 2026-10-16; the version is `CMakeLists.txt`'s `project()`) |
| BeschleunigerBallett (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` | `linux-arm64`, `linux-riscv64` (its GPU shards also weekly), `windows-x64`, `windows-arm64-cross` through `on-request.yml`; no `release.yml` yet |
| OrchestrANT (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` when a pin moves | `linux-arm64`, `linux-riscv64`, `windows-x64`, `windows-arm64-cross` through `on-request.yml`; no `release.yml` yet, and a pushed `v*` tag still runs the four releasing lanes, which attach their packages, so `on-request.yml` grants three of them `contents: write` |
| WebDavClient (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml` | `linux-arm64`, `windows-x64`, `windows-arm64` through `on-request.yml`; all four through `release.yml` on `main` (since 2026-10-16; the version is `VERSION.txt`'s) |

jotrockenmitlocken builds and deploys its site on every push (`web.yml`), and ANThology
and DocumANTation run only their docs; none of the three has a platform lane to request.

What else decides whether a lane runs:

- **Path filters.** BeschleunigerBallett's Linux x64 lane ignores a push that
  touches only `**.md` or `docs/**`. Most `submodule-pins.yml` callers run only
  when `.gitmodules` or `third_party/**` changes. A workflow that a path filter
  leaves out does not start at all; it does not report `skipped`.
- **Push only.** jotrockenmitlocken's `web.yml` builds and deploys on a push, not
  on a PR.

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

## 2026-09-24 to 2026-10-15

Every platform lane ran on every push and PR, with no commit-message opt-in and no
`if:` on any platform job. The repositories that have not moved still work this way.

## Before 2026-09-24

The Windows lane and the Linux arm64 lane were opt-in per commit: `[build-win]` or
`[build-arm]` had to be in the pushed HEAD commit's message
(`github.event.head_commit.message`), or the workflow reported `skipped`. A
consumer note, a run log or a commit message from before that date may still
name those two tokens; nothing acts on them any more. Today's tokens have a
different form, `[ci <lane>]`, and are read by `on-request.yml`.
