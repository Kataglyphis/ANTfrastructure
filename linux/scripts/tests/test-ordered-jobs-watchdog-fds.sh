#!/usr/bin/env bash
# A watchdog retaining the caller's capture pipe can delay a completed suite until its timeout.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "Linux process file descriptors" bash -c '[[ $(uname -s) == Linux* && -d /proc/self/fd ]]'
# shellcheck source=linux/scripts/lib-ordered-jobs.sh
source "${1:-${TESTS_DIR}/../lib-ordered-jobs.sh}" || exit 2

_WORK="$(mktemp -d)" || exit 1
_cleanup() {
  if [ -n "${_OJ_WATCH_PID:-}" ]; then
    kill -TERM "${_OJ_WATCH_PID}" 2>/dev/null || true
    wait "${_OJ_WATCH_PID}" 2>/dev/null || true
  fi
  rm -rf -- "${_WORK}"
}
trap _cleanup EXIT

OJ_DIR="${_WORK}"
: > "${OJ_DIR}/0.out"

t_case "watchdog output stays in its job log"
_OJ_OWNER_PID=$BASHPID _OJ_COMMAND_PID=$BASHPID OJ_TIMEOUT=60 OJ_INT_POLICY='exit 130' _oj_start_watchdog 0
t_assert_ok t_wait_file "${OJ_DIR}/0.watch"
[ -s "${OJ_DIR}/0.watch" ] || { t_summary; exit 1; }
watch_pid="$(cat "${OJ_DIR}/0.watch")"
t_assert_eq /dev/null "$(readlink "/proc/${watch_pid}/fd/0")"
for fd in 1 2; do
  t_assert_eq "${OJ_DIR}/0.out" "$(readlink "/proc/${watch_pid}/fd/${fd}")" "fd ${fd} retained caller output"
done
kill -TERM "${watch_pid}"
wait "${watch_pid}" 2>/dev/null || true
_OJ_WATCH_PID=""
t_assert_eq dead "$(t_pid_state "${watch_pid}")" "watchdog survived cleanup"
t_summary
