#!/usr/bin/env bash
# The structural guard complements fake-builder execution in test-gcc-cross-launch.sh; no real GCC build is covered.
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
t_assert_contains "${_builder_block}" '_gcc_invoke_cross_builder' \
  "the function must still call the shared builder launch"
_tail="$(printf '%s\n' "${_builder_block}" | awk '
  /_gcc_invoke_cross_builder/ { inv=1 }
  inv { print; if ($0 !~ /\\$/) exit }')"
t_assert_contains "${_tail}" "|| die" \
  "the builder command itself must end in an explicit die, not rely on errexit"

t_case "the documented skip is still the only tolerated non-zero return"
t_assert_contains "${_builder_block}" "GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE" \
  "the opt-in skip is what the if-condition exists for"

t_summary
