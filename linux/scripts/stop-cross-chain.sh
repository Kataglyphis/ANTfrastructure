#!/usr/bin/env bash
set -euo pipefail

# stop-cross-chain.sh — stop a cross chain and its children; walks the process tree, so a trap-less chain is cleaned too.

_STOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/01-core" && pwd)"
# shellcheck source=linux/scripts/01-core/logging.sh
source "${_STOP_DIR}/logging.sh"
# shellcheck source=linux/scripts/01-core/chain-lifecycle.sh
source "${_STOP_DIR}/chain-lifecycle.sh"

GRACE_SECS=15

usage() {
  cat <<'EOF'
Usage: stop-cross-chain.sh [options]

Cleanly stop a running cross build chain and its nerdctl/buildctl children.

Options:
  --timeout SECS   Seconds to wait for a graceful TERM before sending KILL
                   (default: 15)
  -h, --help       Show this help text

Finds the chain via its pidfile (build-cross-chain.sh writes it; override the
path with CROSS_CHAIN_PIDFILE) and falls back to pgrep on build-cross-chain.sh.
EOF
}

# The [.] trick only stops pgrep matching itself; a launcher whose argv names the chain must be excluded too.
_stop_self_and_ancestors() {
  local p="$$"
  while [ -n "${p}" ] && [ "${p}" -gt 1 ] 2>/dev/null; do
    printf '%s\n' "${p}"
    p="$(ps -o ppid= -p "${p}" 2>/dev/null | tr -d ' ')"
  done
}

# Wait up to GRACE_SECS for <pid> to disappear. Returns 0 if it exited.
_stop_wait_for_exit() {
  local pid="$1" waited=0
  while [ "${waited}" -lt "${GRACE_SECS}" ]; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
    waited=$((waited + 1))
  done
  kill -0 "${pid}" 2>/dev/null && return 1
  return 0
}

_stop_pid_tree() {
  local pid="$1"
  log "stopping cross chain pid ${pid} and its child build processes"
  kill -TERM "${pid}" 2>/dev/null || true
  chain_terminate_descendants TERM "${pid}"
  if _stop_wait_for_exit "${pid}"; then
    log "cross chain pid ${pid} stopped cleanly"
  else
    warn "pid ${pid} still alive after ${GRACE_SECS}s — sending KILL"
    chain_terminate_descendants KILL "${pid}"
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  # Sweep any descendants that outlived the orchestrator (re-parented builds).
  chain_terminate_descendants KILL "${pid}"
}

# Sets GRACE_SECS from --timeout; usage and unknown options exit here.
_stop_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) GRACE_SECS="${2:-15}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) warn "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
  done
}

# The pidfile names the chain while its pid lives; a dead one is removed. <var> gets the pid, or stays empty.
_stop_pidfile_target() {
  local pidfile="$1"
  local -n _found="$2"
  [ -f "${pidfile}" ] || return 0
  local pid
  pid="$(cat "${pidfile}" 2>/dev/null || true)"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    _found="${pid}"
    return 0
  fi
  warn "stale pidfile ${pidfile} (pid '${pid:-}' not running) — removing it"
  rm -f "${pidfile}" 2>/dev/null || true
  return 0
}

# No live pidfile: pgrep for the chain, skipping this script and its ancestors, whose argv may name it too.
_stop_pgrep_target() {
  local -n _found="$1"
  local exclude cand
  # Bracket trick: 'build-cross-chain[.]sh' avoids self-match.
  exclude=" $(_stop_self_and_ancestors | tr '\n' ' ') "
  for cand in $(pgrep -f 'build-cross-chain[.]sh' 2>/dev/null || true); do
    case "${exclude}" in *" ${cand} "*) continue ;; esac
    _found="${cand}"
    break
  done
  if [ -n "${_found}" ]; then log "no live pidfile — found chain via pgrep: pid ${_found}"; fi
  return 0
}

# Drops the pidfile when it still names the pid just stopped.
_stop_remove_pidfile_if() {
  local pidfile="$1" target="$2"
  if [ -f "${pidfile}" ] && [ "$(cat "${pidfile}" 2>/dev/null || true)" = "${target}" ]; then
    rm -f "${pidfile}" 2>/dev/null || true
  fi
  return 0
}

main() {
  _stop_parse_args "$@"

  local pidfile target=""
  pidfile="$(cross_chain_pidfile_path)"
  _stop_pidfile_target "${pidfile}" target
  [ -n "${target}" ] || _stop_pgrep_target target

  if [ -z "${target}" ]; then
    log "no running cross chain found (nothing to stop)"
    exit 0
  fi

  _stop_pid_tree "${target}"
  _stop_remove_pidfile_if "${pidfile}" "${target}"
  log "done."
}

main "$@"
