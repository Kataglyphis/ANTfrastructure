#!/usr/bin/env bash
# Tests for verify-function-size.py. The gate derives its root from its own path,
# so each case builds a throwaway tree and runs the real script against it.
# Every contract here was PROVEN to go red once. See docs/code-quality-tooling.md.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
PY="${PREFLIGHT_PYTHON:-python3}"

# A tree with one shell file holding a function of <n> lines, plus an optional
# allow file. Echoes the tree root.
_fixture() {
  local n="$1" allow="${2-}" d
  d="$(mktemp -d)"
  mkdir -p "${d}/linux/scripts"
  cp "${SCRIPTS_DIR}/verify-function-size.py" "${d}/linux/scripts/"
  {
    echo "big() {"
    for _ in $(seq 1 $((n - 2))); do echo "  :"; done
    echo "}"
  } > "${d}/linux/scripts/subject.sh"
  [ -n "${allow}" ] && printf '%s\n' "${allow}" > "${d}/linux/scripts/function-size.allow"
  printf '%s' "${d}"
}

_run() { "${PY}" "$1/linux/scripts/verify-function-size.py" 2>&1; }
_rc()  { "${PY}" "$1/linux/scripts/verify-function-size.py" >/dev/null 2>&1; echo $?; }

# One fixture, one verdict. Every case below differs only in the function length,
# the allow line, and what the message must say.
_gate_says() {
  local n="$1" allow="$2" want="$3" why="$4" fix out
  fix="$(_fixture "${n}" "${allow}")"
  out="$(_run "${fix}")"
  rm -rf "${fix}"
  t_assert_contains "${out}" "${want}" "${why}"
}

t_case "a short function is not reported"
FIX="$(_fixture 10)"
t_assert_eq "0" "$(_rc "${FIX}")" "10 lines is under the limit"
rm -rf "${FIX}"

t_case "a new oversized function fails"
FIX="$(_fixture 100)"
t_assert_eq "1" "$(_rc "${FIX}")" "100 lines, unfrozen, must fail"
rm -rf "${FIX}"
_gate_says 100 "" "not frozen" "the message must say what to do"

t_case "a frozen function at its recorded length passes"
FIX="$(_fixture 100 "linux/scripts/subject.sh | big | 100 | baseline")"
t_assert_eq "0" "$(_rc "${FIX}")" "the baseline is the contract"
rm -rf "${FIX}"

t_case "growth past the frozen number fails"
_gate_says 100 "linux/scripts/subject.sh | big | 90 | baseline" \
  "GREW from 90 to 100" "frozen numbers may only go down"

t_case "shrinking without updating the entry fails, so the baseline cannot rot"
_gate_says 100 "linux/scripts/subject.sh | big | 110 | baseline" \
  "shrank from 110 to 100" "an improvement must be recorded"

t_case "a freeze for a function no longer over the limit is stale and fails"
_gate_says 10 "linux/scripts/subject.sh | big | 100 | baseline" \
  "STALE freeze" "delete the line once it drops under"

t_summary
