<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Code Quality Tooling

Two audiences share this page. The first half is the C++ formatter and linter
guidance that is true for any Kataglyphis C++ project (the configs live here,
the consumers copy them). The second half is this repository's OWN quality
gates — the scripts under `linux/scripts/verify_*.py`, `docs/scripts/` and
`lint-*.sh` that `preflight.sh` runs, the pre-commit hook runs in its fast tier,
and CI runs in full. Every gate ships as a set: the script, its allowlist, a
`linux/scripts/tests/test-*.sh` suite, a `mutations.json` entry that proves the
suite can fail, a `preflight.sh` slug, and a section below. The table of all
slugs with their proof status is generated, not hand-written — see
`docs/code-quality-gates.md`.

## C++ formatters and linters (clang-format, clang-tidy, cmake-format)

The commands, the traps and the cadence — everything that is true for any
Kataglyphis C++ project. Adopted here 2026-08-07 from a consumer that had it all
in its own `docs/code-quality.md`; what stayed behind there is that project's
measured drift figures and its own build-script wiring.

The configs these tools read (`.clang-format`, `.clang-tidy`,
`.cmake-format.yaml`, `gcovr.cfg`) are owned by this repo too — see
[`shared/config/README.md`](../shared/config/README.md)
for why they are copied into consumers rather than referenced.

### Where the tools are

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

### clang-format

Works on the host with no build directory — it needs only the source and
`.clang-format`.

**Scope matters.** `git ls-files '*.cpp'` from a repo root also matches vendored
third-party code under `third_party/`, which is not yours to reformat. Always
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

### clang-tidy

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

### Suggested cadence

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

### The failure mode to watch for

A clang-format check that **reports** a deviating count without **failing** the
build lets drift grow indefinitely while every build stays green. One consumer
went from 72 to 142 deviating files that way. If you wire the check into a build,
decide explicitly whether it gates — and if it does not, track the number
somewhere a test can assert on, so the growth is at least visible.

Reformatting a large accumulated drift is a **decision, not a chore**: it
touches most of the tree in one commit and collides with in-flight work. Do it
deliberately, ideally right after a merge point, and add the commit to
`.git-blame-ignore-revs` so history stays readable.

### `linux/scripts/lib/code-quality.sh` — the shared library

Project-agnostic core: a wrapper sets the `CODE_QUALITY_*` variables, sources
the library, and calls the step functions in the order it wants. The library
deliberately does not set `-e`/`-u`/`-o pipefail`, so sourcing it cannot change
the caller's shell options.

#### Caller variables

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

#### Dart file enumeration

`code_quality_find_dart_files [root]` prints every tracked `*.dart` path
(default root `.`), excluding `build/`, `third_party/`, `flutter/` and
`rust_builder/`. It is the twin of `Get-ProjectDartFiles`
(`windows/scripts/modules/WindowsFormatting.Common.psm1`) and both return the
same set for a given repo.

**Never `dart format .` in a CI lane.** The Linux lanes install the Flutter SDK
inside the mounted workspace (`flutter_dir: /workspace/flutter`), so the
recursive walk reformats the SDK. Measured 2026-09-03 on
OmniAccelerANT: `Formatted 7404 files (627 changed)`, 604 of them
under `flutter/` — by itself enough to fail `--set-exit-if-changed`.

#### Known divergences from the Windows path — read before "unifying" the two

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
| 3 | `--header-filter` | not passed, so clang-tidy's default applies (headers matching the main file's stem) | `--header-filter=<escaped Src dir>.*`, to suppress third_party noise |
| 4 | `--checks` | a checks argument is passed (the consumer disables one check that crashes its clang-tidy) | `$Checks` defaults to an **empty** array; an imposed `--checks=-misc-include-cleaner` used to crash some versions |
| 5 | Invocation shape | one invocation with the whole file list — fast, but one crash loses the run | per file in a loop — slower, isolates failures, logs per-file skips |
| 6 | Missing `compile_commands.json` | hard error, telling the user to configure CMake first | regenerates via `ninja -C <build> -t compdb` when possible, throws only if not |
| 7 | File enumeration | `find` with `-not -path` exclusions | `git ls-files` with a `Get-ChildItem` fallback, because its container receives sources by tar-pipe and has no `.git`; also excludes `_deps`, `vcpkg_installed`, `.venv`, `site-packages` |

## This repository's own gates

The sections below are the design notes per gate: why it exists (with the
numbers measured when it was added), what it checks, how to fix a finding, and
which suite and mutation guard it. Slugs in parentheses are the `preflight.sh`
names; `PREFLIGHT_ONLY=<slug> bash linux/scripts/preflight.sh` runs one gate alone.

Four slugs joined on 2026-09-03, in the order their sections appear below:
`gate-registry` (the meta-gate — is every other slug provable at all? — plus the
derived table), `code-complexity` (decision paths and nesting depth, beside
`code-size`), `dead-functions` (a shell function nothing anywhere names), and
`shellcheck-warnings` (a per-file, per-code ratchet over the advisory tier
`lint-shell.sh` prints but never gated). The same day `code-dupes` and
`env-knobs` gained the missing bookkeeping halves of their contracts — an
unrecorded shrink and a knob nobody reads any more now fail — and `mutations`
learned to refuse a bite recorded while that suite was already red. `preflight.sh`
runs 33 checks today; which of them a suite or a mutation actually proves is
generated into `docs/code-quality-gates.md`, never hand-maintained here.

## Python that lives in shell heredocs

775 lines of Python sat inside `linux/scripts/**/*.sh` heredocs as of 2026-09-01
— invisible to `lint-python.sh`, which only globbed `*.py`. A syntax error or an
undefined name in one of those blocks would have shipped silently.

`linux/scripts/extract_embedded_python.py` writes each block to a temp file that
the lint gate then includes. Two distinctions are load-bearing:

- **A directly-executed block is extracted alone.** `python3 - <<'PY'` and
  `"$py" - <<'PY'` are complete programs. Blocks that are `cat`ed
  (`cat <<'PY_TAIL'`) are FRAGMENTS of one program assembled later — see
  `_smoke_genai_py_verdict` in `06-packaging/smoke-common.sh` — so a family of two
  or more sharing a marker prefix is concatenated in file order and a lone
  fragment is dropped, because linting one alone reports undefined names for
  variables the earlier fragment defines.
- **`ast.parse` decides whether a family is Python at all.** A `PY`-ish marker is
  a naming convention, not a guarantee: a `cat <<'TPL_PY_HEAD'` config template
  assembles into something that does not parse, and is left out rather than
  guessed at. Without that check the gate reddens on files that are not Python.
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

The extractor's file list has TWO halves, and each is now pinned separately:
`find linux/scripts -name '*.sh'` (the `probe.sh` cases plus
`python-lint.embedded-file-discovery`, which NARROWS the find rather than deleting
it) and `find linux/host-config/git-hooks -type f` (the git-hook cases plus
`python-lint.hook-half-of-discovery`). The second half exists because a git hook
cannot carry a `.sh` suffix; the pre-commit hook's `_mutation_plan` is ~15 lines of
embedded Python that would silently leave the gate if that half were dropped.
`tests/test-python-lint-gate.sh` asserts on the extractor's mapped-back NAME and
line (`pre-commit__3.py:1:` = opener line 3, body line 1), not on the exit code, so
a fixture that never reaches ruff cannot pass the case by accident.

## Proving a gate can go red

Three slugs read "proven" in the registry while nothing could turn them red:
`python-lint`, `comment-size` and `masked-decls`. Each was proven only by a suite
that asserted the gate's *text* — that `lint-python.sh` mentions the extractor,
that `verify_comment_size.py` contains `.rstrip()` — so neutering the verdict
(`return rc` → `return 0`) survived the whole suite.

A real negative proof has four parts, and the fixture pattern the other suites
already use supplies all four:

1. **A throwaway tree.** All three gates derive their root from their own path
   (`lint-python.sh` `cd`s to it), so a copy under `<tmp>/linux/scripts` scans
   only what the case plants — never the repo.
2. **An offender the gate MUST reject**, asserted on the **exit code** as well as
   the message. Asserting only the message is how these tests went hollow.
3. **The clean counterpart it must accept** with rc 0, so the offending case is
   not passing for some unrelated reason.
4. **A `mutations.json` entry that neuters the verdict**, proven to make the
   suite fail.

`tests/test-prevention-gates.sh` does this for `comment-size` (an 11-line block
fails naming `file:line  11 lines`; a 10-line block passes) and for `masked-decls`
(`local x="$(date)"` fails naming the variable; the declare-then-assign split
passes), plus the two-way allowlist contract for both — frozen at its own key the
offender passes, and that same row against the clean subject is STALE. The
subjects are built with `printf`, not written as literal lines: a real
`local x="$(cmd)"` in the suite would be a new offender for the gate it tests.

`tests/test-python-lint-gate.sh` covers the two tiers `lint-python.sh` runs. The
**gate tier** (`ruff check --select E9,F63,F7,F82`) is the one preflight can fail,
so that is the one proven: an undefined name and a syntax error each exit 1. The
**advisory tier** (the full default ruleset) must report and still exit 0 — an
unused import prints `ADVISORY:` and passes. The fixture writes `RUFF_VERSION`
from `01-core/versions.env` into its own `versions.env`, so it bootstraps the same
pinned ruff the repo does instead of whatever is on PATH.

The same suite pins the gate's **target set**, which the tier cases cannot see: a
tree carrying all three shapes at once — a plain `.py`, a `python3 - <<'PY'` block
opened on line 2 of `probe.sh`, and a `cat`ed `TPL_PY_*` family holding nginx
config — must go red for a gate-tier error in either of the first two and stay
green otherwise. The heredoc finding is asserted down to `probe__2.py:1:`, which
is how a ruff diagnostic against a temp file maps back to the shell file and the
opener line it came from. Switching the extraction off, narrowing the `find` that
feeds it, or dropping the parse check each turn one of those three assertions red;
before this, all three were silent — every suite stayed green while ~775 lines
left the gate. The suite builds its fixture openers as `printf` ARGUMENTS so it is
never itself an extraction target.

Mutations: `comment-size.verdict-discarded`, `comment-size.limit-not-enforced`,
`masked-decls.verdict-discarded`, `masked-decls.substitution-required`,
`python-lint.gate-tier-neutered`, `python-lint.tier-boundary`,
`python-lint.embedded-extraction-off`, `python-lint.embedded-file-discovery` and
`python-lint.heredoc-python-decision` (the last targets
`extract_embedded_python.py`, which `verify_gate_registry.py` does not count among
`python-lint`'s own files — a `.sh` gate's shelled-out helpers are outside
`own_files` today, so that entry is proven but uncredited).

## Dockerfile lint: hadolint rule selection (`dockerfile-lint`)

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

### ENV instruction ordering (`dockerfile-lint`)

A `${VAR}` inside an `ENV` instruction expands to the value `VAR` held *before*
that instruction. A key set two lines up in the same `ENV` therefore expands
**empty**, and nothing says so: BuildKit emits no warning, hadolint has no rule
for it, and the `UndefinedVar` frontend check only runs in the advisory
`docker buildx build --check` pass, which is skipped on every nerdctl-only host.

Two Dockerfiles shipped that way, both found on 2026-09-04 by reading the ENV of
an image already on the host:

| file | written | what the image actually got |
| --- | --- | --- |
| `Dockerfile.android` | `PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:…:${ANDROID_NDK_HOME}:${PATH}"` | `PATH=/cmdline-tools/latest/bin:/platform-tools:/build-tools/36.0.0::…` — three entries that name no directory, and an empty one, which POSIX reads as the working directory |
| `Dockerfile.nvidia` | `PATH="${CUDA_HOME}/bin:${PATH}"`, `LD_LIBRARY_PATH="${CUDA_HOME}/lib64:…"` | a bare `/bin` fronting `PATH` and `/lib64` fronting `LD_LIBRARY_PATH`, instead of the CUDA ones |

`verify_dockerfile_env_order.py` runs as pass 0 of `lint-dockerfiles.sh` — no
download, so it is the one pass that cannot be skipped. It reports a value that
reads a key assigned **earlier in the same instruction**. Two references are
deliberately not findings, because both resolve correctly:

* a key reading **itself** (`PATH="/opt/bin:${PATH}"`) — that is the
  inherit-and-extend idiom, and the inherited value is exactly what it wants;
* a name that is also an `ARG` **in the same stage** — the reference resolves
  from the ARG, which is why `GCC_PREFIX=/opt/gcc-${GCC_VERSION}` beside
  `ENV GCC_VERSION=${GCC_VERSION}` is correct. ARG scope resets at every `FROM`,
  and so does the excuse.

The fix is always the same: split the `ENV` in two. The second instruction sees
the first one's keys.

Proof: `tests/test-dockerfile-env-order.sh` (23 assertions) and eight
`dockerfile-lint.env-order-*` mutations, including one that deletes the call
from `lint-dockerfiles.sh` — a gate nothing invokes is the `copy-media-payloads.sh`
defect again.

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

**One reader, keyed from the left.** `quality_allow.iter_rows(path, keys, fmt)`
parses every counted allow file and yields `(key, count, reason, line number)` per
row, in file order and repeats included; `load_rows` is its dict view and
`load_counts` that view minus the reasons. `keys` names how many columns precede
the count, so everything after it is the reason and a reason may hold `|` and `#`
— until 2026-09-04 the count was taken as the second field *from the right* and an
inline `#` was stripped before the split, so one `|` in a hand-written reason
raised `ValueError: invalid literal for int()` before any gate could report
anything, and a `#` silently truncated the reason. A row that fits neither shape
is `ERROR: <allow file>:<line>: expected '<fmt>'` and exit 2 — a verdict naming
the offending row, never a traceback.

**Every counted gate declares its arity (2026-09-05).** `code-complexity.allow`
passes `keys=3`, `function-size.allow` `keys=2`, `file-size.allow` `keys=1`,
`shellcheck-warnings.allow` and `code-dupes.allow` `keys=2`. `keys=None` survives
only as the reader's default and no gate uses it, which closes the last live hole
in this contract: with the count taken from the right, a reason of the shape
`… | 90 | …` does not raise, it silently keys the row on five columns and the
freeze then reads STALE. A named error was never the worst case; a wrong key was.

Declaring the arity also deleted `verify_code_complexity.check_rows`'s
`len(key) != 3` branch (a short row now fails in the reader, naming its line) and
the `code-complexity.allow-row-arity` mutation that pinned it, which had become
unkillable.

**`code-dupes` keys on an UNORDERED pair, and that is why the reader yields rows
rather than a table.** `a | b` and `b | a` are one entry, so
`verify_code_dupes.load_allow` folds the reader's two key columns into a
`frozenset` itself and keeps the line numbers to say `duplicate row for A <-> B
(first at line N)`. Two *identical* rows have to reach it as two, which a dict
view would already have folded — hence `iter_rows`. `verify_doc_dupes.load_allow`
is the last copy of the parse still open; it wants the same three-line body.

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

**A bite is only evidence if the suite was green first.** Until 2026-09-03 a
mutation counted as biting whenever its test came back non-zero — including when
that test was *already* red, from unrelated drift in a tree several agents were
editing. Every entry under a broken suite then read `bites` and the gate passed,
which is the same false green it exists to find. Each DISTINCT test command is
now run once unmutated per invocation (cached by command string) before any entry
using it is applied; if that baseline fails, the entry is reported as
`FAIL: <id> -- baseline test already fails unmutated (vacuous bite)`, the gate
exits 1, and the file is never mutated. The cost is one extra suite run per
distinct command, and it is paid once per command, not once per entry. The
manifest holds **839 entries** over **235 distinct test commands**; both digits are
derived, not typed (`## Doc numbers are derived`). A full uncapped run took 5m58s
on 2026-09-03, when the manifest held 180 entries — a one-off measurement that
scales with the manifest, not a current figure.

**The gate never edits the tree it is given.** Until 2026-09-03 `apply_and_run()`
wrote the mutated text straight into `--root` (default: this repo) and restored it
in a `finally`. Preflight and the pre-commit hook both run it that way, and this
repo builds *from its own working directory* — buildkit is handed `--local
context=.`. Entries target scripts that are `COPY`'d into an
image (`linux/scripts/01-core/*`, `03-media/*`, `06-packaging/*`), so a cross build
running at the same time could snapshot a deliberately neutered script into a
shipped layer; anything else reading the tree during that window saw a gate with
its guarantee removed. Restoring afterwards does not help — the hazard is the
window, not the end state.

Every invocation now builds ONE throwaway copy of the root (`mirror_tree()`, an
`os.walk` + `copy2` that skips `.git`, `external`, `out`, `logs`, `archive` and
`linux/webserver/dist`), points the whole run at it, and `rmtree`s it in a
`finally`. Tests still run with `cwd` = that copy, so the relative commands every
entry uses (`bash linux/scripts/tests/test-*.sh`) resolve unchanged. `--changed`
still asks git about the REAL repo. Measured once, 2026-09-03: 0.58s for 6.4k
files / 131MB, paid per invocation whether it runs one entry or all of them —
under 1% of a full run that day.

**One mirror per shard; the proof is still one mutation at a time.** Measured
2026-09-04 after the integration wave, all **309** entries biting, each run alone
on an otherwise idle 32-core host: a full serial run costs **12m14s**, one process
per mutant. None of that can be batched — two mutations proven in one suite run
prove neither — but they are independent, so the entries are dealt round-robin
over `--jobs` shards, each with its OWN `mirror_tree` copy, each applying, running
and restoring inside it. Baselines stay shared across shards (one unmutated run
per distinct command, whichever shard reaches it first) and every verdict is
buffered per entry and printed in manifest order, so the report never depends on
which shard finished when. Same 309 entries, same verdicts, same order:
**1m59s** at the default `--jobs 8` (6.2x) and **1m24s** at `--jobs 16` (8.7x).
Measure one run at a time — two of these racing each other on the same host
report numbers that mean nothing, which is how the first attempt at this
paragraph was thrown away. The default is `min(8, os.cpu_count())` — each shard is a full ~200 MB copy
of the tree, so jobs cost memory, not just cores — and it is capped at the number
of entries, so a one-id run still makes one copy. `--jobs 1` is the old serial
behaviour; `--in-place` is always serial.

Symlinks carry TWO properties here, not one. `mirror_tree` copies with
`follow_symlinks=False`, so a link stays a link: dereferencing would pull whatever
it points at — a host binary, a device node — into a copy made once per commit,
and would turn a path the tests see as a link into a regular file. This repo has a
live instance inside the copied scope: `docs/.venv/bin/python` →
`/usr/bin/python3`, an absolute escape. Keeping such a link AS a link is not
enough by itself — a test running inside the copy can still read and write
through it to the host path — so since 2026-09-04 `mirror_tree` does not copy a
link whose `realpath` falls outside the tree at all. Four symlinks exist in the
copied scope, all under `docs/.venv`, and exactly one of them escapes. And
precisely BECAUSE the copy holds links
rather than contents, a write through one would land outside the copy, so
`apply_and_run()` refuses a symlink target outright and fails with `target is a
symlink -- a write through it escapes the copy`. The check sits before the
existence test, because `os.path.exists` follows links and a dangling one would
otherwise be reported as `target missing`. Restoring afterwards is not a defence:
the outside file would hold the mutation *while the test runs*, which is exactly
the transient-write hazard this whole rewrite was about. Selection happens first, so a `--changed` hook run that selects
nothing (the common commit) copies nothing at all.

| flag | use |
| --- | --- |
| *(none)* | every entry — CI, or before a release |
| `--changed` | only entries whose target is committed since `origin/main`, staged, or edited. CI's incremental mode; the commit hook no longer uses it (see the cost budget below — those are push semantics, and a hook re-paid them once per commit). Until 2026-09-03 this took the FIRST non-empty of those three, so a staged file was never selected while unpushed commits existed: the hook let a stale mutation through and the next, unrelated commit tripped on it |
| `--only <id>` | one entry, while writing it |
| `--root <dir>` | which tree to copy and check. It is copied too — pointing the gate at a mirror is a second belt, not the isolation mechanism |
| `--jobs <n>` | how many mutations to prove at once, one mirror each (default `min(8, cpu_count)`, capped at the entry count). Every mutation is still applied, run and restored alone, inside its own shard's copy |
| `--in-place` | mutate `--root` itself, no copy. The pre-2026-09-03 behaviour, kept for the gate's OWN fixtures: their test commands name the subject by absolute path, so nothing would bite inside a copy. Never point it at the repo |

### The pre-commit hook's cost budget

The hook advertised ~11 s. Measured on this tree 2026-09-04, the batch commit
`9a5bf8dd` (43 files) took it **5m26s**, and the mutation step was all of it: a
full uncapped run of the 132 entries those files own measures **322 s**. AGENTS.md
was wrong by a factor of thirty, and a hook that slow is the hook its own header
warns about — it teaches `--no-verify`, which is worse than no hook.

Two things were wrong, and both are fixed in the hook, not in the gate:

**Scope.** `--changed` unions three sets, one of which is *everything committed
since `origin/main`*. Those are PUSH semantics. In a pre-commit hook they mean
every commit of a batch re-pays for all the commits before it, so the tenth
commit of a session is the most expensive one even if it touched one file. The
hook now selects on the STAGED files alone — the same scoping it already applies
to `shellcheck` (`--files`) and to the doc gates. `--changed` keeps its meaning
for CI.

**Cost.** Even staged-only, the mass is lopsided: the totals above spread over a
handful of suites, and `test-code-complexity.sh` alone owns more than a fifth of
the manifest. Each entry costs one full run of its suite — 0.5 s for a cheap one,
3.2 s for `test-code-complexity.sh` (measured 2026-09-03) — so touching one gate script can be a minute on its
own. No selection rule makes that both complete and fast. So the hook **samples**,
and says so:

- at most `PRECOMMIT_MUTATION_CAP` entries (default **16**; `0` = uncapped),
- **newest first** — `mutations.json` is appended to, so the newest entries are
  the ones written in the commit being made, which are exactly the ones most
  likely never to have bitten,
- and when it cut, it prints `SAMPLED <n> of <m> entries … NOT full coverage`.
  A green hook must never imply coverage it did not pay for; that rule has cost
  this repo enough already (`## Proving a gate can go red`). `make preflight`
  and CI still run every entry.

Measured 2026-09-04 against the merged 309-entry manifest, on a 32-core host: the
whole hook run end to end against a real staged index, with the parts timed
separately.

| step | one-file commit (`linux/scripts/preflight.sh`) | this wave's own 77-file diff |
| --- | --- | --- |
| 18 fast whole-tree slugs | 6.4 s | 6.4 s |
| `shellcheck -S error` + warning ratchet, staged only | 0.3 s (1 file) | 14.1 s (45 files) |
| doc-duplication gate, only when `docs/*.md` moves | — | 0.2 s (8 files) |
| mutation step | 8.7 s — all 9 matched entries, no sampling | 13.4 s — 16 of 264, sampled |
| **hook, end to end** | **15.0 s** | **33.0 s** |

Neither column is a worst case: the sample is newest-first, NOT cost-aware, so
what it costs depends on which suite the newest matched entries belong to, not on
how many files are staged. A one-file commit that happens to stage a *gate* script
can cost more than a wide one. A commit that touches no mutation target at all
skips the step entirely.

**The cap moved 6 → 16 on 2026-09-04**, when the gate learned to shard. Same rig,
the same newest-first sample of the 77-file diff, measured both ways: 6 entries
cost **9.3 s** sharded against **15.5 s** serial, 16 cost **13.4 s** against
**44.9 s**. Sixteen sharded therefore costs 4 s more wall time than six used to
while proving 2.7× as many entries — which is the whole trade: the hook's budget
is seconds of WALL time, and sharding is the only thing that buys coverage
without spending more of it. End to end the same commit is **33.0 s** at 16 and
**29.0 s** at 6.

`--print-mutation-plan <cap> <manifest> <file-of-staged-paths>` prints
`plan <run> <matched>` and the ids, without running anything; it exists before the
hook's `git rev-parse`, so `tests/test-precommit-hook.sh` can drive the selection
off-target and inside the mutation gate's own throwaway copy. git never passes
arguments to a `pre-commit` hook, so it cannot fire by accident.

The suite also drives the hook END TO END — a stub `git` feeds it a staged-file
list and a stub `verify_mutations.py` records the argv it is handed — so the
`SAMPLED` notice, the agreement between the number it states and the ids actually
run, and the abort on a surviving mutation are each pinned by a mutation
(`pre-commit.notice-is-printed`, `pre-commit.notice-count-is-the-run`,
`pre-commit.uncapped-claims-no-sample`, `pre-commit.mutation-failure-aborts`).
Before that, deleting the notice call left every suite, the registry and preflight
green.


Adding a fix without a mutation entry is allowed; adding a *gate* without one is
how the next inert check gets in. The gate guards itself: 29 entries (`mutations.*`)
neuter its survivor-reporting, its file restore, its baseline pass, its use of the
copy, the opt-in-ness of `--in-place`, the cleanup of the copy, both production
call sites, the exclude list, the single-match rule, `copy2`, and both halves of
the symlink contract. The isolation proof is
a witness file: the fixture's test command `cp`s the pointed-at subject somewhere
else *while the mutation is applied*, and the suite asserts that snapshot still
reads `GUARD=on` — an after-the-fact byte comparison cannot tell isolation from a
successful restore.

**Isolation is a DEFAULT, and a default is one flag from being off.** Nothing in
the code stops `--in-place` being appended to preflight's `run_check mutations`
line or to the hook's `--changed` line; every suite in the repo survives that edit,
and the consequence is precisely the hazard above. `test-mutation-gate.sh` therefore
reads both call sites out of `linux/scripts/preflight.sh` and
`linux/host-config/git-hooks/pre-commit` and asserts that each still invokes the
gate — `run_check mutations`, and an `if` whose branch is the staged-file run — and
that no invocation line carries `--in-place`. Four entries
(`mutations.preflight-callsite-isolated`, `mutations.hook-callsite-isolated`,
`mutations.preflight-runs-the-gate`, `mutations.hook-runs-the-gate`) flip each call
site and must bite. The test only READS those two files; they belong to other gates.

**Three properties of the copy are pinned rather than assumed.** `COPY_EXCLUDES` is
membership, so emptying it is invisible to every functional test — the run just gets
slower and clones `.git`. The suite plants a payload in each excluded tree, has the
fixture's test command list what it can see from *inside* the copy, and asserts none
of them arrived — against a whole-checkout clone per invocation, at the mirror
cost measured above. `copy2`, not `copyfile`, carries the mode across, so a mutated `.sh`
is still executable in the copy: the suite chmods its subject and has the test command
require `-x`. Losing that would turn every shell test red for the wrong reason — a
vacuous-bite storm, not a verdict. And a `find` string matching MORE than once is now
an error (`ambiguous, name one edit`) instead of a silent first-occurrence edit that
neuters one of several copies, leaves the guarantee half-standing, and reports a false
`SURVIVED`; zero matches was already `stale`. Every entry matched exactly once when
the rule landed (2026-09-03).

### The pre-push hook

The commit hook samples; CI runs every entry. Between the two there was nothing,
so an entry that ROTTED — its target renamed, its `find` string reworded by a
refactor that had nothing to do with it — stayed invisible for as long as nobody
touched it. That is the failure this repo keeps hitting, and it is not the
expensive half of a bite: whether an edit still APPLIES costs one read of the
target, while whether the suite can fail costs a full suite run.

`--stale-check` splits the two. It runs `applicable()` — the same precondition
`apply_and_run()` uses, one owner, so the two can never disagree — over every
selected entry and runs no test at all. Measured 2026-09-05 on this tree: **378
entries in 0.06 s**, against minutes for the same entries proven for real. It
reports a missing target, a symlink target, a `find` string that matches zero
times or more than once, and a no-op `replace`.

What it does NOT do is ask whether a test can fail, and the suite pins that: a
manifest whose mutation the tests SURVIVE passes `--stale-check` and fails the
gate. A caller that ran only the cheap pass and called it coverage would be the
exact false green the gate exists to find.

`linux/host-config/git-hooks/pre-push` runs both halves, in that order:

- `--stale-check` over the WHOLE manifest — the only thing in the repo, outside
  CI, that reads every entry;
- `--changed` for real, whose existing semantics (everything committed since
  `origin/main`, plus the index and the worktree) are push semantics exactly.

`PREPUSH_MUTATION_JOBS` (default **4**, not the gate's 8) is the escape hatch for
the memory the mirrors hold: one ~200 MB copy of the tree per job, on a host where
`/tmp` is tmpfs and a cross build may be running. `git push --no-verify` bypasses
the hook; `make hooks` installs both.

`tests/test-prepush-hook.sh` drives the hook end to end twice — once with a stub
gate recording its argv, for the two abort paths and the flags, and once with the
REAL gate over a planted manifest, so that a rotted entry is proven to stop a
push rather than merely to print.

## Doc numbers are derived

Three waves in a row shipped prose quoting a manifest count that the next wave
invalidated — `180 entries` outlived 180 by two rebuilds of this page, in four
places at once. Re-typing the digit is what failed; the fix is the same one
`tests/test-preflight-slugs.sh` already applies to the slug count.

`linux/scripts/tests/test-doc-numbers.sh` measures the truth from
`docs/scripts/mutations.json`, from `_FAST_SLUGS` in the pre-commit hook, and from
`verify_dead_functions.py --census` run through its own CLI, and
fails when this page, `cross-build-verification.md` or `AGENTS.md` disagrees.
`bash linux/scripts/tests/test-doc-numbers.sh --update` rewrites the digits in
place, so tracking a new wave is one command rather than a hunt.

Two spellings are load-bearing, because they are what the gate finds:

| in prose | pinned against |
| --- | --- |
| `**<n> entries** over **<m> distinct test commands**` — this page, exactly once | the manifest's length and its distinct `test` commands |
| ``<n> … (`<prefix>.*`)`` — any of the three pages | how many ids carry that prefix |
| `the <n> fast slugs` / `the <n> cheap whole-tree slugs`, and ``` `_FAST_SLUGS` (`:<a>-<b>`) ``` | the hook's own list and the lines it spans |
| `<n> definitions qualify`, `**<n>** rows remain`, `reports **<n>** rows today`, `the reachability tier reports <n>` — this page, each exactly once | the three counts in the `--census` header line |

A count of the whole manifest has ONE owner, the first row above; the other two
pages say "every entry" and the gate fails if a bare `all <n> entries` comes
back. The dead-function census joined the table on 2026-09-05, for the same reason
the others did: its three figures were re-typed prose and had drifted by 11
functions and 8 rows. Two numbers remain unpinnable and are written as what they
are: a wall clock moves with the machine, and a per-gate offender census belongs to
its allow file. Those carry the date they were measured, or no digit at all — a
figure a reader cannot trust is worse than a sentence without one.

## Code size — functions and files (`code-size`)

`linux/scripts/verify_code_size.py`, preflight slug `code-size`. One contract over
four subjects: **shell functions** and **Python functions** over
`FUNCTION_SIZE_LIMIT` (default 80) against `function-size.allow`, and **shell,
Python and Dockerfile files** over `FILE_SIZE_LIMIT` (default 800) against
`file-size.allow`. The offenders that exist today are frozen in those two
files, which are the inventory — this page does not keep a second count.

Python functions are read with `ast`, not a regex: `end_lineno` is exact, nested
`def`s are qualified (`Class.method`), and a decorator or a multi-line signature
cannot fool it. Dockerfiles have no function structure, so they are size-checked
as files only — `Dockerfile.media` at 1162 lines is the largest **Dockerfile**
in the tree (three shell/Python files are bigger) and was invisible to every
gate until 2026-09-03.

One script rather than two: the four-way contract and the allow-file handling are
shared, and a second copy would have tripped the duplication gate — correctly.

### What a shell function's extent is

`shell_functions` counts braces over `code_lines`, not over the raw file: comment
text, quoted text and heredoc bodies are blanked first, with quote and `$( )`
state carried across lines. Until 2026-09-04 it counted raw `{` and `}`, and three
things followed. A `}` in a comment or a string ended the function early —
`generate_pkgconfig_file` measured **5** lines instead of 37, truncated by the
comment describing the very stray-brace bug it fixes, and
`_gst_monorepo_tflite_flags` measured 32 instead of 51 for the same reason. An
unbalanced `{` in a comment or a quoted `case` pattern meant the count never
returned to zero, so the function was **invisible to every extent gate** —
`override_soundtouch_codeberg_checksum` (68 lines, cc 16) and
`claude_stream_render` (38 lines) had never been measured by anything. And a
column-0 `name() {` inside a `cat <<'SH'` fixture read as a definition: 29 names
over 62 heredoc occurrences, four of which had been frozen in
`dead-functions.allow` as dead code that never existed.

The stripper is `strip_line` / `code_lines`, and it lives **here** rather than in
`verify_code_complexity.py`, which is where it was first written: `code-size` owns
`scan`, `DEF_HEAD` and `shell_functions`, and `code-complexity`, `dead-functions`
and `gate-registry` all import from it, so the lexer sits at the bottom of the
import graph and every gate that reads shell source shares one copy. Importing
upward from `code-size` into `code-complexity` would have been a cycle.

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

Covered by `linux/scripts/tests/test-code-size.sh`, over throwaway
trees, each case proven to go red by disabling the matching branch. One of them exists
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

### Header pointers must name a section

A pointer with no `#anchor` passes every check above and still rots: rename the
section it meant and nothing complains, because the page it names still exists.
That is CL4 in the backlog, and it was found the hard way — a header pointing at
the quarantined general-Linux cheat-sheet, a page that said nothing about the
script pointing at it.

A gate over **every** bare pointer is not worth having: re-derived on 2026-09-05
there are 463 code pointers, 197 anchored and **266 bare**, and most of the bare
ones are prose naming a whole page, which is not a broken reference. So the rule
is narrowed to where the house comment convention already promises an anchor —
the **header** of a `.sh`/`.py` file, meaning the first `HEADER_LINES` (10) lines.
A `page.md § Heading` on the line is not bare: the `§` check already validates
where that lands.

Of the **110** distinct file-header pointers measured on 2026-09-05, 96 name a
section, 6 use the `§` spelling, and **8** are bare — frozen two-way in
`docs/scripts/doc-header-pointers.allow`, keyed `<file>` + TAB + `<page>` so a
header moving within its block does not re-flag it.

**The 38 rows of debt the rule shipped with are closed.** The allow file opened at
45 rows in three groups, and the two that were debt are gone:

| group | then | now |
| --- | --- | --- |
| the page IS the subject | 7 | 8 — unchanged in kind, plus `verify_gate_registry.py`, whose page is its own generated output |
| into `refactoring-backlog.md` | 9 | 0 — each re-pointed at a durable page, because an OPEN entry is archived when it closes, so an anchor there is built to rot |
| into a large multi-subject page | 29 | 0 — one anchor each, at the section that actually owns the file |

Nine of those needed a section that did not exist yet, so the section was written
rather than the pointer bent to fit: three failure classes in `failure-modes.md`
(errexit suppressed inside an `if !` condition, an unreachable checksum probe
reading as "nothing to verify", a soname resolved by an `apt-cache` prefix guess),
four in `cross-build-verification.md` (the `01-core` layer table, the cross
gobject-introspection wrapper names, `gstreamer-env.sh`, and the wrapper
generation gate), one in `shared-script-libraries.md`, and one promotion of an
already-written paragraph — "Verify the shipped BYTES, never the push" — into the
heading it always deserved. **That is the point of the rule:** a pointer that
cannot name a section is usually telling you the doc has a hole, not that the
anchor is optional.

**And that class cannot come back.** `UNFREEZABLE_PAGES` in the gate makes a
header pointer at `refactoring-backlog.md` a finding whether it is frozen or not,
and the message carries the fix: re-point at the durable page. Freezing is what
the nine rows did, and every one of them rotted the way the group comment said it
would. Mutation `doc-links.header-open-backlog` proves the rule is live.

**Its blind spots, named.** The header window stops at line 10. Dockerfiles and
`.env` files sit outside the scan entirely. An anchor can resolve and still be the
wrong section for the file quoting it. And the 266 pointers living in ordinary
prose were declined on purpose, not overlooked.

**One consequence of the scan set, and it is deliberate.** The manifest and both
allow files under `docs/scripts/` are inside this gate's own scope, so a reference
quoted in a mutation entry is held to the same rule as one in code. Break a
pointer there and the real tree goes red — which is why
`doc-links.flutter-checks-anchor` neuters the target *heading* rather than the
pointer text. `dead-functions` exempts the manifest; this gate does not, on the
grounds that a stale pointer is stale wherever it is written.

## Gate proof registry (`gate-registry`)

`linux/scripts/verify_gate_registry.py`, preflight slug `gate-registry`, allowlist
`linux/scripts/gate-proofs.allow`, generated page
[`code-quality-gates.md`](code-quality-gates.md). It is the meta-gate: every other
slug in `preflight.sh` must be provable, and the table that says so is derived,
never typed.

**Why it exists.** The failure this repo keeps finding is a check that looks green
while proving nothing — the same failure the `mutations` gate exists for, one level
up. A gate with no suite and no mutation is exactly that risk, and nothing used to
count them. This gate counts them, freezes today's unproven set, and refuses to let
it grow.

### What it derives

It parses `KNOWN_SLUGS` and every `run_check <slug> "<name>" <command>` line, and
for each slug emits: script, allow files, proving suites, proving mutations and
hook tier. `KNOWN_SLUGS` and the `run_check` set disagreeing is a hard error, not a
partial table; so is more than one surviving `run_check` line for one slug.

Resolving the **script**:

- the first token that ends in `.py`/`.sh` and is a repo file — a *file gate*;
- otherwise the last shell function the command names, resolved to its defining
  file — an *inline gate*. Several files may define that name, so the tie-break is
  `preflight.sh` first, then a file the `run_check` command itself names, and only
  then alphabetical. The function's line extent is kept, so the allow-file scan
  sees the function body and not the whole host file;
- the `if [ -f X ]; then run_check … else run_check … MISSING` pair collapses to
  the real arm.

### Proof rules

These are printed in the generated page's intro too, because a reader's first
question is always "why does *that* suite count?".

- **A suite proves a gate by mentioning its needle.** The needle is the script
  basename for a file gate and the **function name** for an inline gate. The match
  is a left-bounded word (`(?<![\w.-])needle\b`), not a substring: a suite naming
  `not-delta.sh` does not prove `delta.sh`.
- **Why a mention and not "the suite executes the script".** Suites here
  legitimately *copy* a gate into a throwaway tree and run it from there; an
  execution-based rule would report the best-tested gates as unproven. The price is
  stated openly: an incidental mention counts. The `mutations` gate is the backstop
  that turns a mention into evidence.
- **Why the function name for an inline gate.** An inline gate's script column is
  its host file — usually `preflight.sh`, which four unrelated suites mention in
  passing. Keyed by the file, `crlf-guard` read "proven" while neutering its awk
  pattern survived all four. Keyed by `check_crlf_guard`, only
  `tests/test-crlf-guard.sh` counts.
- **A `mutations.json` entry is credited to the gate its id prefix names** — ids
  are `<slug>.<kebab>` — and only when its `target` is that gate's own script or a
  module that script `import`s. The prefix is the claim, the target the evidence;
  both must agree, so no entry can prove two gates.
- **Why not "the suite that proves this gate runs it".** That was the first rule
  and it was circular: "proves" is mention-based, and three suites mention
  `verify_code_size.py` only because they `cp` it into a fixture as a *dependency*
  of the gate they actually test. `code-size` therefore claimed 7 mutations owned
  by `gate-registry`, `code-complexity` and `dead-functions`. Keying on the id
  ended it; `shellcheck`, `artifact-parity` and `stage-graph` lost the mutation
  half of their proof (all three keep a suite, none dropped to UNPROVEN).
- **The convention is enforced in both directions, over every entry.** The rule is
  about the ID, not about which files happen to be registered. A prefix that names
  a preflight slug is a claim of ownership: it fails unless the `target` is that
  slug's own script or a module it imports — over an ordinary build script just as
  much as over another gate's file. A prefix that names no slug fails when it pins
  a registered gate's file at all (that entry belongs to the gate, under the
  gate's name), and otherwise must be a declared descriptive family. A typo'd or
  copied prefix would otherwise stop proving anything in silence, which is the
  exact failure this whole gate exists to catch. The message names the prefix, the
  target and who does own it. The escape is a freeze under the `mutation-id:`
  namespace in `gate-proofs.allow`, which ratchets down like the slug list.
- **Why not "every id must start with a slug".** Many entries pin
  ordinary build scripts no gate owns (`wheels.`, `qairt.`, `boot.`, `sccache.`,
  …); forcing those under a slug would put false credit in a generated table. They
  keep descriptive prefixes, declared once as `mutation-family:` lines, so an
  invented or misspelled namespace still fails loudly and a family nothing carries
  any more reads STALE.
- **The hook-tier column follows the hook, not one string in it.** `hook+CI` = the
  slug is listed in `_FAST_SLUGS`, so the whole gate runs on every commit;
  `hook (scoped)+CI` = a later hook block hands the gate the staged file list
  (`shellcheck`, `shellcheck-warnings`, `mutations`);
  `hook (whole tree, when relevant)+CI` = a block runs the **whole-tree** gate but
  only fires when the commit touches its inputs (`doc-dupes`, behind
  `[ -n "${_staged_md}" ]`); `CI` = preflight and CI only. The two hook tiers are
  not interchangeable to a reader: one says "only what you staged was checked",
  the other says "everything was checked, this time". A block is scoped when its
  body expands the guard variable or passes `--changed`; otherwise it is
  whole-tree. The needle is the same one the suite scan uses, so `not-delta.sh` in
  the hook does not promote `delta.sh`.
- `script-tests` and `mutations` are **by construction**: they *are* the proof
  machinery, so they can never read UNPROVEN.

### The allowlist

`gate-proofs.allow` is a **set metric** under the two-way rule (see
[The allowlist contract](#the-allowlist-contract)): a slug with no proof that is
not frozen is NEW and fails; a frozen slug that has since gained a proof is STALE
and its line must be deleted. The list only ratchets down. Baseline 2026-09-03: 15
of 33 slugs — the four gates added that day all shipped with a suite, so none of
them is on it. Lines prefixed `mutation-id:` are the second namespace, counted and
reported on their own line: mutation ids that break the `<slug>.<kebab>`
convention. The check found two on 2026-09-04 —
`shellcheck-warnings.pin-only-path-bin` and `shellcheck-warnings.list-files-first`,
both pinning `lint-shell.sh`, which `shellcheck` owns — and both were renamed to
`shellcheck.<kebab>` in `mutations.json` and their freezes deleted in the same
change: renaming without deleting reports STALE, deleting without renaming reports
the prefix that cannot own it.

Lines prefixed `mutation-family:` are the third namespace and are NOT debt: they
declare the descriptive prefixes used over ordinary build scripts, which no gate
owns. 16 declared on 2026-09-04, covering 43 ids. An undeclared prefix fails as
NEW; a family no id carries any more is STALE. If a family name is ever adopted as
a preflight slug, every id under it starts being judged by ownership and the
declaration goes stale in the same run. The file therefore holds three counts: 15
frozen slugs, 5 `mutation-id:` freezes and 16 `mutation-family:` declarations.

Today's five frozen ids are the shape the file-ownership model cannot express.
`mutations.preflight-callsite-isolated` and `mutations.preflight-runs-the-gate`
pin `preflight.sh`, whose sole registered owner is `crlf-guard`;
`mutations.hook-callsite-isolated` and `mutations.hook-runs-the-gate` pin
`linux/host-config/git-hooks/pre-commit`, which no gate owns. All four prove how
the ORCHESTRATOR invokes the `mutations` gate, and `test-mutation-gate.sh` is what
catches them. The fifth, `python-lint.heredoc-python-decision`, pins
`extract_embedded_python.py` — the helper `lint-python.sh` shells out to but does
not `import`, so `own_files()` does not credit it. The last three became visible
only on 2026-09-04: before the id rule was widened it was silent over files no
gate owns. Renaming any of them would put false credit in a generated table, so
they are frozen instead. The fix is an ownership rule for call sites and for a
shell gate's shelled-out helpers, not a rename; see `docs/refactoring-backlog.md`.

The cheapest proof per frozen slug, by shape:

- **Tree-consistency checkers** (`copy-coverage`, `critical-fixes`,
  `patch-integrity`, `arg-consistency`, `mirror-consistency`, `runtime-paths`,
  `android-parity`, `pkg-names`, `version-snapshot`): a fixture tree with one
  planted offender and one clean twin, asserting the exit code *and* the message —
  most vacuous tests assert only the message. `stdout-returns` left this list on
  2026-09-04 by being written that way; it is the worked example below.
- **Third-party linter wrappers** (`dockerfile-lint`, `workflow-lint`,
  `secret-scan`): the wrapper is what is untested, not the linter. Feed it a file
  the linter must reject and assert the wrapper propagates a non-zero exit.
- `doc-dupes`: mirror `tests/test-code-dupes.sh`.
- `sbom`: assert `--check` fails on a hand-edited SBOM, the way this gate asserts a
  hand-edited registry fails.

### `crlf-guard`, the worked example

`check_crlf_guard` is inline in `preflight.sh`: it asks `lint-shell.sh --list-files`
which of the tracked files are shell scripts, reads `git ls-files --eol` over exactly
those, and fails naming every one whose **working-tree** bytes carry CR.

**Which column decides.** `git ls-files --eol` prints `i/<eol> w/<eol> attr/<attr>`
— the index shape and the working-tree shape. Only `w/` counts here, because
buildkit builds from the working directory (`--local=context=.`): a file that is
`i/crlf` but `w/lf` ships LF bytes and is not an offender, and flagging it would be
a false positive on any tree mid-`git add`. A file missing from the working tree
prints an empty `w/` column and is likewise not an offender.

**Which files are in scope.** The pathspec used to be `-- '*.sh'`, which cannot see
an extension-less script on a shell shebang — including
`linux/host-config/git-hooks/pre-commit`, the hook that runs this very gate. The
neighbouring `shellcheck` gate admits those files explicitly, so the repo held two
gates with two different answers to "what is a shell script". There is now one
owner: `lint-shell.sh --list-files`, the same scope the shellcheck warning ratchet
consumes. Feeding it `git ls-files -z` classified the whole tracked tree in ~68 ms
on 2026-09-03,
which is inside the budget for a `_FAST_SLUGS` member. A tracked file that is not a
shell script (prose, a patch, a fixture) may carry CR and is not an offender.

**Which shapes are offenders.** `w/crlf` is only emitted when *every* line ends
CRLF. The realistic accident — an editor or a merge that rewrote *some* lines — is
`w/mixed`, and a bare CR with no LF after it makes git report `w/-text`. All three
put a `\r` into a line bash will execute, which is exactly the container failure
`$'\r': command not found`. `w/-text` is also git's shape for a genuinely binary
file, which a tracked `*.sh` never legitimately is, so it is flagged too; `w/none`
(no line endings at all) and `w/lf` are clean. The awk therefore splits the eol
prefix into fields and compares the second one, rather than substring-matching the
whole prefix — an `attr/` value is in the same tab-delimited field and must not be
able to vote.

`tests/test-crlf-guard.sh` extracts the function with `t_fn_src` and runs it inside
throwaway git repos, one per shape: LF-only passes; wholly-CRLF, one-CRLF-line-among-LF
(`w/mixed`) and a lone CR (`w/-text`) are each named with their shape and return 1
while the LF sibling is not named; `w/mixed` is still caught under a
`.gitattributes` `*.sh text eol=lf` pin, because that attribute normalises the
*next* checkout, not the bytes on disk now; CRLF-in-index-with-LF-on-disk and a
deleted file both pass; an extension-less `git-hooks/pre-commit` is caught while an
extension-less `NOTES` is not; and a directory that is not a repo, or a tree with no
`lint-shell.sh` to answer the scope question, returns 1 printing
`__git-ls-files-FAILED__` instead of reading as clean.

That last guarantee holds **only under `pipefail`** — a failing stage fails the
pipeline only because `preflight.sh` sets `set -uo pipefail`. The suite used to
hard-code those options when it ran the extracted function, so deleting `pipefail`
from `preflight.sh` survived every suite in the tree. It now *derives* the options from
`preflight.sh`'s own `set -` line and asserts that line pins `pipefail`, which puts
the dependency where it lives; `crlf-guard.pipefail-pin` proves it.

Seven mutations pin it, all survived by every suite that merely mentions
`preflight.sh`: `crlf-guard.pattern-neutered` (the awk condition → `never-matches`),
`crlf-guard.mixed-blind` (drop the `w/mixed` arm — the original bug),
`crlf-guard.lone-cr-blind` (drop the `w/-text` arm), `crlf-guard.index-column`
(read `i/` instead of `w/`), `crlf-guard.scope-sh-suffix-only` (back to the
`'*.sh'` pathspec), `crlf-guard.scope-not-classified` (take every tracked path
instead of asking the owner) and `crlf-guard.pipefail-pin` (`set -uo pipefail`
→ `set -u`).

**Known limit.** `lint-shell.sh` sniffs the shebang with `head -n 1`, so a *wholly*
CRLF extension-less script reads as `#!/usr/bin/env bash\r`, matches no arm, and is
invisible to this gate and to `shellcheck` alike. A half-rewritten one (`w/mixed`,
the realistic accident) keeps an LF first line and is caught. Closing it is one
edit in `lint-shell.sh`, that gate's scope owner, not a second classifier here.

### Flags

| flag | use |
| --- | --- |
| *(none)* | check mode — fails on a stale page, a NEW unproven slug, or a STALE frozen line |
| `--write` | regenerate `docs/code-quality-gates.md` |

The page is data, not prose: regenerate it, never hand-edit it. It must be
regenerated whenever a slug, a suite name, a mutation entry or the hook's
`_FAST_SLUGS` changes.

### Known limits

- Mention-based proof is a heuristic. A suite that names a gate and asserts nothing
  about it still counts; only the `mutations` gate can tell the difference.
- Only slugs wired into `preflight.sh` are visible. A checker that exists but is
  not wired in is invisible to this registry.
- The hook-tier column sees `_FAST_SLUGS` and any hook block that *names* the gate.
  A hook that ran a gate without naming its script or its inline function — behind
  a variable, say — would still read CI-only.
- Scope is read from the block, not from the gate's own argument parser. A block
  that named the gate and then scoped it through some third spelling of "the
  staged files" would read whole-tree.

Pinned by `tests/test-gate-registry.sh` over a twelve-slug fixture
plus `ordinary.sh`, a build script no `run_check` registers (one per shape: file
gate proven by a suite, by its own mutation, by an inherited mutation credited by
id prefix, the same import under another gate's prefix, unproven, `[ -f ]`
fallback pair, inline in `preflight.sh`, inline in a sourced lib, inline with a
same-named stub in a lib nobody sources, run whole-tree by a staged-docs block,
scoped by `--changed` rather than the guard variable, by-construction) plus the
`mutation-id:` and `mutation-family:` ratchets in both directions and all three
convention breaches they catch, 32 in `tests/test-crlf-guard.sh`,
and 28 entries (`gate-registry.*`).

## Shell complexity (`code-complexity`)

`linux/scripts/verify_code_complexity.py`, preflight slug `code-complexity`,
~0.4s over the whole tree. Two numbers per function — **cyclomatic complexity**
(`COMPLEXITY_LIMIT`, default 15, in decision paths) and **nesting depth**
(`NESTING_LIMIT`, default 5, block levels below the function body) — over the
same scan set as `code-size` (`linux/scripts`, `linux/host-config`,
`docs/scripts`), frozen in `code-complexity.allow` under the four-way contract.
Today: `cc: 67 over 15 paths; 67 frozen` and `nesting: 3 over 5 levels; 3 frozen`.

**Why, next to `code-size`.** Length is the cheap proxy. A 60-line function with
a `case` inside a `while` inside two `if`s is the one that actually resists
change, and it never shows up in a line-count queue. The two gates share
`quality_allow.py` and `verify_code_size.shell_functions`, so there is one scan
set, one allow contract, and no second copy of either.

### What counts as a path

Shell: `if`, `elif`, `while`, `until`, `for` **in command position**; the `&&`
and `||` operators anywhere in code; and one per `case` arm. An arm is the `)`
closing a pattern at the paren depth its `case` opened at — which is how it is
told apart from the `)` of a `$(...)`, including a `$(...)` inside an arm body.

Python: an `ast` walk — `If`/`IfExp`/`For`/`While`/`With` one each, `Try` one per
handler, `match` one per case, a `BoolOp` `len(values) - 1`, a comprehension one
per `if`. Nested `def`s are excluded from their parent and measured on their own.

### What counts as nesting

Shell openers `if for while until select case {`, closers `fi done esac }`. The
function's own brace is subtracted, so a body statement is depth 0. Python blocks
are the branch nodes plus `try` and `match`; an `elif` is an `If` inside its
parent's `orelse` and continues that parent's depth instead of adding a level, so
a five-arm `elif` chain reads as depth 1, not 5.

### What the shell counter cannot see

Before tokenizing, a body is reduced to code text by `verify_code_size.code_lines`
(that module owns the stripper; see `code-size`). Heredoc bodies are dropped in
every spelling (`<<WORD`, `<<'WORD'`, `<<"WORD"`, `<<-WORD`; `<<<` is a
here-string and is *not* one). Comments are dropped from `#` to end of line —
`${#x}` and `$#` are not comments. Quoted text is blanked, and quote state is
carried **across lines**, so a multi-line `awk '...'` program is one string, while
a `$( )` inside `"..."` re-enters code: the `&&` in `"$(a && b)"` is a real path.

### Command position — the fix that moved the numbers

The first cut fed every bare word to the walker and matched reserved words by
equality alone. So `err Could not resolve TFLite host tools ... for cross wheel
build` scored a path for `for` *and* opened a block that never closed. Exactly
fifteen such hits lived in `build-litert.sh` and nowhere else in the tree:
`_litert_wheel_cross_args` measured 24/4 where it is really 21/2, and
`_litert_wheel_run` 6/4 where it is 4/2 — its nesting inflated by two log lines.

A reserved word now counts only in **command position**: at a line start, or
after `;`, `;;`, `;&`, `;;&`, `&&`, `||`, `|`, `&`, `(`, `$(`, `{`, the `)` that
opens a `case` arm, or one of `then else do elif if while until ! time` that was
itself in command position. Out of position the word is text — no path, no block,
and no command position of its own for the token after it. Newlines are tokens
for exactly this reason: without them a line start is invisible, and a `done`
ending one line decides whether the keyword starting the next one counts.

Membership of that set is pinned element by element. Deleting just `|` from
`CMD_OPS` used to survive the entire suite — `cmd | while read -r x; do … done`
then measured cc 1, nesting 0 — because every case that exercised command
position gave the walker several other ways to re-enter it. There is now one
case per member, each a construct that only that member enables: a pipe-fed
`while`, an `&& if` and an `|| if`, a backgrounded `a & if`, the first word of a
subshell, of a `$( )` and of a `{ … }` group, `x=1; if …` for the bare `;`, a
plain line start for the newline — and, for the three arm terminators `;; ;& ;;&`,
the `esac` that closes the arm, proven by a *second* `case` that would otherwise
be measured as nested inside the first.

### Three parser traps, closed in the same pass

- **`$(( a << b ))` read as a heredoc.** `<<` matched the heredoc pattern with
  terminator `b`, that terminator never appeared, and the rest of the function was
  swallowed — complexity silently collapsing toward 1. Arithmetic now pushes its
  own frame (`$((` anywhere, `((` after a delimiter) and heredoc detection is off
  while one is open. The delimiter set `" \t;(|&"` is pinned one character per
  case: `if (( x << n ))`, a tab-indented `(( x = y << n ))`, `x=1;((y << n))`,
  `cat <(((x << n)))`, `true|((x << n))` and `sleep 1 &((x << n))`. Collapsing the
  whole set to `" "` used to survive the suite; the tab case alone now bites, and
  each of the six is a mutation of its own. A **line start** is the seventh
  delimiter and had no case of its own: a `((` in column 0 has nothing before it,
  so dropping the `i == 0` arm sent the guard reading the line's *last* character
  and turned the shift back into a heredoc.
- **The `}` of an unquoted `${x:-$(cmd)}`.** The `)` ends the substitution token
  and leaves a bare `}` that closed a block never opened, so nesting read one
  level too shallow for the remainder of the function. A `}` is a block end only
  when preceded by a line start, whitespace or `;` — what bash requires of it
  anyway. The guard is deliberately one-sided: gating `{` the same way cost a real
  level in `$({ objdump …; } | awk …)`, and a bare `{` token that is *not* a group
  opener does not arise, because `${…}` tokenizes as one word. That delimiter set
  is its own three-character constant, unrelated to `CMD_OPS`; its `;` — the
  `{ : ;}` spelling — is the member a case can miss, because dropping it only
  shows up in what the *unclosed* group does to the nesting of everything after.
- **Escaped quotes.** `\"` inside `"..."` and a `\'` in code were handled but
  unasserted. Both have a case now, and the first one had to be rewritten: with a
  single `||` inside the string, deleting the guard gained one path from inside
  the string and lost the `&&` on the line after, for the same total — the
  mutation survived. Two interior `||` make it bite.

### The allow file

`<path> | <function> | cc|nesting | <count> | <reason>`. The metric is part of the
key, so a `cc` row does not cover the same function's nesting or vice versa. A row
whose third field is neither `cc` nor `nesting` used to be filtered out of both
passes and ignored — not even reported STALE — and a row missing the metric column
crashed the gate with an `IndexError` before either summary line printed. Both now
fail with the offending row echoed back.

### Known limits, not fixed here

- **Function extents come from `verify_code_size.shell_functions`**, which since
  2026-09-04 counts braces over stripped code — the fix belongs there and landed
  there, together with the stripper this gate used to own. A nested `name() { … }`
  is still swallowed by its parent, because `DEF` is anchored at column 0 by
  design. See [what a shell function's extent
  is](#what-a-shell-functions-extent-is).
- `(( … ))` is recognised only after a delimiter, and `&&` / `||` *inside*
  arithmetic still count as paths — in bash they do short-circuit, so that is
  arguably right rather than a bug.
- An unterminated quote, or a heredoc whose terminator never appears, poisons the
  rest of that one function. This is a heuristic tokenizer, not bash's parser;
  where it is wrong the number is frozen with a reason and stays honest in both
  directions, which is the point of the contract.

### Tests

`linux/scripts/tests/test-code-complexity.sh`. Each case installs
the gate with its two imports into a throwaway tree and reads the number back
**through the real CLI** with `COMPLEXITY_LIMIT=0 NESTING_LIMIT=-1`, so nothing
asserts on the parser's internals. Its last case runs the gate on the real tree,
and that case is what caught the gate tripping its own limit: `_code_char` reached
cc 20 while gaining the arithmetic handling and had to be split into
`_open_group` / `_close_group` / `_code_char`.

47 mutation entries (`code-complexity.*`) carry it: the four contract directions (in `quality_allow.py`),
the tokenizer guarantees (heredocs, here-strings, quotes, cross-line quote state,
comments, case arms, worst-not-last, the Python walk, elif depth, the metric split,
the surviving verdict), and one for each fix above — including **both** directions
of the command-position rule, so that neither "every word is a keyword" nor "no
word ever is" can pass. Twenty of them delete a single element from `CMD_OPS`, a
single character from the arithmetic delimiter set (its line-start arm included) or
the `;` from the `}` delimiter set, so no member of any of the three can be dropped
without a case going red.

## Dead shell functions (`dead-functions`)

`linux/scripts/verify_dead_functions.py`, preflight slug `dead-functions`. Every
shell function defined under `linux/scripts` or `linux/host-config` must be named
at least once somewhere in the scanned code. Definitions come from
`verify_code_size.functions()`, so the two gates cannot disagree about what a
definition is — including the `function name {` form and a one-liner on a file's
last line, both of which an earlier brace walker missed, and **excluding** the
column-0 definition heads inside heredoc fixtures, which that same walker counted
as definitions until 2026-09-04. Every function it finds no use for is frozen in
`linux/scripts/dead-functions.allow` — the gate is what makes "all of them" true —
and the run prints its own totals rather than this page re-typing them, because the
one count that WAS re-typed here went stale by 106 in a day. The whole pass costs
under a second, which is why it is in the pre-commit tier.

**What counts as a use.** The corpus is every text file under `linux/`, `.github/`
and `docs/scripts/`, plus the `Makefile`. A Dockerfile `RUN bash -c "… && fn"` is
a use — that is how stages call helpers. Before matching, each file has its
comments *and its definition heads* stripped, so neither a mention in a comment
nor a second copy of the same function keeps the first one alive. Matching is on
word boundaries: `used_fn_extra` is not a use of `used_fn`, `run-used_fn` is.

**A definition's mentions of ITSELF are subtracted (2026-09-05).** String literals
are not stripped from the corpus, so `printf 'export_clang_gcc_toolchain_env: no
GCC toolchain at %s\n'` inside that function's own body read as a call to it —
backlog CL3 was the live instance. `self_mentions()` counts, per name, how many
times its own definitions' bodies name it and `mentions()` subtracts that, so a
diagnostic that prints the function's name is not a caller and neither is
recursion. A call anywhere else still outvotes the discount.

Stripping string literals corpus-wide is the fix that looks obvious and is wrong:
measured on this tree it turns **nine live functions dead**, among them the
`trap 'on_err' ERR` / `trap '_chain_on_exit' EXIT` handlers and helpers named
only inside a generated meson cross file. A name inside a string genuinely can be
a call; a name inside a string *in its own body* cannot be one from outside. The
narrow rule is the one that holds. It costs one extra walk of the shell scan set
— 0.5s → 0.9s, still the pre-commit tier.

**What is not corpus, and why:**

| excluded | reason |
| --- | --- |
| `*.md` | prose about code is not a caller |
| `*.patch`, `*.diff`, any `patches/` directory | quoted upstream source |
| `*.allow`, `docs/scripts/mutations.json` | a gate's own baseline *describes* code; counting an `.allow` row as a use would send every freeze STALE, and a mutation's `find`/`replace` text is the same argument |
| `linux/webserver/dist` | the built Flutter bundle — minified output can name anything |
| `.pytest_cache`, `.dart_tool`, `__pycache__`, `_build`, `.venv`, `node_modules`, `.git` | generated, not written by anyone |
| `windows/`, `shared/` | other lanes (see below) |

The `dist` exclusion is the exact path `linux/webserver/dist`, not any directory
called `dist`, so a future `linux/scripts/dist/` is not silently dropped. Two
directories that *look* generated are deliberately kept: `linux/scripts/03-media/build/`
and `.../onnxruntime/build/` are real source. `.pytest_cache` was in the corpus
until 2026-09-03 — pytest writes test node ids there, exactly the shape that names
a function nothing calls.

**The allow file is two-way** ([the allowlist contract](#the-allowlist-contract)):
a key not frozen is NEW and fails; a frozen key that gains a caller, or whose
function is deleted, is STALE and also fails. Each group names the dispatch the
scanner cannot see:

- `linux/scripts/lib/*.sh` — the library API consumer repos source; the callers
  are not in this tree at all.
- `verify-parity.sh check_*` — reached as `"check_${check_name}"` over `CHECK_LIST`.
- `command_not_found_handle` — bash calls it, nothing else does.
- four `test-embedded-python-extract.sh` names — heredoc fixture text that
  `functions()` reads as column-0 definitions; it is not heredoc-aware.

The **DEAD** group the file carried until 2026-09-04 — three `cpython_ext_*` and
`verify_shared_lib_optional`, frozen only because their files sat inside the
2026-09-03 build closure — was deleted with its rows once that build shipped
(the 2026-09-04 wave). Deleting the two `cpython_ext_modules_*` wrappers orphaned their
private `_cpython_ext_modules_by_class`, which went with them.

### The limitation: same-name masking

The gate keeps **one name table for the whole corpus**. That is what makes it cheap,
and it is also its hole: a function is "used" as soon as *any* file names it,
so a dead `log()` in one script is kept alive by a live `log()` in another. Every
short helper name — `log`, `warn`, `pass`, `bad`, `err`, `cleanup` — is effectively
unguarded, and the gate's clean run is not evidence about them.

Four real dead functions were invisible to it on the day it was written, and all
four are now deleted: `ghcr-delete-tags.sh log()` (its sourced `ghcr-common.sh`
never called it), `verify-manifest-freshness.sh pass()`/`bad()` together with the
`ok`/`fail` counters they incremented — that script's Python heredoc prints its own
`OK`/`FAIL` lines — and, once the 2026-09-04 build shipped, `cleanup()` in
`linux/scripts/03-media/build/ffmpeg/build-ffmpeg.sh`. That last one never got an
allow row: masking hides it from the gate, so a row would have read STALE the
moment it was written. `tests/test-dead-functions.sh` pins its absence instead.

### The unlinked-definer arm: the part of the masking that IS provable

`unlinked()` is a second gate arm, added 2026-09-05 (backlog GH6). It fails a
definition when all four hold:

1. its **own file** never names it again, once comments and definition heads are gone;
2. a **second file defines the same name**, so the live verdict comes from a name this
   file does not own;
3. **every** other file naming it also defines it — no file that merely *calls* the name
   exists anywhere in the corpus;
4. and **no corpus file names two of those definers' basenames**, the subject's own text
   and the peers' included.

(4) is the whole argument. If nothing in the tree ever mentions two of these files
together, nothing can source or run them into one shell, so no mention of the name
can be about this copy — and (3) has already ruled out a caller that owns no
definition. It answers scope without a call graph, by asking whether the two
definitions could ever be in scope at the same time. It costs one basename scan per
surviving candidate, computed lazily; the gate stays under a second.

**It found one row on this tree**, and it is a true one:
`06-packaging/verify-parity.sh`'s `check_python`, the sixth of the six
`"check_${check_name}"` dispatch targets. Its five siblings have been frozen since
2026-09-03; this one could not be, because `06-packaging/smoke-toolchain.sh` defines a
`check_python` of its own and the name table therefore read it as used — an allow file
that looked complete and was one row short. The arm makes that row **writable**: a
masked function used to send its own freeze STALE the moment it was written (the
ffmpeg `cleanup()` precedent), and now the arm that flags it is also what holds it.

**How it is disarmed, which is the thing to know before editing near it.** Any corpus
file that starts naming both definers' basenames — a new test, a new runner, a doc
generator under `docs/scripts` — switches (4) off, the arm goes quiet, and the frozen
row then reads STALE. The STALE message says so. `tests/test-dead-functions.sh` is the
live instance of the hazard and assembles the name and both basenames from `printf`
arguments for exactly that reason, the same trap `arg-consistency` and `lint-env-knobs`
fixtures carry. The failure direction is a false *negative* plus a loud, explained
gate failure — never a false positive against correct code.

**What it deliberately does NOT do.** It is not the `source_module`-aware call graph
the next section prices, and it does not try to be. Two other rules were built and
measured against this tree first, and both are ruled out:

| rule | result |
| --- | --- |
| resolve `source`/`source_module` into a load graph, treat a candidate as dead when no file sharing a shell with it names the name | with unresolvable `source "${VAR}"` statements treated as hubs — the only conservative reading — the 478-file corpus is **one component** and the rule reports nothing |
| the same graph with the hubs dropped, restricted to files nothing else names by basename | **20 rows, 20 false positives.** Every one is a suite stub for a unit under test that the file loads through a path no resolver follows: a function body cut out with `sed` and fed to `bash -c`, a module path assembled at runtime |

That second measurement is the reason this arm asks whether two files can ever MEET
rather than trying to resolve what a call site sees.

### `--census`: the per-file pass, and why it is advisory

`python3 linux/scripts/verify_dead_functions.py --census` runs the pass masking
defeats: a definition whose **own file** never names it again. It cannot be a gate
on this tree, and the numbers say why. 428 definitions qualify, and nearly all are
alive: library helpers called by whoever sources the file, stubs a suite defines
for the code under test, `"check_${name}"` dispatch. Filter to files that are
self-contained — they source nothing, and no other corpus file names them by
basename — and **0** rows remain. A gate on the unfiltered set would be a
false-positive machine; a gate on the filtered set would be inert.

**So there is a second tier, added 2026-09-04, and it is the one that pays.** It
is keyed on `(file, name)` rather than on the file's reachability: a candidate
whose name a **second file also defines**. That is exactly the surface where the
gate's live/dead verdict comes from a name it does not own — the same-name masking
under "Known limits" — and it reports **94** rows today where the reachability
tier reports 0. The header also carries the slice of that list the unlinked-definer
arm can decide: the arm reaches **1** of them today, and the arm, not the census, is
what fails it. `--census` prints all four counts, lists both sets, and always exits 0.

Reading it: a row in either list is a deletion candidate, the masked list more
strongly than the other because the gate is provably blind there; the "never names
again" count is context, not a queue. The sourcing guard on the first tier is not
decoration — a library a file sources can call back into that file's own functions,
which is precisely the `command_not_found_handle` and `check_${name}` shape.

**The four numbers in this section are DERIVED, not re-typed.** They moved by 11
functions and 8 rows between two groomings before anyone noticed, so
`tests/test-doc-numbers.sh` now runs `--census` and compares its header against the
prose here — the considered count, the reachability tier, the masked tier and the
unlinked-definer count — and `--update` rewrites the digits. Nothing else in the repo
may quote them.

**What closing the masking hole actually costs.** The census is a watch list, not a
fix: it says *where* the verdict is untrustworthy, never whether a given definition
is dead. A verdict needs scope, and scope here means resolving, for each call site,
which definition of that name is in scope at that point — which is a call graph
over a `source`/`source_module` topology this repo builds at RUNTIME. Concretely it
needs: the sourcing graph (`source_module <name>` resolved through
`SCRIPTS_ROOT`, plus the container-vs-repo dual layout `media_load_arch_flags`
already switches on), the Dockerfile stage graph, because a `RUN` inherits only
what its stage COPYed, and a rule for the ~40 helper names two files define on
purpose. That is a second tool the size of the gate, and it would still guess at
`bash -c` strings — the 20-row measurement in the arm's section above is what that
guessing costs. What shipped instead is the corner of the problem that needs no
graph: the unlinked-definer arm decides the cases where the definers can never meet,
and the census keeps reporting the rest of the 94 as a watch list to delete from by
hand with the ffmpeg `cleanup()` precedent — pinning the absence in
`tests/test-dead-functions.sh`, since a masked function the arm does NOT reach can
never hold an allow row (it would read STALE the moment it was written).

**The quoted `' #'` trap.** Comment stripping removes from a `#` preceded by
whitespace to end of line. `$#` and `${#arr[@]}` are safe (no whitespace before the
`#`) and both are tested, but a call sitting after a quoted `' #'` earlier on the
same line is not seen. That direction is a false *negative*: it can hide a use,
never invent one.

`shared/` is out of the corpus for the same reason `windows/` is — it is a template
lane shipped to consumer repos, not a caller in this tree. The cost is visible:
three `lib/agentic-loop.sh` rows are frozen with `shared/agentic-loop/templates/Run-AgenticLoop.sh`
named in their reason instead of being seen. Adding `shared` to `CORPUS` would send
those three rows STALE; that is the deliberate trade, not an oversight.

### Coverage

`linux/scripts/tests/test-dead-functions.sh`, over throwaway trees —
each case copies the gate plus the two modules it imports and plants a subject,
callers and an allow file. 31 mutations (`dead-functions.*`), every one proven
to bite, covering the
corpus boundaries one at a time (Dockerfiles in; `.allow`, `.patch`, `.diff`,
`patches/`, `linux/webserver/dist`, `.pytest_cache`, `.dart_tool` and
`mutations.json` out; `dist` narrow), both `re.MULTILINE` flags (without them only
a comment or a definition head at byte 0 is stripped — every fixture used to sit at
byte 0, so the flags were previously proven only by the real tree), the `(?<=\s)`
lookbehind that keeps a tab-indented comment a comment, `linux/host-config` being a
subject and not merely a caller, the two-way freeze contract, both `--census`
tiers — the reachability filter, the masked `(file, name)` keying, and the rule
that the pass reports and never fails — and every clause of the unlinked-definer
arm, each shown by a fixture the arm must stay quiet on: the two definers linked by
a third file, by the peer, and by the subject; a caller that owns no definition; a
definition its own file names again.

## Stdout-return gate (`stdout-returns`)

A shell function whose STDOUT *is* its return value cannot log on fd 1.
`logging.sh` routes `log()`/`info()` to fd 1 and `warn()`/`err()`/`die()` to fd 2,
so the moment someone adds a `log()` to such a function every `x="$(f)"` caller
captures the log line together with the value. It shipped twice — the
`compiler_cache_launcher()` leak that configured GCC with an `[INFO]` line glued
to `sccache gcc`, and `normalize_llvm_cmake_dir()` logging into three call sites
that consumed its stdout as a path.

`verify_stdout_returns.py` pins the CLASS rather than either instance: it collects
every name used in a `$( … )` anywhere under `linux/scripts`, then reports each
definition of one of those names that opens a line with `log` or `info` and does
not redirect it. Both halves are load-bearing and both are mutated: dropping the
consumed-set filter reports functions whose stdout nobody reads, and dropping the
`>&2` check reports the documented fix. The logger must OPEN the line — matching
mid-line would flag every message that merely mentions a log file.

**Proof (2026-09-04).** `tests/test-stdout-returns.sh`, over
throwaway trees at the gate's own depth (it derives its root from `parents[2]`),
plus four `stdout-returns.*` mutations, every one proven to bite. This was the
first of the fourteen `gate-proofs.allow` slugs to be closed rather than
re-frozen; the shape generalises to the eight tree-consistency checkers still
listed above.

## Shellcheck warning ratchet (`shellcheck-warnings`)

`linux/scripts/verify_shellcheck_warnings.py`, preflight slug
`shellcheck-warnings`, baseline `linux/scripts/shellcheck-warnings.allow`, suite
`linux/scripts/tests/test-shellcheck-warnings.sh`.

One `shellcheck -x -f json1 -S warning` run over exactly the file set
`lint-shell.sh --list-files` prints, counted per `(file, SCxxxx)` and checked
against the frozen rows with the shared four-way rule. On 2026-09-04, after the
row review below: **319 files in scope, 174 warning-level findings in 72 files, 92
frozen rows** — SC2034 (84), SC2155 (19), SC2154 (16), SC2178 (12), SC2046 (11),
SC1090 (9), SC2163 (8).

**Every row carries a verdict (2026-09-04).** The 95 rows the baseline
froze on 2026-09-03 all read `not yet reviewed`; each has now been read against the
finding in its file and the reason column says why the code is right, or names the
defect and why it is not being fixed without a build. Three rows were closed by
fixing the code instead: an unguarded `cd` before `exec` in `lib/app-runner.sh` and
another in `ctest_run_execute` (both libraries set no `-e`, so a failed `cd` ran the
app or the suite in the caller's directory — `test-lib-modules.sh` now asserts no
bare `cd` survives anywhere under `lib/`), and a dead `arch` local in
`lint-dockerfiles.sh`. Four families account for most of what remains and none of
them is a defect: `local -n` namerefs SC2178/SC2034 cannot see, associative-array
subscripts SC2154 misreads as variable references, `export "${__varname}"` indirect
exports SC2163 misreads, and variables a *sourced* consumer reads. Two verdicts are
worth reading before anyone "cleans up" the rest: `verify.sh`'s SC2155 is
load-bearing (`version_major` returns 1 on an empty version, so splitting the
declaration would turn a tolerated empty `GCC_WANTED` into a `set -e` abort), and
the SC2034 rows that CL6 held open were dead code in build-closure files, kept
only because nothing static can prove a chain still runs. Four are **closed on
2026-09-05** — `stage-defs.sh`, `python_uv.sh`, `pre-setup.sh` and
`gstreamer-env.sh` lost their rows entirely, and `build-runtime-manifest.sh`
re-baselined 3 → 2 — each deletion landing with a suite that executes what
survives it, not with a grep. `package_archive.sh` stays at 4 by DECISION, not
by inertia: nothing in this repo invokes it and no stage copies it, so its three
parsed-and-ignored flags are a CLI contract for callers outside this repo and no
build can rule on them either. The two `SC2206` cmake-argv rows also stay, with
sharper reasons: `build-clang.sh`'s two values are file literals, so quoting is
provably a no-op, while `cross-env.sh`'s is operator-reachable, so quoting is a
real argv change only a build can price.

**Why it exists.** `lint-shell.sh` gates at `-S error` and prints warnings as
advisory noise, so those 177 findings were watched by nothing: the 178th was
free, and a fix nobody recorded left no trace. That the advisory tier is not
harmless is already written into `lint-shell.sh` itself — SC2215 (a `\`
followed by a comment, so the command runs with no arguments) is warning-level,
and on 2026-08-28 it dropped every flag from an android ONNX Runtime build and
cost four hours of chain time. SC2215 got its own hard-fail arm there; this gate
is the general form.

**One owner per input.** The gate computes neither its scope nor its binary:

| input | owner | why |
| --- | --- | --- |
| the file set | `lint-shell.sh --list-files` | a ratchet over a scope of its own would drift away from the linter it ratchets. List mode prints repo-relative paths and nothing else — it now returns before the `no shell scripts to check` banner, which as stdout would have become a scope entry |
| the binary | `lint-shell.sh --print-bin` | different shellcheck versions count different warnings, and a frozen count is meaningless without a frozen tool |

`SHELLCHECK_BIN` still overrides everything (the suite uses it to inject stubs);
the gate's own `shutil.which` lookup is gone.

**Version pinning, and why CI stopped installing shellcheck.**
`shellcheck_ensure` used to take any `shellcheck` on `PATH`. CI apt-installs
0.9.0 on noble while the baseline was frozen with the `versions.env` pin
`SHELLCHECK_VERSION=v0.11.0`, so CI would have gone red on counts that are
correct locally. It now accepts a `PATH` copy **only** when its reported version
equals the pin, and otherwise falls through to the bootstrap it already had — the
pinned release, downloaded once into a version-keyed cache and SHA256-verified.
The `Install shellcheck` step in `.github/workflows/ubuntu26.04.yml` is therefore
removed: the gate brings its own, verified.

**The commit hook is inside the scope (2026-09-04).** `lint-shell.sh` admitted
extension-less shebang scripts for EXPLICITLY passed paths only, so
`git ls-files -z | xargs lint-shell.sh --list-files` answered 319 files (hook
included — that is how `crlf-guard` reached it) while the argument-less default
sweep answered 312 `*.sh` and this ratchet asked *that* one. The one file every
commit runs was therefore linted at `-S error` and watched at warning level by
nothing. The default `find` now takes `\( -name '*.sh' -o -path
'…/linux/host-config/git-hooks/*' \)`; the shebang test downstream still decides
what is a shell script, so a non-shell hook is not swept in. The hook carries
zero warning-level findings, so the baseline gained no rows — the hole was
coverage, not debt.

**The set-dependence bug this gate was born with.** Without `-x`, shellcheck
follows a `# shellcheck source=…` directive only when the sourced file is *also*
a command-line input. The 300-plus-file run therefore saw a variable consumed by
a sourced sibling as used, while `--files linux/scripts/lib-orchestrator.sh`
alone reported SC2034 — the same file, two verdicts, decided by who else was on
the command line. Worse, `--write-baseline --files` then wrote a row the next
whole-set run rejected as STALE. `-x` makes both modes see the same thing;
whole-set counts are unchanged by it (177 findings, the same 95 rows). A
consequence worth knowing: with `-x`, editing file B can move file A's count when
A sources B. That is the truth the whole-set run always reported, and the
recovery is `--write-baseline --files A`.

| flag | use |
| --- | --- |
| *(none)* | the whole scope against the whole baseline — preflight and CI, ~22 s |
| `--files f…` | only these files against only their own rows, ~0.2 s — the pre-commit hook's staged mode. Counts are filtered to the listed files, so a finding the tool attributes elsewhere is not a staged file's problem, and other files' rows are not read as STALE. A path outside the scope is skipped with a visible `note:`, never silently |
| `--write-baseline [--files f…]` | freeze the current counts. Existing reasons are kept verbatim; a new row gets `baseline <date>, not yet reviewed`. With `--files`, unchecked files' rows are left alone |

**Exit 2 is never a pass.** Three ways this gate can be unable to answer, and all
three are exit 2 with a message rather than zero findings: `--list-files` fails
(an empty scope would check nothing and pass), `--print-bin` cannot produce a
binary, or shellcheck emits something that is not json1. Each has a suite case
and a mutation.

**Reasons may not contain `|` or `#`.** `quality_allow.load_counts` — the reader
the other gates share — takes the count as the *second field from the right*, so
a reason containing `|` shifts the column and raises `ValueError`, and an inline
`#` is stripped before the split. This gate therefore reads its allow file the
same way (comment first, fields after) and folds any extra `|`-separated tail
into one field when it rewrites, so what it writes is safe for every reader.
`verify_shellcheck_warnings.py` does not call `load_counts` at all — its frozen
counts come from the one parser that also carries the reasons — but that is a
workaround, not the fix: a shared `(count, reason)` reader belongs in
`quality_allow.py`, and is filed for that file's owner.

**Coverage.** `tests/test-shellcheck-warnings.sh`, over throwaway trees whose subjects provoke SC2034,
SC2155 and a source-directive pair, plus stub binaries for the paths a real
shellcheck cannot produce; 18 mutations (`shellcheck-warnings.*`), every one
proven to bite. The suite's
last case runs the gate against the live tree, and `SKIP_REAL_TREE=1` drops it —
which is what every mutation `test` command sets, so no mutation can be recorded
as biting because the tree drifted rather than because the guarantee was removed.

**The rows are frozen, not reviewed.** All 95 carry `not yet reviewed`. SC2034 is
85 of the 177 findings and is where the real bugs are: a variable that is
genuinely unused is usually a typo'd reference somewhere else. Triage belongs in
`docs/refactoring-backlog.md`; what this gate guarantees is only that the number
matches reality, so a change lands in the diff with a reason next to it.

## Contract tightening 2026-09-03 (`code-dupes`, `env-knobs`)

Two allowlisted gates were leaking in the same direction: their baselines could
only ever get *looser*. `code-dupes` froze a budget and never noticed when the
measurement fell below it; `env-knobs` printed a registry of operator knobs and
never noticed when a knob left the tree. A baseline that can only loosen is not
a baseline, it is a memo. Both now carry the four-way rule from
[The allowlist contract](#the-allowlist-contract), with the bookkeeping half
enforced as hard as the growth half.

### `code-dupes` — the budget must EQUAL the measurement

`docs/scripts/verify_code_dupes.py` against `docs/scripts/code-dupes.allow`,
rows of `fileA | fileB | budget | reason`. Four ways to fail:

| condition | what the gate does |
| --- | --- |
| new offender | an unlisted pair over the threshold is a finding |
| growth | a pair above its budget is a finding, printed with `over its budget of N` |
| unrecorded shrink | the budget is above the measurement — prints `shrank from W to N` **and the exact row to paste**, reason carried over verbatim |
| stale freeze | the pair is no longer over the threshold — prints `is no longer over the threshold (N shared, threshold T)` |

The stale line names the count measured **before** the threshold cut, so a pair
that merely dropped under the line reads differently from one that stopped
overlapping entirely (`0 shared`). The earlier wording, `no longer overlaps`,
was simply false for the first case and sent the reader looking for a deletion
that had not happened.

The key is an **unordered** pair, so `a | b` and `b | a` are the same row —
which means listing both is a bookkeeping error, not a redundancy. It exits 2
naming both line numbers rather than silently letting the last one win. A
same-file twin collapses to a one-element key and is written with the name
twice.

All bookkeeping is printed **before** the new-findings early return, so one run
shows everything: a stale row does not hide behind a fresh copy you were going
to fix anyway.

**The suppression side effect, now a mandatory edit.** A shingle held by more
than `MAX_OWNERS` (6) units is treated as idiom and dropped from pair counting.
That makes *mass-copying* the one reliable way to hide duplication from this
gate: paste a block into a seventh place and every pair count that block feeds
goes **down**. Before the shrink rule that just made the gate quieter. Now the
drop is an unrecorded shrink, and the gate refuses to pass until the new, lower
budget is written into the allow file — so the mass-copy lands in the diff with
a human's reason beside it. The widest blocks are still surfaced as a ranked
worklist under `--report` (`widely-copied blocks`) rather than being thrown away.

**`--kind` scopes the allowlist too.** `--kind shell` judges only rows whose
files are both shell; other kinds' rows are neither judged stale nor counted in
the `N allowlisted pair(s)` total. Two caveats that follow from that:
`--kind md` on a tree with no Markdown in scope exits 2 (`nothing in scope`),
and **`--baseline --kind X` rewrites the WHOLE file from that kind's pairs
only** — it will drop every other kind's row. Re-baseline without `--kind`.

**`--baseline` is destructive by design.** It keeps the five header comment
lines and nothing else: rows are re-sorted by budget descending, existing
reasons carried over verbatim, new rows dated `baseline <today>, not yet
reviewed`, and pairs at or under the threshold dropped entirely. The live file
is hand-ordered and carries per-row review notes, so the 2026-09-03 re-baseline
was done **in place** rather than by running `--baseline`. Treat the flag as a
first-freeze tool.

No census number is kept here: the scanned-unit and file counts move with every
file added, so a copy in prose is stale the day after it is written. The gate's
own OK line prints them — run `python3 docs/scripts/verify_code_dupes.py`. The
stable parts are the shape: no block over 10 shared 12-token shingles, deliberate
twins budgeted in `code-dupes.allow`, and shingles with more than 6 owners
suppressed as idiom.

### `env-knobs` — a stale allow row always fails

`linux/scripts/lint-env-knobs.sh` against `linux/scripts/lint-env-knobs.allow`,
preflight slug `env-knobs`. A knob is CONSUMED if some `*.sh` under
`linux/scripts` reads it as `${VAR:-...}`. It is OWNED by any of four things:
a key in a `.env` file a build stage SOURCES, a Dockerfile `ARG`/`ENV`, an
assignment or `: "${VAR:=…}"` anywhere in the scripts, or a row in the allow file.
Both the consumed scan and the two script-side owner scans go through one `_scan`
helper, so *reader* and *owner* are decided by exactly the same line filter.

**Which `.env` files own (2026-09-05).** `ENV_OWNER_FILES` is
`01-core/versions.env` plus `03-media/core/arch-flags-*.env`. The arch-flags files
were missing until 2026-09-05, and that was the gap: `MEDIA_SKIP_CSOUND` and its
five siblings are knobs whose value is **data, not an operator choice** — the
riscv64 file sets `MEDIA_SKIP_CSOUND=1` and the arm64 file `=0`, and
`media_load_arch_flags` (`03-media/core/common.sh`) sources whichever matches the
target arch. Re-homing them to a `: "${MEDIA_SKIP_CSOUND:=0}"` at the reader would
have been a second, competing claim on the value; teaching the scan the file that
already owns them retired all six registry rows instead (215 → 209).

`04-runtime/runtime-paths.env` is deliberately NOT in that list. It is reference
data `verify-runtime-paths.sh` compares Dockerfile `ENV` blocks against, and no
stage sources it, so counting its 39 keys would invent an owner for every path
knob. `tests/test-env-knobs.sh` pins both directions, and a mutation each way
holds them.

Unowned knobs stay advisory unless `KNOB_GATE=1` (preflight always sets it).
A **stale** row — one whose knob no reader consumes any more — fails
unconditionally, `KNOB_GATE` or not, because it is bookkeeping, not a judgement
call: the registry claims to describe the operator surface, and a row for a knob
nothing reads describes nothing. For the same reason the
`OK: every consumed knob has an owner` line is withheld while a stale row is
failing. That line was technically true in exactly that state, which is what
made it worth removing.

**A comment is not a reader.** The scan used to `grep -o` straight out of the
raw file, so prose *about* a knob kept its row alive. Two rows were being held
up by nothing but explanation — `OPTIONAL` by a sentence in
`01-core/guard-helpers.sh` describing what vendored files do, and
`UBUNTU_PORTS_MIRROR_URL` by the `01-core/cross-env.sh` note recording that the
fallback had been **deleted**. The row survived precisely because someone wrote
down that the reader was gone. The pipeline now greps whole lines, drops
full-line comments, strips trailing ` # …`, and only then extracts knob names;
both rows are deleted, and a third comment-only mention (`EXTRA_CMAKE_FLAGS` in
the LiteRT build) no longer counts as consumption.

Three limits of that filter, stated so nobody rediscovers them:

- The trailing-comment strip cuts at the first **whitespace-preceded** `#` and
  is not quote-aware. `${#arr[@]}` is safe (its `#` follows `{`), but a knob
  read to the right of a ` #` that sits *inside* a quoted string would be
  missed. Measured 2026-09-03 over every non-comment `${VAR:-}` line in the tree:
  the strip removed zero knob occurrences that day. The failure mode is loud — a live
  row reported stale — not a silent pass.
- Full-line `#` inside a heredoc is dropped like any other comment. For the
  shell and Python bodies this repo emits that is correct; a heredoc in a
  language where `#` is not a comment would lose a reader.
- `$VAR`, `${VAR}` and `${VAR:?}` readers are invisible **by design**. The gate
  is about the *default-carrying* operator surface: `${VAR:-x}` is a knob with a
  documented fallback, a bare `$VAR` is an internal variable.

**A comment is not an OWNER either (2026-09-04).** The fix above was applied to
the consumed side only; the owner scan still `grep -o`'d the raw file, so one
`# FOO=1` written anywhere under `linux/scripts` made `FOO` owned and silenced
the unowned check for it. That is the worse half of the bug — the consumed side
fails loud (a live row reported stale), this one fails silent. Owners fell from
1272 to 1219 when the same filter was applied, and **fifteen** live knobs turned
out to have no owner but prose. None were fixed at the reader; every one is a
real `${NAME:-default}` operator switch that nothing in the repo assigns, so all
fifteen were first re-homed as documented rows in `lint-env-knobs.allow`.
`SKIP_REAL_TREE` is the one that shows the shape of the hazard: it was
introduced by the same batch that added the consumed-side filter, and its only
owner in the whole tree was the sentence in `test-shellcheck-warnings.sh`
explaining it.

**A row is not a home (2026-09-04, build window).** Thirteen of the fifteen were
then given a `: "${NAME:=default}"` at the reader and their rows deleted with
them, so the default is greppable where it is read instead of in a registry:
`IREE_CROSS_BUILD_COMPILER`, `LINT_DOCKERFILES_BUILD_CHECK`,
`LLVM_INSTALL_PROFILE`, `MEDIA_STRIP`, `NODE_RISCV64_MAJOR_REQUIRED`,
`OPENCV_GSTREAMER_PASS`, `PYTHON_LTO`, `RUNTIME_CLANG_VERSION_SMOKE`,
`RUNTIME_COMPILER_SMOKE`, `RUNTIME_IMAGE_SMOKE`, `SKIP_REAL_TREE`,
`STV_COMPUTE` and the renamed `CROSS_GCC_TOOLCHAIN_PATH` — that last one deleted
outright on 2026-09-05 with the function that read it (backlog CL3), leaving
twelve. `:=` and `:-` share
their empty-or-unset fallback rule, so the only behavioural difference is that
the variable is now SET in the reading shell — which is why a knob whose value
is data rather than an operator choice must not be converted. `MEDIA_SKIP_CSOUND`
is exactly that knob and stays a row: its real value comes from
`03-media/core/arch-flags-<arch>.env` (`=1` on riscv64, `=0` on arm64), sourced
by `media_load_arch_flags`, and the owner scan reads `*.sh` only, so the `.env`
that decides it is invisible to the gate. `PREFLIGHT_ONLY`/`PREFLIGHT_SKIP` are
the other two, left to the lane that owns `preflight.sh`.

**Nor is a message, a usage line or a test argument (2026-09-04).** The comment
filter above is line-wise, and the owner scan still `grep -o`'d raw line text, so
an assignment-shaped substring *inside a quoted string* owned the knob:
`err "…; FORCE_LOW_DISK=1 accepts the risk"` owned `FORCE_LOW_DISK`, and
`_lane_run FORCE_LOW_DISK=1` — an argument to a test helper — owned it a second
time. **Forty-five** live knobs had no other owner: 36 real operator escape
hatches (`FORCE_LOW_DISK`, `GCC_REQUIRE_GPG`, `RUNTIME_REGISTER_BINFMT`,
`OPENCV_ALLOW_NO_PNG`, `WRAPPER_CONTENT_GATE`, …), 5 test-fixture knobs
(`BUILD_RC`, `DISK_OK`, `HAS_PINNED_BASE`, `TRANSIENT`, `MODRES_POISON_SOURCED`),
3 values injected into the smoke container rather than assigned in a shell
(`RT_PROBE_SH`, `SMOKE_ONNX_PY`, `STV_ASSERT_ONLY`), and `VERSION`, which CI
exports after `version_util.sh` writes it to `$GITHUB_ENV`. All 45 are documented
rows in `lint-env-knobs.allow`; none was silenced by widening the scan.

The owner scan is now a ~40-line `awk` tokenizer instead of a grep. It drops
comments, single- and double-quoted text and heredoc bodies, and counts a
`NAME=` only in **command position**: line start, or after `;` `&&` `||` `|` `(`
`)` `{`, a `case` arm's `)`, `then`/`else`/`elif`/`do`/`if`/`while`/`until`,
`export`/`local`/`declare`/`readonly`/`typeset`/`env`/`time`/`!` (with their
option words), or another assignment word in an env-prefix chain. Two details
carry their weight: `"$( … )"` re-enters code, so `_out="$(VULKAN_CROSS_STRICT=1
_trace)"` still owns — without it four live knobs lost their only owner; and the
`{` guard stays, so a `${VAR=x}` expansion is not an assignment (the owner form
is the documented `: "${VAR:=…}"`). Heredoc bodies deliberately own nothing: the
`NAME=value` lines in `runtime_write_artifact_metadata`'s `artifact.env` are data
this repo *emits*, not settings it applies to itself. Script-side owners fell
1271 → 912.

This is the same command-position idea the shell complexity gate implements in
the complexity gate (`verify_code_size.code_lines` + `_Walker`), and it is deliberately
**not** shared: that one is a Python module that returns metrics for a scan set,
this one is an awk filter inside a bash pipeline, and making the bash gate import
the Python one would buy a duplicated 40 lines at the price of a cross-language
dependency in a 0.5 s gate. If a third consumer ever needs it, extract one
tokenizer then.

Its one shared limitation is also worth stating: quote state resets at each
newline (the complexity gate does the same). A `NAME=1` line in the middle of a
multi-line `'…'` argument therefore still reads as an assignment. It can only
*add* an owner, never remove one, and the heredoc skip already covers the form
this repo actually writes multi-line program text in.

**A backslash-escaped `\${NAME:-}` is not a reader.** A sixteenth knob, `VAR`,
surfaced — the gate's own output strings say `consumed \${VAR:-} knobs:`. That
is literal text, not an expansion, so an allowlist row would have been a lie.
`_scan` now deletes `\$` sequences before extracting. Measured over the tree,
`VAR` is the only name that ever appears escaped-only; `LD_LIBRARY_PATH` and
`SUDO` also appear escaped but have real readers elsewhere.

**The private-prefix promise lives in the extraction regex.** A trailing
`grep -vE '^_'` used to sit after extraction, where it could never match: the
regex before it already demands `[A-Z]` first. It is deleted. The `_scan`
selector is now deliberately loose (`[A-Za-z_][A-Za-z0-9_]*`) precisely so the
extract pattern is the only thing enforcing the rule, and a mutation that widens
it to `[A-Z_]` surfaces `_PRIVATE_KNOB` as unowned.

**Scope gotcha.** `linux/scripts/**/*.sh` is a recursive scan and it includes
`linux/scripts/tests/`. A suite that spells a literal `${MY_FIXTURE_KNOB:-}` in
its own source registers as a real consumer of that name in the live census —
this bit while writing `test-env-knobs.sh`, where two fixture knobs surfaced as
UNOWNED against the real tree. The suite therefore spells every fixture knob
through `printf '${%s:-}' NAME`, the trick the original `_consume` helper
already used.

Census at the time of writing (2026-09-03): `consumed ${VAR:-} knobs: 643 |
owners: versions.env=174 dockerfiles=116 scripts=912 allowlist=225 | stale allow
rows: 0`.

### The owner tokenizer, 2026-09-04

Two holes in the tokenizer were making the census lie, and both are closed.

**A heredoc redirection is matched in the character loop, BEFORE quote state.**
`<<X`, `<<-X`, `<<'X'`, `<<"X"` and `<<\X` all now mark their body as data.
The pre-2026-09-04 code matched the terminator on the *post-quote* text, so
`cat <<'EOT'` had already been reduced to `cat <<` by the time the heredoc was
looked for, and the whole usage block was scanned as code. That is how ~45
operator switches came to be "owned" by their own help text. `hdpush()` parses
the delimiter itself and returns the index past it, so the delimiter never reaches
quote state.

**Heredocs are a QUEUE.** Several opened on one line end one at a time:
`cat <<'ONE' <<'TWO'` ends ONE at `ONE` and TWO at `TWO`, instead of treating the
second body as code. A heredoc opened inside `$( )` works in both nesting shapes,
because `$( )` is already a code frame and the detection lives in code state.

**Unquoted delimiters must start `[A-Za-z_]`** — the same shape the old regex
demanded. That single rule is what keeps `<<<` here-strings and `$(( a << 2 ))`
from opening one; its bail returns past the second `<`, so a here-string cannot
re-enter as a heredoc. KNOWN LIMIT, unchanged: an arithmetic shift by a NAMED
variable (`$(( x << SHIFT ))`) still looks like a delimiter. Nothing in the tree
hits it today, and an END-rule probe over every script the owner scan reads
(295 on 2026-09-04) finds no unterminated
heredoc at EOF.

**Ownership follows the whole env-prefix chain.** `FOO=1 BAR=2 cmd` credits both.
The match loop no longer truncates the line as it walks it — it fed `cmdpos` the
VALUE of the previous assignment as the whole prefix, so only the FIRST name of a
chain owned, while the doc already CLAIMED chain support. `cmdpos` walks the
prefix back over preceding assignments, so `cmd A=1 B=2` still credits neither:
a word after a command name stays an argument even when it is assignment-shaped.

Census after (2026-09-04): `consumed ${VAR:-} knobs: 643 | owners: versions.env=174
dockerfiles=116 scripts=946 allowlist=225 | stale allow rows: 0`. Five script-side
owners were LOST, every one a quoted-delimiter heredoc body (a `python3 <<'PY'`
program, a `versions.env` fixture, a `<<'EOF'` fixture); none of those names went
unowned. 29 were GAINED, all genuine env-prefix chains. Both censuses are dated
snapshots of that one change, kept because the deltas are what they explain; the
live figure after the 2026-09-04 integration wave is `637 | 176 / 116 / 982 / 214`,
and the gate is the authority for it, not this page.

### Proof

`linux/scripts/tests/test-code-dupes.sh` and
`linux/scripts/tests/test-env-knobs.sh` each copy their gate into
a throwaway tree — the gates derive their root from their own path — and parse
the measured overlap rather than hardcoding it, so the fixtures cannot rot.
12 entries (`code-dupes.*`) and 29 (`env-knobs.*`) in
`docs/scripts/mutations.json` neuter one guarantee each and are proven to make
those suites fail: the shrink and stale detections and their
exit codes, the pre-threshold count, the stale wording, the duplicate-row exit,
the `--kind` scoping, the bookkeeping ordering, `--baseline`'s reason carry-over,
the two comment filters, the `KNOB_GATE`-independence of stale, the withheld
all-clear line, the trailing strip's cut point, the escaped-`\$` deletion, and the
extraction regex that bars `_`-prefixed privates. The rest neuter one piece each
of the owner tokenizer — quoted text, command position, comments, heredoc bodies,
`$( )` re-entry, the keyword prefixes, the env-prefix chain, the case arm, and
the `${VAR=x}` guard, plus the heredoc rewrite above: the body-is-data rule, the
quoted delimiter, the `<<-` tab-stripped terminator, the queue, the here-string
bail, single-quoted text in command position, and both halves of the env-prefix
chain.

## Trailing-conditional returns (`trailing-conditional`)

A shell function returns the status of its **last** command. So a function whose
last statement is `cond && action` returns 1 whenever `cond` is false — on the
path where there was *nothing to do* — and a caller under `set -e` dies there
with no message at all. Two silent build deaths in two days had exactly this
shape: `reconcile_local_wheels` on 2026-09-03, and the `logging.sh` ERR-trap case
on 2026-09-02, which is the same bug seen from the trap side.

shellcheck has no check for it. SC2015 is about `a && b || c` precedence and says
nothing about a function's exit status; `-S error`, which `lint-shell.sh` gates
at, would not fail on it even if it did. `linux/scripts/verify_trailing_conditional.py`
closes that hole over every `.sh` file under `linux/`.

### The rule

For each function the gate takes the **last statement** of the body and asks what
its status is. The statement is the last non-empty line of stripped code, joined
backwards over continuations (a line ending in `\`, `&&`, `||`, `|`, `{`, `(`,
`then`, `do` or `else` continues into the next), then cut at its last top-level
`;`. Stripping is `verify_code_size.code_lines` — the one tokenizer the size,
complexity and dead-function gates already share — so comments, quoted text and
heredoc bodies are invisible and a `&&` inside `"…"` or `$( … )` is not an
operator.

Given that statement, in this order:

| shape | verdict |
| --- | --- |
| a bare `done` / `fi` / `esac` / `}` | step INTO the block: judge its own last statement instead |
| a top-level `\|\|` | judge the **last arm** by these same rules, and answer with that |
| a top-level `&&` | **finding** |
| first word is `[`, `[[`, `test` or `!` | **finding** |
| a bare call to a function this FILE defines that is itself a finding | **finding** |
| anything else | not a finding |

"Top level" means at paren depth 0 and outside `[[ … ]]`, so `[[ -n "${a}" \|\|
-n "${b}" ]]` is read as one test — its `||` is an operator of the test, not a
fallback arm — and `x="$(a && b)"` returns the assignment, not the inner list.
`&&` and `||` bind looser than `|`, which is why the presence of `&&` is decided
before anything is said about pipelines.

The first and last rows are the 2026-09-05 sharpening (backlog GH3), and each has
a limit built in on purpose:

* **A closer is stepped through only when it is bare.** `done | sort -u` returns
  the pipeline, not the loop body, so a closer carrying any top-level operator is
  judged as the ordinary statement it is. Inside the block the last live line is
  taken as the block's last statement — for an `if` that is the last branch, for a
  `case` the last arm, and a `;;`-only line is skipped rather than read as empty.
  The other branches are not examined: one hop, not a path enumeration.
* **The delegate hop stays inside one file.** A trailing bare call is credited to a
  definition in the SAME file, iterated to a fixed point, so `is_cross` and
  `cross_build_enabled` inherit `cross_build_is_active`'s verdict, which inherits
  `cross_target_is_foreign`'s. Reaching across files would resurrect the same-name
  masking GH6 describes: one `log()` anywhere would decide every `log()`.
* **A `||` is no longer blanket cover.** The old rule trusted any top-level `||`;
  the new one trusts only what the author put in the LAST arm. `a && b || true`
  still passes; `do_thing || [ -n "${x}" ]` and the SC2015 shape `a || b && c` do
  not. This found nothing in the tree — a rule that closes a hole rather than one
  that reports a defect.

The fix the gate asks for is to end on the action:

```sh
[ -x "${cxx}" ] || return 0
printf '%s' "${cxx}"
```

### The false-positive shape, and why there is an allow file

A trailing conditional is *idiomatic* wherever the function's status **is** the
answer: `cross_mode_requested`, `best_effort_mode`, `smoke_is_elf`,
`ancestry_run_ids_coherent` and a dozen more exist only to be read in a
condition. The gate cannot see call sites, so it cannot tell those from a defect
— and it does not try. Sixteen predicates and two verdict functions
(`smoke_test_ffmpeg`, `patch_csound_sys_char_signedness`) are frozen in
`trailing-conditional.allow` under the two-way rule of
[the allowlist contract](#the-allowlist-contract): a key that is not frozen is
NEW, a frozen function that stops ending on a conditional is STALE. The key is
`<file>\t<function>` — never a line number, which would re-flag every site
whenever something above it moved. Each group carries the reason it was kept.

Freezing one is a judgement, so make it out loud: **every** call site must read
the status as an answer. If any caller invokes it bare under `set -e`, it is a
defect, not a predicate.

### Known limits

The four false negatives this section used to list — last-statement-only, the
block closer, the trusted `||`, and the one-line definition — were closed on
2026-09-05. A one-line `f() { …; }` now presents the same body as a multi-line
one: the definition head comes off the first line and the closing brace off the
last, which is the only thing that trim is for — a `}` on its own line is already
handled as a block closer. What remains:

* **One hop, one file.** The delegate rule does not follow a call into another
  file, and it does not follow a call made through a variable or `eval`.
* **A block written on ONE line is judged whole.** `if [ -n "${x}" ]; then
  do_thing; fi` on a single line is not stepped into: its first word is `if`, and
  an `if` with no matching branch returns 0. Only a bare closer on its own line
  opens the block.
* **A definition indented inside a block is not scanned at all.** `DEF` is
  column-anchored, shared with the size and dead-function gates, so the
  `cross_build_is_active` fallbacks defined inside `if ! command -v …` blocks in
  `01-core/common.sh` and `03-media/core/common.sh` are invisible here.
  `tests/test-cross-fallback-parity.sh` is what watches those.
* **A `while true` loop never falls out of the loop**, so its body's trailing
  conditional is not what the function returns. `invoke_agent`
  (`lib/agentic-loop.sh`) is the one such FALSE POSITIVE in the tree today. It was
  normalised to an `if` rather than allow-listed, because a `break` added later
  would make it a real defect — and the behavioural half of that one is honestly
  unproven: reverting it fails the gate, not a suite.

Every remaining limit but the last is a false NEGATIVE. The gate is deliberately
tuned that way: a noisy gate gets an allow row, and an allow row is cover.

### The four the first version found

All four were live, all four are fixed, and each has a mutation that restores the
old shape and a case that catches it:

* `derive_cxx_from_cc` (`01-core/compiler-resolution.sh`) ended on
  `[ -x "${cxx}" ] && printf …`, so a derived `c++` that is not executable
  returned 1 — against the function's own documented contract of "empty output".
  Its caller at `:130` assigns it inside a `||` list, where that status kills the
  script instead of returning the intended 1. Fixing it moved the refusal to
  `_cross_env_resolve_tools`, which now tests the value rather than the status.
* `_chain_on_exit` (`build-cross-chain.sh`) is the chain's **EXIT trap** and
  ended on `declare -F cross_cleanup_local_context_workdir … && …`. Whenever that
  helper is not defined the trap returns 1, and under `set -e` a chain that
  finished green exits 1.
* `patch_gstreamer_sources` (`03-media/…/patch-gstreamer-sources.sh`) ended on
  the last of six `[ -f … ] && bash apply_patch …` lines. Both call sites invoke
  it bare under `set -euo pipefail`, so a tree without `subprojects/gst-libav`
  would abort the GStreamer build. Only the last of the six is converted to an
  `if`; the other five are not the function's status, and the gate now guards the
  end of the list against a seventh patch being appended.

### The five the sharpening found

Four are the same defect the gate was built for, one file deeper than the old
rule could see; each is now an `if` whose false path returns 0, and each has a
case in part B that runs the function off-target under `set -e`.

* `csv_each` (`01-core/guard-helpers.sh`) looped `[ -n "${_item}" ] && "${_fn}"
  …`, so a CSV with a trailing comma — `a,b,` — made the loop's last iteration
  the empty one and the helper returned 1, against its own documented contract
  that empty elements are *skipped*.
* `append_version_build_args` (`01-core/version-forwarding.sh`) did the same over
  the tracked-version list, and `append_common_build_args` ends on a call to it,
  so an empty value in the LAST versions.env key would have taken the
  orchestrator's build-arg assembly down with it. Latent today only because every
  tracked key currently has a value.
* `_dump_gst_build_logs` (`03-media/…/build-gstreamer-stage.sh`) is the GStreamer
  stage's ERR trap and ended on the last of four `[ -f … ] && echo && cat` lines
  — the same shape, from the trap side, as the `logging.sh` death of 2026-09-02.
* `wasm_opt_load_pin` (`lib/wasm-opt.sh`) returned 1 whenever the last
  `BINARYEN_*` key was already exported, which is its documented normal path
  ("unless they are already set").
* `invoke_agent` (`lib/agentic-loop.sh`) is the false positive described under
  Known limits.

The delegate hop and the one-line rule also made three predicates in
`01-core/cross-env.sh` visible for the first time (`cross_build_is_active` and
its two aliases), plus `is_amd64_arch` and ten one-line stub predicates in
suites. All fourteen are frozen with their reason; none is a defect.

### Proof

`linux/scripts/tests/test-trailing-conditional.sh` plants one
`subject.sh` per rule in a throwaway tree — the gate derives its root from its
own path — and then lifts each of the fixed functions out of its file with `sed`
and runs it under `set -eu`, because none of those three files can be sourced
whole. The mutation entries neuter the `||` escape hatch, the `[[ … ]]` bracket
tracking, the `;` cut and the continuation join, plus one per fix.

The 2026-09-05 wave added a case per new shape (one-line body, each of the three
block closers plus the two shapes a closer must NOT open, the `||` last arm, the
delegate hop and its cross-file refusal) and one part-B case per fix. It also
retired one assertion: `a || b \\` + `&& c` was the old proof that continuations
are joined, and that shape is now a finding on its own, so the join is proven
instead by `out="$(a \\` + `&& b)"` — a bare `&&` list read alone, an assignment
once joined.

Cost: 0.49s over the whole tree, next to `dead-functions` at 0.50s and
`code-complexity` at 0.66s, both already in the hook's fast tier.

## Nine gates that left the unproven list (2026-09-05)

`gate-proofs.allow` froze **12** preflight slugs at the 2026-09-03 baseline with
neither a suite nor a mutation. Three left on 2026-09-04. This wave closed nine
more, each the same way: a characterisation suite driving the REAL gate in a
throwaway tree, every case asserting the exit code and not only the message, plus
mutations over the gate's own script that turn that suite red.

Two rules shaped every one of them.

**A gate has to be able to be GREEN.** Each suite opens with a healthy fixture.
Without it a red case proves only that the fixture is broken.

**Advisory is a contract, not an omission.** Four of these gates deliberately
report findings without failing — the extraction is heuristic, or the divergence
is sometimes legitimate. Each of those has a mutation that makes the advisory
FATAL and a case that catches it. A suite that pinned only the message would let
the two kinds swap places silently.

### Android library stage parity (`android-parity`)

`01-core/verify-android-stage-parity.sh`. The five `android-*` stages in
`Dockerfile.android` are copy-paste ON PURPOSE — separate stages are what makes
BuildKit build them concurrently — so the gate makes the copy mechanical:
normalise `ARG ANDROID_LIB`, drop comments and blanks, require the five blocks to
be byte-identical.

`tests/test-android-stage-parity.sh` pins the two deliberate differences (the
LIB value, per-stage comments) against six ways to break it, of which two are the
ones a reader would not think of: a divergence in the LAST stage (the first is
the reference, so a loop that stops early lets the tail drift), and a stage the
gate can no longer FIND — a rename that quietly drops a fifth of the Dockerfile
from the comparison. `android-parity.stage-list-complete` is the same hazard from
the other side: the script's own `STAGES` list is the contract.

### Patch integrity (`patch-integrity`)

`verify-patch-integrity.sh`. A malformed or orphaned patch only detonates hours
into a cross build, so the gate reads every `*.patch` statically: it must parse as
a unified diff (`---`, `+++`, `@@` all three), and some `*.sh` must name it.

The apply SITE is advisory: a raw `git apply` reports INFO and still passes,
because some sites legitimately pre-date `apply-patch.sh`.
`patch-integrity.raw-apply-site-is-advisory` is what keeps a later tightening from
turning a green tree red for no build reason. The corpus being `*.sh` is also
pinned: a patch named only in a doc is still applied by nothing.

### Script COPY coverage (`copy-coverage`)

`verify_script_copy_coverage.py`. The bug it was written for was TRANSITIVE:
`Dockerfile.package` COPY'd and RAN `install-deps.sh`, which sourced
`/opt/scripts/03-media/core/common.sh` that the image never had — exit 127, deep
inside a build. So the suite's load-bearing case is the transitive one; a
direct-references-only check calls that image complete.

Four more shapes are pinned because getting any of them wrong makes the gate red
on a HEALTHY tree, which is how a gate gets switched off: a directory COPY
provides everything beneath it, a per-RUN bind mount counts as provided, a COPY
wrapped over backslash-newlines is one logical line, and `KNOWN_BASE_PROVIDED` is
keyed per Dockerfile so an inherited path cannot leak to every image. Two more
cover the vacuity edges: a tree with no Dockerfiles fails rather than reporting a
clean sweep, and `--report-core-usage` stays read-only — its own docstring calls
its counts a lower bound.

### Ubuntu mirror consistency (`mirror-consistency`)

`01-core/verify-ubuntu-mirror-consistency.sh`. APT-HTTP is why this gate has two
halves. The original check only proved `use-fast-ubuntu-mirror.sh` was
REFERENCED — and that is exactly how the CA-bootstrap http downgrade shipped with
nothing restoring https for a custom mirror.

So the suite gives each half its own red. The WIRING half: `bootstrap_ca` must
call `restore_mirror_https_scheme`, and AFTER the ca-certificates install —
restoring earlier puts apt back into the chicken-and-egg the downgrade existed to
break. The OUTCOME half runs the real downgrade+restore pipeline on a fixture
sources file and requires it to END on https; `mirror-consistency.outcome-is-asserted`
is APT-HTTP itself, a call site that was present while the sources stayed on
http. A third case guards the fixture's own PRECONDITION: if the downgrade stops
landing there is nothing left to restore and the outcome check would pass for the
wrong reason.

### Runtime path consistency (`runtime-paths`)

`04-runtime/verify-runtime-paths.sh`, and the LOG31 note on it is literal: this
script once NEVER failed, an inner warning swallowed by an outer green. Its
contract is now split down the middle and the suite proves both sides.

Missing INFRASTRUCTURE — `runtime-paths.env`, `versions.env`,
`Dockerfile.package`, `Dockerfile.media` — is a broken tree and fails hard, all of
them reported in one run rather than one per invocation. Every path-mismatch WARN
stays advisory, because the ENV-block extraction is heuristic and produces false
positives on a healthy tree; `runtime-paths.warn-is-advisory` and
`runtime-paths.warn-scope-is-narrow` are the two mutations that keep a
well-meaning tightening from making the gate unusable.

### Version ARG consistency (`arg-consistency`)

`01-core/verify-arg-consistency.sh` is six sections and they are not all fatal.
Fatal: an ARG default that drifts from `versions.env` (it wins silently on a plain
`docker build`), a default-LESS ARG naming a `versions.env` variable (the
LITERTJS_VERSION class — an empty value), the two case-mapped literals in
`gcc.sh` and `common.sh`, the ~25 inline GCC fallbacks, and a hand-forward
duplicating the auto-forward (XC7). Advisory: the `# noforward` coverage warning,
and the generic `${VAR:-literal}` scan, whose divergence is often deliberate.

The case worth naming is `arg-consistency.scan-vacuity-floor`. The GCC literal
scan refuses to report OK when it matched fewer than ten sites, because a refactor
that rewrites those literals into a shape the pattern cannot see would otherwise
make the gate find nothing, print a pass, and let the next bump drift unnoticed.
The suite drives that floor directly.

One trap the suite had to dodge, and the next editor will too: this file lives
under `linux/`, so a literal inline GCC fallback written out in the test source is
scanned as a REAL site. The fixture assembles the expansion from `printf`
arguments instead. The same rule applies to the version-snapshot generator's
basename — see below.

### Workflow lint (`workflow-lint`)

`lint-workflows.sh` names its own hazard: "a lint gate that checks nothing still
reports green". Two ways that happens, and both are driven against the real
`actionlint`. Linting the WRONG TREE: the optional root argument exists because a
submodule checkout puts this script inside the consumer, where the default root
resolves to ContainerHub; the suite gives it a broken checkout and a clean one and
requires the verdicts to follow the argument, and a root that does not exist to be
refused rather than fall back. Running an UNPINNED binary: with no `actionlint` on
`PATH` and an empty cache, a missing `ACTIONLINT_VERSION` and a missing
`ACTIONLINT_*_SHA256` each have to refuse, driven offline through a fixture tree
that carries its own `versions.env`.

### Secret scan (`secret-scan`)

`lint-secrets.sh` over the working tree with the pinned `gitleaks`. The suite
plants a synthetic credential — assembled at run time, since this repo scans
itself — and requires four things: the gate FAILS, the finding names the file and
line (it once failed on main saying "leaks found: 2" and naming neither, which is
what `--verbose` is for), the value is REDACTED so the CI log does not become the
leak, and the scan is scoped to the path it was handed. No case scans the whole
repo: that run is the preflight slug's own job and would cost this suite minutes.

### Curated SBOM (`sbom`)

`generate_sbom.py --check`. The curated half of the inventory is the published
corresponding-source record for the copyleft components an image scanner cannot
see, so a document that drifts from `versions.env` is worse than none.

The gate is only possible because the document is byte-REPRODUCIBLE — hence the
frozen `1970-01-01T00:00:00Z` creation stamp, which the suite asserts directly: a
wall-clock stamp would make `--check` red on every run, and a gate that is always
red gets switched off. The other cases are the ways `--check` could be hollow: a
missing file is not an up-to-date file, comparison is byte equality rather than
existence, `--stdout` writes nothing, and a `versions.env` bump really does move
the document.

### The repo's own cmake-format gate (`cmake-format`)

An inline preflight function that drives `lib/code-quality.sh` end to end:
`code_quality_ensure_cmake_format` provisions the tool through uv into
`.venv-cmake-format` when it is not on `PATH` (pins in
`linux/scripts/cmake-format.requirements.txt` — `pyyaml` is in there because
`cmake-format==0.6.13` does not depend on it and dies with
`ModuleNotFoundError` the moment it reads a YAML config),
`code_quality_find_cmake_files` walks the tree, and
`code_quality_run_cmake_format --check` is the verdict. In scope is every
repo-owned `CMakeLists.txt`/`*.cmake`; excluded are `third_party/`,
`external/`, venvs, `out/` — and `windows/scripts/patches/`, whose shim bytes
are Windows layer-cache keys a reformat would invalidate. A walk that returns
zero files is a refusal, not a green: an exclude glob that eats the corpus
must not pass vacuously.

`--check` is newline-strict, and with `line_ending: unix` that is the right
strictness for this tree: `*.cmake` is `-text` with LF in the index, so the
ten `cmake/` files that carried CRLF working trees were autocrlf leftovers
from before the 2026-08-14 attributes rules, and normalising them left
`git diff` EMPTY. Re-CRLFing them instead would have kept the gate
permanently red.

### The two that stay frozen, with better reasons

Both of them took their route out on 2026-09-05, and `gate-proofs.allow`'s bare-slug
namespace is empty for the first time: **34 slugs, 34 proven, 0 frozen** (36 of 36
since `shared-config` and `cmake-format` arrived proven on 2026-09-06). The
heading keeps its name because several files point at this anchor, and because the
two stories are the reason the freeze list was worth keeping honest rather than
deleting.

**`critical-fixes` took the recommended route: the split.** It was two scripts in
one trench coat — half greps over the repo tree, half probes of
`/opt/python-cross`, `/opt/litert` and friends that exist only inside a built
image. Proving the tree half alone would have credited the slug for a suite that
never touches the checks whose findings gate a rebuild, so the script was cut in
two instead: `verify-critical-fixes.sh` keeps fix5–fix10 and stays the slug,
`06-packaging/smoke-critical-fixes.sh` takes fix1–fix4 and is run against a
shipped image by hand. `test-critical-fixes.sh` then proves BOTH halves — the
host gate in a fixture tree, the image probes under `CF_SMOKE_ROOT`.

The split was decided by MEASURING first, not by reasoning about testability, and
the measurement is why it is right. Run in the shipped images for the first time,
the four moved probes reported four failures and **all four were the probe being
stale**, while the host half's verdict lost exactly two assertions — fix4's
amd64-cc-on-an-amd64-host tautology. A frozen slug had been carrying checks that
could not have gone green in the one place they were meant to run. The numbers,
and the real 707-header defect a corrected fix2 then found on all three shipped
arches, are in
[`cross-build-verification.md`](cross-build-verification.md#the-in-image-half-of-critical-fixes).
**The generalisable part: before writing the suite a frozen slug is asking for,
run the gate where it is supposed to run.** Two of these probes had never
executed anywhere, and no suite written against them would have said so.

**`version-snapshot` got the one-fixture-per-sub-check suite its reason demanded.**
`sync_versions.py --check` is a fan-out: `result |=` over seven sub-checks plus a
subprocess into `generate-website-licenses.py`, whose targets span `README.md`
markers, the deps table, doc literals, Dockerfile ARG defaults and
`windows/scripts/build-*-from-source.ps1`. Because the verdict is an OR, a suite
that reddens ONE sub-check would un-freeze the slug while six stayed unproven —
the hollow-proof shape this list exists to prevent. `test-version-snapshot.sh`
reddens six of the seven independently, plus the subprocess, and pins the seventh.

**The fixture is a SYMLINK FARM, and that is what made the wave affordable.**
`collect_versions()` — which `render_snapshot()` calls, so every `--check` run
depends on it — hard-reads five fixed files (`linux/webserver/Dockerfile` and four
under `windows/`) and raises an uncaught `FileNotFoundError` on a missing one,
plus it `KeyError`s on any of eight `versions.env` keys. A hand-built minimal tree
therefore cannot reach a verdict at all, and a full copy is 8 GB. So the fixture
mirrors the repo as symlinks one directory at a time, materialising only the file
under test as a real copy. `sync_versions.py` itself must always be a real copy:
it derives `REPO_ROOT` from `Path(__file__).resolve()`, and `resolve()` would
follow a symlink straight back to the real tree. The suite's own first case is the
green baseline printing all seven verdict lines — without it none of the reds
would mean anything — and its last case proves the perturbations are DISJOINT,
which under an OR is the difference between proving a sub-check and hiding one.

**Writing that suite found a sub-check that has never checked anything.**
`script_default_target_files()` globs `windows/scripts/build-*-from-source.ps1`.
Those ten scripts live one directory deeper, in `windows/scripts/build/`, so the
glob returns an EMPTY list and `check_script_defaults` prints
`Windows build-script -DefaultValue pins match versions.env.` having scanned zero
files. No fixture can redden it, so the suite pins the emptiness as a KNOWN GAP —
two `find` counts, 0 here and 10 there — which goes red the day the glob is fixed.
It was NOT fixed here on purpose: widening it makes ten PowerShell scripts gate
subjects for the first time, and any fallout is Windows-lane work that this repo's
standing directive keeps out of a Linux wave. It is the owner's call.

**A hollow mention nearly happened while writing this.** `test-arg-consistency.sh`
asserted on the gate's own fix hint, which spells `sync_versions.py` — and the
registry credits a suite that MENTIONS a gate's script. `version-snapshot` flipped
to `proven` on a suite that asserts nothing about it. The assertion now stops
short of the basename, with a comment saying why.
