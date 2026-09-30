#!/usr/bin/env bash
# tool-checks.sh, each case in a child shell: require_tools exits, and the load guard makes a re-source a no-op.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="$(cd "${TESTS_DIR}/.." && pwd)/01-core"
MODULE="${CORE}/tool-checks.sh"

_out=""; _rc=0
# _run <bash snippet>: the snippet sources the module itself, so a case can define the pair first.
_run() {
  _out="$(bash -c "
set -u
source '${CORE}/logging.sh'
$1" 2>&1)"
  _rc=$?
}

# Two names no PATH can satisfy, so "every missing tool" is testable.
_ABSENT_A=tool_checks_absent_a_9f3
_ABSENT_B=tool_checks_absent_b_9f3

t_case "has_tool answers for a command on PATH, and for one that is not"
_run "source '${MODULE}'; has_tool bash"
t_assert_eq "0" "${_rc}" "bash is on PATH in every environment this suite runs in"
_run "source '${MODULE}'; has_tool ${_ABSENT_A}"
t_assert_eq "1" "${_rc}" "an absent command is a plain non-zero, not an exit"

t_case "require_tools returns quietly when every tool is present"
_run "source '${MODULE}'; require_tools bash env; echo REACHED"
t_assert_eq "0" "${_rc}"
t_assert_contains "${_out}" "REACHED" "it must RETURN, not exit, when nothing is missing"

t_case "require_tools names EVERY missing tool, not just the first"
_run "source '${MODULE}'; require_tools ${_ABSENT_A} bash ${_ABSENT_B}; echo REACHED"
t_assert_contains "${_out}" "${_ABSENT_A}"
t_assert_contains "${_out}" "${_ABSENT_B}" \
  "reporting only the first turns 'install these two' into two failed runs"

t_case "a missing tool is FATAL: require_tools does not return to its caller"
t_assert_eq "1" "${_rc}" "err exits 1; a warning here would let the build carry on toolless"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -F REACHED || true)" \
  "the line after require_tools must never run"

t_case "a caller that already defines the pair keeps ITS version"
# Hence a `declare -F` guard per definition, not just the file-level load guard.
_run "has_tool() { echo CALLER_HAS_TOOL; return 0; }
require_tools() { echo CALLER_REQUIRE_TOOLS; return 0; }
source '${MODULE}'
has_tool ${_ABSENT_A}
require_tools ${_ABSENT_A}
echo REACHED"
t_assert_eq "0" "${_rc}" "the caller's require_tools returns 0; the module's would have exited 1"
t_assert_contains "${_out}" "CALLER_HAS_TOOL"
t_assert_contains "${_out}" "CALLER_REQUIRE_TOOLS"

t_case "double-source is safe"
_run "source '${MODULE}'; source '${MODULE}'; require_tools bash; echo REACHED"
t_assert_eq "0" "${_rc}"
t_assert_contains "${_out}" "REACHED"

t_summary
