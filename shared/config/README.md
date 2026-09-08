<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Shared tool configuration

Canonical `.clang-format`, `.clang-tidy`, `.cmake-format.yaml`, `gcovr.cfg` and
`.pre-commit-config.yaml` for Kataglyphis C++ projects — plus, since 2026-09-08,
the two bootstrap templates in `shared/windows/templates/` and
`shared/linux/templates/`, which are copied for the same reason and had gone
unwatched for it. `shared-assets.manifest` next to this file is the list; a
consumer declares which of those rows it takes. This repo already owned
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

```bash
bash third_party/ContainerHub/shared/config/sync-shared-config.sh --repo-root . --check
bash third_party/ContainerHub/shared/config/sync-shared-config.sh --repo-root . --write
```

`-Check` exits non-zero on any difference and is meant to run as a test in the
consumer; `-Write` copies the canonical files over the local ones. Exit 2 is
reserved for "this gate or its input is broken" so it never reads as drift.

## Changing a config

Edit it **here**, then run `-Write` in each consumer and commit both. Editing a
consumer's copy directly is what the check exists to catch.

That instruction includes the repo this directory lives in: ContainerHub's own
root `.cmake-format.yaml` is a consumer copy (its runners resolve the config at
the repo root, like every consumer's), so refresh it with the same `-Write`
run. `linux/scripts/preflight.sh` (slug `shared-config`) goes red when it
drifts from — or goes missing against — the canonical file here; the other four
names have no root copy in ContainerHub and are `-Ignore`d by name there. That
call is the one remaining `-Ignore` caller and becomes a two-word
`.containerhub-shared.manifest` at this repo's root the moment `preflight.sh`
is touched.

## MISSING is not DRIFTED

These are two different facts and they used to arrive as one. A consumer that
does not carry `.clang-tidy` is not broken — it has no C++ for clang-tidy to
read. A consumer whose `.clang-tidy` says something other than the canonical one
*is* broken. Reporting both as "differs" is what made this gate unrunnable for
three of the four consumers: they failed on files they had never taken, so
nobody wired the check in, so the files that *were* shared drifted unwatched.

So the two are separated, and which is which comes from a **declaration** rather
than from a flag on the command line:

| State | Verdict | Exit |
|---|---|---|
| declared, present, identical | `OK` | 0 |
| declared, present, differs | `DRIFTED` | 1 |
| declared, absent | `MISSING` (its own paragraph) | 1 |
| not declared | nothing at all | 0 |

The last row is the one that matters. An undeclared file is not skipped, not
warned about and not counted — it is not this mechanism's business, and it is
never mentioned in the output.

## The two manifests

**Owner side — `shared-assets.manifest`, next to this file.** One row per file
ContainerHub is the source of truth for: `id | canonical path here | default
path in a consumer | mode | knob prefixes`. Adding a shared file is one row.

**Consumer side — `.containerhub-shared.manifest` at the consumer's repo root.**
One row per asset that repo takes: the id, and optionally the path if the file
does not sit where the registry's default says. It is picked up automatically;
`-Manifest` / `--manifest` points at one elsewhere. Whole file, for jotrockenmitlocken:

```
containerhub-sh   scripts/lib/containerhub.sh
```

and for OmniAccelerANT:

```
cmake-format
containerhub-sh
resolve-build-module
```

An id the registry does not know is a hard error naming the valid ones — the
same typo guard `-Ignore` used to carry, now covering the whole declaration
rather than the exception list.

`-Ignore` survives only for a repo root that has no manifest yet
(ContainerHub's own preflight `shared-config` gate is the last such caller).
Passing it *together* with a manifest is refused: a stale ignore silently
overriding a declaration is precisely the confusion being removed.

## Intentional per-project overrides

A project that genuinely owns one of these files simply does not declare it. The
declaration is the record of the exception, and it lives in the consumer next to
the files it describes rather than in a flag inside somebody's CI YAML.

A boundary case first, so the escape hatch is not over-applied: **OrchestrANT
takes none of the five configs.** It is Python-only — no `CMakeLists.txt`,
nothing for the clang tools, `cmake-format` or `gcovr` to read. Its
`.pre-commit-config.yaml` is its own ruff configuration, not a divergent copy
of the canonical C++ one. Its manifest therefore lists only the two bootstrap
templates, and its ruff file is never looked at — under the old `-Ignore`
scheme that same repo could not pass the gate at all without naming four files
it had never taken.

**AccelerANTgine** owns three of the five: it declares `clang-format` and
`cmake-format` and leaves the other three out.

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

## The template trees are owners too

`shared/windows/templates/Resolve-BuildModule.ps1` and
`shared/linux/templates/containerhub.sh` are the two files a consumer cannot
consume by reference, because each one is what *finds* the submodule. They were
copied into consumers and then nothing watched them: on 2026-09-08
`Resolve-BuildModule.ps1` existed in four copies under three distinct headers,
and `containerhub.sh` sat in all four consumers. They are now registry rows like
any other shared file, in `body` mode.

`body` mode exists because a verbatim compare would be wrong here. Two deltas
are legitimate and one is not:

- **The header prose.** Every consumer replaces the template's "TEMPLATE — copy
  to …" block with its own "copied from ContainerHub, do not hand-edit" note,
  and OrchestrANT's additionally records what it verified and when. So the
  comparison starts at the file's **first line of code** — `Set-StrictMode` in
  the PowerShell file, the load guard in the bash one — and everything above it
  is the consumer's to write.
- **The declared knob.** `containerhub.sh` documents
  `KATAGLYPHIS_REPO_ROOT_RELATIVE` as an adjustable, and jotrockenmitlocken
  really does set `../..` because its copy sits two levels down rather than
  three. `Resolve-BuildModule.ps1` has the same knob in
  `$script:RepoRootRelativeToHere`. A line whose start matches a declared knob
  prefix is masked before comparing, so the *value* is free — but only the
  value: rewrite the line itself and it is drift again.
- **Everything else is drift**, including comments below the first code line.

## The bash twin

`sync-shared-config.sh` is a full reimplementation, not a wrapper, and it is
what lets this gate run at all on Linux: **none of the hub's Linux images ship
pwsh**, which is exactly why OmniAccelerANT's workflow has to run the check in a
separate hosted-runner job outside its container. Both read the same two
manifests and are required to produce the same lines and the same exit code;
verified against all four consumer trees on 2026-09-08, byte-identical output
each time, on the Windows host and inside `latest-cross`.

Two portability notes worth keeping, both found by running the pair against each
other rather than by reading them:

- PowerShell unrolls a returned array of one element, so a manifest with a
  single row came back as that row's *characters*. `return , $rows`.
- bash 5.3 does not apply ANSI-C quoting to a `$'\r'` inside a `${x%…}` that is
  inside an array-element assignment, so CRLF survived the strip and every
  CRLF-checked-out canonical file read as drift. The CR lives in a variable now.

## Completeness is enforced

Every row in `shared-assets.manifest` must have a file behind it. Do not add a
row without adding the file: `-Write` would die inside `Copy-Item` with a bare
"path not found" and `-Check` would blame the *consumer* for a file that is
actually missing *here* — both readings send the reader to the wrong repo. The
scripts throw a message naming this repo instead, and they throw it only for
assets the consumer actually declared, because an asset nobody takes is nobody's
failure.

`-Write` copies verbatim, so it serves `exact` assets only. On a `body` asset it
refuses and says why: splicing a canonical body under the consumer's own header
while preserving its knob values is a merge, not a copy, and a merge that went
quietly wrong would defeat the gate it was fixing.
