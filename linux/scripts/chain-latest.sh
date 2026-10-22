#!/usr/bin/env bash
# The :latest chain as a bounded systemd user unit; a second one would share the host's disk and RAM.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE=start
case "${1:-}" in
  "") ;;
  --plan) MODE=plan ;;
  --run) MODE=run ;;
  *) echo "usage: chain-latest.sh [--plan|--run]" >&2; exit 2 ;;
esac

set -a
# shellcheck source=/dev/null
. "${REPO_ROOT}/linux/scripts/chain-latest.env" || exit 2
set +a
: "${CHAIN_WORKTREE:=${XDG_CACHE_HOME:-${HOME}/.cache}/kataglyphis/chain-worktree}"

free_gb() { df --output=avail -BG "$1" 2>/dev/null | tail -n 1 | tr -dc '0-9'; }
mem_gb() { awk '/^MemAvailable:/ { printf "%d", $2 / 1048576 }' /proc/meminfo; }
# The divisor cross_build_mem_divisor() injects under --parallel-archs: each build sizes its job pools to RAM / this.
mem_divisor() {
  local n max
  n="$(printf '%s' "${CHAIN_ARCHES}" | awk -F, '{ print NF }')"
  max="${MAX_PARALLEL_ARCHS}"; [ "${n}" -lt "${max}" ] && max="${n}"
  if [ "${max}" -gt 1 ]; then echo $(( max * PAR_INTRA_STEP_BUDGET )); else echo 1; fi
}
unit_active() { systemctl --user is-active --quiet "${CHAIN_UNIT}"; }

print_plan() {
  echo "chain-latest plan"
  echo "  profile:   ${REPO_ROOT}/linux/scripts/chain-latest.env"
  echo "  worktree:  ${CHAIN_WORKTREE} (at ${CHAIN_REF})"
  echo "  unit:      ${CHAIN_UNIT}, RuntimeMaxSec=${CHAIN_RUNTIME_MAX}"
  echo "  arches:    ${CHAIN_ARCHES}, stages from ${CHAIN_FROM_STAGE}"
  echo "  parallel:  MAX_PARALLEL_ARCHS=${MAX_PARALLEL_ARCHS} PAR_INTRA_STEP_BUDGET=${PAR_INTRA_STEP_BUDGET} PUSH_MAX_ATTEMPTS=${PUSH_MAX_ATTEMPTS} RUNTIME_GATE_JOBS=${RUNTIME_GATE_JOBS}"
  echo "  divisor:   BUILD_MEM_DIVISOR=$(mem_divisor) (min(arches, ${MAX_PARALLEL_ARCHS}) x PAR_INTRA_STEP_BUDGET, docs/build-parallelism-memory-tuning.md)"
  echo "  command:   bash linux/scripts/build-cross-chain.sh --target-arches ${CHAIN_ARCHES} --parallel-archs --from-stage ${CHAIN_FROM_STAGE}"
  echo "  disk:      $(free_gb "${HOME}")G free on ${HOME} (gate ${CHAIN_MIN_FREE_GB}G)"
  echo "  memory:    $(mem_gb)G available (gate ${CHAIN_MIN_MEM_GB}G)"
  if unit_active; then echo "  unit:      ACTIVE, a start would refuse"; else echo "  unit:      inactive"; fi
}

check_capacity() {
  local free mem
  free="$(free_gb "${HOME}")"; mem="$(mem_gb)"
  [ "${free:-0}" -ge "${CHAIN_MIN_FREE_GB}" ] || { echo "chain-latest: ${free:-?}G free is below the ${CHAIN_MIN_FREE_GB}G gate; not starting" >&2; return 4; }
  [ "${mem:-0}" -ge "${CHAIN_MIN_MEM_GB}" ] || { echo "chain-latest: ${mem:-?}G available is below the ${CHAIN_MIN_MEM_GB}G gate; not starting" >&2; return 4; }
}

refresh_worktree() {
  if [ ! -e "${CHAIN_WORKTREE}/.git" ]; then
    git -C "${REPO_ROOT}" fetch -q origin && git -C "${REPO_ROOT}" worktree add -q --detach "${CHAIN_WORKTREE}" "${CHAIN_REF}" || return 1
  fi
  git -C "${CHAIN_WORKTREE}" fetch -q origin && git -C "${CHAIN_WORKTREE}" checkout -q --detach "${CHAIN_REF}" || return 1
  git -C "${CHAIN_WORKTREE}" submodule update --init --recursive -q || return 1
  mkdir -p "${CHAIN_WORKTREE}/out"
}

start_unit() {
  local log
  log="${CHAIN_WORKTREE}/out/chain-latest-$(date +%Y%m%d-%H%M)-${CHAIN_FROM_STAGE}.log" || return 1
  systemctl --user reset-failed "${CHAIN_UNIT}" 2>/dev/null || true
  systemd-run --user --unit="${CHAIN_UNIT}" -p "RuntimeMaxSec=${CHAIN_RUNTIME_MAX}" \
    --working-directory="${CHAIN_WORKTREE}" \
    -E "PATH=${PATH}" -E "CHAIN_LOG=${log}" -E "CHAIN_ARCHES=${CHAIN_ARCHES}" -E "CHAIN_FROM_STAGE=${CHAIN_FROM_STAGE}" \
    -E "MAX_PARALLEL_ARCHS=${MAX_PARALLEL_ARCHS}" -E "PAR_INTRA_STEP_BUDGET=${PAR_INTRA_STEP_BUDGET}" \
    -E "PUSH_MAX_ATTEMPTS=${PUSH_MAX_ATTEMPTS}" -E "RUNTIME_GATE_JOBS=${RUNTIME_GATE_JOBS}" \
    bash -c 'exec bash linux/scripts/chain-latest.sh --run' || return 1
  echo "chain-latest: started ${CHAIN_UNIT}; log ${log}"
}

run_body() {
  local log="${CHAIN_LOG:?chain-latest --run needs CHAIN_LOG from the unit}" sampler rc=0
  mkdir -p "$(dirname "${log}")"
  ( while sleep 60; do printf '%s %s\n' "$(date +%s)" "$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"; done >> "${log%.log}.mem.tsv" ) &
  sampler=$!
  bash linux/scripts/build-cross-chain.sh --target-arches "${CHAIN_ARCHES}" --parallel-archs --from-stage "${CHAIN_FROM_STAGE}" \
    > "${log}" 2>&1 < /dev/null || rc=$?
  kill "${sampler}" 2>/dev/null
  wait "${sampler}" 2>/dev/null
  exit "${rc}"
}

case "${MODE}" in
  run) run_body ;;
  plan) print_plan ;;
  start)
    print_plan
    check_capacity || exit $?
    if unit_active; then echo "chain-latest: ${CHAIN_UNIT} is already running; stop it first" >&2; exit 5; fi
    refresh_worktree || { echo "chain-latest: the worktree could not be refreshed to ${CHAIN_REF}" >&2; exit 6; }
    start_unit
    ;;
esac
