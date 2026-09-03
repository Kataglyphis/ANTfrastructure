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

## Python that lives in shell heredocs

775 lines of Python sat inside `linux/scripts/**/*.sh` heredocs as of 2026-09-01
— invisible to `lint-python.sh`, which only globbed `*.py`. A syntax error or an
undefined name in one of those blocks would have shipped silently.

`linux/scripts/extract_embedded_python.py` writes each block to a temp file that
the lint gate then includes. Two distinctions are load-bearing:

- **Only directly-executed blocks are extracted.** `python3 - <<'PY'` and
  `"$py" - <<'PY'` are complete programs. Blocks that are `cat`ed
  (`cat <<'PY_TAIL'`) are FRAGMENTS assembled into one program later — see
  `_smoke_genai_py_verdict` in `06-packaging/smoke-common.sh` — and linting one
  alone reports undefined names for variables the earlier fragment defines.
<a id="comment-openers"></a>
- **A comment cannot open a heredoc.** Prose that QUOTES an opener
  (`# use python3 - <<'PY'`) is not one; the extractor skips lines whose first
  non-blank character is `#`.
- **The opener line may carry trailing redirections.** The first version of the
  extractor required the heredoc token to end the line, so it silently skipped
  `"$py" - <<'PY' 2>/dev/null || echo ...` — the shipped-truth probe in
  `06-packaging/smoke-runtime-image.sh`, i.e. the largest block that mattered.

Both shapes are pinned in `linux/scripts/tests/test-embedded-python-extract.sh`,
and the coverage was proven by injecting an undefined name into a real heredoc
and watching the gate go red.

### hadolint rule selection

Windows Dockerfiles are PowerShell (`# escape=`` + SHELL ["pwsh",...]), but
hadolint's embedded shellcheck still parses RUN bodies as sh wherever it
cannot see the inherited SHELL — e.g. stages whose base is an ARG image
(`FROM ${MEDIA_CORE_FFMPEG_IMAGE} AS ...`), where the SHELL set back in
`common` is invisible to a static linter. PowerShell that happens to parse as
sh slips through; PowerShell that does not (`...; & 'C:\x.ps1'` —
Dockerfile.media-builder:321) raises a shellcheck PARSE error, which is
error-severity and so fails the gate on a pure false positive.

Suppress the "shellcheck could not parse this at all" family, and only for
windows/*: those diagnostics can never be true for a PowerShell RUN. The Linux
Dockerfiles keep the full rule set — a real sh parse error there must still
fail. Style/semantic shellcheck rules stay on everywhere.

The list is the whole parse-error family on purpose, not the codes observed so
far. The first version of this fix listed only the ones that had actually
fired (SC1070 on Dockerfile.media-builder); the very next Windows Dockerfile
added to the repo tripped SC1088 instead and broke main again. Which parse
error PowerShell happens to provoke is arbitrary — enumerating them one
outage at a time is not a policy.

## The allowlist contract

Every gate that freezes a baseline uses one of two rules, both owned by
`linux/scripts/quality_allow.py` so a new gate cannot invent a third:

- **Counted metrics** (`key | count | reason`, e.g. `function-size.allow`) use
  the **four-way** rule: a new offender fails, growth past the frozen count
  fails, an *unrecorded shrink* fails (the improvement must land in the diff),
  and a stale freeze fails. The number therefore always equals reality.
- **Set metrics** (one tab-separated key per line, e.g. `comment-size.allow`)
  use the **two-way** rule: a key not frozen is NEW, a frozen key no longer
  found is STALE.

Keys are chosen to survive unrelated edits — file + name, or file + first
comment line — never a line number. A gate that copies these rules instead of
importing them is the duplication the `code-dupes` gate exists to refuse.

## The mutation gate (`mutations`)

`docs/scripts/verify_mutations.py` with `docs/scripts/mutations.json`, preflight
slug `mutations`. For each recorded entry it makes a literal edit that **neuters
one guarantee**, runs the named test, and requires the test to FAIL. A mutation
the tests survive is reported and fails the gate.

**Why it exists.** Reading a test cannot tell you whether it can fail. In one
session, eight tests written to guard a fix turned out to pass with the fix
removed: a window-grep that matched the wrong `|| die`, a stub that bypassed the
extraction under test, an `if` wrapper that suppressed the very errexit it meant
to prove, and a fixture whose short definition came first. Every one was caught
by breaking the guarded code by hand. This gate is that habit, written down.

**A recurring shape worth naming:** most vacuous tests assert on the failure
MESSAGE and never on the exit code, so the tool prints a failure and returns 0.
Assert both.

| flag | use |
| --- | --- |
| *(none)* | every entry — CI, or before a release |
| `--changed` | only entries whose target is in the diff — the pre-commit hook |
| `--only <id>` | one entry, while writing it |
| `--root <dir>` | resolve targets and run tests elsewhere (its own tests use this) |

Adding a fix without a mutation entry is allowed; adding a *gate* without one is
how the next inert check gets in. The gate guards itself: two entries neuter its
own survivor-reporting and its file restore.

## Code size — functions and files (`code-size`)

`linux/scripts/verify_code_size.py`, preflight slug `code-size`. One contract over
four subjects: **shell functions** and **Python functions** over
`FUNCTION_SIZE_LIMIT` (default 80) against `function-size.allow`, and **shell,
Python and Dockerfile files** over `FILE_SIZE_LIMIT` (default 800) against
`file-size.allow`. 38 functions and 10 files are over today, all frozen.

Python functions are read with `ast`, not a regex: `end_lineno` is exact, nested
`def`s are qualified (`Class.method`), and a decorator or a multi-line signature
cannot fool it. Dockerfiles have no function structure, so they are size-checked
as files only — `Dockerfile.media` at 1162 lines is the largest **Dockerfile**
in the tree (three shell/Python files are bigger) and was invisible to every
gate until 2026-09-03.

One script rather than two: the four-way contract and the allow-file handling are
shared, and a second copy would have tripped the duplication gate — correctly.

**Why it exists.** Until 2026-09-03 the repo had no length metric at all. The F1
and F2 queues in `docs/refactoring-backlog.md` were counted by hand, which is why
their tables went stale between rounds — they had to be re-measured five times in
a single day, and two functions over the limit (`_shipped_truth_probe` at 121
lines, `cmake_build_parse_args` at 116) had never appeared in them.

**The contract is four-way, and each direction matters:**

| condition | verdict |
| --- | --- |
| over the limit, not frozen | FAIL — split it, or freeze it with a reason |
| grew past its frozen number | FAIL — update the entry and say why |
| **shrank** below its frozen number | FAIL — update the entry |
| frozen but no longer over the limit | FAIL — stale, delete the line |

**Growth is allowed, but never silent.** An outright ban would block a needed
addition to an already-oversized file and push it into the wrong one instead — the
gate caught exactly that within an hour of existing, when ten `ADV` probes were
added to `smoke-runtime-image.sh` for WC. What the gate guarantees is that the
number always matches reality, so a size change lands in the diff next to a reason.

The last two rows are what stop the baseline becoming cover for the next offender:
an improvement has to be recorded, and a freeze cannot outlive its subject. Same
shape as `comment-size` and `masked-assignments`.

**Length is weak evidence on its own.** This gate does not argue that a long
function is wrong; it argues that the queue should stay honest without a human
re-counting. The judgement about whether to split lives in the backlog.

Covered by `linux/scripts/tests/test-code-size.sh`: 20 assertions over throwaway
trees, each proven to go red by disabling the matching branch. One of them exists
because a mutation slipped through — asserting on the FAIL message alone let a
variant pass that printed the failure and still exited 0, so the file half now
asserts the exit code too.


## Comment size (`comment-size`)

Owner directive 6 says two lines at the point of use; longer text belongs in
`docs/` with a pointer. `verify_comment_size.py` fails on any NEW comment block
over 10 lines in `linux/scripts` or `linux/host-config`. The 175 blocks that
predate the gate are frozen in `comment-size.allow`; shrinking one means
deleting its line, and a stale entry fails too, so the list cannot rot.

Entries are keyed on **file + the block's first comment line**, not on a line
number — a block must not re-flag because something above it moved. One subtlety
cost a debugging round: the key is truncated to 60 characters and must then be
`rstrip()`ed, because the allowlist reader strips each line, so a key ending in
whitespace reported the same block as NEW *and* STALE at once.

A companion gate for cache blast radius (a script COPY'd into a shared stage
that only leaf RUNs use) was prototyped and **dropped**: shared 01-core helpers
are legitimately COPY'd into base stages for their descendants, so it produced
false positives, and a noisy gate teaches people to ignore gates. The
verify-media-artifacts case it was meant to catch is recorded in
docs/refactoring-backlog.md F6 instead.

## Code-to-docs pointers (`doc-links`)

The comment rule above produces one artefact per shortened comment: a
`docs/<page>.md#<anchor>` pointer in code. 286 of them in 131 files as of
2026-09-03 — more than every Markdown link in `docs/` combined — and nothing
rendered them, so nothing noticed when a page or heading moved. The first census
found one dead page and five dead anchors, two of them written that same week
under the very directive that created the convention.

`docs/scripts/verify_doc_links.py` therefore scans code as well as docs (one
owner for every kind of cross-reference): `linux/`, `docs/scripts/`, `.github/`
and the `Makefile`, all suffixes except `.md`/`.patch`/`.diff`. A pointer's page
must exist and its `#anchor` must be a heading slug or an `<a id="…">` in that
page. Anchors are matched **exactly** — code pointers are written by hand to a
known slug, so the prose-abbreviation tolerance of the `§` check does not apply.

When a heading is long or likely to be reworded, give it a stable id
(`<a id="qairt_headers_dir"></a>` above the heading) and point code at that
instead of the slug. `windows/` is not scanned: it is its own lane.

Fixtures for both failure directions live in
`linux/scripts/tests/test-doc-links.sh`; mutation `doc-links.code-pointers`
proves the scan is still running.
