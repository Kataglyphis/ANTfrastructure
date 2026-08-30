#!/usr/bin/env bash
set -euo pipefail

# stop-cross-chain.sh — stop a cross chain AND its nerdctl/buildctl children.
# Finds the chain via pidfile, falls back to pgrep -f 'build-cross-chain[.]sh'
# (the [.] bracket trick avoids self-match). Walks the process subtree
# directly, so a trap-less orchestrator is still fully cleaned up.

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

# Exclude self and ancestors from the pgrep fallback: a launcher whose argv
# contains the string would be a false target. The [.] trick only stops pgrep
# from self-matching; ancestors need explicit filtering.
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

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) GRACE_SECS="${2:-15}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) warn "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
  done

  local pidfile target=""
  pidfile="$(cross_chain_pidfile_path)"

  if [ -f "${pidfile}" ]; then
    local pid; pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      target="${pid}"
    else
      warn "stale pidfile ${pidfile} (pid '${pid:-}' not running) — removing it"
      rm -f "${pidfile}" 2>/dev/null || true
    fi
  fi

  if [ -z "${target}" ]; then
    # Bracket trick: 'build-cross-chain[.]sh' avoids self-match; ancestors excluded above.
    local exclude cand
    exclude=" $(_stop_self_and_ancestors | tr '\n' ' ') "
    for cand in $(pgrep -f 'build-cross-chain[.]sh' 2>/dev/null || true); do
      case "${exclude}" in *" ${cand} "*) continue ;; esac
      target="${cand}"; break
    done
    [ -n "${target}" ] && log "no live pidfile — found chain via pgrep: pid ${target}"
  fi

  if [ -z "${target}" ]; then
    log "no running cross chain found (nothing to stop)"
    exit 0
  fi

  _stop_pid_tree "${target}"

  # Remove the pidfile if it still points at the pid we just stopped.
  if [ -f "${pidfile}" ] && [ "$(cat "${pidfile}" 2>/dev/null || true)" = "${target}" ]; then
    rm -f "${pidfile}" 2>/dev/null || true
  fi
  log "done."
}

main "$@"
