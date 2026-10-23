#!/usr/bin/env bash
# Permission fixtures observe mode restoration and captured verdicts without invoking Renovate or lock tools.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/renovate-fixtures.sh
source "${1:-${TESTS_DIR}/renovate-fixtures.sh}"
probe="${WORK}/mode probe"
: > "$probe"
OBSERVED=()
OBSERVED_MODE=''
_run() {
  OBSERVED=("$@")
  OBSERVED_MODE="$(stat -c '%a' "$probe")"
  RC=7
  OUT='fixture failure'
}

t_case "temporary fixture permissions are active during a failed run"
_run_in_mode "$probe" 444 640 'repo with spaces' 'report with spaces' --apply --managers pub --note 'option with spaces'
t_assert_eq 444 "$OBSERVED_MODE"
t_case "failed fixture runs restore the caller-selected permission mode"
t_assert_eq 640 "$(stat -c '%a' "$probe")"
t_case "cleanup preserves the run verdict and diagnostics"
t_assert_eq 7 "$RC"
t_assert_eq 'fixture failure' "$OUT"
t_case "permission fixtures retain argument boundaries and option order"
t_assert_eq 'repo with spaces' "${OBSERVED[0]}"
t_assert_eq 'report with spaces' "${OBSERVED[1]}"
t_assert_eq '--apply|--managers|pub|--note|option with spaces' "${OBSERVED[2]}|${OBSERVED[3]}|${OBSERVED[4]}|${OBSERVED[5]}|${OBSERVED[6]}"
t_summary
