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

The group scanner reads TOML, not one indentation style. It used to gather the
`extra = "…"` occurrences of a line only **after** the character walk had already
closed the group on that line's `]`, so a group written inline —
`conflicts = [ [ { extra = "a" }, { extra = "b" } ] ]`, which uv accepts — produced
no group, excluded nothing, and left `--all-extras` to die on the very conflict it
was meant to route around. The group's text is now accumulated during the same walk
and read at the `]` that closes it, so the inline, multi-line and mixed layouts all
give the same answer. Orchestr-ANT-ion writes the multi-line form, so this was
latent there; what settles it is a consuming repo's CI lane running
`uv sync --all-extras`, because no ContainerHub cross stage calls `uv_sync_project`
at all — it is reached only from `02-toolchain/python/ci_*.sh`.

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

**`:latest-cross`, on every architecture.** It is a multi-arch index —
`linux/amd64`, `linux/arm64` and `linux/riscv64`, all children present as of
2026-08-12 — so docker resolves the right platform per runner and the tag does
not have to be spelled per lane.

The arch-suffixed tags (`:latest-cross-amd64`, `-arm64`, `-riscv64`) exist, but
treat them as an implementation detail of the image build. A consumer that names
one is pinning itself to a single architecture.

> Between 2026-08-04 and 2026-08-12 the index listed **amd64 only**, and lanes
> had to name `:latest-cross-arm64` explicitly or `docker pull` on an arm runner
> died with "no matching manifest for linux/arm64/v8 in the manifest list
> entries". If you find such a workaround still in place, it is stale — remove
> it rather than copying it.

Do not use the plain `:latest`. Its per-platform children were deleted by a
`ghcr-cleanup` bug (fixed 2026-08-11 in b70d3f4) and are **still missing**, so
the index resolves, every child 404s, and `docker pull` reports only
`manifest unknown`.
