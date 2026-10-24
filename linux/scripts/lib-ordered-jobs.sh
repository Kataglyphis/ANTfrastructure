# shellcheck shell=bash
# Recorded commands run N at a time, each into its own log; their reports come whole, in the order recorded.
[ -n "${_ORDERED_JOBS_SH_LOADED:-}" ] && return 0
_ORDERED_JOBS_SH_LOADED=1

OJ_CMDS=()
OJ_DIR=""
OJ_NEXT=0

# <var>: the job count that variable asks for, default one per CPU; rc 2 on anything but a positive integer.
oj_count() {
  local value="${!1:-}"
  [ -n "${value}" ] || value="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  case "${value}" in
    ''|*[!0-9]*|0)
      printf '%s=%s is not a positive integer\n' "$1" "${value}" >&2
      return 2
      ;;
  esac
  printf '%s' "${value}"
}

# <command...>: record one command; its index is its place in the report.
oj_add() {
  OJ_CMDS+=("$(printf '%q ' "$@")")
}

# Git Bash has no process groups to kill; there a command runs as a plain subshell, as before.
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) OJ_GROUPS=0 ;; *) OJ_GROUPS=1 ;; esac

OJ_WORKERS=()
OJ_SIGNAL=0
OJ_LAUNCHING=0

_oj_capture_policy() { _OJ_CAPTURED_POLICY="$2"; }

_oj_signal_policy() {
  local definition="$1" status="$2"
  _OJ_CAPTURED_POLICY="exit ${status}"
  [ -z "${definition}" ] || eval "_oj_capture_policy ${definition#trap }"
}

# An ignored caller INT must stay ignored in every owned child, including the watchdog.
_oj_child_int_trap() {
  if [ -z "${OJ_INT_POLICY}" ]; then
    trap '' INT
  elif [ "$1" = - ]; then
    trap - INT
  else
    trap ':' INT
  fi
}

_oj_dispatch_signal() {
  local pending="${OJ_SIGNAL}" policy
  [ "${pending}" -ne 0 ] || return 0
  OJ_SIGNAL=0
  [ "${OJ_PARENT_SIGNALS:-0}" -ne 0 ] || exit "${pending}"
  case "${pending}" in 130) policy="${OJ_INT_POLICY}" ;; *) policy="${OJ_TERM_POLICY}" ;; esac
  eval "${policy}"
}

_oj_signal() {
  [ "${OJ_REAPING:-0}" -eq 0 ] || return 0
  OJ_SIGNAL="$1"
  if [ "${OJ_LAUNCHING}" -eq 0 ]; then _oj_dispatch_signal; fi
}

_oj_restore_signal() {
  local original="$1" active="$2" signal="$3"
  [ "$(trap -p "${signal}")" = "${active}" ] || return 0
  if [ -n "${original}" ]; then eval "${original}"; else trap - "${signal}"; fi
}

_oj_wait_gone() {
  local target="$1" deadline
  deadline=$((SECONDS + $2))
  while kill -0 -- "${target}" 2>/dev/null; do
    [ "${SECONDS}" -lt "${deadline}" ] || return 1
    sleep 0.01
  done
}

_oj_stop_owned() {
  local pid="${1:-}" target
  [ -n "${pid}" ] || return 0
  target="${pid}"
  [ "${OJ_GROUPS}" -eq 0 ] || target="-${pid}"
  kill -TERM -- "${target}" 2>/dev/null || true
  if ! _oj_wait_gone "${target}" 2; then
    kill -KILL -- "${target}" 2>/dev/null || true
    if ! _oj_wait_gone "${target}" 5; then
      printf 'ERROR: ordered job process %s did not disappear after KILL\n' "${target}" >&2
      return 1
    fi
  fi
  wait "${pid}" 2>/dev/null || true
}

_oj_worker_reap() {
  local status=0
  if _oj_stop_owned "${_OJ_WATCH_PID:-}"; then
    _OJ_WATCH_PID=""
    rm -f "${OJ_DIR}/${_OJ_INDEX}.watch"
  else status=1; fi
  if _oj_stop_owned "${_OJ_COMMAND_PID:-}"; then
    _OJ_COMMAND_PID=""
    rm -f "${OJ_DIR}/${_OJ_INDEX}.pgid"
  else status=1; fi
  return "${status}"
}

_oj_worker_exit() {
  OJ_REAPING=1
  trap '' INT TERM USR1
  trap - EXIT
  local verdict="$1" supervisor_status=0
  if [ "${verdict}" -eq 0 ] && [ "${_OJ_COMPLETED:-0}" -eq 0 ]; then verdict=1; supervisor_status=1; fi
  if ! _oj_worker_reap; then verdict=1; supervisor_status=1; fi
  if [ -d "${OJ_DIR}" ]; then
    printf '%s\n' "${verdict}" > "${OJ_DIR}/${_OJ_INDEX}.rc.tmp"
    mv "${OJ_DIR}/${_OJ_INDEX}.rc.tmp" "${OJ_DIR}/${_OJ_INDEX}.rc"
  fi
  exit "${supervisor_status}"
}

_oj_spawn_command() {
  local index="$1"
  OJ_LAUNCHING=1
  _OJ_OWNER_PID=$BASHPID
  [ "${OJ_GROUPS}" -eq 0 ] || set -m
  (
    set +m
    trap - QUIT TERM USR1 EXIT
    _oj_child_int_trap -
    while [ ! -f "${OJ_DIR}/${index}.go" ]; do
      kill -0 "${_OJ_OWNER_PID}" 2>/dev/null || exit 143
      [ ! -e "${OJ_DIR}/cancelled" ] || exit 143
      sleep 0.01
    done
    [ ! -e "${OJ_DIR}/cancelled" ] || exit 143
    eval "${OJ_CMDS[${index}]}"
  ) >> "${OJ_DIR}/${index}.out" 2>&1 < /dev/null &
  _OJ_COMMAND_PID=$!
  [ "${OJ_GROUPS}" -eq 0 ] || set +m
  OJ_LAUNCHING=0
  _oj_dispatch_signal
  printf '%s\n' "${_OJ_COMMAND_PID}" > "${OJ_DIR}/${index}.pgid"
  [ ! -e "${OJ_DIR}/cancelled" ] || exit 143
  : > "${OJ_DIR}/${index}.go"
}

_oj_start_watchdog() {
  local index="$1" end
  end=$((SECONDS + OJ_TIMEOUT))
  OJ_LAUNCHING=1
  set -m
  (
    set +m
    trap - QUIT TERM USR1 EXIT
    _oj_child_int_trap -
    while kill -0 "${_OJ_COMMAND_PID}" 2>/dev/null; do
      if [ "${SECONDS}" -ge "${end}" ]; then
        : > "${OJ_DIR}/${index}.timeout"
        kill -USR1 "${_OJ_OWNER_PID}" 2>/dev/null
        break
      fi
      sleep 1
    done
  ) </dev/null >> "${OJ_DIR}/${index}.out" 2>&1 &
  _OJ_WATCH_PID=$!
  printf '%s\n' "${_OJ_WATCH_PID}" > "${OJ_DIR}/${index}.watch"
  set +m
  OJ_LAUNCHING=0
  _oj_dispatch_signal
}

# The supervisor registers its child before releasing it and joins both the command and watchdog before reporting.
_oj_start() {
  local index="$1" rc=0
  OJ_SIGNAL=0; OJ_LAUNCHING=0; OJ_PARENT_SIGNALS=0; _OJ_INDEX="$1"
  _OJ_COMMAND_PID=""; _OJ_WATCH_PID=""; _OJ_COMPLETED=0; OJ_REAPING=0
  trap '_oj_worker_exit $?' EXIT
  trap '_oj_signal 143' TERM
  trap ':' QUIT
  _oj_child_int_trap ':'
  trap '_oj_signal 124' USR1
  _oj_spawn_command "${index}"
  if [ "${OJ_GROUPS}" -ne 0 ] && [ -n "${OJ_TIMEOUT:-}" ]; then _oj_start_watchdog "${index}"; fi
  while :; do
    rc=0; wait "${_OJ_COMMAND_PID}" || rc=$?
    kill -0 "${_OJ_COMMAND_PID}" 2>/dev/null || break
  done
  _OJ_COMPLETED=1
  exit "${rc}"
}

_oj_launch() {
  local index="$1"
  OJ_LAUNCHING=1
  ( trap - TERM USR1 EXIT; trap ':' QUIT; _oj_child_int_trap ':'; _oj_start "${index}" ) </dev/null >> "${OJ_DIR}/${index}.out" 2>&1 &
  OJ_WORKERS[${index}]=$!
  OJ_LAUNCHING=0
  _oj_dispatch_signal
}

_oj_recover_worker() {
  local index="$1" kind status=0
  for kind in watch pgid; do
    if [ -s "${OJ_DIR}/${index}.${kind}" ]; then
      _oj_stop_owned "$(cat "${OJ_DIR}/${index}.${kind}")" || status=1
    fi
  done
  printf 'ERROR: ordered job supervisor exited before completing cleanup\n' >> "${OJ_DIR}/${index}.out"
  printf '1\n' > "${OJ_DIR}/${index}.rc"
  return "${status}"
}

_oj_join() {
  local index="$1" pid="${OJ_WORKERS[$1]:-}" status=0
  [ -n "${pid}" ] || return 0
  wait "${pid}" 2>/dev/null || status=$?
  unset "OJ_WORKERS[${index}]"
  if [ ! -f "${OJ_DIR}/${index}.rc" ]; then
    _oj_recover_worker "${index}" || return 1
    return 1
  fi
  case "${status}" in
    0) return 0 ;;
    130|143) [ ! -e "${OJ_DIR}/cancelled" ] || return 0 ;;
  esac
  _oj_recover_worker "${index}" || return 1
  return "${status}"
}

_oj_collect_worker_failures() {
  local index
  for index in "${!OJ_WORKERS[@]}"; do
    if [ ! -f "${OJ_DIR}/${index}.rc" ] && ! kill -0 "${OJ_WORKERS[$index]}" 2>/dev/null; then
      _oj_join "${index}" || true
    fi
  done
}

# Cancellation stays visible until every registered supervisor has stopped publishing or launching commands.
oj_reap() {
  local index status=0
  [ -n "${OJ_DIR}" ] && [ -d "${OJ_DIR}" ] || return 0
  OJ_REAPING=1
  : > "${OJ_DIR}/cancelled"
  for index in "${!OJ_WORKERS[@]}"; do
    [ -f "${OJ_DIR}/${index}.rc" ] || kill -TERM "${OJ_WORKERS[$index]}" 2>/dev/null || true
  done
  for index in "${!OJ_WORKERS[@]}"; do _oj_join "${index}" || status=1; done
  OJ_REAPING=0
  return "${status}"
}

# <report-fn>: hands <i> <rc> <log> to it for every ended command whose predecessors are all reported.
_oj_flush() {
  while [ "${OJ_NEXT}" -lt "${#OJ_CMDS[@]}" ] && [ -f "${OJ_DIR}/${OJ_NEXT}.rc" ]; do
    _oj_join "${OJ_NEXT}" || true
    "$1" "${OJ_NEXT}" "$(cat "${OJ_DIR}/${OJ_NEXT}.rc")" "${OJ_DIR}/${OJ_NEXT}.out"
    OJ_NEXT=$((OJ_NEXT + 1))
  done
}

_oj_ended() {
  local f n=0
  for f in "${OJ_DIR}"/*.rc; do [ -e "${f}" ] && n=$((n + 1)); done
  printf '%s' "${n}"
}

# <jobs> <report-fn> [first] [last]: every recorded command; first and last are index lists run alone, before and after the rest.
oj_run() {
  local jobs="$1" report="$2" first=" ${3:-} " last=" ${4:-} " i launched=0 old_term old_int active_term active_int
  old_term="$(trap -p TERM)"; old_int="$(trap -p INT)"
  OJ_SIGNAL=0; OJ_LAUNCHING=0; OJ_WORKERS=()
  [ "${#OJ_CMDS[@]}" -gt 0 ] || return 0
  OJ_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ordered-jobs.XXXXXX")" || return 1
  OJ_PARENT_SIGNALS=1
  _oj_signal_policy "${old_term}" 143; OJ_TERM_POLICY="${_OJ_CAPTURED_POLICY}"
  _oj_signal_policy "${old_int}" 130; OJ_INT_POLICY="${_OJ_CAPTURED_POLICY}"
  [ -z "${OJ_TERM_POLICY}" ] || trap '_oj_signal 143' TERM
  [ -z "${OJ_INT_POLICY}" ] || trap '_oj_signal 130' INT
  active_term="$(trap -p TERM)"; active_int="$(trap -p INT)"
  for i in "${!OJ_CMDS[@]}"; do
    case "${first}" in *" ${i} "*) _oj_launch "${i}"; _oj_join "${i}"; launched=$((launched + 1)) ;; esac
  done
  for i in "${!OJ_CMDS[@]}"; do
    case "${first}${last}" in *" ${i} "*) continue ;; esac
    # Counted by rc files, never by wait: a caller's own background jobs are children of this shell too.
    while [ $((launched - $(_oj_ended))) -ge "${jobs}" ]; do
      _oj_collect_worker_failures
      sleep 0.2
      _oj_flush "${report}"
    done
    _oj_launch "${i}"
    launched=$((launched + 1))
  done
  while [ "$(_oj_ended)" -lt "${launched}" ]; do
    _oj_collect_worker_failures
    sleep 0.2
    _oj_flush "${report}"
  done
  for i in "${!OJ_CMDS[@]}"; do
    case "${last}" in *" ${i} "*) _oj_launch "${i}"; _oj_join "${i}" ;; esac
  done
  _oj_flush "${report}"
  for i in "${!OJ_WORKERS[@]}"; do _oj_join "${i}"; done
  rm -rf "${OJ_DIR}"
  OJ_DIR=""
  _oj_restore_signal "${old_term}" "${active_term}" TERM
  _oj_restore_signal "${old_int}" "${active_int}" INT
}
