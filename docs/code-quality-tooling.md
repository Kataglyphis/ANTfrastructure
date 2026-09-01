<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Code Quality Tooling (clang-format, clang-tidy, cmake-format)

The commands, the traps and the cadence — everything that is true for any
Kataglyphis C++ project. Adopted here 2026-08-07 from a consumer that had it all
in its own `docs/code-quality.md`; what stayed behind there is that project's
measured drift figures and its own build-script wiring.

The configs these tools read (`.clang-format`, `.clang-tidy`, `gcovr.cfg`) are
owned by this repo too — see [`shared/config/README.md`](../shared/config/README.md)
for why they are copied into consumers rather than referenced.

## Where the tools are

LLVM is commonly installed on Windows hosts but **not on `PATH`**:

```pwsh
$CF = 'C:\Program Files\LLVM\bin\clang-format.exe'
$CT = 'C:\Program Files\LLVM\bin\clang-tidy.exe'
```

On Linux there is no equivalent resolution step, and
`linux/scripts/lib/code-quality.sh` is not one: it is a **library you source**,
not a wrapper that locates binaries. It invokes bare `clang-format -i`
(in `code_quality_run_clang_format`) and bare `clang-tidy` (in `code_quality_run_clang_tidy`) straight
off `PATH`, and there is no `CODE_QUALITY_*_BIN` knob among the variables it
documents (the variables it documents in its header). Nothing checks for the binaries first
either: the library *defines* a fallback `require_tools` (its fallback `require_tools`)
but never calls it, so a missing LLVM tool surfaces as the shell's own
`command not found` at the call site. Put LLVM on `PATH` yourself.

`cmake-format` is the one tool the library will provision:
`code_quality_ensure_cmake_format` (`code-quality.sh`) creates a venv
with `uv` and installs the project's requirements — but only when the consuming
project has set both `CODE_QUALITY_UV_VENV_CREATE_SCRIPT` and
`CODE_QUALITY_UV_INSTALL_REQUIREMENTS_SCRIPT`. Without them it hard-errors
(inside that function) instead of bootstrapping anything.

## clang-format

Works on the host with no build directory — it needs only the source and
`.clang-format`.

**Scope matters.** `git ls-files '*.cpp'` from a repo root also matches vendored
third-party code under `ExternalLib/`, which is not yours to reformat. Always
scope to your own sources:

```pwsh
$own = git ls-files 'Src/*.cpp' 'Src/*.hpp' 'Src/*.ixx' 'Test/*.cpp' 'Test/*.hpp'
```

**Check only** (CI-style, writes nothing, non-zero exit on drift):

```pwsh
$dirty = @()
foreach ($f in $own) {
  & $CF --dry-run --Werror $f 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { $dirty += $f }
}
"$($dirty.Count) / $($own.Count) files need formatting"
```

**Apply in place:**

```pwsh
foreach ($f in $own) { & $CF -i $f }
```

**Only what you touched** — the low-risk everyday version. Reformatting a whole
tree at once buries real changes in noise:

```pwsh
git diff --name-only HEAD -- 'Src/*' 'Test/*' |
  Where-Object { $_ -match '\.(cpp|hpp|ixx|h)$' } |
  ForEach-Object { & $CF -i $_ }
```

## clang-tidy

Needs `compile_commands.json`. Two traps that cost real time:

1. **Container paths.** A database generated *inside* a build container records
   the container's workspace root (e.g. `C:/ws`). Running host clang-tidy
   against it fails with `LLVM ERROR: Cannot chdir into "C:/ws/<build-dir>"`.
   Rewriting the paths into a scratch copy gets it running:

   ```pwsh
   $db = "$env:TEMP\tidydb"; New-Item -ItemType Directory -Force $db | Out-Null
   (Get-Content <build-dir>\compile_commands.json -Raw) `
     -replace '<container-workspace>', '<host-repo-root>' |
     Set-Content "$db\compile_commands.json" -NoNewline
   & $CT -p $db --quiet <a-source-file>
   ```

2. **C++23 modules.** Even with paths fixed, translation units that `import` a
   module fail (`cannot open file '...X.ixx'`) because module BMIs still
   reference the container layout. A project's clang-tidy wrapper should
   therefore **skip files using module syntax**. What remains checkable is the
   non-module surface — still worthwhile:
   `cppcoreguidelines-special-member-functions`,
   `modernize-use-trailing-return-type` and friends fire on real code.

The clean alternative is to let the build run clang-tidy, where paths are
consistent by construction.

## Suggested cadence

- **Per change:** format the files you touched (the `git diff` variant).
- **Weekly / before a PR:** full check across your own sources; fix what is
  yours.
- **Periodically:** a clang-tidy pass over the non-module TUs. On Linux, drive it
  from `linux/scripts/lib/code-quality.sh` — a library your project's own quality
  script sources, exposing `code_quality_run_clang_format`,
  `code_quality_check_clang_format`, `code_quality_prepare_compile_db`,
  `code_quality_run_clang_tidy` and `code_quality_run_cmake_format` as separate
  steps to call in whatever order it wants. It is not a command you run: it has
  no `main`, and nothing in this repo sources it — per
  [`shared/config/README.md`](../shared/config/README.md) the consumers are the
  downstream C++ projects.

## The failure mode to watch for

A clang-format check that **reports** a deviating count without **failing** the
build lets drift grow indefinitely while every build stays green. One consumer
went from 72 to 142 deviating files that way. If you wire the check into a build,
decide explicitly whether it gates — and if it does not, track the number
somewhere a test can assert on, so the growth is at least visible.

Reformatting a large accumulated drift is a **decision, not a chore**: it
touches most of the tree in one commit and collides with in-flight work. Do it
deliberately, ideally right after a merge point, and add the commit to
`.git-blame-ignore-revs` so history stays readable.

## `linux/scripts/lib/code-quality.sh` — the shared library

Project-agnostic core: a wrapper sets the `CODE_QUALITY_*` variables, sources
the library, and calls the step functions in the order it wants. The library
deliberately does not set `-e`/`-u`/`-o pipefail`, so sourcing it cannot change
the caller's shell options.

### Caller variables

| Variable | Meaning | Default |
|---|---|---|
| `CODE_QUALITY_PROJECT_ROOT` | repo root; replaces the container workspace prefix when remapping a compile DB | `$PWD` |
| `CODE_QUALITY_CMAKE_SEARCH_ROOT` | root of the cmake-format walk | `.` |
| `CODE_QUALITY_CMAKE_EXCLUDE_PATHS` | `find -not -path` globs for that walk | empty |
| `CODE_QUALITY_CMAKE_FORMAT_CONFIG` | cmake-format config, passed with `-c` only if it exists | `.cmake-format.yaml` |
| `CODE_QUALITY_CPP_FORMAT_EXTENSIONS` | extensions fed to clang-format | — |
| `CODE_QUALITY_CLANG_TIDY_EXTENSIONS` | extensions fed to clang-tidy (TUs only) | — |
| `CODE_QUALITY_CLANG_TIDY_ARGS` | extra clang-tidy arguments, e.g. per-project `-checks=` | empty (see axis 4) |
| `CODE_QUALITY_CLANG_TIDY_FIX` | `true` appends `-fix` | `false` |
| `CODE_QUALITY_COMPILE_DB_HINT` | sentence appended to the "missing compile_commands.json" error | — |
| `CODE_QUALITY_CONTAINER_WORKSPACE` | container mount point remapped in a compile DB; empty disables | `/workspace` |
| `CODE_QUALITY_GCC_TOOLCHAIN_PROBE_DIR` | directory whose absence means the container GCC is unavailable locally; empty disables the flag stripping | empty |
| `CODE_QUALITY_GCC_TOOLCHAIN_PREFIX` | prefix matched when stripping container-only toolchain flags | `/opt/gcc-` |
| `CODE_QUALITY_VENV_DIR` | virtualenv used to obtain cmake-format | `<project root>/.venv` |
| `CODE_QUALITY_UV_VENV_CREATE_SCRIPT` | script that creates the venv | — |
| `CODE_QUALITY_UV_INSTALL_REQUIREMENTS_SCRIPT` | script that installs its requirements | — |

Both `UV_*` scripts run with the project root as cwd and are only needed when
cmake-format is not already on `PATH`. Anything the wrapper does not provide is
discovered from the environment: logging from `01-core/logging.sh` (or minimal
fallbacks), tool presence from the caller's `require_tools`/`has_tool`.

### Known divergences from the Windows path — read before "unifying" the two

The Windows equivalent is split across `WindowsFormatting.Common.psm1` and
`WindowsCMake.Common.psm1` (both here) plus `WindowsClang.Common.psm1` (in the
consumer project). An audit found seven genuine differences. They are recorded
so that unifying the sides is a decision with the facts in hand rather than an
accident — the Linux library reproduces the Linux behaviour exactly, and none of
these were "fixed" during the extraction.

| # | Axis | Linux | Windows |
|---|---|---|---|
| 1 | Source roots | clang-format **and** clang-tidy walk `Src` and `Test` | `Get-ProjectCppFiles` walks the whole workspace for clang-format, but clang-tidy is filtered to `Src` only, so `Test` is never tidied |
| 2 | C++20 module TUs | every `.c/.cc/.cpp/.cxx` goes to clang-tidy | files matching `^import\s+kataglyphis` are skipped |
| 3 | `--header-filter` | not passed, so clang-tidy's default applies (headers matching the main file's stem) | `--header-filter=<escaped Src dir>.*`, to suppress ExternalLib noise |
| 4 | `--checks` | a checks argument is passed (the consumer disables one check that crashes its clang-tidy) | `$Checks` defaults to an **empty** array; an imposed `--checks=-misc-include-cleaner` used to crash some versions |
| 5 | Invocation shape | one invocation with the whole file list — fast, but one crash loses the run | per file in a loop — slower, isolates failures, logs per-file skips |
| 6 | Missing `compile_commands.json` | hard error, telling the user to configure CMake first | regenerates via `ninja -C <build> -t compdb` when possible, throws only if not |
| 7 | File enumeration | `find` with `-not -path` exclusions | `git ls-files` with a `Get-ChildItem` fallback, because its container receives sources by tar-pipe and has no `.git`; also excludes `_deps`, `vcpkg_installed`, `.venv`, `site-packages` |
