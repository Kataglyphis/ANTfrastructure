#!/usr/bin/env bash
# Runs a project's tests on its installed cp3XYt wheel after ci_packaging.sh; the subset and flags: docs/python-ci.md#the-suite-on-the-installed-wheel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ci-common.sh" || { echo "Error: failed to source ci-common.sh" >&2; exit 1; }

PYTHON_VERSION="${PYTHON_VERSION:-${DEFAULT_PYTHON_VERSION:?no pinned Python: keep versions.env beside python_uv.sh, or pass a version}}"
HELPER="$SCRIPT_DIR/free-threaded-wheel-tests.py"
EXTRA=""
ISOLATED=0
SUBSET=0
COPIES=()
TEST_ENV=()
PYTEST_ARGS=()
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --python-version) PYTHON_VERSION="${2:?--python-version needs a value}"; shift 2; continue ;;
      --extra) EXTRA="${2:?--extra needs a value}"; shift 2 ;;
      --copy) COPIES+=("${2:?--copy needs a path}"); shift 2 ;;
      --env)
        [[ "${2:-}" == [A-Za-z_]*=* ]] || err "--env needs NAME=VALUE, not '${2:-}'"
        TEST_ENV+=("$2"); shift 2 ;;
      --isolated) ISOLATED=1; shift ;;
      --) shift; PYTEST_ARGS=("$@"); SUBSET=1; break ;;
      *) err "unknown argument: $1" ;;
    esac
    SUBSET=1
  done
}
parse_args "$@"
[ "${SUBSET}" -eq 0 ] || [ "${#COPIES[@]}" -gt 0 ] || err "no --copy: name the tests to run against the installed wheel"

detect_workspace
prepare_ci_workspace --cd

FT_VERSION="$(printf '%s' "${PYTHON_VERSION%t}" | cut -d. -f1,2)t"
FT_ABI="cp$(printf '%s' "${FT_VERSION%t}" | tr -d .)t"

# The same three cases in which ci_packaging.sh builds no free-threaded wheel.
if [ -n "${PACKAGING_CROSS_TARGET:-}" ]; then
  info "free-threaded wheel tests skipped: the ${PACKAGING_CROSS_TARGET} cross build ships no ${FT_ABI} wheel"
  exit 0
fi
case "${PYTHON_FREE_THREADED_WHEEL:-auto}" in
  off) info "free-threaded wheel tests skipped: PYTHON_FREE_THREADED_WHEEL=off"; exit 0 ;;
  auto)
    if ! verdict="$(python3 -I "$SCRIPT_DIR/free-threaded-wheel.py" declares pyproject.toml 2>&1)"; then
      info "free-threaded wheel tests skipped: ${verdict}"
      exit 0
    fi ;;
esac

# pyproject.toml's table is the one definition every lane reads; flags are for a caller without one.
table_rc=0
table="$(python3 -I "${HELPER}" table --format argv pyproject.toml 2>&1)" || table_rc=$?
case "${SUBSET}:${table_rc}" in
  0:0) mapfile -t table_args <<< "${table}"; parse_args "${table_args[@]}" ;;
  0:1) err "no --copy, and ${table}: name the tests to run against the installed wheel" ;;
  1:0) err "both the flags and pyproject.toml's [tool.antfrastructure.free-threaded-wheel-tests] name the tests: keep one" ;;
  1:1) ;;
  *) err "${table}" ;;
esac
for path in "${COPIES[@]}"; do
  [ -e "${path}" ] || err "--copy ${path}: no such file or directory"
done

shopt -s nullglob
wheels=(dist/*-"${FT_ABI}"-*"$(uname -m)".whl)
built=(dist/*)
[ "${#wheels[@]}" -eq 1 ] || err "expected one ${FT_ABI} $(uname -m) wheel in dist/, found ${#wheels[@]} among: ${built[*]##*/}"

ft_python="$(UV_PYTHON_DOWNLOADS=never uv python find "${FT_VERSION}" 2>/dev/null)" || err "no ${FT_VERSION} interpreter for the wheel tests"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
venv="${work}/venv"
mkdir "${work}/run"

uv venv --python "${ft_python}" "${venv}" || err "cannot create ${venv}"
uv export --locked --no-emit-project ${EXTRA:+--extra "${EXTRA}"} --format requirements.txt -o "${work}/requirements.txt" >/dev/null ||
  err "uv export of the lock${EXTRA:+ with the ${EXTRA} extra} failed"
uv pip install --python "${venv}/bin/python" -r "${work}/requirements.txt" ||
  err "the lock's set${EXTRA:+ with the ${EXTRA} extra} does not install on ${FT_VERSION}"
uv pip install --python "${venv}/bin/python" --no-deps "${wheels[0]}" || err "${wheels[0]} does not install into ${venv}"

# Outside the checkout: the sources would shadow the installed modules.
for path in "${COPIES[@]}"; do
  cp -r --parents "${path}" "${work}/run/"
done
python_flags=()
[ "${ISOLATED}" -eq 0 ] || python_flags=(-I)

info "free-threaded wheel tests: ${wheels[0]##*/} on $("${venv}/bin/python" -VV)"
(cd "${work}/run" && env "${TEST_ENV[@]}" "${venv}/bin/python" "${python_flags[@]}" "${HELPER}" run -- "${PYTEST_ARGS[@]}") ||
  err "the tests failed against ${wheels[0]##*/}, or left the GIL enabled"
info "free-threaded wheel tests passed: ${wheels[0]##*/}"
