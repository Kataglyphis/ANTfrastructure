<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Python CI: the drivers, and the two traps in `uv`

The Python consumers (OrchestrANT, WebDavClient)
share their whole CI surface with this repository:

| Layer | Where |
|---|---|
| Linux lane | [`../.github/workflows/python-ci-linux.yml`](../.github/workflows/python-ci-linux.yml) (`workflow_call`) |
| Windows lane | [`../.github/workflows/python-ci-windows.yml`](../.github/workflows/python-ci-windows.yml) (`workflow_call`) |
| Step drivers | `linux/scripts/02-toolchain/python/ci_{tests,static_analysis,build_docs,packaging}.sh` |
| uv primitives | `linux/scripts/01-core/python_uv.sh` |

A consumer's workflow is configuration, not steps. Its `scripts/linux/ci_*.sh`
are wrappers that `antfrastructure_exec` into the drivers above — see
[`../shared/linux/templates/README.md`](../shared/linux/templates/README.md).

## Positional arguments: empty means default

Every driver reads its positionals as `"${N:-default}"`, and that expansion
treats an **empty** argument exactly like an absent one. So the reusable
workflows pass every version input unconditionally and let an empty value fall
through to the driver's own default — there is no conditional command building
anywhere, and a caller names a version only to genuinely override it.

This is also why two consumers that *looked* different were running identical
commands: passing `'3.14'` to `ci_static_analysis.sh` is exactly its default.

## The static-analysis knobs, and the bandit trap between them

Two knobs decide what the six analysers grade, and each has a Windows twin that
carries the same default:

| Knob | Windows twin | Default |
|---|---|---|
| `STATIC_ANALYSIS_EXTRA_PATHS` | `-ExtraPaths` | empty |
| `BANDIT_EXCLUDES` | `-BanditExcludes` | `tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results` |

`STATIC_ANALYSIS_EXTRA_PATHS` is a space-separated path **list**, word-split on
purpose, so no element may contain a space. It exists because a consumer whose
importable package is not the whole first-party tree had the rest graded by
nothing: OrchestrANT's `benchmarks/`, `frontend/`, `bench/` and `examples/`
were outside every analyser until it landed.

**The trap.** Both drivers spelled the extras as one `-r` per path. bandit's
`-r` is `store_true` against a **single** `nargs='*'` positional, so
`bandit -r a -r b` is `unrecognized arguments` and exit 2 — measured against
bandit 1.9.4 in the family image. The bandit gate therefore failed on the very
knob the other five analysers handled, which is why OrchestrANT could not adopt
it. The form bandit accepts is **one `-r` followed by the whole target list**,
and `tests/test-python-static-analysis.sh` counts the flags so it cannot come
back.

`BANDIT_EXCLUDES` **replaces** the default list rather than adding to it: a
consumer that names an exclude set means that set. Setting it is how a consumer
stops hard-coding the whole `-x` string in its own driver.

## Turning the Windows PowerShell lint on

`python-ci-windows.yml` takes `lint-powershell` (boolean, default `false`) and
`lint-path` (string, default `scripts`). Together they add a second job on the
same Windows runner that runs
[`windows/scripts/Invoke-Lint.ps1`](../windows/scripts/Invoke-Lint.ps1) — the
mandatory parse pass, the AST traps and PSScriptAnalyzer — over the **caller's**
tree, with the hub's ruleset consumed by reference.

```yaml
jobs:
  windows:
    uses: Kataglyphis/ANTfrastructure/.github/workflows/python-ci-windows.yml@main
    with:
      lint-powershell: true
      lint-path: scripts/windows
    secrets:
      GHCR_PAT: ${{ secrets.GHCR_PAT }}
```

It is a separate job and deliberately does **not** `needs:` the build: a syntax
error in the build scripts is exactly when the lint is worth having, and it
needs no image pull. `-FailOnAnalyzer` is passed unconditionally and is not an
input — without it the analyzer prints its findings and exits 0, which is a
check that cannot fail.

**The lint without the build.** `build-python-package` (boolean, default
`true`) gates the container build job, so a repo with no Python package can call
this lane for the gate alone:

```yaml
jobs:
  powershell-lint:
    uses: Kataglyphis/ANTfrastructure/.github/workflows/python-ci-windows.yml@main
    with:
      build-python-package: false
      lint-powershell: true
```

There is no `secrets:` block there and that is the point: `GHCR_PAT` is
`required: false`, because a required secret is refused at call time and would
have made the lint unreachable for exactly the callers this switch is for. The
build job asserts the token in its own first step, so a caller that wanted the
build and forgot the secret is told which input it missed instead of failing
inside a `docker login` against ghcr. OxidANT — a Rust crate whose Windows
container build is a different workflow — had measured the lint job as
byte-for-byte its own and still could not call this lane until the gate existed.

Every caller written before the switch is unchanged, because it defaults on.

## Trap 1 — `--all-extras` is fatal with declared conflicts

`uv sync --all-extras` is not "install as much as possible". On a project that
declares `[tool.uv] conflicts`, uv refuses outright:

```
error: Extras `ml-ai` and `ml-ai-webgpu` are incompatible with the declared
       conflicts: {`orchestrant[ml-ai]`, `orchestrant[ml-ai-webgpu]`}
```

There is no flag that means "pick a satisfiable subset". OrchestrANT
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
family, which for OrchestrANT resolves to `ml-ai` and `pytorch-cpu`, the
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
give the same answer. OrchestrANT writes the multi-line form, so this was
latent there; what settles it is a consuming repo's CI lane running
`uv sync --all-extras`, because no ANTfrastructure cross stage calls `uv_sync_project`
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

**`:latest`, on every architecture.** It is a multi-arch index —
`linux/amd64`, `linux/arm64` and `linux/riscv64`, all children present as of
2026-08-12 — so docker resolves the right platform per runner and the tag does
not have to be spelled per lane.

The arch-suffixed tags (`:latest-amd64`, `-arm64`, `-riscv64`) exist, but
treat them as an implementation detail of the image build. A consumer that names
one is pinning itself to a single architecture.

> Between 2026-08-04 and 2026-08-12 the index listed **amd64 only**, and lanes
> had to name `:latest-cross-arm64` explicitly or `docker pull` on an arm runner
> died with "no matching manifest for linux/arm64/v8 in the manifest list
> entries". If you find such a workaround still in place, it is stale — remove
> it rather than copying it.

The same index was named `:latest-cross` until 2026-09-22; that name survives
only as a deprecated alias — see
[`rancher-desktop-linux-containers.md` § The image: always `:latest`](rancher-desktop-linux-containers.md#the-image-always-latest).
