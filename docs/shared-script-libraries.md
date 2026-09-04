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
checkout (`ExternalLib/Kataglyphis-ContainerHub/linux/scripts/lib/<lib>.sh`), so
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
