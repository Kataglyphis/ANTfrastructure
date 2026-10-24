#!/usr/bin/env bash
# An owned child retaining the caller's capture pipe can delay a completed suite until its timeout.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "Linux process file descriptors" bash -c '[[ $(uname -s) == Linux* && -d /proc/self/fd ]]'
# shellcheck source=linux/scripts/lib-ordered-jobs.sh
source "${1:-${TESTS_DIR}/../lib-ordered-jobs.sh}" || exit 2

_WORK="$(mktemp -d)" || exit 1
_cleanup() {
  if [ -n "${_OJ_SUPERVISOR_PID:-}" ]; then
    oj_reap >/dev/null 2>&1 || true
  fi
  if [ -n "${_OJ_WATCH_PID:-}" ]; then
    kill -TERM "${_OJ_WATCH_PID}" 2>/dev/null || true
    wait "${_OJ_WATCH_PID}" 2>/dev/null || true
  fi
  rm -rf -- "${_WORK}"
}
trap _cleanup EXIT

_assert_owned_fds() {
  local pid="$1" label="$2" fd
  t_assert_eq /dev/null "$(readlink "/proc/${pid}/fd/0")" "${label} fd 0 retained caller input"
  for fd in 1 2; do
    t_assert_eq "${OJ_DIR}/0.out" "$(readlink "/proc/${pid}/fd/${fd}")" "${label} fd ${fd} retained caller output"
  done
}

OJ_DIR="${_WORK}"
: > "${OJ_DIR}/0.out"

t_case "watchdog output stays in its job log"
_OJ_OWNER_PID=$BASHPID _OJ_COMMAND_PID=$BASHPID OJ_TIMEOUT=60 OJ_INT_POLICY='exit 130' _oj_start_watchdog 0
t_assert_ok t_wait_file "${OJ_DIR}/0.watch"
[ -s "${OJ_DIR}/0.watch" ] || { t_summary; exit 1; }
watch_pid="$(cat "${OJ_DIR}/0.watch")"
_assert_owned_fds "${watch_pid}" watchdog
kill -TERM "${watch_pid}"
wait "${watch_pid}" 2>/dev/null || true
_OJ_WATCH_PID=""
t_assert_eq dead "$(t_pid_state "${watch_pid}")" "watchdog survived cleanup"

t_case "supervisor owns output and keeps earlier diagnostics"
OJ_DIR="${_WORK}/supervisor"
mkdir -p "${OJ_DIR}"
printf '%s\n' 'supervisor diagnostic' > "${OJ_DIR}/0.out"
marker="${OJ_DIR}/command.wrote"
OJ_CMDS=()
OJ_WORKERS=()
OJ_INT_POLICY='exit 130'
OJ_TERM_POLICY='exit 143'
OJ_TIMEOUT=''
oj_add bash -c 'printf "command output\n"; printf "ready\n" > "$1"; sleep 30' _ "${marker}"
_oj_launch 0
_OJ_SUPERVISOR_PID="${OJ_WORKERS[0]}"
t_assert_ok t_wait_file "${marker}"
t_assert_eq alive "$(t_pid_state "${_OJ_SUPERVISOR_PID}")" "supervisor exited before inspection"
_assert_owned_fds "${_OJ_SUPERVISOR_PID}" supervisor
t_assert_eq $'supervisor diagnostic\ncommand output' "$(cat "${OJ_DIR}/0.out")" "command erased earlier diagnostics"
command_pid="$(cat "${OJ_DIR}/0.pgid")"
t_assert_ok oj_reap
t_assert_eq dead "$(t_pid_state "${_OJ_SUPERVISOR_PID}")" "supervisor survived cleanup"
t_assert_eq dead "$(t_pid_state "${command_pid}")" "command survived cleanup"
_OJ_SUPERVISOR_PID=""
t_summary
