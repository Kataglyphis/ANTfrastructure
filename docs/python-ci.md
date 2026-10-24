<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Python CI: the drivers, and the three traps in `uv`

The Python consumers (OrchestrANT, WebDavClient) share their whole CI surface with this repository:

| Layer | Where |
|---|---|
| Linux lane | [`../.github/workflows/python-ci-linux.yml`](../.github/workflows/python-ci-linux.yml) (`workflow_call`) |
| Windows lane | [`../.github/workflows/python-ci-windows.yml`](../.github/workflows/python-ci-windows.yml) (`workflow_call`), and its build driver `windows/scripts/python/Invoke-PythonCiBuild.ps1` (§ The Windows build driver) |
| Step drivers | `linux/scripts/02-toolchain/python/ci_{tests,static_analysis,build_docs,packaging}.sh` |
| uv primitives | `linux/scripts/01-core/python_uv.sh` |
| Chain ORT reconcile | `uv_reconcile_chain_ort` in `python_uv.sh`, `Sync-UvChainOnnxRuntime` in `windows/scripts/modules/WindowsUv.Common.psm1`; both run the ORT census `linux/scripts/03-media/runtime/ort-venv-census.py` (the Windows image's module copy runs the one `windows/Dockerfile` puts in `C:\temp\scripts\`) |
| Chain OpenCV (Windows) | `Sync-UvChainOpenCv` in `WindowsUv.Common.psm1`, over `Copy-ChainOpenCvPackage` in `WindowsPythonApp.Common.psm1` |
| App bundles (zip/MSI/deb/… inputs) | [`python-app-bundles.md`](python-app-bundles.md) |
| Free-threaded wheel (declared, proved) | `linux/scripts/02-toolchain/python/free-threaded-wheel.py`, run by both packaging drivers (§ Two wheels: GIL and free-threaded) |
| Tests on the installed cp3XYt wheel | `test-free-threaded-wheel.sh`, `windows/scripts/python/Invoke-FreeThreadedWheelTests.ps1` and the arm64 stage, over `free-threaded-wheel-tests.py` (§ The suite on the installed wheel) |

A consumer's workflow is configuration, not steps: its `scripts/linux/ci_*.sh` wrappers
`antfrastructure_exec` into the drivers above
([`../shared/linux/templates/README.md`](../shared/linux/templates/README.md)).

## Positional arguments: empty means default

Every driver reads its positionals as `"${N:-default}"`, which treats an **empty** argument like
an absent one. So the reusable workflows pass every version input unconditionally and let an
empty value fall through to the driver's default: no conditional command building anywhere, and a
caller names a version only to override it. That is why two consumers that *looked* different ran
identical commands: the pinned X.Y is `ci_static_analysis.sh`'s default (`DEFAULT_PYTHON_VERSION`: the
image's `PYTHON_MAJOR_MINOR`, else `versions.env`'s `PYTHON_VERSION`; § Upgrading Python).

## One arch per caller: the `arches` input

`python-ci-linux.yml` takes `arches` (string, default `"x64 arm64"`): the rows to run,
space-separated. The default runs both, so a caller written before the input keeps its job names
(`x64`, `arm64`) and artifact names. A caller on the fleet's one-file-per-arch convention
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

The docs build runs on the `x64` row only, after a red test too, and uploads the site as
`python-docs-site`; the `docs` job hands it to `build-docs.yml`, which adds the `.htaccess`, checks
its links (`docs-link-allow`) and publishes it on a push to `develop` or `main`
([`docs-sites.md`](docs-sites.md#the-reusable-workflow)). So the `linux-x64.yml` caller passes the
FTP secrets.

A `plan` job turns the list into the build matrix and **fails** on an unknown name (`amd64`,
`x86_64`), a name listed twice and an empty list; otherwise `arches: "x64 arn64"` would run one
row and stay green. Separators are whitespace, newlines included, so a block-scalar input works;
`x64,arm64` is one unknown name.

**Why a plan job and not a filtered static matrix.** An `exclude:` cannot drop a row that
`include:` defines: GitHub applies `exclude` first, and an `include` entry that no longer fits any
combination is added back as a new one. So the rows live once, in the plan step's `case` table,
and the build job reads `fromJSON(needs.plan.outputs.matrix)`. Cost: the runner labels sit inside
a `run:` block, where the workflow-convention gate's `*-latest` ban cannot see them;
[`tests/test-reusable-linux-lane.sh`](../linux/scripts/tests/test-reusable-linux-lane.sh)
runs that step and holds the labels to the same rule.

**Consumers follow hub `develop`.** The fleet calls this lane at `@develop` (since 2026-09-25), so
the input reached the consumers at once. WebDavClient split its `ubuntu-26.04-amd64-arm64.yml`
into `linux-x64.yml` and `linux-arm64.yml` the same day; OrchestrANT followed.

### riscv64: the image itself runs under QEMU

`arches: riscv64` runs on an amd64 runner with the riscv64 image under QEMU, tests only. The row:

- registers QEMU's binfmt handler through `setup-riscv64-cross` with `sysroot: false` (the sysroot
  serves cross builds; a Python lane has nothing to cross-compile);
- runs every container step with `--platform linux/riscv64`;
- carries its own `timeout: 360` in the plan's matrix: the first opt-in packaging run hit the old
  180-minute budget (the measured 139-min test leg plus the emulated wheel build would not fit);
- leaves the docs build to `x64` and skips static analysis: both steps carry
  `if: matrix.arch != 'riscv64'`.

Pass `test-extras` (comma list) so every leg syncs only those extras: a riscv64 leg wants `test`,
because the full set builds wheels from source under emulation. See
[`riscv64-cross-test-lanes.md`](riscv64-cross-test-lanes.md).

Packaging the riscv64 row is **opt-in** through `package-emulated: true`: an arch-specific wheel
(a Cython build) otherwise exists for every arch but this one. The wheel is **cross-built on the
amd64 row** (`PACKAGING_CROSS_TARGET=riscv64`, `--platform linux/amd64`, the riscv64 sysroot and
the staged target Python under `/opt/python-cross/riscv64`), under the five setuptools knobs
[`linux-cross-builds.md` § Cross Python wheels](linux-cross-builds.md#cross-python-wheels-setuptools-knobs)
pins:

- `CC`/`LDSHARED` are the riscv64 cross wrapper, `CFLAGS` carries the target include dir,
  `SETUPTOOLS_EXT_SUFFIX` the target SOABI suffix.
- `_PYTHON_HOST_PLATFORM` is the target tag, on the wheel's `python -m pip wheel` command alone:
  uv reads it while inspecting the interpreter and refuses the riscv64 tag at `uv venv` and
  `uv build` alike (`Unknown operating system: linux_riscv64`). The sdist stays on
  `uv build --sdist`.

The wheel link searches the sysroot's libraries first (`LDSHARED` carries
`-L<sysroot>/lib/riscv64-linux-gnu -L<sysroot>/usr/lib/riscv64-linux-gnu`). setuptools appends the
host interpreter's `LIBDIR` (`/usr/lib/x86_64-linux-gnu`) to every extension link, so the driver's
`-lc` found the host `libc.so`, whose linker script's `OUTPUT_FORMAT(elf64-x86-64)` overrides lld's
emulation: lld refused every riscv64 object "as incompatible with elf64-x86-64" (runs 37196119524
and 37329297990, reproduced 2026-10-07). It was not a dropped target, as first read: the
`-Wl,-m,elf64lriscv` pin that answered that reading failed the same way, and the link succeeds
without it.

The emulated row only tests: its compile hung four hours on one Cython unit (run 37127505865) and
could not fit the 360-minute job. The app packages of a `packaging/app.json` app do not follow:
they need the AppImage tooling the image ships for amd64/arm64 only, so `ci_packaging.sh` warns and
ships wheels only there.

**The test legs start from the image's uv cache seed.** `ci_tests.sh` copies
`PYTHON_UV_CACHE_SEED` into uv's cache before its first sync, so the wheels the app lock's `test`
extra would build under QEMU (numpy, matplotlib, contourpy, pillow, line-profiler, psutil, pyyaml:
108 min on 2026-10-07) are already built, for the `X.Y` leg and, since CON110, the `X.Yt` one
([`consumer-image-contract.md` § The riscv64 uv cache seed](consumer-image-contract.md#the-riscv64-uv-cache-seed)).
It covers the lock of the OrchestrANT commit the image was built from; a package the consumer's
lock moved since builds as before.

**The cross wheel is installed where it runs.** After packaging, the row runs `ci-wheel-smoke.sh`
in the riscv64 image under QEMU (CON83): it takes the one `cp3XY` riscv64 wheel from `dist/`,
installs it into a fresh venv over the lock's core dependencies
(`uv sync --locked --no-dev --no-install-project`, from the same seed), imports the package
outside the checkout and loads every compiled module the wheel owns without running its body,
since a module may import an optional extra the core install lacks (`wheel-smoke.py`). A wheel
built for the wrong arch, linked against a missing symbol or shadowed by the source tree fails the
row. The step needs a hub pin that ships the script; on an older pin a host step before it skips it
with a warning, so a consumer's lane stays green until its own gitlink moves.

The packaging leg syncs `SYNC_EXTRAS` (the caller's `test-extras`), not all extras, and shares
`UV_CACHE_DIR=/workspace/.uv-cache`, so its build tools come from the cache the other rows warm.
Measured 2026-10-03 with the emulated predecessor: without both, the leg resolved 306 packages
(opencv-python and torchvision from git among them) and was killed at the 300-minute budget.

## Working on a Python consumer locally

What both consumers share on a developer's machine (2026-10-19; it left their READMEs).

**The pre-commit hook** is the same ruff-only config in both:

```bash
uv venv
source .venv/bin/activate   # .venv/Scripts/activate in pwsh
uv pip install pre-commit
pre-commit install
pre-commit run --all-files  # once, optional
```

**Static analysis is a gate, not a report.** `scripts/linux/ci_static_analysis.sh` is the driver CI
runs; it exits `1` when codespell, bandit, vulture, `ruff check --no-fix`, `ruff format --check` or
`ty check` finds anything. Redirecting its output to a log file hides that exit from the terminal:
check `$?`, or drop the redirect.

**A binary-only wheel** compiles every module with Cython (`setup.py`'s `CYTHONIZE` branch; the
idea: [Protect source code](https://art-vasilyev.github.io/posts/protecting-source-code/)).
`python -m zipfile --extract <WHEEL> <TARGET_DIR>` shows what one holds, and
`pip debug --verbose` lists the tags the interpreter accepts.

**The tools in the `test` extras:** [ty](https://github.com/astral-sh/ty) (types),
[ruff](https://github.com/astral-sh/ruff) (lint and format), [uv](https://github.com/astral-sh/uv)
(environments and locks), [py-spy](https://github.com/benfred/py-spy) (sampling profiler),
[line_profiler](https://github.com/pyutils/line_profiler) and
[pytest-benchmark](https://github.com/ionelmc/pytest-benchmark).

## The static-analysis knobs, and the bandit trap between them

Two knobs decide what the six analysers grade; each has a Windows twin with the same default:

| Knob | Windows twin | Default |
|---|---|---|
| `STATIC_ANALYSIS_EXTRA_PATHS` | `-ExtraPaths` | empty |
| `BANDIT_EXCLUDES` | `-BanditExcludes` | `tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results` |

`STATIC_ANALYSIS_EXTRA_PATHS` is a space-separated path **list**, word-split on purpose, so no
element may contain a space. It exists because the first-party tree outside a consumer's importable
package was graded by nothing: OrchestrANT's `benchmarks/`, `frontend/`, `bench/` and `examples/`
were outside every analyser until it landed.

**The trap.** Both drivers spelled the extras as one `-r` per path. bandit's `-r` is `store_true`
against a **single** `nargs='*'` positional, so `bandit -r a -r b` is `unrecognized arguments` and
exit 2 (measured against bandit 1.9.4 in the family image). The bandit gate failed on the very knob
the other five analysers handled, so OrchestrANT could not adopt it. bandit accepts **one `-r`
followed by the whole target list**; `tests/test-python-static-analysis.sh` counts the flags so it
cannot come back.

`BANDIT_EXCLUDES` **replaces** the default list, it does not add to it: a consumer that names an
exclude set means that set. It is how a consumer stops hard-coding the whole `-x` string in its own
driver.

## Turning the Windows PowerShell lint on

`python-ci-windows.yml` takes `lint-powershell` (boolean, default `false`) and `lint-path` (string,
default `scripts`). Together they add a second job on the same Windows runner that runs
[`windows/scripts/Invoke-Lint.ps1`](../windows/scripts/Invoke-Lint.ps1) — the mandatory parse
pass, the AST traps and PSScriptAnalyzer — over the **caller's** tree, with the hub's ruleset
consumed by reference.
The job installs `PSSCRIPTANALYZER_VERSION` from the checked-out hub's
`linux/scripts/01-core/versions.env`; the lint process imports that exact version.
A missing pin or pinned installation fails the job.

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

It is a separate job and does **not** `needs:` the build: a syntax error in the build scripts is
exactly when the lint is worth having, and it needs no image pull. `-FailOnAnalyzer` is passed
unconditionally and is no input: without it the analyzer prints its findings and exits 0, a check
that cannot fail.

**The lint without the build.** `build-python-package` (boolean, default `true`) gates the
container build job, so a repo with no Python package can call this lane for the gate alone:

```yaml
jobs:
  powershell-lint:
    uses: Kataglyphis/ANTfrastructure/.github/workflows/python-ci-windows.yml@develop
    with:
      build-python-package: false
      lint-powershell: true
```

No `secrets:` block, on purpose: `GHCR_PAT` is `required: false`, because a required secret is
refused at call time and would make the lint unreachable for exactly the callers this switch is
for. The build job asserts the token in its own first step, so a caller that wanted the build and
forgot the secret is told which input it missed instead of failing inside a `docker login` against
ghcr. OxidANT (a Rust crate whose Windows container build is a different workflow) had measured the
lint job as byte-for-byte its own and still could not call this lane until the gate existed. Every
caller written before the switch is unchanged: it defaults on.

## Trap 1 — `--all-extras` is fatal with declared conflicts

`uv sync --all-extras` is not "install as much as possible". On a project that declares
`[tool.uv] conflicts`, uv refuses outright:

```
error: Extras `ml-ai` and `ml-ai-webgpu` are incompatible with the declared
       conflicts: {`orchestrant[ml-ai]`, `orchestrant[ml-ai-webgpu]`}
```

No flag means "pick a satisfiable subset". OrchestrANT declares 12 pairwise conflicts across two
mutually exclusive families (the `ml-ai-*` and the `pytorch-*` backends), so every one of its lanes
died here, whatever it had been asked to do.

`uv_sync_project()` handles it, in this order:

1. **`UV_SYNC_EXTRAS`**: an explicit list (`"a,b"` or `"a b"`) becomes `--extra a --extra b`, and
   `--all-extras` is dropped. The project knows best.
2. **Auto-detect**: otherwise the conflict groups are parsed out of `pyproject.toml` and enough
   extras are excluded via `--no-extra` to make `--all-extras` satisfiable. Greedy in
   **declaration order**: keep an extra unless it conflicts with one already kept.

Declaration order keeps the first-declared member of each family: for OrchestrANT `ml-ai` and
`pytorch-cpu`, the right pair for CI. The choice is logged, with a pointer to `UV_SYNC_EXTRAS`. A
project with no conflicts gets an empty exclusion list and a byte-identical command.

The group scanner reads TOML, not one indentation style. It used to gather a line's `extra = "…"`
occurrences only **after** the character walk had closed the group on that line's `]`, so an
inline group — `conflicts = [ [ { extra = "a" }, { extra = "b" } ] ]`, which uv accepts — produced
no group, excluded nothing, and left `--all-extras` to die on the conflict it was meant to route
around. The group's text is now accumulated during the walk and read at the `]` that closes it, so
inline, multi-line and mixed layouts give the same answer. OrchestrANT writes the multi-line form,
so this was latent there. Only a consuming repo's CI lane running `uv sync --all-extras` settles it:
no ANTfrastructure cross stage calls `uv_sync_project`; only `02-toolchain/python/ci_*.sh` reaches
it.

## Trap 2 — `UV_PYTHON` beats the activated venv

The CI images export `UV_PYTHON=/opt/venv/bin/python` (a root-owned system venv) and run as the
non-root user `kataglyphis`. **uv honours `UV_PYTHON` over the activated virtualenv**, so `--active`
alone is not enough: the sync targets `/opt/venv` and dies:

```
error: failed to remove file `/opt/venv/lib/python3.14/site-packages/...`:
       Permission denied (os error 13)
```

So `uv_sync_project()` and `uv_pip_install_requirements()` pin `--python <venv>/bin/python`; the pin
is load-bearing, not tidiness. Pin any new uv entry point too, and end it in
`uv_reconcile_chain_ort` (Trap 3).

The image after CON11 exports neither `UV_PYTHON` nor `VIRTUAL_ENV` (in source since
2026-09-26): `Dockerfile.torch` empties both, since Docker cannot unset an inherited ENV, and the
entrypoint unsets them, so uv
targets an activated venv again while `/opt/venv/bin` stays first on `PATH`. Keep the pin: every
image before it exports both, and the pin is correct on either.

The two traps stack: the extras error hides the venv error, because the resolve never gets far
enough to write anything. Fixing only the first just moves the failure.

## Trap 3 — ONNX Runtime comes from the chain, not PyPI

Owner rule of 2026-09-23: every component that uses ONNX Runtime loads the ORT this repository
builds ([`onnxruntime-single-source.md`](onnxruntime-single-source.md)); a consumer's test venv
inside our images is one. Before the rule, `uv sync --all-extras` installed whatever the lock named,
so OrchestrANT's CI tested on PyPI `onnxruntime`, `onnxruntime-gpu` and `onnxruntime-genai` (plus
the `-directml` pair on Windows), all overlapping in one `site-packages/onnxruntime`.

**Inside our images the sync installs no PyPI ORT at all** (since 2026-10-12). With a `uv.lock`
and a chain store (step 1 below: `ORT_CHAIN_WHEEL_DIR` on Linux; on Windows also the image's
`PYTHON_WHEELS`), `uv_sync_project` and `Sync-UvProjectDependencies` pass `--no-install-package` for
every lock entry the census counts as ONNX Runtime (`onnxruntime` and `onnxruntime-*`), on the
unlocked retry too, and the reconcile installs the chain wheels in their place. The chain's ORT
then serves a Python that PyPI's has no wheel for yet: 1.31.0 stopped at cp314 when 3.15.0 came out, and
a locked sync on 3.15 failed on it.

Every `uv_sync_project` (Linux) and `Sync-UvProjectDependencies` (Windows) ends by reconciling the
venv it synced:

1. **Inside our images?** The chain wheel store says so. Linux: `ORT_CHAIN_WHEEL_DIR`, which
   `linux/Dockerfile.torch` sets to `/opt/onnxruntime-wheels`. Windows: `ORT_CHAIN_WHEEL_DIR`, else
   the image's `PYTHON_WHEELS` (`C:\runtime\wheels`), else `C:\runtime\wheels` if it exists.
2. **The census names the ORT distributions.** The venv's own interpreter runs
   `ort-venv-census.py --purge-list` with `-I`: every distribution named `onnxruntime` or
   `onnxruntime-*`, and every owner of the `onnxruntime`, `onnxruntime_genai` or
   `onnxruntime_extensions` package.
3. **No ORT distribution:** inside our images the venv's interpreter still checks that none of
   those three packages imports; an ORT package no distribution owns (copied files, a
   `pip --target` leftover) fails the sync. **Outside our images:** a loud `NOTICE` that names the
   distributions, and the venv stays as uv resolved it.
4. **The ABI check comes first.** The chain wheels are built for the image interpreter (cp314
   today), and uv installs a path wheel of another ABI tag without complaint. So before the venv is
   touched, each store ORT wheel's tag must fit the venv's own (`abi3` and `none` fit any), or the
   sync fails naming the misfits. A `cp3XYt` venv gets the image's twins instead, when
   `PYTHON_WHEELS_FREE_THREADED` names their store (both lanes, § Free-threaded and GIL legs). On
   Linux it takes only the twins of the flavours `ORT_CHAIN_WHEEL_DIR` holds: a GPU image's twin
   store carries two ORT flavours, and a venv given both has two cores.
5. **The replacement:** `uv pip uninstall` every listed distribution that reached the venv (a
   skipped one never did), then `uv pip install --no-index --no-deps --force-reinstall` every
   `onnxruntime[-_]*.whl` in the store. Then two proofs, and **either one failing fails the sync**:
   `--check --store` (each ORT distribution byte-identical to a store wheel, `onnxruntime` owned
   once), and `import onnxruntime` in that venv, which catches a load failure on a fitting tag.
6. **`UV_NO_SYNC=1` is exported on success**, only when it was unset, and released by the next sync
   of a venv without ORT. `uv run` re-syncs to the lock by default and would put PyPI ORT back;
   `uv sync` itself ignores the variable.

A failed `uv sync` keeps its own exit status; the reconcile never runs after it.

**Where the Linux store comes from.** `/opt/wheels` is only a bind mount inside the torch RUN, so
`setup-torch-venv.sh stage_chain_ort_wheels` copies exactly the wheels the census matched
`/opt/venv` against (the installed flavour only) into `ORT_CHAIN_WHEEL_DIR` and proves `/opt/venv`
against the store. Any failure stops the image build; a venv without ORT leaves the store empty.

**A leg on another interpreter.** Inside our images an ORT project's legs run on the image
interpreter. Two remedies work on both lanes:

- drop the other legs (`test-python-versions`, or the consumer's `$PythonVersions`);
- list them in `EXPERIMENTAL_PYTHON_VERSIONS`, so a failed sync warns instead of failing the
  matrix. The reusable workflow passes only `PYTEST_PATHS` and `FREE_THREADED_SYNC_EXTRAS` into the
  container (§ What the test leg runs), so the consumer's `scripts/linux/ci_tests.sh` wrapper must
  export it.

`UV_SYNC_EXTRAS` is NOT a remedy: every sync of the run reads it, so leaving ORT out of one leg
leaves it out of all of them.

The hub defaults are the image interpreter (owner decision 2026-09-23): `PYTHON_VERSION`'s X.Y
for `ci_tests.sh`, `ci_build_docs.sh`'s `COVERAGE_VERSION` and the static-analysis and packaging
drivers, plus X.Yt for a project that declares free-threading; `tests/test-python-ci-defaults.sh`
holds them to `versions.env`. Every lane tests and packages only that X.Y and X.Yt (owner,
2026-10-20): a consumer names no version, or `pinned` and `pinnedt`.

| Message | Cause | Fix |
|---|---|---|
| `chain ORT: need the store … the interpreter … and the census …` | the store is declared but missing (an image regression), or the venv interpreter or the census is missing | the census comes from the hub checkout (`linux/scripts/03-media/runtime/`) or, for the Windows image's module copy, from `C:\temp\scripts\ort-venv-census.py`; an image built before `windows/Dockerfile` COPYed it there has none, so import the module from the hub checkout |
| `the store … holds no onnxruntime wheel` | the store is empty, for example a venv built without ORT | build the store with ORT, or keep ORT out of that venv |
| `… is a cp313 venv, and the chain wheels are built for the image interpreter: …` | the leg's interpreter is not the image's; the venv was not touched | drop the leg or list it in `EXPERIMENTAL_PYTHON_VERSIONS` |
| `… imports ONNX Runtime with no distribution to purge (…)` plus census `FAIL` lines | an ORT package no distribution owns | remove the files the `FAIL` lines name |
| `the chain onnxruntime does not import in …` | the tag fits but the load fails (a DLL or `.so` the venv cannot find) | the import error follows the message |
| `still carries a non-chain ONNX Runtime` | the census found a foreign distribution | read the `FAIL` lines that follow |

`onnxruntime-extensions` and prebuilt plugin-EP wheels have no chain counterpart: they are purged
and not replaced, as the rule asks.

**Not covered:** tool venvs built from requirement files (`uv_pip_install_requirements` /
`Install-UvRequirements`: cmake-format, docs), `uvx` / `uv tool`, pip calls outside these helpers,
ORT vendored under another import name, and runners that are not our images (they get the notice
only). The Windows chain wheel importing in a plain consumer venv, without the app venv's
DLL-directory shim, has not been run inside `:winamd64` yet.

**Tests:** `linux/scripts/tests/test-uv-chain-ort.sh` (a real venv plus the real census, with a uv
stand-in), `windows/scripts/tests/Uv.ChainOrt.Tests.ps1` (including the image's module copy in the
layout `windows/Dockerfile` builds), and the mutation family `uv-chain-ort` in
`docs/scripts/mutations.json`.

**On Windows, OpenCV comes from the image too.** PyPI's `cv2.pyd` imports Media Foundation, which
Server Core lacks, so `import cv2` fails in every `:winamd64` venv. After the ORT reconcile,
`Sync-UvProjectDependencies` calls `Sync-UvChainOpenCv`: it uninstalls every `opencv*` distribution,
copies the image's cv2 into the venv (the copy's config names the image dirs its DLL closure lives
in: OpenCV's `bin`, the chain ORT and FFmpeg), and holds `uv run` off the lock with `UV_NO_SYNC`, as
the ORT reconcile does, because a re-sync would put PyPI's opencv back. It is a no-op outside the
image and in a venv without OpenCV. Why the config must be rewritten, and the bundle's variant of
the same copy:
[`python-app-bundles.md` § Windows: the image's OpenCV](python-app-bundles.md#windows-the-images-opencv-not-pypis).
Test: `windows/scripts/tests/Uv.ChainOpenCv.Tests.ps1`.

## What the test leg runs

**The project's own `testpaths`.** `ci_tests.sh` passes pytest no path unless `PYTEST_PATHS` (the
`test-paths` input, comma-separated) names some, so pytest reads the consumer's `testpaths`. It
used to hard-code `tests/unit`: when WebDavClient gained its arm64 and Windows lanes (2025-10-20),
every lane narrowed to that directory, and its six WebDAV client tests and the integration test ran
on no lane until 2026-10-01. The Windows driver takes the same list as `TestPaths`
(§ The Windows build driver).

**A free-threaded leg that gates.** The pinned X.Yt sits in `EXPERIMENTAL_PYTHON_VERSIONS` by default,
because `--all-extras` pulls in wheels that exist only for the GIL build (onnxruntime-genai-cuda,
ai-edge-litert, atheris, bcrypt 4). Measured 2026-10-01: that leg synced nothing and ran no test on
any lane of OrchestrANT or WebDavClient, while every job stayed green. The `free-threaded-extras`
input (`FREE_THREADED_SYNC_EXTRAS`) fixes that:

- **Set:** a leg whose version ends in `t` syncs only those extras (`test`, say) plus the core
  dependencies, and gates like any other leg.
- **Empty:** the leg stays experimental. A failed venv, sync or test run prints a
  `::warning title=Python <v> not tested::` annotation, so the run's summary shows it.
- **ORT:** a core set without ORT never meets the chain ORT's ABI check below (Trap 3). A test that
  needs an extra the leg does not install must skip, with `pytest.importorskip`.

Tests: `linux/scripts/tests/test-python-ci-defaults.sh`, mutations
`python.ci-tests-runs-the-configured-testpaths`,
`python.ci-tests-free-threaded-leg-syncs-its-own-extras` and
`python.ci-tests-experimental-sync-failure-is-annotated`.

## The Windows build driver

`python-ci-windows.yml`'s build job runs `build-script` in the `:winamd64` container. Left empty,
that is the repo's own `scripts\windows\Build-Windows.ps1` when the checkout has one, else
[`windows/scripts/python/Invoke-PythonCiBuild.ps1`](../windows/scripts/python/Invoke-PythonCiBuild.ps1)
with `-RepoRoot` set to the mount. The driver runs the Linux lane's four steps, logging to
`logs\build-windows-*.log` and `logs\build-summary-*.json`:

1. **pytest per leg**, each leg in its own venv, synced `--locked` when `uv.lock` exists. The
   `bench/` demos log `skipped` instead of failing. A leg with no extras of its own that
   `EXPERIMENTAL_PYTHON_VERSIONS` lists (default: the pin's X.Yt) may fail without failing the run.
2. **`Invoke-CiStaticAnalysis.ps1`**, which gates.
3. **`DataLocks`**, each fetched beside itself by the hub's `fetch-data-lock.py`
   ([`data-repositories.md`](data-repositories.md#the-hubs-fetcher)), then **`Invoke-CiPackaging.ps1`**.
4. **`Invoke-FreeThreadedWheelTests.ps1`**, the tests on the installed cp3XYt wheel
   (§ The suite on the installed wheel), which gates.

A repo keeps its values in `scripts\windows\python-ci.psd1`, under the driver's parameter names. A
parameter on the command line wins; a key that is no parameter fails the run.

```powershell
# scripts\windows\python-ci.psd1
@{
    PackageName           = 'orchestrant'
    FreeThreadedExtras    = 'test'
    ExtraPaths            = @('benchmarks', 'frontend', 'bench', 'examples')
    BanditExcludes        = 'tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results,benchmarks/tests'
    DataLocks             = @('resources/models/models.lock')
}
```

| Setting | Linux twin | Empty means |
|---|---|---|
| `PackageName` | `package-name` | pyproject.toml's `name` |
| `PythonVersions` | `test-python-versions` | the pinned X.Y, plus X.Yt when pyproject.toml declares free-threading; `pinned` and `pinnedt` work in a list |
| `TestExtras` | `test-extras` | every extra |
| `FreeThreadedExtras` | `free-threaded-extras` | every extra, and the X.Yt leg stays experimental |
| `TestPaths` | `test-paths` | the project's `testpaths` |
| `StaticAnalysisPythonVersion`, `PackagingPythonVersion` | `static-analysis-python-version`, `packaging-python-version` | the pin |
| `ExtraPaths`, `BanditExcludes` | `STATIC_ANALYSIS_EXTRA_PATHS`, `BANDIT_EXCLUDES` | § The static-analysis knobs |
| `DataLocks` | the repo's `ci_packaging.sh` wrapper | nothing is fetched |
| `EnablePySpy` | — | no py-spy demo |

To run it by hand, start it from the repo root inside `:winamd64`:
`pwsh -File third_party\ANTfrastructure\windows\scripts\python\Invoke-PythonCiBuild.ps1`. Test:
`windows/scripts/tests/PythonCiBuild.Tests.ps1`, with a uv, a python and the three child drivers
replaced by stand-ins that record each call.

The Windows free-threaded wheel-test driver scopes suite environment variables
through `Invoke-WithProcessEnvironment`. Absent, empty and configured parent
values are restored after success, failed setup or a thrown test command, while
location and native test status retain their existing policy. Shared Linux helper
lookup lives in `WindowsPythonWheel.Common`; UV's ORT census uses that resolver
with the same repository-first and copied-image fallback paths.

## Windows arm64: the staged test job

`python-ci-windows.yml` with `arm64-tests: true` adds two jobs (CON113, 2026-10-20). A hosted
`windows-11-arm` runner has no image, so a `windows-2025` job stages everything the device runs in
`:winarm64`, and the device job installs nothing. Before, the device job installed uv and the pinned
CPython through uv (`Downloading cpython-3.15.0-windows-aarch64-none`, WebDavClient run
39336879640) and built the wheels with the runner's Visual Studio.

**The stage**, `windows/scripts/python/New-Arm64PythonTestStage.ps1` from the caller's ANTfrastructure
pin, writes `dist\windows-arm64-python`:

- **Legs** from `arm64-python-versions`. Empty is the pinned X.Y, plus X.Yt when `pyproject.toml`
  declares free-threading (`Resolve-PythonLegList`); `pinned` and `pinnedt` stand for X.Y and X.Yt.
- **Interpreters:** per leg a copy of the image's target tree, `C:\runtime\python` or
  `C:\runtime\python-freethreaded`, with its site-packages emptied.
- **Wheels:** the leg's `cpXY` or `cpXYt` `win_arm64` wheel, cross-built with the image's VS 2026 and
  clang-cl in a child process (`New-CrossBuildPython`, `Invoke-CrossWheelBuild`, `CYTHONIZE=True`).
  `CL` carries `--target=aarch64-pc-windows-msvc`, so a `setup.py` that swaps in clang-cl needs no
  target flag of its own.
- **Site-packages:** the lock's set and the leg's wheel, installed for the target with the host's
  interpreter of the same ABI (`Install-PythonCrossSite`). Extras: `arm64-extras` (empty is all),
  `free-threaded-extras` for an X.Yt leg. Every package is hash-checked from `uv.lock`; pyyaml is built
  pure from its locked sdist; a `cp3XYt` wheel PyPI lacks (psutil) comes from the image's
  `wheels-free-threaded\deps`, by its own hash.
- **Tests:** `arm64-test-files` (empty: `tests` and the root's pytest configuration files) are copied
  to `run\` without the package, so the tests import the installed wheel. `arm64-test-env` takes
  `NAME=value` pairs, `test-paths` pytest's paths.
- **Proofs:** each binary wheel unpacked alone to `proof-<leg>`, for `free-threaded-wheel.py load` on
  a GIL leg and `prove` on an X.Yt leg (`Get-NativeWheelCheck`), under `python -S`.
- **Wheel tests:** on an X.Yt leg, `pyproject.toml`'s free-threaded wheel tests in `wheel-tests-<leg>\`
  and `wheel-tests-<leg>.cmd`, on the leg's own interpreter and site (§ The suite on the installed
  wheel). The leg must install the table's `extra`, or the stage fails.

The arch gate then grades the tree standalone (every PE ARM64, at least 10, every import resolved
in the stage or Windows), and the tree uploads as `python-windows-arm64-stage`.

**The device** runs `Invoke-StagedTests.ps1` over its `tests.json`: per leg `run-pytest-<leg>.cmd` and
`prove-<leg>.cmd`, and `wheel-tests-<leg>.cmd` on an X.Yt leg. The one `TESTS:` line goes to the
summary; a failed test or proof, or no passing test, fails the job. With `arm64-wheels: true` it then uploads the wheels as
`packages-windows-arm64-wheels`.

**What fails the stage:** a locked package with no `win_arm64` wheel for a leg and no pure build. uv
builds it with the host interpreter and refuses the result. Keep it off ARM64 with a marker,
`"<pkg>; platform_machine != 'ARM64'"` (Linux aarch64 reports `aarch64`), as WebDavClient does for
py-spy and line_profiler, or give the image its wheel (`Build-TargetSdistWheel.ps1`).

**A release** that collects `*.whl` from every upload must skip the stage
(`--skip python-windows-arm64-stage`): its two interpreters carry ensurepip's pip wheel.

Tests: `PythonArm64Stage.Tests.ps1`, `PythonApp.Cross.Tests.ps1` (`Install-PythonCrossSite`),
`PythonWheel.FreeThreaded.Tests.ps1` (`Resolve-PythonLegList`, `Get-NativeWheelCheck`) and
`test-reusable-windows-lane.sh`. The stage itself runs only in `:winarm64`.

## Free-threaded and GIL legs in one container

Since CON66 the image ships the free-threaded interpreter itself, at `/usr/local/bin/python3.14t`,
outside uv's store, so a `3.14t` leg downloads nothing. Since 2026-10-07 it is the toolchain stage's
`--disable-gil` source build of `PYTHON_VERSION`, no longer uv's python-build-standalone download
([`consumer-image-contract.md` § The free-threaded Python](consumer-image-contract.md#the-free-threaded-python)).

Since 2026-10-11 the leg also cannot download one. In the shipped image, whose ENV names
`PYTHON_MAJOR_MINOR` and `PYTHON_CROSS_ACTIVE_ROOT`, `uv_venv_create` runs `uv venv` for
`PYTHON_MAJOR_MINOR` and its `t` twin with `UV_PYTHON_DOWNLOADS=never` and logs the interpreter it
took (`the image's own interpreter, UV_PYTHON_DOWNLOADS=never (/opt/python-freethreaded 3.14.8)`).
When the image lacks that interpreter, the leg fails with
`python3.14t is missing, though this image ships it` instead of downloading one. Other versions and
runs outside the image still let uv download, and a caller's own `UV_PYTHON_DOWNLOADS` wins.
Measured in the `:latest` amd64 child on 2026-10-11 with `python3.14t` hidden from `PATH`: the old
code downloaded a free-threaded CPython and WebDavClient's `3.14t` leg passed, 23 tests green; the
new code fails the leg. An image older than 2026-10-07 has no `python3.14t`, so its `3.14t` leg now
fails, and the rest of this section is history.

uv 0.12 lets a plain `3.14` request take a free-threaded build: once a `3.14t` leg has downloaded
`3.14.7+freethreaded` into uv's managed store, a later `uv venv --python 3.14` in the same container
picks it over the image's GIL `3.14.4` (WebDavClient, 2026-09-29, BACKLOG CON40).
`uv_ensure_python_available` also stripped the `t`, so `python3.14` counted as having `3.14t`.

So `uv_venv_create` hands uv `uv_python_request`'s form: a bare `X.Y[.Z]` becomes `X.Y[.Z]+gil`;
`3.14t`, paths and explicit variants pass unchanged. Only discovery takes `+gil`:
`uv python install 3.14+gil` fails with `No download found`, so the install step passes the bare
version, which installs the GIL build. Measured in `:latest` on 2026-09-30: legs 3.14t, 3.14, 3.13,
3.15, 3.14t, 3.14 in one container each got the interpreter they named. Test, for both fixes:
`linux/scripts/tests/test-uv-python-request.sh`.

Windows has the same trap and the same cure: `New-UvProjectEnvironment` asks uv for
`Get-UvPythonRequest`'s form. OrchestrANT's 3.14 leg took a free-threaded 3.14.7, which has no wheel
for one of its locked packages (2026-09-30). Test: `windows/scripts/tests/Uv.PythonRequest.Tests.ps1`.

A Windows `3.14t` leg gets the image's interpreter too: a `:winamd64` built after 2026-10-07 ships
`C:\python-freethreaded\python3.14t.exe`, source-built beside the GIL build and last on `PATH`
([`windows-builds.md` § The free-threaded CPython](windows-builds.md#the-free-threaded-cpython)).
`uv venv --python 3.14t` and `uv build --python 3.14t` resolve to it with
`UV_PYTHON_DOWNLOADS=never`. An older image still has uv download one.

**The chain's own twins.** The same `:winamd64` ships `cp3XY-cp3XYt` builds of the chain wheels whose
code declares free-threading (ONNX Runtime, PyAV, apache-tvm-ffi and the two IREE packages) in
`PYTHON_WHEELS_FREE_THREADED` (`C:\runtime\wheels-free-threaded`), apart from the GIL store
([`windows-builds.md` § The free-threaded wheels](windows-builds.md#the-free-threaded-wheels)).
`Sync-UvChainOnnxRuntime` reads that store for a venv whose ABI tag is `cp3XYt`, so a Windows `3.14t`
leg of an ORT project gets the chain ORT like its GIL legs; without the store it fails on the ABI as
before. The arm64 bundle carries the same store with `win_arm64` twins, minus the IREE compiler
([`windows-builds.md` § The arm64 cross twins](windows-builds.md#the-arm64-cross-twins)).

Linux does the same since 2026-10-07: `:latest` names its twin store, `/opt/wheels-free-threaded`, in
`PYTHON_WHEELS_FREE_THREADED` (a name with no version, which Windows reads first as well), and
`uv_reconcile_chain_ort` reads it for a `cp3XYt` venv
([`consumer-image-contract.md` § The free-threaded wheels](consumer-image-contract.md#the-free-threaded-wheels)).
An image without the variable still refuses the leg on the ABI, and the runtime smoke's `FT-STORE`
gate fails it. Test: `linux/scripts/tests/test-uv-chain-ort.sh`.

**uv downloads nothing for a `+gil` request**, so a version the host lacks is installed first.
OmniAccelerANT's 3.12 venv (its CMake format gate) stopped with `No interpreter found for
Python 3.12+gil in managed installations, search path, or registry` (2026-10-01). Like Linux's
`uv_ensure_python_available`, `New-UvProjectEnvironment` now asks `uv python find` first; when
nothing is found it runs `uv python install X.Y`, which installs the GIL build, then creates the
`+gil` venv. Measured in `:winamd64`: 3.12 is installed and its venv is a GIL 3.12.14; 3.14 still
takes the image's own `C:\temp\cpython`, with no download.

`uv build` is a second door into the same trap: it discovers its own interpreter and ignores the
venv, so `Invoke-CiPackaging.ps1` and `ci_packaging.sh` pass it the same `--python X.Y+gil`. Without
that flag, OrchestrANT's only Windows binary wheel was `cp3XY-cp3XYt` (2026-10-01), which the app
bundle's GIL runtime could not install.

The GIL interpreter `uv build` then finds is the image's in-tree build
(`C:\temp\cpython\PCbuild\amd64`). Its `python314.lib` sits beside `python.exe`, not in a `libs\`
directory, the only place setuptools looks: the Cython link failed with `LNK1104: python314.lib`.
The free-threaded download had hidden this, because it is a regular install. So the binaries step
puts the interpreter's directory on `LIB` whenever a `python3*.lib` sits there.

## Two wheels: GIL and free-threaded

A project that declares free-threading support ships two binary wheels: `cp3XY-cp3XY` for the GIL
interpreter and `cp3XY-cp3XYt` for the free-threaded one. The sdist and the pure `py3-none-any`
wheel are built once; they serve both.

**Opting in** is the official trove classifier, in `pyproject.toml`'s `[project]` table:

```toml
classifiers = ["Programming Language :: Python :: Free Threading :: 2 - Beta"]
```

Any level counts (`1 - Unstable`, `2 - Beta`, `3 - Stable`, `4 - Resilient`), and so does the bare
`Programming Language :: Python :: Free Threading`. `Programming Language :: Python
:: 3.14t` is no classifier: PyPI refuses an upload that names it, and the drivers ignore it. The
Cython build must declare the same, with `freethreading_compatible=True` in
`cythonize(compiler_directives=...)` (Cython 3.1+); without it every compiled module re-enables the
GIL when it loads, and the proof below fails.

**What the drivers do.** `ci_packaging.sh` and `Invoke-CiPackaging.ps1` read the classifier with
`linux/scripts/02-toolchain/python/free-threaded-wheel.py declares`. When it is there:

1. **The build.** After the GIL Cython wheel, the same `CYTHONIZE=True` build runs on the
   free-threaded twin of the packaging version (`3.15` gives `3.15t`). The interpreter is the
   image's, found by `uv python find` and never downloaded
   ([`consumer-image-contract.md` § The free-threaded Python](consumer-image-contract.md#the-free-threaded-python)).
   Without one the step fails and says so.
2. **The tag.** The build must leave one `cp3XYt` wheel. On Linux it is auditwheel-repaired like
   the GIL wheel. A pure result is logged and dropped.
3. **The proof.** A fresh venv of the same interpreter installs the shipped wheel without its
   dependencies, and `free-threaded-wheel.py prove` loads every compiled module the distribution
   owns. It creates each module without running its body: that is where CPython decides about the
   GIL, and a missing optional dependency then cannot fail or fake the verdict. A bare `.so` or
   `.pyd` counts as a module only when it exports `PyInit_<name>`, so a library the wheel bundles
   beside its modules is not loaded as one. The step fails when `sys._is_gil_enabled()` is true
   afterwards, and names each module whose `RuntimeWarning` re-enabled it.

The image's own wheels get the same twin and the same proof in the media stage, decided by a table
rather than a classifier
([`consumer-image-contract.md` § The free-threaded wheels](consumer-image-contract.md#the-free-threaded-wheels)).

Without the classifier the drivers build exactly what they built before and log one line:
`free-threaded wheel skipped: the project does not declare support (...)`.

**The override** is `PYTHON_FREE_THREADED_WHEEL` (on Windows also `-FreeThreadedWheel`): `auto`, the
default, follows the classifier, `on` builds without it, `off` skips it, and any other value fails
the run. A caller sets it with the `free-threaded-wheel` input of `python-ci-linux.yml` (passed to
the packaging container) and of `python-ci-windows.yml` (passed to the build container, where
`Invoke-CiPackaging.ps1` reads it).

**The riscv64 cross build skips it** (`PACKAGING_CROSS_TARGET`): it has no free-threaded target
interpreter and logs `free-threaded wheel skipped: the riscv64 cross build has no
free-threaded target interpreter`. The Windows arm64 cross lane builds it, as below.

### The suite on the installed wheel

The proof loads the wheel's modules; it runs none of their code. The X.Yt test leg runs the code,
but from the sources, not the Cython build. A project that wants its tests on the compiled modules
names them once, in `pyproject.toml`, and every lane reads that table (CON122):

```toml
[tool.antfrastructure.free-threaded-wheel-tests]
extra = "test"
copy = ["tests/unit/test_thread_safety.py"]
env = { ORCHESTRANT_REQUIRE_COMPILED = "1" }
isolated = true
pytest-args = ["-W", "error", "tests/unit/test_thread_safety.py"]
```

| Lane | Runs it | Where |
|---|---|---|
| Linux, each arch | `linux/scripts/02-toolchain/python/test-free-threaded-wheel.sh`, from the project's `ci_packaging.sh` wrapper after the hub's | `:latest` |
| Windows x64 | `windows/scripts/python/Invoke-FreeThreadedWheelTests.ps1`, step 4 of the Windows build driver | `:winamd64` |
| Windows arm64 | `wheel-tests-<leg>.cmd`, staged on the X.Yt leg (§ Windows arm64: the staged test job); OrchestrANT's own stage calls `New-FreeThreadedWheelTestStage` | `windows-11-arm` |

- **The table.** `copy` is required: paths, relative to the checkout, staged at the same relative
  path in a temporary directory. `extra` is one extra of the lock, `env` pairs reach pytest only,
  `isolated` adds `python -I`, `pytest-args` go to pytest. `free-threaded-wheel-tests.py table` reads
  it; an unknown key, a path that leaves the checkout, a wrong type or any other table under
  `[tool.antfrastructure]` (a misspelt name) fails the run.
- **What it installs.** A fresh venv of the image's free-threaded interpreter, found and never
  downloaded, gets the lock's set (`uv export --locked --no-emit-project`, with the `extra`), then
  the shipped `cp3XYt` wheel of this arch with `--no-deps`. The device has no uv: the stage's leg
  site already holds the same set and wheel.
- **Where it runs.** In the staged directory, because from the checkout the sources would shadow
  the installed modules. Do not copy the package itself. Leave `isolated` off when the tests import
  siblings by package path (`from tests.helpers import …`), which needs the run directory on
  `sys.path`. The project's pytest config is not copied unless `copy` names it, so pass its warning
  filters in `pytest-args`.
- **The GIL check.** `free-threaded-wheel-tests.py run` runs pytest in-process on the free-threaded
  interpreter and fails when the GIL is on before the tests or after them, even when every test
  passed; pytest's warnings summary then names the module that re-enabled it. Every lane logs
  `free-threaded wheel tests passed: <wheel>` on success.
- **When it skips.** In the three cases in which the packaging driver builds no free-threaded
  wheel: a cross build, `PYTHON_FREE_THREADED_WHEEL=off`, and `auto` without the classifier. Windows
  also skips a project without the table, saying so. A declared project with no `cp3XYt` wheel of
  this arch in `dist/` fails. On Linux, flags (`--copy`, `--extra`, `--env`, `--isolated`, `--`)
  can stand in for the table; both together fail, and so does neither.
- **What a test may not assume there.** A compiled module's `__file__` is its extension, a
  source-stripped wheel has no `.py` for `inspect` or a hash, and Cython's `import` returns a `None`
  in `sys.modules` as the module instead of raising. Fake an absent module with a `sys.meta_path`
  finder that raises `ModuleNotFoundError`.

OrchestrANT runs its thread-safety tests this way, WebDavClient its whole suite. Tests:
`linux/scripts/tests/test-python-free-threaded-wheel-tests.sh`, the real-interpreter `run` cases in
`test-python-free-threaded-wheel.sh`, and `windows/scripts/tests/PythonWheel.Suite.Tests.ps1`.

### The arm64 cross lane's free-threaded wheel

Since 2026-10-12 (CON75) the Windows arm64 cross lane ships `cp314-cp314t-win_arm64`. The
`:winarm64` image carries both halves: the host's x64 `C:\python-freethreaded` runs the build, and
the target tree `C:\runtime\python-freethreaded` (CON74) supplies `python314t.lib`.
`Invoke-CiPackaging.ps1` starts `New-CrossFreeThreadedWheel.ps1` as a child process, so the VS
environment it enters ends with it:

1. **The plan.** The classifier decides, as natively. The step is skipped when the image has no
   target tree.
2. **The environment.** The script enters VS's x64_arm64 environment. A uv venv of the host's 3.14t
   holds `[build-system].requires` as declared. Its `sitecustomize` pins `EXT_SUFFIX` to
   `.cp314t-win_arm64.pyd` (`New-FreeThreadedBuildPython`).
3. **The target, for every `build_ext`.** `DIST_EXTRA_CONFIG` sets `plat_name = win-arm64` and the
   target's `libs\` as `library_dirs` for `build_ext`, and the platform for `bdist_wheel`.
   - A command-line `build_ext -L` reaches only the first instance.
   - OrchestrANT's `CleanBuildPy` wipes `build\lib`, so `bdist_wheel` relinks. With `-L` on the
     command line, that relink took the host's x64 `python314t.lib`.
4. **The build and the gates.** `uv build --wheel --no-build-isolation` runs with that venv. Then the
   static gates check the tags, the imports (`python314t.dll` only) and `Assert-WheelTargetArch`.
5. **The kit.** The wheel goes to `dist\windows-arm64\free-threaded\`, never `dist\`, because
   `Select-PythonAppWheel` refuses a binary wheel of another ABI. Beside it go the target tree as
   `python\`, `free-threaded-wheel.py`, `WindowsPythonWheel.Common.psm1` and
   `Test-FreeThreadedWheel.ps1`.

**The device.** `container-ci-windows.yml`'s arm64 run job starts `Test-FreeThreadedWheel.ps1` from
the downloaded product. It runs `Invoke-TwinDeviceProof`, the bundle gate's own proof:
- the wheel installs offline into a venv of the packed `python3.14t.exe`;
- then `free-threaded-wheel.py prove` runs on it.

A product without the directory logs one line and passes.

**The project's part.** setuptools' own MSVC compiler needs nothing: `plat_name = win-arm64` selects
the ARM64 `cl.exe`. A project that swaps in `clang-cl` must also name the target, because `clang-cl`
otherwise compiles for the host.
- OrchestrANT adds `--target=aarch64-pc-windows-msvc` to its extensions' `extra_compile_args` when
  `VSCMD_ARG_TGT_ARCH` is `arm64`, which VS's cross environment sets.
- In `:winarm64` (`ba6bfaae…`), OrchestrANT 0.0.30's wheel built this way and passed all three gates
  (2026-10-12).
- On `windows-11-arm` it then loaded: OrchestrANT run 38221408508 imported all 64 compiled modules
  on free-threaded 3.14.8 with the GIL disabled (2026-10-12).
- A project that sets the compiler's `cc` to `clang-cl` must `initialize()` the compiler first: the
  first `compile()` initializes lazily and puts `cl.exe` back, so OrchestrANT's and WebDavClient's
  first extension compiled with MSVC's `cl` until 2026-10-12. A `spawn` hook does not catch it,
  because setuptools 84 never calls one.

**The app bundles pick by their runtime's ABI.** `python-app-bundle.sh` and `Select-PythonAppWheel`
take the `cp314` wheel for their GIL runtime. A binary built for another ABI alone is an error, not
a fallback to the pure wheel.

**auditwheel on Linux** is PATH's, else the binary packaging venv's (OrchestrANT's `packaging` extra
installs it there). Until 2026-10-07 only PATH counted, and it never has one, so every Cython wheel
shipped as `linux_<arch>` under a log line calling it pure. With no auditwheel anywhere, a platform
wheel ships unrepaired, with a warning.

Tests: `linux/scripts/tests/test-python-free-threaded-wheel.sh` and
`windows/scripts/tests/PythonWheel.FreeThreaded.Tests.ps1`. Inside `:latest` the Linux suite also
runs `prove` for real: it compiles two C extensions against `/opt/python-freethreaded` (or
`FT_PYTHON`), one declaring `Py_MOD_GIL_NOT_USED` and one not. A host without a free-threaded
interpreter logs a SKIP line for that case.

## Upgrading Python

One line moves every image, lane and default: `PYTHON_VERSION` in
`linux/scripts/01-core/versions.env` (owner rule 2026-10-12: an upgrade must stay that easy).

1. Set `PYTHON_VERSION=X.Y.Z` and run `python3 docs/scripts/bump_versions.py --write --only PYTHON_VERSION`.
   It moves to the newest X.Y patch and writes `PYTHON_TGZ_SHA256` from python.org's tarball.
2. `python3 docs/scripts/sync_versions.py --write` copies the pin into the Dockerfiles' ARG defaults.
3. Rebuild the chain from `compiler`. Its GCC, LLVM and Rust layers stay cached, because the Python
   ARGs sit right above the CPython RUN; every stage after it builds again, and so does every wheel
   the chain builds per Python ABI (ONNX Runtime and its twins, GenAI, IREE, PyAV, tvm-ffi, LiteRT,
   OpenCV's cv2, riscv64's torch).

**What follows without an edit:**

- The images ship the source-built interpreter on every arch, GIL (`/usr/local/bin/pythonX.Y`) and
  free-threaded (`/opt/python-freethreaded`), never the distro's `python3`, so Ubuntu's own Python
  version does not matter. arm64 and riscv64 build what apt used to supply for it (numpy, PyGObject,
  pycairo, contourpy) from sdists.
- `PYTHON_MAJOR_MINOR`, which the image advertises, and the wheel tags `PYTHON_ABI_TAG` and
  `PYTHON_FT_ABI_TAG` (`common.sh`).
- The drivers' defaults. `ci_tests.sh` runs X.Y, plus X.Yt when `pyproject.toml` declares
  free-threading; the packaging, static-analysis, docs, wheel-smoke and wheel-test drivers take X.Y,
  and so do Windows' `Invoke-CiPackaging.ps1`, `Invoke-CiStaticAnalysis.ps1` and
  `New-Arm64PythonTestStage.ps1` (`Get-PinnedPythonVersion`). A consumer that passes no version follows
  the image; one that picks its legs writes `pinned` (`pinned` alone for the GIL leg, `pinnedt` for
  its twin). `ci_build_docs.sh` also publishes the default leg's reports as `pytest-report.html`/`.md`
  and `pytest-report-free-threaded.html`, so a docs page links names without a version.
- The free-threaded store's names carry no version: `/opt/wheels-free-threaded`,
  `PYTHON_WHEELS_FREE_THREADED`, and on Windows `C:\runtime\wheels-free-threaded` under the same
  variable.
- Windows' build side: `Get-PinnedPythonVersion` feeds the free-threaded interpreter's name, the twin
  tag, the arm64 tvm-ffi wheel tags and the target's `pythonXY.lib`; OpenCV's `FindPythonInterp` stub
  asks the interpreter for its version; `Test-Container` grades the pin and fails without one.
- The riscv64 uv cache seed, the app bundle's python-build-standalone, and the hub's own workflows,
  which read X.Y from `versions.env`.
- Renovate reports every new release, a minor included, and its rule names no version.

**What still needs a look:** a consumer's lock needs wheels (or buildable sdists) for the new tag,
since only the image's own wheels come from the chain; PyPI packages whose `requires-python` stops
below the new version (pyhailort says `<3.14`). On Windows, two pin sets stay version-bound:
- the arm64 bundle's three native pytest wheels (`PYTEST_WINDOWS_ARM64_CHARSET_NORMALIZER/COVERAGE/MARKUPSAFE`),
  which `Build.Arm64WheelStack.Tests.ps1` names as soon as `PYTHON_VERSION` moves;
- the arm64 torch stack (`TORCH_WINDOWS_ARM64_*`), cp313 until PyTorch ships newer `win_arm64` wheels.

`ai-edge-litert` has no wheel for a new tag until the chain builds it from source (BACKLOG CON91);
until then the Windows app venvs go without it.

## Which Linux image

**`:latest`, on every architecture.** It is a multi-arch index (`linux/amd64`, `linux/arm64` and
`linux/riscv64`, all children present as of 2026-08-12), so docker resolves the right platform per
runner and no lane spells the tag per arch.

The arch-suffixed tags (`:latest-amd64`, `-arm64`, `-riscv64`) exist, but they are an
implementation detail of the image build: a consumer that names one pins itself to a single
architecture.

> Between 2026-08-04 and 2026-08-12 the index listed **amd64 only**: lanes had to name
> `:latest-cross-arm64` explicitly, or `docker pull` on an arm runner died with "no matching
> manifest for linux/arm64/v8 in the manifest list entries". Such a workaround still in place is
> stale: remove it, do not copy it.

The same index was named `:latest-cross` until 2026-09-22; that name is retired and no release
publishes it. Its registry tags stay until the conditions in
[`AGENTS.md` § Image and tag naming](../AGENTS.md#image-and-tag-naming-published-tags)
are met. Name `:latest`:
[`rancher-desktop-linux-containers.md` § The image: always `:latest`](rancher-desktop-linux-containers.md#the-image-always-latest).
