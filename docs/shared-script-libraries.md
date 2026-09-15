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

## The tree, as AGENTS.md drew it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for
this heading. AGENTS.md keeps one line per top-level directory; the per-file
detail, the deletion history and the consumer-surface notes are here.

```
linux/scripts/
├── 01-core/             shared utilities (62 as of 2026-09-01 — `ls linux/scripts/01-core/*.sh | wc -l`; the literal said 48 for long enough that README repeated it, so treat any count here as indicative: versions.env, logging, platform, cross-env, cross-gcc, cross-meson, cross-apt, compiler-resolution, tag-naming, stage-defs, digest-pinning, ancestry, build-helpers, cli-parsers, …)
├── 02-toolchain/        GCC, LLVM, Rust, Python, CMake, Vulkan builds
├── 03-media/            media library build scripts
│   ├── core/common.sh   single DRY bootstrap — sourced by every media script
│   ├── build/           per-library build scripts
│   │   ├── onnxruntime/   ONNX Runtime + GenAI (build/ steps, runtime/ pkgconfig, android/)
│   │   ├── litert/        LiteRT + TFLite C API (Critical Fix #2: abseil span.h copy in build-litert.sh)
│   │   ├── opencv/        OpenCV 5.x
│   │   ├── ffmpeg/        FFmpeg (build-ffmpeg.sh has fixed host compiler wrapper)
│   │   ├── gstreamer/     GStreamer monorepo (common/ has patch-gstreamer-sources.sh — Critical Fix #5)
│   │   ├── libcamera/     libcamera
│   │   ├── pyav/          PyAV wheel (`import av`), built in a stage layered on the FFmpeg it links against (Dockerfile.media `FROM ffmpeg AS pyav`); versions.env pinned PYAV_VERSION while nothing built it until 2026-08
│   │   ├── armnn/         Arm NN + Arm Compute Library — arm64 ONLY; other arches get empty /opt/armnn + /opt/acl
│   │   └── iree/          android/ ONLY (dispatched via android-dispatch.sh); the Linux-lane IREE is built by 05-frameworks/torch/build-app-wheelhouse.sh
│   └── runtime/         artifact collection, runtime config, wheel repair, verification, media-env.sh (canonical ENV)
├── 04-runtime/          entrypoint + env scripts (gstreamer-env.sh, etc.)
├── 05-frameworks/       TVM, Torch, Flutter
└── 06-packaging/        assembly + smoke tests (smoke-media.sh, smoke-common.sh)
```

Top-level orchestrators: `build-cross-chain.sh`, `build-cross-compiler.sh`, `build-cross-stage.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`. Verification: `verify-cross-chain.sh`, `verify-critical-fixes.sh`, `verify-artifact-copy-parity.sh`.

Beyond `linux/scripts/`:

```
linux/scripts/lib/       consumer-facing bash libraries: agentic-loop.sh,
                         app-runner.sh (generic app launcher: arg parse, exe
                         discovery, LD_LIBRARY_PATH, per-profile hooks),
                         cmake-build.sh, code-quality.sh, coverage.sh,
                         slang-compile.sh, wasm-opt.sh, ctest-run.sh (ctest
                         runner + perf-baseline comparator), docs-build.sh
                         (Sphinx build helper), rust-toolchain.sh — the last
                         three had NO doc entry anywhere until the 2026-08-08
                         orphan sweep; nothing in-repo invokes lib/, it is a
                         consumer surface shipped into the images
linux/scripts/02-toolchain/rust/   cargo_* helpers (test/bench/fmt+clippy/
                         security/coverage/release/update/doc via
                         _cargo_wrapper.sh) — consumer surface COPY'd into the
                         toolchain/sdk/package images; nothing in-repo calls
                         them (the redundant zero-ref Build-Linux.sh duplicate
                         was deleted 2026-08-08)
linux/scripts/02-toolchain/python/ci_*.sh   Python CI helpers (tests, static
                         analysis, packaging, docs) — same consumer-surface
                         status as rust/
linux/scripts/01-core/setup-host-deps.sh    hand-run host bootstrap (rootless
                         nerdctl/buildkit prerequisites); intentionally not
                         wired into CI or builds
linux/scripts/06-packaging/package_archive.sh   tar/deb/AppImage/Flatpak
                         assembly — consumer surface. Called from
                         OxidANT's
                         .github/workflows/rust_ubuntu26_04.yml release job.
                         Deleted by the 2026-08-08 orphan sweep as
                         "zero-reference" and restored 2026-08-11: the sweep
                         searched only THIS repo, so a consumer's CI lane was
                         broken silently. Grep the consumer repos before
                         deleting anything under lib/, rust/, python/ or
                         06-packaging/.
windows/scripts/         Windows lane, GROUPED since #108 (2026-08-20):
                         build/ (chain components: Build-*FromSource.ps1,
                         Build-*All.ps1 wrappers, Test-Container.ps1,
                         Import-Versions.ps1), host/ (Install-*/Set-*/
                         Repair-*/Reset-* + elevated maintenance),
                         diagnostics/ (Test-*/Get-*/Invoke-*/Measure-* probes
                         + the Invoke-DiagnosticProbe.ps1 runner). A settled
                         one-shot is DELETED, not archived: git history is the
                         record, and the diagnostics/archive/ facility that
                         used to hold them never worked as advertised —
                         `**/archive/` in .dockerignore strips it from every
                         build context, so the -ProbeScript archive/<name>.ps1
                         it promised could not solve. Container mounts
                         stay FLAT (C:\bkmnt, C:\temp\scripts) — the
                         $scriptAssetRoot resolver bridges both layouts and
                         is gated by ScriptAssetRoot.Parity.Tests.
                         Ungrouped residents BY DECISION (#131):
                         Invoke-Lint.ps1, entrypoint.cmd, cargo-retry.cmd
                         (consumer-CI suspect — never delete unverified),
                         certificates/ (MSIX cert generation + WebDAV
                         download_webdav_files.py — see its README.md),
                         python/ + rust/ (consumer CI-lane drivers).
                         modules/*.psm1 (reusable PS modules: SourceBuild,
                         Build.Common, ContainerBuild.Reuse, AgenticLoop,
                         CMake, Config, Formatting, Msix.{Common,Signing},
                         WebDav, Uv, Scripts.Shared, Toolchain, CodeQL,
                         ContainerImage, Flutter, Installer,
                         HostMaintenance, SmokeTest, GstPlugins, …),
                         tests/ (harness + suites), shims/
windows/upstream/        prepared upstream submissions (not build inputs), one
                         directory per submission = format-patch + PR.md. See
                         its README.md for the index, and
                         docs/upstream-windows-patches.md for the graded
                         register of EVERY local third-party change.
                         hcsshim-teardown-timeout/ is the one already FILED
                         (microsoft/hcsshim#2855) and also carries ISSUE.md,
                         the deployed 45min local patch and the rebuild
                         recipe; the other 14 are prepared and UNSENT - do
                         not post without the owner saying so.
shared/agentic-loop/     cross-platform data: prompts/*.md — the single source
                         for the default planner/refactor-planner/executor task
                         prompts read by BOTH WindowsAgenticLoop.Common.psm1
                         and linux/scripts/lib/agentic-loop.sh
.github/actions/         12 composite actions consumers call @main, incl.
                         cleanup-disk-space (Windows runners),
                         run-in-linux-container, run-in-windows-container;
                         full list in .github/actions/README.md
```

`out/`: generated build artifacts (OCI layouts, rootfs exports). Excluded from Docker context via `.dockerignore`.

## Module loading order, as AGENTS.md carried it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), unedited except for this heading and the relative links. The RULES stayed there; this is the reference behind them.

`artifact-common.sh` sources 01-core modules in dependency order:
1. `common.sh` 2. `tag-naming.sh` 3. `stage-defs.sh` 4. `digest-pinning.sh` 5. `chain-verify.sh` 6. `ancestry.sh` 7. `build-helpers.sh` 8. `cross-stage-build.sh` 9. `context-management.sh` 10. `version-forwarding.sh` 11. `cli-parsers.sh` 12. `runtime-build-fns.sh` 13. `compiler-resolution.sh` 14. `parallel-loop.sh` 15. `path-helpers.sh`. `abseil-headers.sh` is
deliberately NOT in this loop (backlog A3, 2026-08-12): it has no host-side
caller, and its in-image consumers load it via `source_module`.

`runtime-flow-common.sh` is sourced by `lib-orchestrator.sh` inside `runtime_flow_preamble()`; `build-runtime-artifacts.sh` and `build-runtime-manifest.sh` reach it by sourcing `lib-orchestrator.sh`.

**Which loader a NEW script should use (the dual-loader rule):** scripts that
also execute INSIDE containers (bind-mounted or COPY'd — base-image, 02-toolchain,
03-media, 06-packaging) load via `modules.sh` / `source_module`, which resolves
both the repo layout and the `/opt/scripts` container layout. Host-only
orchestration (`build-cross-*.sh`, runtime flows) sources `artifact-common.sh`
directly. Do not mix: a container-capable script hard-sourcing repo paths breaks
at `/opt/scripts`. (Known wart: `modules.sh` hardcodes a `../02-toolchain`
search path — a 01-core file encoding stage-2 layout; fold a fix into any
future `modules.sh` touch. The layer order itself is frozen by
`tests/test-layer-order.sh`.)

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
directory further away — and every consumer vendors the whole ANTfrastructure
checkout (`third_party/ANTfrastructure/linux/scripts/lib/<lib>.sh`), so
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

**dartdoc emits TWO page shapes, and a third kind of file.** Some pages carry a
static left sidebar with a bare `<ol>`; the rest carry
`<div id="dartdoc-sidebar-left-content"></div>`, filled at runtime from a
`*-sidebar.html` fragment — measured on one consumer, 1030 of 1459 pages were the
second kind. Those fragments are not documents at all: no `<html`, no `</body>`.
So the renderer skips a page it cannot hang navigation on and skips a fragment it
cannot attach a footer to, rather than aborting the run on the first one, and the
END of the run is where vacuity is caught instead: a run that navigated no page,
or that configured a footer and footered no page, fails. It prints both numbers
(`navigated X/N and footered Y/N`) so "it worked" is a measurement.

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
it answers the same inside a consumer's `third_party/ANTfrastructure` checkout —
which is the case the cwd-relative probe existed for in the first place.

## Consumer entry points that are not libraries

The things below are executables a consumer *runs*, not cores it sources. They
share one rule, and it is the rule the `lint-secrets.sh` and `lint-workflows.sh`
repairs were both about: **the consumer repo root is an explicit argument, never
inferred from `BASH_SOURCE`.** A consumer checks this repo out at
`third_party/ANTfrastructure/`, so a self-derived root resolves to ANTfrastructure and
the tool operates on the wrong tree — reporting green, having looked at nothing.

### Gate aggregation (`01-core/gates.sh`)

`run_gate` / `gate_skip` / `assert_gates`, the shell half of the fleet's
"run every gate, then fail once" idiom (the PowerShell half is
`Invoke-BuildGate` / `Add-BuildGateSkip` / `Assert-BuildGates` in
`WindowsBuild.Common.psm1`).

```bash
source "${CORE_DIR}/gates.sh"
gate_reset "static analysis"
run_gate "ruff check" ruff check --no-fix src
run_gate "ty"         ty check
if has_tool clang-tidy; then
  run_gate  "clang-tidy" clang-tidy src
else
  gate_skip "clang-tidy" "not installed in this image"
fi
assert_gates            # 0 when all passed; 1 naming every failure or skip
```

Every gate RUNS even after an earlier one fails, so one push names every finding
instead of one per round trip. `run_gate` returns 0 for a *failing* gate — that
is deliberate and it is only safe because `assert_gates` re-raises: a `run_gate`
batch with no closing `assert_gates` is suppression, not aggregation. It is
compatible with `set -e` (the command runs inside a `||` list). `assert_gates`
also fails when **no** gate ran, because an aggregator whose list came out empty
reporting success is the failure this mechanism exists to prevent.

#### The third bucket: a gate that could not RUN

A gate can also be neither a pass nor a failure: its tool is not installed. Both
ways of forcing that into the other two buckets are lies — counted as a pass it
is the suppression this file exists to prevent, counted as a failure it is a red
nobody can act on — so `gate_skip <name> [why]` records it as its own thing. The
reason is part of the record on purpose: "skipped" without one reads exactly like
a gate somebody quietly deleted.

| Bucket | Recorded by | Counts as "a gate ran"? | Verdict |
|---|---|---|---|
| pass | `run_gate`, command exits 0 | yes | green |
| failure | `run_gate`, command exits non-zero | yes | red, and named |
| skip | `gate_skip` | **no** | **red, unless `--tolerate-skips`** |

**A skip is RED BY DEFAULT, and that default is the inverse of the first cut.**
The earlier spelling was `assert_gates --fail-on-skip`: tolerance was what you
got for free and strictness was the thing you had to remember, which is exactly
the "allowed to fail" shape the fleet rule forbids. A driver that forgot the flag
reported green over a tool that never ran, and nothing in the tree recorded which
drivers those were. Inverted, tolerance is an explicit `--tolerate-skips` at a
call site, so one `grep -rn -- --tolerate-skips` enumerates every place in the
fleet where a missing tool is currently allowed to pass and the audit is finite.
`assert_gates` returns **2** for any other argument, so a stale `--fail-on-skip`
is a caller bug rather than a silently re-armed default.

A skip does not count towards `_GATE_RAN`, so **a batch of nothing but skips is
red even with `--tolerate-skips`**: nothing was graded, so there is no result to
tolerate. That is the no-gate-ran rule above, and it outranks the flag — as does
a real failure sharing the batch.

#### `run_gate` runs its command in a SUBSHELL

`( "$@" )`, not a bare `"$@"`. Upstream check helpers report failure with `err()`
(`01-core/logging.sh`), which ends in `exit 1`. Called directly that `exit`
unwinds the *driver*, not just the gate: the findings already recorded are lost,
the gates after it never run, and the batch never reaches `assert_gates` — "stop
at the first failure" arriving through the back door, in the one file whose whole
job is to prevent it. `||` does not catch `exit`; only a subshell does. The cost
is that a gate can no longer export state back to the driver, which no caller
wanted. `linux/scripts/tests/test-lint-gates.sh` grades this by running one
driver against the shipped file and against a copy with the subshell removed: the
copy has to die mid-batch, or the shipped file passing proves nothing.

#### Windows parity, and the one place the halves differ

The third bucket is mirrored exactly — `Add-BuildGateSkip -Context -Name
[-Reason]` and `Assert-BuildGates [-TolerateSkips]`, where a `[switch]` is false
unless passed, so the inverted default is the same fact on both halves.

The subshell is **not** mirrored, and that was measured rather than assumed:
`exit` inside a gate scriptblock terminates the whole PowerShell driver through
both `& $Script` and `$Script.Invoke()`, and the only containment left is a child
runspace, which breaks the closures a gate scriptblock is written with. The
hazard also does not arise there for the reason it does in bash.
`Invoke-BuildGate`'s contract is that a gate fails by *throwing*, or by a
non-zero exit propagated through `Invoke-BuildExternal`, and its `try`/`catch`
already contains both; PowerShell has no equivalent of the fleet-wide `err()`
helper that makes `exit` the normal way to report a failure.
`windows/scripts/tests/BuildGates.ThirdBucket.Tests.ps1` pins both halves of that
paragraph, the child-`pwsh` measurement included, so the day PowerShell contains
an `exit` this section goes red instead of quietly aging into a false claim.

### Tool presence (`01-core/tool-checks.sh`)

`has_tool <cmd>` and `require_tools <cmd>...`, the latter naming *every* missing
tool rather than the first. Each is defined only when the caller has not already
defined it, so a project `common.sh` still wins — that conditional shape is what
the inline fallbacks in `lib/code-quality.sh` and `lib/coverage.sh` were, and
those two now source this instead of carrying a copy each.

### Python interpreter probe (`01-core/python-probe.sh`)

`preflight_python_require <caller>` returns 0 with `PREFLIGHT_PYTHON` exported
when that value (or, unset, `python3`) runs `-c pass`, and 1 naming the caller
and the knob otherwise. Plain `python3` is not trusted because on Windows Git
Bash it is the Microsoft Store stub, which prints an install hint and exits
non-zero. `preflight.sh` probes a candidate list and exports the winner; a gate
run standalone inherits nothing, so `lint-workflows.sh` and `run-lint-gates.sh`
call this before their Python steps instead of each carrying the check inline,
which is where the second copy sat until 2026-09-14. Expand the value unquoted,
as `preflight.sh` does: it may be a command line such as
`uv run --no-project python`, the very hint the failure message gives.

### `run-in-ci-image.sh` — run a command in the CI image

```bash
bash third_party/ANTfrastructure/linux/scripts/run-in-ci-image.sh . -- bash scripts/linux/build.sh
```

`<repo-root> [--engine docker|nerdctl] [--platform ...] [--workdir ...]
[--mount-hub-scripts] [--name N] [--keep] -- <command...>`.

Every consumer README, every "reproducing CI locally" section and half the agent
prompts carried the same hand-typed `docker run`, and they had all drifted: a
different tag, a forgotten `MSYS_NO_PATHCONV`, a mount at a different path, no
`safe.directory`. This is that line once. The image comes from
`ci-image-ref.sh`, the root is mounted at `/workspace` and registered as a git
safe.directory before the command runs (without it every `git ls-files` inside
fails as "dubious ownership", which breaks a format gate long before anything
builds), and the engine defaults to `nerdctl` when present, else `docker` — the
local box runs Rancher Desktop and CI runs docker, and neither should have to
say so.

`MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'` are exported by the script rather
than documented for the reader: from Git Bash, MSYS rewrites anything that looks
like a POSIX path into a Windows one, destroys every `-v`/`-w` argument, and
fails with "expected an absolute path". A note nobody reads is how that keeps
being rediscovered.

CI workflow steps keep using the `run-in-linux-container` composite action; this
is for everything that is not a workflow step.

### `ci-image-ref.sh` — the family CI image reference

Prints `${IMAGE_REGISTRY_PREFIX}:${CI_IMAGE_LINUX_TAG}` (or `…_WINDOWS_TAG` with
`--windows`) on stdout and nothing else, so it is safe in a command substitution.

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace \
  "$(third_party/ANTfrastructure/linux/scripts/ci-image-ref.sh)" <cmd>
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

### The empty-scope rule

`_lint_gates_scope` builds a gate's file list from `git ls-files` under the graded
root, minus the excluded top-level directories. Its third argument decides what an
**empty** result means, and the two callers genuinely differ:

| Mode | Meaning | Who uses it |
|---|---|---|
| `refuse-empty` (default) | a BROKEN SCOPE. `lint-shell.sh` with zero file arguments falls back to ANTfrastructure's OWN tree and passes, so green over nothing is a lie. | the shell gate |
| `allow-empty` | a FACT about the repo. | the python gate |

The python gate can allow it because it passes **explicit absolute paths**: with no
paths there is no argument list to fall back from, so there is nothing to run and
nothing to mis-grade. That distinction is not cosmetic — ANThology is a pure Dart
package and OxidANT a Rust crate, neither has a single `.py`, and refusing an empty
Python scope made both lanes exit 1 on every push for a reason nothing in either tree
could change. A permanently red lane is a tolerated failure by construction.

### `run-lint-gates.sh` — six gates over a consumer tree, plus the opt-in ratchets

```bash
bash third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh "$PWD"
bash third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh "$PWD" --exclude vendor
```

shellcheck, actionlint (+ the CI image-ref check), gitleaks, ruff (error tier),
the shared-config drift check and the consumer pin-forwarding check, in one
command, every gate running even after one fails. Three consumers had grown their own copy
— two of them as `run:` blocks inside a workflow, so the gate blocking their
deploy could not be reproduced locally at all.

What the copies carried and this keeps: the `git ls-files` scope (a `**/*.sh`
glob does not recurse without `globstar`, so it graded the directories somebody
remembered), the empty-list guards (`lint-shell.sh` with zero file arguments
falls back to **ANTfrastructure's own** tree and exits 0), and the gitleaks
self-test — a clean-tree positive control plus a planted-PAT canary matched **by
path**, which is what tells "the gate ran and found nothing" from "the gate never
started" and proves the scan root was honoured.

`--exclude <dir>` (default `third_party`) drops a vendored top-level directory
from every scope while KEEPING the tracked plain files directly inside it: those
are the consumer's own, and dropping the whole prefix excluded them silently.

The pin *preconditions* the copies carried ("does the pinned `lint-secrets.sh`
understand a scan root yet?") are gone by construction: this script ships in the
same commit as the gates it calls.

**`--ratchets`** (opt-in, 2026-09-14) adds the eight measurement gates that take
`--root` — `verify_code_size`, `verify_code_complexity`, `verify_dead_functions`,
`verify_comment_size`, `verify_stdout_returns`, `verify_masked_assignments`,
`verify_trailing_conditional` and `verify_shellcheck_warnings` — over the
consumer tree, exactly as [the scan-root contract](code-quality-tooling.md#the-scan-root-contract)
describes: the freeze files are read from `<consumer-root>/<gate>.allow`
(`function-size.allow`, `file-size.allow`, `code-complexity.allow`,
`dead-functions.allow`, `comment-size.allow`, `masked-assignments.allow`,
`trailing-conditional.allow`, `shellcheck-warnings.allow`; `verify_stdout_returns`
has none). It is opt-in because a tree with no freeze files is red on its first
run — that first report is what seeds them. Seed, commit, then keep the flag on
in the wrapper and the workflow.

The step also runs **`docs/scripts/verify_doc_links.py --root`** (2026-09-15),
which is the ninth gate and the odd one out: it has no freeze file, so there is
nothing to seed and it is safe the very first time the flag goes on. It grades
every tracked Markdown page in the consumer — which is what puts a consumer's
own `README.md` into the cross-reference graph at all — and it runs even when
the tree carries no shell, because a Dart or Python repo still has pages.

A consumer with **no tracked shell at all** — a pure Dart or Python repo — may
still pass the flag: the step asks `gate_scope.assert_non_empty` once with
`on_empty="allow"`, prints `ratchets: no tracked *.sh outside third_party under
<root> - nothing to grade.` and returns green. That decision belongs to the
aggregator, not to the gates: rule 2 of the scan-root contract says an empty scan
is a decision and never a default, and *who pointed the gate at this tree* is the
only thing that knows which answer is right. Pointed at a tree by hand, a gate
still refuses. A root that is not a usable checkout fails the step outright, with
`gate_scope`'s own message.

The Python gates run under `PREFLIGHT_PYTHON` when it is set (the same contract
`preflight.sh` and `lint-workflows.sh` document) and probe the interpreter first:
on a Windows host plain `python3` is the Microsoft Store stub, and the probe
names the fix instead of letting a gate die inside its Python step.

### `05-frameworks/flutter/setup-sqlite3-wasm.sh`

Fetches the pinned `sqlite3.wasm` into `<consumer-root>/web/`, SHA256-verified
through `download_verified_file`. Two consumers had copied the same unverified
`curl` and had already drifted to different versions; the version and its digest
now live in `01-core/versions.env` (`SQLITE3_WASM_VERSION` /
`SQLITE3_WASM_SHA256`). There is deliberately no version argument — the pin is
the point.

### `05-frameworks/flutter/lane-prologue.sh`

`flutter_lane_prepare_env [flutter_dir]` is the Flutter twin of
`cmake-build.sh`'s `cmake_build_prepare_env`, and exists for the same reason:
two consumers had each grown their own prologue, they had drifted, and the
differences were all work the IMAGE already does.

It asserts `${FLUTTER_DIR:-/opt/flutter}/bin/flutter`, puts its `bin/` on `PATH`
once, registers a git `safe.directory` for **the repo root only**, defaults
`PUB_CACHE` to `<repo>/.pub-cache`, and prints `flutter --version` — the tag is
unpinned, so the version is a measurement rather than a constant.

Three things it does not do, and must not gain: a `safe.directory` for the SDK
(`setup-package-image.sh:556` registers `/opt/flutter` at `--system` level, so a
`--global` copy is a no-op that reads like a requirement), sourcing `~/.bashrc`
to find flutter (`Dockerfile.package:268` already puts it on `PATH`, and a stock
non-interactive `.bashrc` returns early with a meaningless status while hiding a
broken rc file), and installing an SDK — a lane that installs one is testing a
different toolchain from the one it ships.

`flutter_build_web [--wasm] [--no-tree-shake-icons] [args...]` is the optional
second half: `flutter build web --release` with the two flags every consumer
passes named rather than re-spelled, everything else forwarded untouched.

### `01-core/webdav-download.sh`

`webdav_download_tree <remote> <local> [extension|all]` pulls a WebDAV tree into
a directory. Credentials come from `WEBDAV_HOSTNAME` / `WEBDAV_USERNAME` /
`WEBDAV_PASSWORD` and are never arguments — a password on a command line is in
every `ps` listing and in every CI log line that echoes the command.

It installs the client at `WEBDAVCLIENT_REF` from
[`01-core/versions.env`](../linux/scripts/01-core/versions.env), which is the
point of the pin: the PowerShell twin (`WindowsWebDav.Common.psm1`) installs the
same ref, so "which WebDavClient did this run use" has one answer instead of
"whatever the default branch was that day". The `--python` in the install is
load-bearing — the image bakes a root-owned `/opt/venv` and exports `UV_PYTHON`
at it, so a plain `uv pip install` inside an activated `.venv` still targets
`/opt/venv` and dies with "Permission denied (os error 13)" as the uid-1001
build user.

The script it runs is `01-core/download-webdav-files.py`. With no `--extension`
(or `all`) it hands the whole walk to the client's own
`download_all_files_iterative`; a 140-line hand-rolled traversal used to live in
its place, with its own URL joining, sub-path sanitising and streaming download,
each a second implementation of something the client already did. The
extension-filtered path stays for the early `.pfx` certificate fetch, which
genuinely wants one file type out of a shared folder. A one-line shim remains at
`windows/scripts/certificates/download_webdav_files.py`, because the PowerShell
module resolves that path relative to itself.

### `01-core/http-readiness.sh`

`wait_for_http <url> <who> [attempts] [sleep]` polls until an endpoint answers.
Three consumers had written this loop and every difference between them was an
accident — attempt count, sleep length, and the one that matters: whether
failure kills the caller. It **returns** non-zero rather than exiting, because
the nginx caller has to dump `docker logs` before it dies and a helper that
calls `exit` takes that away. Probes that fail while the server is still
starting are the expected case and stay silent; only the verdict is printed, and
it names `who` — a bare URL never told anyone which server failed to come up.
Defaults are 50 attempts at 0.2s, the ten seconds the consumers converged on.
