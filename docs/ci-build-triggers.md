# CI Build Triggers (commit-message opt-ins)

> **These lanes live in CONSUMER repos, not here.** ContainerHub's own CI is
> `ubuntu24.04.yml` (preflight + docs), `windows-scripts.yml` (PowerShell
> lint/tests), `llm-stack-tests.yml` (push/PR, path-filtered on
> `linux/llm-stack/**`), and three scheduled housekeeping workflows —
> `ghcr-cleanup.yml` (Sundays), `sbom.yml` and `stale-docs-check.yml` (both
> Mondays). None of them builds a container image — `llm-stack-tests.yml` runs
> against a digest-pinned `ollama/ollama` *service* container, it does not build
> one — and none reacts to the tokens below. This page documents the convention
> the *consuming* application repos use with the images published from here.

Not every CI lane runs on every push. The heavier lanes are **opt-in per
commit** via magic tokens in the commit message, so routine work does not spend
Windows-runner minutes or cross-compile time it does not need. The token is
matched against `github.event.head_commit.message`, so it must be in the
**pushed HEAD commit's** message (not an earlier commit in the push).

| Lane | Trigger | Default |
|---|---|---|
| Linux x86_64 (build + test + coverage) | always, on push/PR to `main`/`develop` | **runs every time** |
| Windows (MSVC/clang-cl container build) | `[build-win]` in the commit message | skipped |
| Linux ARM64 | `[build-arm]` in the commit message | skipped |

## Usage

Add the token anywhere in the commit subject or body:

```
git commit -m "fix(shadows): correct the cascade split maths [build-win]"
```

Combine them to run both extra lanes from one push:

```
git commit -m "build: verify the toolchain on every target [build-win][build-arm]"
```

## Consequences worth knowing

- **A green checkmark without `[build-win]` says nothing about Windows.** The
  Windows workflow reports `skipped`, which reads as success at a glance but
  means it never ran. If a change touches the Windows build (CMake, clang-cl
  flags, the container image, anything under `windows/`), push at least once
  with `[build-win]` before trusting it. Same for ARM and `[build-arm]`.
- **The token is on the HEAD commit only.** If you push a batch, only the last
  commit's message is checked. Amend or add an empty trigger commit
  (`git commit --allow-empty -m "ci: run windows [build-win]"`) if the token
  landed on an earlier commit.
- These gates predate the current work and are a deliberate runner-cost
  decision. Whether the Windows lane *should* be opt-in, or run on PRs to
  `main` / nightly, is an open question tracked in the main repo's `BACKLOG.md`
  under "CI and release gaps".

See also [`github-cli-pipeline-monitoring.md`](github-cli-pipeline-monitoring.md)
for reading lane status with `gh` (including telling a real pass from a
`skipped` gate).
