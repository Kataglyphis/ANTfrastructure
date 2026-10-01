#!/usr/bin/env bash
# renovate-fixtures.sh -- the sourced world the renovate suites run in; not named test-*.sh, so run-tests.sh skips it.
[ -n "${_RENOVATE_FIXTURES_SH_LOADED:-}" ] && return 0
_RENOVATE_FIXTURES_SH_LOADED=1

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPT="${TESTS_DIR}/../renovate-local.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Host tools minus every lock tool, so "cargo is not installed" is a fixture property, not a hope.
BARE_PATH="${WORK}/bare-path"
mkdir -p "${BARE_PATH}"
for _bin in bash env sh git sed grep awk mktemp dirname basename rm mkdir tr cut \
            cat wc sort head tail uname ls cp mv chmod sleep find; do
  _src="$(command -v "${_bin}" 2>/dev/null || true)"
  if [ -n "${_src}" ]; then ln -sf "${_src}" "${BARE_PATH}/${_bin}"; fi
done
PY_ABS="$(command -v python3 || command -v python)"

# Stub lock tools record argv and cwd: they prove what would run without running it.
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"
ARGV_LOG="${WORK}/lock-argv.txt"
for _tool in cargo dart flutter npm yarn pnpm uv poetry pdm; do
  printf '#!/usr/bin/env bash\nprintf "%%s | %%s | %%s\\n" "$(basename "$0")" "$*" "${PWD##*/}" >> "%s"\n' \
    "${ARGV_LOG}" > "${STUBS}/${_tool}"
  chmod +x "${STUBS}/${_tool}"
done

# Fixtures: Renovate's own managerFilePatterns, so detection reads real patterns, not a test table.
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

# _pkg_json <file> <dep> <cur> <new> [occurrences] -> one packageFile entry, one deps entry per occurrence, as Renovate reports.
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

# _report_pair <out> <manager> <dep> <cur> <new> <file> <file>: one update in two files, so the plan must be one unit.
_report_pair() {
  printf '{"repositories":{"local":{"packageFiles":{"%s":[%s,%s]}}}}\n' \
    "$2" "$(_pkg_json "$6" "$3" "$4" "$5")" "$(_pkg_json "$7" "$3" "$4" "$5")" > "$1"
}

# _report_mixed <out> <mgrA> <fileA> <depA> <curA> <newA> <mgrB> <fileB> <depB> <curB> <newB>: two managers in one plan.
_report_mixed() {
  printf '{"repositories":{"local":{"packageFiles":{"%s":[%s],"%s":[%s]}}}}\n' \
    "$2" "$(_pkg_json "$3" "$4" "$5" "$6")" \
    "$7" "$(_pkg_json "$8" "$9" "${10}" "${11}")" > "$1"
}

# _repo <name> -> a throwaway checkout; the caller plants files, then _commit.
_repo() {
  local d="${WORK}/$1"
  mkdir -p "${d}/.github/workflows"
  git -C "${d}" init -q
  printf '%s' "${d}"
}

_commit() { t_git_commit "$1"; }

# The Cargo.toml + Cargo.lock pair shared by the missing-tool and --dry-run cases.
_cargo_repo() {
  local d
  d="$(_repo "$1")"
  printf '[package]\nname = "fixture"\n\n[dependencies]\nserde = "=1.0.100"\n' > "${d}/Cargo.toml"
  printf '# placeholder\n' > "${d}/Cargo.lock"
  _commit "${d}"
  printf '%s' "${d}"
}

# protocol.file.allow on every checkout: `submodule update --remote` fetches under the submodule's own config.
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

# _vendor_sub <super> <name> <f.txt content> -> the upstream, vendored into <super> as `sub`; the caller commits.
_vendor_sub() {
  local up
  up="$(_init_repo "${WORK}/upstream-$2")"
  _plant_file "${up}" f.txt "$3"
  git -C "$1" config protocol.file.allow always
  _add_sub "$1" "${up}" sub
  printf '%s' "${up}"
}

# A behind, branch-declaring submodule beside a manifest: both --apply halves in one plan.
_sub_repo() {
  local up d
  d="$(_init_repo "${WORK}/$1")"
  up="$(_vendor_sub "${d}" "$1" 'one\n')"
  _plant_file "${d}" pubspec.yaml 'name: fixture\ndependencies:\n  http: 1.1.0\n'
  _plant_file "${up}" f.txt 'two\n'
  printf '%s' "${d}"
}

# The same, one level deeper (sub/deep), the family's real shape, for nested-submodule dirtiness.
_deep_repo() {
  local up dp d
  dp="$(_init_repo "${WORK}/deepstream-$1")"
  _plant_file "${dp}" d.txt 'deep one\n'
  up="$(_init_repo "${WORK}/upstream-$1")"
  _add_sub "${up}" "${dp}" deep
  _plant_file "${up}" f.txt 'one\n'
  d="$(_init_repo "${WORK}/$1")"
  _add_sub "${d}" "${up}" sub
  # `submodule add` clones one level; an empty sub/deep stays clean whatever happens to it.
  git -C "${d}/sub" -c protocol.file.allow=always submodule update -q --init deep >/dev/null 2>&1
  git -C "${d}/sub/deep" config protocol.file.allow always
  _commit "${d}"
  _plant_file "${up}" f.txt 'two\n'
  printf '%s' "${d}"
}

# Commit and attached ref: `--remote` detaches HEAD, so shas alone would miss a lost branch.
_sub_at() {
  printf '%s %s' "$(git -C "$1/sub" rev-parse HEAD)" \
    "$(git -C "$1/sub" symbolic-ref --quiet HEAD || printf 'DETACHED')"
}

# _plant <name> <relative file> <printf -b content> -> a committed checkout carrying exactly that file.
_plant() {
  local d
  d="$(_repo "$1")"
  printf '%b' "$3" > "${d}/$2"
  _commit "${d}"
  printf '%s' "${d}"
}

# _plant_all <name> <rel> <content> [<rel> <content>]... -> the same, with several files in one commit.
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

# OUT and RC come from one plain assignment: `rc=$?` after a pipe reports the wrong process.

# Knobs, set as `NAME=value _run` so they reset: STUB_PATH, RUN_CONFIG, RUN_PYTHONPATH, RUN_TMPDIR.
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

# A prefix assignment on a function call reaches every frame below and ends with the call.
_run_stubbed() { STUB_PATH="${STUBS}:${BARE_PATH}" _run "$@"; }

# _apply_plan <root> <plan.json>: the apply half over a hand-written plan, the honest way to make the locator wrong.
# shellcheck disable=SC2034  # OUT and RC are read by the suites that source this
_apply_plan() {
  OUT="$(cd "${TESTS_DIR}/.." && "${PY_ABS}" renovate_planner.py edit "$1" "$2" 2>&1)"
  RC=$?
  return 0
}

_line() { sed -n "$2p" "$1"; }

# One reader per manifest kind: <repo> <line> -> that line.
_step() { _line "$1/.github/workflows/ci.yml" "$2"; }
_pub() { _line "$1/pubspec.yaml" "$2"; }
_req() { _line "$1/requirements.txt" "$2"; }
_cargo_line() { _line "$1/Cargo.toml" "$2"; }


# The reports both suites reuse.
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

# One packageRule sending pub to a human: exit 2 without an unwritable file or a broken locator.
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
