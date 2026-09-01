#!/usr/bin/env bash
# Tests for the two gates added 2026-09-01 to stop classes of defect recurring:
# comment-size (owner directive 6) and copy-scope (cache blast radius).
# Both mutations below were proven to go red. docs/code-quality-tooling.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PY="${PREFLIGHT_PYTHON:-python3}"
S="${TESTS_DIR}/.."

t_case "the gate passes on the frozen tree"
t_assert_ok "${PY}" "${S}/verify-comment-size.py"

t_case "it is registered in preflight"
t_assert_contains "$(cat "${S}/preflight.sh")" "comment-size" "an unwired gate is not a gate"

t_case "a key that truncates onto whitespace still survives the allowlist"
# The first freeze broke on exactly this: a 60-char cut ending in a space, which
# the allowlist reader then stripped, so the block was NEW and STALE at once.
t_assert_contains "$(cat "${S}/verify-comment-size.py")" ".rstrip()" \
  "truncate first, then rstrip"

t_case "the comment allowlist keys on text, not line number"
t_assert_eq "0" "$(grep -c -E '\t[0-9]+$' "${S}/comment-size.allow")" \
  "a line number would re-flag every block whenever something above it moves"


t_summary
