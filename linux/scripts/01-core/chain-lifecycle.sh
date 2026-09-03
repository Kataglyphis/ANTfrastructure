# shellcheck shell=bash
# chain-lifecycle.sh
# Shared orchestrator-lifecycle helpers for the cross build chain (Batch 5).
#
# Sourced by BOTH build-cross-chain.sh (the orchestrator) and
# stop-cross-chain.sh (the out-of-band stopper), so the run-id generation,
# the canonical pidfile location, and the child-reaping walk are defined in
# exactly ONE place and can never drift between the two.
#
# Pure bash, no heavy dependencies — safe to source from a lightweight stopper
# that does not want the full artifact-common stack.
[ -n "${_CHAIN_LIFECYCLE_SH_LOADED:-}" ] && return 0
_CHAIN_LIFECYCLE_SH_LOADED=1

# ==============================================================================
# cross_run_id_generate
#
# Echo a fresh, collision-resistant run id: a UTC timestamp plus 8 random hex
# chars (from the kernel uuid source when available, else $$/$RANDOM). Unlike
# the JS Date.now()/Math.random() pairing this replaces on other lanes, bash's
# `date`+uuid is monotonic-enough and unique per run for log namespacing.
# ==============================================================================
cross_run_id_generate() {
  local rand=""
  if [ -r /proc/sys/kernel/random/uuid ]; then
    rand="$(tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8)"
  fi
  [ -n "${rand}" ] || rand="$$${RANDOM}"
  printf '%s-%s' "$(date -u +%Y%m%d-%H%M%S)" "${rand}"
}

# ==============================================================================
# cross_run_id_ensure
#
# Generate ONE canonical CROSS_RUN_ID for this orchestrator process and export
# it so every downstream consumer (chain-status.json, resource-monitor rid,
# per-stage log markers in cross-stage-build.sh) shares the same value instead
# of each inventing its own `:-` default. Idempotent: a value already in the
# environment (a caller/wrapper override) is preserved.
# ==============================================================================
cross_run_id_ensure() {
  if [ -z "${CROSS_RUN_ID:-}" ]; then
    CROSS_RUN_ID="$(cross_run_id_generate)"
  fi
  export CROSS_RUN_ID
}

# ==============================================================================
# cross_chain_pidfile_path
#
# Canonical pidfile location for a running cross chain. build-cross-chain.sh
# writes its PID here at start and removes it on clean exit; stop-cross-chain.sh
# reads it to find a live chain. Both resolve the path through THIS function so
# they always agree. Override with CROSS_CHAIN_PIDFILE; default is a stable
# well-known path (independent of LOG_DIR, which the stopper does not know).
# ==============================================================================
cross_chain_pidfile_path() {
  printf '%s' "${CROSS_CHAIN_PIDFILE:-${TMPDIR:-/tmp}/kata-cross-chain.pid}"
}

# ==============================================================================
# chain_terminate_descendants <signal> <root_pid>
#
# Depth-first walk the process subtree rooted at <root_pid> and send <signal>
# to every DESCENDANT (grandchildren before children), never to <root_pid>
# itself. This is the child-reaping primitive behind O1: a killed orchestrator
# used to orphan its nerdctl/buildctl grandchildren, which then had to be pkill'd
# by hand (and left zombies). Every kill is best-effort — a process that already
# exited (or that we cannot signal) must never abort the sweep.
# ==============================================================================
chain_terminate_descendants() {
  local sig="${1:-TERM}" root="${2:-$$}" kid
  # `pgrep -P` lists only direct children; recurse to reach the whole tree.
  for kid in $(pgrep -P "${root}" 2>/dev/null || true); do
    chain_terminate_descendants "${sig}" "${kid}"
    kill "-${sig}" "${kid}" 2>/dev/null || true
  done
}

# ==============================================================================
# chain_status_kv_json  "k=v,k=v"   → `"k": "v", "k": "v"`
# chain_status_list_json "a,b"      → `"a", "b"`
#
# JSON bodies for the chain-status.json fields B3 adds (per-arch outcomes, gates
# that did not run). No IFS splitting; values are shell-safe ids, no escaping.
# ==============================================================================
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
