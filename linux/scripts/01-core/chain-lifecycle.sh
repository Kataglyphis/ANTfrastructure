# shellcheck shell=bash
# Run id, pidfile and child reaping shared by the orchestrator and stop-cross-chain.sh; dependency-free on purpose.
[ -n "${_CHAIN_LIFECYCLE_SH_LOADED:-}" ] && return 0
_CHAIN_LIFECYCLE_SH_LOADED=1

cross_run_id_generate() {
  local rand=""
  if [ -r /proc/sys/kernel/random/uuid ]; then
    rand="$(tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8)"
  fi
  [ -n "${rand}" ] || rand="$$${RANDOM}"
  printf '%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "${rand}"
}

# One exported CROSS_RUN_ID per orchestrator so consumers never invent their own; a caller's value wins.
cross_run_id_ensure() {
  if [ -z "${CROSS_RUN_ID:-}" ]; then
    CROSS_RUN_ID="$(cross_run_id_generate)"
  fi
  export CROSS_RUN_ID
}

# Independent of LOG_DIR, which the stopper does not know.
cross_chain_pidfile_path() {
  printf '%s' "${CROSS_CHAIN_PIDFILE:-${TMPDIR:-/tmp}/kata-cross-chain.pid}"
}

# chain_terminate_descendants <signal> <root_pid>: grandchildren first, never the root; best-effort per kill.
chain_terminate_descendants() {
  local sig="${1:-TERM}" root="${2:-$$}" kid
  # `pgrep -P` lists only direct children; recurse to reach the whole tree.
  for kid in $(pgrep -P "${root}" 2>/dev/null || true); do
    chain_terminate_descendants "${sig}" "${kid}"
    kill "-${sig}" "${kid}" 2>/dev/null || true
  done
}

# chain_status_kv_json "k=v,.." and chain_status_list_json "a,.." emit JSON bodies; values are shell-safe ids, unescaped.
_chain_status_next_item() {   # prints "<item>|<rest>"
  local csv="${1:-}" item
  item="${csv%%,*}"
  if [ "${item}" = "${csv}" ]; then printf '%s|' "${item}"; else printf '%s|%s' "${item}" "${csv#*,}"; fi
}

# One CSV walk for both JSON shapes; $2 names the per-item emitter.
_chain_status_walk_json() {
  local csv="${1:-}" emit="$2" out="" sep="" pair item
  while [ -n "${csv}" ]; do
    pair="$(_chain_status_next_item "${csv}")"
    item="${pair%%|*}"; csv="${pair#*|}"
    [ -n "${item}" ] || continue
    out="${out}${sep}$("${emit}" "${item}")"
    sep=", "
  done
  printf '%s' "${out}"
}

# Emitters: stdout IS the return value, so they never log.
_chain_status_emit_kv() { printf '"%s": "%s"' "${1%%=*}" "${1#*=}"; }
_chain_status_emit_str() { printf '"%s"' "$1"; }

chain_status_kv_json() { _chain_status_walk_json "${1:-}" _chain_status_emit_kv; }
chain_status_list_json() { _chain_status_walk_json "${1:-}" _chain_status_emit_str; }
