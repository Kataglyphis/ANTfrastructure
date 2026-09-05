#!/usr/bin/env bash
# Parity/robustness suite for the consumer-facing linux/scripts/lib/ modules.
# These are sourced STANDALONE by external repos, so every module must:
#   (1) be double-source safe (re-source guard),
#   (2) end up with info/warn/err defined (real logging.sh or fallbacks),
#   (3) reach the REAL logging.sh, and own no private copy of the fallbacks.
# docs/shared-script-libraries.md#the-logging-bootstrap
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB_DIR="${TESTS_DIR}/../lib"

for mod in "${LIB_DIR}"/*.sh; do
  name="$(basename "${mod}")"
  # The agentic-* pair is one executable loop split over two files, not a
  # source-library: agentic-engines.sh is a half that its own sourcer feeds.
  # docs/agentic-loop-build-matrix.md#the-two-bash-files
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
# These libraries set no -e, so a bare `cd` that fails only prints to stderr and
# the next command runs where the caller happened to be. docs/code-quality-gates.md
_unguarded="$(grep -rnE '^[[:space:]]*cd [^|&]*$' "${LIB_DIR}" || true)"
t_assert_eq "" "${_unguarded}" "guard each with || err/|| return"

t_summary
