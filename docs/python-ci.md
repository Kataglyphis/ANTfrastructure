<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Python CI: the drivers, and the three traps in `uv`

The Python consumers (OrchestrANT, WebDavClient)
share their whole CI surface with this repository:

| Layer | Where |
|---|---|
| Linux lane | [`../.github/workflows/python-ci-linux.yml`](../.github/workflows/python-ci-linux.yml) (`workflow_call`) |
| Windows lane | [`../.github/workflows/python-ci-windows.yml`](../.github/workflows/python-ci-windows.yml) (`workflow_call`) |
| Step drivers | `linux/scripts/02-toolchain/python/ci_{tests,static_analysis,build_docs,packaging}.sh` |
| uv primitives | `linux/scripts/01-core/python_uv.sh` |
| Chain ORT reconcile | `uv_reconcile_chain_ort` in `python_uv.sh`, `Sync-UvChainOnnxRuntime` in `windows/scripts/modules/WindowsUv.Common.psm1`; both run the ORT census `linux/scripts/03-media/runtime/ort-venv-census.py` (the Windows image's module copy runs the one `windows/Dockerfile` puts in `C:\temp\scripts\`) |

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

## One arch per caller: the `arches` input

`python-ci-linux.yml` takes `arches` (string, default `"x64 arm64"`): the rows
to run, space-separated. The default is both rows, so every caller written
before the input runs exactly what it ran before, with the same job names
(`x64`, `arm64`) and the same artifact names. A caller that follows the fleet's
one-file-per-arch convention
([`adopting-in-a-new-project.md` § Workflow file names and display names](adopting-in-a-new-project.md#workflow-file-names-and-display-names))
calls the lane once per file:

```yaml
# .github/workflows/linux-arm64.yml
name: Linux arm64 · build + test
jobs:
  linux:
    uses: Kataglyphis/ANTfrastructure/.github/workflows/python-ci-linux.yml@develop
    with:
      package-name: orchestrant
      arches: arm64
    secrets:
      GHCR_PAT: ${{ secrets.GHCR_PAT }}
```

The docs build and the FTP deploy run on the `x64` row only, so the
`linux-x64.yml` caller is the one that passes the FTP secrets.

A small `plan` job turns the list into the build matrix, and it **fails** on an
unknown name (`amd64`, `x86_64`), on a name listed twice, and on an empty list.
Without that, `arches: "x64 arn64"` would run one row and stay green.
Separators are whitespace, newlines included, so a block-scalar input works;
`x64,arm64` is one unknown name.

**Why a plan job and not a filtered static matrix.** An `exclude:` cannot drop
a row that `include:` defines: GitHub applies `exclude` first, and an `include`
entry that no longer fits any combination is added back as a new one. So the
rows are written once, in the plan step's `case` table, and the build job reads
`fromJSON(needs.plan.outputs.matrix)`. The cost is that the runner labels sit
inside a `run:` block, where the workflow-convention gate's `*-latest` ban
cannot see them;
[`tests/test-reusable-linux-lane.sh`](../linux/scripts/tests/test-reusable-linux-lane.sh)
runs that step and holds the labels to the same rule.

**Consumers follow hub `develop`.** The fleet calls this lane at `@develop`
(since 2026-09-25), so the input reached the consumers at once. WebDavClient
split its `ubuntu-26.04-amd64-arm64.yml` into `linux-x64.yml` and
`linux-arm64.yml` the same day; OrchestrANT's split is still open.

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
    uses: Kataglyphis/ANTfrastructure/.github/workflows/python-ci-windows.yml@develop
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
    uses: Kataglyphis/ANTfrastructure/.github/workflows/python-ci-windows.yml@develop
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
another uv entry point, pin it too, and end it in `uv_reconcile_chain_ort`
(Trap 3).

The two traps stack: the extras error hides the venv error, because the resolve
never gets far enough to write anything. Fixing only the first one just moves
the failure.

## Trap 3 — ONNX Runtime comes from the chain, not PyPI

The owner rule of 2026-09-23 says every component that uses ONNX Runtime loads the
ORT this repository builds
([`onnxruntime-single-source.md`](onnxruntime-single-source.md)). A consumer's test
venv inside our images is such a component. Before the rule, `uv sync --all-extras`
installed whatever the lock named, so OrchestrANT's CI tested on PyPI `onnxruntime`,
`onnxruntime-gpu` and `onnxruntime-genai` (plus the `-directml` pair on Windows), all
overlapping in one `site-packages/onnxruntime`.

Every `uv_sync_project` (Linux) and `Sync-UvProjectDependencies` (Windows) now ends by
reconciling the venv it synced:

1. **Inside our images?** The chain wheel store says so. Linux: `ORT_CHAIN_WHEEL_DIR`,
   which `linux/Dockerfile.torch` sets to `/opt/onnxruntime-wheels`. Windows:
   `ORT_CHAIN_WHEEL_DIR`, else the image's `PYTHON_WHEELS` (`C:\runtime\wheels`), else
   `C:\runtime\wheels` if it exists.
2. **The census names the ORT distributions.** The venv's own interpreter runs
   `ort-venv-census.py --purge-list` with `-I`: every distribution named `onnxruntime`
   or `onnxruntime-*`, and every owner of the `onnxruntime`, `onnxruntime_genai` or
   `onnxruntime_extensions` package.
3. **No ORT distribution:** inside our images the venv's interpreter still checks that
   none of those three packages imports. An ORT package no distribution owns (copied
   files, a `pip --target` leftover) fails the sync. **Outside our images:** a loud
   `NOTICE` that names the distributions, and the venv stays as uv resolved it.
4. **The ABI check comes first.** The chain wheels are built for the image interpreter
   (cp314 today), and uv installs a path wheel of another ABI tag without complaint.
   So before the venv is touched, each store ORT wheel's tag must fit the venv's own
   (`abi3` and `none` fit any), or the sync fails naming the misfits.
5. **The replacement:** `uv pip uninstall` every listed distribution, then
   `uv pip install --no-index --no-deps --force-reinstall` every `onnxruntime[-_]*.whl`
   in the store. Then two proofs, and **either one failing fails the sync**:
   `--check --store` (each ORT distribution byte-identical to a store wheel,
   `onnxruntime` owned once), and `import onnxruntime` in that venv, which catches a
   load failure on a fitting tag.
6. **`UV_NO_SYNC=1` is exported on success**, only when it was unset, and released by
   the next sync of a venv without ORT. `uv run` re-syncs to the lock by default and
   would put PyPI ORT back; `uv sync` itself ignores the variable.

A failed `uv sync` keeps its own exit status; the reconcile never runs after it.

**Where the Linux store comes from.** `/opt/wheels` is only a bind mount inside the torch
RUN, so `setup-torch-venv.sh stage_chain_ort_wheels` copies exactly the wheels the census
matched `/opt/venv` against (the installed flavour only) into `ORT_CHAIN_WHEEL_DIR` and
proves `/opt/venv` against the store. Any failure stops the image build; a venv without
ORT leaves the store empty.

**A leg on another interpreter.** Inside our images an ORT project's legs run on the image
interpreter. Two remedies work on both lanes: drop the other legs (`test-python-versions`,
or the consumer's `$PythonVersions`), or list them in `EXPERIMENTAL_PYTHON_VERSIONS`, so a
failed sync warns instead of failing the matrix. The reusable workflows pass no env into
the container, so the consumer's `scripts/linux/ci_tests.sh` wrapper must export it.
`UV_SYNC_EXTRAS` is NOT a remedy: every sync of the run reads it, so leaving ORT out of
one leg leaves it out of all of them. The hub defaults are the image interpreter (owner
decision 2026-09-23; the images carry CPython 3.14 only): `ci_tests.sh` `PY_VERSIONS='3.14'`
and `ci_build_docs.sh` `COVERAGE_VERSION=3.14`, like the static-analysis and packaging
drivers. `tests/test-python-ci-defaults.sh` holds them to `versions.env`'s `PYTHON_VERSION`.
OrchestrANT dropped its 3.13 legs. A project that needs another interpreter names it for every
driver, docs included. WebDavClient (no ORT; atheris has no cp314 wheel) pins 3.13 for its tests,
static analysis and packaging, and needs `docs-python-version: '3.13'` as well: nothing sets it
for it, and without it the first hub bump past this default fails its docs job on atheris.

| Message | Cause | Fix |
|---|---|---|
| `chain ORT: need the store … the interpreter … and the census …` | the store is declared but missing (an image regression), or the venv interpreter or the census is missing | the census comes from the hub checkout (`linux/scripts/03-media/runtime/`) or, for the Windows image's module copy, from `C:\temp\scripts\ort-venv-census.py`; an image built before `windows/Dockerfile` COPYed it there has none, so import the module from the hub checkout |
| `the store … holds no onnxruntime wheel` | the store is empty, for example a venv built without ORT | build the store with ORT, or keep ORT out of that venv |
| `… is a cp313 venv, and the chain wheels are built for the image interpreter: …` | the leg's interpreter is not the image's; the venv was not touched | drop the leg or list it in `EXPERIMENTAL_PYTHON_VERSIONS` |
| `… imports ONNX Runtime with no distribution to purge (…)` plus census `FAIL` lines | an ORT package no distribution owns | remove the files the `FAIL` lines name |
| `the chain onnxruntime does not import in …` | the tag fits but the load fails (a DLL or `.so` the venv cannot find) | the import error follows the message |
| `still carries a non-chain ONNX Runtime` | the census found a foreign distribution | read the `FAIL` lines that follow |

`onnxruntime-extensions` and prebuilt plugin-EP wheels have no chain counterpart. They are
purged and not replaced, which is what the rule asks for.

**Not covered:** tool venvs built from requirement files (`uv_pip_install_requirements` /
`Install-UvRequirements`: cmake-format, docs), `uvx` / `uv tool`, pip calls outside these
helpers, ORT vendored under another import name, and runners that are not our images (they
get the notice only). The Windows chain wheel importing in a plain consumer venv, without
the app venv's DLL-directory shim, has not been run inside `:winamd64` yet.

**Tests:** `linux/scripts/tests/test-uv-chain-ort.sh` (a real venv plus the real census,
with a uv stand-in), `windows/scripts/tests/Uv.ChainOrt.Tests.ps1` (including the image's
module copy in the layout `windows/Dockerfile` builds), and the mutation family
`uv-chain-ort` in `docs/scripts/mutations.json`.

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

The same index was named `:latest-cross` until 2026-09-22; that name is retired
(no release publishes it; the tags go once `main` carries `:latest`) — see
[`rancher-desktop-linux-containers.md` § The image: always `:latest`](rancher-desktop-linux-containers.md#the-image-always-latest).
