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

# <i>: command i into its log; a subshell, so its exit cannot end the runner, with the SIGINT a background job loses.
_oj_start() {
  local rc=0 pid end
  if [ "${OJ_GROUPS}" -eq 0 ]; then
    ( trap - INT QUIT; eval "${OJ_CMDS[$1]}" ) > "${OJ_DIR}/$1.out" 2>&1 < /dev/null || rc=$?
  else
    # Its own process group, killed whole once it ends: a test's children outlived their runs for days (2026-10-21).
    set -m
    ( trap - INT QUIT; eval "${OJ_CMDS[$1]}" ) > "${OJ_DIR}/$1.out" 2>&1 < /dev/null &
    pid=$!
    set +m
    printf '%s\n' "${pid}" > "${OJ_DIR}/$1.pgid"
    if [ -n "${OJ_TIMEOUT:-}" ]; then
      end=$((SECONDS + OJ_TIMEOUT))
      ( while kill -0 "${pid}" 2>/dev/null; do
          if [ "${SECONDS}" -ge "${end}" ]; then : > "${OJ_DIR}/$1.timeout"; kill -KILL -- "-${pid}" 2>/dev/null; fi
          sleep 1
        done ) &
    fi
    wait "${pid}" || rc=$?
    kill -KILL -- "-${pid}" 2>/dev/null || true
    rm -f "${OJ_DIR}/$1.pgid"
    [ ! -e "${OJ_DIR}/$1.timeout" ] || rc=124
  fi
  printf '%s\n' "${rc}" > "${OJ_DIR}/$1.rc.tmp"
  mv "${OJ_DIR}/$1.rc.tmp" "${OJ_DIR}/$1.rc"
}

# Kills every command still running; a runner calls it from its EXIT trap, so an interrupted run leaves none behind.
oj_reap() {
  local f
  [ -n "${OJ_DIR}" ] && [ -d "${OJ_DIR}" ] || return 0
  for f in "${OJ_DIR}"/*.pgid; do
    [ -f "${f}" ] && kill -KILL -- "-$(cat "${f}")" 2>/dev/null
  done
  return 0
}

# <report-fn>: hands <i> <rc> <log> to it for every ended command whose predecessors are all reported.
_oj_flush() {
  while [ "${OJ_NEXT}" -lt "${#OJ_CMDS[@]}" ] && [ -f "${OJ_DIR}/${OJ_NEXT}.rc" ]; do
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
  local jobs="$1" report="$2" first=" ${3:-} " last=" ${4:-} " i launched=0
  [ "${#OJ_CMDS[@]}" -gt 0 ] || return 0
  OJ_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ordered-jobs.XXXXXX")" || return 1
  for i in "${!OJ_CMDS[@]}"; do
    case "${first}" in *" ${i} "*) _oj_start "${i}"; launched=$((launched + 1)) ;; esac
  done
  for i in "${!OJ_CMDS[@]}"; do
    case "${first}${last}" in *" ${i} "*) continue ;; esac
    # Counted by rc files, never by wait: a caller's own background jobs are children of this shell too.
    while [ $((launched - $(_oj_ended))) -ge "${jobs}" ]; do
      sleep 0.2
      _oj_flush "${report}"
    done
    _oj_start "${i}" &
    launched=$((launched + 1))
  done
  while [ "$(_oj_ended)" -lt "${launched}" ]; do
    sleep 0.2
    _oj_flush "${report}"
  done
  for i in "${!OJ_CMDS[@]}"; do
    case "${last}" in *" ${i} "*) _oj_start "${i}" ;; esac
  done
  _oj_flush "${report}"
  rm -rf "${OJ_DIR}"
}
