#!/usr/bin/env bash
# Tests for verify_trailing_conditional.py and for the four functions it found.
# Part A plants one subject.sh per rule in a throwaway tree (the gate derives its
# root from its own path); part B evals each fixed function under `set -e` and
# asserts the "nothing to do" path returns 0.
# docs/code-quality-tooling.md#trailing-conditional-returns-trailing-conditional
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gate-tree.sh"
GATE="${SCRIPTS_DIR}/verify_trailing_conditional.py"
PY="${PREFLIGHT_PYTHON:-python3}"

_fixture() {
  gate_tree_subject trailing-conditional.allow "$1" "${2-}" \
    "${GATE}" "${SCRIPTS_DIR}/verify_code_size.py" "${SCRIPTS_DIR}/quality_allow.py"
}
_gate() { "${PY}" "$1/linux/scripts/verify_trailing_conditional.py"; }

# _verdict <rc> <why> <subject> [allow];  _says <substring> <why> <subject> [allow]
_verdict() {
  local fix; fix="$(_fixture "$3" "${4-}")"
  t_assert_eq "$1" "$(t_rc _gate "${fix}")" "$2"
  rm -rf "${fix}"
}
_says() {
  local fix; fix="$(_fixture "$3" "${4-}")"
  t_assert_contains "$(t_out _gate "${fix}")" "$1" "$2"
  rm -rf "${fix}"
}

t_case "the gate passes on the frozen tree"
t_assert_ok "${PY}" "${GATE}"

t_case "a trailing && list is a finding"
_verdict 1 "the false arm returns 1 and kills the caller under set -e" \
  $'f() {\n  [ -n "${x}" ] && do_thing\n}'
_says "NEW trailing-conditional return" "the heading names the failure class" \
  $'f() {\n  [ -n "${x}" ] && do_thing\n}'
_says "linux/scripts/subject.sh:2" "the finding carries file and line" \
  $'f() {\n  [ -n "${x}" ] && do_thing\n}'

t_case "the documented fix shape passes"
_verdict 0 "guard-then-act ends on the action, so the empty path returns 0" \
  $'f() {\n  [ -n "${x}" ] || return 0\n  do_thing\n}'

t_case "a trailing semicolon does not empty the last statement"
_verdict 1 "the cut must leave something behind or it is not a separator" \
  $'f() {\n  [ -n "${x}" ] && do_thing;\n}'

t_case "a bare test as the last statement is a finding"
_verdict 1 "a function ending on [ ... ] returns the test" \
  $'f() {\n  do_thing\n  [ -n "${x}" ]\n}'
_verdict 1 "and so does one ending on test(1)" \
  $'f() {\n  test -n "${x}"\n}'

t_case "an explicit || tail is not a finding"
_verdict 0 "|| true is how a deliberate no-op path is spelled" \
  $'f() {\n  [ -n "${x}" ] && do_thing || true\n}'

t_case "|| INSIDE a [[ ]] test does not read as the escape hatch"
_verdict 1 "the || is an operator of the test, not a fallback arm" \
  $'f() {\n  [[ -n "${a}" || -n "${b}" ]]\n}'

t_case "only the LAST ;-separated statement is judged"
_verdict 1 "y=1 is not what the function returns" \
  $'f() {\n  y=1; [ -n "${x}" ]\n}'
_verdict 0 "the && lives inside the loop, not in the statement that returns" \
  $'f() {\n  for a in "$@"; do [ -n "${a}" ] && printf \'%s\\n\' "${a}"; done | sort -u\n}'

t_case "an && inside a substitution is not a top-level operator"
_verdict 0 "the assignment is what returns, not the inner list" \
  $'f() {\n  out="$(a && b)"\n}'

t_case "a statement that closes a block is not a finding"
_verdict 0 "if/fi returns 0 when the condition is false" \
  $'f() {\n  if [ -n "${x}" ]; then do_thing; fi\n}'
_verdict 0 "and so does a case with no matching arm" \
  $'f() {\n  case "${x}" in a) do_thing ;; esac\n}'

t_case "a continuation line is joined onto the statement it continues"
_verdict 1 "the shape of the 2026-09-02 EXIT-trap death spans two lines" \
  $'f() {\n  declare -F g >/dev/null 2>&1 \\\n    && g\n}'
_verdict 0 "read alone the second line looks like a bare && list; it is not one" \
  $'f() {\n  a || b \\\n    && c\n}'

t_case "a heredoc body is not code"
_verdict 0 "a conditional in emitted text does not end the function" \
  $'f() {\n  cat <<EOF\n[ -n "${x}" ] && do_thing\nEOF\n}'

t_case "trailing comments and blank lines do not move the last statement"
_verdict 0 "the comment is not a statement" \
  $'f() {\n  do_thing\n\n  # [ -n "${x}" ] && do_thing\n}'

t_case "the allowlist is two-way"
_verdict 0 "a frozen predicate passes" \
  $'f() {\n  [ -n "${x}" ]\n}' "$(printf 'linux/scripts/subject.sh\tf\n')"
_verdict 1 "a frozen function that no longer ends on a conditional is STALE" \
  $'f() {\n  do_thing\n}' "$(printf 'linux/scripts/subject.sh\tf\n')"
_says "STALE" "and says so" \
  $'f() {\n  do_thing\n}' "$(printf 'linux/scripts/subject.sh\tf\n')"

t_case "the allowlist keys on file+function, not line number"
t_assert_eq "0" "$(grep -c -E '\t[0-9]+' "${SCRIPTS_DIR}/trailing-conditional.allow")" \
  "a line number would re-flag every site whenever something above it moves"

# ---------------------------------------------------------------------------
# Part B — the four live defects. Each function is lifted out of its file and run
# under `set -e`, because none of the four files can be sourced whole.
_fn() { sed -n "/^$2() {/,/^}/p" "${SCRIPTS_DIR}/$1"; }
# _rc_of <rc-var-name> <preamble> <file> <fn> <call>
_rc_of() {
  local pre="$1" file="$2" fn="$3" call="$4"
  bash -c "set -eu; ${pre}
$(_fn "${file}" "${fn}")
${call}" >/dev/null 2>&1; printf '%s' "$?"
}

t_case "derive_cxx_from_cc returns 0 when the derived g++ is not executable"
t_assert_eq "0" "$(_rc_of ":" 01-core/compiler-resolution.sh derive_cxx_from_cc \
  'derive_cxx_from_cc /nonexistent/aarch64-linux-gnu-gcc')" \
  "returning 1 here killed the caller at compiler-resolution.sh:130 under set -e"
t_assert_eq "" "$(bash -c "set -eu
$(_fn 01-core/compiler-resolution.sh derive_cxx_from_cc)
derive_cxx_from_cc /nonexistent/aarch64-linux-gnu-gcc" 2>/dev/null)" \
  "the documented contract is empty output, not a failure"

t_case "_cross_env_resolve_tools still refuses when no g++ can be derived"
t_assert_eq "1" "$(_rc_of 'require_cross_gcc_tool() { if [ "$1" = g++ ]; then return 1; fi; printf /bin/true; }
resolve_build_gcc_tool() { printf /bin/true; }
derive_cxx_from_cc() { :; }' 01-core/cross-env.sh _cross_env_resolve_tools \
  'declare -A T; _cross_env_resolve_tools x T')" \
  "an empty derived CXX must fail, not sail on with CXX unset"

t_case "_chain_on_exit returns 0 when the cleanup helper is not defined"
t_assert_eq "0" "$(_rc_of '_chain_remove_pidfile() { :; }' build-cross-chain.sh _chain_on_exit \
  '_chain_on_exit')" \
  "an EXIT trap that returns 1 turns a green chain red under set -e"

t_case "patch_gstreamer_sources returns 0 when the last patch target is absent"
_tmp="$(mktemp -d)"; mkdir -p "${_tmp}/subprojects"
t_assert_eq "0" "$(_rc_of "_apply_patch=/bin/true; _patch_dir=${_tmp}; echo() { :; }" \
  03-media/build/gstreamer/common/patch-gstreamer-sources.sh patch_gstreamer_sources \
  "patch_gstreamer_sources ${_tmp}")" \
  "a tree without gst-libav must not fail the two unguarded call sites"
rm -rf "${_tmp}"

t_summary
