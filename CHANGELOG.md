# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-08-29 … 2026-09-07`](docs/changelog-archive-2026-09-07.md) ·
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.


## 2026-09-25 - MIGraphX links with MLIR off: upstream's stubs, backported

With HIP compiling (entry below), the build reached `migraphx_gpu.dll` and stopped
at the link: `is_module_fusible`, `adjust_param_shapes`, `dump_mlir_to_file` and
`dump_mlir_to_mxr` were undefined. At `rocm-10.0`, `mlir.cpp` declares them for
every build but defines them only when `MIGRAPHX_MLIR` is set, and the rocm lane
builds MLIR off because TheRock ships no rocMLIR. Upstream fixed this on `develop`
in 5a80dc91ba (#5154, 2026-08-24), after the tag.

`windows/scripts/patches/migraphx/001-mlir-off-stubs.patch` carries that commit's
four definitions verbatim. Their signatures were checked against the pinned
`mlir.hpp`. Phase 1 git-inits the tarball and applies the patch with
`Invoke-SourcePatch`, and `Dockerfile.rocm-migraphx` mounts the directory.
`upstream-windows-patches.md` lists it as fixed upstream, to retire on a bump.

`Test-PatchesApplyClean.ps1` now maps `migraphx` to `MIGRAPHX_WINDOWS_COMMIT`.
That is a commit, and `git clone --branch` takes only names, so a 40-hex ref
clones through `--revision` (git 2.49 or later). A `-PatchRoot` holding a single
patch no longer dies on `.Count`. The whole catalogue passes, 20 of 20.
`Rocm.Migraphx.Tests.ps1` covers placement, the patch and the mount: 54 pass.

## 2026-09-25 - MIGraphX's HIP code compiles against MSVC 14.51's `<cmath>`

With the configure through, every HIP source in `migraphx_device` failed (114
errors): `__device__ function 'isgreater' cannot overload __host__ __device__
function 'isgreater'`, with the previous declaration at MSVC 14.51's
`cmath:688`, `_CLANG_BUILTIN2(isgreater)`. Under clang that `<cmath>` defines the
six two-argument comparisons as `constexpr` builtin wrappers. HIP makes those
`__host__ __device__`, so clang's HIP headers can no longer add their `__device__`
versions. Upstream MIGraphX's Windows GPU job avoids this by building with VS 2022
17.13.

The owner chose to keep the image's own clang/MSVC 14.51 toolchain. The first
try, `-Xclang -fno-cuda-host-device-constexpr`, cleared all 114 errors but broke
device code instead (`reference to __host__ function 'operator unsigned int'`,
`std::integral_constant` at `xtr1common:34`). It was dropped before any push.

`Write-HipMsvcCmathOverlay` now writes an `-isystem` directory ahead of clang's
resource dir. The wrapper includes both headers with `<>`, so the overlay reaches
them. Each overlay header renames those six names, `#include_next`s the untouched
original and restores them, so device code calls MSVC's builtin versions. No
TheRock file is copied or edited. The flag is inert for non-HIP sources, which
never include these headers. `Rocm.Migraphx.Tests.ps1` covers the overlay;
51 cases pass.

## 2026-09-25 - MIGraphX takes TheRock's nlohmann_json through a natvis shim

With its own rocm-cmake (entry below), MIGraphX got past
`rocm_add_version_resource`, then stopped at `src/CMakeLists.txt:389`:
`Cannot find source file: C:/TheRock/build/nlohmann_json.natvis`. TheRock's
nlohmann_json 3.12.0 was installed by an MSVC-style build. Its exported target
therefore lists `<prefix>/nlohmann_json.natvis`, a debugger visualizer, as an
interface source, and TheRock's dist does not carry that root-level file. It was
the only missing source.

`Write-NlohmannJsonConfigShim` writes a two-file package into the deps prefix:
- The config includes TheRock's own config by absolute path, then clears
  `INTERFACE_SOURCES` on `nlohmann_json::nlohmann_json`.
- The version file includes TheRock's.

`nlohmann_json_DIR` points at the shim. Headers, version and the staged licence
notice all stay TheRock's. `Rocm.Migraphx.Tests.ps1` covers the shim's content,
its refusal when TheRock lacks the package, and the new configure argument.

## 2026-09-25 - MIGraphX builds with its own rocm-cmake pin

The rocm chain got through LiteRT (1:17:33), TVM (2:55:07) and the media merge
(42:20), then stopped in `rocm-migraphx` at the MIGraphX configure:
`src/CMakeLists.txt:184: Unknown CMake command "rocm_add_version_resource"`.
MIGraphX `rocm-10.0` calls that function in five CMakeLists, and rocm-cmake added
it in 33541cd51f ("Add versioning for Windows", 2026-04-17). MIGraphX pins
`ROCm/rocm-cmake@6a7c5b73` in its own `requirements.txt` (6 commits past it). The
build took rocm-cmake from TheRock instead, and every TheRock tag points at
10155d7272, 4 commits before it.

Phase 2 of `Build-MigraphxFromSource.ps1` now does three things:
- It reads the commit from the pinned MIGraphX tree's `requirements.txt`
  (`Get-MigraphxRocmCmakeCommit`, which accepts only a 40-hex id).
- It fetches exactly that commit (`Save-GitCommitSource`). git verifies every
  object against the id and HEAD is re-read.
- It installs rocm-cmake into the deps prefix, which precedes TheRock on
  `CMAKE_PREFIX_PATH`.

MIGraphX does `find_package(ROCmCMakeBuildTools REQUIRED)`, so it now finds this
copy. The owner chose deriving it over a new `versions.env` pin: `versions.env` is
baked into `Dockerfile.base`, so a pin there would re-key the whole Windows chain,
while this change re-keys only the MIGraphX stage. It also makes a MIGraphX bump
carry its own rocm-cmake. `Rocm.Migraphx.Tests.ps1` covers the parse, both
refusals, the parameter guard, and where phase 2 stages it.
`docs/windows-rocm.md` § Supply chain records the exception.

## 2026-09-25 - `BACKLOG.md`: every known image gap, measured

The root `BACKLOG.md`, in the agentic loop's `- [ ]` / `- [b]` format, now lists
every gap in `:latest`, `:winamd64` and the `:winarm64` bundle that a consumer
hits or works around. There are CON7–CON33, grouped by image, each with its
evidence and what closes it. CON7–CON10 moved there from
`docs/refactoring-backlog.md`, which now points at it.

**Sources.** Nine consumers and this hub's own docs were swept for image notes and
workarounds. Each Linux candidate was then measured in `:latest` (`ec4bb68b`,
amd64, uid 1001, through the entrypoint). Windows and arm64 items cite runs and
hub documents.

**Found:**
- **CON14: a stale stage.** API 37 was added to source on 2026-09-18, but the
  image built on 2026-09-22 has no `ANDROID_EXTRA_*` ENV and only
  `platforms/android-36`.
- **CON17:** the image's clang has no libFuzzer runtime (`llvm-cross.sh:201`),
  which breaks WebDavClient's atheris build.
- **CON15:** LLVM 21 `clang-tidy`/`llvm-profdata`/`llvm-cov`/`ld.lld` sit first on
  PATH next to clang 23.
- **CON12:** the published `:winamd64` builds OpenCV/GenAI against an ONNX
  Runtime that is not the chain's.

**Closed by the measurement.** Eleven gaps that consumers still describe turned out
closed. Among them: `CARGO_HOME` ownership, rustup, wasm32,
`GSTREAMER_ROOT_ANDROID`, and a second ONNX Runtime in `/opt/opencv5/lib` that is
the chain build, byte for byte. `BACKLOG.md` lists all eleven so nobody files them
again. `docs/riscv64-rva23-baseline.md`'s pointer for the
TVM/IREE RVV codegen item now names CON24, and `docs/INDEX.md` lists the file.

## 2026-09-25 - The fleet calls this hub at `@develop`, not `@main`

Owner directive. Work lands on `develop`. `main` is a release branch that has
lagged it since 2026-09-16, and its `versions.env` still sets
`CI_IMAGE_LINUX_TAG=latest-cross`. The composite actions read that file at the ref
they were called at. So every consumer lane pulled `:latest-cross`, which no
release moves any more, and a Linux image fix such as CON7 would never have
reached one. Both tags are one GHCR version today, so nothing changes in what CI
runs until the next publish.

- **In the hub:** `prepare-windows-container-host` now calls its three sub-actions
  at `@develop`, and the reusable workflows call their 15 action references at
  `@develop`. `lint-gates.yml` checks the tooling out at `ref: develop`, and the
  consumer registry's hub entry now reads `develop`.
- **Docs and templates:** AGENTS.md's tag note, `.github/actions/README.md`, six
  docs pages and `shared/templates/AGENTS.md.template` now say `@develop`.
  `adopting-in-a-new-project.md` § 6 says why.
- **In the consumers:** 110 references across eight repositories move in their
  own commits.
- **What this means for `:latest-cross`:** it is deletable once it is a GHCR
  version of its own. `python-ci.md` notes that OrchestrANT and WebDavClient no
  longer wait for `main` before splitting their `amd64-arm64` workflow.

## 2026-09-24 - Backlog: four image gaps the consumer lanes hit (CON7–CON10)

`docs/refactoring-backlog.md` gains two arm64 GCC gaps and two Windows LLVM gaps. Each
cites the run that showed it and says what closes it. CON7 (no libsanitizer in the
arm64 GCC) is fixed in source by e2de5852 and waits only for a published image. CON8
(arm64 GCC configures cannot find libX11) comes with a hypothesis and the check that
decides it. CON9 (`clang_rt.profile`) and CON10 (clang-tidy) are the two components
the patched Windows LLVM does not build. No code changed.

## 2026-09-24 - ONNX Runtime GenAI is configured without its own tests (`ENABLE_TESTS=OFF`)

With FFmpeg fixed, the rocm chain got through OpenCV (25:36) and Hailo (8:09), then failed in
`media-core-built` at ONNX Runtime GenAI v0.15.2: `unit_tests.exe` would not link
(`undefined symbol: Generators::Log`, `Generators::g_log`, `SetLogBool`, `GetEnv`). GenAI
gates `test\` on its own `ENABLE_TESTS` option (default ON) and ignores the `BUILD_TESTING=OFF`
this script already passed. Its `unit_tests` links the shared `onnxruntime-genai` and uses
internals that DLL does not export. Only the CUDA variant, which every earlier chain run built,
compiles those sources into the test itself, so the rocm lane's CPU build was the first to hit
it. Nothing in the chain runs GenAI's tests, so `Build-OnnxGenaiFromSource.ps1` now passes
`-DENABLE_TESTS=OFF` on every lane. That also drops the CUDA kernel tests from the CUDA
lanes' build time. `SourceBuild.GenaiOrt.Tests.ps1` pins the flag, and its case fails with
the flag removed.

## 2026-09-24 - `lib/compiler-llvm-tools.sh`: the LLVM tools of the compiler that built a tree

BeschleunigerBallett's coverage lane failed with `error: no profile can be merged`: its
`build-coverage-llvm.sh` calls this hub's `coverage.sh`, which runs `llvm-profdata` and
`llvm-cov` by bare name, and PATH's copies are an older LLVM than the image's clang.
AccelerANTgine had hit and fixed the same thing locally (`compiler_llvm_tool` and
`use_compiler_llvm_tools` in its `scripts/linux/ci-common.sh`). With a second consumer
needing them, both functions move up unchanged into `linux/scripts/lib/compiler-llvm-tools.sh`.
`test-compiler-llvm-tools.sh` covers them with two fake LLVM installs (the tree's compiler,
and a different `clang++` first on PATH): 6 assertions. Three new mutations bite, family
`compiler-llvm-tools`. `docs/shared-script-libraries.md` lists the library and describes it.
The consumers switch to it with their next hub pin.

## 2026-09-24 - makedef hands llvm-nm its object list as @file: xargs died in the rocm lane's environment

The refusal below paid off on the first rerun. The rocm FFmpeg stage stopped at
`makedef: 'C:/llvm-patched/bin/llvm-nm.exe' listed no global symbol in 116 object(s)`, and
the captured stderr was not llvm-nm's at all:
`assertion "bc_ctl.arg_max >= LINE_MAX" failed: file "xargs.c", line 512`. Git for Windows'
xargs subtracts the whole environment block from the ~32 000-character command-line limit.
The rocm lane's environment is large enough (hundreds of version variables, among them
the long `TORCH_ROCM_*` wheel URLs) that nothing was left, so xargs aborted before it ran
llvm-nm. The amd64 lane's smaller environment stayed under the line, which is why the same
FFmpeg linked there four times. The previous `2>/dev/null` had turned the abort into an
empty export list.

`makedef` no longer uses xargs. It writes the object list, one per line, to
`<version script>.nm-objects` and runs `llvm-nm --defined-only -g @<that file>`, so no
command line carries the list. LLVM tools expand response files, and the real llvm-nm 23.1.0
read it and exported exactly the `av*` symbols from clang's COFF objects. Reproduced on this
host with Git for Windows' shell: past ~33 KB of environment, the xargs version fails
(`xargs: environment is too large for exec`) at 33, 41 and 50 KB, and the `@file` version
passes at all three. `test-ffmpeg-makedef.sh` asserts one llvm-nm run with one `@file`
argument and no object on its command line (19/19). The new
`ffmpeg-makedef.objects-by-response-file` mutation, which puts xargs back, bites.

## 2026-09-24 - FFmpeg's makedef refuses an empty export list and runs the compiler's own llvm-nm

The rocm chain (hub a943dd94) built base, the ROCm SDK layer, the patched toolchain and ONNX
Runtime, then failed FFmpeg n9.0.2's `make + install`: `swresample-7.dll` and `swscale-10.dll`
could not resolve a single libavutil symbol (`av_mallocz`, `av_log`, `av_channel_layout_*`).
`avutil-61.dll` had linked, but with an empty export list. The replacement
`windows/scripts/patches/ffmpeg/makedef` writes each DLL's `.def` from an `llvm-nm` dump.
It sent `llvm-nm`'s stderr to `/dev/null` and wrote `EXPORTS` with nothing under it
whenever the dump came back empty. Its own header records the same symptom from the
replacement before it. The same FFmpeg linked four times on the plain amd64 lane
(09-21, 09-22). The rocm lane adds AMF and Vulkan, and the FFmpeg script puts scoop's shims
first on the PATH its Git-bash `make` sees, so a bare `llvm-nm` is not necessarily the
compiler's.

- `makedef` keeps `llvm-nm`'s stderr in `<version script>.nm-errors`. It exits 1, naming the
  tool, the object count and that stderr, when the dump is empty or when no symbol matches
  the version script's globs. Nothing reaches the `.def` on either refusal.
- It runs `$LLVM_NM`, with bare `llvm-nm` only as the fallback. `Build-FfmpegFromSource.ps1`
  sets it on the clang-cl toolchain to the `llvm-nm.exe` beside the `clang-cl` that this
  PATH resolves (`Get-FfmpegLlvmNm`), and throws if there is none.

`linux/scripts/tests/test-ffmpeg-makedef.sh` drives `makedef` with a stub `llvm-nm` whose
"objects" are nm-format text, so it runs on any host. It passes 15/15 here, and 11/15 fail
against the old script, which ignored `LLVM_NM` and on a host with no `llvm-nm` wrote an empty
`EXPORTS` list: the rocm signature, reproduced. The four new mutations bite
(`ffmpeg-makedef.*`, a family declared in `gate-proofs.allow`). `SourceBuild.FfmpegRocm.Tests.ps1`
covers `Get-FfmpegLlvmNm`; its throw case fails when the throw is removed. Against real COFF
objects from clang 23.1.0 and its llvm-nm, in the Linux image, `makedef` exported exactly the
`av*` symbols and refused an nm that could not read them. What emptied the rocm dump is not
pinned yet: the next rocm run either links with the compiler's own `llvm-nm`, or stops at
`makedef` with that tool's own error.

## 2026-09-24 - The WebDAV client installs from its commit archive, not through git

BeschleunigerBallett's Windows lane (run 36020442781) died before its build, inside the
early WebDAV download. `uv pip install git+https://github.com/Kataglyphis/WebDavClient@<pin>`
makes uv run `git submodule update --recursive --init`. The pinned commit still carries
`ExternalLib/Kataglyphis-ContainerHub`, whose nested DocumANTation and LaTeX submodules
overflow Git for Windows' gitdir limit inside uv's cache: `fatal: '$GIT_DIR' too big`. A
shorter cache root cannot help, because the limit is on the gitdir chain.

Both halves now install
`kataglyphis_webdavclient @ https://github.com/Kataglyphis/WebDavClient/archive/<pin>.tar.gz`:
the same commit's tree, with no git and no submodules. The package needs nothing from
them. The Windows half builds that string in one function, `Get-WebDavClientRequirement`,
which refuses anything but a full 40-character commit SHA. Its Pester cases pin the form
and the refusal (3/3). `webdav-download.sh` uses the same form. Checked on this host: an
archive install of the pinned commit into a fresh venv imports `WebDavClient`, which has
`download_all_files_iterative`.

`versions.env`'s comment above `WEBDAVCLIENT_REF` still says "installed from git". It
moves with the next change to that file, because any byte changed there rebuilds the
Windows chain from `Dockerfile.base`'s `COPY versions.env` onward.

## 2026-09-24 - The pre-commit hook checks the derived doc numbers when their inputs move

7482747c added two consumer-inventory mutations and left `docs/code-quality-tooling.md`
quoting 1332 entries. The hook said OK. CI's preflight then failed `test-doc-numbers.sh`,
and every `doc-numbers.*` mutation in all four shards reported a baseline that already
failed (run 36022089345). 2bba2833 fixed the digit. The hook now runs
`test-doc-numbers.sh` whenever `docs/scripts/mutations.json`, the hook itself,
`docs/code-quality-tooling.md`, `docs/cross-build-verification.md` or `AGENTS.md` is
staged, and it refuses the commit with the `--update` command to run. It does not run
when none of them is staged. The new block sits after the doc-duplication gate, so the
two hook spans the docs quote do not move. `test-precommit-hook.sh` gains the abort case
and the skip case (42 assertions), and three new mutations bite:
`pre-commit.doc-numbers-aborts`, `pre-commit.doc-numbers-trigger-names-the-manifest` and
`pre-commit.doc-numbers-only-when-an-input-moves`. The manifest now holds 1337 entries.

## 2026-09-24 - `Invoke-WithAsanOptions -Options ''` adds nothing instead of refusing to bind

`Invoke-WithRuntimePath` takes an optional `[string]$AsanOptions` and hands it to
`Invoke-WithAsanOptions`, whose `-Options` was a mandatory `[string]`. PowerShell refuses
an empty string there, so `Invoke-WithRuntimePath -AsanOptions ''` could never run.
AccelerANTgine's `Start-Windows.ps1` passes exactly that for its full-application runs, to
opt out of the test-binary defaults. Its Windows lane got past its container build for the
first time in weeks (run 36020001871) and then stopped at the CLI version check: `Cannot bind
argument to parameter 'Options' because it is an empty string`. `-Options` now takes
`[AllowEmptyString()]`, and an empty value runs the block with `ASAN_OPTIONS` exactly as the
caller had it: nothing prepended, not even a separator. `Testing.Asan.Tests.ps1` has both
shapes; both cases fail against the old module with that same message.

## 2026-09-24 - The consumer inventory counts a consumer's own modules as its own

`verify_consumer_inventory.py` failed its first run after the fleet renames (36019965353):
`OxidANT names a hub path that does not exist: scripts/windows/New-ReleaseArchive.ps1:18 ->
WindowsOrtPayload.Common.psm1`. That module is OxidANT's own, in `scripts/windows/modules/`,
where `Resolve-BuildModule` falls back to it. It dates from 2026-09-23 and is the first local
module whose name starts with `Windows`. The gate assumed every `Windows*` name was the hub's.
`dangling_modules` now skips a name the consumer tracks as a `.psm1` outside its test trees
(a fixture's `.psm1` exists to be absent and still counts as dangling).
`test-consumer-inventory.sh` covers both. Two new mutations,
`consumer-inventory.own-module-is-not-dangling` and `consumer-inventory.fixture-psm1-is-not-own`,
bite. Against the live fleet: CONSUMER INVENTORY OK, 0 dangling.

## 2026-09-24 - Workflow names follow the fleet convention; `arches` for the Python Linux lane

The owner set one naming rule for the workflows of every repository in the family:
kebab-case files, one file per platform and arch for a build, display names
`<Platform> <Arch> · <what>` (or `<Area> · <what>`). The hub goes first. The rule and
the fleet's rename table:
[`adopting-in-a-new-project.md` § Workflow file names and display names](docs/adopting-in-a-new-project.md#workflow-file-names-and-display-names).

The consumer renames cleared most of the workflow-convention backlog, so
`workflow-conventions.allow` drops twelve CENSUS rows that now measure zero
(OmniAccelerANT, OxidANT and AccelerANTgine all three checks, jotrockenmitlocken
job-timeout and permissions, ANThology job-timeout) and lowers BeschleunigerBallett's
job-timeout 15 → 13 and permissions 12 → 11, each measured with
`verify_workflow_conventions.py` on the renamed tree. OrchestrANT keeps its 2 until its
Linux lane splits on `arches`. `test-workflow-lint.sh`'s ramp cases graded a fixture
named OxidANT against the REAL allow file, so they passed only while the real OxidANT
still had a backlog; they now carry their own census. `third_party/DocumANTation` moves
to `2e861fc`, its own rename (`docs.yml`, `linux-x64.yml`).

- **Renamed.** `ubuntu26.04.yml` → `linux-x64.yml` ("Linux x64 · preflight + mutation
  gate") and `windows-scripts.yml` → `windows-x64.yml` ("Windows x64 · script tests").
  Their concurrency groups follow the file (`linux-x64-…`, `windows-x64-…`), and
  `windows-x64.yml`'s path filter names itself. The README badge moved; a Windows x64
  badge is new.
- **Display names only.** `actions-selftest.yml` "Composite actions · self-test",
  `consumer-inventory.yml` "Consumers · inventory", `ghcr-cleanup.yml` "GHCR · cleanup",
  `llm-stack-serving.yml` "LLM stack · serving", `sbom.yml` "SBOM",
  `stale-docs-check.yml` "Docs · stale check" (its issue footer too; the issue is still
  found by its title).
- **The reusable workflows keep their FILE names**, because every consumer calls them
  at `@main`: `build-docs.yml` "Docs · build (reusable)", `lint-gates.yml` "Lint gates
  (reusable)", `python-ci-linux.yml` "Python CI · Linux (reusable)",
  `python-ci-windows.yml` "Python CI · Windows (reusable)", `submodule-pins.yml`
  "Submodule pins (reusable)". AGENTS.md now states that as a rule.
- **`python-ci-linux.yml` takes `arches`** (string, default `"x64 arm64"`), so
  OrchestrANT and WebDavClient can split into `linux-x64.yml` and `linux-arm64.yml`. The
  default runs both rows with the same job and artifact names as before. A new `plan`
  job builds the matrix and fails on an unknown, repeated or empty name; a static matrix
  cannot be filtered, because GitHub adds an excluded `include:` row back. Callers see
  one more check, `<job> / plan`.
  [`python-ci.md` § One arch per caller](docs/python-ci.md#one-arch-per-caller-the-arches-input).
- **Tests.** New `tests/test-reusable-linux-lane.sh` (33 assertions) runs the plan step
  itself: the default rows equal the old static matrix, one name gives one row, the
  refusals fire, and no row uses a `*-latest` label. That last one is needed because
  the labels now sit in a `run:` block, which the workflow-convention gate cannot read.
  Seven new mutations in a new family, `linux-lane` (declared in `gate-proofs.allow`), each
  seen biting; the manifest goes 1325 -> 1332. The three `mutations.ci-*` entries and
  `test-mutation-gate.sh` point at `linux-x64.yml`. `code-dupes.allow` gains two rows
  for the new suite's preamble, the same row the Windows lane's suite has.
- **Fleet references.** Hub prose that names a consumer workflow uses the new name, with
  the old one beside it where the text is dated: the `consumers.json` notes, the CENSUS
  reasons in `workflow-conventions.allow` (counts unchanged), `shellcheck-warnings.allow`,
  `code-quality-tooling.md`, `shared-script-libraries.md`, `dependency-updates.md`,
  `cross-build-verification.md`, `New-Archive.ps1`'s header, and
  `github-cli-pipeline-monitoring.md` (now `gh run list --workflow linux-x64.yml`).
  `ftp-deploys.md`'s 2026-09-09 table keeps its old names and line numbers as a dated
  record and points at the rename table. Left alone on purpose:
  `02-toolchain/rust/cargo_fmt_clippy.sh` quotes `rust_ubuntu26_04.yml:134-139` as a
  dated citation, and that file sits in `Dockerfile.toolchain`'s
  `COPY linux/scripts/02-toolchain/`, so a comment edit would re-key the toolchain stage.
- **For the consumers.** A split that adds caller files without a top-level
  `permissions:` raises that repo's `permissions` count above its CENSUS row, and its
  lint lane fails; give each new file its own block. `arches` reaches a caller only once
  this is on hub `main`.
- **What re-keys:** nothing. No `versions.env`, `01-core`, Dockerfile or other
  image-closure file changed.

## 2026-09-24 - Hailo: review fixes

A review of the entry below found a check that could be skipped, an old-path guarantee
that no test held, and docs claims that went further than the evidence.
`HAILO_NESTED_CACHE` behaves as it did. Under `HAILO_PYHAILORT_IPO=off` the install is
stricter; `upstream` warns as it always did.
[`hailo-support.md` § pyhailort](docs/hailo-support.md#pyhailort).

- **Under `off`, a failed install into `/opt/venv`, or no wheel at all, stops the
  build.** The installed-module check ran only inside `if uv pip install ...; then`, so a
  failed install only warned, the `RUN` stayed green, and an image could ship without
  pyhailort in `/opt/venv` while the docs called the check fatal. `install_pyhailort` now
  prints uv's own error and dies, naming `HAILO_PYHAILORT_IPO=upstream`, which keeps the
  old warning. `import hailo_platform` still only warns in both modes, and the gates
  table now says so. A run without `/opt/venv`, outside the image, still only stages the
  wheel.
- **Found on the way:** the `ls | head` that finds the wheel was unguarded under
  `pipefail`, so "no wheel" never reached its `return 0`: the build died with rc 2 and no
  message (shell-safety class 2). Guarded; no wheel is now an error under `off` and a
  warning under `upstream`.
- **The old nested build's `HOME` has a test.** The fake cmake recorded the `HOME` it ran
  with, and nothing read it. `off`, and `carry` without a launcher, now assert the
  caller's `HOME`, and `carry` the carrier. The carrier test's login file sets `PATH` and
  `SCCACHE_DIR` itself, which pins that the carrier's exports come after it.
- **Docs.** README and `failure-modes.md` tied a working pyhailort to a build date, but no
  image has this change yet, the arm64 import is untested, and an image built from
  `develop` that day still carries the stub. Both now name the switch and say the import
  only warns and is proven on amd64 only; `hailo-support.md` too. The Hailo `RUN`'s cache
  mounts are the chain's own on whichever arch `CROSS_BUILD_PLATFORM` names, so on the
  Jetson the old 10G cap could trim `sccache-arm64` too, not only `sccache-amd64` on the
  cross host: `build-cache-tiers.md` and the entry below are corrected. `hailo-support.md` § pyhailort
  now says the shipped module depends on floating `scikit-build-core>=0.10` and
  `pybind11>=2.13.6,<3` resolves from PyPI, which reach the image now that the module is
  real. Pinning them waits for the next planned `versions.env` re-key (an open question on
  that page). The entry below also gave `# noforward` as a reason for scikit-build-core,
  which was wrong: the Hailo `RUN` loads the image's `versions.env` and can read
  `PY_SCIKIT_BUILD_CORE_VERSION` today. Only pybind11 needs a new key.
- **`code-dupes.allow`:** two budgets go back up by one and two rows come back, all four
  as they were before 2026-09-20. `install_pyhailort` no longer holds the shingle
  `[ -n "S" ] || return N`, so the shingle falls from 7 owners to 6, under the idiom
  cutoff, and counts for those pairs again. No file in those pairs changed.
- **Tests.** `test-hailo-build.sh` 110 -> 139 assertions: the `HOME` each mode configures
  with, the login-file order, and `install_pyhailort` itself, run under `set -e` against a
  fake uv and a sandbox venv in both modes (installed, stub, failed install, failed import,
  no wheel, no venv). Six new mutations, each seen biting: `hailo.off-keeps-home`,
  `hailo.no-launcher-no-carrier`, `hailo.carrier-login-first`,
  `hailo.install-failure-fatal`, `hailo.install-no-wheel-fatal` and
  `hailo.install-no-wheel-guard`. All 36 `hailo.*` bite; the manifest goes 1252 -> 1258.
- **What re-keys:** the wrapper's Hailo `RUN` (`build-hailort.sh`), which the entry below
  already re-keys and no host has built yet. No `versions.env`, `01-core` or Dockerfile
  change.
- **Verified here:** on the Windows host, the suites that read the touched files (the two
  that fail, `test-version-snapshot` and `test-mutation-gate`, fail on the same assertions
  at the parent commit), all 36 `hailo.*` mutations, shellcheck and its warning ratchet,
  the hook's fast gates, the doc gates and the manifest's `--stale-check`. In the local
  amd64 image: `test-hailo-build.sh` as uid 1001 (139 passed) with the six new mutations
  biting there too, and `install_pyhailort` alone as root against the image's uv and
  `/opt/venv`, with a stub wheel, a truncated wheel and no wheel under both values, each
  with the exit code above. **Not verified:** a full `build-hailort.sh` run with these
  changes, and everything the entry below lists.

## 2026-09-24 - Hailo: the nested protobuf build is cached, pyhailort is a real module, the old build one switch away

arm64's Hailo `RUN` took 595 s in the 2026-09-22 lane, and 384 s of that was HailoRT's
configure: it builds a host protobuf (200 objects) under `env -i`, so the compiler cache
never reached it, while every other compile hit. The same diagnosis found that every image
shipped pyhailort as an empty module. Speedup item `hailo-arm64`, with its challenge's
corrections. **Owner decision: both options**, each default the fast or fixed path and the
old build one switch away.
[`hailo-support.md` § two switches](docs/hailo-support.md#the-nested-build-cache-and-pyhailort-two-switches).

- **`HAILO_NESTED_CACHE=carry|off`**, default `carry`. Only HailoRT's configure runs with
  `HOME` at a new directory in the `RUN`'s tmpfs. It mirrors the real `HOME`, and its
  `.bash_profile` runs the real login file, then exports every exported `SCCACHE_*` and
  `CCACHE_*` variable (not `versions.env`'s pins) and both CMake launchers, with the
  parent's own `sccache` and `ccache` first on `PATH`. `off` is the old uncached nested
  build. Measured natively on amd64: the configure took 9 s warm under `carry` and 32 s
  under `off`, and 243 requests reached the cache for the 200 nested objects.
- **Found on the way:** the clean `PATH` resolves the distro sccache 0.13 in `/bin` before
  the pinned 0.17. Its stats requests fail against the 0.17 server, and with no server
  running it starts a 0.13 one on the same socket. The carrier puts the parent's binaries
  first, so client and server are one binary.
- **The gate** (`hailo_assert_nested_cache_reached`). Under `carry` with a launcher it fails
  the build when the cache saw fewer requests than half the nested objects, or when the
  nested build left no `.ninja_log`; a spawner without the exact `env -i` line fails
  before the configure. Everything else warns. `USE_SCCACHE=0` keeps it armed on ccache;
  `USE_CCACHE=0` and `off` only warn. One `[CACHE] hailo/<phase>: secs= requests= hits=
  misses= launcher= cap=` line per phase: configure, build, pyhailort, libzmq, TAPPAS.
- **`HAILO_PYHAILORT_IPO=off|upstream`**, default `off`. Upstream forces IPO, and lld
  cannot link GCC's slim LTO objects, so every image carried a 4 KB `_pyhailort` without
  `PyInit__pyhailort`. `off` patches the forced IPO out of the cached source; the twelve
  sources compile at `compute_cpp_heavy_jobs` and cache; `hailo_check_pyext` checks the
  wheel's module and the installed one (ELF machine, a defined `PyInit__pyhailort`),
  fatal under `off` (a failed install too, since the review entry above), a warning under
  `upstream`, which rebuilds the old stub. Measured on amd64: a 1.7 MB module, and
  `import hailo_platform` works on Python 3.14.
- **Cache caps.** The Hailo `RUN` passes `Dockerfile.base`'s `SCCACHE_CACHE_SIZE=30G` and
  `CCACHE_MAXSIZE=30G`. The runtime image lost base's ENV, so `compiler-cache.sh`'s 10G
  applied there and trimmed the shared mount, which is the chain's own cache on the arch
  `CROSS_BUILD_PLATFORM` names: `sccache-amd64` on the cross host, `sccache-arm64` on the
  Jetson (corrected in the review entry above). The suite pins the pair to base.
- **Where the code is.** New `03-media/build/hailo/hailo-build-lib.sh` (the switches, the
  carrier, the counters, the gate, the IPO patch, the module check) and
  `probe-hailo-nested-cache.sh`, a seconds-long check inside an image: `off`, then `carry`
  cold and warm. `build-hailort.sh` routes its configure through the carrier and refuses a
  typo. `lib-orchestrator.sh` forwards both switches only when set and sources the lib;
  `build-cross-chain.sh` and both runtime orchestrators refuse a typo (exit 2) before
  they build anything.
- **Challenge corrections applied.** Both switches exist (the design had none for the cache
  fix, against the owner's rule); only exported variables are carried, so the unexported
  10G default never becomes a nested server's cap; the `HOME` redirect keeps the real
  `HOME`'s reads through the mirror; the gate follows the code's `USE_*` semantics; the
  cap scope is the build platform's arch, not only amd64 (the review entry above); the
  pybind build is capped; the twelve TUs are twelve.
- **Not done, and why.** The design's Unit 2: its stats fix is already in
  `compiler-cache.sh`, and moving the carrier into `01-core` would re-key the chain from
  the compiler stage. Unit 3, the opt-in cross fast path: the recorded `-EL` cross failure
  is not diagnosed, and the wrapper's final stage would need a restructure no BuildKit
  here could test. Pinning scikit-build-core and pybind11: `PY_PYBIND11_VERSION` is 3.x
  while pyhailort needs <3, so pybind11 needs a new `versions.env` key, which re-keys every
  stage from base; both are left for that re-key (the review entry above says why it now
  matters).
- **What re-keys:** per lane, the wrapper's Hailo `RUN` (`Dockerfile.torch` and the
  `hailo/` directory it COPYs) and the small `RUN` after it, which re-run on every lane
  anyway. No `versions.env`, `01-core` or other Dockerfile is touched, and the
  orchestrators and `lib-orchestrator.sh` are outside every image closure. The first run
  compiles the nested protobuf and the pybind11 sources cold, once.
- **Tests.** `tests/test-hailo-build.sh` (new, 110 assertions): the switches, the carrier
  through a real `env -i ... bash -l`, every variable `setup_ccache` exports, the configure
  wrapper against a fake cmake that spawns its nested build the same way, the gate's
  thresholds, the counters' anchoring, the IPO patch both ways, the module check on the
  shipped stub's symbol table, cap parity and the wiring. `t_stage_build_args` in
  `test-harness.sh` is now the one owner of the forwarding probe `test-web-lane-tools.sh`
  had, because `code-dupes` caught the second copy. 30 `hailo.*` mutations, all seen
  biting; `mutation-family:hailo` registered; `file-size.allow` +1 line for
  `build-cross-chain.sh`.
- **Verified here.** In the local amd64 image, as root with this tree's scripts at the
  image paths: `build-hailort.sh` end to end under `carry` cold and warm, `off`,
  `upstream` and `USE_SCCACHE=0` (every run exit 0, numbers in the doc), the probe as root
  and as uid 1001, and every suite as uid 1001 (the failures there are the baseline
  tree's too). On the Windows host: the touched suites, all 30 new mutations and the 25
  existing ones on touched files (11 of those in the image, where their suites run),
  shellcheck and its warning ratchet on every touched shell file, and the preflight gates.
  **Not verified:** arm64 under QEMU, where the saving is (estimated at 2.5 to 4 minutes per
  arm64 lane), the BuildKit `RUN` itself, the Jetson and the X100. The commands for the
  build host are in the doc.

## 2026-09-24 - The wrapper's wheelhouse: review fixes

A review of the entry below found that `RUNTIME_WHEELS_SOURCE=export` cannot run on
the cross host's `--no-push` chains, which that entry and the docs did not say, plus
three smaller gaps; rerunning its suites in the CI image found a fourth. No behaviour
changed: `image` and `export` do what they did.
[`linux-cross-builds.md` § The wrapper's wheelhouse](docs/linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries).

- **`export` is refused on a `--no-push` chain whose android tag is published**, which
  is every default or variant `--no-push` chain on the amd64 cross host. Such a chain
  threads no android pin, so `runtime_android_pin` resolves the published tag's
  registry digest, and this run's android layout never has it. The arch stops at the
  runtime lane, before its base build, with both digests named; the remedy is
  `RUNTIME_WHEELS_SOURCE=image`. `failure-modes.md` had suggested re-exporting the
  layout from the tag the lane names, which would have switched the package build to
  the published android as well; it now says never. Making `export` read this run's
  tag there would give up "the same image as `image` mode", so that is left to the
  owner. The same resolution means `image` mode on such a chain builds the venv from
  the PUBLISHED android's wheels while the package copies from this run's layout. That
  predates the knob and is unchanged; it is now documented and a test pins it.
- **The A/B runs through the chain.** The runtime lane's disk watch, whose mid-lane
  prune is the suspected eviction, runs only in `build-cross-chain.sh`, so the
  standalone `build-runtime-manifest.sh` A/B could not reproduce the wait. The primary
  A/B is now `CROSS_LOCAL_CONTEXT_HANDOFF=0 RUNTIME_WHEELS_SOURCE=<m>
  build-cross-chain.sh --only runtime --no-push`, and the standalone run is a
  mechanism check only. An arch counts only when its image-mode run shows the
  `wheels-source` extraction. The runtime lane writes no stage log, so the recipe
  greps the tee'd transcript, not a `runtime.log` that never existed.
- **Tests.** `test-runtime-wheels-source.sh` (91 -> 101 assertions) checks every
  `[runtime-timing]` step in both modes, and the published-tag `--no-push` case:
  `export` refuses whether or not the registry's copy was pulled, and `image` mounts
  the registry's digest. The shared nerdctl stub answers `image inspect` per ref. Two
  new mutations, both seen biting: `wheels-source.timed-steps` (unwrapping the
  wrapper step's timer used to survive) and `wheels-source.nopush-published-ref`.
- **Both wheels suites are hermetic.** In the CI image they failed 7 of 91 and 5 of
  21 assertions, at 736dea8a too: the image exports `ONNX_PACKAGE=onnxruntime` and
  `PYTORCH_EXTRA=pytorch-cpu`, which the wrapper forwards as operator pins.
  `rw_hermetic_env` (in `runtime-wheels-fixtures.sh`) now clears what the wrapper path
  and the fixtures read before any case sets its own; an exported `ENABLE_NVIDIA=true`,
  `RUNTIME_NO_CACHE=1` or `NERDCTL_BIN` no longer decides a case either. The
  dead-function census counts the new helper (508 -> 509 in `code-quality-tooling.md`).
- **Two stale hook-span references on this branch**, both fixed on `develop` already
  and repeated here verbatim so this commit could pass the hook:
  `cross-build-verification.md` quoted the staged-shell block as `:101-118` (it is
  `:102-119` since 57bec177), and the two `pre-commit.doc-span-*` mutations searched
  for the old spans (as 1b941556 did). The Windows-host floor fix for
  `verify_doc_links.py` came over from `develop`'s 5a1648d8 as its own commit, de8aed49.
- **What re-keys**, correcting the entry below: `Dockerfile.package` COPYs `01-core`
  whole (`:372`), so the package image re-keys from that COPY on, its setup RUNs and
  `wrapper-smoke` included. That is free on a full chain, where android changes
  anyway, and one package rebuild per arch on a runtime-only rerun with an unchanged
  android. This entry's own code edit is one comment in `01-core/runtime-build-fns.sh`
  (it said the pin is always empty under `--no-push`): the same re-key set as the
  entry below, and nothing more while no host has built that entry.
- **Verified here:** on the Windows host, both wheels suites (also under a hostile
  exported env), all 23 `wheels-source.*` mutations, the whole manifest's
  `--stale-check`, `build-cross-chain.sh --dry-run` of the new A/B command in both
  modes (it hands the lane `--skip-manifest` and no `--push`), and the helper's dry
  run showing `export` naming the registry digest; in the local `:latest-cross` image,
  the touched suites green. **Not verified:** no BuildKit ran, so neither the refusal
  against a real `nerdctl save` layout nor the chain-driven A/B has run.

## 2026-09-24 - The wrapper's wheelhouse: `RUNTIME_WHEELS_SOURCE=image|export`, image the default

In the 2026-09-22 lane the torch RUN waited 161 / 565 / 661 s (amd64 / arm64 /
riscv64) before `uv venv` wrote its first file; on 2026-09-21 it waited 96 / 1 / 2 s
with the same scripts. The likely cause: to bind-mount `/opt/wheels` (about 0.1 GB)
BuildKit must hold and checksum the whole android snapshot (about 12.7 GB), and pulls
it again when something evicted it after the package build. Inferred, not proven.
**Owner decision: both options**, the current one the default until a host lane
confirms the other. Speedup item `uv-wait`, with its challenge's corrections. How to
pick: [`linux-cross-builds.md` § The wrapper's wheelhouse](docs/linux-cross-builds.md#the-wrappers-wheelhouse-two-deliveries).

- **`RUNTIME_WHEELS_SOURCE=auto|image|export`**, default `auto` = `image`. `image` is
  the old delivery, byte for byte: the wrapper's argument vector is identical to the
  pre-change code over 32 combinations of pin, host infix, variant,
  `ARTIFACT_CONTEXT_ROOT` and GPU. `export` builds only `Dockerfile.torch`'s new
  `wheels-export` stage (`--output type=local`) before each arch's base and package
  builds. It copies `/opt/wheels` out of the image image mode would mount, seals it
  with a sha256 manifest, and the wrapper mounts that directory
  (`WHEELS_IMAGE=runtime_wheels`). Any other value exits 2, at the chain's start too.
- **Challenge corrections applied.** The export reads the ref image mode reads
  (`runtime_wheels_image_ref`, moved out of `append_wrapper_build_args`), not the
  package's `ARTIFACT_IMAGE`, so an empty pin, a custom prefix or
  `--artifact-build-mode native` cannot switch the source. Under `ARTIFACT_CONTEXT_ROOT`
  it reads the android OCI layout only when its digest equals the containerd image's,
  otherwise it stops (always, on a `--no-push` chain whose android tag is published:
  the review entry above). The staging root is minted in the main shell, so `--push-all`
  works. The wrapper re-checks the whole manifest; there is no fallback between
  modes. `image` needs no `ARTIFACT_CONTEXT_ROOT` refusal: it is the old code for both
  lane modes, so the design's separate `containerd` value is gone.
- **Diagnostics in both modes**: `[runtime-timing]` per step, `[wheels]` for the
  export, `[torch-run] start` as the torch RUN's first statement, `[torch-venv]
  wheelhouse` (a content digest equal to the host's) and `[torch-venv:timing]` after
  every `setup-torch-venv.sh` step. [The measurement recipe and the A/B](docs/cross-build-verification.md#measuring-the-torch-runs-wait-before-uv-venv).
- **Where the code is.** `linux/scripts/lib-runtime-wheels.sh` (new, outside every
  image closure, loaded by `lib-orchestrator.sh`) holds the modes, the export, the
  seal and the arch loop both runtime orchestrators now run. `01-core/runtime-build-fns.sh`
  gains the resolver, the `image` arm, a two-way branch in `append_wrapper_build_args`
  and `_runtime_timed`: the wrapper's arguments are built there, so this part could
  not live elsewhere.
- **What re-keys.** `01-core` is mounted whole by `Dockerfile.toolchain`'s verify
  layer and COPY'd whole after it, so the next full chain rebuilds the compiler image
  from that layer on (its GCC and LLVM layers still hit), then sdk, media and android
  for every arch on warm compiler caches; the variant chains' `Dockerfile.nvidia` and
  `Dockerfile.amd` RUNs likewise. That rebuild is ALREADY due: the published
  `cross-compiler-amd64` dates from 2026-09-22 12:15Z, and 57bec177 and d8c31072
  (2026-09-23) changed `01-core` and `versions.env`, which re-keys from base. So this
  adds nothing to the next chain, if it lands before that chain. Per lane:
  `Dockerfile.torch` (the torch RUN, hailo and final) and `setup-torch-venv.sh`, which
  re-run every lane anyway. `Dockerfile.package` itself is untouched, but it COPYs
  `01-core` whole, so the package re-keys from that COPY on (the review entry above).
- **Tests.** `tests/test-runtime-wheels-source.sh` (new, 91 assertions, hermetic)
  shares `tests/runtime-wheels-fixtures.sh` with `test-runtime-wheels-context.sh`,
  which now extracts the moved helpers; `test-env-contract.sh` counts the lib as the
  knob's consumer. 21 `wheels-source.*` mutations, each seen biting;
  `mutation-family:wheels-source` registered. Two `code-dupes.allow` rows (the in-RUN
  digest twin, and a self-pair that shrank because of the new files) and one
  `file-size.allow` row (+2 lines in `build-cross-chain.sh`).
- **Verified here** (Windows host): the suites above, dry runs of
  `build-runtime-artifacts.sh` in both modes and with a typo, and the chain's typo
  refusal. **Not verified:** no BuildKit ran. The `wheels-export` build, the named
  directory context on the host's rootless OCI worker (0.31.2), the layout digest
  check against real `nerdctl save` output, and whether `export` removes the wait at
  all are for the host A/B in the recipe above.

## 2026-09-24 - A mutation-gate timeout on a Windows host is a verdict, not a crash

- **`verify_mutations.py`**: `_run_test` killed a timed-out test's tree with `os.killpg`,
  which a Windows python does not have, so the first slow test there ended the whole gate
  in an `AttributeError` with no verdicts (seen on the pre-push gate of 2026-09-24, on
  `test-web-lane-tools.sh` under parallel load). Without process groups it now runs
  `taskkill /T` on the shell's tree. On Linux nothing changes.
- **`test-mutation-gate.sh`**: the timeout case asserts the verdict and the absence of a
  traceback on every host; only its grandchild check stays POSIX-only. Measured on Git
  Bash: fails before the fix, passes after (98/98 with `MSYS=winsymlinks:nativestrict`,
  which the suite's symlink cases need there). No mutation entry: CI's Linux python has
  `os.killpg`, so a mutant of the Windows branch could not bite there.


## 2026-09-24 - The doc-links git-free floor works under a Windows python

- **`verify_doc_links.py`**: `_static_ignores` compared `str(path)` with the `/`-spelled
  `UNTRACKED_OUTPUT` rows, and a Windows python spells a relative path with `\`, so
  without git the floor excluded nothing there. It matches the POSIX form and still
  returns the caller's `str()`; on Linux nothing changes. `test-doc-links.sh` said so on
  a Windows host (`the floor skips 0 of 3 output paths`), which failed the commit hook
  whenever it sampled a doc-links entry there. That suite also needs a one-word
  `PREFLIGHT_PYTHON` (it quotes the value) and `PYTHONUTF8=1` on such a host.


## 2026-09-23 - The preflight timeout was a regression from 57bec177: fix11 is fast again, the mutation gate is sharded, and four hidden reds are fixed

**This was our regression.** On `a7ccc896` the Ubuntu 26.04 `preflight` job was killed
at its 45-minute timeout inside the mutation gate. `57bec177` had made fix11 run one awk
pass over its corpus per rule (~50 per gate run), and `test-critical-fixes.sh` ran the
whole gate once or twice per knocked-out row: the suite went from 4.4 s to 45-59 s on the
runner, and its 68 mutation entries each re-ran it (43% of the gate's serial cost). The
killed job printed nothing the gate had found, because the report was buffered.

- **fix11 judges its corpus in one awk pass.** The checks queue rules (`_f11_deny`,
  `_f11_require`, `_f11_pair`, `_f11_count`); `_f11_judge` answers them all, rules outside
  and lines inside, so gawk compiles each regex once. `_f11_env_writes` gives each of its
  seven forms its own `match()` site (gawk recompiled one shared site seven times per line:
  22 s of the runner's 32 s real-tree run). A pass that returns fewer verdicts than rules
  is a FAIL. Real tree, CI-parity container: gawk 10.1 s → 0.7 s.
- **`test-critical-fixes.sh`** builds the fixture once, `cp -a`s it per row, and runs only
  the knocked-out fix, extracted with `t_fn_src`; a case proves the extraction prints
  exactly what the gate prints, and the fix11 Cargo case still runs the real gate, so a
  FAIL is proven to reach its exit code (`critical-fixes.summary-reaches-exit`).
  52.5-64 s → 6.5-8.2 s (gawk, CI-parity container, paired runs). All 75 entries bite.
  The gate's serial cost, one lab session: 11469 s → 6633 s.
- **The mutation gate is its own CI job, in four shards.** `preflight` runs with
  `PREFLIGHT_SKIP=mutations`; the `mutations` job (matrix `shard: [0, 1, 2, 3]`, 30 min,
  same setup steps) runs `PREFLIGHT_ONLY=mutations PREFLIGHT_MUTATION_SHARD=K/4`, which
  preflight passes on as the new `verify_mutations.py --shard K/N` (`entries[K::N]`).
  Locally, `make preflight` still runs every entry.
- **`verify_mutations.py` streams.** Each verdict is printed, flushed and tagged `[j/J]`
  as its entry completes; a closing line names the failures in manifest order.
- **Four reds the timeout hid**, all from `e785e82d`/`57bec177`:
  `test-version-snapshot.sh` counted 11 `Build-*FromSource.ps1` subjects (13 since the
  MIGraphX and AMD GPU EP scripts); `cross-build-verification.md` cited the hook's
  staged-shell block as `:101-118` (now `:102-119`); `pre-commit.doc-span-fast-slugs` was
  stale; and `test-smoke-arch-parity.sh`'s sandbox lacked `check-ort-provenance.sh`, which
  `smoke-runtime-image.sh` now sources (39 assertions read empty). The 20 entries of the
  first two suites had been vacuous.

Docs: [`code-quality-tooling.md` § The mutation gate in CI, sharded](docs/code-quality-tooling.md#the-mutation-gate-in-ci-sharded),
[`onnxruntime-single-source.md` § How G4 runs](docs/onnxruntime-single-source.md#how-g4-runs-one-judging-pass).
Unverified until CI runs: the per-shard wall time on the runner (projected at about 10-16 of
its 30 minutes, slice 1 up to 4 more, scaled from `41a07927`'s measured CI gate time) and the
gawk real-tree time there.


## 2026-09-24 - ORT census: an ORT under another name is found by the entry point it defines

**Closes a G6 hole a review found.** Take an ORT with its fingerprints stripped,
rename it (`libhelper.so`), and give it an `$ORIGIN` RUNPATH beside the chain ORT.
The census called it an importer, modelled its `dlopen` onto the chain copy, and
passed it. OmniAccelerANT's packer gives exactly that RUNPATH to every ELF holding
`OrtGetApiBase`. The whole-path fingerprint (the earlier 2026-09-24 census entry)
had also widened the hole a little: an ORT whose source paths lost their NUL passed too, where it
was `STALE` before. Details:
[`onnxruntime-single-source.md` § An ORT under another name](docs/onnxruntime-single-source.md#an-ort-under-another-name).

- **Rule:** a file that DEFINES `OrtGetApiBase` is an ORT instance under any name,
  graded by its bytes; with no fingerprint it is `UNPROVEN` ("an ORT under another
  name"). A consumer only imports it or `dlsym`s it.
- **Linux:** `elf_defines` in `ort_census_probe.py` looks the symbol up through
  `DT_GNU_HASH`, or `DT_HASH` when there is no GNU table, as `ld.so` does, and
  ignores an undefined (imported) entry. Such a BIN line ends in `def`, which
  `check-ort-provenance.sh` uses for the message.
- **Windows:** `Get-PeExportNames` is new in `WindowsTargetArch.Common`, beside
  `Get-PeImportNames`. Both now read the headers through one private
  `Read-PeLayout`, and the import results are unchanged on 87 real PEs. A
  forwarded export is left out, so a DLL that forwards `OrtGetApiBase` to
  `onnxruntime.dll` stays an importer. `WindowsOrtProvenance.Common` sets `Defines` on
  such a fact and makes it an instance.
- **Measured** in a local `:latest-cross` (e8eb8a42), with the image's chain ORT
  renamed and stripped two ways, beside the chain copy: the census before this
  change passed both, and this change gives `UNPROVEN` for both. Whole-image census: no verdict moved
  outside those scratch files. The 2026-09-17 OmniAccelerANT release bundle still
  passes. OmniAccelerANT's bundle-gate suites pass: 13/13 as committed, and 17/17
  for its liboxidant cases. On the Windows host, the three consumers' ORT suites
  pass against this hub.
- **Tests:**
  - `test-ort-census.sh` 122 → 132 assertions (a GNU- and a SysV-hashed
    definition is `UNPROVEN` and red, an import through either stays a green
    importer);
  - `Smoke.OrtCensus.Tests.ps1`: the loader table gains four rows (names the
    chain directory, the same with no ORT, exports `OrtGetApiBase`, forwards
    it), and the separate oxidant case folds into them (26 → 25 tests);
  - `TargetArch.PeInspection.Tests.ps1` 5 → 6 (kernel32's own exports versus its
    forwarders).
  6 new mutation entries (`ort-census.probe-defines*`, `-gnu-hash`, `-sysv-hash`,
  `ort-census.unproven-def`), each verified to bite. 5 Windows mutations were run
  by hand on scratch copies, and each bit.
- **Code-dupes budgets moved with it:** the Smoke suite's self-pair 17 → 26 (the
  export table pokes fields the way the PE header does), GenAI/G2 48 → 46, and the
  FFmpeg/rocm-Torch row is gone (below the threshold now). The two unchanged
  pairs moved because shingle-owner counts shift.
- **Not covered:** an ORT that is renamed, stripped AND rebuilt without the
  `OrtGetApiBase` export; archive members (name and fingerprint only).


## 2026-09-24 - riscv64 web-lane tools: `legacy` is the old build verbatim; review fixes

A review of the entry below found that `WEB_LANE_TOOLS_SOURCE=native` is not the
build riscv64 had before, as that entry and the docs claimed, and that no knob
combination reached it. How to pick a path:
[`consumer-image-contract.md` § Building the web-lane tools from source](docs/consumer-image-contract.md#building-the-web-lane-tools-from-source).

- **`WEB_LANE_TOOLS_SOURCE=legacy`** (new): the package stage's pre-2026-09-23
  from-source leg, verbatim. `cargo install --locked <tool> --version <pin>` into
  `CARGO_HOME` (so cargo records it in `.crates.toml`), in the stage's own env: no
  forced C env, no gate, no cache, no provenance line, and a failed install only
  WARNs. It reads neither the cross artifact nor `WEB_LANE_TOOLS_CACHE`.
- **What `native` is, said plainly** in the contract, the knob table, AGENTS.md and
  the failure-mode entry: the package stage with rv64gc Rust, plus four differences
  from the old build. It forces vendored static C. It installs a bare binary, so a
  consumer's `cargo install <tool>` stops on `binary already exists` without
  `--force`, as it already does on amd64 and arm64. Its gate is fatal. It reads the
  cache first.
- **Every guard now has a test and a mutation.** Twelve new `rust.web-lane-*`
  entries: the producer's 30-minute `timeout` (a recording stub), `unset BUILDARCH
  BUILDPLATFORM` (an inherited `BUILDARCH=arm64` must still record `cross:amd64`),
  the "at least one GLIBC_ entry" refusal, a fatal empty `getconf`, a fatal failed
  `install`, the producer's sysroot GLIBC ceiling, the up-front knob check in
  `setup-package-image.sh` (a typo stops amd64 even when its prebuilt succeeds),
  both no-`rustc` branches and three for `legacy`. With no `rustc -V` release,
  `cross` is now an ERROR wherever an artifact was expected; a `skipped` arch still
  WARNs.
- **Both suites are hermetic.** `test-web-lane-tools.sh` took `TARGET_ARCH` from the
  caller: in the CI image (`TARGET_ARCH=amd64`) it failed 39 of 194 assertions, and
  an exported `WEB_LANE_TOOLS_SOURCE=native` failed 11. `_wlt` now clears the arch
  and Rust build env (the fixture arch is `WLT_T_ARCH`). `test-setup-package-image.sh`
  read the image's own `versions.env` and failed 3 there; its sandbox now clears
  that, the `*_SHA256` pins and the `WEB_LANE_TOOLS_*` switches.
- **What re-keys**, against the entry below: android's `web-lane-tools` producer RUN
  and package's setup RUN, per arch, because both bind-mount the edited library. No
  `versions.env`, `01-core` or other Dockerfile instruction changed; the
  `Dockerfile.package` edit is a comment.
- **Verified here:** both suites on the Windows host (the two JAVA_HOME symlink
  failures in `test-setup-package-image.sh` are host-only and predate this) and in
  the `:latest-cross` image with its own env, all green there; every mutation tied
  to either suite bites in that image. **Not verified:** no chain has run either
  entry. `legacy`'s command is the one the 2026-09-22 riscv64 chain ran, but no
  chain has reached it through the switch.

## 2026-09-23 - riscv64 web-lane tools: cross-built in android, cached, native one switch away

riscv64's package stage compiled `wasm-pack` and `flutter_rust_bridge_codegen` under
QEMU on every chain: 960 s + 1,665 s of a 3,384 s RUN (riscv64 layer file times,
2026-09-22). **Owner decision: both options.** A cross build on the build host is
the default; the native build stays, one switch away. Speedup item `riscv-tools`,
with its challenge's corrections. How to pick a path:
[`consumer-image-contract.md` § Building the web-lane tools from source](docs/consumer-image-contract.md#building-the-web-lane-tools-from-source).

- **Producer.** New stage `web-lane-tools` in `Dockerfile.android`, FROM
  `android-sdk`, i.e. before `final` swaps the amd64-hosted cross GCC out. It runs
  `06-packaging/web-lane-tools.sh produce`: `cargo install --target <triple>` under
  the hub's own `setup_linux_cross_env`, a 30-minute bound, vendored static C, its
  own cachemounts. It writes a manifest per tool. A failed cargo or gate records
  `status=failed` and android stays green. `final` COPYs the output as its LAST
  instruction, so a producer change re-keys nothing above it.
- **Package side.** `install_web_lane_toolchain` keeps the prebuilt-first path, so
  amd64 and arm64 install the same bytes as before. Its from-source leg is now
  `wlt_install_from_source`: the cross artifact or a gated native `cargo install
  --locked` in the package stage, chosen by `WEB_LANE_TOOLS_SOURCE=auto|cross|native`
  (default `auto`), through a version-keyed binary cache
  (`WEB_LANE_TOOLS_CACHE=on|refresh|off`). `legacy`, the old build verbatim, came
  a day later (2026-09-24 entry).
- **Fail loud on a claim.** Every from-source binary passes `wlt_assert_binary` on
  its staged bytes before install: ELF64, machine, lp64d, loader, a `NEEDED`
  allowlist, the image's GLIBC ceiling, `--version`. Artifacts and cache entries
  must also match their sha256. A binary that claims to be good and fails is fatal
  in every mode, and so is a bad knob or `cross` without an artifact. Availability
  misses still only WARN (`rust.web-lane-non-fatal`, retargeted to the new file).
- **Native hosts.** A build host whose arch is the target (the X100, a Jetson on
  `CROSS_BUILD_PLATFORM=linux/arm64`) gets `skipped: native-build-platform`, so
  `auto` builds natively there with nothing set.
- **Where it deviates from the design, and why.** The COPY sits after the GCC swap,
  not before it (the challenge: above the swap, every producer change re-ran a
  prefix-sized copy). The producer loads 01-core by explicit path from per-file
  mounts, never `source_module`, which would find `android-sdk`'s older copy.
  `cross` builds natively on a `skipped` manifest, so amd64 and arm64 do not turn a
  failed prebuilt download into an error. The native leg keeps the old build's
  rv64gc Rust, but not its command, its C env or its failure policy (corrected in
  the 2026-09-24 entry). The knobs are forwarded by `lib-orchestrator.sh`, not by
  new `versions.env` lines (Phase 2 of the design), and the library is bind-mounted
  into the setup RUN rather than COPYed, so no image gains a file. The producer
  keys on the rustc it actually runs, and its registry cache id is per target.
- **What re-keys on the next chain.** base, compiler, sdk and media: nothing. No
  `versions.env` or `01-core` edit, and `lib-orchestrator.sh` is in no Docker
  closure. android, per arch: the new producer vertex (seconds for amd64/arm64,
  which only write skip manifests; the cross compile for riscv64) and `final`'s new
  last layer; the five library stages and the GCC swap hit the cache. package, per
  arch: the setup RUN and what follows it, which re-run on every chain anyway. New
  cachemount ids: `web-lane-tools-cross-<target>`,
  `cargo-registry-web-lane-tools-<target>`, `web-lane-tools-bin-<arch>`.
- **Verified here:** `tests/test-web-lane-tools.sh` (new, off-target, stubbed
  readelf/cargo plus real-readelf cases), `tests/test-setup-package-image.sh`
  (now drives the real library), 30 new `rust.web-lane-*` mutations, the preflight
  gates. **Not verified:** no chain has run it. The producer has never run inside
  `android-sdk`; the design's probe ran the cross build in the amd64 runtime image
  with apt cross binutils. What to watch for on the first run is in
  `docs/build-watch-list.md`.

## 2026-09-23 - The arm64 and riscv64 GCC ship libsanitizer

**What was broken.** In the published `:latest` (index `ec4bb68b`), the arm64
(`b867d353`) and riscv64 (`66f4dea1`) images' `/opt/gcc-16.2.0` had no
`include/sanitizer/` and no `libasan`, `libubsan`, `liblsan` or `libtsan`. Any
`-fsanitize=address` build there failed with `fatal error:
sanitizer/common_interface_defs.h: No such file or directory`. It was found through
AccelerANTgine's `linux-debug-GNU` preset, where abseil's `dynamic_annotations.h`
includes that header. amd64 was not affected. Mechanism, gates and cost:
[`docs/cross-build-verification.md` § The native GCC ships libsanitizer](docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer).

- **Cause.** Those images' `cc` is the Canadian-native GCC (host == target), and
  `build-gcc.sh` built and installed only libgcc, libstdc++-v3 and libatomic for every
  `--target` build.
- **Fix.** `build-gcc.sh` adds `target-libsanitizer` to the make and install targets
  when `--host` equals `--target`. The plain cross compilers and the full-make host GCC
  are unchanged. No configure flag, `gcc.sh` or Dockerfile changed.
- **Gates.** `build-gcc.sh` fails when libsanitizer installed no header or `libasan`,
  because its configure can switch itself off silently. `swap-native-gcc.sh` checks the
  header and `libasan`/`libubsan`/`liblsan`/`libtsan` (plus `libhwasan` on amd64 and
  arm64), each with the image's ELF machine, on every build-host shape. The native
  Jetson and X100 lanes' own full-make GCC is checked too. The wrapper smoke compiles
  and links `-fsanitize=address,undefined` against the header and requires both
  runtimes in `NEEDED`. The runtime-image battery runs that binary only where the build
  host's arch is the image's, since qemu-user cannot host ASan/LSan reliably. Both
  smokes' TU shifts by a variable (`(8 >> c)`): GCC 16 defaults to C++20, which drops
  the shift-base check, and a TU with no UBSan call loses `libubsan` under
  `--as-needed`. New suite `test-native-gcc-sanitizers.sh`, which runs both smokes
  against a modelled GCC and executes the battery's container body; 23 mutations
  `native-gcc-san.*`.
- **What re-keys.** `build-gcc.sh` is in the compiler image's closure (Dockerfile.toolchain
  RUN 1, the LLVM RUN, RUN 3c and the `/opt/scripts/toolchain` COPY). The next Linux
  chain therefore rebuilds the one compiler image: the host GCC, both plain crosses,
  both Canadian natives (now with libsanitizer), then LLVM, Rust and CPython on the new
  digest. Every stage below it rebuilds on all three arches: sdk, media, android,
  runtime package, wrapper-smoke, wrapper and the manifest. Three more edits land in
  stages that re-run anyway on their new parents: `swap-native-gcc.sh` (the android
  final COPY), `validate-compilers.sh` (Dockerfile.package's artifact-source bind and
  its COPY) and `build-gcc.sh` again (Dockerfile.package's `02-toolchain/` COPY). Base
  is untouched. `smoke-runtime-image.sh` runs on the host and is in no image. The
  compile caches survive the re-key, because the sccache/ccache mounts are outside the
  image digest. The host and plain-cross GCC configure lines are unchanged, so their
  compiles should hit; the run's sccache stats will show whether they do. The nvidia
  and rocm variant images were never affected (their GCC is the build host's full
  make). Their chains re-key on the next run because they build on the new shared sdk,
  with no change in their GCC. Consumers that still pull `:latest-cross` through the
  hub's actions at `@main` keep the frozen image.
- **The next run must include the compiler stage.** On arm64 and riscv64 a partial
  rebuild on the old images now fails on purpose, instead of shipping without the
  runtime: a `--from-stage sdk|media|android` run on the old compiler digest stops at
  the android swap, and a `--from-stage runtime` run (or `build-runtime-artifacts.sh` /
  `build-runtime-manifest.sh`) on the published android images stops at the wrapper
  smoke with `COMPILER FAIL [gcc-sanitizers]`. No arm64 or riscv64 wrapper can be
  rebuilt from a partial stage until a chain from the compiler stage down has run.
  amd64 is unaffected.
- **Size.** About +79 MB uncompressed in the arm64 `/opt/gcc-16.2.0`, the size of
  amd64's set (79.3 MB, mostly unstripped `lib*san.a`). riscv64 has no hwasan, but its
  static archives are about 3x amd64's (`libstdc++.a` 171 MB against 55 MB), so expect
  roughly +190-200 MB there. The compiler, sdk, media and android images carry both
  native prefixes (roughly +270-280 MB), but those images are not shipped. None of this
  is measured on a built image; the compressed delta is not known.
- **Unverified until the Linux chain runs on the build host:** that libsanitizer
  configures and builds in the Canadian cross at all (libstdc++-v3 builds the same way,
  which is the main evidence it will); how much time the two libsanitizer builds add
  (not measured); the compressed size; and the sanitizer RUN on amd64. The arm64 and
  riscv64 RUNs happen only on a Jetson or X100 build host. TSan on riscv64 needs an
  sv39 or sv48 VMA, unverified on the X100. The static and stubbed tests ran on a
  Windows host. The suite also ran in a local amd64 `:latest-cross`, where the wrapper
  smoke compiled, linked and passed with the real GCC 16.2.0, and the smoke TU ran
  natively under ASan+UBSan.
- **Still missing on arm64 and riscv64, out of scope:** libgomp (`omp.h`), libitm and
  gfortran, and a target `libasan` for the amd64 image's plain cross compilers.


## 2026-09-24 - ORT census: a consumer that names the chain directory is not an ORT build

**Fixes G6 failing OmniAccelerANT's Linux lane** (run 35928030957, x64 and arm64):
`UNPROVEN /lib/liboxidant.so -- an ORT-named binary with no source fingerprint`. The
bundle was correct: it held the chain ORT, byte for byte. The census got the file
wrong. Details and measurements:
[`docs/onnxruntime-single-source.md` § What "the chain ORT" is](docs/onnxruntime-single-source.md#what-the-chain-ort-is).

- **Cause 1: a directory string counted as a fingerprint.** OxidANT's loader keeps
  `/opt/onnxruntime/onnxruntime/core/` as a string to check the ORT it loads. The
  census treated any file holding `onnxruntime/core/` as an ORT build. Now a
  fingerprint is a whole source-file path ending in NUL (`.cc`, `.cpp`, `.cxx`, `.c`,
  `.h`, `.hpp`, `.inc`, `.cu`, `.cuh`), the shape `__FILE__` leaves. Changed in
  `ort_census_probe.py` (`MARK`) and in the Windows twin
  (`WindowsOrtProvenance.Common.psm1`, `$script:OrtPathMarker`), where `oxidant.dll`
  would have been `STALE`. `liboxidant.so` is now an importer, and G6 checks that it
  resolves to the chain ORT, which it used to skip. Every fingerprint of the chain ORT
  1.29 (592), its dnnl EP (23) and the Android build (545) still matches.
- **Cause 2: a relative root printed as "no fingerprint".** rustc packs string
  literals with no NUL between them, so the text before the directory became a
  relative root (`''`), which `emit()` prints as `-`. The probe now prints it as `.`,
  and `check-ort-provenance.sh` reads `.` as relative. A lone relative root is
  `FOREIGN` (relative), as on Windows, not `UNPROVEN`.
- **The same false positive hit G1 on FFmpeg.** FFmpeg compiles its configure line
  into every lib and tool, and the chain's passes
  `-I/usr/local/lib/onnxruntime-cpu/include/onnxruntime/core/session`
  (`ffmpeg-dnn-backends.sh`). The old rule made every FFmpeg ELF an ORT build with
  no fingerprint. Whole-image census of a local `:latest-cross` (e8eb8a42), old vs new
  probe: `UNPROVEN` 14 → 1 (10 FFmpeg ELFs and 3 scratch `liboxidant.so` copies gone).
  `libavfilter` is now the registered `ffmpeg` consumer it is, graded by RES and
  STAMP, and the other nine are not ORT at all. The runtime smoke's census
  (SHIPPED-TRUTH E) would have reported the same ten on the next image.
- **Stricter, on purpose:** a reference file whose roots are all relative is now
  `FOREIGN`, where `-` passed before. It matches Windows. e8eb8a42 has no such
  reference: its two unfingerprinted ones (`libonnxruntime_providers_shared.so`, the
  Android `libonnxruntime4j_jni.so`) still print `-` and pass as before. The CI image
  (ec4bb68b) was not available here to check.
- **Tests:** `test-ort-census.sh` 110 → 122 assertions (the fingerprint shape, a
  rustc-packed consumer passing beside the chain ORT, then failing with no ORT or a
  one-byte-off one, a relative-only ORT). 6 new mutation entries (`ort-census.probe-*`,
  `ort-census.relative-dot`), each verified. `Smoke.OrtCensus.Tests.ps1` 24 → 26.
- **Reproduced in a local `:latest-cross` (e8eb8a42)** with the REAL `liboxidant.so`
  built from OxidANT f018bec with the lane's features, inside the 2026-09-17 release
  bundle, through OmniAccelerANT's own packer and bundle checks. Hub a7ccc896 gives
  CI's line and `bundle closure: 1 failure(s) across 42 ELF file(s)`; this change
  gives `ORT census PASS`. Five mutations of that bundle (ORT removed, one byte off,
  foreign, no `$ORIGIN`, a renamed re-rooted ORT) each still fail.
- **Consumers pick it up with a hub pin bump, and their Windows ORT test fixtures
  need one edit.** OxidANT's loader does not change: the consumer rule is "name the
  chain directory, never embed a whole ORT source path". The rule is in `AGENTS.md`
  § Linux Build Rules and in the section 25 bullet of
  `docs/windows-build-invariants.md`. But a fixture that fakes an ORT as
  `"$chainSrc OrtGetApiBase"` has no fingerprint under the new rule. At this commit,
  OmniAccelerANT's `OrtRunner.Tests.ps1` fails 2 of 6, and OxidANT's
  `OrtPayload.Tests.ps1` and AccelerANTgine's `OrtBundle.Tests.ps1` fail one case
  each (`UNPROVEN` where `STALE` is expected). Ending the fake path with a NUL
  (`` "$chainSrc`0OrtGetApiBase" ``) fixes all three and passes at either hub:
  [`onnxruntime-single-source.md`](docs/onnxruntime-single-source.md#what-the-chain-ort-is).
  (Corrected on 2026-09-24. This bullet first said nothing in the consumers changes.)

## 2026-09-24 - Review follow-ups to the sccache-endpoint fix

Six review findings on the entry below, each verified before it was applied.

- **A parent the run did not build is graded before a stage inherits it.** `FROM` copies the
  parent image's config ENV (the merge Dockerfile's comment said it does not; corrected). With
  the merge `built` stage's own ENV gone, a `bk-windows-toolchain` from before the fix passed
  its endpoint straight through to the published image, and only the final gate, hours later,
  would have seen it. `Invoke-BkStage` now solves `Dockerfile.publish-gate` on every
  `BASE_IMAGE` the run neither built nor graded, before the stage; a stale parent fails in
  seconds and the error says to rebuild it. The fresh toolchain is graded right after its
  solve. All three sites go through `Invoke-BkPublishGate`. **A run started before this commit
  has no gate: restart the chain with `toolchain` in `-Stages` from a fresh driver process;
  never resume it.** [`windows-build-resources.md` § An image this run did not build](docs/windows-build-resources.md#an-image-this-run-did-not-build).
- **The Windows gate's default path is tested.** The gate's RUN passes no `-Scopes`, and no
  test did either. Now a uniquely named leaking Process variable must make a bare
  `Assert-ImageEnvPublishable` throw, the Process/Machine/User list is pinned from the AST, and
  an in-suite mutant for each proves it bites.
- **The Linux image-env gate has no switch.** Check 6 of `verify-shipped-wrapper.sh` sat
  inside the `RUNTIME_IMAGE_SMOKE=1` block and never ran on `--manifest-only`/`--repair`. It is
  now `_manifest_image_env_gate`, the first step of `create_manifest`, on every path that
  creates an index; check 6 is gone. The `make` help and four `image-env.manifest-*`
  mutations (replacing the two `image-env.wrapper-*`) follow.
- **The consumer probe tries every address at once.** `Test-TcpEndpointReachable` now
  resolves within the budget and connects to every address in parallel. Before, an IPv4-only
  listener behind `http://localhost:<port>` was removed after 2049 ms, because Windows refuses
  `::1` only after ~2 s; now it is kept in 37 ms. New cases: that one, a 200 ms bound against
  a closed port, and an unresolvable name, with an in-suite mutant per case.
- **The build host keeps its remote tier.** Consumer builds on the build host reached WebDAV
  only through the leaked ENV and would have lost it silently. `Invoke-ContainerBuild` now
  forwards this host's `SCCACHE_WEBDAV_ENDPOINT` and `SCCACHE_MULTILEVEL_CHAIN` into the
  container at run time (`Add-HostSccacheRemoteEnv`) unless `-CacheEnv` sets them (`''` opts
  out). A `docker run` by hand still passes `-e` itself:
  [`windows-build-resources.md` § The build host's remote tier, at run time](docs/windows-build-resources.md#the-build-hosts-remote-tier-at-run-time).
- **Two things this host needed to commit it through the hook.** `verify_doc_links.py`'s git-free
  floor compared `str(path)` with POSIX entries, so on Windows it ignored nothing and
  `test-doc-links.sh` failed at baseline; it now matches the POSIX spelling (a no-op on Linux).
  And `build-cross-chain.sh`'s `_CHAIN_RUNTIME_GATES` does not name the new Linux gate yet:
  staging that file samples `test-chain-lifecycle.sh`, whose symlink cases fail on a Windows
  host, so that one-line edit is for a Linux host.
- **Re-key set: nothing beyond the entry below.** The driver, the tests and the Linux host
  scripts are in no image closure, the merge Dockerfile edit is a comment (no LLB change), and
  the two edited modules are copied only by the final `windows/Dockerfile`, which re-keys
  anyway. Base, the sdk slot and the toolchain are untouched. Linux: nothing re-keys.

## 2026-09-23 - The published image no longer carries the build host's sccache endpoint

**What broke.** `:winamd64` (digest `3137eebe…`, built 2026-09-22 from hub `0d85b8c1`)
shipped `SCCACHE_WEBDAV_ENDPOINT=http://192.168.188.116:5000` — the owner's LAN WebDAV — plus
the build host's chain, force-local and cache settings, from the ENV blocks of four
Dockerfiles (`patched-llvm` from #164, media-builder's `common`, the merge `built` stage,
`rocm-migraphx`). The consumer wiring turns the sccache launchers on whenever sccache is on
PATH; on a GitHub runner sccache 0.18's server fails its storage check (`tcp connect error`)
and exits, every client times out after 10-12 s, and CMake calls clang-cl broken. That turned
AccelerANTgine and OmniAccelerANT red (runs 35921977157, 35912798986), and nobody could see
why, because `$null = Invoke-ContainerBuild` discarded the build's stdout. Account and table:
[`docs/windows-build-resources.md` § What the published image carries](docs/windows-build-resources.md#what-the-published-image-carries).

- **(1) ARGs, not ENV.** `SCCACHE_WEBDAV_ENDPOINT`, `SCCACHE_MULTILEVEL_CHAIN` and
  `SCCACHE_FORCE_LOCAL` are ARGs with no default, redeclared in every stage whose RUN
  compiles through sccache: `patched-llvm`; media-core-built-onnx/-ffmpeg/-opencv/-hailo,
  media-core-built, media-litert-built and media-tvm-built; the merge `built` stage;
  `rocm-migraphx`. An ARG does not cross a FROM, and the media-core chain crosses solves. The
  ENV blocks keep only the container-local runtime defaults (`SCCACHE_DIR`,
  `SCCACHE_CACHE_SIZE`, `SCCACHE_ERROR_LOG`, `SCCACHE_LOG`, `SCCACHE_IDLE_TIMEOUT`), with
  unchanged values. `Dockerfile.sccache-write-probe` follows (it ships nothing).
- **(2) Publish gates.** Windows: `windows/Dockerfile.publish-gate` + `WindowsImageEnv.Common.psm1`,
  solved by `Build-Buildkit.ps1` after the smoke gate and before `-FinalTar`/`-PushRef`, not
  skippable by `-SkipSmokeGate`; it grades the Process, Machine and User scopes. Linux: check 6
  of `verify-shipped-wrapper.sh` reads each wrapper's config ENV, hard even under
  `WRAPPER_CONTENT_GATE=0`. Static, both lanes: `linux/scripts/verify_image_env.py --dockerfile`
  as pass 0b of `lint-dockerfiles.sh`, which also refuses a compiling Windows RUN whose stage
  lacks the endpoint ARG. A leak is a build-host sccache name or an RFC1918/link-local address
  in a host position; `linux/scripts/tests/image-env-cases.json` grades the PowerShell and the
  Python matcher alike.
- **(3) Consumer defense for images already published.** `Enable-SccacheCompilerWrapper`, the
  choke point of `Initialize-BuildCacheEnvironment` and `Invoke-CmakeConfigureAndBuild`, now
  calls `Clear-UnreachableSccacheEndpoint` (exported): a 2 s TCP probe of the endpoint; if it
  fails, the variable (and a chain naming webdav) is removed for the process with one WARN, and
  sccache falls back to local disk. A reachable endpoint is untouched.
- **(4) Container output is visible.** Every unconsumed docker call in
  `WindowsContainerBuild.Reuse.psm1` ends in `| Out-Host` — the tar-pipe `docker exec`, the
  bind-mount `docker run`, the stale-cache cleanups, the output-directory probe and the source
  prune — so `$null = Invoke-ContainerBuild` no longer swallows the build. `$LASTEXITCODE` and
  the returned object are unchanged.
- **Re-key set.** Windows: the `patched-llvm` stage (so `bk-windows-toolchain`), every
  media-builder stage below `common` plus `buildmods`/`tvmmods`, the whole merge Dockerfile, and
  on the rocm lane `rocm-migraphx`; everything after them re-keys because its parent does
  (llama, torch, final; final also COPYs the modules dir). NOT re-keyed: `Dockerfile.base`, the
  sdk slot (CPU alias, `Dockerfile.nvidia`, `Dockerfile.rocm`) and the toolchain's `builder`
  and `built` (CPython) stages — no file they COPY or mount changed. Linux: no Dockerfile
  changed, nothing re-keys.
- **Not covered, recorded.** BuildKit writes a RUN's build args into the layer history, so the
  final image's history still names the endpoint; nothing reads it at run time. Backlog #177
  (a secret mount) owns it. Hostnames, loopback and files inside the image are out of the
  matchers' scope.
- **Tests.** Windows: `ImageEnv.PublishGate.Tests.ps1` (fixture parity, one in-suite mutant
  per rule, the driver's call order and two driver mutants), `Build.SccacheEndpointProbe.Tests.ps1`
  (closed and listening loopback ports, both wiring sites, one WARN, a mutant),
  `ContainerBuild.Output.Tests.ps1` (child-session visibility, an AST guard with two mutants)
  and a new case in `Modules.Orchestrators.Tests.ps1`. Linux: `test-image-env.sh` (a
  fake-nerdctl run of the wrapper gate included). Fifteen new `mutations.json` entries
  (`dockerfile-lint.image-env-*`, `image-env.*`), each proven to bite. Docs:
  `windows-build-resources.md`, `build-cache-tiers.md`, `windows-builds.md`,
  `windows-build-invariants.md` (49 rules now), `failure-modes.md`, `code-quality-tooling.md`,
  the #164 archive entry, backlog #177 and `AGENTS.md` § Push And Publish Rules.

## 2026-09-23 - Windows Scripts CI is green again: an unmounted CUDA root reads as absent, and the Hailo patches are checked

- **`WindowsSourceBuild.Cuda.psm1`.** `ad5b7d8f` (#176) built `Get-CudnnLibraryDir`'s and
  `Test-CudaWindowsArm64Payload`'s paths with `Join-Path`, which resolves the root's drive
  and throws `DriveNotFoundException` on an unmounted one; the contract (and the
  `SourceBuild.Resolve` `X:\` cases) is `$null` / `$false`. Every `lint-and-test` run
  since 2026-09-20 failed on it, on the runner and on any host without an `X:`. The paths
  are interpolated now; the rocm lane gate in `Get-GpuEnvironment` had the same latent
  shape and changes with them. The tests stay as the regression cases.
- **`Test-PatchesApplyClean.ps1`** maps `patches/hailo/` to `hailo-ai/hailort` at
  `v<HAILORT_VERSION>` (the tag `Build-HailortFromSource.ps1` downloads). Without it the
  four Hailo patches failed `patch-drift` unchecked since `da14e043`; all four apply
  cleanly at v5.4.0.


## 2026-09-23 - ONNX Runtime has one source: the chain

**Owner rule: every component that compiles against, links or loads ONNX Runtime uses
the ORT this repo builds from source**, on both lanes and in the consumer repos. No
NuGet, PyPI, release-zip, apt, bundled or pyke copy, and no exceptions; a plugin EP
counts as ORT. Every consumer, the six guards and what each cannot see:
[`docs/onnxruntime-single-source.md`](docs/onnxruntime-single-source.md) (new). The rule
itself: `docs/windows-build-invariants.md` (48 rules now) and `AGENTS.md` § Linux Build
Rules.

- **What was broken.** Windows OpenCV downloaded `onnxruntime-win-x64-1.25.1.zip` at
  configure time (arm64 zip on the cross lane) and linked it, unpinned. Windows GenAI
  compiled against NuGet `Microsoft.ML.OnnxRuntime.DirectML` 1.24.4 from a feed, unhashed.
  The rocm venv carried PyPI `onnxruntime-ep-webgpu`. Neither the OpenCV nor the GenAI
  download showed in the shipped image. Correction to the 2026-09-23 `-Variant rocm`
  sdk-slot entry below: its "Found, not fixed (every lane)" OpenCV line was true of the
  Windows lanes only; Linux pre-set `HAVE_ONNXRUNTIME` all along.
- **Windows OpenCV** (every lane): a nested-header shim over the chain ORT,
  `-DHAVE_ONNXRUNTIME=ON`, both CMake packages disabled, and a configure gate. G-API's
  DirectML EP is compiled in for the first time, delay-loading dxcore/d3d12/dxgi/DirectML
  through an OpenCV CMake hook. dnn and G-API now need `onnxruntime.dll` 1.30 or later.
- **Windows GenAI**: an `ORT_HOME` shim; the `ortlib`/`onnxruntime` FetchContent names point
  at an empty dir, so a fallback fails configure. Configure and tree gates; the configure
  log is kept. `DirectML.h`/`D3D12Core.dll` and a DXC restore are still unhashed NuGet
  fetches (not ORT), recorded as follow-ups.
- **WebGPU EP**: the rocm spike builds ORT's in-tree WebGPU EP (Dawn on D3D12) into the
  chain `onnxruntime.dll`, with a pinned DXC release beside it. The PyPI plugin and its
  `TORCH_ROCM_WINDOWS_ORT_EP_WEBGPU_*` pins are gone; five `ORT_WEBGPU_WINDOWS_*` pins are
  new. `-NoRocmSpikes` builds without it.
- **G2, the build gate + stamp**: `Assert-ChainOrtOnly` (`WindowsOrtProvenance.Build.psm1`)
  and `ort_assert_chain_only` (`linux/scripts/03-media/ort-provenance.sh`) end every
  consumer build: OpenCV, GenAI, FFmpeg, GStreamer, and the AMD GPU EP. They grade the
  tree, fetch caches, build records and logs, and a pass writes the stamp G1 requires.
  Placed outside the census module and `03-media/core/`, per-file mounted, for the cache.
- **G1, the ORT census on the shipped image**: Windows smoke section 25; Linux
  SHIPPED-TRUTH E (`check-ort-provenance.sh`, `ort_census_probe.py`). Byte identity with
  the image's own chain ORT, the loader order per importer, the consumer contract, stamps.
- **G3**: both final images set `ORT_LIB_LOCATION`, `ORT_PREFER_DYNAMIC_LINK=1`,
  `ORT_SKIP_DOWNLOAD=1` and `ORT_DYLIB_PATH`, so an `ort-sys` build there cannot fetch
  pyke's ORT. Asserted by section 19 and the new contract row `ort-crate-env`.
- **G4**: `verify-critical-fixes.sh` fix11, a static denylist over both lanes' scripts,
  plus the G1/G2/G3 wiring. **G6**: `Test-OrtProvenanceTree` / `check-ort-provenance.sh
  <dir>` for consumer bundles.
- **App venv**: one census, `ort-venv-census.py`, purges by name pattern and package
  ownership (no fixed lists) and fails the torch stage unless every ORT distribution is a
  chain wheel byte for byte. A missing Linux chain wheel is fatal (it used to fall back to
  PyPI 1.27.0). Smoke section 21 adds DirectML and chain-wheel checks on every amd64 lane
  (floor 2 → 4). The nvidia smoke counts any GenAI flavour as the GenAI. The Windows app
  `uv sync` no longer installs the lock's PyPI ORT and GenAI before the purge: each
  `onnxruntime*` name in `uv.lock` is `--no-install-package`, and one without a chain
  wheel of its family stops the stage.
- **Consumer CI venvs** (`python-ci-*`): inside our images, `uv_sync_project` /
  `Sync-UvProjectDependencies` reconcile onto the chain wheels and fail unless the census
  and an import prove it. Linux gains `ORT_CHAIN_WHEEL_DIR=/opt/onnxruntime-wheels`.
  Owner decision: the 3.13 legs go (the chain wheels are cp314, the images carry 3.14
  only). `ci_tests.sh` `PY_VERSIONS` and `ci_build_docs.sh` `COVERAGE_VERSION` default to
  3.14 and OrchestrANT drops its 3.13 legs. WebDavClient (no ORT) needs
  `docs-python-version: '3.13'` in its workflow no later than the commit that moves its hub
  pin past this, or its docs job syncs atheris on 3.14 and fails. The Windows image COPYs
  the census to `C:\temp\scripts\`, beside its module copy, which failed every sync without it.
- **Linux**: a missing chain ORT stops OpenCV (no more silent build without it); dnn's
  copies in `/opt/opencv5/lib` become links to the chain; `000-onnxruntime.conf`; FFmpeg's
  chain `-L` goes first, a chain its probe cannot link stops FFmpeg (it used to skip the
  backend), and a link gate reads `config.mak`; a gate over the gst `onnx` plugin's
  `build.ninja`; apt ORT denied in code, by an apt-plan gate and a dpkg gate. The chain
  wheel manifest G1 reads follows the wheel through `repair-wheels.sh`'s cross strip and
  retag, and a twin of its name stops the stage. G2's default fetch caches match Windows
  (pyke, pip, uv, NuGet) plus cargo and the FFmpeg SDK cache; uv counts only wheels it
  downloaded, since its mount keeps old chain wheels. GenAI's G2 RUN mounts its build's caches.
- **Hub consumer API**: `WindowsOnnx.Common` refuses NuGet ORT, `Get-OnnxPackageLayout`
  throws, `Get-OnnxChainLayout` is new, and `WindowsMediaRuntime.Common` stages the chain only.
- **Consumer repos** (working trees; gitlinks not moved): OxidANT drops
  `download-binaries` for `load-dynamic`, loads only fingerprinted chain files, gates its
  lock, and ships the chain DLLs in its zip/MSIX/MSI; AccelerANTgine's CMake requires the
  fingerprinted chain prefix; OmniAccelerANT stages and stamps the chain ORT beside its
  runner, refuses anything else at launch, and drops the System32 fallback.
- **No in-box ORT in the images, now asserted.** A one-`RUN` probe over `bk-windows-base`
  (servercore:ltsc2025, OS 26100.33438) found no `onnxruntime*`, Windows ML or DirectML
  DLL anywhere on `C:\`. Smoke § 25 gains `ORT in-box` on every amd64 lane (verdict
  `INBOX`, floor 4 → 5; the cross lane skips it), and no exemption can waive an in-box path.
  A base that ships one keeps the previous `WINDOWS_BASE_DIGEST`: app-local chain copies
  cannot clear the census today, and fix11 refuses a script line that deletes or patches
  an in-box ORT under `C:\Windows`.
- **Re-keys: the full chain, on both lanes.** `versions.env` changed. Windows imports it
  in `Dockerfile.base`'s last layers, so every stage after base rebuilds on every lane.
  Linux mounts it into its base, so everything after base rebuilds on every arch. The
  script edits alone would re-key most of the Linux media build too: `Dockerfile.media`
  mounts `01-core` (`python_uv.sh` changed) whole into most of its RUNs, and the
  `onnxruntime` script dir (`60-build-genai.sh` changed) whole into the GPU ORT, GenAI,
  wasm and js/pkgconfig RUNs. Images built before this fail the STAMP check until rebuilt.
- **Not proven by a build.** Nothing but that probe ran in a container. Likeliest first
  reds, all fail-closed: GenAI and G-API's DirectML EP against the 1.30 headers under
  clang-cl; Dawn under clang-cl; a Linux package depending on `libonnxruntime1.x`; a G2
  false positive on a real record path.

## 2026-09-23 - Windows rocm lane: remaining AMD GPU paths

**The rocm lane fills its AMD GPU gaps: OpenCL, Vulkan, FFmpeg Vulkan, llama.cpp Vulkan,
gfx1200 and LiteRT, and the TVM ROCm spike builds again.** All of it is gated on
`HasRocm`; cpu and nvidia keep their flags. Details: [`docs/windows-rocm.md`](docs/windows-rocm.md).

- **TVM ROCm spike.** It had failed the whole media-tvm RUN (IREE included): the
  minimal-LLVM branch never ran on amd64, because the patched toolchain LLVM
  (`AArch64;X86`) is always on PATH. `Get-TvmLlvmChoice` now treats a PATH llvm-config
  without AMDGPU as absent on the spike and builds `X86;AArch64;NVPTX;AMDGPU`.
  `ROCM-FEATURES.txt` records the read-back target list, and `TVM.ps1` compares it with
  what TVM links (`amdgpu`, or `amdgcn` before LLVM 23).
- **OpenCL ICD.** `Install-Rocm.ps1` registers TheRock's `amdocl64.dll` under
  `HKLM\SOFTWARE\Khronos\OpenCL\Vendors`. Before, nothing did, and the loader found no
  platform.
- **Vulkan loader.** New `Install-VulkanLoader.ps1` puts LunarG's signed `vulkan-1.dll`
  into System32 (FFmpeg's `dlopen` and Python never read PATH), with the pinned copy and
  its licence in `C:\vulkan-loader`. New pin `VULKAN_RT_WINDOWS_ZIP_SHA256`, refreshed by
  `spec_vulkan`. New smoke `rocm-checks/GpuLoaders.ps1`; amfcodec is now load-probed.
- **FFmpeg** gets `--enable-vulkan` against the SDK's headers and glslc: the vulkan
  hwdevice, 9 hwaccels, 5 encoders, 18 filters, swscale's SPIR-V backend. A 35-symbol
  `config.mak` gate and new smoke listings. libplacebo stays off.
- **llama.cpp Vulkan.** The same build's official Vulkan zip in
  `C:\runtime\opt\llama.cpp-vulkan`, its own layer, off PATH. `Install-LlamaCppHip.ps1`
  is now `Install-LlamaCpp.ps1 -Backend hip|vulkan`, and `LlamaCpp.ps1` grades both. New
  pin `LLAMA_CPP_VULKAN_SHA256`; the bump spec takes the newest build with both zips.
- **Torch venv.** Device wheels for gfx1200 next to gfx1201 (six new pins), and a gate that
  refuses a rocBLAS GPU without device pins. `ai-edge-litert` 2.2.0 with its WebGPU
  accelerator. The PyPI WebGPU plugin EP added here the same morning was replaced by the
  chain's own WebGPU EP (entry above).
- **Licences.** `deps.json` rows for the Vulkan loader, the llama.cpp Vulkan build (libomp
  in both zips), `ai-edge-litert`, and gfx1200 in the PyTorch row.
- **Re-keys: the full chain, on both lanes.** The new pins live in `versions.env`, which
  Windows imports in `Dockerfile.base`'s last layers and Linux mounts into its base. So
  every Windows stage after base rebuilds on every lane, and every Linux stage after base
  on every arch. cpu/nvidia output is unchanged. The media-tvm script edit alone would
  re-key that RUN on every lane (the script is bind-mounted).
- **Nothing here ran in a container or on a GPU.** Likeliest first breaks: AMD's PAL
  initialising in a GPU-less Server Core (every OpenCV T-API check now loads it); the
  AMDGPU minimal LLVM's time and memory; FFmpeg's Vulkan sources under clang-cl. Windows
  Defender flags `llama-gguf-split.exe` as `Wacatac.B!ml` on this host.

## 2026-09-23 - Windows `-Variant rocm`: the ROCm layer moves into the sdk slot, and media turns on AMD GPU features

**The ROCm layer now sits where `Dockerfile.nvidia` sits** (owner directive), so toolchain
and media build on `GPU_TYPE=rocm`: base → sdk=rocm → toolchain → media → migraphx → llama
→ torch → final. This supersedes the 2026-09-22 "forks after media" entry. Every feature is
gated on the new `(Get-GpuEnvironment).HasRocm`; the cpu and nvidia lanes keep their flags
and outputs, locked by tests in every touched suite. What each component enables, with
evidence: [`docs/windows-rocm.md`](docs/windows-rocm.md).

- **Driver.** Every rocm tag after `bk-windows-base` carries a `-rocm` infix
  (`bk-windows-sdk-rocm` … `bk-winamd64-rocm`), so a rocm run never overwrites a default
  image (golden test for cpu/nvidia on amd64 and arm64). New rocm-only stages `migraphx` and
  `llama`; `-Stages rocm` is refused. New `-NoRocmSpikes` (drops migraphx, passes
  `TVM_ROCM=0`). `TVM_ROCM` and `TORCH_ROCM` + pins go to the rocm lane only
  (`Get-BkRocmStageArg`), also through the `-ConcurrentAux` children. A rocm `-Stages` list
  with a gap in the post-media chain is refused as a stale parent (backlog #39).
  `Dockerfile.rocm` gets a 45 GB disk floor. `bk-windows-rocm` is orphaned: remove it by hand.
- **Contract.** `Get-GpuEnvironment` returns `HasRocm`/`RocmRoot` and throws on
  `GPU_TYPE=rocm` without `lib\cmake\hip` (the rocm twin of #45). `Invoke-CmakeConfigure`
  appends `-DCMAKE_IGNORE_PREFIX_PATH=<ROCm tree>` on the rocm lane so TheRock's
  flatbuffers/nlohmann_json/zlib never reach a non-HIP build; HIP consumers pass
  `-AllowRocmPrefix`. Meson (GStreamer), Bazel (LiteRT-LM), FFmpeg and TVM scrub the tree
  themselves and prove it with a post-configure gate. HIP device code compiles only with
  TheRock's clang++ by absolute path.
- **Media, rocm lane only.**
  - GStreamer: `hip`, `amfcodec`, `d3d11`, `d3d12` pinned `enabled` (meson `auto` already
    built them everywhere).
  - FFmpeg: AMD AMF (`--enable-amf`, header-only `AMF_HEADERS_*` pin): h264/hevc/av1 encoders,
    h264/hevc/av1/vp9 decoders, vpp/sr/frc filters, `amf` hwdevice. A generic H.264/HEVC
    encoder lookup now resolves to `*_amf` on this lane.
  - OpenCV: OpenCL T-API was already on everywhere; the clBLAS/clFFT probes are pinned off and
    a configure gate proves no ROCm leak.
  - IREE: HIP HAL driver and `rocm` compiler target, with a carried patch so the driver finds
    `amdhip64_7.dll`; `IREE_ROCM_DEVICE_BC_SHA256` mirrors IREE's bitcode pin.
  - TVM: OpenCL runtime; ROCm codegen + runtime as a spike. Fixed on the way: TVM's
    `find_rocm` read `ROCM_PATH` even with `USE_ROCM=OFF`.
  - LiteRT-LM: GPU backend (WebGPU over Dawn on D3D12) with four `LITERT_LM_*_SHA256` pins.
- **New rocm stages.** `Dockerfile.rocm-llama` installs llama.cpp's official Windows ROCm
  build b11115 (SHA256-pinned, off PATH, `LLAMA_CPP_HIP_HOME`). `Dockerfile.rocm-migraphx`
  (spike) builds MIGraphX 2.17.0 from source (`MLIR=OFF`, a configuration no upstream CI
  builds) and AMD's ORT plugin EP `migraphx-ep.dll`; all 17 archives SHA256-pinned, the EP's
  hash-less FetchContent pre-seeded and disconnected.
- **Torch.** `Dockerfile.torch` ends `FROM rocm-${TORCH_ROCM}`: cpu/nvidia build the
  unchanged `app` stage; the rocm lane installs torch 2.13.0+rocm10.0.0 and torchvision
  0.28.0+rocm10.0.0 offline from 10 URL+SHA256 pins (`Install-TorchRocm.ps1`).
- **ONNX Runtime** stays CPU + DirectML; the dead `onnxruntime_USE_ROCM` branch is gone.
- **Smoke.** `Test-RocmImage.ps1` runs every `windows/scripts/build/rocm-checks/*.ps1`
  (GStreamer, FFmpeg, OpenCV, IREE, TVM, LiteRtLm, Torch, LlamaCpp, MIGraphX), all GPU-less.
- **Test harness.** `Get-GpuEnvironment` rocm cases and `Get-CMakeRocmIsolationArgs` in
  `SourceBuild.Resolve`; new suites per component, each mutation-checked.
- **Licences.** `deps.json` gains TheRock, the AMF headers, the AMD PyTorch wheels, the
  llama.cpp and MIGraphX/EP closures and the LiteRT-LM GPU payload. The HIP/OpenCL runtime
  has no licence file: a public push of `:winamd64-rocm` is an owner decision.
- **Cost.** The touched modules and scripts are bind-mounted into the toolchain and media
  RUNs, so every lane rebuilds patched LLVM and media once with unchanged flags.
- **Found, not fixed (every lane, owner decision):** OpenCV's dnn module downloads
  `onnxruntime-win-x64-1.25.1.zip` unpinned at configure time; LiteRT-LM is cloned by tag.
- **Nothing here has been seen running on a GPU yet**; see the open points in
  `docs/windows-rocm.md`.

## 2026-09-23 - CUDA_ARCHITECTURES: Hopper (90) retired too

Same day, same owner, one entry lighter: `86;87;89;120`. 90 (H100/H200) joins
80 (A100/A30) on the commented line in `versions.env`; re-adding either is
inserting the number in ascending order. The CUDA compile now runs four cubins
per source file instead of five, and the image supports exactly the hardware
the owner has: RTX 30xx/A10/A40, Jetson Orin, Ada, and RTX 50 / RTX PRO
Blackwell. The absence stays a HARD edge -- no PTX, so an H100 would fail at
session creation, which is why both retired numbers are documented rather than
deleted.


## 2026-09-23 - CUDA_ARCHITECTURES: 80 retired, Blackwell (120) added

Owner decision. The set is now `86;87;89;90;120` — RTX 30xx/A10/A40, Jetson
Orin, Ada, Hopper, and GeForce RTX 50 / RTX PRO Blackwell. 80 (Ampere GA100)
is retired and kept as a commented line in `versions.env`, because its absence
is a HARD edge: ORT embeds no PTX, so an A100 or A30 now fails at session
creation rather than running a slow path.

Three facts, verified against NVIDIA's docs and a real nvcc before the edit,
decide why the value is spelled exactly this way:

- **Neighbours cover nothing.** A cubin runs on its own major at an
  equal-or-higher minor: 86 does not reach 87, 90 does not reach 120.
- **ONNX Runtime narrows it further.** v1.30.0 rewrites every entry to
  `sm_<cc>a-real` — arch-specific, cubin-only. In the ORT artefact `120` covers
  12.0 and NOT 12.1 (GB10/DGX Spark); `100` would cover B100/B200 but not B300
  (10.3). The owner's hardware is RTX-50-class, hence 120 alone.
- **Jetson Thor is 110**, its own major, reachable from nothing else — the same
  shape as Orin's 87, and a deliberate not-yet for the arm64 lane.

The trailing-`90`→`90a` rewrite in `30-build-native-nvidia.sh` is GONE. ORT
appends the `a` itself, so it was redundant — and being a suffix match it would
have silently stopped firing the moment the list no longer ended in 90, which
is exactly what this change does. Its removal also retires the "keep this list
ascending" constraint that `versions.env` warned about.

Thirteen places carried the literal list; all moved together, including the
Windows Pester pin whose comment stated a standing owner directive ("NEVER
trim") that this decision supersedes. The directive survives in its real
meaning — no trimming as a speed lever — with the set named as a decision.

How to turn an arch on or off, with the four rules and the cost, is now in
`AGENTS.md` § GPU architecture coverage; the user-facing card list is in
README.md § Which GPUs `:latest-nvidia` runs on.

## 2026-09-22 - hcsshim fork rebased: `Install-NewHost` builds `5e9df53c` and re-pins a reused work dir; `Invoke-WithEnv` really removes

**`Kataglyphis/hcsshim@feature/configurable-teardown-timeout` is rebased onto upstream
`main` `0e1f18b7`.** The head moves from `19251429` to `5e9df53c`, and PR
microsoft/hcsshim#2855 follows it. The patch is unchanged: same patch-id, and none of the
26 new upstream commits touch `cmd/containerd-shim-runhcs-v1`, `internal/hcs`, `cow`,
`jobcontainers` or `uvm`. The new build is 25 890 304 bytes with Go 1.27.1, sha256
`7A4BF6A3…`, `vcs.modified=false`. `gofmt`, `go vet` and the shim package tests pass.

- `Install-NewHost.ps1` pins `$forkPin = 5e9df53c…`. The old commit is on no branch any
  more, so a fetch by its SHA works only as long as GitHub keeps the object.
- `Sync-ShimForkCheckout` is new. It also re-pins a `%TEMP%\kataglyphis-hcsshim-fork`
  left behind by an earlier run. Before this, a reused work dir skipped the fetch
  entirely, so a pin bump could quietly rebuild the old tree.
  - Tests: `NewHost.ShimFork.Tests.ps1` (3 cases).
  - Mutation-checked by hand against three broken copies of the function: re-pin
    skipped, always fetch, fetch error swallowed. Each one made a case fail.
- **The test harness's `Invoke-WithEnv` now really removes a variable.** A PowerShell
  `$null` reaches .NET's `SetEnvironmentVariable` as `''`. That leaves the variable set
  to an EMPTY value, which child processes still see. It had two effects:
  - `$null` in `-Vars` never removed a variable.
  - A variable that was unset before the call was left behind as empty, although the
    comment said "removing".
  - Measured on PS 7.6.6 / .NET 10: git then reads `GIT_DIR=''` and stops with
    `fatal: not a git repository: ''`. `cmd`'s `if defined` calls the same variable
    undefined, which is why nothing noticed before.
  - The fix passes `[NullString]::Value`. `Harness.WithEnv.Tests.ps1` (2 cases) and the
    shim-fork suite fail against the old version.
  - The budgets of two code-dupes pairs involving `TestHarness.psm1` shrank as a result
    (47 → 34, 35 → 28).
- Docs:
  - `windows-host-setup.md` § R1 has the new build numbers, the new stock size after
    Stevedore's 2026-09-21 update (25 975 296), and how to update an existing clone
    after a rebase.
  - `windows-build-lanes.md` and `failure-modes.md` name the new binary.
  - The `hcsshim-teardown-timeout/README.md` status header now records the rebase.

## 2026-09-22 - Windows `-Variant rocm`: the driver builds `:winamd64-rocm`

**`Build-Buildkit.ps1 -Variant rocm` builds the ROCm image.** It runs the default chain
up to media, then `Dockerfile.rocm` → torch → final under its own tags
(`bk-windows-rocm`, `bk-windows-torch-rocm`, `bk-winamd64-rocm`), so a rocm run never
overwrites the default images. `-Variant rocm -Stages rocm,torch,final` reuses an
existing default media.

- `-Variant ''|nvidia|rocm`; `-Gpu` stays and means nvidia. `Resolve-BkVariant` refuses
  before buildkitd is touched: rocm on arm64, `-Gpu` with rocm, `-Stages rocm` on another
  variant, and a push tag that does not match the variant (only rocm may push to
  `:winamd64-rocm`).
- `Install-Rocm.ps1` refuses a media base that carries `GPU_TYPE`, `CUDA_ROOT` or
  `CUDA_PATH`: the shared media tag can hold a leftover `-Gpu` build.
- Smoke: `EXPECT_ROCM=1` runs `Test-RocmImage.ps1` after the CPU suite. It checks the env
  contract, the absence of CUDA, that AMD's LLVM does not shadow `clang-cl`/`lld-link`,
  `.info\version`, the device bitcode, and a `hipcc --offload-arch=gfx1201` compile.
- Torch stays CPU until OrchestrANT has a Windows ROCm extra.
- The nvidia and default runs are unchanged: same tags, same push behaviour.
- Tests: `Driver.Variant.Tests.ps1` (8) and `Rocm.Install.Tests.ps1` (17).

## 2026-09-22 - Hooks on a Windows host: pre-push clears git's environment, the shellcheck ratchet grades again

**Git exports `GIT_DIR` (and `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_PREFIX`) to hooks,
and the pre-push hook passed them straight to the mutation gate.** Its fixtures run
`git -C <tmp> init`. With `GIT_DIR` set, each init re-initialised the REAL gitdir
instead of the temp one. For a submodule gitdir (`.git/modules/<name>`, a path that
does not end in `/.git`) git guesses "bare" and writes `core.bare = true`. Seen on a
push from this repo's checkout inside OmniAccelerANT: from then on every git command
warned `core.bare and core.worktree do not make sense`, `git status` refused to run,
and `git check-attr` found nothing, so the EOL-attribute suite failed on 64 files. The
branches and the index stayed untouched.

- `linux/host-config/git-hooks/pre-push` now runs `unset GIT_DIR GIT_WORK_TREE
  GIT_INDEX_FILE GIT_PREFIX` first, exactly as pre-commit already did.
- `test-prepush-hook.sh` runs the hook with all four variables exported and asserts that
  none reaches a gate. Mutation `mutations.push-clears-git-env` turns the `unset` into a
  no-op, and the test goes red.
- Recovery and the symptom text:
  [`docs/failure-modes.md`](docs/failure-modes.md#a-push-leaves-the-repo-bare-corebare-and-coreworktree-do-not-make-sense).

**The shellcheck warning ratchet never graded a file on a Windows host.** Two bugs:
- A bare `bash` in `subprocess` resolves to System32's WSL launcher before PATH. That
  launcher mangles the `C:\` script path, so every staged `.sh` failed the pre-commit
  ratchet.
- `--files` paths came back with `\`, while lint-shell.sh's scope uses `/`, so each file
  counted as "outside the scope" (0 of 394 graded).

`verify_shellcheck_warnings.py` now takes PATH's `bash` (`_bash()`), converts the MSYS
`--print-bin` answer with `cygpath -w`, and normalises `--files` to `/`. All three are
no-ops on Linux. Mutation `shellcheck-warnings.bash-from-path` bites the new
`test-shellcheck-warnings.sh` case. The suite itself still has 4 Linux-only assertions on
Windows, where it runs fake `shellcheck` scripts through native Python; at HEAD, 51 of
its 68 assertions failed there.

## 2026-09-22 - Windows ROCm layer: `windows/Dockerfile.rocm` + `Install-Rocm.ps1` (not wired yet)

**ROCm on Windows now has a build path.** It uses AMD's documented Windows tar
install: the same TheRock 10.0.0 release, from the same `stable.repo.amd.com` host,
that `setup-rocm-repo.sh` installs on Linux. The driver does not build it yet.
`-Variant rocm` is the next step.

- `windows/scripts/host/Install-Rocm.ps1`:
  - refuses anything but amd64;
  - downloads `therock-dist-windows-<family>-<release>.tar.gz` and verifies it
    against the pinned SHA256, refusing an empty pin;
  - extracts it with System32 `tar.exe` into `C:\TheRock\build`;
  - asserts the layout (hipcc, hipconfig, hipInfo, `amdhip64_*.dll`, the HIP
    headers, AMD's clang, the device bitcode, `.info\version` = the pin);
  - runs `hipcc --version` inside the container.
- `windows/Dockerfile.rocm` forks after media, right before torch, because nothing
  in the Windows media chain can consume ROCm: MIGraphX is Linux-only. It sets
  AMD's variables but never puts `lib\llvm\bin` (AMD's `clang-cl.exe`) on PATH, and
  appends `bin\` last.
- `versions.env`: `ROCM_WINDOWS_RELEASE=10.0.0`, `ROCM_WINDOWS_GFX_FAMILY=gfx120X-all`,
  `ROCM_WINDOWS_TARBALL_SHA256`. AMD publishes no checksum, so it is self-measured
  like `ROCM_GPG_KEY_SHA256`.
- `Rocm.Install.Tests.ps1` covers the URL guard, the amd64 refusal, the layout gate
  (each required file removed in turn must fail it) and the PATH rules.
- Why, the measured hashes and sizes, and the licence inventory:
  [`docs/windows-builds.md` § ROCm layer](docs/windows-builds.md#rocm-layer-dockerfilerocm).

## 2026-09-22 - ROCm ASAN is optional and OFF; the plan for the first `:latest-rocm` run

The owner asked for AMD's AddressSanitizer packages alongside the normal ones,
then decided against them as a default once the size was measured: >100 GiB in a
container image is not acceptable. So `ENABLE_ROCM_ASAN` (`Dockerfile.amd`,
default `false`) gates the parallel `packages-asan` repo stanza, the install of
`amdrocm-asan${ROCM_VERSION}`, and whether `copy_rocm_payload` lets
`/opt/rocm/core-asan-*` into the shipped image at all.

Measured against the live repo index on 2026-09-22, which is why it is off:
`amdrocm-llvm-dev-asan10.0` is **61.7 GiB** installed, the full ASAN set
**134.8 GiB** (the normal image is ~19 GiB), all 30 gfx-specific ASAN packages
are gfx942/gfx950 only, and there is no ASAN MIGraphX and no ASAN torch wheel —
so the two things this image exists for stay uninstrumented either way.

Co-installing also collides on `update-alternatives`: the ASAN debs register the
same names at the same priority, so `/opt/rocm/{core,lib,bin}` and `hipcc` can
resolve into the ASAN tree, and which one wins flips between rebuilds. The knob
therefore re-`--set`s every hijacked alternative back and then ASSERTS the normal
tree owns them, failing the build if not. None of this path has run yet.

Ten non-ASAN items from the same sweep are written up in
`docs/linux-accelerator-images.md` § ROCm, largest first: per-gfx metapackages
(~18.4 GiB -> 9-13 GiB), `ROCM_PATH`/`PATH` missing in the shipped image,
asserting the installed versions (`stable` is a ROLLING suite, so our
`ROCM_VERSION` pin is a label, not a constraint), the resolved `ld.so.conf`
path, `/dev/kfd` access for uid 1001, no `seccomp=unconfined` and no baked
`HSA_OVERRIDE_GFX_VERSION`, writable MIOpen caches, a GPU-less build-time
self-check (`amd-smi`, not the deprecated `rocm-smi`), AMD's CDI container
toolkit, and a Renovate comment that watches a git tag instead of the apt
package.

## 2026-09-22 - `:latest-cross` is retired, not deprecated

The alias lived for one day. The owner decided against a deprecation window, so
the mechanism is gone rather than disabled: `CROSS_LEGACY_ALIAS_TAG`,
`cross_final_image_legacy_alias` and the second `manifest push` in
`build-runtime-manifest.sh` are deleted. From here on a release publishes
`:latest` and nothing else.

**The registry tags stay, and deleting them would take the fleet's Linux CI down
with them.** Every consumer resolves its container ref
through this repo's composite actions pinned at `@main` (98 `...@main` refs
across six repos, none passing an explicit `image:`), and `main` is 56 commits
behind: it still says `CI_IMAGE_LINUX_TAG=latest-cross` and both action defaults
still name the old tag. So the tag the fleet actually pulls today is
`:latest-cross`. The owner decided to stay on `develop`, so that merge is not scheduled:
`:latest-cross` remains the fleet's CI ref, frozen at the last release that
published it. It is documented as do-not-delete rather than pending.

The deletion itself is also not a plain "delete the version": `:latest` and
`:latest-cross` are ONE GHCR package version (`sha256:e0de6c95…`, and the same
for the arm64/riscv64 pairs), and GHCR deletes by version, not by tag. The old
name has to be made a version of its own first, or the deletion has to wait for
the release after which `:latest` has moved on and `:latest-cross` is frozen
alone. `ghcr-delete-tags.sh` already refuses the unsafe form: it skips a version
whose digest is shared with a tag being kept, so running it today is a no-op,
not a disaster (`docs/linux-host-setup.md` § B8).

`test-tag-naming.sh` keeps a regression guard: no tag function may compose the
old name again. Dated history keeps it, because the tag really was called that.

## 2026-09-22 - GPU variant chains: `CROSS_VARIANT=nvidia|rocm` builds `:latest-nvidia` / `:latest-rocm`

**A GPU image is now a variant CHAIN, not a toggle on the default one.**
Before this change `ENABLE_NVIDIA=true` / `ENABLE_AMD=true` changed only the
build args. A GPU run would have pushed CUDA bytes under the default
`cross-media-<arch>`, `cross-android-<arch>`, `:latest-<arch>` and `:latest`. The
NVIDIA/AMD layers were not stages at all, only hand-run commands whose tags were
deleted from the registry this morning.

- **Tags.** `CROSS_VARIANT` (implied by `ENABLE_NVIDIA`/`ENABLE_AMD`; both is an
  error) adds `-<variant>` to every tag from the new `gpu` stage on:
  `:cross-toolchain-<v>-<arch>`, `:cross-media-<v>-<arch>`,
  `:cross-android-<v>-<arch>`, `:latest-<v>-<arch>` and the manifest
  `:latest-<v>`. Base, compiler and sdk stay shared. A variant never gets the
  `:latest-cross` alias.
- **Stage graph.** `gpu` (`Dockerfile.nvidia` / `Dockerfile.amd`) goes between
  sdk and media when a variant is set. The default graph is unchanged.
- **Refusals** (`stage-defs.sh` `cross_variant_refusal`, shared by
  `build-cross-chain.sh` and `build-cross-stage.sh`):
  - A variant starts at `gpu` and refuses to build base, compiler or sdk.
  - Every target must be the build platform's arch, because CUDA/ROCm are
    installed for and compiled against it. rocm is amd64-only.
  - A pushing variant must build on `linux/amd64`, because the shared
    `:cross-sdk-<arch>` it builds on is the amd64 lane's.
  - The Jetson lane (native, `--no-push`) stays allowed.
  - The variant's `ENABLE_*` / `ENABLE_TENSORRT` are exported where the graph
    is built. Otherwise a single-stage rebuild wrote CPU bytes under
    `-nvidia` tags.
- **Runtime helpers.** `build-runtime-artifacts.sh` and
  `build-runtime-manifest.sh` refuse an output prefix without `-<variant>`, and
  `build-runtime-artifacts.sh` defaults to `cross_final_image_tag`. Before
  this, `ENABLE_NVIDIA=true build-runtime-artifacts.sh --push` published a
  CUDA wrapper as `:latest-amd64`.
- **Strictly serial** (owner decision). The pidfile is claimed atomically
  (noclobber) at the check, and a live chain makes a second one refuse to
  start. Chains share the buildkit store and the disk guard, and the guard
  evicts whatever the running chain does not protect. A variant keeps its own
  `chain-status-<v>.json` and `out/build-logs/<v>/` (also when `make`
  passes the default `--log-dir`). Its runtime lane budgets 180 GB.
- **NVIDIA defaults.** `ENABLE_TENSORRT=false` (no `libnvinfer` in the runtime
  payload yet). The wrappers take `onnxruntime-gpu` + `pytorch-cu130`.
- **ROCm runtime.** `copy_rocm_payload` copies `/opt/rocm` into the package,
  and `000-rocm.conf` puts its libraries on the loader path. Before this, the
  MIGraphX EP had nothing to load.
  - TheRock's absolute `update-alternatives` links are resolved hop by hop
    inside the artifact and re-made relative.
  - A tree without `libamdhip64` is fatal.
  - `Dockerfile.package` now passes `ENABLE_AMD` to the copy; without it the
    copy never ran. The wrappers take `onnxruntime-migraphx` +
  the app's `pytorch-rocm71` extra. That index stops at torch 2.13, so the pin
  enforcement now re-installs the `PYTORCH_VERSION` pair from the new
  `PYTORCH_ROCM_INDEX=rocm7.14` (there is no rocm10 line). The old code's CPU
  fallback would have swapped a ROCm torch for a CPU one without a word.
- **One onnxruntime flavour per GPU venv.** The amd64 CPU `onnxruntime_dnnl`
  (and a plain `onnxruntime`) are pruned next to `onnxruntime_gpu` /
  `onnxruntime_migraphx`. Before this, both force-installed into one
  `site-packages/onnxruntime/`, and ARCH-PARITY refused the image. The parity
  table knows `ENABLE_AMD` → `onnxruntime_migraphx`, and the rocm wrapper gets
  the build-time twin of the CUDA check: `torch.version.hip` plus
  `MIGraphXExecutionProvider`.
- **Reviewed before merge.** An adversarial review (34 findings, 22 upheld by
  two independent skeptics) produced the items above. It also raised
  `test-gpu-variant.sh` (45 assertions, through the real entry points in
  read-only modes) and env-isolated the default tag suites.
- **The Jetson lane's names** follow the variant: the example image is
  `:latest-nvidia-hostarm64-arm64`.
- **arm64 CUDA from an amd64 host is feasible but not built.** NVIDIA's
  `ubuntu2604/cross-linux-sbsa` repo carries `cuda-cross-sbsa-13-4`, the cross
  cuBLAS/cuFFT/cuSPARSE/cuRAND and `libcudnn9-cross-sbsa-cuda-13`. NCCL exists
  only as a native sbsa `.deb` (unpack it into the target tree). Wiring it needs
  the ORT/OpenCV/TVM CUDA cross flags and an ELF-machine gate. Until then, the
  arm64 half of `:latest-nvidia` is built natively.


## 2026-09-22 - `:latest-cross` becomes `:latest`; variants are `:latest-<variant>`; the `:hailo` variant is retired

**The Linux default manifest is `:latest`** (owner directive 2026-09-22). The
old name was historical. `CI_IMAGE_LINUX_TAG=latest`, and every derived tag
follows the prefix: wrappers `:latest-<arch>`, runtime stages
`:latest-base-<arch>` / `:latest-package-<arch>`, host-infixed runs
`:latest-hostarm64`. The registry was switched without a rebuild. The live
3-arch index (`sha256:e0de6c95…`) and its three children were re-tagged
`:latest` and `:latest-{amd64,arm64,riscv64}`, so `:latest` and `:latest-cross`
resolve to identical bytes. The old dead `:latest` from the ghcr-cleanup bug
was already gone (404), so nothing was overwritten.

**`:latest-cross` stays as a deprecated alias until 2026-10-31.**
`build-runtime-manifest.sh` now also pushes the same index under the name in
`CROSS_LEGACY_ALIAS_TAG` (`cross_final_image_legacy_alias` in `tag-naming.sh`).
That happens only for the amd64 lane's default image, and only after `:latest`
passed every gate. After the date, empty the key and delete the tag. The
freshness check now receives `--tag` for the index the run actually wrote,
instead of always reading the default.

**Variant grammar: `<version>[-<variant>][-<arch>]`.** Variants exist only for
stacks that cannot ship in `:latest`, which today means `:latest-nvidia` and
`:latest-rocm` (`rocm`, not `amd`, so a variant never reads like an arch).
**Neither is published yet.** The registry's `:nvidia` / `:amd` tags are
single-arch 2026-04 builds on the Ubuntu 24.04 base and were deliberately *not*
promoted. Hailo and QNN are built into `:latest` instead. The current release
carries HailoRT 5.4.0 + `hailonet` on amd64/arm64 (verified in the shipped
wrappers). It carries no QNN, because no QAIRT zip was staged in
`linux/qnn-sdk/` for that build.

**The standalone Hailo variant is gone.** `linux/Dockerfile.hailo` is deleted,
along with its two `code-dupes.allow` rows. The published `:hailo` (run
`20260919-…`) was a generation older than the standard wrapper that already
carried the same payload.

**Registry cleanup (same day):** 21 stale tagged versions deleted after
proving no kept index referenced any of them: `:hailo`, `:hailo-amd64`,
`:hailo-arm64`; the April GPU chains (`:nvidia`, `:amd`, `toolchain-`/`media-`/
`android-`/`torch-` `nvidia`/`amd`, `toolchain-amd`, `latest-cross-nvidia-amd64`);
the old-name runtime intermediates `latest-cross-{base,package}-{amd64,arm64,riscv64}`;
and the pre-chain `:toolchain`. No `buildcache-*` tags existed.


## 2026-09-22 - The arm64 GPU runtime image runs on a Jetson

The runtime lane (base -> package -> wrapper) had never carried a GPU. Built
natively on a Jetson AGX Orin with `ENABLE_NVIDIA=true`, it now ships CUDA,
cuDNN and NCCL into the package, and installs `pytorch-cu130` and
`onnxruntime-gpu` in the wrapper. On the Orin's GPU (see
`docs/linux-host-setup.md` § B2b for the rootless call):

- PyTorch: `cuda available: True`, device `Orin (8, 7)`, a matmul matching the CPU.
- ONNX Runtime 1.29: a MatMul served by `CUDAExecutionProvider`.
- OpenCV 5.0 CUDA: one device, `cuda.threshold` bit-identical to the CPU.
- `nvcc -arch=sm_87` in the image: a kernel over 1M elements, 0 wrong.

Fixed on the way, each with a suite that goes red when the fix is removed:
`--no-push` wrapper builds could not see the android wheels (now a directory
context), the torch pin step swapped CUDA torch back to CPU, a read-only
`/opt/wheels` made the ORT-variant prune fail silently, GenAI asked for TRT-RTX
without TensorRT, the Vulkan prune left 1.8 GB of x86-64 in the arm64 image on
a non-amd64 builder, and the arm64 gtk4 exception now follows the loader rather
than the arch.

A USB camera works too: `linux/jetson-webcam/run.sh` streams SSDLite
detections from the Orin's GPU to a browser at the camera's 30 fps, 13 ms per
inference. torchvision's own call managed 9 fps: its per-class postprocess spent
182 ms launching kernels. The app replays the network from a CUDA graph and runs
one vectorized NMS, with the same detections.

Not yet: the image's media layer predates the 2026-09-18 pin wave (ORT 1.29,
GenAI still `trt-rtx`), and the official PyTorch `cu130` wheels warn that they
do not target compute capability 8.7.


## 2026-09-21 - The arm64 CUDA/cuDNN lane builds natively on SBSA

The GPU lane had never been built on arm64. Built on a Jetson AGX Orin, for
arm64 only, base through media with NVIDIA's SBSA CUDA 13.3, cuDNN 9.26 and
NCCL. ORT's CUDA provider, 11 OpenCV CUDA modules and TVM's CUDA runtime carry
`sm_80 sm_86 sm_87 sm_89 sm_90`; ffmpeg links NVENC/NVDEC.

Two defects blocked the GPU layer on EVERY arch: NVIDIA's repository path used
the Ubuntu codename (a 404) and both keyring SHA pins were stale. The rest was
arm64 enablement: `sm_87` in `CUDA_ARCHITECTURES`, `CUDA_ARCH_BIN` for OpenCV,
`ENABLE_TENSORRT=false` and `CUDA_INSTALL_COMPAT=0` for a Jetson, the image's
GCC 16 kept with `NVCC_PREPEND_FLAGS=-allow-unsupported-compiler`, a
`CUDA_MB_PER_CICC` job budget against `cicc` peaks, `/tmp` restored after
`COPY --link`, and ffmpeg's nonfree `--enable-cuda-nvcc` dropped. The chain
still has no NVIDIA stage; the layer is inserted by hand
(`docs/linux-accelerator-images.md` § NVIDIA on arm64 (SBSA)).


## 2026-09-21 - HailoRT on Windows (Phase 3): library + CLI, both arches

The Windows lane now builds HailoRT like the Linux lane does - from the
SHA-pinned v5.4.0 tarball, with the same ten externals staged offline at the
same commits - as a `media-core-built-hailo` branch between opencv and the core
merge, installed to `C:\runtime\hailo`. Probe-proven on amd64
(`out/build-logs/probe-hailo-amd64-*`: `libhailort.dll` PE 0x8664 +
`hailortcli.exe`); the arm64 cross build rides the same branch.

Three upstream Windows/clang-cl gaps had to be patched, each found live and
documented in `docs/hailo-support.md` § Phase 3:

- `quantization.hpp`'s `bankers_round` keys on `_MSC_VER` - which clang-cl
  defines on every arch - so the x86 intrinsics fail on ARM64 and on a bare x64
  clang-cl without `-msse4.1`.
- `driver_os_specific.cpp` writes explicit-specialization members without
  `template<>`, which clang-cl enforces.
- `os/windows/filesystem.cpp` omits `LockedFile::~LockedFile()` while the header
  declares it, so `hailortcli` cannot link.

Not yet: TAPPAS (Linux-only), the pyhailort wheel, the GStreamer `hailonet`
element on Windows, and device execution.

## 2026-09-20 - Windows-on-ARM64 CUDA/cuDNN: the cross lane is wired (#176)

The arm64 lane built its **CUDA stack for the first time**, on the x64 host, with no
arm64 device involved. Final run `bk-20260920-203631` (2:45:53): smoke **120/0/15**,
arch gate **1047/0**, and every CUDA artefact 0xAA64.

- **Payload**: `Install-Cuda.ps1 -TargetArch arm64` keeps the x64 toolkit (headers
  + nvcc are the host tools) and stages the arm64 redist components
  (`cuda_cudart`, `libcublas`, `libcufft`, `libcurand`, `libnvjitlink`, `libnpp`,
  `libcusolver`, `libcusparse`) into the same root as `lib\arm64` / `bin\arm64`,
  plus the arm64 cuDNN archive. NVIDIA names the arm64 cuDNN archive `_cuda13.4`
  where the x64 one is `_cuda13` — the URL builder is arch-aware now. Every archive
  SHA-pinned in `versions.env` (`redistrib_13.4.2.json` / `redistrib_9.26.0.json`).
- **Build**: `Get-NvccHostCompilerPath` is the one owner of the nvcc host compiler
  (native x64 cl, cross `Hostx64\arm64` cl) and `Get-NvccCudaCmakeArgs` adds
  `nvcc --use-local-env` on cross — the documented x64→ARM64 flow. ORT, GenAI,
  OpenCV and TVM each enable CUDA on the cross lane only when
  `Test-CudaWindowsArm64Payload` finds the payload — a positive signal, never a host
  GPU probe. Classic TensorRT stays OFF on cross (x64-only).
- **OpenCV**: NPP was the missing link (`CUDA::nppial`/`nppif`), and cudafilters'
  `wavelet_matrix_2d.cuh` used the x86-only `_mm_popcnt_u64`; the guard change alone
  was not enough because nvcc's device pass rejects `__builtin_popcountll` too, so
  the ARM64 branch is a software popcount (patch probe-proven in
  `out/probe-arm64-popcount`). TVM's legacy FindCUDA hardcodes `lib\x64`, so the
  cross branch names the arm64 `CUDA_CUDART/CUBLAS/CUDA_LIBRARY`, host compiler and
  `--use-local-env` explicitly.
- **Gates**: `-Gpu -TargetArch arm64` is a supported driver combination; the cross
  smoke gets `EXPECT_GPU` (a lost CUDA env reds instead of skipping) and its cuDNN
  run-probe became a link + PE-machine assert (`Assert-NativeLinkRun -CrossLinkOnly`),
  because an aarch64 DLL cannot execute on the x64 host.

## 2026-09-20 - the GPU lane's smoke stops demanding an EULA payload nobody staged

The `-Gpu` amd64 chain built green through `final` -- CUDA EP, cuDNN, OpenCV
`WITH_CUDA`, GenAI-CUDA, the torch-app ORT+CUDA venv and the IREE CUDA-target
compile all passed -- but the smoke gate returned 225/228: all three reds were
the TensorRT asserts, on a host with no TensorRT zip, which is the documented
NORMAL state. `windows-builds.md` § TensorRT setup already ruled that the
zip-less lane must pass ("do NOT re-harden this into a fail-fast"), so the
asserts were the defect:

- `Test-TensorRtTreeStaged` (`WindowsSmokeTest.Common`) applies the same
  presence rule as the build's `Resolve-TensorRtRoot`: root set, exists,
  non-empty. The guaranteed-empty `C:\tensorrt` is NOT staged.
- §8/§20 branch on it: staged -> `cuda=1 trt=1` + the provider DLL + the python
  TRT EP; zip-less -> `cuda=1 trt=0` + no provider DLL + python CUDA-EP only.
  CUDA stays hard in both branches, nothing is skipped, and a staged tree with a
  silently-disabled EP still reds.
- Pester coverage for the decision (unset, missing, empty, one entry); the
  Windows suite is green at 864/864.

## 2026-09-20 — the torchvision pair fix, and the Hailo variant

**The Linux rebuild's version-pin assertion caught a mismatched
torch/torchvision pair.** The 2026-09-18 wave bumped `TORCHVISION_VERSION` to
v0.29.0 while `PYTORCH_VERSION` stayed v2.13.0; pytorch/vision's compatibility
table pairs torch 2.13 with torchvision **0.28** (0.29 needs torch 2.14), and
both the wheelhouse's built-in fallback and OrchestrANT's lock install 0.28.0 —
so the runtime image shipped 0.28.0 and `assert_pinned_versions` failed the
amd64 smoke with `installed 0.28.0+cpu NOT in expected ['0.29.0']`. Reverted
the pin to v0.28.0 with a `bump:hold` note that re-derives from the table at
every torch bump. The wrappers were already built and pushed; the manifest was
repaired with `build-runtime-manifest.sh --repair --push-manifest` (no image
rebuilds) and the published index now carries this run's three wrappers.

**A second gap the incident exposed, deliberately not fixed here.**
`Dockerfile.media` never declares `PYTORCH_VERSION`/`TORCHVISION_VERSION` as
ARGs, so the app-wheelhouse RUN cannot see them and falls back to the script's
built-in defaults — which also means the layer cache does not re-key on a
version bump. It stayed invisible only while the pin equalled the fallback.
Wiring it re-keys the wheelhouse for all three arches (hours under QEMU); it
needs a planned window, and it is tracked in
[`docs/refactoring-backlog.md`](docs/refactoring-backlog.md).

**Hailo support landed as the opt-in `:hailo` variant**
([`docs/hailo-support.md`](docs/hailo-support.md)). `linux/Dockerfile.hailo`
builds HailoRT 4.24.0 (the `hailo8` line — Hailo-8/8R/8L) plus `hailortcli` and
the `hailonet` GStreamer element against the media image's GStreamer, offline
against verified protobuf 21.12 and gRPC 1.54.0 sources, then copies the
payload into the published runtime image. Run it with `--device=/dev/hailo0` on
a host that loaded the GPL-2.0 `hailo_pci` driver. The standard `:latest-cross`
is untouched — the variant builds after the runtime lane, like `:nvidia`/`:amd`.
`pyhailort` is deliberately not built (the public package ships only in Hailo's
`.deb`). Pins live in `versions.env`, licence rows in `docs/deps/deps.json`
(MIT, and LGPL-2.1-or-later with a source pointer), and
`sync_versions.py --check` is green. **Both arches built, verified and
published the same day** as `:hailo-amd64` / `:hailo-arm64`, joined into the
multi-arch `:hailo` manifest — `hailortcli --version` reports 4.24.0 and
`gst-inspect-1.0 hailonet` resolves the element in both shipped images. Three
build attempts shaped the final design: the offline externals must sit at the
literal `<src>/hailort/external/<name>-src` paths (16 of them, commit-verified);
the base runtime runs as uid 1001, so the payload copy needs an explicit
`USER root`; and the builder is the **runtime image itself**, not
`cross-android-<arch>` — those are amd64-hosted cross toolchains, and HailoRT's
nested FetchContent cmake cannot be reached by a cross `CMAKE_C_COMPILER`
(`as: unrecognized option '-EL'`, then a stale cross cache producing a
Ninja/RPATH "not ELF-based" error). Native is slower on arm64 under QEMU and
correct. riscv64 has no HailoRT support at any version; the script refuses it.

**Torch 2.14 + torchvision 0.29 land in `:latest-cross`, and Hailo becomes
standard.** The pins move to the valid pair (`PYTORCH_VERSION=v2.14.0`,
`TORCHVISION_VERSION=v0.29.0`); riscv64 has no upstream wheels, so it
source-builds the same pair (an interim `<KEY>_RISCV64` override keeping it at
v2.13.0/v0.28.0 was removed when WH1 closed — see the entries below). `assemble-torch-app.sh` gained
`enforce_torch_version_pins`: on the arches with cp314 wheels (amd64, arm64) the
runtime force-installs the pinned pair from the CPU index after the lock-driven
sync, so the shipped venv matches the build pins the smoke asserts — the app
lock (OrchestrANT) lags them. And HailoRT + hailortcli + hailonet are now built
in `Dockerfile.torch` for amd64 and arm64 (riscv64 skips), so every
`:latest-cross` wrapper carries Hailo by default; the `:hailo` variant stays as
a convenience tag.

**Hailo switches to Hailo-10H, Hailo-8 is dropped, pyhailort is built, TAPPAS
is declined, the Dataflow Compiler is staged.** `HAILORT_VERSION` moves to
**5.4.0** (`master`, the Hailo-10/15 line) and the externals are re-derived for
that tree — no gRPC (master has no `grpc.cmake`), with minja, tl-expected and
the newer cli11/json pins; libusb/tokenizers/slint/montserrat stay unstaged
because their features (USB, servers) are off. `build-hailort.sh` now also
builds the **pyhailort** wheel from `bindings/python/platform/`
(scikit-build-core) and installs it into `/opt/venv` with upstream's
`requires-python <3.14` relaxed and an import test — the image runs 3.14, and a
failed import is reported, not hidden. **TAPPAS stays out**: v5.4.0 supports
GStreamer 1.16–1.20 while this image ships 1.29.2; the `hailonet` element is
the pipeline integration the repo needs. The **Dataflow Compiler** is
login-gated and x86_64-only, so it gets the QNN-style staged drop point
`linux/hailo-sdk/` (the amd64 wrapper installs a staged wheel; the Model Zoo
stays a host-side tool).

**WH1 is closed: the app wheelhouse's refs are wired, and all three arches now
carry torch 2.14 / torchvision 0.29.** `Dockerfile.media`'s `app-wheelhouse`
stage gained `ARG PYTORCH_VERSION` / `TORCHVISION_VERSION` / `IREE_VERSION` and
exports them to `build-app-wheelhouse.sh`, which previously fell back to its
built-in `v2.13.0`/`v0.28.0`/`v3.11.0` defaults and did not even re-key on a
pin bump. riscv64 has no upstream torch wheels, so its media stage SOURCE-BUILDS
the same refs — the per-arch `PYTORCH_VERSION_RISCV64` overrides are gone, and
with them the 2.13/0.28 split the first rebuild exposed.

**TAPPAS is built against GStreamer 1.29.2 — with build-args, not patches.**
The plan had it as blocked (its README names 1.16-1.20 as the supported
matrix), but that is the TESTED matrix: the meson constraint is `>= 1.0` and a
spike proved a clean build. What actually had to change: `libargs` is a Meson
ARRAY and its elements must be comma-separated (a space-joined value silently
keeps only the last element, and every HailoRT header then goes missing);
`libxtensor`/`libcxxopts`/`librapidjson` must point at `core/open_source/`;
that tree's header-only dependencies (xtensor, xtl, cxxopts, pybind11,
rapidjson, Catch2) are staged at pinned commits because upstream clones them
from BRANCHES (rapidjson: master); and **libzmq** is built in (MPL-2.0) for
the `hailoexportzmq`/`hailoimportzmq` elements, since the runtime image has no
usable apt. `gst-inspect-1.0 hailotools` passes in the built image, and the
plugin is staged into the same plugin dir as `hailonet`. Also fixed on the way:
`HAILO_BUILD_TOOLS=OFF` (the v5.4.0 tarball ships no `tools/` dir, so ON makes
CMake die), the missing `mkdir -p` that made the HailoRT download fail with
curl error 23, and pyhailort's `requires-python <3.14` metadata (relaxed before
the wheel build, import-tested after).

## 2026-09-19 - the Windows dual-lane rebuild: two build-killers fixed, CUDA on the network installer

The first rebuild of the 2026-09-17/18 wave ran **green on BOTH Windows lanes** —
amd64 6:29 (smoke 198/0/1), arm64 2:43 (smoke 102/0/16) — after the chain found
two build-killers, both fixed and probe-verified:

- **The VS stable channel stopped REGISTERING
  `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`** while its files stayed on
  disk, so CPython's `find_msbuild.bat` (vswhere) died with `Failed to find
  MSBuild` ~80 min in. `Install-Vs.ps1` now `--add`s the component explicitly
  and the base asserts the **vswhere query** — a file check passes on the broken
  shape, which is exactly how it escaped.
- **The 3.9 GB CUDA 13.4.2 full installer dies in-container with `0xE0E00064`**
  (self-extraction on the wcifs layer; silent, no logs; the network installer
  succeeds with identical flags). `Install-Cuda.ps1` uses the **network
  installer with a pinned 37-subpackage list** instead: 10 MB download, ~2 min
  install, CCCL/Thrust included, and the SHA pin moved with it.

Also landed the same day: the ghcr credential helper (`credsStore: wincred`)
was replaced by a direct auth entry so `-PushRef` can publish; CUDA 13.4.2's
renamed installer and the sccache 0.18 zip were proven by the runs; the sccache
CUDA canary is still owed before `cuda_llm` is re-wrapped.

## 2026-09-18 - the dependency wave, and sccache 0.18 retires its source build

**Reported by Renovate (local CLI, 35 updates), applied through the two tools
that own the writes; nothing was proven by a build.** The Windows base and the
Linux chain must prove it in the next window.

**Renovate's allowed set (12 lines):** `actions/checkout` v6.0.2,
`docker/login-action` v4.0.0, `github/codeql-action`, `actions/upload-artifact`,
`astral-sh/setup-uv` pins, and `SYFT_VERSION=v1.52.0` (a self-contained key its
file-scoped packageRule clears). The other 23 reported updates are
`dependencyDashboardApproval`-gated by design and were applied by hand, which is
the documented ritual for them.

**Safe + report tiers (`bump_versions.py --write-all`, checksums refreshed with
each version):** uv 0.12.16, node 26.9.0, ollama 0.34.2, flutter 3.47.4,
LiteRT-LM 0.17.1, the ubuntu base digest, syft v1.52.0.

**Hand bumps (Renovate-visible, no programmatic checksum source):**
LLVM 23.1.1 on BOTH lanes - `LLVM_RELEASE` + `LLVM_COMMIT=e7ce3600` +
`LLVM_WINDOWS_VERSION` + the 23.1.1 source-tarball SHA + the aarch64
compiler-rt SHA (now pinned instead of warn-unverified); onnxruntime v1.30.0;
FFmpeg n9.0.1; openvino 2026.4.0; ComputeLibrary v53.3.0; torchvision v0.29.0;
openh264 2.6.0; ruff 0.16.8; sccache 0.18.0 on both lanes.

**The one patch this wave retires: the Windows sccache source build.** 0.18.0
ships mozilla/sccache#2722 + #2811 + #2816 - the three fixes `SCCACHE_GIT_REV`
was pinning - so `Install-RustToolchain.ps1` now installs the released
`x86_64-pc-windows-msvc` zip against a new `SCCACHE_WINDOWS_ZIP_SHA256`, the
scoop sccache install is gone, and `SCCACHE_GIT_REV` is deleted from
`versions.env`, the base ARG, the driver, and `bump_versions.py`. **The CUDA
canary bar stands:** `cuda_llm` stays on bare nvcc until a candidate sccache
passes `verify-cuda-cache` + the ONNX fused_moe canary; history and the bar are
in [`windows-build-resources.md`](docs/windows-build-resources.md).

**The patch audit found nothing else to retire.** Every other local patch still
fixes something the pinned version lacks - including on LLVM 23.1.1, which does
NOT carry llvm#219275 (merged 2026-09-16, after the tag) and whose #219276 is
still open. The full per-patch verdicts are in
[`upstream-windows-patches.md`](docs/upstream-windows-patches.md) and
[`upstreamable-patches.md`](docs/upstreamable-patches.md), both refreshed.

**Not bumped, deliberately:** protobuf 36.2 - `PROTOC_VERSION` is slaved to
LiteRT-LM's vendored pin (`bump:hold`). The `renovate` row reported a
`sha512-...` value, which is a datasource artifact, not a version; the approval
gate keeps it from being written. **CUDA 13.4.2 landed later the same day**
once the 404 was explained: 13.4 renamed the Windows installer to
`cuda_<v>_windows_x86_64.exe`, `Install-Cuda.ps1` now picks the name by
version, `spec_cuda` follows, and `CUDA_INSTALLER_SHA256` was refreshed from the
downloaded installer.

CON4 is measured and closed: winamd64 was Dart 3.12.2 / Flutter 3.44.8 against
`:latest-cross` Dart 3.13.3 / Flutter 3.47.3. Both pins are now 3.47.4, so the
next Windows rebuild is what aligns them; the backlog entry is gone.

**F1's last outside-the-closure row closed.** `docs/scripts/bump_versions.py
main` (160 lines) is 32: `linux/scripts/tests/test-bump-versions.sh` drives the
real `main()` in-process over fake tiers (40 assertions: the `--only` refusal,
the lookup-failure sweep contract, `--check`/`--write`/`--write-all`, `bump:hold`,
the UNCLASSIFIED self-audit and the offline half of `--audit-sha-pairs`), and the
split into `_parse_args` / `_lookup` / `_sweep` / `_safe_row` / `_report_row` /
`_write_phase` plus the reporting helpers kept rc, stdout, stderr and the
written bytes identical to HEAD's for the same inputs (checked side by side).
The `function-size.allow` and `code-complexity.allow` rows are deleted, and the
`file-size.allow` row is re-trued to 1116.

**The Linux backlog's two owner questions are answered; the list is now two
registers.** `06-packaging/package_archive.sh` HAS a consumer: OxidANT's
`.github/workflows/rust_ubuntu26_04.yml:204` runs the hub path directly, so the
`--appdata-file`/`--app-id`/`--appimage-extract-and-run` CLI contract is live and
the script stays — the `shellcheck-warnings.allow` row's "Needs the OWNER" is
replaced by that evidence, and `docs/code-quality-tooling.md` names it. The QNN
SDK pin stays at v2.49.0.260730: only a newer SDK needs a re-pin, none is staged
and the fetch is login-gated. The consumer inventory did not catch the consumer
because its `linux-script` class covers `linux/scripts/*.sh` only and treats the
stage trees as reached THROUGH the top level; OxidANT proves a direct call
exists, and the class note now says so.

The two 2026-09-03 audit questions that section also carried were already
answered on 2026-09-17 — `Get-Pin` strips the surrounding quote pair (proved by
the passing `CUDA_ARCHITECTURES` assertion over the quoted value), and
`sync_versions.py`'s `check_script_defaults` glob matches the renamed
`windows/scripts/**/Build-*FromSource.ps1` scripts with the TVM_COMMIT→TVM_REF
exception the PinParity suite documents.

**The first rebuild caught the LLVM pin — and the catch is the pin doing its
job.** `LLVM_COMMIT` had been set to `e7ce3600`, which is the ANNOTATED TAG
OBJECT of `llvmorg-23.1.1`, not the commit it peels to. The compiler stage's
clone-time assertion (`llvm_assert_commit_pin` compares `git rev-parse HEAD`
against the pin) died with `resolved to 6dfe1677…, but LLVM_COMMIT pins
e7ce3600…`. Fixed to the peeled commit
`6dfe1677ab8dffbc6ec13d53a1e0215d75147689` in `versions.env` and in
`test-native-build-host.sh`, which had locked the wrong hash. The 22.1.8 and
23.1.0 rows above it were correct peeled commits, so only the 23.1.1 row was
mis-copied from `git ls-remote`'s first (tag-object) line.

## 2026-09-17 — the F4 extraction wave, CON1-CON6, and the Windows defect batch

**Nothing in this entry was proven by an image rebuild.** The Linux chain was not
rebuilt and no Windows image was rebuilt — the container-side files are cache
inputs of the next window — so every verdict below is a static gate, a bash suite
or a Pester assertion on an idle tree. The 2026-09-05 lesson is the standing
warning: a full green battery preceded two build-killing bugs found in minutes.
The full narratives live in
[`refactoring-backlog-archive-2026-09-17.md`](docs/refactoring-backlog-archive-2026-09-17.md)
and
[`windows-backlog-archive-2026-09-17.md`](docs/windows-backlog-archive-2026-09-17.md);
the two open backlogs keep only pointers and open work.

**F4: all 27 PowerShell extractions applied.** Every row the 2026-09-09 review
identified and left unapplied is done: `Get-CommandParameterArgumentMap` +
`Get-AstDefaultValue` in the pin-parity suite (233 → 154), `WriteArMemberHeader`
(85 → 74), the hoisted `$newFakeSccache` (28 → 26), `$newStageTree`,
`Assert-ManualTestOutcome`, `Get-ProjectSourceFiles` (118 → 43), the uv-delegate
repoint to `New-UvBuildDelegates` (a row retired), `Enable-SccacheCompilerWrapper`
(30 → 20), the LSM module's five-function surface, the docker/buildctl candidate
owners (`Get-PreferredToolPath`, `Resolve-BuildCtlPath`), `Show-Exclusions`,
`Assert-FileSha256` at four call sites, `Install-AArch64CompilerRt` (with
`Install-ScoopTools` keeping a forced copy the base-stage closure cannot call),
`Assert-NoCacheStageMatched`, and the coordinator's `Start-HostServices`.
`docs/scripts/code-dupes.allow` records **39 stale rows removed, 22 budgets
re-trued, 2 added**; the finding arm is clean and the allowlist stands at **591**
pairs. Honest residue, both in the archive: twelve rows survive because the
overlap shrank without going under the threshold (eleven still say "NOT YET
APPLIED" in their frozen reason, which only the allowlist writer may re-word),
and one budget row measured 12 against a recorded 13 at this tip — a suppression
flip the gate reports as a stale freeze, not a finding.

**AS1 residual closed.** The compiler-stage host stanza derives from
`build_arch_oci` instead of a literal `amd64`; `cross-apt.sh` gained
`cross_apt_sources_file_for_arch` / `cross_apt_mirror_url_for_arch`, so an
amd64/i386 cross target gets a real archive file and not just an added
architecture; and `FAST_UBUNTU_REWRITE_SECURITY` flipped to default-true, so the
host `-security` comes from the same archive as the target pocket (the explicit
`false` opt-out stays, and so do the tests on both arms).

**CON1, CON2, CON3, CON5, CON6 closed; CON4 blocked.** The web lane installs
`RUST_NIGHTLY_TOOLCHAIN` (`nightly-2026-06-28`) — a dated pin is a no-op on a
warm image, where the floating channel is updated and dies on EXDEV out of a
read-only layer. The flatpak refs are probed in both scopes through one owner
(`app_packaging_flatpak_ensure_refs`), deleting the ~1.9 GB per-user duplicate
pull. `GSTREAMER_ROOT_ANDROID` was verified already exported (`Dockerfile.android`
and `Dockerfile.package`) — no edit. API 37
(`ANDROID_EXTRA_COMPILE_SDK=37.0`, build-tools 37.0.0) ships beside 36, so the
consumer's `permission_handler_android` pin can be dropped once the image ships.
`KATAGLYPHIS_FLATPAK_FINISH_ARGS` appends to the generated finish-args through
`app_packaging_flatpak_finish_args_block`, registered in
`lint-env-knobs.allow`. **CON4 stays open, blocked:** the Linux half measured
Dart 3.13.3 / Flutter 3.47.3, and the Windows half needs the exact command now
recorded in the backlog (the winamd64 image is not local to this host).

**F1's two seams cut, F2's register gained one row.** `_agentic_planner_phase`
(reporting `planner_ran` through a nameref, five new suite cases) and
`_cross_build_drop_registry_cache_after_flake` (nameref-taken `build_cmd` and
`_regcache_fails`); both `run_agentic_loop` allow rows deleted, and
`_cross_stage_build_impl` fell under 80 with the same work. F2 has no split
target; `lib/app-packaging.sh` crossed 800 with CON2 + CON6 and took a
NOT-a-split row.

**Windows: #158's thirteen audited defects landed in one closure window.**
`Build-Buildkit.ps1` forwards `-TargetArch` to `-ConcurrentAux` children,
registers child-forwarded `-NoCacheStage` entries as matched, exempts
`final-tar`/`final-push` from cache-busting, refuses `-ConcurrentAux -NoSccache`,
and owns the halving formula once. The `DEPS_MIN_*` ARG/ENV block moved above the
RUN that reads it. The toolchain lane now calls `Disable-ContainerWindowsUpdate`,
with the module mounts its `built` stage needs. `Invoke-GitClone` captures the
submodule-update exit code. `Install-NewHost.ps1` builds the Kataglyphis hcsshim
fork at a pinned commit and asserts the env-configurable teardown knob instead of
patching constants; `-ServiceEnvironment …=5m` deploys it, and the buildkitd
restart is guarded. `Update-HostVhdx.ps1`'s rollback paths and `Optimize-HostVhdx`
/ `Publish-ShimPatch` start services through `Start-HostServices` (reverse order,
failures red), and the copy verify skips what robocopy skips. The agentic loop's
captured output became a `ConcurrentQueue`, and `-ExecutorOnly`'s failure cap now
reports exit 1, pinned by two source-level Pester assertions (the cap is
unreachable in dry-run; `mutations.json` carries no entry for it). A genai
post-copy floor closes the last unverified major. **The 36-minor opportunistic
sweep was NOT done** and is recorded as such in the archive.

**Windows: the rest of the batch.** Eight settled sccache/CUDA probes deleted
(714 lines) and `Dockerfile.probe` re-pointed to `Test-OnnxTuReplay.ps1`; the
compiler-rt verify + System32-tar block ported into the base and merge copies
with `Assert-FileSha256`; patched LLVM compiles through sccache (remote-only
gate, session wrapper, stats on stderr, cache mounts in the Dockerfile);
smoke section 23 covers the baked `C:\temp\scripts` surface, moving the arm64
floor 66 → 69; the #168-#174 comment wave moved every essay to its owning page
(plus a docs home for `Build-OpencvGstreamerPlugin.ps1`); and #175's remaining
checks landed. The 2026-09-03 doc drift is fixed — paths, variable names instead
of submodule version restatements, 23 categories, the `Dockerfile.toolchain-builder`
name, the QNN contradiction, and `deps.json`'s Linux-sccache misattribution with
every generator regenerated. The PascalCase doc anchors resolve; `doc-links` is
green.

**Blocked or left open, deliberately.** Windows #153 (the corpus is absent from
this checkout), #157 and #163 (both need a chain run and/or measurement), #162
(own re-key window), #155 (standing do-not-integrate) and #158's minors sweep;
Linux CON4 (the Windows-side measurement above); and one host quirk found and
recorded rather than fixed: `verify_code_size.py`, `verify_code_complexity.py`
and `verify_comment_size.py` mis-resolve backslash-spelled allow paths under
Windows Python and report every frozen row twice, while the same runs are green
under WSL/Linux. No page owns that trap yet; the 2026-09-17 archive carries the
measurement.

## 2026-09-16 — four hub defects the family pass isolated

Each was measured in a consumer and fixed here, where the code lives.

**The clang runtime triple: amd64 was never normalized.** LLVM builds
`lib/clang/<v>/lib/<triple>/` from the string it is CONFIGURED with; the driver
searches it under the triple it NORMALIZES to. `llvm-cross.sh` had a per-arch
case list that covered arm64 and riscv64 and never mentioned amd64, so x86_64
alone was configured `x86_64-linux-gnu` and searched
`x86_64-unknown-linux-gnu`. Six clang jobs in BeschleunigerBallett died on
`cannot find .../libclang_rt.profile.a` while every gcc job passed, and
`clang -print-runtime-dir` said `(runtime dir is not present)`. The mapping is
DERIVED now (`llvm_cross_clang_triple`) and refuses a string that is not a
Debian multiarch triplet, because falling through to the input is what shipped
the wrong value. Measured after the fix:

| target | deb triplet | LLVM triple |
| --- | --- | --- |
| amd64 | `x86_64-linux-gnu` | `x86_64-unknown-linux-gnu` |
| arm64 | `aarch64-linux-gnu` | `aarch64-unknown-linux-gnu` |
| riscv64 | `riscv64-linux-gnu` | `riscv64-unknown-linux-gnu` |

The affected lane stays red until the image is rebuilt: `:latest-cross` moved on
2026-09-12 and carries the defect, so this corrects the NEXT image, not today's
runs.

**The shared `.clang-format` has never parsed.** `Standard: c++23` is not a
member of that enum (c++03 through c++20, plus `Latest` and `Auto`), so
clang-format exits 1 on the config itself and formats nothing. Measured in the
family image: before, `.clang-format:98:11: error: unknown enumerated scalar`
and the file untouched; after `Standard: Latest`, exit 0 and the file rewritten.
Every consumer carries the same line through the shared-assets manifest and none
could fix it locally, because editing a vendored copy is what the drift gate
exists to catch. **Consequence, not damage:** the formatter has never rewritten
anything, so the first working run in each consumer produces a real diff —
AccelerANTgine measured 13 of its 20 files under `Src/`. That is theirs to take.

**PUB_CACHE lands inside the repo, and tree-walking gates found it.**
`flutter_lane_prepare_env` defaults `PUB_CACHE` to `<repo>/.pub-cache` for a
real reason, which stands. But `code_quality_find_cmake_files` shipped NO
default excludes, so a consumer that ran the prologue and then the cmake-format
gate graded its dependencies' `example/` CMake files — 28 in OmniAccelerANT.
The hub creates the directory, so the hub excludes it:
`CODE_QUALITY_CMAKE_DEFAULT_EXCLUDES` is ADDED to whatever a consumer sets,
never replaces it. Any OTHER tree-walking gate still needs its own row, and
`docs/shared-script-libraries.md` now says so where the prologue is described.

**`uv_run` leaked the image's virtualenv.** `uv_sync_project` clears `UV_PYTHON`
and `VIRTUAL_ENV` for its call; `uv_run` was `uv run --active` with both still
in scope, and uv honours `UV_PYTHON` OVER an activated venv. Measured in the
family image as uid 1001: the old form resolves to `/opt/venv/bin/python3`, the
image's root-owned system venv; the fixed form resolves to the run's own
`.venv/bin/python3`. That is both reported failures — analysers dying on
`Permission denied` under `/opt/venv`, and a per-version venv silently rebuilt
without the extra pytest lives in. This unblocks the deletion of WebDavClient's
two local wrappers, which carry notes saying exactly that.

## 2026-09-16 (later) — ten mutation entries the batch rotted, re-pointed

The Ubuntu lane's preflight was red on the mutation gate for a SECOND reason,
found only after the first was fixed: ten recorded mutations no longer applied
to their targets. `verify_mutations.py --stale-check` named every one, and the
pre-batch run at `4f6f516a` (34722813887) named none — so the 27-commit batch
rotted them, the same way it rotted the consumer inventory.

Two mechanical causes, and the manifest simply did not follow the code:

* Seven entries pin a `python3 ...` call site in `lint-python.sh` and the two
  versioned hooks. The batch replaced the literal interpreter with `${_PY}` /
  `${_LINT_PY}`, so every one of those `find` strings stopped matching.
* Two pin the LINE SPANS that `docs/cross-build-verification.md` quotes for the
  pre-commit hook's `_FAST_SLUGS` block and its staged-shell block. The hook
  moved, the prose was updated to `:87-90` and `:101-118`, the manifest was not.

The tenth, `doc-numbers.total-re-quoted`, targeted a sentence in AGENTS.md that
`acc61567` moved out when it cut that file from 1863 lines to 900.
`test-doc-numbers.sh` still scans AGENTS.md and `cross-build-verification.md` as
the two MIRRORS of `code-quality-tooling.md`, so the mirror arm keeps its
mutation — on the mirror that still carries the sentence.

A stale entry is not a cosmetic failure: it is a guarantee nobody is testing,
and the gate says so by name rather than skipping it. All ten were re-pointed at
the code they are meant to neuter and all ten bite again; the staleness pass is
clean over the whole 841-entry manifest.

## 2026-09-15 (later) — the four red lanes: one this batch caused, three it did not

Separating cause from coincidence first, because the batch above is 27 commits
and three of these lanes were already red before it.

**Consumer Inventory — NEW, this batch.** Green at the pre-batch tip
(run 34816752742 on `4f6f516a`), red at `604294e2` (run 35015536117). The batch
taught `ref_re` the backslash so a Windows-spelled hub path is visible at all,
and that widened capture then swallowed things that are not path separators:

* The hub's own `run-lint-gates.sh:173` prints a hub path from a format string
  ending `manifest\n`. That trailing C escape read as one more path segment,
  so the gate reported `shared-assets.manifest/n` — a file that is right
  there — as a dangling reference. A reference SPELLED with slashes now ends
  at the first backslash; one spelled with backslashes is unchanged, and still
  caught.
* BeschleunigerBallett's `scripts/windows/tests/Resolve-BuildModule.Tests.ps1`
  asserts that resolving `NoSuchModule` names both locations it searched. That
  is a fixture path that must NOT exist, which `FIXTURE_PREFIXES` already
  excused — for `linux/scripts/tests/` and `windows/scripts/tests/` only. A
  consumer spells the same directory `scripts/windows/tests/`. The rule is now
  a path SEGMENT, so it holds in every repo's layout.

Both are false positives with a test each; a dangling backslash path outside a
test tree still fails the run, which is the arm the batch added.

**Composite actions self-test — PRE-EXISTING.** Red on `4667b00c`
(run 34683896775) and `8203965d` (run 34681555187) before the batch, with the
same message: the step asserted `ACTION_DIRS=11` and the container reported 12.
`deploy-over-ftp` made it twelve on 2026-09-10. The literal was a claim about
the repository wearing the clothes of a claim about the mount; the step now
counts the host checkout and compares, which cannot rot and also catches a
miscount on the host side.

**Ubuntu 26.04 — PRE-EXISTING.** Red at the pre-batch tip on `4f6f516a`
(run 34722813887): preflight's mutation gate, one survivor,
`doc-links.tracked-output-floor`. The mutation deletes the static floor from
under a HAPPY git, and the test that should have caught it measured the floor
against what is on disk — and inside the mutation mirror no output path is on
disk, so `floor` was empty and every comparison was `set() == set()`. The
git-free arm beside it had already been moved to the synthetic probe list for
exactly this reason; the tracked arm now uses it too, and the mutation bites.

**SBOM — PRE-EXISTING, and not a test problem.** Red on every scheduled run:
`4f6f516a` (34808919489, 2026-09-14), `2a4e8a9b` (34086038781, 2026-09-07),
`6a9fd5fb` (33359833450, 2026-08-31). All three arches die the same way, mid
layer: `unable to populate layer cache ... disk quota exceeded`. `registry:`
streams rather than pulling into a daemon, but syft still caches layers under
`TMPDIR`, and a cross image does not fit on the runner's root volume. The cache
moves to `/mnt`. Nothing about what is scanned changes.

## 2026-09-15 — the audit's second hub batch: the owner's decisions, executed

The 2026-09-14 family audit left 33 open items against this repository and
twelve questions for the owner. The answers came back; this is the hub's side of
them. Cross-repo halves (the consumer wrappers, the OrchestrANT copy of the NAS
census, the dartdoc fork deletion, the Flutter lane rewrite) are a separate pass
— every hub-side helper they need exists now.

### The owner's decisions

**D1. The home-lab stacks stay, and the README says so.** `linux/homeassistant/`
and `linux/nextcloud-aio/` are the owner's personal operations stacks, carried
here deliberately. README.md states that under its own heading, with the
consequence spelled out: anything claiming this repository is build
infrastructure ONLY is false. The h4 that claimed exactly that is rewritten to
what the tree actually holds.

**D9. `linux/webserver/dist/` stops being tracked.** 82 MB of minified Flutter
output, built in another repository, rewritten in full on every site build, and
unrebuildable by anything here. The image takes it from a named BUILD CONTEXT
now (`COPY --from=site`, `--build-context site=<jot>/build/web`), and a build
that names no `site` context fails at that line rather than serving nothing.
`git rm -r --cached` only — the files stay on disk. `license-assets/` stays
TRACKED, against the item text: it is 48 KB, this repo GENERATES it, and a live
gate checks it is current.

**D8. The NAS document-AI thread leaves for OrchestrANT.** `nas_census.py`, its
suite and `nas-document-ai.md` are removed here, with their mutations, their
allow row and their family, and every reference repointed. The consumer side is
a later pass; the files are recoverable from this commit's parent.

**D4. The repository size is documented, not rewritten.** `project-info.md` now
says what is large (nothing, after D9), why the pack is still ~154 MB (dist's
history) and why no `filter-repo` runs: it would change every commit id, break
the gitlink in six consumers and every SHA in every changelog entry, to save a
one-time clone cost measured in seconds.

**D10. AGENTS.md is 900 lines, down from 1863.** Nothing was deleted. Every
paragraph either stayed because it is a RULE an agent must not break, or landed
in the docs page that owns its topic with a link back — the Validation
measurements to `linux-host-setup.md` § B7/B8, the caching mechanism to
`build-cache-tiers.md` and `windows-build-resources.md`, the command reference to
`linux-cross-builds.md`, the Repo Map's per-file detail to
`shared-script-libraries.md`, and so on. § Contents states the split, so the next
reader knows which side a new paragraph belongs on.

**A089, decided by Claude because the item recommended it.**
`renovate-fleet.sh --vendored` is an opt-in mode for the two cases that are not
the accident the default protects against: a repo of the owner's with no own
checkout anywhere, and a container that mounts a single superproject.

### The scan-root contract reaches the docs gates

`doc-links`, `doc-dupes` and `code-dupes` resolved their root from `__file__`,
so in a consumer's `third_party/ANTfrastructure` checkout they graded THIS
repository and reported that as the consumer's verdict. All three take `--root`
now, keep their current behaviour exactly when the root is the hub, and read
their budget from `<root>/<gate>.allow` otherwise. `doc-links` joins the
`--ratchets` step — it is the only one with no budget to seed — which is what
finally puts a consumer's own `README.md` into the cross-reference graph.

Ten gates gained a `--root` test case and a
`<gate>.root-argument-is-the-tree` mutation; nine are verified to bite (the
tenth needs shellcheck, which this image has not). That needed a fixture the
suites did not have: every existing one plants a tree AROUND the gate, so the
gate cannot tell it from its own repo. `gate-tree.sh` grows `gate_tree_git` plus
two assertion helpers, because ten hand-copied blocks are what the code-dupes
gate exists to catch.

### The upstream halves the consumer forks were waiting on

A Flutter lane prologue and an HTTP-readiness helper (three consumers had each
written the poll loop; this one RETURNS rather than exits, so the nginx caller
can still dump its logs). `run-in-ci-image.sh`, which is the hand-typed
`docker run` every README carried, once — with the Git Bash path-mangling escape
exported rather than documented, because a note nobody reads is how that keeps
being rediscovered. A cmake-format venv DEFAULT instead of an error. MSIX
orchestration (`Invoke-MsixPackage`, `Get-PackageVersion`) with the assertion
that makeappx actually produced a file. `export_clang_gcc_toolchain_env`
restored, with a prefix resolver that probes for `crtbeginS.o` instead of
trusting a composed path. The WebDAV downloader moved to `01-core/` with its
client PINNED, so both lanes install the same one. `STATIC_ANALYSIS_EXTRA_PATHS`
and `CARGO_CLIPPY_ARGS`, the two knobs whose absence made consumers hand-roll
the drivers.

### The second pass: what the first one CLAIMED and did not ship

A consumer measured the pinned tree and found six of the helpers above absent —
they had been listed from a plan rather than from the tree, which is the exact
mistake the audit keeps finding. They exist now, each shaped by the consumer
code it replaces rather than by what looked tidy here.

**The bandit bug, first, because it made an existing knob unusable.**
`STATIC_ANALYSIS_EXTRA_PATHS` reached bandit as one `-r` per path. bandit's `-r`
is `store_true` against a SINGLE `nargs='*'` positional, so `bandit -r a -r b`
is "unrecognized arguments" and exit 2 — measured against bandit 1.9.4 in the
family image. The knob therefore took the bandit gate down on every lane that
set it, which is why OrchestrANT documented it as broken instead of adopting it.
One `-r` and the whole target list now, on BOTH lanes: the Windows twin
`Invoke-CiStaticAnalysis.ps1` had built the same shape. The tests COUNT the
flags, and `Python.StaticAnalysisArgv.Tests.ps1` builds the Windows argv out of
the script's AST and asserts its default exclude list equals the Linux one.

**`BANDIT_EXCLUDES` / `-BanditExcludes`** (A107): the `-x` list was a literal on
the gate line, so a consumer with one more directory to skip had to hard-code
the whole string in its own driver. The default is that literal, character for
character; setting the knob REPLACES the list, because a consumer that names an
exclude set means that set.

**`cmake-build.sh --configure-arg`**, repeatable, forwarded to the configure
step only. AccelerANTgine's `ci-release.sh` needed `-DCMAKE_LINK_WHAT_YOU_USE`
and `-DCPACK_ENABLE_APPIMAGE`, and with no way to add a `-D` it ran
`--skip-configure true` plus its own `cmake -B … --preset …` — three library
entry points where `cmake_build_main` now does. A value containing a space stays
one argument, an empty value is fatal rather than dropped (`cmake ""` fails with
a message about the source directory), and the list is reset per parse.

**`app_packaging_ensure_flatpak_runtime` and
`app_packaging_package_cmake_install_flatpak`.** The existing flatpak packager
takes a Flutter BUNDLE tree; a CMake project has no bundle, so the cmake-install
variant is its own function — but it obeys this file's three conventions, and
two of them the consumer's fork did not: the staging tree is container-native
(the out dir is routinely the build directory on a mounted workspace), and
flatpak-builder's exit code is not the verdict — ostree is asked whether the app
is committed. The runtime installer is deliberately not the container one: it
installs nothing with apt, asks before installing, and falls back user→system.

**`fix_bind_mount_ownership`** in `01-core/bind-mount-ownership.sh`, with the
split that is the whole point of it intact: only the paths that actually differ
are chowned, a failure as a non-root uid is explained and tolerated (handing a
file to another uid needs CAP_CHOWN — a red nobody can act on is what the old
`|| true` was hiding from), and the same failure as root is fatal.

**`WindowsMediaRuntime.Common`** with `Copy-MediaRuntimeBundle` and
`Get-MediaRuntimeDirectory`, collapsing the three sites — ClangCL debug, profile
and release — that each staged the same GStreamer + ONNX Runtime DLL closure.
One difference from the fork it replaces: the recursive NuGet probe is pinned to
the TARGET runtime identifier instead of `win-x64`, so a foreign-rid payload
cannot be staged next to the exe.

**`python-ci-windows.yml` gains `lint-powershell` and `lint-path`.** OrchestrANT
and OxidANT each hand-wrote the same PowerShell-lint job within a week; they
agreed on everything that matters and differed only in the directory they
pointed the gate at. It is a second job on the same runner, defaulted OFF, and
deliberately does not `needs:` the build — a syntax error in the build scripts
is exactly when the lint is worth having.

### The third pass: two gaps the consumers measured in what shipped yesterday

Both were found by a consumer running the new code, and both are the same
failure: a hub helper that is *almost* the consumer's, so the consumer keeps its
own copy and the duplication the upstreaming was for survives.

**`app_packaging_require_flatpak_tools` requires ostree.** It checked `flatpak`
and `flatpak-builder` only, while the verdict both flatpak packagers ask is
`app_packaging_assert_flatpak_committed`'s `ostree refs`. Debian's and Ubuntu's
`flatpak` package depends on libostree and **not** on the ostree CLI, so a dev
box with both declared tools present passed the check and then failed at the
verdict — `is not in <repo>` over an export that had succeeded. AccelerANTgine
measured exactly that and kept its local `ensure_flatpak_tools` with ostree
added rather than adopt the hub's; that local check can go now (its apt /
`AUTO_INSTALL_FLATPAK` half is a separate, deliberate difference and stays).
Each missing tool is reported with the reason the packaging step needs it, and
all of them at once, because one `apt-get` installs the set.

**`python-ci-windows.yml` gains `build-python-package`.** The `lint-powershell`
input added yesterday was unreachable for the consumer it was written for:
`build-test-python-package-on-windows` carried no `if:`, so turning the lint on
also bought a winamd64 image pull, a Python package build, a `./dist/` upload
and a `GHCR_PAT`. OxidANT is a Rust crate with no Python package — it measured
the hub job as byte-for-byte its own and still had to keep it. The build job is
gated on the new input, which **defaults true** so every existing caller is
unchanged, and `GHCR_PAT` is `required: false`, because a required secret is
refused at call time and would have kept the lint unreachable for exactly the
callers the gate is for. The build job asserts the token in its own first step,
so a caller that wanted the build and forgot the secret is told which input it
missed instead of failing inside a `docker login`. OxidANT's `powershell-lint`
job can become a `uses:` now — the retirement condition its comment records.

Ten assertions over four cases join `test-app-packaging-flatpak.sh` and twelve
over five join `test-reusable-windows-lane.sh`, with six mutations (three per
gap) proven to bite. No budget moved: the only derived number that changed is the mutation
manifest, 835 -> 841 entries over the same 91 distinct test commands, written by
`test-doc-numbers.sh --update`.

### Gates and hooks

One Python-probe owner for `lint-python.sh` and the versioned hooks: eight bare
`python3` call sites, one of which was silently turning the embedded-Python
extractor into a no-op on a Windows host. The consumer inventory can see the
half of the fleet it was blind to — backslash-spelled hub paths, and the three
shapes that reach a PowerShell module by NAME. A weekly failure now files an
issue instead of reporting to nobody. The delete guard stops listing two
repository checkouts that have not existed since the 2026-09-12 rename.

Budgets moved with the code and every one is recorded at the measurement, with
the cause: six code-dupes budgets re-measured after the corpus grew, seven rows
retired as stale, seven added, two doc-dupes rule/mechanism pairs budgeted,
`renovate-fleet.sh` frozen at 814 lines with the not-a-split argument, six
comment-size headers frozen, and three new operator knobs registered.

## 2026-09-14 — family audit: the hub's side of the fixes

A cross-repo audit of all nine consumers against this hub (reuse, duplication,
docs freshness, naming, quality-gate reuse, topic separation) landed the hub
half of its mechanical fixes here; the consumer halves are one commit per repo.

* **Three files the 2026-09-08 "no consumer" sweep (2eaed40e) deleted are
  back**: `windows/scripts/modules/WindowsOnnx.Common.psm1` (AccelerANTgine's
  `Build-Windows.ps1` imports it by NAME; its Windows lane was red from the pin
  bump that carried the deletion), `windows/scripts/modules/WindowsContainerLog.Common.psm1`
  and `windows/scripts/rust/New-Archive.ps1` (OxidANT reaches both by path).
  The consumer inventory gains a `windows-lang-script` class for
  `windows/scripts/rust/*.ps1` (the `windows/scripts/*.ps1` glob is
  non-recursive, so nothing graded them), and AGENTS.md § Contributing
  Reusable Work Here now carries the rule: a hub file is deleted only when the
  inventory reports it *named by nobody*.
* **`.github/consumers.json`**: WebDavClient is a confirmed consumer (verified
  against a clone; it still calls the python-ci lanes under the pre-rename
  `Kataglyphis-ContainerHub` name, which is its own migration item); the
  `unconfirmed` array is empty (AccelerANTgine and ANThology were already
  confirmed rows); the OxidANT and AccelerANTgine notes say what those repos
  actually do.
* **`Sync-UvProjectDependencies` excludes the extras that `[tool.uv] conflicts`
  forbid** (`Get-UvConflictGroups`, `Get-UvExtrasToExclude`, `UV_SYNC_EXTRAS`
  override), the port of `python_uv.sh`'s `_uv_extras_to_exclude` — OrchestrANT's
  Windows lane had failed on `uv sync --all-extras` since 2026-09-12 while the
  Linux twin routed around it. Pinned by `Uv.ConflictExtras.Tests.ps1`.
* **`run-lint-gates.sh --ratchets`** (opt-in): the eight `--root` measurement
  gates over the consumer tree, freeze files at `<root>/<gate>.allow`; no
  consumer had run any of them. The consumer-pins gate and the new step run
  under `PREFLIGHT_PYTHON` instead of a bare `python3`, through the probe
  `lint-workflows.sh` had carried inline — now `01-core/python-probe.sh`
  (`preflight_python_require`), the one owner both call, and it accepts a
  command-line value such as `uv run --no-project python`, which is the hint the
  failure message itself gives. `gate_scope.tracked()` pins `encoding="utf-8"`
  (a non-ASCII tracked path aborted every `*`-scoped gate on a cp1252 host).
* **Two reusable lanes**: `.github/workflows/lint-gates.yml` (`workflow_call`;
  inputs `exclude`, `submodules`, `hub-checkout`, `ratchets`) replaces the seven
  consumer copies of the lint job, and `submodule-pins.yml` gained
  `workflow_call` (inputs `suite-path`, `pester-version`, `runner`) so the three
  consumer copies collapse to one `uses:` line.
* **`deploy-over-ftp` has callers**: `build-docs.yml` and `python-ci-linux.yml`
  publish through it (their own `chmod -R 755` steps are gone with it), and
  `actions-selftest.yml` names every input in a guarded step so actionlint
  holds the contract. `docs/ftp-deploys.md` and `.github/actions/README.md`
  say so.
* **`.gitattributes`** pins the extensionless bash files
  (`linux/host-config/git-hooks/*`, `linux/nextcloud-aio/custom-bin/*`), the
  Linux build context's text files (`linux/Dockerfile*`, `*.txt`, `*.allow`) and
  the Python gates (`linux/**/*.py`, `docs/**/*.py`, `.claude/**/*.py`) to LF: a
  `core.autocrlf=true` checkout materialised them CRLF, and preflight's
  crlf-guard, shellcheck, android-parity and `test-advertised-keys.sh` (its
  fixture mutates a gate with a `$`-anchored sed) went red on every Windows host
  bind-mount while Linux CI stayed green.
* **Docs**: `adopting-in-a-new-project.md` gains § 9 *Quality gates* (manifest,
  aggregator, pin suite, python-ci lanes) and four checklist rows, and stops
  claiming a layout uniform "across all seven consumers" (the two Linux-only
  Flutter repos keep a flat `scripts/`); `shared/templates/README.md` describes
  the six-section AGENTS template it ships; `docs/INDEX.md` cites a
  BeschleunigerBallett passage that still exists; `dependency-updates.md` names
  `GITHUB_COM_TOKEN` for `--platform=local` (three sites said `RENOVATE_TOKEN`,
  which is why four consumers had measured and retyped the correction);
  `shared-script-libraries.md` documents six lint gates, not three; stale counts
  in AGENTS.md (12 actions; the pre-commit mutation cap), README.md (no
  hard-coded slug count), `.github/actions/README.md` and `ci-build-triggers.md`
  (`llm-stack-serving.yml`, the pins/selftest/inventory workflows) corrected;
  the consumer-inventory examples say `/c/GitHub`; a broken link in
  `shared/linux/templates/README.md` fixed.


## 2026-09-12 (night) — Home Assistant hardening pass

* **Energy dashboard repaired**: solar is back on the Growatt inverter
  (`sensor.hannemann_total_energy_today`) and the Tasmota smartmeter counters
  are the grid import/export source, after `homeassistant.customize` gave them
  `kWh`/`total_increasing`/`energy` metadata.
* **Security/runtime**: login ban threshold 5 (was −1 = off), recorder
  `commit_interval: 30`, `stop_grace_period: 60s`, `privileged` and
  `/run/dbus` dropped — the latter silences the BlueZ D-Bus spam, since a
  rootless container cannot authenticate to the host bus anyway.
* **Cleanup**: 5 stale `mobile_app` registrations and the 2 Bluetooth adapter
  entries deleted; dead `sleep_for_90sec`, the missing `themes/` include,
  `automationsBackup.yaml` and `.storage/tmp*` removed. The two
  `forecast_solar` entries are two arrays (10 kWp + 2.5 kWp), not duplicates,
  and both were kept.


## 2026-09-12 (evening) — the Home Assistant stack moves in

* **`linux/homeassistant/` now tracks the compose stack that lived in
  `~/Documents/homeassistant`** — compose plus the hand-written YAML and
  blueprints, with the volume rewritten to the relative `./config`. Live state
  (recorder DB, logs, `backups/`, `secrets.yaml`, `.storage/`) is gitignored and
  also excluded from every Docker build context, and the stale 455 MB `core`
  dump was deleted. `secrets.yaml.example` is the tracked template; the WoL MAC,
  the F@H SSH commands and the alert address live in the gitignored
  `secrets.yaml` as whole-value `!secret` nodes, and the three stale-device
  automations plus the unwanted high-power F@H stop were removed.
* All remaining automations were dropped at the owner's request —
  `automations.yaml` is `[]` — leaving the WoL switch and the `shell_command`
  services callable from the UI.
* **Two pre-existing reds cleared on the way**, because the newly installed
  pre-commit hook runs whole-tree gates: the three `shared/*/templates/README.md`
  pages lost their duplicated table boilerplate (code-dupes), and
  `gate-proofs.allow` shed the 19 mutation families the benchmark lab took to
  OrchestrANT, with `docs/code-quality-gates.md` regenerated (gate-registry).


## 2026-09-12 (later still) — the benchmark lab leaves for OrchestrANT

* **The measurement suite, the viewer and the tracked results moved out of
  `linux/llm-stack/`** to OrchestrANT (`benchmarks/`, with the runner in the
  `orchestrant.benchmark` package). This repo keeps the serving stack,
  `backends.json` — the registry both host tooling and the benchmarks consume —
  and `nas_census.py`. `llm-stack-tests.yml` becomes `llm-stack-serving.yml`:
  the compose files parse, the registry keeps its default and GenieX lanes, and
  the NAS census test still runs.
* The roadmap and panel-review pages, ~200 mutation entries, the size
  allowlists, the doc-link test fixtures and every prose pointer moved with the
  lab; the two gate tests that pinned `linux/llm-stack`'s scan membership now
  pin the NAS file that stayed.


## 2026-09-12 (latest) — the pre-existing CI reds, fixed

* **The composite-actions self-test could not find its own local actions.**
  Three jobs called `./.github/actions/...` with no checkout ahead of them, so
  GitHub searched an empty workspace. Each now bootstraps the repository first;
  the actions under test still do their own checkout.
* **The consumer inventory failed on its own test fixtures.** `dangling_refs`
  now skips `linux/scripts/tests/` and `windows/scripts/tests/`: those suites
  build fake consumer trees full of paths that must not exist, and a real call
  in a test fails the suite itself.
* **And on vendored submodule paths.** A fresh clone leaves
  `third_party/DocumANTation/` empty, so a reference into it read as dangling;
  paths declared in `.gitmodules` are now outside the check.
* **The version snapshot failed on the DocumANTation Dockerfile.** The pin was
  behind, so its `ARG` defaults had drifted from versions.env; bumped to the
  rename commit.
* **The SIGPIPE case in test-renovate-exit.sh was a race, not a defect.** A
  closed pipe ends the run through the PIPE trap (141) or through bash's
  EPIPE-on-builtin path (1); the test accepts both and still asserts the tree is
  intact, which is the part that must not vary. New helper:
  `t_assert_contains_any`.


## 2026-09-12 (later) — the hub is now ANTfrastructure

* **`Kataglyphis/ContainerHub` is renamed to `Kataglyphis/ANTfrastructure`.**
  GitHub redirects the old URLs so nothing breaks in flight, but the whole
  family is swept in the same change: every URL, `uses:` ref and Renovate
  `github>` preset; the submodule path (`third_party/ANTfrastructure`); the
  bash bootstrap (`shared/linux/templates/antfrastructure.sh`,
  `antfrastructure_path` / `antfrastructure_source` / `antfrastructure_exec`);
  the `CONTAINERHUB_*` environment variables; and the per-consumer
  `.antfrastructure-shared.manifest`. The rename starts here because this repo
  owns the template every consumer copies.


## 2026-09-12 — merge cleanup: the CI reds the Renovate merge left behind

* Eight preflight checks were red on `origin/main` after the Renovate merge;
  all fixed here: code-dupes (2 budgets tightened, 4 stale rows removed, the
  env-suite clone given one owner), SBOM regenerated, comment-size (6 new
  blocks frozen), code-size re-baselined after the `bump_versions.py` shrink,
  shellcheck SC2088 reworded, workflow-lint's spelled-out CI image ref replaced
  with the helper's name, and the six failing unit suites.
* The Windows job's failures were LiteRT-LM pin parity: `0.16.1 -> 0.17.0` and
  PROTOC `31.1 -> 35.1` in `Build-LitertLmFromSource.ps1`, plus the same
  LiteRT-LM default in `Build-LitertLmBazel.ps1`. The PinParity scanner also
  excluded `tests/` with Windows path separators only, so on Linux it scanned
  the test fixtures themselves.
* `verify_mutations.py --jobs > 1` raced: the first shard mutates the repo root
  in place while the other shards were still copying their mirrors, so a mirror
  could capture a mutated file and its baseline read as a vacuous bite. Mirrors
  are now materialized before any shard starts.
* The fleet suite's per-repo budget was 1s, which flaked on a loaded host (the
  repo before the slow one timed out too); it is 5s now, and the slow fixture
  still sleeps 20s so the verdict is unchanged.
* The hook itself carried a bug the new renovate suites exposed: git exports
  `GIT_DIR` to pre-commit, so fixtures that shell out to git operated on the
  superproject and the mutation sample failed under `git commit` while passing
  standalone. The hook clears `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE`/
  `GIT_PREFIX` before it runs anything.


## 2026-09-11 — android stage unblocked: every installed foreign arch gets a source

* **Symptom.** The android stage failed on all three arches within seconds:
  `libc6:i386=2.43-2ubuntu2.4` (fresh from archive) Breaks the foreign
  `libc6:arm64`/`riscv64=2.43-2ubuntu2.3` (frozen on ports) and apt had no
  source to upgrade them from.
* **Root cause.** The compiler base installs `libc6` for both foreign arches,
  but `Dockerfile.media`'s apt reset leaves sources for the build host and the
  current target only. A transient archive/ports sync gap (i386 2.4 vs
  arm64/riscv64 2.3, back in sync minutes later) then makes the i386 install
  unsatisfiable.
* **Fix.** `cross_ensure_installed_foreign_arch_sources` (`01-core/cross-apt.sh`)
  writes a per-arch ports source for every installed foreign arch that lacks
  one; `android-sdk.sh` calls it before `apt-get update`. Reproduced and
  validated against the real media-parent state in a container before coding.
* **Test.** `test-cross-apt.sh` covers the helper (ports arches only, existing
  file untouched, missing wiring = no-op) plus a whole-line wiring check on
  `android-sdk.sh`. Both mutations proven red — the first attempt at the wiring
  check passed with the call deleted because the helper's name appeared in a
  comment.
* **Two gates the fix flushed out.** `test-mirror-consistency`'s NOSITES fixture
  went blind because `command -v ubuntu_write_deb822_source` parsed as a call
  site; the scanner now skips `command -v`/`type -t`/`declare -F` probes, which
  could previously make a writer-less tree read green. `test-script-copy-coverage`
  needed `ubuntu-mirror.sh` in `KNOWN_BASE_PROVIDED` for Dockerfile.android
  (inherited from the compiler base).
* **Symptom entry:** [`docs/failure-modes.md`](docs/failure-modes.md#apt-libc6i386-install-is-unsatisfiable-after-an-archiveports-drift).


## 2026-09-11 (night) - ASan runtime staging follows the link policy

* **The build stages the runtime the link selected.** `Get-SanitizerRuntimeDlls`
  (WindowsCMake.Common) walked `clang-cl`-on-PATH first and returned LLVM's
  `clang_rt.*san*.dll`, while `cmake/Sanitizers.cmake` links Microsoft's
  import lib from the VS toolset; inside the Windows image every
  ASAN-instrumented build tool then died at load with
  `STATUS_ENTRYPOINT_NOT_FOUND` (`0xC0000139`). It now delegates to
  `Get-AsanRuntimeDirs` (WindowsTesting.Common), the one owner of the
  Msvc-first policy - no second root ordering to drift.
* **Regression covered:** `WindowsCMake.Common.Tests.ps1` pins the delegation
  and the empty-result array (full suite: 826/828; the 2 LiteRT-LM pin parity
  failures predate this change).


## 2026-09-11 (late) — bump_versions.py shrinks to the complement

* **The detection half is gone, the finishing half stays.** The script's tiers
  drop every key Renovate now owns and reports (23 entries out of SAFE/REPORT),
  about 80 lines of upstream-querying helpers with them, and the coverage
  audit learns `renovate_owned()` — a key is classified when it is in a tier,
  carries a `# renovate:` annotation, or is a non-version.
* **What it still does, on purpose:** paired `*_SHA256`/`*_COMMIT` refresh
  (`--write`/`--write-all`), the keys with no feed, the two registry digests,
  the artifact-gated TENSORFLOW_C check, and the slaved PROTOC derivation.
* **Measured after the shrink:** `--check` completes with **0 lookup failures
  and 0 unclassified keys**, and still reports the real outstanding bumps
  (pwsh, uv, node, ollama, pandoc, flutter, CUDA/cuDNN, both digests).
* **Pre-existing, not introduced:** `--audit-sha-pairs` fails on 11 scattered
  `*_SHA256` keys that predate this change (verified on HEAD); recorded here so
  the next sweep can classify them rather than rediscover them.

## 2026-09-11 (evening) — 68 -> 89: vendor JSON, PyPI twins and digests

* **Twenty-one more keys.** Three custom datasources (`custom.cuda` with an
  HTML-href fetch and a JSONata strip, `custom.vulkan`'s WINDOWS value,
  `custom.nuget`'s `tools.json`), a second customManager using the regex
  manager's `currentDigest` capture for `UBUNTU_DIGEST` /
  `WINDOWS_BASE_DIGEST`, `versioning=regex:...` for the 4-part PyPI twins
  (`nvidia-cudnn-cu13`, `tensorrt`) and for `protocolbuffers/protobuf`'s
  major.minor-only `31.1`, plus ROCm via `ROCm/TheRock` tags.
* **Two live iterations, both measured.** `format: plain` maps each LINE to a
  version, so CUDA needed the HTML fetcher; and `skipReason: invalid-value`
  named strict semver as the reason cuDNN, TensorRT and protoc were silently
  updateless.
* **Live report: 29 pending updates and zero lookup warnings** — including the
  two digest moves and the setuptools `<82` cap holding (no 84 proposal).
* **20 tracked keys remain annotation-free**, in documented classes: a slaved
  pin, feeds no datasource can serve (MIGraphX, flatpak branch, JRE selector,
  the libffi wrap), platform matrices with no feed, checksums/raw SHAs,
  artifact-gated and dated pins —
  [`docs/dependency-updates.md`](docs/dependency-updates.md#what-is-still-not-annotated-and-why).

## 2026-09-11 (later) — the local apply half can write versions.env

* **`custom.regex` becomes a writable manager for the self-contained keys.**
  `renovate_locator.find_annotated_env` anchors on the hint's `depName` and
  returns the KEY= line under it; `renovate_audit._parse_env` reads the file
  back independently. A KEY, not a dep name, identifies a leaf — the live
  dry-run immediately caught that `NODE_VERSION` and `RENOVATE_NODE_VERSION`
  share `depName=node`, which a dep-keyed parser had refused wholesale.
* **Which keys may be written is a file-scoped policy** in
  `.github/renovate.json`: approval by default, cleared for the Rust
  security-tool and Python build-executor installs, the npm web runtimes,
  `rust-lang/rust`, `cargo-c`, `APP_REF` and `syft`. On the live ANTfrastructure
  report that is 7 applicable rows and 13 refusals, exactly as intended.
* **`bump_versions.py` is demoted, not deleted:** it remains the lock tool for
  every coupled `*_SHA256`/`*_COMMIT` pin and the detector for the 41
  unannotated keys. New suite
  [`test-renovate-env.sh`](linux/scripts/tests/test-renovate-env.sh) covers the
  write, the refusal and the unreadable hint; all six Renovate suites stay
  green (201/87/105/98/15/11 assertions).

## 2026-09-11 — versions.env is 68 keys visible to Renovate, not 18

* **The annotation pass, verified against the real report.** `bump_versions.py`
  tracks 99 keys; 68 now carry a `# renovate:` annotation (up from 18). A live
  `renovate-local.sh --managers custom.regex .` resolved every one of them with
  **zero lookup warnings** and reported 20 pending updates — `uv 0.12.13`, LLVM
  `23.1.1`, LiteRT-LM `0.17.0`, ComputeLibrary `v53.3.0`, openh264 `2.6.0`,
  flutter `3.47.3`, syft `v1.51.1`, among others. The remaining 41 tracked keys
  are documented exclusions in
  [`docs/dependency-updates.md`](docs/dependency-updates.md#what-is-still-not-annotated-and-why):
  coupled `bump:hold` pairs, vendor indexes with no datasource, base/platform
  pins, untransformable tag shapes, deliberate same-major pins and checksums.
* **Every datasource was tag-shape checked first** (`git ls-remote`), then
  added: `github-tags`/`github-releases`, `pypi`, `npm`, `node-version`,
  `python-version`, `flutter-version`, `crate`. The customManager grew a
  `versioning=` capture with the standard `versioningTemplate`, needed by the
  two leading-zero tags (`ARM-software/armnn` `v26.07`,
  `microsoft/vcpkg` `2026.07.29`); `test-renovate-annotations.sh` now asserts
  the capture and the template cannot drift apart.
* **Two would-be wrong bumps are gated to match the writer's tiers:**
  `NODE_VERSION` within its major (`allowedVersions <27`) and
  `PYTHON_VERSION` within its minor (`<3.15`) — what `bump_versions.py` classes
  same-major/same-minor in SAFE.

## 2026-09-10 — the foreign Vulkan prefixes are two files from amd64

* **VK6 and VK7 closed, measured on both pushed digests.** `lib/` is 118 on
  amd64 and **123** on arm64 (`@sha256:f77f97fa`) and riscv64
  (`@sha256:028ce048`); `bin/` 52 everywhere; layers 9 / 10 / 10. The gap VK6
  opened at **72 files is now 2**, identically on both arches.
* **The entry's own fix would have made it worse.** `BUILD_SHARED_LIBS` is
  exclusive, not additive: ON alone gains 9 files and LOSES 6, because glslang
  guards three static installs behind `if(NOT BUILD_SHARED_LIBS)`. The vendor
  configures glslang twice into one prefix and the STATIC pass must land LAST,
  because the second install owns `lib/cmake/glslang` and therefore what
  `find_package(glslang)` describes. A test asserts the order, not just the
  presence.
* **Two files stay, both explained.** `VulkanLoader` is a layout difference the
  consumers already assume; `libshaderc_util.a` has no install rule and ships
  with no headers even on amd64, so it is unlinkable there too.
* **VK7 mirrors the vendor's own prune** and is guarded on `include/dxc/dxcapi.h`
  — without that marker the helper would `rm -rf include/llvm` out of whatever
  directory it is handed, and `/opt/llvm-target` holds 41 MB of real LLVM 23
  headers.
* **VK5 closed with them:** arm64's earlier number was measured against a tree
  that no longer existed. Both foreign arches now report `24/24` from the
  current one, with zero `unavailable on <arch>` lines.
* **EX1 closed too**, and the residual AS1 neighbours are latent (every cross
  stage builds on `linux/amd64`).

## 2026-09-09 (later) — all three arches ship 52 Vulkan binaries

* **VK4/VK5 closed: 52 = 52 = 52, and the foreign pair leads on layers.** Measured
  on the pushed digests with both directories listed in a container, not derived
  from a log: `bin/` 52 on amd64, arm64 (`@sha256:6eefc3c3`) and riscv64
  (`@sha256:1bdfbb3a`); `explicit_layer.d` 9 on amd64 and **10** on both foreign
  arches. Zero entries in either direction — the sets are identical, not just
  equal in size. `dxc`, `vkconfig`, `vkconfig-gui` and `llvm-tblgen` report ELF
  AArch64 / RISC-V, so none is a copied host binary.
* **The gap was never a build failure.** LunarG's `./vulkansdk` builds 24
  components under `all`; the HOST list named 18. A component not named there is
  never checked out, and the install helper returns before incrementing
  `_vk_attempted` — so the three missing ones were never counted as attempted and
  the verdict read a clean `N/N`. Four rows and three dynamic-arg arms later the
  table is 21 + 3 hardwired = 24, exactly the vendor's own `build_all` count.
* **`-Werror` on a warning this file already knew about.** `dxc` failed the first
  riscv64 run at `external/SPIRV-Tools/source/util/timer.h` on GCC 16's
  `-Warray-bounds`. Configure had completed, so LLVM 3.7 does know the riscv64
  host triple. `_vulkan_target_build_spirv_tools` had carried
  `-DSPIRV_WERROR=OFF` for that exact warning for ages; DXC vendors its own copy
  of SPIRV-Tools. The rebuild logged 164 such warnings on riscv64 and **93 on
  aarch64** — the fix saved both lanes, not one.
* **A vacuous success caught before it shipped.** VulkanTools does
  `find_package(Qt6 ... QUIET)` and, without Qt6, drops the whole configurator
  with a `message()` and exits 0 — the row would have counted as BUILT with no
  vkconfig in the image. `CMAKE_REQUIRE_FIND_PACKAGE_Qt6=TRUE` makes it honest.
* **A gate that was coin-flipping.** `verify-artifact-copy-parity.sh` failed ~1
  run in 10 on an unchanged tree, naming a different artifact each time. Both
  sets were byte-identical on a red run: the bug was `printf | grep -qxF`, whose
  status is not reliably 0 when `-q` exits early on a pipe. Replaced with a shell
  `case`; 200 runs green and both directions still redden.
* **Still open, both small:** VK6 (13 shared libraries the foreign arches do not
  get, caused by our own `ENABLE_OPT=OFF` / `SPIRV_CROSS_SHARED` flags) and VK7
  (11 DXC files they ship that the vendor prunes).

## 2026-09-09 — riscv64 reaches 20/20, and the apt pockets have to agree

* **VK2 is closed: 20/20 Vulkan cross-components on both foreign arches.**
  `Vulkan cross-targets riscv64: 20/20` (`sdk-rv64-20260908-211949`, pushed
  `@sha256:09a4d255`) and `aarch64: 20/20` (`sdk-20260908-132426`). Verified on
  the shipped bytes, not the log: `riscv64/bin` holds 37 entries and is a strict
  subset of `x86_64/bin`'s 52, and `vulkanCapsViewer`, `slangc`, `gfxrecon-info`
  and `vulkaninfo` all report ELF machine RISC-V. The 15-entry delta is entirely
  LunarG's prebuilt tarball (the DXC family, `llvm-tblgen`, `vkconfig`) — which no
  arch builds from source, and which is now VK4 rather than a regression.
* **The last blocker was not Qt and not riscv64: the host and target apt sources
  disagreed on a POCKET.** The compiler stage wrote `ubuntu.sources` for amd64
  **without** `-security` and `ubuntu-ports.sources` **with** it. Since
  `libcurl3t64-gnutls` is `Multi-Arch: same`, amd64 topped out at
  `8.18.0-1ubuntu2.4` while riscv64's candidate was `2.5`, no common version
  existed, and apt reported the DEPENDENT (`libappstream5:riscv64`) as
  unsatisfiable. Every `Multi-Arch: same` library with a security-only upload was
  affected; Qt6 was just the first to matter. Proven by A/B on the same base
  image, one line different.
* **Fixed in three places, because two of them are not enough.**
  `build_python.sh` and `Dockerfile.media` now write both halves with
  `-security`; `cross_align_host_apt_pockets` (cross-apt.sh) repairs an
  **inherited** skew at the point of use, so a stage benefits without its parent
  being rebuilt — which is why the riscv64 sdk stage could be fixed with no
  compiler rebuild. `archive.ubuntu.com` carries `<codename>-security` for amd64
  (HTTP 200), so the old `0` bought nothing.
* **The `mirror-consistency` gate now asserts the pair, not the literals.** It
  runs the real `ubuntu_write_deb822_source` for a host arch and a ports arch and
  requires the two suite sets to match, then parses every shipped call site with
  `shlex` and fails if they disagree on the flag. Neither file is invalid on its
  own, so nothing that reads one file at a time could ever have caught this.
* **`_apt_sources_rewrite` now owns the atomic sources rewrite.** The pocket
  repair had drifted into an eight-line identical run with
  `apt_sources_set_architectures`; the dupes gate caught it, and the shared owner
  keeps the three properties each of which was paid for by a real failure (temp
  beside the target, explicit cleanup instead of a trap in a SOURCED file, and no
  `mv` after a failing awk).
* **Also this window:** the retry classifier stopped reading BuildKit's elapsed
  prefix as an HTTP 429, `smoke-toolchain.sh` asserts LLVM by major.minor instead
  of the full pin, `lint-secrets.sh`'s gitleaks invocation was repaired, and
  `bench_coding.py`'s `RLIMIT_NPROC` counts tasks rather than processes.

## 2026-09-08 — the container stack installs rootless, with no sudo

* **`install-nerdctl-full.sh` grew a rootless prefix mode.** It always installed
  into `/usr/local` with unconditional `sudo tar` / `sudo cp -a`, which made it
  unrunnable unattended on a host whose sudo prompts for a password. It now
  installs into `$HOME/.local` with no sudo anywhere. The mode is AUTO-DETECTED
  from the live `systemd --user` units' `ExecStart` — those units are the only
  authority on what a host actually runs — so neither host needs a knob;
  `NERDCTL_ROOTLESS=1|0` forces it. Every safety property is unchanged: busy-build
  refusal, SHA256 verification, backup + `--rollback`, the cache-mount census, the
  buildkitd worker assertion and the QEMU-binfmt warning.
* **Extracting the bundle was only half a prefix change.** The units keep the
  absolute `ExecStart` they were generated with, so an install into a new prefix
  moved no daemon at all. The script now repoints
  `~/.config/systemd/user/{containerd,buildkit}.service` and prepends
  `${PREFIX}/bin` to their `Environment=PATH`, stashing the pre-image in
  `${NERDCTL_BACKUP_DIR}/systemd-user` so `--rollback` restores units as well as
  binaries. A relocation is same-version by definition, so the "daemon version
  MOVED" proof is replaced there by the one that actually applies: every daemon's
  `/proc/<pid>/exe` must resolve under the new prefix.
* **A drop-in `ExecStart` beats the unit file's.**
  `buildkit.service-override.conf` hardcoded `/usr/local`, so applying host config
  after a rootless install silently reverted `buildkitd` to the other prefix —
  invisible until a build failed. It now carries `@NERDCTL_PREFIX@`, substituted
  by `apply-host-config.sh` and `verify-host-config.sh` before they install or
  diff.
* **CNI plugins: 0 → 18.** Rootless nerdctl resolves plugins under its own
  `$HOME/.local/libexec/cni`, not under `/usr/local`, so summy-server had been
  running with none at all — `/usr/local/libexec/cni` held only a LICENSE. The
  install now counts them where nerdctl actually looks and fails the run at zero.
* **Measured on summy-server (aarch64, Snapdragon X, WSL2).** The relocation was
  byte-identical: sha256 matched across `nerdctl`, `containerd`, `buildkitd`,
  `rootlesskit`, `runc` and `containerd-rootless.sh`, because `/usr/local` already
  held the same nerdctl-full 2.3.5 bundle. Not a version change — a relocation.
  Documented as [`linux-host-setup.md` § B3c](docs/linux-host-setup.md#b3c-install-rootless-into-homelocal-no-sudo).

