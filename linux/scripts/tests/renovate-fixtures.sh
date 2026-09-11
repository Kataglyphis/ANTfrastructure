#!/usr/bin/env bash
# renovate-fixtures.sh -- the throwaway world the renovate suites run in. Not a
# suite: run-tests.sh globs test-*.sh, so this name keeps it out of the sweep,
# and test-harness.sh beside it is the precedent for a sourced file here.
#
# One owner for what every case needs: a committed checkout, a PATH owning no
# lock tool unless a case adds one, Renovate's OWN managerFilePatterns, the
# report shapes measured on 44.71.0, the runner that reads rc correctly, and one
# reader per manifest kind. Split out of test-renovate-local.sh on 2026-09-10,
# when the read-back wave took that file past the 800-line limit.
[ -n "${_RENOVATE_FIXTURES_SH_LOADED:-}" ] && return 0
_RENOVATE_FIXTURES_SH_LOADED=1

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="${TESTS_DIR}/../renovate-local.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A PATH holding exactly what the script needs and NOTHING a lockfile is owned
# by. Built by symlink from whatever this host actually has, so "cargo is not
# installed" is a property of the fixture rather than a hope about the runner.
BARE_PATH="${WORK}/bare-path"
mkdir -p "${BARE_PATH}"
for _bin in bash env sh git sed grep awk mktemp dirname basename rm mkdir tr cut \
            cat wc sort head tail uname ls cp mv chmod sleep find; do
  _src="$(command -v "${_bin}" 2>/dev/null || true)"
  if [ -n "${_src}" ]; then ln -sf "${_src}" "${BARE_PATH}/${_bin}"; fi
done
PY_ABS="$(command -v python3 || command -v python)"

# Stub lock tools that record their argv and working directory instead of
# resolving anything. They prove WHAT would be run; they do not run it.
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
ARGV_LOG="${WORK}/lock-argv.txt"
for _tool in cargo dart flutter npm yarn pnpm uv poetry pdm; do
  printf '#!/usr/bin/env bash\nprintf "%%s | %%s | %%s\\n" "$(basename "$0")" "$*" "${PWD##*/}" >> "%s"\n' \
    "${ARGV_LOG}" > "${STUBS}/${_tool}"
  chmod +x "${STUBS}/${_tool}"
done

# Fixtures
# Renovate's OWN managerFilePatterns (44.71.0). Every case injects this, so the
# script's detection reads real patterns rather than a per-test table.
CONFIG="${WORK}/config.json"
cat > "${CONFIG}" <<'JSON'
{
 "cargo":{"managerFilePatterns":["/(^|/)Cargo\\.toml$/"]},
 "pub":{"managerFilePatterns":["/(^|/)pubspec\\.ya?ml$/"]},
 "npm":{"managerFilePatterns":["/(^|/)package\\.json$/"]},
 "pep621":{"managerFilePatterns":["/(^|/)pyproject\\.toml$/"]},
 "dockerfile":{"managerFilePatterns":["/(^|/|\\.)([Dd]ocker|[Cc]ontainer)file$/"]},
 "github-actions":{"managerFilePatterns":
   ["/(^|/)(workflow-templates|\\.(?:github|gitea|forgejo)/(?:workflows|actions))/.+\\.ya?ml$/"]},
 "pip_requirements":{"managerFilePatterns":
   ["/(^|/)[\\w-]*requirements([-._]\\w+)?\\.(txt|pip)$/"]},
 "pre-commit":{"enabled":false,
   "managerFilePatterns":["/(^|/)\\.pre-commit-config\\.ya?ml$/"]},
 "git-submodules":{"enabled":false,"managerFilePatterns":["/(^|/)\\.gitmodules$/"]},
 "packageRules":[]
}
JSON

# _pkg_json <file> <dep> <cur> <new> [occurrences] -> one "packageFile" entry.
# The report shape MEASURED on renovate 44.71.0: one `deps` entry per OCCURRENCE
# of the pin, which is what lets the planner count them. The ONE place this
# suite spells that JSON -- writing it out again per report shape is both a copy
# and a second thing to keep in step with Renovate.
_pkg_json() {
  local file="$1" dep="$2" cur="$3" new="$4" n="${5:-1}" i sep=""
  printf '{"packageFile":"%s","deps":[' "${file}"
  for ((i = 0; i < n; i++)); do
    printf '%s{"depName":"%s","currentValue":"%s","updates":[{"newValue":"%s"}]}' \
      "${sep}" "${dep}" "${cur}" "${new}"
    sep=,
  done
  printf ']}'
}

# _report <out> <manager> <file> <dep> <cur> <new> [occurrences]
_report() {
  printf '{"repositories":{"local":{"packageFiles":{"%s":[%s]}}}}\n' \
    "$2" "$(_pkg_json "$3" "$4" "$5" "$6" "${7:-1}")" > "$1"
}

# _report_pair <out> <manager> <dep> <cur> <new> <file> <file>
# The SAME update in TWO package files -- the shape that asks whether a plan
# spanning several files is one unit or a walk that can stop half way.
_report_pair() {
  printf '{"repositories":{"local":{"packageFiles":{"%s":[%s,%s]}}}}\n' \
    "$2" "$(_pkg_json "$6" "$3" "$4" "$5")" "$(_pkg_json "$7" "$3" "$4" "$5")" > "$1"
}

# _report_mixed <out> <mgrA> <fileA> <depA> <curA> <newA> <mgrB> <fileB> <depB> <curB> <newB>
# One report carrying TWO managers -- a gitlink and a manifest in one plan.
_report_mixed() {
  printf '{"repositories":{"local":{"packageFiles":{"%s":[%s],"%s":[%s]}}}}\n' \
    "$2" "$(_pkg_json "$3" "$4" "$5" "$6")" \
    "$7" "$(_pkg_json "$8" "$9" "${10}" "${11}")" > "$1"
}

# _repo <name> -> a throwaway checkout, committed. Files are planted by the
# caller before _commit.
_repo() {
  local d="${WORK}/$1"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q
  printf '%s' "${d}"
}

_commit() { t_git_commit "$1"; }

# The Cargo.toml + Cargo.lock pair the two lockfile cases share: one refuses
# for a missing tool, one proves --dry-run runs none.
_cargo_repo() {
  local d
  d="$(_repo "$1")"
  printf '[package]\nname = "fixture"\n\n[dependencies]\nserde = "=1.0.100"\n' > "${d}/Cargo.toml"
  printf '# placeholder\n' > "${d}/Cargo.lock"
  _commit "${d}"
  printf '%s' "${d}"
}

# The three moves every submodule fixture is built out of, as functions because
# four fixtures across three suites were the same six lines with different names
# in them and the duplication gate caught the fourth.
#   _init_repo  <dir>                  a checkout on `main` taking file:// subs
#   _plant_file <dir> <rel> <content>  one file, printf -b, and a commit
#   _add_sub    <super> <src> <path>   vendor <src>, tracking `main`
# protocol.file.allow goes on EVERY checkout these build: the fetch that
# `submodule update --remote` runs happens INSIDE the submodule and reads the
# submodule's own config, so a fixture missing it can never move a gitlink and
# every case over it passes vacuously.
_init_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config protocol.file.allow always
  printf '%s' "$1"
}

_plant_file() {
  printf '%b' "$3" > "$1/$2"
  _commit "$1"
}

_add_sub() {
  git -C "$1" -c protocol.file.allow=always submodule add -q -b main "$2" "$3" >/dev/null 2>&1
  git -C "$1/$3" config protocol.file.allow always
}

# _vendor_sub <super> <name> <f.txt content> -> the UPSTREAM checkout, printed.
# An upstream repo carrying one tracked file, vendored into <super> as `sub`.
# The fixtures that need a submodule differ only in what the SUPERPROJECT is --
# a bare checkout plus a manifest for the gitlink cases, a whole collateral
# fixture for (K14) in test-renovate-collateral.sh -- so the upstream half has
# one owner here rather than a copy per suite. The caller commits <super>: this
# leaves the `submodule add` staged, and what happens next differs per fixture.
_vendor_sub() {
  local up
  up="$(_init_repo "${WORK}/upstream-$2")"
  _plant_file "${up}" f.txt "$3"
  git -C "$1" config protocol.file.allow always
  _add_sub "$1" "${up}" sub
  printf '%s' "${up}"
}

# A superproject whose one submodule declares a branch and is BEHIND it, beside
# a manifest: the plan that moves a gitlink AND writes a manifest, which is the
# only shape that can ask whether the two halves are one unit. Both suites drive
# it -- test-renovate-local.sh for what gets written, test-renovate-exit.sh for
# what gets put back when the second half fails or is stopped.
_sub_repo() {
  local up d
  d="$(_init_repo "${WORK}/$1")"
  up="$(_vendor_sub "${d}" "$1" 'one\n')"
  _plant_file "${d}" pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n'
  _plant_file "${up}" f.txt 'two\n'
  printf '%s' "${d}"
}

# The same superproject, one level DEEPER: `sub` itself carries a submodule
# `deep`. That is the family's real shape -- every consumer has
# third_party/ContainerHub, and every ContainerHub has third_party/DocumANTation
# -- and it is the only shape that can ask what a NESTED submodule's dirtiness
# means for the cleanliness check the parent gets.
_deep_repo() {
  local up dp d
  dp="$(_init_repo "${WORK}/deepstream-$1")"
  _plant_file "${dp}" d.txt 'deep one\n'
  up="$(_init_repo "${WORK}/upstream-$1")"
  _add_sub "${up}" "${dp}" deep
  _plant_file "${up}" f.txt 'one\n'
  d="$(_init_repo "${WORK}/$1")"
  _add_sub "${d}" "${up}" sub
  # `submodule add` clones ONE level; without this `sub/deep` is an empty
  # directory, which is clean whatever anybody does to it -- a fixture that
  # could never reproduce the bug and would pass against the broken code.
  git -C "${d}/sub" -c protocol.file.allow=always submodule update -q --init deep >/dev/null 2>&1
  git -C "${d}/sub/deep" config protocol.file.allow always
  _commit "${d}"
  _plant_file "${up}" f.txt 'two\n'
  printf '%s' "${d}"
}

# WHERE a submodule is checked out, as one string: the commit AND the ref it is
# attached to. `--remote` leaves it detached at the new tip, so a case comparing
# shas alone would call a detached HEAD "put back" -- which is how a rollback
# hands a branch checkout back as a detached one and nobody notices.
_sub_at() {
  printf '%s %s' "$(git -C "$1/sub" rev-parse HEAD)" \
    "$(git -C "$1/sub" symbolic-ref --quiet HEAD || printf 'DETACHED')"
}

# _plant <name> <relative file> <printf -b content> -> a committed checkout
# carrying exactly that file. Eight cases differ only in the manifest and what
# they then assert, and writing the plant-and-commit shape out eight times is
# the copy the duplication gate catches.
_plant() {
  local d
  d="$(_repo "$1")"
  printf '%b' "$3" > "${d}/$2"
  _commit "${d}"
  printf '%s' "${d}"
}

# _plant_all <name> <rel> <content> [<rel> <content>]... -> the same, for a
# fixture that needs SEVERAL files in ONE commit. _plant is the one-file case
# and _plant_file commits per file; a fixture whose point is the shape of a
# whole tree -- a cargo workspace, a manifest under a directory with a space in
# it -- wants them landing together. Writing the mkdir/printf/_commit shape out
# per fixture is the copy the duplication gate catches: it saw _k15_repo against
# _k21_repo in test-renovate-collateral.sh at a 6-line identical run.
_plant_all() {
  local d rel
  d="$(_repo "$1")"
  shift
  while [ "$#" -ge 2 ]; do
    rel="$1"
    mkdir -p "$(dirname "${d}/${rel}")"
    printf '%b' "$2" > "${d}/${rel}"
    shift 2
  done
  _commit "${d}"
  printf '%s' "${d}"
}

# The script under its two injected inputs, on a PATH that owns no lock tool
# unless the caller adds one. OUT/RC are set together, from a plain assignment
# with no pipeline: `rc=$?` after a pipe reports the wrong process.

# Four knobs, each read as `NAME=value _run ...` so it resets itself: STUB_PATH
# adds the stub lock tools, RUN_CONFIG swaps the injected Renovate config,
# RUN_PYTHONPATH goes in front of site-packages, and RUN_TMPDIR gives the run a
# private TMPDIR -- which is how a case READS whether the copies the script
# takes beside a write were deleted, rather than inferring it. Three of the four
# arrived as hand-rolled copies of this invocation inside a case, which is
# exactly what a copy of the runner risks.
OUT=""
RC=0
# shellcheck disable=SC2034  # OUT and RC are read by the suites that source this
_run() {
  local repo="$1" report="$2"
  shift 2
  OUT="$(PATH="${STUB_PATH:-${BARE_PATH}}" PREFLIGHT_PYTHON="${PY_ABS}" \
         PYTHONPATH="${RUN_PYTHONPATH:-}" \
         TMPDIR="${RUN_TMPDIR:-${TMPDIR:-/tmp}}" \
         RENOVATE_LOCAL_REPORT="${report}" \
         RENOVATE_LOCAL_CONFIG="${RUN_CONFIG:-${CONFIG}}" \
         bash "${SCRIPT}" "$@" "${repo}" 2>&1)"
  RC=$?
  return 0
}

# The script with the stub lock tools on PATH. Six cases need exactly that, and
# spelling the set/run/reset triple out each time is the copy the duplication
# gate catches -- it saw the resulting five-line run between two cargo cases.
# The prefix form is what makes the reset unnecessary: measured on bash 5.3.9,
# an assignment in front of a FUNCTION call reaches every frame below it and is
# gone when the call returns, so no case can inherit another's PATH.
_run_stubbed() { STUB_PATH="${STUBS}:${BARE_PATH}" _run "$@"; }

_line() { sed -n "$2p" "$1"; }

# One reader per manifest kind: <repo> <line> -> that line. Cases differ only in
# which line they read back, and spelling the path out in every assertion is the
# copy the duplication gate catches.
_step() { _line "$1/.github/workflows/ci.yml" "$2"; }
_pub() { _line "$1/pubspec.yaml" "$2"; }
_req() { _line "$1/requirements.txt" "$2"; }
_cargo_line() { _line "$1/Cargo.toml" "$2"; }


# The three reports every wave reuses. They are the SAME three pins the lettered
# cases established, hoisted here because both suites read them: a report built
# inside whichever case happened to need it first is not an owner, it is an
# accident of order.
A_REPORT="${WORK}/a.json"
_report "${A_REPORT}" pub pubspec.yaml http 1.1.0 1.6.0
B_REPORT="${WORK}/b.json"
_report "${B_REPORT}" github-actions .github/workflows/ci.yml actions/checkout v4 v5
RUFF_REPORT="${WORK}/ruff.json"
_report "${RUFF_REPORT}" pip_requirements requirements.txt ruff ==0.9.0 ==0.16.6
# The one report that names BOTH halves of an --apply, for _sub_repo above.
SUB_REPORT="${WORK}/sub.json"
_report_mixed "${SUB_REPORT}" \
  git-submodules .gitmodules sub main main \
  pub pubspec.yaml http 1.1.0 1.6.0

# The injected config carrying ONE packageRule: pub updates go to a human. It is
# how a case reaches exit 2 -- the "completed, and something was not applied"
# arm -- without needing an unwritable file or a broken locator. Two suites need
# it, one to prove a single repo exits 2 and one to prove the fleet composes
# those into 2, and it is the same JSON both times.
REFUSE_CONFIG="${WORK}/config-refuse.json"
REFUSE_WHY="pub bumps need a human"
"${PY_ABS}" - "${CONFIG}" "${REFUSE_CONFIG}" "${REFUSE_WHY}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = json.load(fh)
cfg["packageRules"] = [{"description": sys.argv[3],
                        "matchManagers": ["pub"],
                        "dependencyDashboardApproval": True}]
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(cfg, fh)
PY
