<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Shared script libraries (`linux/scripts/lib/`)

Sourceable, **project-agnostic** cores. Nothing about a specific project is
hard-coded in any of them. The contract is always the same:

1. A thin wrapper script sets that library's `*_DEFAULT_*` / `*_*` variables —
   its project defaults.
2. It optionally declares hook functions.
3. It sources the library and calls the library's `*_main`.

None of them set `-e`/`-u`/`-o pipefail`: sourcing must not change the caller's
shell options, and wrappers are expected to run under `set -euo pipefail`
themselves. Anything the wrapper does not provide is discovered from the
environment — logging from `01-core/logging.sh` (or minimal fallbacks), job
computation from `01-core/parallelism.sh`, tool presence and the Vulkan
environment from the caller's own `has_tool`/`require_tools`/`source_vulkan_env`
when it declares them.

Two libraries in this directory have their own pages, because their topic is
bigger than the library: [`code-quality.sh`](code-quality-tooling.md) and
[`slang-compile.sh`](slang-shader-compilation.md).

## What holds the standalone contract

Two suites, and they split the work. `tests/test-lib-smoke.sh` is the cheap half
over every `lib/*.sh`: the module parses (`bash -n`), it sources cleanly under
`set -euo pipefail` — a strict-mode consumer must not be killed by an unbound
variable or a failing top-level command — and sourcing it defines at least one
function, counted as a delta inside one shell so functions exported into the
test environment cannot fake the number. A module that exports nothing is a
gutted or early-returning copy, not a library. It also parses
`cmake_build_parse_args` in isolation. No network, no cmake run.

`tests/test-lib-modules.sh` is the strict half described under
[The logging bootstrap](#the-logging-bootstrap): double-source safety, and that
`info`/`warn`/`err` arrive from the real `01-core/logging.sh` rather than a
private fallback copy. It skips `agentic-loop.sh`, which is an executable loop
rather than a source-library.

## The logging bootstrap

`log-bootstrap.sh` is the one owner of the block every other library needs
before it can say anything: resolve `../01-core/logging.sh` if the caller has
not already defined `info`, and otherwise define the minimal `info`/`warn`/`err`
that let the library run standalone. Each library sources it on the line after
its own re-source guard; only `cmake-build.sh` and `wasm-opt.sh` keep a
`_*_CORE_DIR` of their own, because they reach into `01-core` for
`parallelism.sh`, `load-versions-env.sh` and `downloads.sh` as well.

It is a separate file, and not an idiom pasted into each library, because nine
hand-kept copies **had already drifted twice, and both drifts were defects**
(complexity audit F-A): `app-runner.sh` carried no re-source guard and never
attempted the real `01-core/logging.sh`, so standalone consumers silently got
the minimal fallbacks — no `log`, no `die`, different formatting — forever;
`rust-toolchain.sh` had no guard either and defined no `err`, so an `err` call
would have inherited whatever the caller happened to have, or exploded. No
duplication gate could catch that: at nine owners every shingle of the block
lands in `verify_code_dupes`' `suppressed as idiom at >6 owners` bucket
(`MAX_OWNERS = 6`), which is why the copies were free to rot.

Sourcing a sibling to get logging is not the bootstrap paradox it looks like.
The block it replaced already sourced a file — `../01-core/logging.sh`, one
directory further away — and every consumer vendors the whole ContainerHub
checkout (`third_party/ContainerHub/linux/scripts/lib/<lib>.sh`), so
a missing file **next to** the library it serves is a broken checkout, not a
supported state. `tests/test-lib-modules.sh` holds that line: every `lib/*.sh`
must source cleanly standalone, define `info`/`warn`/`err`, survive a double
source, and end up with the *real* logging module rather than the fallbacks.

## `cmake-build.sh` — configure + build a CMake project in a container

| Variable | Meaning | Default |
|---|---|---|
| `CMAKE_BUILD_DEFAULT_PRESET` | CMake preset name | — |
| `CMAKE_BUILD_DEFAULT_BUILD_DIR` | build directory | `build` |
| `CMAKE_BUILD_DEFAULT_CLEAN_BUILD_DIR` | `true` to `rm -rf` the build dir first | `false` |
| `CMAKE_BUILD_DEFAULT_SKIP_CONFIGURE` | `true` to build without configuring | `false` |
| `CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT` | `setup-env.sh` sourced when it exists | — |
| `CMAKE_BUILD_DEFAULT_MB_PER_JOB` | peak RAM per compile job | `4000` |
| `CMAKE_BUILD_DEFAULT_ALLOW_PREBUILD_FAILURE` | `true` makes a failing pre-build hook non-fatal | `false` |
| `CMAKE_BUILD_SAFE_DIRECTORY` | path registered as a git `safe.directory`; empty disables | `/workspace` |
| `CMAKE_BUILD_PREBUILD_LABEL` | label logged around the pre-build hook | — |
| `CMAKE_BUILD_USAGE_INTRO` | one-line description shown in `--help` | — |

**Vulkan selection — `_cmake_build_resolve_vulkan`.** Three sources can name a
Vulkan SDK, and they are resolved in one place: an explicit `--vulkan-version` /
`--vulkan-setup-script` / `--vulkan-sdk` flag overwrites whatever the image
exported, and `CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT` is consulted last — only
when nothing else set `VULKAN_SETUP_SCRIPT` **and** the file it names exists.
That `-f` test is the load-bearing half: `cmake_build_prepare_env` sources
`VULKAN_SETUP_SCRIPT` unconditionally once it is set, so adopting a default that
is not on disk turns a missing SDK into a sourcing error much later.
`tests/test-lib-smoke.sh` pins all four cases.

**Hook — `cmake_build_prebuild_hook`.** Called only when the wrapper declares it.
Runs after configure, immediately before `cmake --build`; use it for code or
asset generation the build or the runtime depends on (shader precompilation,
codegen). **A non-zero return is fatal by default** — see `cmake_build_run()`
for why.

## `ctest-run.sh` — run a CMake project's test suite in a container

The twin of `cmake-build.sh` for the test phase, and **deliberately a separate
library** rather than another entry point inside it: CI configures and builds
once, then runs ctest several times over different build trees (plain, ASan,
TSan…). Sourcing the build driver for that would drag in its cargo/ccache/sccache
writability fallbacks and its pre-build hook machinery, none of which a ctest run
uses.

| Variable | Meaning | Default |
|---|---|---|
| `CTEST_RUN_DEFAULT_BUILD_DIR` | build tree to `cd` into; empty means "stay here" | `build` |
| `CTEST_RUN_DEFAULT_BUILD_TYPE` | value for `ctest -C` | `Debug` |
| `CTEST_RUN_DEFAULT_EXCLUDE` | default `ctest -E` regex | none |
| `CTEST_RUN_DEFAULT_ARGS` | ctest flags when the caller does not override them | maximally loud on purpose — a container test run is only debuggable through its log |
| `CTEST_RUN_SAFE_DIRECTORY` | git `safe.directory`; empty disables | `/workspace` |
| `CTEST_RUN_USAGE_INTRO` | one-line description shown in `--help` | — |

A GPU test suite needs the loader and the layers on the same terms the build had,
which is why the Vulkan environment is resolved here too.

## `docs-build.sh` — build a Sphinx documentation tree

Every project in this family builds its docs the same way: get a virtualenv with
the docs requirements, pull whatever the C++/Doxygen side generated into
`_static`, optionally run a diagram generator, then `make html` and
`make linkcheck` with warnings promoted to errors.

**Not** `02-toolchain/python/ci_build_docs.sh`, which is the docs step for
pure-Python repositories (`uv_sync_project` over a `pyproject`, pytest/coverage
report staging, no linkcheck). This one is for projects whose docs sit next to a
C++/Rust build.

| Variable | Meaning | Default |
|---|---|---|
| `DOCS_BUILD_PROJECT_ROOT` | project root | cwd |
| `DOCS_BUILD_DOCS_DIR` | directory holding the Sphinx Makefile | `<root>/docs` |
| `DOCS_BUILD_SOURCE_DIR` | Sphinx source dir | `<docs>/source` |
| `DOCS_BUILD_STATIC_DIR` | static asset dir | `<source>/_static` |
| `DOCS_BUILD_VENV_DIR` | virtualenv to activate | `<root>/.venv` |
| `DOCS_BUILD_UV_VENV_CREATE_SCRIPT` | script that creates the venv | — |
| `DOCS_BUILD_UV_INSTALL_REQUIREMENTS_SCRIPT` | script that installs its requirements | — |
| `DOCS_BUILD_SVG_SOURCE_DIR` | directory whose `*.svg` are copied into the static dir before the build; empty skips | — |
| `DOCS_BUILD_GENERATOR_SCRIPT` | Python script run with the source dir as cwd before Sphinx; empty skips | — |
| `DOCS_BUILD_PYTHON` | interpreter for that script | `python` |
| `DOCS_BUILD_SPHINXOPTS` | `SPHINXOPTS` for every target | `-W --keep-going` — warnings are errors, but the build reports all of them |
| `DOCS_BUILD_TARGETS` | array of make targets | `html linkcheck` |

Both `UV_*` scripts run with the project root as cwd — the same contract as
`code-quality.sh`'s pair, and both defer to `01-core/python_uv.sh`.

**A missing SVG is fatal on purpose.** An empty diagram set means the generating
build did not run, and shipping docs with holes in them is worse than failing
here.

## `dartdoc-build.sh` — theme and enrich a `dart doc` site

The Dart/Flutter counterpart of `docs-build.sh`. `dart doc` has no theme and no
navigation hook, so the library works the only two seams it leaves: the
generated `doc/api/static-assets/styles.css`, and the emitted HTML.

**The theme sheet is generated, never hand-written.** `DARTDOC_BUILD_THEME_CSS`
points at `style/dartdoc.css`, which DocumANTation's `style/generate_style.py`
renders from `style/brand.json` — the same single source of truth the LaTeX,
Pandoc and Sphinx consumers read. That file exists because the hand-written
predecessor had drifted onto a Tailwind slate/sky palette (`#0284c7` links,
`#22c55e` hover) while the brand's link colour was `#0e7490`, so one site in the
family rendered a different brand from every other. Its two marker lines are
load-bearing: `dartdoc_build_apply_theme` truncates a previous append at the
first line, so rebuilding cannot stack copies of the sheet.

`dartdoc-guides.py` next to it renders the configured Markdown into dartdoc's
own `index.html` shell, so a guide page carries the same header, sidebars and
theme as an API page, and rewrites every relative `*.md` link onto the guide
page rendered from that file.

| Variable | Meaning | Default |
|---|---|---|
| `DARTDOC_BUILD_PROJECT_ROOT` | project root | cwd |
| `DARTDOC_BUILD_DOC_ROOT` | directory `dart doc` writes into | `<root>/doc` |
| `DARTDOC_BUILD_CLEAN_CMD` | array run before generation; unset skips | — |
| `DARTDOC_BUILD_DOC_CMD` | array that generates the site | `dart doc` |
| `DARTDOC_BUILD_THEME_CSS` | generated brand sheet appended to dartdoc's stylesheet | — (required) |
| `DARTDOC_BUILD_IMAGES_DIR` | directory copied to `doc/api/images`; empty skips | — |
| `DARTDOC_BUILD_GUIDES` | array of `<source markdown>\|<slug>\|<nav title>` | — |
| `DARTDOC_BUILD_FOOTER_LINKS` | array of `<label>\|<url>` for the page footer | — |
| `DARTDOC_BUILD_FOOTER_TITLE` | bold name in front of those links | — |
| `DARTDOC_BUILD_TITLE_SUFFIX` | appended to each guide page's `<title>` | — |
| `DARTDOC_BUILD_VENV_DIR` | venv for the renderer | `${TMPDIR:-/tmp}/kataglyphis-dartdoc-venv` |
| `DARTDOC_BUILD_REQUIREMENTS` | its requirements file | `lib/dartdoc-guides.requirements.txt` |
| `DARTDOC_BUILD_PYTHON` | interpreter for the renderer | the venv's, created on demand |

**A configured input that is missing is fatal.** An absent
`DARTDOC_BUILD_IMAGES_DIR`, guide source or theme sheet fails the build instead
of being skipped: a docs site quietly missing its theme and half its pages is
worse than a build that stops and says so. The same rule governs the CI
ownership fix — the container writes `doc/` as root over a bind mount, and a
`chown` that fails leaves a tree the host user cannot rebuild.

## The rustdoc theme sheet

`02-toolchain/rust/cargo_build_doc.sh` styles `cargo doc` output with the same
generated brand sheet the Sphinx and dartdoc builds use: DocumANTation's
`style/generate_style.py` renders it from `style/brand.json` and ships it inside
the `sphinx_kataglyphis` package.

It did not always find it. Both probes that stood in that script named a hub path
that resolves to nothing — the hub's own `docs/_static/css/custom.css` was dropped
in `28425115` (2026-07-15) as a stale fork of that very sheet, and the fallback
pointed one level short, at `linux/docs/_static/`, which has never existed in this
repository. The block therefore produced an empty `EXT_CSS` on every run and
rustdoc got no theme at all, silently.

The path is now resolved from `SCRIPT_DIR` rather than the working directory, so
it answers the same inside a consumer's `third_party/ContainerHub` checkout —
which is the case the cwd-relative probe existed for in the first place.

## Consumer entry points that are not libraries

Three things below are executables a consumer *runs*, not cores it sources. They
share one rule, and it is the rule the `lint-secrets.sh` and `lint-workflows.sh`
repairs were both about: **the consumer repo root is an explicit argument, never
inferred from `BASH_SOURCE`.** A consumer checks this repo out at
`third_party/ContainerHub/`, so a self-derived root resolves to ContainerHub and
the tool operates on the wrong tree — reporting green, having looked at nothing.

### Gate aggregation (`01-core/gates.sh`)

`run_gate` / `assert_gates`, the shell half of the fleet's
"run every gate, then fail once" idiom (the PowerShell half is
`Invoke-BuildGate` / `Assert-BuildGates` in `WindowsBuild.Common.psm1`).

```bash
source "${CORE_DIR}/gates.sh"
gate_reset "static analysis"
run_gate "ruff check" ruff check --no-fix src
run_gate "ty"         ty check
assert_gates            # 0 when all passed; 1 naming every failure
```

Every gate RUNS even after an earlier one fails, so one push names every finding
instead of one per round trip. `run_gate` returns 0 for a *failing* gate — that
is deliberate and it is only safe because `assert_gates` re-raises: a `run_gate`
batch with no closing `assert_gates` is suppression, not aggregation. It is
compatible with `set -e` (the command runs inside a `||` list). `assert_gates`
also fails when **no** gate ran, because an aggregator whose list came out empty
reporting success is the failure this mechanism exists to prevent.

### Tool presence (`01-core/tool-checks.sh`)

`has_tool <cmd>` and `require_tools <cmd>...`, the latter naming *every* missing
tool rather than the first. Each is defined only when the caller has not already
defined it, so a project `common.sh` still wins — that conditional shape is what
the inline fallbacks in `lib/code-quality.sh` and `lib/coverage.sh` were, and
those two now source this instead of carrying a copy each.

### `ci-image-ref.sh` — the family CI image reference

Prints `${IMAGE_REGISTRY_PREFIX}:${CI_IMAGE_LINUX_TAG}` (or `…_WINDOWS_TAG` with
`--windows`) on stdout and nothing else, so it is safe in a command substitution.

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace \
  "$(third_party/ContainerHub/linux/scripts/ci-image-ref.sh)" <cmd>
```

Workflow steps do **not** need it: the four container composite actions carry the
same value as their `image:` input default. It is for the callers that cannot omit
an input because they are not calling an action — a raw `docker run`, a local
repro, a lane driver. It is the one entry point here that takes **no** consumer
root, because the only file it reads is this repo's `versions.env` whatever tree
is being built; a root parameter would imply a per-consumer answer and there is
none. Its PowerShell twin is `Get-CiImageReference`
(`WindowsContainerImage.Common.psm1`) and
`tests/test-ci-image-ref.sh` asserts that both agree with
`verify_ci_image_refs.py`, which grades the four action defaults.

### `run-lint-gates.sh` — the three lint gates over a consumer tree

```bash
bash third_party/ContainerHub/linux/scripts/run-lint-gates.sh "$PWD"
bash third_party/ContainerHub/linux/scripts/run-lint-gates.sh "$PWD" --exclude vendor
```

shellcheck, actionlint (+ the CI image-ref check) and gitleaks, in one command,
all three running even after one fails. Three consumers had grown their own copy
— two of them as `run:` blocks inside a workflow, so the gate blocking their
deploy could not be reproduced locally at all.

What the copies carried and this keeps: the `git ls-files` scope (a `**/*.sh`
glob does not recurse without `globstar`, so it graded the directories somebody
remembered), the empty-list guards (`lint-shell.sh` with zero file arguments
falls back to **ContainerHub's own** tree and exits 0), and the gitleaks
self-test — a clean-tree positive control plus a planted-PAT canary matched **by
path**, which is what tells "the gate ran and found nothing" from "the gate never
started" and proves the scan root was honoured.

`--exclude <dir>` (default `third_party`) drops a vendored top-level directory
from every scope while KEEPING the tracked plain files directly inside it: those
are the consumer's own, and dropping the whole prefix excluded them silently.

The pin *preconditions* the copies carried ("does the pinned `lint-secrets.sh`
understand a scan root yet?") are gone by construction: this script ships in the
same commit as the gates it calls.

### `05-frameworks/flutter/setup-sqlite3-wasm.sh`

Fetches the pinned `sqlite3.wasm` into `<consumer-root>/web/`, SHA256-verified
through `download_verified_file`. Two consumers had copied the same unverified
`curl` and had already drifted to different versions; the version and its digest
now live in `01-core/versions.env` (`SQLITE3_WASM_VERSION` /
`SQLITE3_WASM_SHA256`). There is deliberately no version argument — the pin is
the point.
