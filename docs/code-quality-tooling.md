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

The configs these tools read (`.clang-format`, `.clang-tidy`, `gcovr.cfg`) are
owned by this repo too — see [`shared/config/README.md`](../shared/config/README.md)
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
| 3 | `--header-filter` | not passed, so clang-tidy's default applies (headers matching the main file's stem) | `--header-filter=<escaped Src dir>.*`, to suppress ExternalLib noise |
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

**A bite is only evidence if the suite was green first.** Until 2026-09-03 a
mutation counted as biting whenever its test came back non-zero — including when
that test was *already* red, from unrelated drift in a tree several agents were
editing. Every entry under a broken suite then read `bites` and the gate passed,
which is the same false green it exists to find. Each DISTINCT test command is
now run once unmutated per invocation (cached by command string) before any entry
using it is applied; if that baseline fails, the entry is reported as
`FAIL: <id> -- baseline test already fails unmutated (vacuous bite)`, the gate
exits 1, and the file is never mutated. The cost is one extra suite run per
distinct command — 29 of them across 180 entries — inside a full run of about
six minutes (5m58s, measured twice), and it is paid once per command, not once
per entry.

**The gate never edits the tree it is given.** Until 2026-09-03 `apply_and_run()`
wrote the mutated text straight into `--root` (default: this repo) and restored it
in a `finally`. Preflight and the pre-commit hook both run it that way, and this
repo builds *from its own working directory* — buildkit is handed `--local
context=.`. Of the 180 entries, 11 target scripts that are `COPY`'d into an
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
still asks git about the REAL repo. Measured cost: 0.58s for 6.4k files / 131MB,
paid once per invocation whether it runs one entry or all 139 — a full run stays
at 4m2xs (+0.2%). Selection happens first, so a `--changed` hook run that selects
nothing (the common commit) copies nothing at all.

| flag | use |
| --- | --- |
| *(none)* | every entry — CI, or before a release |
| `--changed` | only entries whose target is committed since `origin/main`, staged, or edited. CI's incremental mode; the commit hook no longer uses it (see the cost budget below — those are push semantics, and a hook re-paid them once per commit). Until 2026-09-03 this took the FIRST non-empty of those three, so a staged file was never selected while unpushed commits existed: the hook let a stale mutation through and the next, unrelated commit tripped on it |
| `--only <id>` | one entry, while writing it |
| `--root <dir>` | which tree to copy and check. It is copied too — pointing the gate at a mirror is a second belt, not the isolation mechanism |
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

**Cost.** Even staged-only, the mass is lopsided: 180 entries over 29 distinct
test commands, and one file (`verify_code_complexity.py`) owns 41 of them. Each
entry costs one full run of its suite — 0.5 s for a cheap one, 3.2 s for
`test-code-complexity.sh` — so touching one gate script can be a minute on its
own. No selection rule makes that both complete and fast. So the hook **samples**,
and says so:

- at most `PRECOMMIT_MUTATION_CAP` entries (default **6**; `0` = uncapped),
- **newest first** — `mutations.json` is appended to, so the newest entries are
  the ones written in the commit being made, which are exactly the ones most
  likely never to have bitten,
- and when it cut, it prints `SAMPLED <n> of <m> entries … NOT full coverage`.
  A green hook must never imply coverage it did not pay for; that rule has cost
  this repo enough already (`## Proving a gate can go red`). `make preflight`
  and CI still run all 180.

Measured after, on this tree, 2026-09-04 — end-to-end runs of the whole hook, its
`git diff --cached` fed the two file lists by a shim, with the parts timed
separately:

| step | one-file commit (`01-core/cross-stage-build.sh`) | the 43-file commit `9a5bf8dd` |
| --- | --- | --- |
| 17 fast whole-tree slugs | 4.2 s | 4.2 s |
| `shellcheck -S error` + warning ratchet, staged only | 0.2 s (1 file) | 2.5 s (18 files) |
| mutation step | 2.5 s — all 5 matched entries, no sampling | 19.2 s — 6 of 132, sampled |
| **hook, end to end** | **8.0 s** | **27.2 s** (was 5m26s) |

The 43-file column is the worst case by construction: the six newest entries for
that commit all belong to `test-code-complexity.sh`, the slowest suite in the
manifest. A commit that touches no mutation target skips the step entirely.

`--print-mutation-plan <cap> <manifest> <file-of-staged-paths>` prints
`plan <run> <matched>` and the ids, without running anything; it exists before the
hook's `git rev-parse`, so `tests/test-precommit-hook.sh` can drive the selection
off-target and inside the mutation gate's own throwaway copy. git never passes
arguments to a `pre-commit` hook, so it cannot fire by accident.


Adding a fix without a mutation entry is allowed; adding a *gate* without one is
how the next inert check gets in. The gate guards itself: thirteen entries neuter
its survivor-reporting, its file restore, its baseline pass, its use of the copy,
the opt-in-ness of `--in-place`, the cleanup of the copy, both production call
sites, the exclude list, the single-match rule and `copy2`. The isolation proof is
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
of them arrived (0.57s / 6302 files / 127MB measured, against a whole-checkout clone
per invocation). `copy2`, not `copyfile`, carries the mode across, so a mutated `.sh`
is still executable in the copy: the suite chmods its subject and has the test command
require `-x`. Losing that would turn every shell test red for the wrong reason — a
vacuous-bite storm, not a verdict. And a `find` string matching MORE than once is now
an error (`ambiguous, name one edit`) instead of a silent first-occurrence edit that
neuters one of several copies, leaves the guarantee half-standing, and reports a false
`SURVIVED`; zero matches was already `stale`. All 180 entries matched exactly once when
the rule landed.

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
- **The convention is enforced in both directions.** An entry whose target is a
  registered gate's file is credited to nobody, and therefore fails the gate,
  when its prefix names no slug **or** when it names a real slug that does not own
  that target — a typo'd prefix would otherwise stop proving anything in silence,
  which is the exact failure this whole gate exists to catch. The message names
  the prefix, the target and the slug that does own it. The escape is the same:
  freeze the id under the `mutation-id:` namespace in `gate-proofs.allow`, which
  ratchets down like the slug list.
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

Today's two frozen ids are the shape the file-ownership model cannot express:
`mutations.preflight-callsite-isolated` and `mutations.preflight-runs-the-gate`
pin `preflight.sh`, whose sole registered owner is `crlf-guard` — but what they
prove is how the ORCHESTRATOR invokes the `mutations` gate, and `test-mutation-gate.sh`
is what catches them. Renaming them `crlf-guard.<kebab>` would put a false credit
in a generated table, so they are frozen instead. The fix is an ownership rule for
call sites in `preflight.sh`, not a rename; see `docs/refactoring-backlog.md`.

The cheapest proof per frozen slug, by shape:

- **Tree-consistency checkers** (`stdout-returns`, `copy-coverage`,
  `critical-fixes`, `patch-integrity`, `arg-consistency`, `mirror-consistency`,
  `runtime-paths`, `android-parity`, `pkg-names`, `version-snapshot`): a fixture
  tree with one planted offender and one clean twin, asserting the exit code *and*
  the message — most vacuous tests assert only the message.
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
consumes. Feeding it `git ls-files -z` classifies all 1071 tracked paths in ~68 ms,
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
from `preflight.sh` survived all 68 suites. It now *derives* the options from
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

Pinned by 61 assertions in `tests/test-gate-registry.sh` over a twelve-slug fixture
(one per shape: file gate proven by a suite, by its own mutation, by an inherited
mutation credited by id prefix, the same import under another gate's prefix,
unproven, `[ -f ]` fallback pair, inline in `preflight.sh`, inline in a sourced
lib, inline with a same-named stub in a lib nobody sources, run whole-tree by a
staged-docs block, scoped by `--changed` rather than the guard variable,
by-construction) plus the `mutation-id:` ratchet in both directions and both
convention breaches it catches, 25 in `tests/test-crlf-guard.sh`, and 20 mutation
entries.

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

Before tokenizing, a body is reduced to code text. Heredoc bodies are dropped in
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

- **Function extents come from `verify_code_size.shell_functions`**, which counts
  raw `{` and `}` per line with no awareness of comments or strings. A comment
  holding an unbalanced brace ends the function early: `generate_pkgconfig_file` in
  `01-core/common.sh` measures **5 lines**, because the comment four lines in
  mentions `${libdir}` and a stray `` `}` ``. A nested `name() { … }` is swallowed
  by its parent instead of being measured separately. Both are shared with
  `code-size`, and the fix belongs there.
- `(( … ))` is recognised only after a delimiter, and `&&` / `||` *inside*
  arithmetic still count as paths — in bash they do short-circuit, so that is
  arguably right rather than a bug.
- An unterminated quote, or a heredoc whose terminator never appears, poisons the
  rest of that one function. This is a heuristic tokenizer, not bash's parser;
  where it is wrong the number is frozen with a reason and stays honest in both
  directions, which is the point of the contract.

### Tests

`linux/scripts/tests/test-code-complexity.sh` — 88 assertions. Each case installs
the gate with its two imports into a throwaway tree and reads the number back
**through the real CLI** with `COMPLEXITY_LIMIT=0 NESTING_LIMIT=-1`, so nothing
asserts on the parser's internals. Its last case runs the gate on the real tree,
and that case is what caught the gate tripping its own limit: `_code_char` reached
cc 20 while gaining the arithmetic handling and had to be split into
`_open_group` / `_close_group` / `_code_char`.

47 mutation entries carry it: the four contract directions (in `quality_allow.py`),
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
last line, both of which an earlier brace walker missed. 1811 functions today, 39
named nowhere else, all 39 frozen in `linux/scripts/dead-functions.allow`. The
whole pass costs 0.2s, which is why it is in the pre-commit tier.

**What counts as a use.** The corpus is every text file under `linux/`, `.github/`
and `docs/scripts/`, plus the `Makefile`. A Dockerfile `RUN bash -c "… && fn"` is
a use — that is how stages call helpers. Before matching, each file has its
comments *and its definition heads* stripped, so neither a mention in a comment
nor a second copy of the same function keeps the first one alive. Matching is on
word boundaries: `used_fn_extra` is not a use of `used_fn`, `run-used_fn` is.

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
- a **DEAD** group (three `cpython_ext_*`, `verify_shared_lib_optional`) that a
  whole-repo grep confirms nothing calls. They stay frozen only because their
  files sit inside the 2026-09-03 build closure; delete them after that build.

### The limitation: same-name masking

The gate keeps **one name table for the whole corpus**. That is what makes it cost
0.2s, and it is also its hole: a function is "used" as soon as *any* file names it,
so a dead `log()` in one script is kept alive by a live `log()` in another. Every
short helper name — `log`, `warn`, `pass`, `bad`, `err`, `cleanup` — is effectively
unguarded, and the gate's clean run is not evidence about them.

Four real dead functions were invisible to it on the day it was written. Three are
now deleted: `ghcr-delete-tags.sh log()` (its sourced `ghcr-common.sh` never called
it), and `verify-manifest-freshness.sh pass()`/`bad()` together with the `ok`/`fail`
counters they incremented — that script's Python heredoc prints its own `OK`/`FAIL`
lines. The fourth, `cleanup()` in
`linux/scripts/03-media/build/ffmpeg/build-ffmpeg.sh`, is inside the running build
closure and is deliberately left for deletion after that build finishes.

### `--census`: the per-file pass, and why it is advisory

`python3 linux/scripts/verify_dead_functions.py --census` runs the pass masking
defeats: a definition whose **own file** never names it again. It cannot be a gate
on this tree, and the numbers say why. 428 definitions qualify, and nearly all are
alive: library helpers called by whoever sources the file, stubs a suite defines
for the code under test, `"check_${name}"` dispatch. Filter to files that are
self-contained — they source nothing, and no other corpus file names them by
basename — and **0** rows remain. A gate on the unfiltered set would be a
false-positive machine; a gate on the filtered set would be inert. So `--census`
prints both counts, lists only the self-contained rows, and always exits 0.

Reading it: a listed row is a strong deletion candidate; the "never names again"
count is context, not a queue. The sourcing guard is not decoration — a library a
file sources can call back into that file's own functions, which is precisely the
`command_not_found_handle` and `check_${name}` shape.

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

`linux/scripts/tests/test-dead-functions.sh`: 55 assertions over throwaway trees —
each case copies the gate plus the two modules it imports and plants a subject,
callers and an allow file. 22 mutations, every one proven to bite, covering the
corpus boundaries one at a time (Dockerfiles in; `.allow`, `.patch`, `.diff`,
`patches/`, `linux/webserver/dist`, `.pytest_cache`, `.dart_tool` and
`mutations.json` out; `dist` narrow), both `re.MULTILINE` flags (without them only
a comment or a definition head at byte 0 is stripped — every fixture used to sit at
byte 0, so the flags were previously proven only by the real tree), the `(?<=\s)`
lookbehind that keeps a tab-indented comment a comment, `linux/host-config` being a
subject and not merely a caller, the two-way freeze contract, and the three
`--census` rules.

## Shellcheck warning ratchet (`shellcheck-warnings`)

`linux/scripts/verify_shellcheck_warnings.py`, preflight slug
`shellcheck-warnings`, baseline `linux/scripts/shellcheck-warnings.allow`, suite
`linux/scripts/tests/test-shellcheck-warnings.sh`.

One `shellcheck -x -f json1 -S warning` run over exactly the file set
`lint-shell.sh --list-files` prints, counted per `(file, SCxxxx)` and checked
against the frozen rows with the shared four-way rule. Today: **307 files in
scope, 177 warning-level findings in 74 files, 95 frozen rows** — SC2034 (85),
SC2155 (19), SC2154 (16), SC2178 (12), SC2046 (11), SC1090 (9).

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
The `Install shellcheck` step in `.github/workflows/ubuntu24.04.yml` is therefore
removed: the gate brings its own, verified.

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

**Coverage.** 62 assertions over throwaway trees whose subjects provoke SC2034,
SC2155 and a source-directive pair, plus stub binaries for the paths a real
shellcheck cannot produce; 18 mutations, every one proven to bite. The suite's
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
a `versions.env` key, a Dockerfile `ARG`/`ENV`, an assignment or
`: "${VAR:=…}"` anywhere in the scripts, or a row in the allow file. Both the
consumed scan and the two script-side owner scans go through one `_scan`
helper, so *reader* and *owner* are decided by exactly the same line filter.

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
  missed. Measured over all 1459 non-comment `${VAR:-}` lines in the tree: the
  strip removes zero knob occurrences today. The failure mode is loud — a live
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
fifteen were re-homed as documented rows in `lint-env-knobs.allow`:
`IREE_CROSS_BUILD_COMPILER`, `LINT_DOCKERFILES_BUILD_CHECK`,
`LLVM_INSTALL_PROFILE`, `MEDIA_SKIP_CSOUND`, `MEDIA_STRIP`,
`NODE_RISCV64_MAJOR_REQUIRED`, `OPENCV_GSTREAMER_PASS`, `PREFLIGHT_ONLY`,
`PREFLIGHT_SKIP`, `PYTHON_LTO`, `RUNTIME_CLANG_VERSION_SMOKE`,
`RUNTIME_COMPILER_SMOKE`, `RUNTIME_IMAGE_SMOKE`, `SKIP_REAL_TREE`,
`STV_COMPUTE`. `SKIP_REAL_TREE` is the one that shows the shape of the hazard:
it was introduced by the same batch that added the consumed-side filter, and its
only owner in the whole tree was the sentence in `test-shellcheck-warnings.sh`
explaining it.

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
`verify_code_complexity.py` (`shell_code` + `_Walker`), and it is deliberately
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

Census at the time of writing: `consumed ${VAR:-} knobs: 643 | owners:
versions.env=174 dockerfiles=116 scripts=912 allowlist=225 | stale allow rows: 0`.

### Proof

`linux/scripts/tests/test-code-dupes.sh` (34 assertions) and
`linux/scripts/tests/test-env-knobs.sh` (67 assertions) each copy their gate into
a throwaway tree — the gates derive their root from their own path — and parse
the measured overlap rather than hardcoding it, so the fixtures cannot rot.
Nineteen entries in `docs/scripts/mutations.json` neuter one guarantee each and
are proven to make those suites fail: the shrink and stale detections and their
exit codes, the pre-threshold count, the stale wording, the duplicate-row exit,
the `--kind` scoping, the bookkeeping ordering, `--baseline`'s reason carry-over,
the two comment filters, the `KNOB_GATE`-independence of stale, the withheld
all-clear line, the trailing strip's cut point, the escaped-`\$` deletion, and the
extraction regex that bars `_`-prefixed privates. Nine more neuter one piece each
of the owner tokenizer — quoted text, command position, comments, heredoc bodies,
`$( )` re-entry, the keyword prefixes, the env-prefix chain, the case arm, and
the `${VAR=x}` guard.
