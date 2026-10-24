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

Three have their own pages, because their topic is bigger than the library:
[`code-quality.sh`](code-quality-tooling.md),
[`slang-compile.sh`](slang-shader-compilation.md), and the `agentic-loop.sh` +
`agentic-engines.sh` pair, one executable loop in two files
([`agentic-loop-build-matrix.md`](agentic-loop-build-matrix.md#the-two-bash-files)).

The Slang twins accept additional pinned source roots and import an owner's
WGSL manifest without a copied definition; their caller parameters and ownership
rules are in [`slang-shader-compilation.md`](slang-shader-compilation.md#caller-variables).

## Shared compiler and media probe policies

Smoke ELF inspection calls the canonical `platform.sh` parser. A preloaded parser
keeps precedence; otherwise the existing platform loader runs in a subshell so its
functions and flags do not change the smoke caller. Toolchain copies carry that
platform owner. Compiler validation shares its separate raw `Machine:` query and
case-insensitive comparison, retaining host versus swapped/target failure policy.

GStreamer and OpenCV collect optional target-Python paths in caller-selected order
through `cross-python.sh`. Missing probes preserve existing fields; failed probes
retain partial stdout. Cargo compiler bindings share environment publication in
`cross-env.sh`; callers keep compiler validation, wrapper choice, host variables
and Rust-name policy.

Test fixtures share probe execution, rescued-stage assertions and Renovate apply
and permission lifetimes. They retain independent child cleanup so mutating a
production stop function cannot strand the test's own processes.

## Shared ONNX staging and report fixtures

ONNX Runtime and GenAI append their shared cross-toolchain definitions from the
existing ONNX build library. Python, Rust and test switches remain caller policy,
as do the order and spelling of compiler arguments.

`01-core/elf-strip.sh` also owns filename-based shared-library traversal and batched
advisory actions. Callers supply depth, filename patterns and action arguments;
this operation does not replace the content-based ELF probes in `strip_elf_tree`.
Copied build helpers still carry this existing companion.

Copied-gate fixtures share allow-row creation and gate invocation. Version and
mutation suites reuse the common workspace lifecycle while retaining their distinct
cleanup and input trees. Fixtures continue to execute the actual subject gates.

## Shared cache, dependency and packaging operations

`01-core/compiler-cache-utils.sh` supplies launcher selection and start/health probes
without initializing defaults or starting a server when sourced. Copy it beside
`common.sh`, `compiler-cache.sh` and standalone cache probes. Base-image steps use
narrow companion mounts. Callers retain hook versus direct startup, stream routing,
S3 defaults and failure policy.

`install-deps-preamble.sh` reports staged target Python development readiness;
GStreamer, LiteRT and OpenCV retain their native/cross decisions and version lookup
policy, including an explicitly empty OpenCV version. Media core owns optional
Vulkan toolchain import. GStreamer pre-setup shares pkg-config rendering while
retaining fatal Vulkan and advisory Csound write failures and SDK precedence.

`app_packaging_write_deb_control` renders control metadata for native and Python
packagers. Its optional ninth argument distinguishes an omitted Homepage field from
an explicitly empty one. Caller defaults, multiline descriptions, builder arguments
and failure status remain caller policy.

Linux test fixtures share compilerless CMake projects, source-module invocations,
preflight extraction and disposable workspaces. The workspace loads the test harness;
function extraction uses its existing `t_source_functions`. Harness receipt writers
preserve ordered shell-quoted fields, and worker invocations pass the harness path
explicitly. `t_capture_command` captures merged output and raw failure status for
assertions; it does not turn a failed command into a successful test. These fixtures
exercise stubbed operations and do not prove live cache servers or package builds.

## The tree, as AGENTS.md drew it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), and edited since
only to keep it current. AGENTS.md keeps one line per top-level directory; the
per-file detail, the deletion history and the consumer-surface notes are here.

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
│   │   ├── hailo/         HailoRT + hailortcli + the hailonet element, built in the wrapper image (Dockerfile.torch); riscv64 skips
│   │   └── iree/          android/ ONLY (dispatched via android-dispatch.sh); the Linux-lane IREE is built by 05-frameworks/torch/build-app-wheelhouse.sh
│   └── runtime/         artifact collection, runtime config, wheel repair, verification, media-env.sh (canonical ENV)
├── 04-runtime/          entrypoint + env scripts (gstreamer-env.sh, etc.)
├── 05-frameworks/       TVM, Torch, Flutter
└── 06-packaging/        assembly + smoke tests (smoke-media.sh, smoke-common.sh)
```

Top-level orchestrators: `build-cross-chain.sh`, `build-cross-compiler.sh`, `build-cross-stage.sh`, `build-runtime-manifest.sh`, `build-runtime-artifacts.sh`. Verification: `verify-cross-chain.sh`, `verify-critical-fixes.sh`, `verify-artifact-copy-parity.sh`.

Beyond `linux/scripts/`:

```
linux/scripts/lib/       consumer-facing bash libraries: agentic-loop.sh +
                         agentic-engines.sh (one loop in two files),
                         app-packaging.sh (tar/deb/AppImage/Flatpak),
                         app-runner.sh (generic app launcher: arg parse, exe
                         discovery, LD_LIBRARY_PATH, per-profile hooks),
                         cmake-build.sh, code-quality.sh, coverage.sh,
                         compiler-llvm-tools.sh (a build tree's own LLVM
                         tools, first on PATH), dartdoc-build.sh (+
                         dartdoc-guides.py), linker-select.sh (opt-in
                         KATAGLYPHIS_LINKER=lld|mold), log-bootstrap.sh (the
                         logging block the others source), slang-compile.sh,
                         wasm-opt.sh, ctest-run.sh (ctest runner),
                         docs-build.sh (Sphinx build helper),
                         rust-toolchain.sh — the last three had NO doc entry
                         anywhere until the 2026-08-08 orphan sweep. A
                         consumer surface, reached through the consumer's
                         third_party/ANTfrastructure checkout: no image
                         ships lib/, and in-repo only preflight.sh and
                         05-frameworks/flutter/flutter_checks.sh source it
                         (code-quality.sh)
linux/scripts/02-toolchain/rust/   cargo_* helpers (test/bench/debug/
                         fmt+clippy/security/coverage/release/doc; test,
                         bench and debug run through _cargo_wrapper.sh) —
                         consumer surface COPY'd into the
                         toolchain/sdk/package images; nothing in-repo calls
                         them (the redundant zero-ref Build-Linux.sh duplicate
                         was deleted 2026-08-08)
linux/scripts/02-toolchain/python/ci_*.sh   Python CI helpers (tests, static
                         analysis, packaging, docs) — same consumer-surface
                         status as rust/
linux/scripts/01-core/setup-host-deps.sh    hand-run developer-onboarding
                         helper (host toolchains, compiler caches, analysis
                         and coverage tools); intentionally not wired into CI
                         or builds
linux/scripts/06-packaging/package_archive.sh   tar/deb/AppImage/Flatpak
                         assembly — consumer surface. Called from
                         OxidANT's reusable-linux.yml, which its Linux
                         lanes (linux-x64.yml, linux-arm64.yml) call;
                         rust_ubuntu26_04.yml until the 2026-09-24 rename.
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
                         Also ungrouped: patches/ (the static source-build
                         patches, catalogued in its README.md).
                         modules/*.psm1 (reusable PS modules: SourceBuild,
                         Build.Common, ContainerBuild.Reuse, AgenticLoop,
                         CMake, Config, Formatting, Msix.{Common,Signing},
                         WebDav, Uv, Scripts.Shared, Toolchain, CodeQL,
                         ContainerImage, CrossBundle, Flutter, Installer,
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
                         and linux/scripts/lib/agentic-loop.sh;
                         system-prompts/*.md, the role prompts both halves
                         compose (agentic-engines.sh on Linux); templates/,
                         the consumer config and runner wrappers
.github/actions/         12 composite actions consumers call @develop, incl.
                         cleanup-disk-space (Windows runners),
                         run-in-linux-container, run-in-windows-container;
                         full list in .github/actions/README.md
```

`out/`: generated build artifacts (OCI layouts, rootfs exports). Excluded from Docker context via `.dockerignore`.

## Module loading order, as AGENTS.md carried it

Moved out of `AGENTS.md` on 2026-09-15 (owner decision D10), and edited since only to keep it current. The RULES stayed there; this is the reference behind them.

`artifact-common.sh` sources 01-core modules in dependency order:
1. `common.sh` 2. `tag-naming.sh` 3. `stage-defs.sh` 4. `digest-pinning.sh` 5. `chain-verify.sh` 6. `ancestry.sh` 7. `build-helpers.sh` 8. `cross-stage-build.sh` 9. `context-management.sh` 10. `version-forwarding.sh` 11. `cli-parsers.sh` 12. `runtime-build-fns.sh` 13. `compiler-resolution.sh` 14. `parallel-loop.sh` 15. `path-helpers.sh`. `abseil-headers.sh` is
deliberately NOT in this loop (backlog A3, 2026-08-12): it has no host-side
caller, and its in-image consumers load it via `source_module`.

`runtime-flow-common.sh` is sourced by `lib-orchestrator.sh` inside `runtime_flow_preamble()`; `build-runtime-artifacts.sh` and `build-runtime-manifest.sh` reach it by sourcing `lib-orchestrator.sh`.

Both runtime mains call `runtime_prepare_flow` unconditionally so Bash retains
the existing errexit behavior. It exports `DRY_RUN`, binds `TARGET_ARCHES` by
name, resolves wheel delivery, then validates Hailo and host payloads. Wheel
failures keep their status; validation failures exit 2 and payload validation
stdout stays quiet. Image prefixes and provenance placement remain caller policy.


`lib-runtime-wheels.sh` (`RUNTIME_WHEELS_SOURCE`) is sourced by `lib-orchestrator.sh` at top level, right after `artifact-common.sh`. It sits beside `01-core`, not in it, because `01-core` is in the compiler image's closure and this file is host-only. `append_wrapper_build_args` calls into it only while `RUNTIME_WHEELS_EXPORT_ROOT` is set, which only its own `runtime_wheels_setup` does ([both deliveries](linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries)).

`03-media/build/hailo/hailo-build-lib.sh` is sourced there too, right after it, for one function: `hailo_validate_knobs`, which the chain and both runtime orchestrators call before they build anything. The same file is the Hailo build's own library inside the wrapper image, so it sets no shell options and runs nothing at load, and a change to it re-keys only the wrapper's Hailo RUN ([two switches](hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches)).

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
private fallback copy. It skips the `agentic-*.sh` pair, one executable loop split
over two files rather than a source-library.

`t_capture_stubbed` in the shell test harness owns isolated library calls with
per-case environment overrides, a fresh command log and captured output/status.
The Flatpak and bind-mount ownership suites retain their own stub defaults and
expected results. Both suites pass the same assertions before and after the
extraction; status-swallowing and dropped-environment mutations must fail.

## The logging bootstrap

The bootstrap also owns fallback registration for standalone Abseil, Torch
wheelhouse and payload-copy scripts. A scoped `_LOG_BOOTSTRAP_REGISTRAR_ONLY=1`
source imports only the registrar; it loads no real logger and leaves the
bootstrap guard and caller arguments unchanged. Standalone scripts retain
command lookup, plain prefixes and their selected logger names. Library
fallbacks retain function-only lookup, ANSI prefixes, stderr warnings and fatal
errors. Existing callbacks keep their own status and output policy.

Toolchain and Media carry `lib/log-bootstrap.sh` for the core Abseil module,
including a partial Media rebuild against an older SDK parent. Adjacent Media
core copies share the same pre-RUN source set and permissions.
The isolated package payload COPY carries the same file beside its entry point
and inventory. Keep these companions when copying either closure; missing
companions fail instead of restoring private fallback definitions.


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

## Shared CLI value parsing

`app-runner.sh`, `cmake-build.sh` and `ctest-run.sh` source
`cli-value-options.sh` beside them. Keep that companion when copying these libraries.
One cursor loop assigns value flags from each caller's map; caller callbacks retain
positional handling, repeatable configure arguments, optional skip-configure values
and `--` behavior. A value flag without another argument exits with its diagnostic
instead of repeating an unsuccessful `shift 2`. An explicitly empty argument remains
valid where the caller already accepts it.

`test-cli-value-options.sh` exercises all three real parsers with bounded workers;
it launches no application, CMake build or CTest process. Mutation cases remove the
missing-value guard and retain the delimiter, and both must fail.

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
| `CMAKE_BUILD_DEFAULT_CONFIGURE_ARGS` | bash ARRAY of extra configure-step arguments | empty |
| `CMAKE_BUILD_SAFE_DIRECTORY` | path registered as a git `safe.directory`; empty disables | `/workspace` |
| `CMAKE_BUILD_PREBUILD_LABEL` | label logged around the pre-build hook | — |
| `CMAKE_BUILD_USAGE_INTRO` | one-line description shown in `--help` | — |

An empty positional preset remains in `CMAKE_BUILD_POSITIONAL` and uses the normal
caller default. The value-option table is consulted only for a nonempty argument;
Bash associative arrays reject an empty key.

**Vulkan selection — `_cmake_build_resolve_vulkan`.** Three sources can name a
Vulkan SDK, and they are resolved in one place: an explicit `--vulkan-version` /
`--vulkan-setup-script` / `--vulkan-sdk` flag overwrites whatever the image
exported, and `CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT` is consulted last — only
when nothing else set `VULKAN_SETUP_SCRIPT` **and** the file it names exists.
That `-f` test is the load-bearing half: `cmake_build_prepare_env` sources
`VULKAN_SETUP_SCRIPT` unconditionally once it is set, so adopting a default that
is not on disk turns a missing SDK into a sourcing error much later.
`tests/test-lib-smoke.sh` pins all four cases.

**Extra configure arguments — `--configure-arg`.** Repeatable, and the only way
to put a `-D` on the configure command line. Each occurrence appends one
argument, in order, to `CMAKE_BUILD_CONFIGURE_ARGS`; the list is reset per
`cmake_build_parse_args` call and seeded from `CMAKE_BUILD_DEFAULT_CONFIGURE_ARGS`
(an array, not an environment string — splitting one would break the first `-D`
whose value contains a space, and `--configure-arg '-DCMAKE_CXX_FLAGS=-O2 -g'`
must stay one argument). They reach the **configure** step only, never
`cmake --build`. An empty value is fatal rather than dropped: `cmake ""` fails
with a message about the source directory, nowhere near the caller. Without
this, a wrapper that needed one `-D` had to run `--skip-configure true` and
issue its own `cmake -B … --preset …`, i.e. call three library entry points
where `cmake_build_main` would do.

**Hook — `cmake_build_prebuild_hook`.** Called only when the wrapper declares it.
Runs after configure, immediately before `cmake --build`; use it for code or
asset generation the build or the runtime depends on (shader precompilation,
codegen). **A non-zero return is fatal by default** — see `cmake_build_run()`
for why.

## `app-packaging.sh` — the two flatpak entry points

Every packager in the file obeys three rules. Staging trees are container-native,
never inside the mounted workspace: a bind-mounted host drive refuses chmod/fchmod
for the container uid, so dpkg-deb, appimagetool and flatpak-builder fail there,
and only finished artifacts are copied into `out/`. flatpak-builder's exit code is
reported but never the verdict; `ostree --repo=<repo> refs` decides whether the app
is committed. And nothing prints `Created:` without `app_packaging_assert_artifact`. Two entry
points were added on 2026-09-15 for a consumer that packages a **CMake install
tree** rather than a Flutter bundle; the finish-args block and the CON2 probe
landed on 2026-09-17:

* **`app_packaging_ensure_flatpak_runtime [arch] [runtime] [sdk] [version]`** —
  flathub plus the runtime/SDK pair, for a run that is **not** inside the family
  CI image. Deliberately not `app_packaging_setup_dependencies_for_container`:
  that one assumes the image already ships flatpak, installs missing packages
  through a privilege helper and installs under `dbus-run-session`. This one
  installs nothing with apt and asks first, so a warm dev box is a no-op. User
  installation first, system as the fallback, for the remote and for both refs —
  an unprivileged user cannot write the system installation, and pulling a
  second copy of a ref the machine already has system-wide costs 1-2 GB.
  `app_packaging_setup_dependencies_for_container` now probes **both scopes**
  before installing too (CON2, 2026-09-17): the CI image installs the pair
  system-wide as root while the container runs as uid 1001, so its unconditional
  `--user install` was pulling that second copy on every flatpak-packaging run.
* **`app_packaging_flatpak_finish_args_block`** — the manifest's `finish-args`
  list: the four generated entries (network, the two display sockets, DRI) plus
  whatever `KATAGLYPHIS_FLATPAK_FINISH_ARGS` adds, space-separated. **Appended,
  never replaced** (CON6, 2026-09-17). V4L2 capture needs `--device=all` (there
  is no per-device video grant in flatpak) and a user-chosen model path needs a
  `--filesystem=`; the knob exists because the omission is invisible to every
  gate — the bundle ships, the window opens, and only the camera stays silent.
* **`app_packaging_package_cmake_install_flatpak <build_dir> <out_dir> <app_id>
  <project_name> <version_suffix> [runtime] [sdk] [version] [branch] [arch]`** —
  `cmake --install` into a container-native staging prefix, rename the
  PROJECT-named `.desktop`/`.png`/`.appdata.xml` to the APP ID, write the
  manifest, build, and copy only the finished bundle into `<out_dir>`. `<out_dir>`
  is routinely the build directory on a mounted workspace, which is exactly why
  nothing but the bundle is written there.

`app_packaging_require_flatpak_tools`, which both packagers call first, requires
**three** binaries: `flatpak`, `flatpak-builder` and — since 2026-09-15 —
`ostree`. The verdict above is `ostree refs`, but Debian's and Ubuntu's `flatpak`
package depends on libostree and **not** on the ostree CLI, so a box with the two
obvious tools installed passed the check and then reported `is not in <repo>`
over an export that had succeeded. Each missing tool is reported with what the
packaging step wanted it for, and all of them at once: one `apt-get` installs the
set.

`tests/test-app-packaging-flatpak.sh` pins all of them against stubbed
flatpak/flatpak-builder/ostree/cmake, including the two cases the exit code
cannot see: a non-zero `flatpak-builder` whose app **is** committed still ships,
and a zero exit with an empty repo fails.

## `06-packaging/package_archive.sh` — one binary, four formats

One release binary, a tar always, and by `--package-types` a deb, an AppImage and
a flatpak. The types are comma- or space-separated, in any case. Its consumer is
OxidANT's Linux lane. Until 2026-10-06 it wrote the tar and stopped: its
`create_deb()` was deleted on 2026-08-08 as unreachable, and `--flatpak-manifest`,
`--desktop-file` and `--appdata-file` were checked for existence and then never
read.

After the tar it stages the binary alone, under its package name, in
`${KATAGLYPHIS_PACKAGING_WORKDIR:-/tmp/packaging-work}/bundle`. It hands that tree to
the three bundle packagers above, the ones a Flutter lane calls, through seven
knobs. Unset, each keeps the Flutter default, so a Flutter lane packs what it did
before:

| Knob | Flutter default | `package_archive.sh` sets |
| --- | --- | --- |
| `APP_PACKAGING_BUNDLE_DIR` | `build/linux/<arch>/release/bundle` | the staged tree |
| `APP_PACKAGING_VERSION` | `pubspec.yaml`'s `version:` | `--version`, minus a tag's leading `v` |
| `APP_PACKAGING_DESKTOP_FILE` | a generated entry | `--desktop-file` |
| `APP_PACKAGING_ICON_FILE` | `web/icons/Icon-512.png`, then the fallbacks | `--icon-file` |
| `APP_PACKAGING_OUT_DIR` | `out` | `--archive-dir` |
| `APP_PACKAGING_DEB_DEPENDS` | `libc6, libstdc++6, libgtk-3-0` | `libc6, libgcc-s1`, unless the caller set it |
| `APP_PACKAGING_APP_ID` | `<APP_PACKAGING_APP_ID_PREFIX>.<package>` | `--app-id`, when given |

Three details each format depends on:

- **The desktop entry is the project's own.** `app_packaging_adapt_desktop_file` keeps
  every line but `Exec` and `Icon`, and sets those two right after `[Desktop Entry]` for
  the format: the package name for the deb and the flatpak, `AppRun` for the AppImage.
- **The icon goes where its real size says.** `app_packaging_icon_size` reads `WxH` from
  the PNG header, so a 128×128 logo lands in `hicolor/128x128/apps`. A file that is no
  PNG falls back to `512x512`, the directory every icon used to go to.
- **The flatpak copies `lib/` and `data/` only when they exist.** A Flutter bundle has
  both, a single binary has neither.

`--flatpak-manifest` and `--appdata-file` now stop the run with an error that says
why, instead of being accepted and ignored. The flatpak manifest is generated from
the staged bundle. An unknown package type stops the run before anything is built,
and the three bundle formats need `--arch`.

`tests/test-package-archive.sh` pins the wiring against stubbed packagers. It also
packs one real deb through the real library and checks its contents, Depends and
desktop entry. Measured 2026-10-06 in `:latest`, OxidANT's release `kataglyphis_cli`
(1.9 MB; it links `libc`, `libm` and `libgcc_s`) gave:

- a tar of 885 KB;
- a deb of 732 KB, whose binary runs;
- an AppImage of 1.7 MB, which runs with `APPIMAGE_EXTRACT_AND_RUN=1`;
- a flatpak of 684 KB, which `flatpak install --system --bundle` installs and
  `flatpak run --command=oxidant` runs, with its desktop entry and 128×128 icon
  exported.

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

## `compiler-llvm-tools.sh` — the LLVM tools of the compiler that built a tree

Anything that reads clang's output has to come from the same LLVM. That covers
`llvm-profdata` and `llvm-cov` on a raw profile, and `clang-tidy` on module PCMs. The
images put a source-built clang behind `clang`/`clang++`, while the bare tools on
PATH can be an older distro LLVM, so the pairing fails with "no profile can be
merged" or "uses a newer format that cannot be read". The image after CON11 links
clang's own copies into `/usr/local/bin` (BACKLOG CON15); keep the helper for older
images and for a tree another compiler configured.

- `compiler_llvm_tool <build-dir> <tool>` prints the tool beside the compiler that
  configured the tree (`CMAKE_CXX_COMPILER` in its `CMakeCache.txt`, else `clang++`).
  It asks that compiler's `-print-prog-name`, and fails when the answer is the bare
  name, which is clang's way of saying it has none.
- `use_compiler_llvm_tools <build-dir> <tool>...` puts that directory first on PATH,
  but only when it holds every named tool. A half set would mix two LLVMs in one
  report, so it warns and leaves PATH alone instead. Call it in a subshell when the
  directory holds a tool the caller must not swap, such as `clang-format`.

It came up from AccelerANTgine's `ci-common.sh` once BeschleunigerBallett's coverage
lane hit the same "no profile can be merged" (2026-09-24).
`linux/scripts/tests/test-compiler-llvm-tools.sh` pins it with two fake LLVM
installs.

## `linker-select.sh` — an opt-in linker

`KATAGLYPHIS_LINKER=default|lld|mold` picks the linker for one build. Unset, or
`default`, changes nothing: clang keeps GNU ld 2.46 and x64 Rust keeps rustc's
own rust-lld. `linker_select_env` applies it, and `cmake_build_prepare_env` and the
`cargo_test`/`cargo_bench`/`cargo_debug` wrappers call it. A Flutter lane calls it
itself, after it has set `CC`.

- **C/C++:** it appends `-fuse-ld=<x>` to `LDFLAGS`. CMake folds that into every
  `CMAKE_*_LINKER_FLAGS`, but only at the first configure, so a reused build tree
  keeps its old linker. For mold under clang it also passes
  `-Wl,-plugin,<clang prefix>/lib/LLVMgold.so`. Without it mold stops on LTO bitcode
  archive members ("the -plugin option was not provided"). GCC's collect2 passes its
  own plugin.
- **Rust:** for the host triple only, it sets `CARGO_TARGET_<HOST>_LINKER=$CC` and
  appends `-C link-arg=-fuse-ld=<x>` to `CARGO_TARGET_<HOST>_RUSTFLAGS`. wasm32 and
  the Android targets keep their own linkers. Changing the value recompiles every
  crate, and sccache misses with it.
- **Loud, never a fallback.** An unknown value returns 2. Three things return 1:
  a set `RUSTFLAGS` or `CARGO_ENCODED_RUSTFLAGS` (cargo would take either over the
  per-target flags without a word), a driver that cannot link a one-line probe with
  `-fuse-ld=<x>`, and a mold that cannot be had. `USE_LLD` in `compiler-cache.sh`
  falls back silently; this switch exists to measure, and a fallback would make the
  measurement lie.
- **mold comes from PATH, else the pinned release.** No image ships it yet.
  `linker_select_ensure_mold` downloads the `MOLD_LINUX_*` pin in `tool-pins.env`
  (SHA256 per arch: x86_64, aarch64, riscv64) into a version-keyed cache
  (`LINKER_SELECT_CACHE_DIR`, default `$TMPDIR`). An unpinned architecture fails.

**Which one to pick.** Measured 2026-10-05 in `:latest` on 32 cores, across OxidANT,
AccelerANTgine and the OmniAccelerANT Flutter app, and BeschleunigerBallett on 2026-10-06:

| Build | GNU ld | lld 23 | mold 3.0.0 |
| --- | --- | --- | --- |
| AccelerANTgine Debug (ASan, UBSan), relink all 5 binaries | 1.70 s | 0.35 s | 0.56 s |
| AccelerANTgine release, `libAccelerANTgine.so` (ThinLTO) | 0.97 s | 0.85 s | 0.82 s |
| `flutter build linux --release`, full / touch one TU | 49.3 / 3.9 s | 47.6 / 3.8 s | 49.5 / 4.3 s |
| Rust dev link, `liboxidant.so` (rust-lld default: 0.22 s) | 0.87 s | 0.14 s | 0.33 s |
| BeschleunigerBallett `linux-debug-clang` (ASan, UBSan, coverage), relink `commitTestSuite` (110 MB) | 1.55 s | 0.20 s | 0.32 s |

Linking is about 2% of these builds, so `lld` is the useful value. It is already
in the image, and it is the one real gain on Debug relinks. mold 3.0.0 links
correctly, with the same exported symbols and passing tests, but is never faster
than lld here. mold 2.x (Ubuntu's 2.40.4, the last C++ release 2.42.1) does not
link AccelerANTgine. It stops on its non-PIC spdlog (`R_X86_64_PC32 … recompile
with -fPIC`). With spdlog made PIC it exports 619 extra symbols, and two Debug
suites abort on an ASan odr-violation. That is why the pin is 3.x and why no apt
package is used.

`linux/scripts/tests/test-linker-select.sh` pins it with stub drivers and a stubbed
download.

## `riscv64-cross.sh` — cross-build for riscv64, test under QEMU

`riscv64_cross_env` turns the amd64 image into a riscv64 cross environment over a
sysroot built from the image's riscv64 child (`RISCV64_SYSROOT`, default
`/opt/riscv64-sysroot`). It writes triple-named clang wrappers, exports the cc-rs, Cargo
and pkg-config variables for `riscv64gc-unknown-linux-gnu`, names the CMake toolchain in
`RISCV64_CMAKE_TOOLCHAIN_FILE`, sets the QEMU CPU model, and fails when a riscv64 binary
does not execute. Why each piece is there, and what it was measured against:
[`riscv64-cross-test-lanes.md`](riscv64-cross-test-lanes.md).
`linux/scripts/tests/test-riscv64-cross.sh` pins it.

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
`code-quality.sh`'s pair, and both defer to `01-core/python_uv.sh`. Unlike that
pair, which falls back to the hub's own bootstrap since 2026-09-15, both are
required here: an unset one is fatal.

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
theme as an API page. It rewrites every relative link, resolved from the guide's own
source path; a link with a scheme (`https:`, `mailto:`), a site-absolute one and a
same-page anchor stay as they are:

- **to a guide**: that guide's page, anchor kept (`getting-started.md#known-issues`
  becomes `guide-getting-started.html#known-issues`). Heading anchors are GitHub's,
  so an anchor written for GitHub lands on the site too;
- **to any other file or folder of the repository**, Markdown or not
  (`.github/workflows/web.yml`, `rust_builder/cargokit/README`): its page on GitHub,
  `<repository>/blob/develop/<path>` for a file and `/tree/` for a folder, and a path
  inside a submodule goes to that submodule's repository (from `.gitmodules`). The
  repository is `DARTDOC_BUILD_REPO_URL`, else the checkout's `origin`. A submodule the
  build did not check out is linked unchecked;
- **to nothing in the repository**: a page of the built site stays as it is; anything else
  fails the render, and so does a link out of the repository or one with no GitHub URL to
  use, since each would be a 404.

**rustdoc sites take the same guides** (2026-10-21). `docs-site.sh`'s rustdoc builder runs
the stage and render steps over `cargo doc`'s site with `DARTDOC_BUILD_API_DIR=target/doc`,
`DARTDOC_BUILD_FLAVOR=rustdoc` and `DARTDOC_BUILD_SHELL=<crate>/index.html`, the root
package's page (`cargo_build_doc.sh`'s rule). A guide is that page with its main content and
its sidebar's `#rustdoc-toc` replaced, written beside it so its `../static.files/` paths
hold; every page with a `<div class="sidebar-elems">` gets a *Guides* block at its top, and
source pages, which have none, are skipped. A shell missing `#main-content` or
`#rustdoc-toc` fails the render, as dartdoc's landmarks do.

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
| `DARTDOC_BUILD_API_DIR` | the site the guide steps work on | `<doc root>/api` |
| `DARTDOC_BUILD_FLAVOR` | the site's generator, `dartdoc` or `rustdoc` | `dartdoc` |
| `DARTDOC_BUILD_SHELL` | the page a guide is cut from and written beside, relative to the site | `index.html` |
| `DARTDOC_BUILD_CLEAN_CMD` | array run before generation; unset skips | — |
| `DARTDOC_BUILD_DOC_CMD` | explicit array that generates the site; bypasses tool resolution | the pinned dartdoc tool below |
| `DARTDOC_BUILD_TOOL_CACHE` | isolated generator cache root, keyed by the tool pin | `<root>/.dart_tool/dartdoc-tool` |
| `DARTDOC_BUILD_THEME_CSS` | generated brand sheet appended to dartdoc's stylesheet | — (required) |
| `DARTDOC_BUILD_IMAGES_DIR` | directory copied to `doc/api/images`; empty skips | — |
| `DARTDOC_BUILD_GUIDES` | array of `<source markdown>\|<slug>\|<nav title>` | — |
| `DARTDOC_BUILD_FOOTER_LINKS` | array of `<label>\|<url>` for the page footer | — |
| `DARTDOC_BUILD_FOOTER_TITLE` | bold name in front of those links | — |
| `DARTDOC_BUILD_TITLE_SUFFIX` | appended to each guide page's `<title>` | — |
| `DARTDOC_BUILD_REPO_URL` | GitHub URL a link to a repository file that is no guide points into | the checkout's `origin` |
| `DARTDOC_BUILD_VENV_DIR` | the renderer's venv, on a workstation without the image only | `${TMPDIR:-/tmp}/kataglyphis-dartdoc-venv` |
| `DARTDOC_BUILD_REQUIREMENTS` | the file that pins `markdown-it-py==X.Y.Z` | `lib/dartdoc-guides.requirements.txt` |
| `DARTDOC_BUILD_PYTHON` | interpreter for the renderer | `python3`, when it imports the pinned parser |

**A configured input that is missing is fatal.** An absent
`DARTDOC_BUILD_IMAGES_DIR`, guide source or theme sheet fails the build instead
of being skipped: a docs site quietly missing its theme and half its pages is
worse than a build that stops and says so. The same rule governs the CI
ownership fix — the container writes `doc/` as root over a bind mount, and a
`chown` that fails leaves a tree the host user cannot rebuild.

### The API generator

The default resolves the exact `DARTDOC_VERSION` from `01-core/tool-pins.env` through official
pub.dev in `<root>/.dart_tool/dartdoc-tool/<version>`. A matching cached tool is reused; a
failed activation or generator fails the build. `DARTDOC_BUILD_TOOL_CACHE` moves that cache,
and an explicit `DARTDOC_BUILD_DOC_CMD` bypasses resolution. The SDK, app dependencies and the
caller's global tool cache are untouched. This follows the host-tool bootstrap convention;
the Dart executable still comes from the image.

The image's bundled dartdoc 9.0.6 crashes while stripping dependency `@docImport` comments
(`RangeError (end)`, offset 80 in a 79-character comment). Upstream
[9.0.8 fixes the offset drift](https://github.com/dart-lang/dartdoc/blob/main/CHANGELOG.md#908).
On 2026-10-22, the exact published image reproduced that crash on ANThology; the pinned tool
completed its full themed site and the link gate found zero issues across 1179 documents.
`tests/test-dartdoc-tool.sh` checks pin, cache, caller override and error propagation with
recording executables; it does not substitute for that real documentation build.

### The renderer's Python

`dartdoc_build_prepare_python_env` downloads nothing in CI or in the image
(2026-10-19, BACKLOG CON101). It uses, in this order:

1. `DARTDOC_BUILD_PYTHON`, when the caller sets it;
2. `python3`, when it imports `markdown_it` at exactly the version
   `dartdoc-guides.requirements.txt` pins. `:latest`'s `/opt/venv/bin/python3`
   carries 4.2.0;
3. otherwise, with `CI=true` or inside the image (`/opt/venv` exists), it fails:
   `python3 (...) lacks markdown-it-py 4.2.0; CI and the image never download it`;
4. on a workstation without the image, a uv venv at `DARTDOC_BUILD_VENV_DIR` with
   the pinned parser. OmniAccelerANT's `getting-started.md` § *Build API docs*
   runs `generate-docs.sh` on a host, which is the one caller of this path.

Suite: `tests/test-dartdoc-python.sh`.

## The rustdoc theme sheet

`02-toolchain/rust/cargo_build_doc.sh` styles `cargo doc` output with the same
generated brand sheet the Sphinx and dartdoc builds use: DocumANTation's
`style/generate_style.py` renders it from `style/brand.json` and ships it inside
the `sphinx_kataglyphis` package.

It did not always find it. Both probes that stood in that script named a hub path
that resolves to nothing — the hub's own `docs/_static/css/custom.css` was dropped
in `fc26b1d1` (2026-07-15) as a stale fork of that very sheet, and the fallback
pointed one level short, at `linux/docs/_static/`, which has never existed in this
repository. The block therefore produced an empty `EXT_CSS` on every run and
rustdoc got no theme at all, silently.

The path is now resolved from `SCRIPT_DIR` rather than the working directory, so
it answers the same inside a consumer's `third_party/ANTfrastructure` checkout —
which is the case the cwd-relative probe existed for in the first place.

### Every crate of a workspace

A `Cargo.toml` with a `[workspace]` table gets `cargo doc --no-deps --workspace`
(2026-10-19). Without it cargo documents the root package alone: OxidANT's site
showed `oxidant` and none of its ten member crates. Measured in `:latest` against
OxidANT `8af8f67`: 11 crates in `target/doc/`, every one in rustdoc's crate list,
39 s. A caller that names the packages (`-p`, `--package`, `--workspace`,
`--all`) keeps its choice, and a single-package manifest builds as before. Suite:
`tests/test-cargo-build-doc.sh`.

## Consumer entry points that are not libraries

The things below are executables a consumer *runs*, not cores it sources. They
share one rule, and it is the rule the `lint-secrets.sh` and `lint-workflows.sh`
repairs were both about: **the consumer repo root is an explicit argument, never
inferred from `BASH_SOURCE`.** A consumer checks this repo out at
`third_party/ANTfrastructure/`, so a self-derived root resolves to ANTfrastructure and
the tool operates on the wrong tree — reporting green, having looked at nothing.

### `06-packaging/collect-release-assets.sh`

`collect-release-assets.sh [options] <artifacts dir> <out dir>`: a release run's uploads as one
flat directory of release files, by `--skip`, `--include`, `--rename`, `--zip`, `--expect` and the
rest, or one option per line through `--options FILE`. The reusable `release-publish.yml` runs it;
options and names: [`branch-and-release-strategy.md` § *Collecting the release files*](branch-and-release-strategy.md#collecting-the-release-files).

### `lib/fetch-data-lock.py`

`python3 -I fetch-data-lock.py --lock FILE [--dest DIR] [--extract] [--only NAME]...`: the files
or scenes a data lock pins, checked by SHA-256, through a cache; CMake reaches it through
`kataglyphis_fetch_data`. The contract: [`data-repositories.md` § *The hub's fetcher*](data-repositories.md#the-hubs-fetcher).

### `lib/test-harness.sh`

A consumer's bash suite sources `$(antfrastructure_path linux/scripts/lib/test-harness.sh)` and gets
the hub's own harness: `t_case`, `t_assert_eq`, `t_assert_contains`, `t_assert_ok`, `t_assert_fails`,
`t_assert_rc`, `t_assert_grep`, `t_assert_no_grep`, `t_rc`, `t_out`, `t_skip_unless`, `t_needs` and
`t_summary` ([`cross-build-verification.md` § *The `linux/scripts/tests` suites*](cross-build-verification.md#the-linuxscriptstests-suites)).
The suite runs under `set -u`, not `-e`: the harness counts every failed assertion and `t_summary`
sets the exit code, `0` only when at least one assertion ran and none failed. It prints the same
`N assertion(s) passed` line the consumers' own `passed` counters did. Like every `lib/` module it
loads `01-core/logging.sh` through `log-bootstrap.sh`, so `info`, `warn` and `err` are there too.

| A consumer's own helper | The harness |
| --- | --- |
| `expect <rc> <name> <args…>` | `t_case <name>`, then `t_assert_rc <rc> <command…>`; a miss prints the command's output |
| `check <name> <file> <ERE> [absent]` | `t_case <name>`, then `t_assert_grep` or `t_assert_no_grep <file> <ERE>`; a miss prints the file |
| `check <name> <command…>` with a `fails` count | `t_case <name>`, then `t_assert_ok <command…>` |
| `passed` and the closing `printf` | `t_summary` |

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

`python_venv_executable` selects an executable `bin/python`, then
`Scripts/python.exe`, preserving the raw venv path. UV and WebDAV retain their
own named errors and checks. Copies of either module require the pure probe
beside it. UV and Python CI also share the `/workspace/pyproject.toml` override;
caller defaults, cwd changes and PATH setup remain caller policy.

`preflight_python_require <caller>` returns 0 with `PREFLIGHT_PYTHON` exported
when that value (or, unset, `python3`) runs `-c pass`, and 1 naming the caller
and the knob otherwise. Plain `python3` is not trusted because on Windows Git
Bash it is the Microsoft Store stub, which prints an install hint and exits
non-zero. `preflight.sh` probes a candidate list and exports the winner; a gate
run standalone inherits nothing, so `lint-workflows.sh` and `run-lint-gates.sh`
call this before their Python steps instead of each carrying the check inline,
which is where the second copy sat until 2026-09-14. `lint-python.sh` and this
repo's own pre-commit/pre-push hooks joined them on 2026-09-15. Expand the value
unquoted, as `preflight.sh` does: it may be a command line such as
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
`--windows`, `…_WINDOWS_ARM64_TAG` with `--windows-arm64` for the arm64 cross
bundle) on stdout and nothing else, so it is safe in a command substitution.

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
(`WindowsContainerImage.Common.psm1`). `tests/test-ci-image-ref.sh` holds the
script to the same strings as `verify_ci_image_refs.py`, which grades the four
action defaults (and the Windows pair's `image-arm64`);
`ContainerImage.CiRef.Tests.ps1` holds the twin to `versions.env`.

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

### `run-lint-gates.sh` — seven gates over a consumer tree, plus the opt-in ratchets

```bash
bash third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh "$PWD"
bash third_party/ANTfrastructure/linux/scripts/run-lint-gates.sh "$PWD" --exclude vendor
```

shellcheck, actionlint (+ the CI image-ref check), gitleaks, ruff (error tier),
the shared-config drift check, the consumer pin-forwarding check and the
[README length](code-quality-tooling.md#readme-length-readme-length), in one
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
**`verify_doc_dupes.py --against-hub --root`** (2026-10-19) runs beside it: a consumer
page that restates a hub page fails, once the consumer seeds `doc-dupes-hub.allow`
([how it decides](code-quality-tooling.md#consumer-pages-against-the-hub-doc-dupes---against-hub)).

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

Because that cache lands **inside the repository**, a consumer that also runs a
tree-walking gate must keep it out of the walk: every dependency ships its own
`example/` sources, and a gate that grades them fails on code the repository
neither owns nor can format. OmniAccelerANT measured 28 such CMake files —
`fl_chart`'s `example/linux/CMakeLists.txt` among them — after one `pub get`.
`code_quality_find_cmake_files` therefore excludes `*/.pub-cache/*` by default
(`CODE_QUALITY_CMAKE_DEFAULT_EXCLUDES`, added to whatever
`CODE_QUALITY_CMAKE_EXCLUDE_PATHS` a consumer sets, never replacing it): the hub
created the directory, so the hub excludes it. The C/C++ walks skip it too, with the
other dependency and output trees git never lists (`CODE_QUALITY_UNTRACKED_EXCLUDES`;
Windows' walk the same set, 2026-10-19). Any OTHER tree-walking gate a consumer runs —
a licence sweep, a secret scan over sources — has to exclude it in that gate's own list.

Three things it does not do, and must not gain: a `safe.directory` for the SDK
(`setup-package-image.sh:556` registers `/opt/flutter` at `--system` level, so a
`--global` copy is a no-op that reads like a requirement), sourcing `~/.bashrc`
to find flutter (`Dockerfile.package`'s `ENV PATH` already carries it, and a stock
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

The script it runs is `01-core/download-webdav-files.py`. Filtered and complete
walks both call the client's `download_all_files_iterative(..., extension=...)`.
The client owns decoded path validation, local-root containment, response lifetime
and atomic replacement. A listing, HTTP or streaming failure reaches the CLI as
exit status 1, including a failure after earlier successful files. The `.pfx`
certificate fetch uses the same implementation with a filter. A one-line shim remains at
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

### `01-core/bind-mount-ownership.sh`

`fix_bind_mount_ownership <target> <reference>` hands a tree a container wrote
back to whoever owns the bind mount. `<reference>` is a path the host user owns
— normally the workspace root — and its `uid:gid` is what `<target>` is handed
back to; nothing takes a uid as an argument, because a number typed at a call
site is the thing that goes stale.

The three decisions around the `chown` are the whole reason this is shared:

* **Only the paths that actually differ**, never a blanket `chown -R`. On a tree
  that is mostly already correct, recursing over it asks the kernel for a chown
  it refuses for a non-owner and turns a no-op into an error. `-h` so a symlink
  is retargeted rather than its destination, which may be outside the tree.
* **A failure as a non-root uid is explained and tolerated.** Giving a file to a
  *different* uid needs `CAP_CHOWN`; as an unprivileged container user that is
  arithmetic, not a defect, and it was measured red on a Windows host with
  nothing an operator could do about it.
* **The same failure as root is fatal.** There it means a read-only or broken
  mount, and the tree really is left in the state this step exists to prevent.

A missing `<target>` is not an error: a docs step that produced nothing has
nothing to hand back. `lib/dartdoc-build.sh`'s `dartdoc_build_fix_ownership` is
the older blanket `chown -R` form over one fixed tree and predates this;
`tests/test-bind-mount-ownership.sh` pins all three decisions.

## ELF stripping in media and toolchain builds

`01-core/elf-strip.sh` owns `strip_elf_files` and `strip_elf_tree`. Media build
helpers source this companion; copy it beside `build-helpers.sh`. A minimal
`02-toolchain/bootstrap.sh` also needs the companion in its directory, the adjacent
`01-core` directory or `/opt/scripts/core`. It reports a missing companion rather
than defining a private strip implementation. GCC and LLVM's narrow Dockerfile
closures both mount the leaf explicitly.

Tree stripping still selects ELF files, uses the requested tool and parallelism,
and treats strip errors as quiet best-effort work. GCC retains its narrower
executable/shared-object selection and invokes both host and target strip tools.
The shared invocation uses NUL separators, preserving filenames containing spaces;
an empty selection invokes no tool. `test-elf-strip.sh` uses stubbed file and strip
tools, not real ELF mutation or a compiler build.

## Renovate driver helpers

`renovate-cli.sh` owns the local/fleet argument loop and their explicit option
policies. `renovate-git.sh` owns root validation and callback-based submodule
enumeration. Both are passive libraries, require the driver's existing `err`
function and must accompany either driver. Discovery callbacks own branch
classification and recursive identity resolution. See
[dependency-updates.md](dependency-updates.md#shared-driver-helpers) for the dry-run
contract and regression coverage.

GStreamer monorepo setup uses the cross guard validated by `media_common_init`. It
refuses a missing guard before configuring flags, rather than defining its own
fallback. The Meson fixture suite checks both guard verdicts and incomplete closure
refusal. The fallback for core-only consumers remains owned by `01-core/common.sh`.

## Shared CMake and CTest project environment

`lib/project-env.sh` owns Git safe-directory setup and project Vulkan initialization.
It loads `log-bootstrap.sh` directly, so standalone sourcing supplies the same real
logging module as the launchers. The whole-library census includes this companion;
new libraries must pass it before any library mutation has a valid baseline.
Both launchers source it, so copies must carry it and `01-core/vulkan-env.sh`.
An empty safe-directory setting opts out; Git configuration failures stay advisory.
The caller's `source_vulkan_env` hook takes precedence over an explicit setup script,
including its exit status. Explicit scripts use the Vulkan leaf's active-link
restoration. That leaf also owns the common Vulkan CLI help lines.

`test-project-env.sh` checks hooks, setup-script effects in the caller, directory
spacing and each launcher's delegation with stubbed Git. Existing Vulkan fixtures
check the active link. Neither suite initializes a real SDK or changes user Git
configuration. CMake retains its separate Cargo, ccache and linker policies.

Core-only cross detection lives in `core_cross_build_is_active` in `common.sh`;
its source-time selector preserves a loaded canonical guard or compatibility hook.
The fallback suite tests this approximation directly, including native architecture
aliases, while GStreamer tests the mandatory canonical guard at its own boundary.

## Compiler identity and pinned source staging

`platform.sh` owns `clang_embedded_deb_version`, used by package setup and compiler
validation. Embedded Debian metadata identifies the selected binary even when a
loaded distro `libclang-cpp` changes its `--version` output. The existing epoch and
suffix parsing and CLI fallback remain unchanged. The validator wrapper keeps an
empty result nonfatal under `errexit`; setup retains its existing failure policy.
`test-clang-embedded-version.sh` checks these boundaries with executable fixtures,
not a real Clang installation.

`downloads.sh` owns `clone_pinned_repository`: try a filtered clone, fall back to
an unfiltered clone, check out the requested commit and compare HEAD exactly.
Each failure propagates in a conditional caller. HailoRT initializes submodules
after cloning; TAPPAS copies its selected include tree and uses its own sentinel.
The pinned-repository suite exercises those policies with a stub and a real local
Git repository; it accesses no remote repository.

`hailo-build-lib.sh` owns `hailo_unpack_source_archive`. Callers retain their
readiness checks, URLs, hashes and cache paths. The helper verifies before
extraction, creates the destination, applies the requested strip count and keeps
the archive for cache reuse. The archive suite uses real local tarballs and hashes,
including corrupted archives and a failed download over a valid stale archive.
`download_verified_file` stops on fetch failure even when its caller disables
`errexit`; checksum success alone cannot turn a failed fetch green.

## Android CMake target arguments

`android-build-preamble.sh` owns `android_cmake_target_args`, which replaces the
caller's array with the selected NDK toolchain path, ABI and resolved API level.
IREE, LiteRT and OpenCV expand that array into their target configuration; host
configuration, project options, configure retries and failure policy remain with
the caller. The argument suite checks three ABIs and an NDK path containing spaces;
it does not invoke an NDK or build any of the projects.

## Python CI test fixtures

The test harness owns `t_python_ci_fixture <root> <scripts> [relative-script ...]`.
It exports `WS`, `TREE`, `CALLS`, `OUT` and `BIN` for fixture subprocesses, creates isolated directories and copies
`python_uv.sh`, logging and each requested script, then writes workspace detection
that points to `FIXTURE_WS`. Missing inputs fail in conditional callers too.
The four Python CI suites append their own preparation and uv stubs; their wheel,
packaging and interpreter assertions remain unchanged. Harness fixtures verify
source bytes, paths with spaces and workspace binding without invoking uv.

## Windows test fixture helpers

`TestHarness.psm1` owns temporary directory allocation and
exception assertions. `New-TestDir -Prefix` preserves each suite's diagnostic
prefix and creates a unique directory. A suite-scoped fixture keeps its existing
`AfterAll` cleanup; `Invoke-InTestDir` owns cleanup for one test body, including
failures. `Assert-Throws -MessagePattern` checks both the exception and the
expected diagnostic instead of copying a Boolean and catch block.

The harness fixtures exercise directory creation, prefixes, cleanup and exception
matching, with mutation proofs for allocation.

OpenCV and its GStreamer plugin delegate checkout-directory creation to
`Invoke-GitClone` and Git itself. They no longer pre-create the checkout parent;
a local-repository regression covers cloning into missing parent directories.

## Common build CLI dispatch

`01-core/cli-parsers.sh` owns `_parse_common_build_flags` for the runtime and cross
orchestrator parsers. It dispatches global options and mirror updates before
architecture aliases and help. Existing nameref destinations, parser signatures
and project-specific options stay unchanged. Return codes still mean unknown
(`0`), one argument (`1`), a flag plus value (`2`), or help (`255`); the outer
dispatcher retains its missing-value checks. The parser suite exercises both
public entry points, including URL whitespace and swallowed option values.

## Cross GCC builder invocation

`02-toolchain/gcc.sh` owns `_gcc_invoke_cross_builder` for ordinary cross GCC and
Canadian native GCC. It preserves option order, the root sysroot, target include
path, C/C++ languages, non-bootstrap mode, compiler cache and registration policy.
Only the Canadian call supplies `--host`; its compiler environment and configure
cache answers remain with that caller. Prefix, scratch directory and requested or
detected job count are forwarded to the existing builder.

Both callers raise builder failures explicitly. An ordinary cross build can no
longer appear successful under a conditional caller merely because an earlier
installation left executable tools behind. The Canadian link-probe skip remains
opt-in and happens before the builder. Local fake tools exercise argument order,
environment, job counts and fatal/skip paths; they do not compile GCC or inspect
real compiler ELF files.

## Shared Windows source edit cycles

`WindowsSourceBuild.Patches` owns optional/must-exist file loading, callback marker
skips and write/no-change verdicts. Regex and callback transformations keep their
own semantics. Their optional `-Quiet` mode leaves logging and aggregate change
counts with the caller while preserving missing-input errors, transform failures
and regex postconditions. Existing calls keep their default warning behavior.

GStreamer, IREE, LiteRT-LM, C++ keyword conversion and Ninja cleanup use this common cycle.
The GStreamer OpenCV 5 transformation is a pure text function so fixtures can check
header insertion and Windows CRT substitutions without running a source build.
`Get-TestCommandArguments -AsAst` exposes typed argument nodes so fixtures can
exercise the actual caller callbacks without executing the build entry scripts.
The test harness's `Invoke-SourceFileDiagnosticCase` exercises changed/unchanged
transforms in normal and quiet modes, including output types, file bytes, failure
propagation and no-op timestamps.

Torch's Dockerfile test parser indexes stage objects as it reads them, retaining
global instructions, unnamed stages and references to the final instruction lists.
Its fixture and mutation proof cover indexing without invoking a container build.

### Cold module visibility fixtures

`Test-ColdModuleCommands` in the Windows test harness runs module imports and
command visibility checks in a fresh PowerShell session. It returns the child
exit code and captured diagnostics, quotes literal paths and command names,
and accepts `-Force` only when a caller needs a forced entry-level import.
Re-export and build-call closure suites share this probe. Their declarations
come from the harness AST readers and command binder, so malformed scripts
fail before export or function discovery. `Get-TestFunctionNames` reads only
parsed function declarations, including nested definitions, without executing
the source. The fixture tests cover exported and missing commands, failed
imports, apostrophes in paths and isolation from parent-session functions;
they do not execute build entry points.

### ONNX web installation and artifact verdicts

`50-build-js.sh` shares `install_onnx_web_lock` across `js`, `js/common` and
`js/web`. Each call runs in its original directory, retries `npm ci` once
after five seconds and fails after a second error. There is no `npm install`
fallback. `require_onnx_web_js` accepts either JavaScript extension and checks
both `js/web/dist` and the final WASM output directory. The copy still treats
an absent extension as optional, and a missing destination artifact is fatal.

`test-onnx-web-build.sh` runs the actual step with local npm, sleep and cleanup
stubs plus the production logger. It covers both extensions, retry success
and failure in all three directories, failed builds, missing bundles and
failed copies. It does not build real bundles, contact npm or validate the
contents of upstream lockfiles. The fixture can take an earlier step file as
its first argument for behavior comparison.

### Shared bundle packaging lifetime

The public deb, AppImage and Flatpak bundle entry points keep their arguments.
They share a dispatcher that owns local bundle facts, the common icon name
and the final nonempty-artifact verdict. Format callbacks retain their layout,
commands, output names and diagnostics. A callback failure propagates before
the final verdict, even when a previous artifact exists. The callback is
invoked unconditionally: putting it in an `||` list would disable Bash errexit
inside its staging operations. A local regression verifies that an early
copy failure still stops an unconditional AppImage invocation.

The format architecture wrappers share supported-architecture validation and
retain their original alias conversions and format-specific refusal messages.
Bundle copying preserves hidden files, symlinks and executable payloads through
one shared staging operation. Desktop-entry and optional-icon staging has one owner; template adaptation and
format-specific Exec, Icon and destination values remain with the caller.
`test-app-packaging-bundle-facts.sh` exercises these contracts with local
fixtures. The existing archive suite also builds and inspects a real deb; the
Flatpak suite uses tool stubs. These checks do not validate real AppImage or
Flatpak creation on a target machine.

### TVM compiler-name resolution

`_tvm_gcc_commands` in `05-frameworks/tvm.sh` selects versioned GCC and G++
names independently, falling back to the corresponding generic command.
Validation still requires both toolchain compilers and checks explicit CC
and CXX overrides. Selection still resolves override paths and hands C then
C++ to the ABI wrapper with the original LLVM and build-directory arguments.
The local selection fixtures also run against the previous implementation;
they execute neither compilers nor TVM builds.

### Shared log-prefix formatting

`01-core/logging.sh` formats severity labels and their color policy in one
place. `_log_prefix_plain` and `_log_prefix_color` keep their existing names
and output. INFO is blue, WARN yellow, ERROR red; unknown levels retain LOG
with the existing bold-only colored form. `NO_COLOR` still wins over forced
color, normal messages use stdout, warnings use stderr and errors exit 1.
The prefix/stream fixtures and ERR-trap suite run without a terminal; actual
terminal rendering is outside their coverage.

### Shared cross-Python path lookup

The cross-Python library shares library-directory suffix lookup, scoped
Python/triplet/root context and pkg-config filename composition. The staged
prefix precedes system locations, root arguments retain their order, a failed
version probe stops later lookups and embed metadata keeps its own suffix.
Path-context assignments stay in caller-owned locals. The local path fixtures
also run against the previous implementation and cover candidate ordering,
forwarding, missing metadata and resolver failures. They do not execute a
target interpreter or establish target ABI compatibility.

### Windows test fixture companions

`WindowsArchGate.Fixture.psm1` shares architecture-suite binary constructors,
runtime-tree setup and child-gate verdicts. Valid PE samples use the existing
harness constructor; malformed headers and COFF/archive members retain their
boundary bytes. Child exit-code and diagnostic checks remain mandatory, with
a mutation that rejects a fabricated successful exit code.

`WindowsUv.ChainFixtures.psm1` shares command/log observers and replacement
assertions. Recording occurs before caller-owned rejection; each invocation
keeps independent state. OpenCV and ORT keep their own environment and error
handling, exact command expectations and positive/negative pattern checks.
The fixture's dropped-recorder mutation must fail its command-count verdict.
Both companions live beside their suites and must accompany copied suites;
they are test helpers, not new image dependencies.

Wheel requirement fixtures use `New-TestWheel` rather than private ZIP writers.
A Requires-Dist-looking body line proves parsing stops at the header boundary;
a local mutant that reads the body is rejected. These fixtures do not run uv,
target binaries or target interpreters. Existing platform-dependent skips and
failures remain visible in the focused suite results.

### Shared foreign-target guard

The libstdc++ linker repair and runtime pinning entry points share a pure
nonempty-target-versus-build-architecture predicate. They retain raw target
spelling, the existing amd64 fallback after a failed build-architecture probe
and their distinct triplet policies. Default target resolution remains at the
original unconditional call sites, preserving errexit on resolution failures.
The guard fixtures stub all link operations and do not modify system libraries.
The path and guard suites share module selection, scratch setup and cleanup in
`tests/cross-toolchain-fixture.sh`, which must accompany those test scripts.

The artifact suite shares copy/recursion and invalid-pkgconfig fixtures while
retaining each negative condition. Its forced-recursion mutant must fail the
omitted-switch case. These are local test fixtures, not new build dependencies.

### Wheelhouse and media compiler preparation

Torch wheelhouse builds share source preparation and wheel collection while
retaining component clone flags, host-install order and C-extension repair before
retagging. Sysconfig, repair, retagging and copy failures propagate through the
conditional orchestration; failed preparation cannot report success. Local fake
builders cover these paths without downloading or building dependencies.

GStreamer build paths share missing cross-compiler initialization through the
existing media core companion. The stage build retains its additional libstdc++
repair, legacy SDK fallback and runtime pinning in their original order. Fixtures
stub compiler and linker operations; they do not change system libraries.

### Windows formatting and source-build fixtures

Formatting shares tracked-file filtering and clang-format lookup. C/C++ keeps its
sorted, deduplicated Git results and filesystem fallback. Dart remains tracked-only
with its own exclusions and preserves Git order and duplicates. Both formatting
modes prefer PATH, then the two common LLVM installation locations. Missing-tool
rewrite errors identify clang-format instead of an uninitialized local variable;
check mode retains its advisory and mandatory policies.

`WindowsSourceBuild.RetryFixtures.psm1` owns retry fixture environment, temporary
logs and cleanup. Ninja and Git retain distinct retry policies and identical fake
tool programs. `WindowsMedia.WiringFixture.psm1` shares FFmpeg listing and OpenCV
AST wiring assertions. These companions stay beside copied suites; they add no
image dependency. Local mutation proofs reject dropped attempts, nested-function
matches and nonfatal finding guards. Windows-specific execution failures remain
visible on Linux hosts.

The CUDA cache diagnostic delegates context-directory creation to the existing
`Resolve-DirectoryPath` helper. Its random temporary prefix and cleanup stay at
the call site. Local path fixtures cover creation and reuse with payloads; they
do not start BuildKit, access a remote cache or compile CUDA.

Python application requirement hashing groups each requirement with its following
hash lines. Only matching hashed groups gain the built wheel hash; other lines,
repeated groups and continuation bytes retain their order. A local lost-final-group
mutation guards against silently omitting the final requirement.

### Repository refresh and Linux parser fixtures

`downloads.sh` owns the best-effort shallow fetch used by the generic repository
helper and TVM: try the requested ref, then tags, tolerating failure of both.
Checkout policy stays with each caller. The generic helper still tolerates a
failed checkout and reports stale or missing HEAD; TVM still requires checkout
success before refreshing submodules. TVM receives this helper through its
existing `common.sh`/`downloads.sh` companions. Local fake-Git fixtures verify
fetch order and checkout policy against both implementations without a network.

The orchestrator and runtime CLI parsers share named-option assignment through
caller-specific destination maps. Aliases, raw empty and option-shaped values,
consumed-argument counts and common flag precedence retain their policies.
Their public interfaces and nameref targets remain unchanged. Parser fixtures
exercise every mapped option, help, positional inputs and dispatcher errors.

Compiler validation shares target-native GCC/LLVM ELF fallback checks and the
compiler target-failure verdict. Mandatory failures still exit immediately;
advisory failures retain their aggregation and diagnostics. Local fixtures
compare baseline and refactor outputs without executing target compilers.

Parallel-loop fixtures share child-shell setup while retaining the strict
caller-return scenario and separate fail-fast and keep-going expectations.
They still invoke the actual loop library; mutations that omit it or invert
its fixture predicate must fail. These tests launch only local stub workers.

### Shared object smoke lifecycle and ONNX probing

Android NDK and generic compiler object probes share temporary-directory
allocation, compilation, verification dispatch and cleanup in `smoke-common.sh`.
Each caller retains its original C program, artifact name, ELF policy and
messages. NDK rejects an empty architecture mapping; the generic probe retains
its readelf/file-presence guards. Failed or invalid temporary allocation never
invokes the compiler, and failed cleanup cannot report success. The existing
smoke companion must accompany both entry points; no new runtime companion is
introduced. Fake-compiler fixtures exercise successful and failed compilation,
wrong or unreadable ELF metadata, verifier failures and cleanup errors without
running SDK compilers or target binaries.

The media smoke shares native-import versus cross-library probing for ONNX
modules. ONNX Runtime remains required and checks the CPU execution provider;
GenAI remains optional. Cross probes never import target modules. Native library
fallbacks keep their deferred-runtime diagnostic and original search roots.

Argument-consistency checks share declaration traversal and fatal reporting.
Callbacks retain the distinct forwarding, default-drift and defaultless policies,
per-file deduplication, Android exemptions and aggregate counts. Expanded fixtures
run against both the original and refactored checker; mutations guard callbacks,
counting and fatal exits. These are source checks, not container-build proofs.

Disk-guard and Renovate-audit fixtures share cache setup, audit command capture
and rollback verdicts. Independent sizes, modification times, JSON errors and
failure inputs remain explicit. The fixtures perform no real cache pruning,
registry access or build-daemon operations.

### Host architecture resolution and shared quality probes

`platform.sh` shares host probing after the caller selects its preferred raw
architecture. Target resolution retains explicit argument then `TARGETARCH`;
build resolution retains `BUILDARCH` then the final `BUILDPLATFORM` component.
Only an empty selection probes dpkg, then uname. Partial output from failed dpkg,
empty successful uname output and the failed-uname `unknown` fallback retain
their behavior. The target Python version helper delegates its shared pin and
host-probe fallback to the existing host-version owner after its target override.
LLVM builder discovery uses one ordered candidate loop and still prefers the
sibling builder over the installed container path, including non-executable
regular files. Local fixtures check probe order, status and baseline behavior.
No new companion is introduced for these helpers.

C++ quality and tidy file discovery share extension predicates and filesystem
traversal while retaining distinct configuration defaults, multi-root inputs,
exclusions and caller-array ownership. Compiler-cache tests share their fixture
bootstrap while retaining launcher selection and server-address assertions.

Runtime consumer and shipped-content probes share their shell transport and
scalar container configuration lookup. Tests compare generated shell wrappers
and payload environment bytes, including empty-Python guards and caller-owned
sentinel verdicts. Consumer metadata checks keep required entrypoint failures
separate from advisory working-directory differences. Config verdicts also share
volume handling; only the volume check treats `NONE` as absent, while a literal
`NONE` working directory remains an advertised value.

Critical-fix source checks share compound predicates and record parsing while
retaining independent patterns, diagnostics and fatal/advisory policies. Existing
mutation IDs are retargeted to their shared owners when the protected behavior
moves, so extraction cannot silently retire a regression proof.

### Toolchain companion and web-smoke probes

Toolchain common, build-helper and ELF-strip loading share candidate construction
and source lifecycle. Common loading keeps its mounted-core preference; the
build-helper and ELF-strip paths keep repository-core preference after an
adjacent companion. The shared source call stays unconditional so ordinary
errexit remains effective. Existing conditional callers retain their prior
source-status policy, and missing ELF fallback remains fatal. Local fixtures
exercise precedence, missing companions and source failure without building.

Flutter integration smokes share HTTP-200 verdicts and download-size probing.
Callers retain their exact success and failure messages. JavaScript and bootstrap
sizes remain strictly greater than their distinct thresholds; a failed download
retains curl's exit code even when it emits a plausible size. Existing HTTP
probes keep their guarded curl behavior. Fixture sites cover size boundaries,
missing assets, CSP, local engine and fallback fonts without HTTP access.

`01-core/module-bootstrap.sh` owns framework initialization and required-symbol
loading. Base and setup-dependencies keep their distinct module candidate lists;
media validation and Torch setup retain their ordered platform candidates and
fail if the required symbol is still absent. Source calls remain unconditional
so selected-module and framework initialization failures retain the caller's
normal errexit behavior, including existing conditional-call semantics.

The companion is a separate read-only bind mount in all six base RUNs and both
setup-dependencies toolchain RUNs. SDK's explicit core COPY and Torch's explicit
core COPY carry it into later stages. No whole-core mount replaces these narrow
inputs. Fixtures validate candidate order, selected-source failures, missing
symbols and each required Dockerfile closure without apt operations or builds.

### Native ONNX builds and cross-verification targets

Native CPU and AMD ONNX Runtime builds share invocation failure handling and
wheel collection through their existing `build/lib/common.sh` companion. CPU
keeps its retry count and delay; AMD keeps its direct invocation. Cross-build
verbose diagnostics remain advisory, while the failed original build remains
fatal. Native-only missing-wheel fallback, labels, output directories, header
and provenance order and final free-threaded work retain their policies.
Fresh child-shell fixtures exercise collection failures under ordinary errexit
without invoking a real compiler or fetching packages.

`platform.sh` shares cross-verification target selection and normalization.
An available resolver wins even when it returns an empty list. Without that
resolver, the tool-version and LLVM wrappers keep their distinct legacy
fallbacks. Resolver errors retain ordinary errexit; normalization failure keeps
the existing quiet versus logged skip policies. The tool-version wrapper still
restores its architecture variables, while LLVM retains its dispatcher contract.
Fixtures compare both original wrappers and the shared implementation with a
nondefault IFS, aliases, missing/empty targets and failed resolver/callback paths.

LiteRT web vendoring shares repeated asset handling without changing pinned
inputs or payload layout. Lint consumer fixtures share repository creation and
vendored file construction; tests prove those files exist before checking that
a gate excludes them. They use cached lint tools and perform no network work.

GCC release assets share bounded wget invocation while retaining per-asset retry
counts, timeouts, additional flags, argument order and failure status. GCC and
Clang share compiler-cache help rendering and unknown-option rejection through
their already-required toolchain bootstrap. Each builder retains its help spacing,
cache options and remaining parser behavior. Offline argv and byte comparisons
exercise the original and refactored builders without downloading or compiling.

### Cache policy, packaging inventory and media dispatch

`01-core/compiler-cache-utils.sh` owns disabled-flag recognition and launcher
statistics without installing environment defaults or starting cache servers.
Cache modules require this companion; GCC resolves it through the existing
bootstrap. GCC and LLVM retain separate read-only mounts in the toolchain stage,
and the media stage explicitly copies it beside the CMake cache helper. Existing
whole-core copies already carry it. Launcher arguments, selected statistics,
output streams and best-effort failure handling retain each caller's policy.

`06-packaging/media-payloads.sh` owns the ordered optional payload inventory.
The copier processes all fourteen entries; the validator observes only the five
marked for advisory checks. Paths remain relative to the caller's source prefix,
and GPU payload order and missing-payload behavior remain unchanged. Package's
artifact-source validator mounts the companion beside its script. The temporary
copier copies and removes both files; the final validator carries the companion
under `/opt/scripts/packaging`. Each closure is checked without building images.

The GStreamer Android recipe wrapper uses `android_apply_patch` after its existing
recipe guards. Mounted core scripts retain precedence; repository lookup uses
the caller's source directory. Fixtures cover paths containing spaces, both
layouts, skipped recipes and failed patch status without applying real patches.
Arm NN and OpenCV share optional install stripping through media common. Older
SDKs without the strip callback still skip it quietly; callback failures remain
advisory. Tests use stubs and never strip installed libraries.

Lifecycle fixtures use production truthiness behavior instead of copied boolean
tables. They track and reap their own children on exit. Offline fixtures and
mutation checks cover these dispatch contracts; they do not prove compiler,
container build, registry or real filesystem installation behavior.

### Provenance verdicts and verification fixtures

ORT and GenAI verification share hashing and indexed chain-byte comparison in
`03-media/ort-provenance.sh`, which GenAI already sources. Each scan keeps its
own archive rules, exemptions, counters and diagnostic suffixes. Multiple valid
chain files with the same name remain acceptable; missing or unreadable files
retain their previous findings. Offline fixtures exercise byte identity and
failure cases without downloading models or building ONNX Runtime.

The two verifiers also share FetchContent directory-name expressions for
`onnxruntime-src`, `onnxruntime-subbuild` and `onnxruntime-build`. Each caller
retains its own `ortlib` patterns, traversal scope, link handling and pruning.

TVM wheel fixtures share fake-builder invocation while retaining successful,
failed and missing-pipefail paths, captured stderr and log assertions. Ancestry
fixtures share requested-stamp execution while distinguishing missing labels,
unreadable images and requests without a run id. No registry is contacted.

The Ubuntu mirror verifier shares error emission and aggregate accounting.
Every Dockerfile, bootstrap order, scheme and suite probe still runs, and any
failed probe keeps the verifier red. These source checks do not test remote
mirror availability or perform package installation.

### Artifact collection and paired probes

The WASM build worker shares artifact collection across its build passes. Required
build failures remain fatal; optional passes and artifact copies retain their
existing best-effort policies. IREE Android shares its runtime configuration
profile while keeping host and target toolchain and driver options in their
original argument positions. Offline fixtures use stubbed tools; they do not
compile SDKs or validate produced WebAssembly binaries. Their shared
`linux/scripts/tests/script-stage-fixture.sh` owns source selection and workspace cleanup.

Ubuntu mirror callers share source-file enumeration through their existing
`ubuntu-mirror.sh` companion. The original file ordering and shell option state
remain observable. Fixtures exercise source layouts without running apt or
contacting a mirror.

Media artifact checks share the nonempty-file verdict while retaining their
distinct file and symlink admission rules and failure accounting. Image parity
checks share paired probe execution. Version comparison still uses first-line
output and its existing status policy; import checks preserve full output and
per-image failures. Empty version output cannot pass vacuously. Stubbed probes
characterize these contracts without starting containers.

Renovate collateral fixtures share the original-byte and clean-index checks for
staged deletions and modifications. Logging fixtures share severity, status and
unbound-variable verdicts; child scripts still exercise distinct trap lifetimes.
Module shadowing fixtures share production module loading while preserving each
assertion. Ownership fixtures share failed-chown setup while retaining distinct
root and non-root verdicts. Their mutation proofs cover dispatch and failure detection;
they do not perform dependency updates or real compiler builds.

Version-bump fixtures reuse their existing offline Python importer and forward
fixture arguments into fresh interpreters. Tag fixtures retain their exact fake
upstream candidates. GenAI binding fixtures share healthy defaults while passing
per-case overrides last; deliberately unpinned cases keep explicit unset behavior.
Provenance and lint fixtures retain their separate checks while sharing setup.

`t_emit_optional_functions` in the Linux harness serializes present functions in
argument order and skips absent names. Worker fixtures use it only for optional
helpers; required definitions remain mandatory. Focused tests check missing names,
usable emitted bodies and exit status. This test API performs no source parsing
or container execution.

### CLI arguments, core probes and workflow fixtures

`lib/cli-value-options.sh` owns `append_cli_nonempty_args`. Code-quality and
coverage callers retain argument order, duplicate values and whitespace inside
arguments. Empty values remain omitted; gcovr excludes keep their per-value
prefix. Copied libraries carry this companion alongside their existing logging
and tool-check dependencies. The CMake-format fixture explicitly copies it;
repository and submodule consumers already resolve the complete library tree.

`01-core/lint-root.sh` shares scope initialization and root publication without
adding an environment export. Linter-specific options and pinned-tool handling
remain in each driver. ShellCheck fatal reports share diagnostic replay while
retaining distinct flags and headings and the original exit status.

The shell, Python and Dockerfile drivers source `01-core/lint-scope-init.sh`
in their own shell. It loads the root parser, publishes the selected tree and
replaces positional arguments with the unconsumed arguments. Keep this initializer
beside `lint-root.sh` when copying a driver. A function call would isolate `set --`
from the driver. Empty arguments, line breaks, repeated root options and rejected
roots have frozen original receipts; linter execution has separate driver tests.
The ShellCheck root-contract test copies a small hub separately from its consumer
fixture so ignoring `--root` reaches the same assertions without scanning the
entire repository. The live-tree warning check remains separate.

`01-core/common.sh` owns `wheel_archive_run` for quiet wheel unpack and pack
commands, including multiword Python launchers and their raw status. LiteRT
renaming and runtime stripping retain their own payload edits, verdicts and
temporary cleanup. Repacking still regenerates RECORD through the wheel tool.

`02-toolchain/packaging-deps.sh` shares command execution and status capture
between packaging steps and sudo retries. Separate failure handlers retain
best-effort warnings, root refusal and the original sudo arguments and status.
Offline fixtures cover the current user's branch; they do not change privilege
or run package installation.

Wheel platform resolution shares canonical-helper precedence while preserving
LiteRT's required target lookup and Torch's best-effort fallback. GStreamer
shares foreign-target selection through its existing media owner. Keep each
original lookup separate. Remove scratch
state before the selected action so a failed lookup retains its status.

Compiler validation shares GCC version capture and source-fixture transport.
Source writers and probes remain unconditional, with caller-specific source bytes,
compiler arguments, link checks and diagnostics. Dynamic temporary-directory and
sanitizer state keep their original scope; cleanup retains its failure behavior.

ORT provenance shares component-name exclusions and filename candidate predicates.
Tree scans include `.tar.lzma2` archives; build-record scans stay at depth one and
omit that extra suffix. The concatenated GenAI spelling remains an archive-only
exclusion. Partial traversal findings and advisory failure diagnostics remain.
Stream fixtures share workspace and optional receipt initialization while keeping
each suite's expected outputs independent.

Rootless binfmt setup shares requested-architecture CSV parsing in its existing
script. Extraction, registration and verification retain separate unknown-target
and status policies. Array scope, IFS behavior and the literal namespace command
remain unchanged; offline tests never enter a real namespace.

The existing platform owner shares best-effort Debian triplet queries. Optional
mapper failures keep their stdout and suppress stderr and failure status, while
compiler and GStreamer callers retain their defaults and directory choices.
An unavailable canonical query helper fails before caller fallbacks can hide it.

`01-core/verified-script-install.sh` owns curl, optional checksum verification,
shell execution and final cleanup for UV and Rust installers. Callers retain
temporary-file allocation, pin lookup and mismatch callbacks, including their
different diagnostics and cleanup order. Copy this functions-only companion
beside `python_uv.sh`; Rust's Toolchain RUN binds the same fresh file. Cold import
tests reject absent, incomplete and failing companions and verify UV retry after
restoration. Lifecycle tests use fake download and shell commands.

Core helpers share nondefault-host suffix formatting and caller-directory
resolution while preserving explicit path bytes. Disk validation keeps positive
settings distinct from nonnegative free-space readings: zero-disabled settings
do not probe or start a watcher. Stage publication retains built-map, pin and
parallel-marker ordering. These helpers stay in existing mounted/copied owners;
no new runtime companion or broader mount is required.

Lane fixtures share YAML loading and query execution while preserving lane fields,
relative paths for Windows Python and the Linux multiword interpreter contract.
Mutation fixtures keep their ignore and skip scenarios independent. Workflow
fixtures share document and job construction while preserving malformed YAML and
line-sensitive findings. Flatpak failure fixtures forward every per-case tool
and payload override. Offline characterization and mutation proofs validate these
contracts without starting container engines, builds, pruning or disk watchers.

### Repository keys and media development links

`download_optional_verified_file` shares the existing repository-key policy:
a supplied checksum uses verified fetching; an empty checksum prints the caller's
warning and uses three download attempts. CUDA installation and ROCm dearmoring
retain their own cleanup and failure context. ROCm's private stanza renderer
preserves URI order, amd64, keyring paths and optional ASAN separators; independent
golden files check complete source bytes.

`media_missing_dev_symlink` only decides whether a destination is absent and its
source exists, resolving relative sources beside the destination. ArmNN and FFmpeg
retain their own `ln` flags, output order and direct/conditional failure handling.

Test companions share fixture construction and shell invocation context, while
expected output, exit statuses and filesystem receipts remain independent of the
production helpers. `runtime-flow-fixtures.sh` checks shared preparation wiring;
its own positive and negative fixtures ensure a missing step fails the assertion.

### Fetch and runtime validation lifecycles

ONNX fetch uses a private clone-if-missing helper in `20-fetch.sh`. Both
checkouts keep shallow branch cloning with three attempts and ten-second retry
spacing. ORT retains retried submodule commands; GenAI retains one-shot commands
and its existing-directory message. Every cwd change and requirements/emsdk step
remains caller-owned. Frozen offline receipts compare command boundaries, output
and failures; they do not execute Git, downloads or SDK setup.

`validate-media-runtime.sh` shares complete-line unresolved-library collection
and counted summary rendering. Binary scans still accept dangling symlinks while
plugin scans select regular `*.so` paths and live links. Empty records are skipped;
duplicates, whitespace and partial output before resolver failure are retained.
The resolver's failure remains advisory. Repair advice, source-built denial
counters and final fatal gates stay in their original callers.

`runtime-consumer-contract.sh` owns the ordered required-fact guard used by
appimagetool, JDK and Android verdicts. It uses the original first-match fact
reader and preserves exact values. Callers retain their diagnostic priority and
failure status; Android retains its environment reads but skips platform-tools
and PATH fact checks after an explicit payload-off marker. The helper already travels with the smoke script; no new production
companion or image closure is required.

Runtime and SDK help share row descriptions and padding in
`runtime-build-fns.sh`. Callers retain row order, description columns, wrapping
and profile-specific wording. Complete output receipts cover both runtime
entrypoints and SDK help. The environment contract renders runtime help before
checking its names against runtime consumers; documentation functions and SDK-only
references cannot make a dead runtime override appear live.

Torch venv setup shares best-effort missing-marker writes inside
`setup-torch-venv.sh`; cache-aware apt-list cleanup lives in
`package-image-wiring.sh` and is also called by package setup. Copied Torch setup
requires that companion before its first execution, including the early selective
image COPY. Marker reasons, neutral-cwd imports, OpenCV fallback, package choices
and warning/fatal policies remain local. Offline receipts cover failed marker
operations and mount probes without running apt or installing packages.

The Python payload emitted by `smoke-common.sh` uses one exception recorder for
native Tensor and generation failures. Existing operation labels, exception names,
`str` formatting and final defect counts remain unchanged; the recorder does not
invoke custom exception formatting methods.

### Containment, image arguments and runtime enumeration

`01-core/path-helpers.sh` owns the lexical root predicate used by ORT provenance
and GStreamer's ORT checks. GStreamer retains roots verbatim; provenance trims
exactly one trailing slash before ignoring an empty root. Neither policy resolves
symlinks or dot components. Copied callers require the existing helper in their
relative `01-core` layout. Five media recipes mount those same canonical bytes
at the matching installed path; cache IDs and the stage graph stay unchanged.

`image-ref-args.sh` binds the optional container CLI and image reference for
`build-helpers.sh` and `digest-pinning.sh`. One argument uses `NERDCTL_BIN` or
`nerdctl`; multiple arguments retain the explicit first two values and ignore
extras. The callers retain their own inspect/registry work, errors and shell
failure contexts. No new argument validation changes their existing zero-argument
behavior. Both compiler recipes and isolated copied bundles carry the mandatory
pure companion.

FFmpeg's SDK bundler and apt manifest share their existing bin-then-lib runtime
file enumeration. It keeps depth limits, regular-file selection and suppressed
find diagnostics. The bundler retains advisory process-substitution failures;
the manifest retains its pipeline status. Independent byte receipts cover both
producers failing under direct/conditional and strict/relaxed shell contexts.

The runtime help pages also share the three common build-stage descriptions and
options/footer/environment rendering. Caller heredocs retain their own text and
literal values; the independent full-help receipts verify the original byte order.

Cross-chain and cross-compiler help use the common repository-description row
with their original columns. Their `--cross-targets` callbacks share raw assignment
and argument consumption through `orchestrator_set_cross_targets`; compiler targets
remain distinct from the chain's per-stage architecture list. Independent fixtures
exercise empty values, commas, spaces, literal shell text and newlines inside
caller-local variables. Complete help receipts also cover both cross entrypoints.

### Runtime selectors, compiler tools and wheel manifests

`orchestrator_consume_runtime_push_arg` owns the shared runtime push selectors.
Each entrypoint keeps its accepted flag set and unique options. The helper keeps
assignment order and argument consumption; untouched fields remain unset or keep
the caller's existing value. Gates-only handling stays in the manifest caller.

`compiler_tool_enabled` probes availability before checking its explicit tool
policy and retains suppressed lookup output and original lookup status. FFmpeg
and ORT retain the historical off spellings `0`, `false`, `FALSE`, `no`, `NO`,
`off`, `OFF`; their `False` input still enables the optional tool. Other cache
readers retain their established default handling, including `False` as disabled.

`wheelhouse-manifest.sh` owns sorted, null-safe regular-file discovery and binary
hash-separator normalization. The host library retains strict failure behavior;
Torch diagnostics retain their best-effort behavior and separate count/log policy.
Both imports require the canonical companion; Torch's early image COPY carries it.
An independent three-file golden checks complete manifest bytes and hashes, beside
original/current failure receipts and the existing host/image agreement check.

### Native GCC system paths and test dependencies

`01-core/native-gcc-system-paths.sh` owns the system include and library exports
used by Torch setup and the native GCC shell profile. Torch retains directory
discovery. The generated profile imports the same helper when sourced, so flags
set after image construction still precede the appended paths. Repeated sourcing,
empty values and the existing `_idaf` side effect retain their original behavior.
Android and Torch copy the helper before use; the package image's full core copy
also includes it. Independent environment receipts cover both callers.

The FFmpeg TensorFlow fixture reads the canonical `is_truthy` function instead of
maintaining its own implementation. Its expected flags and default-off assertions
remain independent. Chain lifecycle fixtures share process cleanup and archive
construction, while retaining explicit assertions for leaf termination, retained
and removed run IDs, symlinks and foreign files. Cleanup tracks fixture processes
without relying on the production subtree terminator under test.

### Cross-chain verification help

Cross-chain and verification-wrapper help share architecture rows through
`runtime_usage_chain_arches` and the repository row through `runtime_usage_row`.
The `chain` profile preserves the original arch-list wording and column widths.
The verification wrapper loads the function-only renderer inside `usage`; normal
forwarding does not depend on it or initialize build helpers. Its independent
receipts cover full help bytes, a missing renderer, empty and multiline forwarded
arguments, describe mode and the child process's nonzero exit status.

### Optional linkers, installer services and cache removal

FFmpeg and ORT use the optional-tool predicate's explicit literal-false policy
for LLD: only `false` disables it. Values such as `0`, `FALSE`, `no` and `off`
retain their historical enabled behavior. Lookup still precedes the policy check;
lookup failure keeps its original status and suppresses diagnostics. Caller
compiler arguments and logs remain separate. Their offline suites share fixture
setup while retaining independent policy expectations and complete byte receipts.

The nerdctl installer shares its user-stack stop and rootful service actions
inside the installer file. Callers retain service guards, stop/start order,
logging, unit-list splitting and best-effort behavior. Offline fixtures exercise
actual service sections with stubbed commands; they never execute installation
or real service operations.

`_disk_guard_remove_slug` owns guarded, quiet removal and remaining-path evidence.
The in-stage trimmer stops at an undeletable slug; the chain protects it and keeps
looking. Both retain advisory removal-command failure and their original logs
and counters. Unit tests cover actual filesystem outcomes and independent caller
assertions, including empty-root refusal and strict-shell command failure.

### Host Python path policies

`platform.sh` owns `host_python_path` with explicit and derived profiles. Both
retain the ordered executable pins from `MEDIA_HOST_PYTHON`, `UV_PYTHON`,
`VIRTUAL_ENV` and `PYTHON_MAJOR_MINOR`, followed by PATH lookup. The canonical
cross-Python caller retains optional `PYTHON_VERSION` derivation; GStreamer's
fallback does not gain it and still prefers an existing `host_python_bin` override.
Inputs remain raw and are read when called. Each profile retains its original
trailing-newline and output-failure behavior. Both imports require the existing
platform companion rather than loading the broader cross environment or providing
a private fallback. Independent receipts cover pin order, failed lookups, version
policy, overrides, source guards and copied-companion failures.

### Artifact refusal, media dispatch and standalone downloads

`tag-naming.sh` owns the unsupported artifact-mode diagnostic in one private
helper. Platform and image-reference callers retain their own native/cross
branches and lazy access to their environment. Extracted test fixtures carry
the rejection helper so invalid-mode assertions still exercise its exact status
and stderr rather than an undefined-function error.

`smoke_native_dispatch` shares cross-target presence checking and calls the native
callback unconditionally when execution is appropriate. It introduces no local
variables that could shadow caller globals. FFmpeg's shared test-pattern encoder
and null decoder retain exact arguments and streams; callers retain codec policy,
rate and preset choices, the H264 interstitial success message and cleanup order.
Independent complete-section receipts cover tool calls, shell failure contexts,
global state and temporary files without running real media tools.

`source_toolchain_downloads` uses only the historical repository-core and installed
core candidates, in that order, and leaves a supplied `download_file` untouched.
The shared selector's `core-paths-only` mode excludes an adjacent downloads file.
Both standalone callers carry `bootstrap.sh` beside their entrypoint; SDK and
package copies refresh it and Android's flattened layout includes it. Torch's
`/usr/local/bin/vulkan.sh` also carries `vulkan-install.sh`. The bootstrap contains
function definitions and shell options; the downloads module's actual top-level
state remains global when selected. Source calls keep their original strict and
conditional failure behavior, and no private download fallback is restored.

### Numeric versions, guarded links and raw pin lookup

`version_has_numeric_parts` in `load-versions-env.sh` owns three- and four-part
numeric shape checks. Its constructed expression has no capture groups, preserving
`BASH_REMATCH`. It checks shape rather than version ranges or tool availability.
Callers retain their policies: GCC selects its fallback, the builder warns,
Dartdoc rejects invalid pins, and Rust appends the fourth part or selects its
existing fallback. The Rust version utility carries the canonical core loader
beside its existing logging companion.

`path_symlink_missing` checks destination presence and performs the caller's
link action. Source checks and basename calls stay in their original callers,
so a source disappearing after that check keeps its original link behavior.
GCC retains required `SUDO` and `ln -sfn`; Vulkan retains optional `SUDO` and `ln -s`. Expansion stays
lazy, including when a destination exists. Fresh per-file Toolchain mounts and
SDK copies carry the owner; Torch's full core copy refreshes it before use.

`load_raw_pin_if_empty` shares Android/Rust's raw lookup without sourcing pin data.
It retains all matching lines, quotes, whitespace, target export state and read
status, including the original command substitution handling of trailing newlines.
It does not replace the whole-file loader, whose parsing policy differs,
or Package's existing separate policy. The Android copy and Rust mount carry a
fresh owner even when their parent image contains an older loader.

`source_toolchain_required` accepts the required leaf, the action when it is
missing, lookup priority and optional expected function. Calls that name an
expected function validate it and preserve a selected file's nonzero status.
Calls that require only a file retain their historical result policy. Source transport
and required-loader calls remain unconditional so strict failures keep their
original effect. Missing cache helpers still exit; the ELF wrapper retains its
return policy. `bootstrap-import.sh` owns the initial bootstrap source and dispatcher check
at source scope. It returns failures explicitly, and each entrypoint retains its
exit or return policy; selected-leaf calls remain separate and unconditional.
Older bootstraps cannot hide a missing dispatcher in conditional source contexts. Tests cover missing files and exports, stale loaded guards,
partial definitions followed by failure, and complete copied entrypoints.

The tag and numeric suites share `stream-receipt-fixture.sh` for stream capture,
byte comparison, return markers and serialization. Their expected consumer data
remains separate and literal. A small contract suite checks NUL and trailing
newline bytes, nonzero capture status and mismatches beyond the initial bytes.

The initializer is carried beside both the entrypoint and `bootstrap.sh` in
standalone bundles and fresh per-stage copy/mount closures. It is sourced directly
rather than invoked through a function that an older bootstrap may not provide.
This shares the import policy without changing source scope or using `eval`.
