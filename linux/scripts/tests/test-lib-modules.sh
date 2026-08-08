#!/usr/bin/env bash
# Parity/robustness suite for the consumer-facing linux/scripts/lib/ modules.
# These are sourced STANDALONE by external repos, so every module must:
#   (1) be double-source safe (re-source guard),
#   (2) end up with info/warn/err defined (real logging.sh or fallbacks).
# Complexity audit F-A found 2 of 8 had drifted on exactly these properties.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB_DIR="${TESTS_DIR}/../lib"

for mod in "${LIB_DIR}"/*.sh; do
  name="$(basename "${mod}")"
  # agentic-loop is an executable loop, not a source-library — skip.
  [ "${name}" = "agentic-loop.sh" ] && continue

  t_case "${name}: sources cleanly and defines info/warn/err"
  t_assert_ok bash -c "source '${mod}' && declare -F info >/dev/null && declare -F warn >/dev/null && declare -F err >/dev/null"

  t_case "${name}: double-source is safe (guard or idempotent body)"
  t_assert_ok bash -c "source '${mod}' && source '${mod}'"
done

t_case "app-runner picks up the REAL logging module when sourced standalone"
_out="$(bash -c "source '${LIB_DIR}/app-runner.sh'; declare -F log >/dev/null && echo REAL || echo FALLBACK" 2>/dev/null)"
t_assert_eq "REAL" "${_out}" "app-runner must load 01-core/logging.sh (the drifted copy never did)"

t_summary
