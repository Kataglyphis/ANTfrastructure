<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Python CI: the drivers, and the two traps in `uv`

The Python consumers (Kataglyphis-Orchestr-ANT-ion, Kataglyphis-WebDavClient)
share their whole CI surface with this repository:

| Layer | Where |
|---|---|
| Linux lane | [`../.github/workflows/python-ci-linux.yml`](../.github/workflows/python-ci-linux.yml) (`workflow_call`) |
| Windows lane | [`../.github/workflows/python-ci-windows.yml`](../.github/workflows/python-ci-windows.yml) (`workflow_call`) |
| Step drivers | `linux/scripts/02-toolchain/python/ci_{tests,static_analysis,build_docs,packaging}.sh` |
| uv primitives | `linux/scripts/01-core/python_uv.sh` |

A consumer's workflow is configuration, not steps. Its `scripts/linux/ci_*.sh`
are wrappers that `containerhub_exec` into the drivers above — see
[`../shared/linux/templates/README.md`](../shared/linux/templates/README.md).

## Positional arguments: empty means default

Every driver reads its positionals as `"${N:-default}"`, and that expansion
treats an **empty** argument exactly like an absent one. So the reusable
workflows pass every version input unconditionally and let an empty value fall
through to the driver's own default — there is no conditional command building
anywhere, and a caller names a version only to genuinely override it.

This is also why two consumers that *looked* different were running identical
commands: passing `'3.14'` to `ci_static_analysis.sh` is exactly its default.

## Trap 1 — `--all-extras` is fatal with declared conflicts

`uv sync --all-extras` is not "install as much as possible". On a project that
declares `[tool.uv] conflicts`, uv refuses outright:

```
error: Extras `ml-ai` and `ml-ai-webgpu` are incompatible with the declared
       conflicts: {`orchestr-ant-ion[ml-ai]`, `orchestr-ant-ion[ml-ai-webgpu]`}
```

There is no flag that means "pick a satisfiable subset". Orchestr-ANT-ion
declares 12 pairwise conflicts across two mutually-exclusive families (the
`ml-ai-*` backends and the `pytorch-*` backends), so every one of its lanes died
here regardless of what it had been asked to do.

`uv_sync_project()` handles it, in this order:

1. **`UV_SYNC_EXTRAS`** — an explicit list (`"a,b"` or `"a b"`) becomes
   `--extra a --extra b` and `--all-extras` is dropped. The project knows best.
2. **Auto-detect** — otherwise the conflict groups are parsed out of
   `pyproject.toml` and enough extras are excluded via `--no-extra` to make
   `--all-extras` satisfiable. Greedy in **declaration order**: keep an extra
   unless it conflicts with one already kept.

Declaration order is not arbitrary — it keeps the first-declared member of each
family, which for Orchestr-ANT-ion resolves to `ml-ai` and `pytorch-cpu`, the
right pair for CI. The choice is logged, with a pointer to `UV_SYNC_EXTRAS`.

A project with no conflicts is unaffected: the exclusion list comes back empty
and the command is byte-identical to before.

## Trap 2 — `UV_PYTHON` beats the activated venv

The CI images export `UV_PYTHON=/opt/venv/bin/python` (a root-owned system venv)
and run as the non-root user `kataglyphis`. **uv honours `UV_PYTHON` over the
activated virtualenv**, so `--active` alone is not enough — the sync targets
`/opt/venv` and dies:

```
error: failed to remove file `/opt/venv/lib/python3.14/site-packages/...`:
       Permission denied (os error 13)
```

Both `uv_sync_project()` and `uv_pip_install_requirements()` therefore pin
`--python <venv>/bin/python`. That pin is load-bearing, not tidiness. If you add
another uv entry point, pin it too.

The two traps stack: the extras error hides the venv error, because the resolve
never gets far enough to write anything. Fixing only the first one just moves
the failure.

## Which Linux image

Use the `latest-cross` family, and mind the architecture:

| Lane | Image |
|---|---|
| x86-64 | `:latest-cross` |
| arm64 | `:latest-cross-arm64` |

`:latest-cross` is **amd64-only** — a single manifest, not an index — so it
cannot serve an arm64 leg. The reusable Linux workflow picks per matrix leg;
a workflow that takes the architecture as an input derives the tag from it.

Do not use the plain `:latest`. Its per-platform children were deleted by a
`ghcr-cleanup` bug (fixed 2026-08-11), so it resolves as an index whose children
404 and `docker pull` reports only `manifest unknown`.
