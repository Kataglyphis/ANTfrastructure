#!/usr/bin/env bash
# lib/ modules are sourced standalone by other repos; see docs/shared-script-libraries.md#the-logging-bootstrap
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB_DIR="${TESTS_DIR}/../lib"

for mod in "${LIB_DIR}"/*.sh; do
  name="$(basename "${mod}")"
  # The agentic-* pair is one loop split over two files, not a library; see docs/agentic-loop-build-matrix.md#the-two-bash-files
  case "${name}" in agentic-*.sh) continue ;; esac

  t_case "${name}: sources cleanly and defines info/warn/err"
  t_assert_ok bash -c "source '${mod}' && declare -F info >/dev/null && declare -F warn >/dev/null && declare -F err >/dev/null"

  t_case "${name}: double-source is safe (guard or idempotent body)"
  t_assert_ok bash -c "source '${mod}' && source '${mod}'"

  t_case "${name}: picks up the REAL logging module when sourced standalone"
  _out="$(bash -c "source '${mod}'; declare -F log >/dev/null && echo REAL || echo FALLBACK" 2>/dev/null)"
  t_assert_eq "REAL" "${_out}" "${name} must load 01-core/logging.sh (the drifted copies never did)"

  [ "${name}" = "log-bootstrap.sh" ] && continue

  t_case "${name}: keeps no private copy of the logging fallbacks"
  t_assert_fails grep -qF '[1;34m[INFO]' "${mod}"

  t_case "${name}: sources the shared bootstrap"
  t_assert_ok grep -qF 'log-bootstrap.sh' "${mod}"
done

t_case "every cd in lib/ is guarded — an unguarded cd runs the suite/app in the WRONG tree"
# These libraries set no -e, so a failed bare `cd` runs the next command in the caller's dir; see docs/code-quality-gates.md
_unguarded="$(grep -rnE '^[[:space:]]*cd [^|&]*$' "${LIB_DIR}" || true)"
t_assert_eq "" "${_unguarded}" "guard each with || err/|| return"

t_summary
