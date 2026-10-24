#!/usr/bin/env bash
# Real ty fixtures prove the strict scopes; optional-import files remain in the full reports.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf -- "${ROOT}"' EXIT

mkdir -p "${ROOT}/linux/scripts/01-core" "${ROOT}/linux/scripts/tests" \
  "${ROOT}/linux/scripts/05-frameworks/flutter" "${ROOT}/docs/scripts" \
  "${ROOT}/windows/scripts/certificates" "${ROOT}/shared/python" \
  "${ROOT}/linux/llm-stack/tests" "${ROOT}/linux/scripts/02-toolchain/python" \
  "${ROOT}/linux/scripts/lib" "${ROOT}/quality"
cp "${S}/lint-python-types.sh" "${ROOT}/linux/scripts/"
cp "${S}/01-core/load-versions-env.sh" "${ROOT}/linux/scripts/01-core/"
cp "${S}/../../quality/pyproject.toml" "${S}/../../quality/uv.lock" "${ROOT}/quality/"
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
  t_assert_contains "$1" "ty quality gate: clean (17 files)"
  t_assert_contains "$1" "ty Windows gate: clean (1 files)"
  t_assert_contains "$1" "rc=0"
}

t_case "the pinned ty checks tracked quality scripts and writes all reports under logs"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/windows/scripts/subject.py" 42
_set_answer "${ROOT}/linux/scripts/verify_subject.py" 42
_set_answer "${ROOT}/linux/scripts/tests/typed_subject.py" 42
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/typed_subject.py" 42
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" 42
printf 'import pytest\nimport yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/llm-stack/tests/typed_subject.py"
printf 'import pytest\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py"
printf 'import yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_audit.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_cmake.py"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_locator.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_package_names.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_comment_size.py"
printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/verify_gate_registry.py"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/gate_scope.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/quality_allow.py"
printf 'VALUE = 1\n' > "${ROOT}/linux/scripts/extract_embedded_python.py"
git -c core.autocrlf=false -C "${ROOT}" add .
out="$(_run)"
_assert_clean_quality "${out}"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-quality-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-linux.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-windows.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ty-windows-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-annotations.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-annotations-gate.txt"
t_assert_ok test -f "${ROOT}/logs/code-quality/ruff-private-returns-gate.txt"
t_assert_contains "${out}" "Ruff signature annotation gate: clean (19 files)"
t_assert_contains "${out}" "Ruff private return gate: clean (8 files)"

t_case "the locked quality environment resolves test and parser imports"
t_assert_ok test -d "${ROOT}/quality/.venv"
t_assert_no_grep "${ROOT}/logs/code-quality/ty-quality-gate.txt" 'unresolved-import'

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

t_case "a framework source mismatch is inside the strict scope"
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/typed_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "05-frameworks"
t_assert_contains "${out}" "rc=1"
_set_answer "${ROOT}/linux/scripts/05-frameworks/flutter/typed_subject.py" 42

t_case "a type error in the LLM tests fails the expanded strict scope"
printf 'import pytest\nimport yaml\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/llm-stack/tests/typed_subject.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "llm-stack/tests/typed_subject.py"
t_assert_contains "${out}" "rc=1"
printf 'import pytest\nimport yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/llm-stack/tests/typed_subject.py"

t_case "a type error in the Python wheel tests fails the expanded strict scope"
printf 'import pytest\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "free-threaded-wheel-tests.py"
t_assert_contains "${out}" "rc=1"
printf 'import pytest\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/02-toolchain/python/free-threaded-wheel-tests.py"

t_case "a type error in the audit script fails the expanded strict scope"
printf 'import yaml\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/renovate_audit.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "renovate_audit.py"
t_assert_contains "${out}" "rc=1"
printf 'import yaml\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_audit.py"

t_case "a missing private Renovate return fails the focused Ruff gate"
printf 'def _plan():\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff private return gate failed (exit 1)"
t_assert_contains "${out}" "ANN202"
t_assert_contains "${out}" "rc=1"
printf 'def _plan() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/renovate_planner.py"

t_case "missing private verifier returns fail the focused Ruff gate"
for target in verify_package_names verify_comment_size verify_gate_registry; do
  printf 'def _check():\n    return 42\n' > "${ROOT}/linux/scripts/${target}.py"
  out="$(_run)"
  t_assert_contains "${out}" "Ruff private return gate failed (exit 1)"
  t_assert_contains "${out}" "ANN202"
  t_assert_contains "${out}" "rc=1"
  printf 'def _check() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/${target}.py"
done

t_case "a type error in the Markdown parser fails the expanded strict scope"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return "wrong"\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"
out="$(_run)"
t_assert_contains "${out}" "ty quality gate failed (exit 1)"
t_assert_contains "${out}" "dartdoc-guides.py"
t_assert_contains "${out}" "rc=1"
printf 'from markdown_it import MarkdownIt\ndef answer() -> int:\n    return 42\n' > "${ROOT}/linux/scripts/lib/dartdoc-guides.py"

t_case "a Windows source mismatch is visible and fails the Windows type gate"
_set_answer "${ROOT}/docs/scripts/subject.py" 42
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" '"wrong"'
out="$(_run)"
t_assert_contains "${out}" "Windows Python report: findings (2 files)"
t_assert_contains "${out}" "ty Windows gate failed (exit 1)"
t_assert_contains "${out}" "rc=1"
t_assert_grep "${ROOT}/logs/code-quality/ty-windows.txt" 'invalid-return-type'
_set_answer "${ROOT}/windows/scripts/certificates/typed_subject.py" 42

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
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN205"
t_assert_contains "${out}" "rc=1"

t_case "a classmethod without a return annotation fails the full tracked-tree gate"
printf 'class Answer:\n    @classmethod\n    def value(cls):\n        return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN206"
t_assert_contains "${out}" "rc=1"

t_case "a constructor without a return annotation fails the full tracked-tree gate"
printf 'class Answer:\n    def __init__(self):\n        self.value = 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN204"
t_assert_contains "${out}" "rc=1"

t_case "unannotated variadic positional arguments fail the full tracked-tree gate"
printf 'def answer(*values) -> int:\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN002"
t_assert_contains "${out}" "rc=1"

t_case "unannotated variadic keyword arguments fail the full tracked-tree gate"
printf 'def answer(**values) -> int:\n    return 42\n' > "${ROOT}/docs/scripts/subject.py"
out="$(_run)"
t_assert_contains "${out}" "Ruff signature annotation gate failed (exit 1)"
t_assert_contains "${out}" "ANN003"
t_assert_contains "${out}" "rc=1"

t_summary
