#!/usr/bin/env bash
# gates.sh's GitHub annotations (CON293): a failed gate names itself on a runner and in a container, nowhere else.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/test-harness.sh
source "${TESTS_DIR}/test-harness.sh"
GATES="${TESTS_DIR}/../01-core/gates.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# _batch [VAR=value ...]: a batch with one passing and one failing gate, its output on stdout and stderr.
_batch() {
  env -u GITHUB_ACTIONS -u GATES_GITHUB_ANNOTATIONS -u GITHUB_STEP_SUMMARY "$@" bash -c '
    source "$1"; gate_reset "lint, gates"; run_gate "ok" true; run_gate "ruff: check" false; assert_gates' _ "${GATES}" 2>&1
}

t_case "off GitHub a failed gate writes no annotation"
out="$(_batch)"
t_assert_eq "0" "$(grep -c '^::error' <<<"${out}")" "a local run stays plain"

t_case "on a runner the failed gate, and only it, names itself, with the title's : and , escaped"
out="$(_batch GITHUB_ACTIONS=true)"
t_assert_contains "${out}" "::error title=lint%2C gates%3A ruff%3A check::ruff: check failed (exit 1)"
t_assert_eq "1" "$(grep -c '^::error' <<<"${out}")" "the passing gate stays silent"

t_case "in a container the action's variable turns it on, and a writable summary gets a row"
: > "${WORK}/summary.md"
out="$(_batch GATES_GITHUB_ANNOTATIONS=1 GITHUB_STEP_SUMMARY="${WORK}/summary.md")"
t_assert_contains "${out}" "::error title=lint%2C gates%3A ruff%3A check::"
t_assert_contains "$(cat "${WORK}/summary.md")" '- `ruff: check` failed (exit 1) in lint, gates'

t_case "the batch still fails once, after every gate ran"
t_assert_contains "${out}" "lint, gates FAILED (1 of 2): ruff: check"

t_summary
