<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Shared tool configuration

Canonical `.clang-format`, `.clang-tidy`, `gcovr.cfg` and `.pre-commit-config.yaml`
for Kataglyphis C++ projects. This repo already owned the *runners*
(`linux/scripts/lib/code-quality.sh`, `coverage.sh`, `.githooks/pre-commit`);
these are the configs those runners read, adopted here 2026-08-07 after they had
been copied per-project and started to drift (`.clang-format` and
`.pre-commit-config.yaml` were still byte-identical in two repos, `.clang-tidy`
had diverged by 36 lines and `gcovr.cfg` by 4).

## Why these are COPIED into consumers, not referenced

Every other shared thing in this repo is consumed by reference — CMake modules
via `CMAKE_MODULE_PATH`, PowerShell modules via a resolver, composite actions via
`uses:`. These four cannot be, because **the tools that read them discover them
by walking up the directory tree from the file being processed**. A config
sitting in `ExternalLib/Kataglyphis-ContainerHub/shared/config/` is never found:
it is below the source tree, not above it.

Passing explicit paths (`clang-format --style=file:<path>`, `clang-tidy
--config-file=<path>`) fixes the *scripted* invocations, but not editors —
VS Code, clangd and every IDE format-on-save look for `.clang-format` in the
tree. Dropping the local copy would silently stop formatting in the editor while
CI kept passing, which is worse than the duplication.

So the copy stays, and drift is made **impossible instead of unnoticed**:

```pwsh
pwsh -File ExternalLib/Kataglyphis-ContainerHub/shared/config/Sync-SharedConfig.ps1 -RepoRoot . -Check
pwsh -File ExternalLib/Kataglyphis-ContainerHub/shared/config/Sync-SharedConfig.ps1 -RepoRoot . -Write
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
