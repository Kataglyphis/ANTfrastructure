#!/usr/bin/env bash
# Volatile timings and per-language subtotals cannot measure new cache activity; fixtures prove no actual compiler reuse.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_source_functions "${1:-${TESTS_DIR}/../02-toolchain/probe-sccache.sh}" _writes || exit 1
probe_stats_status=0
sccache() {
  [ "$1" = --show-stats ] || return 91
  printf '%s\n' "${probe_stats_text}"
  return "${probe_stats_status}"
}
t_case 'activity includes aggregate integer counters and excludes timings, errors and language subtotals'
probe_stats_text=$'Compile requests executed       2\nCache hits                      3\nCache hits (C/C++)               3\nCache hits rate              10.0 %\nCache writes                    4\nCache write errors              9\nAverage cache write         0.900 s'
t_assert_eq 9 "$(_writes)"
t_case 'changing a duration cannot reduce measured compiler activity'
probe_stats_text="${probe_stats_text/0.900/0.001}"
t_assert_eq 9 "$(_writes)"
t_case 'changing hit rate cannot reduce measured compiler activity'
probe_stats_text="${probe_stats_text/10.0 %/0.0 %}"
t_assert_eq 9 "$(_writes)"
t_case 'unrelated nonzero rows cannot manufacture activity'
probe_stats_text=$'Compile requests                8\nCompile requests executed       0\nCache hits                      0\nCache writes                    0\nCache write errors             47\nAverage cache write         0.009 s'
t_assert_eq 0 "$(_writes)"
t_case 'fractional or nonnumeric aggregate values cannot manufacture activity'
probe_stats_text=$'Compile requests executed     1.2\nCache hits                    0.5\nCache writes                  invalid'
t_assert_eq 0 "$(_writes)"
t_case 'the older singular write label remains supported'
probe_stats_text=$'Compile requests executed       1\nCache hits                      2\nCache write                     4'
t_assert_eq 7 "$(_writes)"
t_case 'failed stats collection retains its raw status'
probe_stats_status=47
t_assert_rc 47 _writes
t_summary
