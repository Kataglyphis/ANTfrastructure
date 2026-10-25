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
| OxidANT (since 2026-10-15) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` when a pin moves | `linux-arm64`, `linux-riscv64` (also weekly), `windows-x64`, `windows-arm64-cross` through `on-request.yml`; all five through `release.yml` on `main` (since 2026-10-16; the version is `Cargo.toml`'s; first: v2.3.4, 2026-10-16) |
| AccelerANTgine (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` when a pin moves | `linux-arm64`, `linux-riscv64`, `windows-x64`, `windows-arm64-cross` through `on-request.yml`; all five through `release.yml` on `main` (since 2026-10-16; the version is `CMakeLists.txt`'s `project()`; first: v0.0.1, 2026-10-16) |
| BeschleunigerBallett (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` | `linux-arm64`, `linux-riscv64` (its GPU shards also weekly), `windows-x64`, `windows-arm64-cross` through `on-request.yml`; all five through `release.yml` on `main` (since 2026-10-16; the version is `VERSION.txt`'s, the notes come from the `CHANGELOG.md` it gained that day; first through it: v1.5.0, 2026-10-17) |
| OrchestrANT (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml`; `submodule-pins.yml` when a pin moves | `linux-arm64`, `linux-riscv64`, `windows-x64`, `windows-arm64-cross` through `on-request.yml`; all five through `release.yml` on `main` (since 2026-10-16; the version is `VERSION.txt`'s). It replaced the pushed `v*` tags, whose four lanes each attached their own packages. Its dry run for 0.0.31 passed all 13 jobs on 2026-10-17 (38955101443), Windows arm64's pyyaml on CPython 3.15 included |
| WebDavClient (since 2026-10-16) | `linux-x64.yml` and `lint-gates.yml` | `linux-arm64`, `windows-x64`, `windows-arm64` through `on-request.yml`; all four through `release.yml` on `main` (since 2026-10-16; the version is `VERSION.txt`'s; first through it: v0.10.0, 2026-10-16) |

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

**None of them builds a container image.** The image chains run on the build hosts
(`windows/Build-Buildkit.ps1`, `linux/scripts/build-cross-chain.sh`), and no workflow here
reacts to a commit-message token. Both name columns follow the family's naming convention
(2026-09-24); the purposes were the README's CI table until 2026-10-19.

| Workflow | Shown as | Trigger | What it runs |
|---|---|---|---|
| `linux-x64.yml` | Linux x64 · preflight + mutation gate | every push and PR to `main`/`develop`, and dispatch | the shell preflight gate suite and its mutation gate as eight sharded jobs |
| `docs.yml` | Docs · build + publish | every push and PR to `main`/`develop`, and dispatch | the hub's site through `build-docs.yml`: `build-docs.sh`, the link gate, and on a push the upload |
| `windows-x64.yml` | Windows x64 · script tests | push/PR that touches `windows/**`, `shared/windows/**`, `.github/actions/**`, `versions.env` or the workflow itself, and dispatch | PowerShell lint, strict complexity with an uploaded JSON report, `windows/scripts/tests`, and targeted Pester coverage reports |
| `python-refactor.yml` | Python refactor · patch preview | dispatch or `workflow_call`, with one tracked Python file path | pinned safe Ruff fixes and formatting, quality checks, then an uploaded patch and logs; read-only repository token |
| `python-static.yml` | Python static analysis (reusable) | dispatch or `workflow_call` | uv-locked Ruff and ty over tracked Python; reports findings by default and gates them with `strict: true` |
| `code-quality-report.yml` | Code quality measurements (reusable) | dispatch or `workflow_call` | rooted size, complexity and duplication reports under ignored `logs/` |
| `windows-arm64.yml` | Windows arm64 · bundle device gate | daily, dispatch, and a push that touches the gate's files | a `windows-2025` job packs the published `:winarm64` runtime bundle, a `windows-11-arm` job runs `Test-Arm64Bundle.ps1` over it |
| `llm-stack-serving.yml` | LLM stack · serving | push/PR that touches `linux/llm-stack/**` | the compose shape and the backend registry. The NAS census test left with the census tool for OrchestrANT on 2026-09-15 |
| `submodule-pins.yml` | Submodule pins (reusable) | push/PR that touches `.gitmodules`, `third_party/**` or the pin suite; also `workflow_call` | the submodule-pin invariant suite, including consumers that use a separate hub checkout |
| `actions-selftest.yml` | Composite actions · self-test | push/PR that touches `.github/actions/**`, Mondays, and dispatch | the composite actions under `.github/actions/` exercised against themselves; dispatch adds the deep Windows lane |
| `consumer-inventory.yml` | Consumers · inventory | Mondays, dispatch, and push/PR that touches its own inputs | clones every repo in `.github/consumers.json` and grades who still calls each hub entry point; files an issue when a reference dangles |
| `ghcr-cleanup.yml` | GHCR · cleanup | Sundays, dispatch | `ghcr-prune-package.sh` deletes untagged versions no kept tag references; every tagged version stays, 14-day age guard |
| `sbom.yml` | SBOM | Mondays, dispatch | SBOM generation |
| `stale-docs-check.yml` | Docs · stale check | Mondays, dispatch | stale doc references and broken script paths |
| `develop-red.yml` | Develop red · watch | twice an hour, dispatch | one `develop-red` issue per family workflow whose `develop` run is red, closed once it is green ([`github-cli-pipeline-monitoring.md`](github-cli-pipeline-monitoring.md#a-red-develop-opens-an-issue)) |
| `develop-red-selftest.yml` | Develop red · self-test | dispatch | fails or passes as its `outcome` input says, to prove the watch |

The `workflow_call` ones run when a caller runs:

| Workflow | Shown as | What it runs |
|---|---|---|
| `build-docs.yml` | Docs · build + publish (reusable) | builds a docs site in the image, adds the hub's `.htaccess`, checks its links, and publishes it on a push to `develop` or `main` ([`docs-sites.md`](docs-sites.md#the-reusable-workflow)) |
| `python-ci-linux.yml` | Python CI · Linux (reusable) | Python lint and tests on Linux, for consumer repos; never triggers here. `arches` picks the rows (default `x64 arm64`) |
| `python-ci-windows.yml` | Python CI · Windows (reusable) | the same for Windows |
| `lint-gates.yml` | Lint gates (reusable) | `run-lint-gates.sh` over a consumer tree, with duplication reporting by default and a separate strict input |
| `powershell-quality.yml` | PowerShell quality (reusable) | PSScriptAnalyzer and rooted complexity JSON for a consumer's selected PowerShell tree |
| `mutation-gates.yml` | Mutation gates (reusable) | consumer-owned tracked recipes and nonempty shard proof |
| `container-ci-windows.yml` | Container CI · Windows (reusable) | the family's Windows container lane: x64, and the arm64 cross lane with its arch gate and a run on `windows-11-arm` ([`windows-cross-builds.md`](windows-cross-builds.md#consumer-cross-lanes-container-ci-windowsyml)) |

`container-ci-riscv64.yml` and `release-packages.yml` are `workflow_call` too, and
`ci-host-speed-probe.yml`, `riscv64-sysroot-probe.yml`, `sccache-release.yml` and
`windows-image-census-probe.yml` run only by hand (`workflow_dispatch`).

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
