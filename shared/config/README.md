<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Shared tool configuration

Canonical `.clang-format`, `.clang-tidy`, `.cmake-format.yaml`, `gcovr.cfg` and
`.pre-commit-config.yaml` for Kataglyphis C++ projects. This repo already owned
the *runners*
(`linux/scripts/lib/code-quality.sh`, `coverage.sh`, `linux/host-config/git-hooks/pre-commit`);
these are the configs those runners read, adopted here 2026-08-07 after they had
been copied per-project and started to drift (`.clang-format` and
`.pre-commit-config.yaml` were still byte-identical in two repos, `.clang-tidy`
had diverged by 36 lines and `gcovr.cfg` by 4).

`.cmake-format.yaml` was left out of that 2026-08-07 adoption and only joined on
2026-09-05. It was the one config the mechanism could not see: still
byte-identical in ContainerHub, BeschleunigerBallett and AccelerANTgine (all
three at blob `81211b60`), but held there by luck rather than by the check —
exactly the position `.clang-tidy` and `gcovr.cfg` had been in before they
diverged by 36 and 4 lines.

## Why these are COPIED into consumers, not referenced

Every other shared thing in this repo is consumed by reference — CMake modules
via `CMAKE_MODULE_PATH`, PowerShell modules via a resolver, composite actions via
`uses:`. These five cannot be, because **the tools that read them discover them
by walking up the directory tree from the file being processed**. A config
sitting in `third_party/ContainerHub/shared/config/` is never found:
it is below the source tree, not above it.

Passing explicit paths (`clang-format --style=file:<path>`, `clang-tidy
--config-file=<path>`) fixes the *scripted* invocations, but not editors —
VS Code, clangd and every IDE format-on-save look for `.clang-format` in the
tree. Dropping the local copy would silently stop formatting in the editor while
CI kept passing, which is worse than the duplication.

`.cmake-format.yaml` is not even reachable by an explicit path today: both
runners hard-code the consumer-root name. `code-quality.sh` defaults
`CODE_QUALITY_CMAKE_FORMAT_CONFIG` to a bare `.cmake-format.yaml` resolved
against the search root, and `WindowsFormatting.Common.psm1` builds it as
`Join-Path $WorkspacePath '.cmake-format.yaml'`. Remove the consumer's copy and
`cmake-format` silently falls back to its built-in defaults — 80-column instead
of 120, no `additional_commands` — reformatting every `CMakeLists.txt` it
touches without one error message.

So the copy stays, and drift is made **impossible instead of unnoticed**:

```pwsh
pwsh -File third_party/ContainerHub/shared/config/Sync-SharedConfig.ps1 -RepoRoot . -Check
pwsh -File third_party/ContainerHub/shared/config/Sync-SharedConfig.ps1 -RepoRoot . -Write
```

`-Check` exits non-zero on any difference and is meant to run as a test in the
consumer; `-Write` copies the canonical files over the local ones.

## Changing a config

Edit it **here**, then run `-Write` in each consumer and commit both. Editing a
consumer's copy directly is what the check exists to catch.

That instruction includes the repo this directory lives in: ContainerHub's own
root `.cmake-format.yaml` is a consumer copy (its runners resolve the config at
the repo root, like every consumer's), so refresh it with the same `-Write`
run. `linux/scripts/preflight.sh` (slug `shared-config`) goes red when it
drifts from — or goes missing against — the canonical file here; the other four
names have no root copy in ContainerHub and are `-Ignore`d by name there.

## Intentional per-project overrides

A project that genuinely needs different settings passes `-Ignore` with the file
names it owns, e.g. `-Ignore gcovr.cfg`. That records the exception explicitly
rather than letting an unexplained diff sit there looking like drift.

A boundary case first, so the escape hatch is not over-applied: **OrchestrANT
is not a consumer of this mechanism at all.** It is Python-only — no
`CMakeLists.txt`, nothing for the clang tools, `cmake-format` or `gcovr` to
read — and it carries none of the five files as copies. Its
`.pre-commit-config.yaml` is its own ruff configuration, not a divergent copy
of the canonical C++ one, and nothing in it invokes `Sync-SharedConfig.ps1`.
`-Ignore` exists for a consumer that carries *some* of the set and deliberately
owns the rest; a repo that carries none of it simply does not run the check.

**AccelerANTgine** is that consumer: it owns three of the five and runs
`-Ignore .clang-tidy,gcovr.cfg,.pre-commit-config.yaml`.

- `.clang-tidy` — it additionally disables `clang-diagnostic-error` and sets a
  `HeaderFilterRegex`. Both are its own answer to clang-tidy seeing an `import`
  without the BMIs on the command line. BeschleunigerBallett answers the same
  question differently, by skipping module TUs entirely
  (`Test-IsCxxModuleTranslationUnit` in `WindowsClang.Common`). Two valid
  strategies; forcing either on the other would weaken it.
- `gcovr.cfg` — coverage excludes follow the directory layout.
- `.pre-commit-config.yaml` — it runs an extra `clang-tidy` hook on commit,
  and its `cmake-format` hook predates the canonical one (2026-09-06, which
  also covers `CMakeLists.txt` — the model's `files:` regex stopped at
  `\.cmake$`). Which hooks a project runs locally is a workflow choice.

Its `.clang-format` is NOT an override: it was ahead of canonical, and canonical
was corrected to match (below).

## The 2026-08-11 correction: canonical was the stale copy

Three canonical files were wrong for **every** C++ consumer, and the drift
report had been reading as "AccelerANTgine deviates" when it was in fact
"AccelerANTgine is ahead":

- `Standard: c++20` while BeschleunigerBallett sets `CMAKE_CXX_STANDARD 23`.
- `.pre-commit-config.yaml`'s clang-format `files:` regex omitted `.ixx`, so
  BeschleunigerBallett's **63 module interface units were never formatted**.
- `misc-include-cleaner` left enabled, which is noise on module-using code.

All three fixed here and written out to the consumers. The lesson for anyone
reading a `-Check` failure: confirm which side is actually right before running
`-Write`.

## Completeness is enforced

The five names live in `Sync-SharedConfig.ps1`'s `$names`, and each one must
have a file next to it here. Do not add a name without adding the file: if one
is missing, `-Write` dies inside `Copy-Item` with a bare "path not found" and
`-Check` blames the *consumer* for a file that is actually missing *here* — both
readings send the reader to the wrong repo. The script now throws a message
naming this directory instead.
