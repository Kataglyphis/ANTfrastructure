#!/usr/bin/env bash
# The `if ! build_canadian_native_gcc_for …` call site suppresses errexit for that
# function's whole body, so every failure inside it must raise explicitly. The
# function needs a cross toolchain and a sysroot, so it cannot run here; what is
# testable is the contract.
# docs/failure-modes.md#a-callee-invoked-in-an-if--condition-runs-with-errexit-off
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
GCC_SH="${TESTS_DIR}/../02-toolchain/gcc.sh"

t_case "the mechanism: an if-condition suppresses errexit inside the callee"
# Not a guard on our code — it records WHY the guard below is needed, because the
# behaviour is easy to misremember and the cost of forgetting is a silent build.
_swallowed="$(bash -c '
  set -e
  f() { false; echo "REACHED"; }
  if ! f; then echo "IF-BRANCH"; fi' 2>&1)"
t_assert_eq "REACHED" "${_swallowed}" \
  "under \`if !\`, a failing command does NOT abort the callee"

t_case "the Canadian native builder invocation raises on failure"
# Without this the builder's exit code was discarded and the two -x checks below
# it still passed, on the binaries install-gcc had already written. Walk the
# invocation's OWN continuation lines: a window-grep also sees those -x checks'
# own `|| die` and would pass with the guard removed (it did).
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
