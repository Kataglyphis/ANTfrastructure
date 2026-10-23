#!/usr/bin/env bash
# Fake host Python covers version precedence and failures, not interpreter discovery or execution compatibility.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../01-core/cross-python.sh
source "${1:-${TESTS_DIR}/../01-core/cross-python.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
host_python_bin() { printf 'bin\n' >> "$work/calls"; [ "$host_status" = 0 ] || return "$host_status"; printf fixture_python; }
fixture_python() { printf 'python\n' >> "$work/calls"; printf '%s' 3.15; }

while IFS='|' read -r target shared host_status expected expected_status expected_calls; do
  t_case "target=$target shared=$shared host-status=$host_status"
  export TARGET_PYTHON_MAJOR_MINOR="$target" PYTHON_MAJOR_MINOR="$shared"
  : > "$work/calls"
  status=0
  actual="$(cross_target_python_major_minor)" || status=$?
  t_assert_eq "$expected" "$actual"
  t_assert_eq "$expected_status" "$status"
  t_assert_eq "$expected_calls" "$(tr '\n' ',' < "$work/calls")"
done <<'CASES'
3.12|3.13|0|3.12|0|
|3.13|0|3.13|0|
||0|3.15|0|bin,python,
||17||1|bin,
CASES
t_summary
