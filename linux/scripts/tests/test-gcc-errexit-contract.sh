#!/usr/bin/env bash
# The function cannot run without a cross toolchain, so its contract is read; see docs/failure-modes.md#a-callee-invoked-in-an-if--condition-runs-with-errexit-off
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GCC_SH="${TESTS_DIR}/../02-toolchain/gcc.sh"

t_case "the mechanism: an if-condition suppresses errexit inside the callee"
# Not a guard on our code: it pins the bash behaviour the guard below exists for.
_swallowed="$(bash -c '
  set -e
  f() { false; echo "REACHED"; }
  if ! f; then echo "IF-BRANCH"; fi' 2>&1)"
t_assert_eq "REACHED" "${_swallowed}" \
  "under \`if !\`, a failing command does NOT abort the callee"

t_case "the Canadian native builder invocation raises on failure"
# Only the invocation's own continuation lines: a window grep would also see the -x checks' `|| die`.
_builder_block="$(awk '/^build_canadian_native_gcc_for\(\)/,/^\}/' "${GCC_SH}")"
t_assert_contains "${_builder_block}" 'bash "${GCC_CROSS_BUILDER}"' \
  "the function must still be the one that invokes the builder"
_tail="$(printf '%s\n' "${_builder_block}" | awk '
  /bash "\$\{GCC_CROSS_BUILDER\}"/ { inv=1 }
  inv { print; if ($0 !~ /\\$/) exit }')"
t_assert_contains "${_tail}" "|| die" \
  "the builder command itself must end in an explicit die, not rely on errexit"

t_case "the documented skip is still the only tolerated non-zero return"
t_assert_contains "${_builder_block}" "GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE" \
  "the opt-in skip is what the if-condition exists for"

t_summary
