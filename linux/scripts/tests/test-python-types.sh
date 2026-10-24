#!/usr/bin/env bash
# A real ty run proves the strict quality scope fails on a type mismatch while the full scan keeps its report.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf -- "${ROOT}"' EXIT

mkdir -p "${ROOT}/linux/scripts/01-core" "${ROOT}/linux/scripts/tests" "${ROOT}/docs/scripts" \
  "${ROOT}/windows/scripts" "${ROOT}/shared/python"
cp "${S}/lint-python-types.sh" "${ROOT}/linux/scripts/"
cp "${S}/01-core/load-versions-env.sh" "${ROOT}/linux/scripts/01-core/"
sed -n '/^\(TY\|RUFF\)_VERSION=/p' "${S}/01-core/tool-pins.env" > "${ROOT}/linux/scripts/01-core/tool-pins.env"
git -C "${ROOT}" init -q

_run() {
  local out rc=0
  out="$(bash "${ROOT}/linux/scripts/lint-python-types.sh" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${out}" "${rc}"
}

_set_answer() {
  printf 'def answer() -> int:\n    return %s\n' "$2" > "$1"
}

_assert_clean_quality() {
  t_assert_contains "$1" "ty quality gate: clean (6 files)"
  t_assert_contains "$1" "rc=0"
}

t_case "the pinned ty checks tracked quality scripts and writes all reports under logs"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/windows/scripts/subject.py" 42
_set_answer "${ROOT}/linux/scripts/verify_subject.py" 42
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" 42
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/gate_scope.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/quality_allow.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/extract_embedded_python.py"
git -c core.autocrlf=false -C "${ROOT}" add .
out="$(_run)"
_assert_clean_quality "${out}"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-quality-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-linux.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-windows.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-annotations.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-annotations-gate.txt"
t_assert_contains "${out}" "Ruff staticmethod annotation gate: clean (7 files)"

t_case "a return type mismatch fails the strict gate"
_set_answer "${ROOT}/docs/scripts/subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "invalid-return-type"
t_assert_contains "${out}" "rc=1"

t_case "a verifier type mismatch is inside the strict scope"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/linux/scripts/verify_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "verify_subject.py"
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/linux/scripts/verify_subject.py" 42

t_case "a test helper type mismatch is inside the strict scope"
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "typed_subject.py"
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" 42

t_case "Windows findings remain visible without pretending the full scan passed"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/windows/scripts/subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "Windows Python report: findings (1 files)"
_assert_clean_quality "${out}"
t_assert_grep "${ROOT}/logs/code-quality/ty-windows.txt" 'invalid-return-type'

t_case "missing annotations are reported without claiming ty requires them"
printf 'def answer():\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
_set_answer "${ROOT}/windows/scripts/subject.py" 42
out="$(_run)"
t_assert_contains "${out}" "Ruff annotation report: findings"
t_assert_contains "${out}" "ty quality gate: clean"
t_assert_contains "${out}" "rc=0"
t_assert_grep "${ROOT}/logs/code-quality/ruff-annotations.txt" 'ANN201'

t_case "missing parameter annotations are reported without failing the type gate"
printf 'def answer(value) -> int:\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff annotation report: findings"
t_assert_contains "${out}" "ty quality gate: clean"
t_assert_contains "${out}" "rc=0"
t_assert_grep "${ROOT}/logs/code-quality/ruff-annotations.txt" 'ANN001'

t_case "a staticmethod without a return annotation fails the full tracked-tree gate"
printf 'class Answer:\n    @staticmethod\n    def value():\n        return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff staticmethod annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN205"
t_assert_contains "${out}" "rc=1"

t_summary
