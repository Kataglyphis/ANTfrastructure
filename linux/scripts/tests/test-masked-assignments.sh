#!/usr/bin/env bash
# Tests for verify-masked-assignments.py. `local x="$(cmd)"` returns local's
# status, so set -e never sees cmd fail. shellcheck's SC2155 misses the
# `${y:-$(cmd)}` spelling, and lint-shell.sh gates at -S error where a warning
# cannot fail — which is why this gate exists. docs/failure-modes.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GATE="${TESTS_DIR}/../verify-masked-assignments.py"
PY="${PREFLIGHT_PYTHON:-python3}"

t_case "the gate passes on the frozen tree"
t_assert_ok "${PY}" "${GATE}"

t_case "shellcheck really is blind to the \${y:-\$(cmd)} form"
_t="$(mktemp)"; printf 'f() {\n  local b="${B:-$(date)}"\n  echo "${b}"\n}\n' > "${_t}"
t_assert_eq "0" "$(shellcheck -S warning -f gcc "${_t}" 2>/dev/null | grep -c -e SC2155)" \
  "if this ever fires, shellcheck improved and the gate can narrow"
rm -f "${_t}"

t_case "the gate is registered in preflight"
t_assert_contains "$(cat "${TESTS_DIR}/../preflight.sh")" "masked-decls" \
  "an unwired gate is not a gate"

t_case "the allowlist keys on file+variable, not line number"
t_assert_eq "0" "$(grep -c -E '\t[0-9]+\t' "${TESTS_DIR}/../masked-assignments.allow")" \
  "a line number would re-flag every site whenever something above it moves"

t_summary
