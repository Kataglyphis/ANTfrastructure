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
| Chain OpenCV (Windows) | `Sync-UvChainOpenCv` in `WindowsUv.Common.psm1`, over `Copy-ChainOpenCvPackage` in `WindowsPythonApp.Common.psm1` |
| App bundles (zip/MSI/deb/… inputs) | [`python-app-bundles.md`](python-app-bundles.md) |
| Free-threaded wheel (declared, proved) | `linux/scripts/02-toolchain/python/free-threaded-wheel.py`, run by both packaging drivers (§ Two wheels: GIL and free-threaded) |

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
`linux-arm64.yml` the same day; OrchestrANT's split followed.

### riscv64: the image itself runs under QEMU

`arches: riscv64` runs on an amd64 runner with the riscv64 image under QEMU,
tests only. The row registers QEMU's binfmt handler through
`setup-riscv64-cross` with `sysroot: false` (the sysroot serves cross builds,
and a Python lane has nothing to cross-compile), runs every container step with
`--platform linux/riscv64`, and carries its own `timeout: 360` in the plan's
matrix - the first opt-in packaging run hit the old 180-minute budget (the
measured 139-min test leg plus the emulated wheel build would not fit). The docs
build stays `x64`'s, and static analysis stays off the row with
it: both steps carry `if: matrix.arch != 'riscv64'`. Pass `test-extras` (comma
list) so every leg syncs only those extras - a riscv64 leg wants `test`,
because the full set builds wheels from source under emulation. See
[`riscv64-cross-test-lanes.md`](riscv64-cross-test-lanes.md).

Packaging the riscv64 row is **opt-in** through `package-emulated: true`: an
arch-specific wheel (a Cython build) otherwise exists for every arch but this
one. The wheel is **cross-built on the amd64 row** (`PACKAGING_CROSS_TARGET=riscv64`,
`--platform linux/amd64`, the riscv64 sysroot and the staged target Python under
`/opt/python-cross/riscv64`), under the five setuptools knobs
[`linux-cross-builds.md` § Cross Python wheels](linux-cross-builds.md#cross-python-wheels-setuptools-knobs)
pins: `CC`/`LDSHARED` are the riscv64 cross wrapper, `CFLAGS` carries the target
include dir, `SETUPTOOLS_EXT_SUFFIX` the target SOABI suffix and
`_PYTHON_HOST_PLATFORM` the target tag — the last one on the wheel's
`python -m pip wheel` command alone, because uv reads it while inspecting the
interpreter and refuses the riscv64 tag at `uv venv` and `uv build` alike
(`Unknown operating system: linux_riscv64`); the sdist stays on `uv build --sdist`.
The wheel link also pins its emulation (`LDSHARED` carries `-Wl,-m,elf64lriscv`):
clang 22 dropped the target when it drove lld through `--gcc-toolchain` on the
runner and lld then refused the riscv64 crt objects as `elf64-x86-64` (run
37196119524). The emulated row only tests: its compile
hung four hours on one Cython unit (run 37127505865) and could not fit the
360-minute job. The app packages of a `packaging/app.json` app do not follow -
they need the AppImage tooling the image ships for amd64/arm64 only, so
`ci_packaging.sh` warns and ships wheels only there.

The packaging leg still syncs `SYNC_EXTRAS` (the caller's `test-extras`) instead
of all extras, and it shares `UV_CACHE_DIR=/workspace/.uv-cache` so its build
tools come from the cache the other rows warm. Measured 2026-10-03, with the
emulated predecessor: without both, the leg resolved 306 packages (opencv-python
and torchvision from git among them) and was killed at the 300-minute budget.

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

The image after CON11 exports neither variable (in source since 2026-09-26):
`Dockerfile.torch` empties both, since Docker cannot unset an inherited ENV, and the
entrypoint unsets them, so an activated venv is what uv targets again while
`/opt/venv/bin` stays first on `PATH`. Keep the pin: every image before it exports
both, and the pin is correct on either.

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
   (`abi3` and `none` fit any), or the sync fails naming the misfits. A `cp3XYt` venv is
   given the image's twins instead, when `PYTHON_WHEELS_CP314T` names their store (both
   lanes, § Free-threaded and GIL legs). On Linux it takes only the twins of the flavours
   `ORT_CHAIN_WHEEL_DIR` holds, since a GPU image's twin store carries two ORT flavours and a
   venv given both has two cores.
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
failed sync warns instead of failing the matrix. The reusable workflow passes only
`PYTEST_PATHS` and `FREE_THREADED_SYNC_EXTRAS` into the container (§ What the test leg runs),
so the consumer's `scripts/linux/ci_tests.sh` wrapper must export it.
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

**On Windows, OpenCV comes from the image too.** PyPI's `cv2.pyd` imports Media Foundation,
which Server Core lacks, so `import cv2` fails in every `:winamd64` venv. After the ORT
reconcile, `Sync-UvProjectDependencies` calls `Sync-UvChainOpenCv`. It uninstalls every
`opencv*` distribution and copies the image's cv2 into the venv. The copy's config names the
image dirs its DLL closure lives in: OpenCV's `bin`, the chain ORT and FFmpeg. Then it holds
`uv run` off the lock with `UV_NO_SYNC`, as the ORT reconcile does, because a re-sync would
put PyPI's opencv back. It is a no-op outside the image and in a venv without OpenCV. Why the config must be rewritten, and the
bundle's variant of the same copy:
[`python-app-bundles.md` § Windows: the image's OpenCV](python-app-bundles.md#windows-the-images-opencv-not-pypis).
Test: `windows/scripts/tests/Uv.ChainOpenCv.Tests.ps1`.

## What the test leg runs

**The project's own `testpaths`.** `ci_tests.sh` passes no path to pytest unless
`PYTEST_PATHS` (the `test-paths` input, comma-separated) names some, so pytest reads the
consumer's `testpaths`. It used to hard-code `tests/unit`. When WebDavClient gained its
arm64 and Windows lanes (2025-10-20) every lane narrowed to that directory, and its six
WebDAV client tests and the integration test ran on no lane until 2026-10-01. Windows
drivers live in the consumers (`scripts/windows/Build-Windows.ps1`) and must not
hard-code a subdirectory either.

**A free-threaded leg that gates.** `3.14t` sits in `EXPERIMENTAL_PYTHON_VERSIONS` by
default, because `--all-extras` pulls in wheels that only exist for the GIL build
(onnxruntime-genai-cuda, ai-edge-litert, atheris, bcrypt 4). Measured 2026-10-01, that leg
synced nothing and ran no test on any lane of OrchestrANT or WebDavClient, while every job
stayed green. The `free-threaded-extras` input (`FREE_THREADED_SYNC_EXTRAS`) fixes that:

- **Set:** a leg whose version ends in `t` syncs only those extras (`test`, say) plus the
  core dependencies, and gates like any other leg.
- **Empty:** the leg stays experimental. A failed venv, sync or test run then prints a
  `::warning title=Python <v> not tested::` annotation, so the run's summary shows it.
- **ORT:** a core set without ORT never meets the chain ORT's ABI check below (Trap 3). A
  test that needs an extra the leg does not install must skip, with
  `pytest.importorskip`.

Tests: `linux/scripts/tests/test-python-ci-defaults.sh`, mutations
`python.ci-tests-runs-the-configured-testpaths`,
`python.ci-tests-free-threaded-leg-syncs-its-own-extras` and
`python.ci-tests-experimental-sync-failure-is-annotated`.

## Windows arm64: the runner-native test job

`python-ci-windows.yml` with `arm64-tests: true` adds a `windows-11-arm` job. No Windows arm64
image runs on a hosted runner, so it takes no container. It checks the caller out with its
ANTfrastructure pin and runs `windows/scripts/python/Invoke-PythonTestLegs.ps1 -InstallUv`.

- **uv** is the `UV_VERSION` release zip, checked against `UV_WINDOWS_ARM64_SHA256` in
  `versions.env`. `bump_versions.py` refreshes that pin with the Linux ones.
- **Legs** come from `arm64-python-versions` (default `3.14`). Each leg gets its own venv
  through `New-UvProjectEnvironment`, so a bare `3.14` asks for `3.14+gil`. Without that, a
  `3.14t` leg earlier in the same job would hand it the free-threaded build (§ Free-threaded
  and GIL legs in one container).
- **Extras:** `arm64-extras` (empty means all extras), `free-threaded-extras` for a `t` leg,
  and `test-paths`, all as on Linux. Every leg gates. A failed leg does not stop the next one,
  and the error names every failed leg and its step: venv, sync or pytest.
- **Wheels only, in practice.** The runner has MSVC but not the family's clang-cl setup, and
  a package without a `win_arm64` wheel would build with the default `cl`. Keep such packages
  off ARM64 with a marker, `"<pkg>; platform_machine != 'ARM64'"`. Linux aarch64 reports
  `aarch64`, so the marker leaves Linux alone. WebDavClient does that for py-spy (no
  `win_arm64` wheel) and line_profiler (none for 3.14t). Check a lock before you turn the job
  on: `uv export --locked`, then
  `uv pip install --dry-run --no-deps --only-binary :all: --python-platform aarch64-pc-windows-msvc`.
  Run it once per leg's interpreter (`--python 3.14t` for the free-threaded leg).

The consumer must pin an ANTfrastructure that ships the script. The job refuses an older pin
by name instead of failing on a missing file. Test: `windows/scripts/tests/PythonTestLegs.Tests.ps1`
(a uv stand-in that records each call).

## Free-threaded and GIL legs in one container

Since CON66 the image ships the free-threaded interpreter itself, at
`/usr/local/bin/python3.14t` and outside uv's store, so a `3.14t` leg downloads nothing.
Since 2026-10-07 it is the toolchain stage's `--disable-gil` source build of
`PYTHON_VERSION`, no longer uv's python-build-standalone download
([`consumer-image-contract.md` § The free-threaded Python](consumer-image-contract.md#the-free-threaded-python)).
On an older image the leg still downloads one, and the rest of this section applies.

uv 0.12 lets a plain `3.14` request take a free-threaded build: once a `3.14t` leg has
downloaded `3.14.7+freethreaded` into uv's managed store, a later `uv venv --python 3.14`
in the same container picks it over the image's GIL `3.14.4` (WebDavClient, 2026-09-29,
BACKLOG CON40). `uv_ensure_python_available` also stripped the `t`, so `python3.14`
counted as having `3.14t`.

`uv_venv_create` therefore hands uv `uv_python_request`'s form: a bare `X.Y[.Z]` becomes
`X.Y[.Z]+gil`, and `3.14t`, paths and explicit variants pass unchanged. Only discovery
takes `+gil`; `uv python install 3.14+gil` fails with `No download found`, so the install
step passes the bare version, which installs the GIL build. Measured in `:latest` on
2026-09-30: legs 3.14t, 3.14, 3.13, 3.15, 3.14t, 3.14 in one container each got the
interpreter they named. Test: `linux/scripts/tests/test-uv-python-request.sh`.

Windows has the same trap and the same cure. `New-UvProjectEnvironment` asks uv for
`Get-UvPythonRequest`'s form. OrchestrANT's 3.14 leg took a free-threaded 3.14.7, which has
no wheel for one of its locked packages (2026-09-30). Test:
`windows/scripts/tests/Uv.PythonRequest.Tests.ps1`.

A Windows `3.14t` leg gets the image's interpreter too. A `:winamd64` built after 2026-10-07
ships `C:\python-freethreaded\python3.14t.exe`, source-built beside the GIL build and last on
`PATH` ([`windows-builds.md` § The free-threaded CPython](windows-builds.md#the-free-threaded-cpython)).
`uv venv --python 3.14t` and `uv build --python 3.14t` resolve to it with
`UV_PYTHON_DOWNLOADS=never`. An older image still has uv download one, and so does the arm64
runner-native job above, which runs without an image.

**The chain's own twins.** The same `:winamd64` ships `cp314-cp314t` builds of the chain wheels
whose code declares free-threading (ONNX Runtime, PyAV, apache-tvm-ffi and the two IREE
packages) in `PYTHON_WHEELS_CP314T` (`C:\runtime\wheels-cp314t`), apart from the GIL store
([`windows-builds.md` § The free-threaded wheels](windows-builds.md#the-free-threaded-wheels)).
`Sync-UvChainOnnxRuntime` reads that store for a venv whose ABI tag is `cp3XYt`, so a Windows
`3.14t` leg of an ORT project gets the chain ORT like its GIL legs. Without the store it fails
on the ABI as before. The arm64 bundle carries the same store with `win_arm64` twins, minus the
IREE compiler ([`windows-builds.md` § The arm64 cross twins](windows-builds.md#the-arm64-cross-twins)).

Linux does the same since 2026-10-07. `:latest` names its twin store, `/opt/wheels-cp314t`, in
the same variable, and `uv_reconcile_chain_ort` reads it for a `cp3XYt` venv
([`consumer-image-contract.md` § The free-threaded wheels](consumer-image-contract.md#the-free-threaded-wheels)).
An image without the variable still refuses the leg on the ABI, and the runtime smoke's
`FT-STORE` gate fails it. Test: `linux/scripts/tests/test-uv-chain-ort.sh`.

**uv downloads nothing for a `+gil` request**, so a version the host lacks is installed first.
OmniAccelerANT's 3.12 venv (its CMake format gate) stopped with `No interpreter found for
Python 3.12+gil in managed installations, search path, or registry` (2026-10-01). Like Linux's
`uv_ensure_python_available`, `New-UvProjectEnvironment` now asks `uv python find` first. When
nothing is found it runs `uv python install X.Y`, which installs the GIL build, and then
creates the `+gil` venv. Measured in `:winamd64`: 3.12 is installed and its venv is a GIL
3.12.14. 3.14 still takes the image's own `C:\temp\cpython`, with no download.

`uv build` is a second door into the same trap. It discovers its own interpreter and
ignores the venv, so `Invoke-CiPackaging.ps1` and `ci_packaging.sh` pass it the same
`--python X.Y+gil`. Without that flag, OrchestrANT's only Windows binary wheel was `cp314-cp314t`
(2026-10-01). The app bundle's GIL runtime could not install it.

The GIL interpreter `uv build` then finds is the image's in-tree build
(`C:\temp\cpython\PCbuild\amd64`). Its `python314.lib` sits beside `python.exe`, not in a
`libs\` directory, which is the only place setuptools looks: the Cython link failed with
`LNK1104: python314.lib`. The free-threaded download had hidden this, because it is a regular
install. The binaries step therefore puts the interpreter's directory on `LIB` whenever a
`python3*.lib` sits there.

## Two wheels: GIL and free-threaded

A project that declares free-threading support ships two binary wheels: `cp314-cp314` for
the GIL interpreter and `cp314-cp314t` for the free-threaded one. The sdist and the pure
`py3-none-any` wheel are built once, because they serve both.

**Opting in** is the official trove classifier, in `pyproject.toml`'s `[project]` table:

```toml
classifiers = ["Programming Language :: Python :: Free Threading :: 2 - Beta"]
```

Any level counts (`1 - Unstable`, `2 - Beta`, `3 - Stable`, `4 - Resilient`), and so does
the bare `Programming Language :: Python :: Free Threading`. `Programming Language :: Python
:: 3.14t` is no classifier: PyPI refuses an upload that names it, and the drivers ignore it.
The Cython build must declare the same, with `freethreading_compatible=True` in
`cythonize(compiler_directives=...)` (Cython 3.1+). Without it, every compiled module
re-enables the GIL when it loads, and the proof below fails.

**What the drivers do.** `ci_packaging.sh` and `Invoke-CiPackaging.ps1` read the classifier
with `linux/scripts/02-toolchain/python/free-threaded-wheel.py declares`. When it is there:

1. **The build.** After the GIL Cython wheel, the same `CYTHONIZE=True` build runs on the
   free-threaded twin of the packaging version (`3.14` gives `3.14t`). The interpreter is
   the image's, found by `uv python find` and never downloaded
   ([`consumer-image-contract.md` § The free-threaded Python](consumer-image-contract.md#the-free-threaded-python)).
   Without one the step fails and says so.
2. **The tag.** The build must leave one `cp314t` wheel. On Linux it is auditwheel-repaired
   like the GIL wheel. A pure result is logged and dropped.
3. **The proof.** A fresh venv of the same interpreter installs the shipped wheel without
   its dependencies, and `free-threaded-wheel.py prove` loads every compiled module the
   distribution owns. It creates each module without running its body: that is where CPython
   decides about the GIL, and a missing optional dependency then cannot fail or fake the
   verdict. A bare `.so` or `.pyd` counts as a module only when it exports `PyInit_<name>`,
   so a library the wheel bundles beside its modules is not loaded as one. The step fails when `sys._is_gil_enabled()` is true afterwards, and names each
   module whose `RuntimeWarning` re-enabled it.

The image's own wheels get the same twin and the same proof in the media stage, decided by
a table rather than a classifier ([`consumer-image-contract.md` § The free-threaded wheels](consumer-image-contract.md#the-free-threaded-wheels)).

Without the classifier the drivers build exactly what they built before, and log one line:
`free-threaded wheel skipped: the project does not declare support (...)`.

**The override** is `PYTHON_FREE_THREADED_WHEEL` (on Windows also `-FreeThreadedWheel`):
`auto`, the default, follows the classifier, `on` builds without it, and `off` skips it.
Any other value fails the run. A caller sets it with the `free-threaded-wheel` input of
`python-ci-linux.yml` (passed to the packaging container) and of `python-ci-windows.yml`
(passed to the build container, where `Invoke-CiPackaging.ps1` reads it).

**Cross lanes skip it.** The riscv64 cross build (`PACKAGING_CROSS_TARGET`) and the Windows
arm64 cross lane have no free-threaded target interpreter. They log `free-threaded wheel
skipped: the <arch> cross build has no free-threaded target interpreter`.

**The app bundles pick by their runtime's ABI.** `python-app-bundle.sh` and
`Select-PythonAppWheel` take the `cp314` wheel for their GIL runtime. A binary built for
another ABI alone is an error, not a fallback to the pure wheel.

**auditwheel on Linux** is PATH's, else the binary packaging venv's (OrchestrANT's
`packaging` extra installs it there). Until 2026-10-07 only PATH counted, and it never has
one, so every Cython wheel shipped as `linux_<arch>` under a log line calling it pure. With
no auditwheel anywhere, a platform wheel ships unrepaired, with a warning.

Tests: `linux/scripts/tests/test-python-free-threaded-wheel.sh` and
`windows/scripts/tests/PythonWheel.FreeThreaded.Tests.ps1`.

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
and no release publishes it. Its registry tags stay until the conditions in
[`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags)
are met. Name `:latest`:
[`rancher-desktop-linux-containers.md` § The image: always `:latest`](rancher-desktop-linux-containers.md#the-image-always-latest).
