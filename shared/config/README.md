<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Shared tool configuration

Canonical `.clang-format`, `.clang-tidy`, `gcovr.cfg` and `.pre-commit-config.yaml`
for Kataglyphis C++ projects. This repo already owned the *runners*
(`linux/scripts/lib/code-quality.sh`, `coverage.sh`, `linux/host-config/git-hooks/pre-commit`);
these are the configs those runners read, adopted here 2026-08-07 after they had
been copied per-project and started to drift (`.clang-format` and
`.pre-commit-config.yaml` were still byte-identical in two repos, `.clang-tidy`
had diverged by 36 lines and `gcovr.cfg` by 4).

## Why these are COPIED into consumers, not referenced

Every other shared thing in this repo is consumed by reference — CMake modules
via `CMAKE_MODULE_PATH`, PowerShell modules via a resolver, composite actions via
`uses:`. These four cannot be, because **the tools that read them discover them
by walking up the directory tree from the file being processed**. A config
sitting in `third_party/ContainerHub/shared/config/` is never found:
it is below the source tree, not above it.

Passing explicit paths (`clang-format --style=file:<path>`, `clang-tidy
--config-file=<path>`) fixes the *scripted* invocations, but not editors —
VS Code, clangd and every IDE format-on-save look for `.clang-format` in the
tree. Dropping the local copy would silently stop formatting in the editor while
CI kept passing, which is worse than the duplication.

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

## Intentional per-project overrides

A project that genuinely needs different settings passes `-Ignore` with the file
names it owns, e.g. `-Ignore gcovr.cfg`. That records the exception explicitly
rather than letting an unexplained diff sit there looking like drift.

The standing example: this canonical set is written for **C++** projects, so a
Python consumer owns its own `.pre-commit-config.yaml` — ruff hooks rather than
clang-format — and runs `-Ignore .pre-commit-config.yaml`.
OrchestrANT is that case, and its difference is a deliberate
override, not drift.

**Kataglyphis-Cpp-Inference** owns three of the four:
`-Ignore .clang-tidy gcovr.cfg .pre-commit-config.yaml`.

- `.clang-tidy` — it additionally disables `clang-diagnostic-error` and sets a
  `HeaderFilterRegex`. Both are its own answer to clang-tidy seeing an `import`
  without the BMIs on the command line. BeschleunigerBallett answers the same
  question differently, by skipping module TUs entirely
  (`Test-IsCxxModuleTranslationUnit` in `WindowsClang.Common`). Two valid
  strategies; forcing either on the other would weaken it.
- `gcovr.cfg` — coverage excludes follow the directory layout.
- `.pre-commit-config.yaml` — it runs extra `clang-tidy` and `cmake-format`
  hooks on commit. Which hooks a project runs locally is a workflow choice.

Its `.clang-format` is NOT an override: it was ahead of canonical, and canonical
was corrected to match (below).

## The 2026-08-11 correction: canonical was the stale copy

Three canonical files were wrong for **every** C++ consumer, and the drift
report had been reading as "Cpp-Inference deviates" when it was in fact
"Cpp-Inference is ahead":

- `Standard: c++20` while BeschleunigerBallett sets `CMAKE_CXX_STANDARD 23`.
- `.pre-commit-config.yaml`'s clang-format `files:` regex omitted `.ixx`, so
  BeschleunigerBallett's **63 module interface units were never formatted**.
- `misc-include-cleaner` left enabled, which is noise on module-using code.

All three fixed here and written out to the consumers. The lesson for anyone
reading a `-Check` failure: confirm which side is actually right before running
`-Write`.

## Completeness is enforced

The four names live in `Sync-SharedConfig.ps1`'s `$names`, and each one must
have a file next to it here. Do not add a name without adding the file: if one
is missing, `-Write` dies inside `Copy-Item` with a bare "path not found" and
`-Check` blames the *consumer* for a file that is actually missing *here* — both
readings send the reader to the wrong repo. The script now throws a message
naming this directory instead.
