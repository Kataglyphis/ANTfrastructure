#!/usr/bin/env bash
# Copied-gate drivers preserve fixture row bytes, argv, environment and verdicts without running host tools.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-workspace-fixture.sh"
declare WORK
t_fixture_workspace_init WORK || exit 1
GATE_TREE="${1:-${TESTS_DIR}/gate-tree.sh}"
# shellcheck source=linux/scripts/tests/gate-tree.sh
source "$GATE_TREE"
TREE="${WORK}/tree with spaces"
mkdir -p "${TREE}/tools"
cat > "${TREE}/tools/probe.py" <<'PY'
import os, sys
print("arg=" + sys.argv[1] + ";env=" + os.environ["FIXTURE_MARKER"], flush=True)
print("diagnostic", file=sys.stderr, flush=True)
sys.exit(int(sys.argv[2]))
PY

t_case "copied gate retains argv boundaries, environment and both diagnostic streams"
actual="$(FIXTURE_MARKER='shared value' gate_tree_out python3 "${TREE}" tools/probe.py 'two words' 0 2>/dev/null)"
t_assert_eq $'arg=two words;env=shared value\ndiagnostic' "$actual"
t_case "copied gate retains a failing child verdict"
t_assert_rc 37 env FIXTURE_MARKER=present bash -c '
  source "$1/test-harness.sh"
  source "$3"
  gate_tree_out python3 "$2" tools/probe.py value 37
' _ "$TESTS_DIR" "$TREE" "$GATE_TREE"
t_case "freeze rows preserve spaces, separators and final newline"
gate_tree_freeze "${TREE}/rows.allow" 'one | two # three' 'second row'
t_assert_eq $'one | two # three\nsecond row' "$(cat "${TREE}/rows.allow")"
t_assert_eq 29 "$(wc -c < "${TREE}/rows.allow" | tr -d ' ')"
t_case "a replacement freeze truncates previous rows"
gate_tree_freeze "${TREE}/rows.allow" changed
t_assert_eq changed "$(cat "${TREE}/rows.allow")"
t_case "an empty freeze retains the original single newline"
gate_tree_freeze "${TREE}/rows.allow"
t_assert_eq 1 "$(wc -c < "${TREE}/rows.allow" | tr -d ' ')"
t_summary
