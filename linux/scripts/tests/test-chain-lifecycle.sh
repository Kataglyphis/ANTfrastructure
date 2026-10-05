#!/usr/bin/env bash
# chain-lifecycle.sh (O1/O2: run ids, pidfile, subtree kill) and build-cross-chain.sh's log and disk guards.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${TESTS_DIR}/../01-core"
source "${TESTS_DIR}/test-harness.sh"
source "${CORE_DIR}/chain-lifecycle.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# O2: run-id generation
t_case "cross_run_id_generate returns a non-empty timestamped id"
rid="$(cross_run_id_generate)"
t_assert_contains "${rid}" "-" "id must join a timestamp and a random suffix"
# Shape: YYYYMMDD-HHMMSS-<hex/rand>  (leading 8-digit date).
case "${rid}" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*) t_assert_eq "1" "1" ;;
  *) t_assert_eq "YYYYMMDD-..." "${rid}" "id must start with an 8-digit date" ;;
esac

t_case "cross_run_id_generate is unique across calls"
a="$(cross_run_id_generate)"; b="$(cross_run_id_generate)"
if [ "${a}" != "${b}" ]; then t_assert_eq "1" "1"; else
  t_assert_eq "distinct" "same" "two generated ids collided: ${a}"
fi

t_case "cross_run_id_ensure sets, exports, and is idempotent"
unset CROSS_RUN_ID || true
cross_run_id_ensure
first="${CROSS_RUN_ID}"
t_assert_ok test -n "${first}"
# exported?
t_assert_contains "$(export -p | grep 'CROSS_RUN_ID' || true)" "CROSS_RUN_ID" "must be exported"
cross_run_id_ensure
t_assert_eq "${first}" "${CROSS_RUN_ID}" "a second ensure must not regenerate"

t_case "cross_run_id_ensure honors a pre-set CROSS_RUN_ID"
CROSS_RUN_ID="my-custom-run"
cross_run_id_ensure
t_assert_eq "my-custom-run" "${CROSS_RUN_ID}" "a caller override must win"
unset CROSS_RUN_ID || true

# O2: pidfile path
t_case "cross_chain_pidfile_path honors CROSS_CHAIN_PIDFILE"
t_assert_eq "/run/mychain.pid" \
  "$(CROSS_CHAIN_PIDFILE=/run/mychain.pid cross_chain_pidfile_path)"

t_case "cross_chain_pidfile_path defaults under TMPDIR"
t_assert_eq "/custom/tmp/kata-cross-chain.pid" \
  "$(TMPDIR=/custom/tmp CROSS_CHAIN_PIDFILE= cross_chain_pidfile_path)"

# O1: TERM a root's subtree: its leaf dies, and the root's parent (this test) is never targeted
t_case "chain_terminate_descendants TERMs the descendant subtree"
t_needs "pgrep (procps)" command -v pgrep
bash -c 'sleep 30 & echo $! > "'"${workdir}"'/leaf.pid"; wait' &
root=$!
# Give the child time to spawn its leaf and record the pid.
_waited=0
while [ ! -s "${workdir}/leaf.pid" ] && [ "${_waited}" -lt 20 ]; do sleep 0.1; _waited=$((_waited + 1)); done
leaf="$(cat "${workdir}/leaf.pid" 2>/dev/null || true)"
t_assert_ok test -n "${leaf}"
chain_terminate_descendants TERM "${root}"
# The leaf (a descendant of root) must terminate; wait briefly for signal.
_waited=0
while kill -0 "${leaf}" 2>/dev/null && [ "${_waited}" -lt 25 ]; do sleep 0.1; _waited=$((_waited + 1)); done
t_assert_fails kill -0 "${leaf}"
kill "${root}" 2>/dev/null || true
wait "${root}" 2>/dev/null || true

# STALE-LOG: build-cross-chain.sh runs main at the bottom, so its shipped text is evaluated piece by piece
CHAIN_SH="${TESTS_DIR}/../build-cross-chain.sh"

t_case "LOG_DIR defaults to out/build-logs so both guards are armed without --log-dir"
# An empty default leaves the truncate marker and the archiver inert without --log-dir.
t_assert_eq "/repo/out/build-logs" "$(
  unset LOG_DIR
  REPO_ROOT=/repo
  eval "$(grep -m1 '^LOG_DIR=' "${CHAIN_SH}")"
  printf '%s' "${LOG_DIR}"
)" "the default must land in the documented out/build-logs"

t_case "an explicit LOG_DIR still wins over the default"
t_assert_eq "/custom/logs" "$(
  LOG_DIR=/custom/logs
  REPO_ROOT=/repo
  eval "$(grep -m1 '^LOG_DIR=' "${CHAIN_SH}")"
  printf '%s' "${LOG_DIR}"
)" "--log-dir / an exported LOG_DIR must not be overridden"

# The archiver, with logging stubbed: only chain-lifecycle.sh is sourced.
log()  { :; }
warn() { :; }
eval "$(sed -n '/^_chain_live_sibling_pid()/,/^}/p' "${CHAIN_SH}")"
# Away from the host's real pidfile: a running chain there would make the archiver refuse.
cross_chain_pidfile_path() { printf '%s' "${TMPDIR:-/tmp}/no-such-chain.$$.pid"; }
eval "$(sed -n '/^_chain_archive_prev_logs() {$/,/^}$/p' "${CHAIN_SH}")"
t_case "the archiver function was extracted from the shipped script"
t_assert_eq "function" "$(type -t _chain_archive_prev_logs || true)"

t_case "archiving moves marker-owned stage logs into archive/<prior-run>/"
LOG_DIR="${workdir}/logs-a"; mkdir -p "${LOG_DIR}"
printf 'wave5j android failure\n' > "${LOG_DIR}/android-amd64.log"
printf '%s' '20260822-155127-8fd813db'  > "${LOG_DIR}/android-amd64.log.run"
CROSS_RUN_ID="20260823-090000-deadbeef"
_chain_archive_prev_logs
t_assert_ok   test -f "${LOG_DIR}/archive/20260822-155127-8fd813db/android-amd64.log"
t_assert_ok   test -f "${LOG_DIR}/archive/20260822-155127-8fd813db/android-amd64.log.run"
t_assert_fails test -e "${LOG_DIR}/android-amd64.log"

t_case "archiving leaves foreign logs (the operator's live tee transcript) alone"
# The running chain's tee transcript lives there too; moving it would redirect the operator's log.
LOG_DIR="${workdir}/logs-b"; mkdir -p "${LOG_DIR}"
printf 'stale stage log\n' > "${LOG_DIR}/media-arm64.log"
printf '%s' 'prior-run'    > "${LOG_DIR}/media-arm64.log.run"
printf 'operator transcript\n' > "${LOG_DIR}/cross-chain-wave5o.log"
_chain_archive_prev_logs
t_assert_ok   test -f "${LOG_DIR}/cross-chain-wave5o.log"
t_assert_fails test -e "${LOG_DIR}/archive/prior-run/cross-chain-wave5o.log"
t_assert_ok   test -f "${LOG_DIR}/archive/prior-run/media-arm64.log"

t_case "a log dir holding no marker-owned logs is left untouched"
LOG_DIR="${workdir}/logs-c"; mkdir -p "${LOG_DIR}"
printf 'operator transcript\n' > "${LOG_DIR}/cross-chain-wave5p.log"
_chain_archive_prev_logs
t_assert_ok    test -f "${LOG_DIR}/cross-chain-wave5p.log"
t_assert_fails test -d "${LOG_DIR}/archive"

t_case "the CURRENT run's own logs are never archived"
LOG_DIR="${workdir}/logs-d"; mkdir -p "${LOG_DIR}"
printf 'current run\n' > "${LOG_DIR}/sdk-amd64.log"
printf '%s' "${CROSS_RUN_ID}" > "${LOG_DIR}/sdk-amd64.log.run"
_chain_archive_prev_logs
t_assert_ok    test -f "${LOG_DIR}/sdk-amd64.log"
t_assert_fails test -d "${LOG_DIR}/archive"

# The log dir must exist before the first writer; an uncreatable one disables logging, never kills the chain
eval "$(sed -n '/^_chain_prepare_log_dir() {$/,/^}$/p' "${CHAIN_SH}")"
REPO_ROOT="${TESTS_DIR}/../../.."

t_case "preparing the log dir creates it (fresh clone has no out/)"
LOG_DIR="${workdir}/fresh/out/build-logs"
_chain_prepare_log_dir
t_assert_ok test -d "${LOG_DIR}"
t_assert_eq "${workdir}/fresh/out/build-logs" "${LOG_DIR}" "a writable dir must be kept"

t_case "an uncreatable log dir disables logging instead of failing the run"
t_needs "chmod mode bits (Git Bash derives them from the file)" t_posix_modes
mkdir -p "${workdir}/ro"
if [ "$(id -u)" != "0" ] && chmod 500 "${workdir}/ro" 2>/dev/null; then
  LOG_DIR="${workdir}/ro/logs"
  _chain_prepare_log_dir
  t_assert_eq "" "${LOG_DIR}" "an unwritable dir must fall back to no per-stage logs"
  chmod 700 "${workdir}/ro" 2>/dev/null || true
else
  t_assert_eq "1" "1"   # root (or a permissionless fs) cannot exercise this
fi

# cross_stage_log_redirect truncates once per run id, so a stage log holds only the current run
source "${CORE_DIR}/cross-stage-build.sh"

t_case "cross_stage_log_redirect appends within a run and truncates a new one"
LOG_DIR="${workdir}/logs-e"
CROSS_RUN_ID="run-1"
f="$(cross_stage_log_redirect media-arm64)"
t_assert_eq "${LOG_DIR}/media-arm64.log" "${f}"
printf 'run-1 line\n' >> "${f}"
f="$(cross_stage_log_redirect media-arm64)"          # same run: must NOT wipe
t_assert_contains "$(cat "${f}")" "run-1 line" "a second stage in the same run must append"
CROSS_RUN_ID="run-2"
f="$(cross_stage_log_redirect media-arm64)"          # new run: must wipe
t_assert_eq "" "$(cat "${f}")" "a NEW run must start from an empty log"
t_assert_eq "run-2" "$(cat "${f}.run")" "the marker must carry the new run id"

t_case "an empty LOG_DIR (opt-out) still yields no log path"
LOG_DIR=""
t_assert_eq "" "$(cross_stage_log_redirect media-arm64)"

# Bounded archive retention: the archiver only adds, on every start, so retention must prune only what it owns
log()  { :; }    # re-stub: sourcing cross-stage-build.sh may pull in the real ones
warn() { :; }
is_dry_run() { [ "${DRY_RUN:-0}" = "1" ]; }   # stands in for build-helpers.sh's
eval "$(sed -n '/^_chain_prune_archived_logs() {$/,/^}$/p' "${CHAIN_SH}")"
t_case "the retention function was extracted from the shipped script"
t_assert_eq "function" "$(type -t _chain_prune_archived_logs || true)"

# One non-empty dir per run id, mtimes oldest-first: retention orders by mtime, as the id shapes do not sort together.
_mk_archive() {
  local root="$1"; shift
  local id i=0
  for id in "$@"; do
    mkdir -p "${root}/archive/${id}"
    printf 'stage log\n' > "${root}/archive/${id}/media-amd64.log"
    touch -m -d "@$(( 1700000000 + i * 3600 ))" "${root}/archive/${id}"
    i=$(( i + 1 ))
  done
}

t_case "retention keeps the newest N run dirs and removes the older ones"
LOG_DIR="${workdir}/ret-a"
_mk_archive "${LOG_DIR}" 20260101-000000-a1 20260102-000000-a2 \
                         20260103-000000-a3 20260104-000000-a4
CROSS_LOG_ARCHIVE_KEEP=2
CROSS_RUN_ID="20260105-000000-current"
_chain_prune_archived_logs
t_assert_fails test -e "${LOG_DIR}/archive/20260101-000000-a1"
t_assert_fails test -e "${LOG_DIR}/archive/20260102-000000-a2"
t_assert_ok    test -f "${LOG_DIR}/archive/20260103-000000-a3/media-amd64.log"
t_assert_ok    test -f "${LOG_DIR}/archive/20260104-000000-a4/media-amd64.log"

t_case "the default keeps 5 run dirs with no env knob set at all"
LOG_DIR="${workdir}/ret-f"
_mk_archive "${LOG_DIR}" 20260101-000000-f1 20260102-000000-f2 20260103-000000-f3 \
                         20260104-000000-f4 20260105-000000-f5 20260106-000000-f6 \
                         20260107-000000-f7
unset CROSS_LOG_ARCHIVE_KEEP
_chain_prune_archived_logs
t_assert_eq "5" "$(find "${LOG_DIR}/archive" -mindepth 1 -maxdepth 1 -type d | wc -l)" \
  "the unset default must be a small, sane number of run dirs"
t_assert_fails test -e "${LOG_DIR}/archive/20260102-000000-f2"
t_assert_ok    test -d "${LOG_DIR}/archive/20260107-000000-f7"

t_case "retention never touches a non-run-id sibling under archive/"
# Neither may be a candidate, nor count against the keep budget.
LOG_DIR="${workdir}/ret-b"
_mk_archive "${LOG_DIR}" 20260101-000000-b1 20260102-000000-b2 20260103-000000-b3
mkdir -p "${LOG_DIR}/archive/wave5o-transcripts"
printf 'x\n' > "${LOG_DIR}/archive/wave5o-transcripts/keep-me.log"
printf 'x\n' > "${LOG_DIR}/archive/notes.txt"
CROSS_LOG_ARCHIVE_KEEP=1
_chain_prune_archived_logs
t_assert_fails test -e "${LOG_DIR}/archive/20260101-000000-b1"
t_assert_fails test -e "${LOG_DIR}/archive/20260102-000000-b2"
t_assert_ok    test -d "${LOG_DIR}/archive/20260103-000000-b3"
t_assert_ok    test -f "${LOG_DIR}/archive/wave5o-transcripts/keep-me.log"
t_assert_ok    test -f "${LOG_DIR}/archive/notes.txt"

t_case 'a PID-named run dir (the ${CROSS_RUN_ID:-$$} fallback) is prunable by age'
# A PID-named dir is a run dir too, and only mtime ranks it: by name a leading 3 sorts after every 2026 id.
LOG_DIR="${workdir}/ret-h"
_mk_archive "${LOG_DIR}" 365161 20260101-000000-h1 1847483 20260102-000000-h2
CROSS_LOG_ARCHIVE_KEEP=2
_chain_prune_archived_logs
t_assert_fails test -e "${LOG_DIR}/archive/365161"
t_assert_fails test -e "${LOG_DIR}/archive/20260101-000000-h1"
t_assert_ok    test -d "${LOG_DIR}/archive/1847483"
t_assert_ok    test -d "${LOG_DIR}/archive/20260102-000000-h2"

t_case "retention skips a symlinked run dir instead of following it"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
# Named to sort oldest, so a follow-the-link bug would delete it and its target first.
LOG_DIR="${workdir}/ret-c"
_mk_archive "${LOG_DIR}" 20260101-000000-c1 20260102-000000-c2
mkdir -p "${workdir}/outside-c"
printf 'precious\n' > "${workdir}/outside-c/precious.log"
ln -s "${workdir}/outside-c" "${LOG_DIR}/archive/20260100-000000-link"
CROSS_LOG_ARCHIVE_KEEP=1
_chain_prune_archived_logs
t_assert_ok    test -f "${workdir}/outside-c/precious.log"
t_assert_ok    test -L "${LOG_DIR}/archive/20260100-000000-link"
t_assert_fails test -e "${LOG_DIR}/archive/20260101-000000-c1"
t_assert_ok    test -d "${LOG_DIR}/archive/20260102-000000-c2"

t_case "the run dir of the CURRENT run is never a retention candidate"
LOG_DIR="${workdir}/ret-g"
_mk_archive "${LOG_DIR}" 20260101-000000-g1 20260102-000000-g2 20260103-000000-g3
CROSS_RUN_ID="20260101-000000-g1"      # oldest => first in line to be removed
CROSS_LOG_ARCHIVE_KEEP=1
_chain_prune_archived_logs
t_assert_ok    test -d "${LOG_DIR}/archive/20260101-000000-g1"
t_assert_fails test -e "${LOG_DIR}/archive/20260102-000000-g2"
CROSS_RUN_ID="20260105-000000-current"

t_case "an empty LOG_DIR can never become a delete of whatever cwd holds"
# An empty or unset LOG_DIR must return before a relative archive/* can resolve against cwd.
decoy="${workdir}/decoy"
_mk_archive "${decoy}" 20260101-000000-d1 20260102-000000-d2 20260103-000000-d3
CROSS_LOG_ARCHIVE_KEEP=1
( cd "${decoy}" && LOG_DIR="" && _chain_prune_archived_logs )
t_assert_ok test -f "${decoy}/archive/20260101-000000-d1/media-amd64.log"
( cd "${decoy}" && unset LOG_DIR && _chain_prune_archived_logs )
t_assert_ok test -f "${decoy}/archive/20260101-000000-d1/media-amd64.log"

t_case "the removal is ATTEMPTED only for a validated run dir, never an empty path"
# A recording rm shows an empty path as `rm -rf -- /archive` before any directory is needed to do damage.
rmlog="${workdir}/rm-calls.txt"; : > "${rmlog}"
rm() { printf '%s\n' "$*" >> "${rmlog}"; }
LOG_DIR=""
( cd "${decoy}" && _chain_prune_archived_logs )
( cd "${decoy}" && unset LOG_DIR && _chain_prune_archived_logs )
LOG_DIR="${workdir}/ret-i"
_mk_archive "${LOG_DIR}" 20260101-000000-i1 20260102-000000-i2
_chain_prune_archived_logs
unset -f rm      # MUST come back: the suite's EXIT trap cleans up with rm -rf
t_assert_eq "-rf -- ${workdir}/ret-i/archive/20260101-000000-i1" "$(cat "${rmlog}")" \
  "exactly one removal, of one validated run dir directly under archive/"

t_case "--dry-run removes nothing (an rm -rf is not a recoverable preview)"
LOG_DIR="${workdir}/ret-dry"
_mk_archive "${LOG_DIR}" 20260101-000000-y1 20260102-000000-y2 20260103-000000-y3
CROSS_LOG_ARCHIVE_KEEP=1
DRY_RUN=1
_chain_prune_archived_logs
t_assert_ok test -d "${LOG_DIR}/archive/20260101-000000-y1"
t_assert_ok test -d "${LOG_DIR}/archive/20260102-000000-y2"
DRY_RUN=0
_chain_prune_archived_logs                       # ... and the same call, for real
t_assert_fails test -e "${LOG_DIR}/archive/20260101-000000-y1"
t_assert_ok    test -d "${LOG_DIR}/archive/20260103-000000-y3"

t_case "CROSS_LOG_ARCHIVE_KEEP=0 keeps everything, a non-numeric value is refused"
LOG_DIR="${workdir}/ret-e"
_mk_archive "${LOG_DIR}" 20260101-000000-e1 20260102-000000-e2 20260103-000000-e3
CROSS_LOG_ARCHIVE_KEEP=0
_chain_prune_archived_logs
t_assert_ok test -d "${LOG_DIR}/archive/20260101-000000-e1"
CROSS_LOG_ARCHIVE_KEEP="five"
_chain_prune_archived_logs
t_assert_ok test -d "${LOG_DIR}/archive/20260101-000000-e1"
CROSS_LOG_ARCHIVE_KEEP=""
_chain_prune_archived_logs
t_assert_ok test -d "${LOG_DIR}/archive/20260101-000000-e1"

# chain-status.json stays at the repo root where readers look; under LOG_DIR that copy would freeze stale green
declare -A _CHAIN_STATUS=()
CROSS_STAGE_ORDER=( runtime )
cross_stage_pin_varname() { printf ''; }
eval "$(sed -n '/^_chain_status_emit() {$/,/^}$/p' "${CHAIN_SH}")"

t_case "chain-status.json is written to the repo root, not into LOG_DIR"
REPO_ROOT="${workdir}/statusroot"; mkdir -p "${REPO_ROOT}"
LOG_DIR="${workdir}/statuslogs";   mkdir -p "${LOG_DIR}"
CROSS_RUN_ID="20260823-101010-status"
unset CROSS_CHAIN_STATUS_FILE || true
_chain_status_emit runtime ok
t_assert_ok    test -f "${REPO_ROOT}/chain-status.json"
t_assert_fails test -e "${LOG_DIR}/chain-status.json"
t_assert_contains "$(cat "${REPO_ROOT}/chain-status.json")" "20260823-101010-status" \
  "the tracked file must carry THIS run's id, not a frozen older one"

t_case "CROSS_CHAIN_STATUS_FILE overrides the pinned repo-root path"
CROSS_CHAIN_STATUS_FILE="${workdir}/statuslogs/elsewhere.json"
_chain_status_emit runtime failed
t_assert_ok test -f "${workdir}/statuslogs/elsewhere.json"
t_assert_contains "$(cat "${workdir}/statuslogs/elsewhere.json")" "failed"
unset CROSS_CHAIN_STATUS_FILE

# B2: the lane-entry disk gate, the only one that can refuse, so it must be able to go red
source "${CORE_DIR}/disk-guard.sh"
eval "$(sed -n '/^_chain_runtime_lane_need_gb() {$/,/^}$/p' "${CHAIN_SH}")"
eval "$(sed -n '/^_chain_runtime_lane_disk_gate() {$/,/^}$/p' "${CHAIN_SH}")"
log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err()  { printf '[ERROR] %s\n' "$*"; exit 1; }
_bool_truthy() { case "${1:-}" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac; }
arch_list_to_words() { printf '%s' "${1//,/ }"; }
_disk_guard_protected_slugs() { printf ''; }
TARGET_ARCHES="amd64,arm64,riscv64"
BUILDKIT_CACHE_DIR="${workdir}/lane-bc"; mkdir -p "${BUILDKIT_CACHE_DIR}"
_lane_free=999
_disk_guard_free_gb() { printf '%s' "${_lane_free}"; }

# The lane builds arches serially and removes each wrapper, so the peak is one wrapper.
t_case "lane need is ONE wrapper, whatever --parallel-archs says"
PARALLEL_ARCHS=0; t_assert_eq "120" "$(_chain_runtime_lane_need_gb)"
PARALLEL_ARCHS=1; t_assert_eq "120" "$(_chain_runtime_lane_need_gb)"
PARALLEL_ARCHS=0

t_case "the lane gate PASSES with ample headroom"
_lane_free=500
( _chain_runtime_lane_disk_gate ) > "${workdir}/lane.txt" 2>&1
t_assert_contains "$(cat "${workdir}/lane.txt")" "runtime lane: 500G free"

t_case "the lane gate REFUSES when the lane cannot possibly fit"
# Red if the gate is removed, stubbed to `return 0`, or its threshold defaults to 0.
_lane_free=88
( _chain_runtime_lane_disk_gate ) > "${workdir}/lane.txt" 2>&1 && _lane_rc=0 || _lane_rc=$?
t_assert_eq "1" "${_lane_rc}" "88G free against a ~120G lane MUST refuse"
t_assert_contains "$(cat "${workdir}/lane.txt")" "runtime lane refused: 88G free"
t_assert_contains "$(cat "${workdir}/lane.txt")" "FORCE_LOW_DISK=1"

# _lane_run [VAR=VAL...]: one gate run in a subshell so knobs cannot leak; sets _lane_rc, logs to lane.txt.
_lane_run() {
  ( [ "$#" -eq 0 ] || export "$@"; _chain_runtime_lane_disk_gate ) \
    > "${workdir}/lane.txt" 2>&1 && _lane_rc=0 || _lane_rc=$?
}

t_case "FORCE_LOW_DISK=1 and CROSS_RUNTIME_LANE_GB=0 both let the lane through"
_lane_run FORCE_LOW_DISK=1
t_assert_eq "0" "${_lane_rc}"
t_assert_contains "$(cat "${workdir}/lane.txt")" "FORCE_LOW_DISK=1, continuing"
_lane_run CROSS_RUNTIME_LANE_GB=0
t_assert_eq "0" "${_lane_rc}"
_lane_run DISK_PREFLIGHT=0
t_assert_eq "0" "${_lane_rc}"

t_case "unknown free space is not treated as a shortfall"
_disk_guard_free_gb() { printf ''; }
_lane_run
t_assert_eq "0" "${_lane_rc}" "an unreadable df must never refuse a multi-hour lane"
_disk_guard_free_gb() { printf '%s' "${_lane_free}"; }

# DISK2: both refusing gates must reach the buildkit fallback. See docs/build-cache-tiers.md#321-the-buildkit-store-fallback-disk1
eval "$(sed -n '/^_chain_evict_slugs() {$/,/^}$/p' "${CHAIN_SH}")"
eval "$(sed -n '/^_chain_bc_free_gb()/p;/^_chain_bc_total_gb()/p;/^_chain_num_below()/p;/^_chain_num_above()/p' "${CHAIN_SH}")"
eval "$(sed -n '/^_chain_stage_disk_guard() {$/,/^}$/p' "${CHAIN_SH}")"
# Both gates run in a subshell, so the record has to be a file, not a variable.
_BK_LOG="${workdir}/bk.txt"
_disk_guard_buildkit_fallback() {
  printf 'CALL %s %s latch=%s\n' "$1" "$2" "${_DISK_GUARD_BUILDKIT_PRUNES}" >> "${_BK_LOG}"
  _DISK_GUARD_BUILDKIT_PRUNES=1
  _DISK_GUARD_BUILDKIT_FREED_GB="${_BK_FREED:-0}"
  [ -z "${_BK_RESCUE_TO:-}" ] || _lane_free="${_BK_RESCUE_TO}"
}
# $1 = free GB; the latch is left dirty, so a gate that opens no episode of its own never reaches the store.
_bk_reset_calls() { : > "${_BK_LOG}"; _lane_free="$1"; _DISK_GUARD_BUILDKIT_PRUNES=9; }
_bk_calls() { cat "${_BK_LOG}"; }

t_case "the lane-entry gate reaches the buildkit store before it refuses the run"
_bk_reset_calls 88
_BK_FREED=0 _BK_RESCUE_TO="" _lane_run
t_assert_eq "1" "${_lane_rc}" "a fallback that cannot help must still leave the refusal intact"
t_assert_contains "$(_bk_calls)" "CALL ${BUILDKIT_CACHE_DIR} 120 latch=0" \
  "the lane gate must offer the store the SAME need it is about to refuse on, on a fresh episode"

t_case "a store that CAN be reclaimed rescues the lane instead of refusing it"
_bk_reset_calls 88
_BK_FREED=223 _BK_RESCUE_TO=311 _lane_run
t_assert_eq "0" "${_lane_rc}" "223G reclaimed from the store must let the lane start"
t_assert_contains "$(cat "${workdir}/lane.txt")" "+ 223G of buildkit layer cache" \
  "the reclaim record must credit the store, not cry defeat"
_BK_FREED=0; _BK_RESCUE_TO=""

t_case "the between-stage guard reaches the store before giving up on cache exports"
# Giving up costs every remaining stage its local cache export, so the store comes first.
_chain_runtime_lane_is_next() { return 1; }
_bk_reset_calls 10
unset CROSS_NO_LOCAL_CACHE_EXPORT
( CROSS_CACHE_MAX_GB=0 _chain_stage_disk_guard media ) > "${workdir}/sg.txt" 2>&1
t_assert_contains "$(_bk_calls)" "CALL ${BUILDKIT_CACHE_DIR} 40 latch=0" "the guard must offer the store its own threshold"
t_assert_contains "$(cat "${workdir}/sg.txt")" "CROSS_NO_LOCAL_CACHE_EXPORT=1" \
  "a store that frees nothing must still reach the give-up"

t_case "a reclaimed store keeps the cache exports ON for the remaining stages"
_bk_reset_calls 10
_BK_RESCUE_TO=200
( CROSS_CACHE_MAX_GB=0 _chain_stage_disk_guard media ) > "${workdir}/sg.txt" 2>&1
t_assert_contains "$(cat "${workdir}/sg.txt")" "after pruning: 200G free"
t_assert_eq "0" "$(grep -c -e 'CROSS_NO_LOCAL_CACHE_EXPORT' "${workdir}/sg.txt" || true)" \
  "the give-up must not fire after the store rescued the stage"
_BK_RESCUE_TO=""

t_case "each gate opens its OWN reclaim episode"
# The latch is per process and the gates are hours apart, so each must reset it.
_bk_reset_calls 88
_lane_run
t_assert_contains "$(_bk_calls)" "latch=0" "the lane gate must clear a stale latch before pruning"
_bk_reset_calls 10
( CROSS_CACHE_MAX_GB=0 _chain_stage_disk_guard media ) >/dev/null 2>&1
t_assert_contains "$(_bk_calls)" "CALL ${BUILDKIT_CACHE_DIR} 40 latch=0" \
  "a latch left set by an earlier stage must not silence this one"

t_case "an ample-disk stage never reaches the store at all"
_bk_reset_calls 500
( CROSS_CACHE_MAX_GB=0 _chain_stage_disk_guard media ) >/dev/null 2>&1
t_assert_eq "" "$(_bk_calls)" "40G threshold with 500G free must never touch buildkit"
unset CROSS_NO_LOCAL_CACHE_EXPORT
_lane_free=999

# DISK3: the image store is safe only with nothing in flight. See docs/build-cache-tiers.md#322-the-image-store-lever-disk3
_IM_LOG="${workdir}/im.txt"
_disk_guard_image_store_fallback() {
  printf 'CALL %s %s in_flight=%s\n' "$1" "$2" "${4:-}" >> "${_IM_LOG}"
  printf 'PROTECTED %s\n' "$(printf '%s' "$3" | tr '\n' ' ')" >> "${_IM_LOG}"
  [ -z "${_IM_RESCUE_TO:-}" ] || _lane_free="${_IM_RESCUE_TO}"
}
CROSS_STAGE_ORDER=(base compiler sdk media android runtime)
stage_enabled() { return 0; }
cross_stage_is_per_arch() { [ "$1" != "base" ] && return 0; return 1; }
cross_stage_tag() { printf 'ghcr.io/x/y:cross-%s%s' "$1" "${2:+-$2}"; }
TARGET_ARCHES="arm64"
_im_reset() { : > "${_IM_LOG}"; _lane_free="$1"; }
_im_calls() { cat "${_IM_LOG}"; }

t_case "the between-stage guard reaches the image store, and only after buildkit"
_im_reset 10
_bk_reset_calls 10
( CROSS_CACHE_MAX_GB=0 _chain_stage_disk_guard media ) >/dev/null 2>&1
t_assert_contains "$(_im_calls)" "CALL ${BUILDKIT_CACHE_DIR} 40 in_flight=0" \
  "between stages nothing is unpacking, which is the only time images may go"

t_case "the completed stage keeps its tag: it is the next stage's parent"
t_assert_contains "$(_im_calls)" "ghcr.io/x/y:cross-media-arm64" \
  "the local OCI handoff reads the just-built image out of the store"
t_assert_contains "$(_im_calls)" "ghcr.io/x/y:cross-runtime-arm64" "the stages still to build stay"
t_assert_eq "0" "$(grep -c -e 'PROTECTED.*cross-compiler-arm64' "${_IM_LOG}" || true)" \
  "a stage this run finished with is re-pullable by the digest it pinned"

t_case "an image-store rescue keeps the cache exports ON for the remaining stages"
_im_reset 10
_bk_reset_calls 10
_IM_RESCUE_TO=200
( CROSS_CACHE_MAX_GB=0 _chain_stage_disk_guard media ) > "${workdir}/sg.txt" 2>&1
t_assert_contains "$(cat "${workdir}/sg.txt")" "after pruning: 200G free"
t_assert_eq "0" "$(grep -c -e 'CROSS_NO_LOCAL_CACHE_EXPORT' "${workdir}/sg.txt" || true)"
_IM_RESCUE_TO=""

t_case "the lane-entry gate reaches it too, protecting every stage it can name"
_im_reset 88
_bk_reset_calls 88
_lane_run
t_assert_contains "$(_im_calls)" "CALL ${BUILDKIT_CACHE_DIR} 120 in_flight=0"
t_assert_contains "$(_im_calls)" "ghcr.io/x/y:cross-base"
t_assert_contains "$(_im_calls)" "ghcr.io/x/y:cross-runtime-arm64"

t_case "an ample-disk stage never reaches the image store either"
_im_reset 500
_bk_reset_calls 500
( CROSS_CACHE_MAX_GB=0 _chain_stage_disk_guard media ) >/dev/null 2>&1
t_assert_eq "" "$(_im_calls)"
unset CROSS_NO_LOCAL_CACHE_EXPORT
_lane_free=999

# B3: a runtime failure skips every gate after the per-arch wrapper loop, so the report must name them
eval "$(sed -n '/^_chain_runtime_arch_state() {$/,/^}$/p' "${CHAIN_SH}")"
eval "$(sed -n '/^_chain_runtime_failure_report() {$/,/^}$/p' "${CHAIN_SH}")"
_CHAIN_RUNTIME_GATES="$(sed -n 's/^_CHAIN_RUNTIME_GATES="\(.*\)"$/\1/p' "${CHAIN_SH}")"
arch_list_to_words() { printf '%s' "${1//,/ }"; }
warn() { printf '[WARN] %s\n' "$*"; }
FINAL_IMAGE="repo/img:latest"
TARGET_ARCHES="amd64,arm64,riscv64"
CROSS_RUN_ID="20260901-000000-b3"
# Stand-in for ancestry_recorded_run_id: amd64's wrapper was never produced.
ancestry_recorded_run_id() {
  case "$1" in
    *-amd64)   return 1 ;;
    *-riscv64) printf 'an-older-run' ;;
    *)         printf '%s' "${CROSS_RUN_ID}" ;;
  esac
}

t_case "the gate list is non-empty — an empty list would report nothing, silently"
t_assert_ok test -n "${_CHAIN_RUNTIME_GATES}"
t_assert_contains "${_CHAIN_RUNTIME_GATES}" "runtime-image-smoke"
t_assert_contains "${_CHAIN_RUNTIME_GATES}" "manifest-completeness"

t_case "per-arch state comes from the wrapper tag's own run-id stamp"
t_assert_eq "missing"        "$(_chain_runtime_arch_state amd64)"
t_assert_eq "built-this-run" "$(_chain_runtime_arch_state arm64)"
t_assert_eq "stale"          "$(_chain_runtime_arch_state riscv64)"

t_case "the failure report NAMES the arch and the gates that never ran"
_CHAIN_ARCH_OUTCOMES=""; _CHAIN_GATES_NOT_RUN=""
_chain_runtime_failure_report > "${workdir}/b3-report.txt"   # NOT $(...): it sets globals
out="$(cat "${workdir}/b3-report.txt")"
t_assert_eq "amd64=missing,arm64=built-this-run,riscv64=stale" "${_CHAIN_ARCH_OUTCOMES}"
t_assert_eq "${_CHAIN_RUNTIME_GATES}" "${_CHAIN_GATES_NOT_RUN}"
t_assert_contains "${out}" "amd64 riscv64" "the arches without this run's image must be named"
t_assert_contains "${out}" "runtime-image-smoke" "the skipped gates must be named"
t_assert_contains "${out}" "manifest-only" "the repair path must be warned off unverified wrappers"

t_case "an all-arches-built failure must NOT claim the gates were skipped"
# The lane can also fail after the loop (a manifest push), where claiming a skip would be false.
ancestry_recorded_run_id() { printf '%s' "${CROSS_RUN_ID}"; }
_CHAIN_ARCH_OUTCOMES=""; _CHAIN_GATES_NOT_RUN="stale-value"
_chain_runtime_failure_report > "${workdir}/b3-report.txt"
out="$(cat "${workdir}/b3-report.txt")"
t_assert_eq "amd64=built-this-run,arm64=built-this-run,riscv64=built-this-run" "${_CHAIN_ARCH_OUTCOMES}"
t_assert_eq "" "${_CHAIN_GATES_NOT_RUN}"
t_assert_contains "${out}" "AT or AFTER"

# Outcomes reach chain-status.json, so a --manifest-only repair cannot assume everything was checked
t_case "chain-status.json records the per-arch outcomes and the skipped gates"
CROSS_CHAIN_STATUS_FILE="${workdir}/b3-status.json"
_CHAIN_ARCH_OUTCOMES="amd64=missing,arm64=built-this-run"
_CHAIN_GATES_NOT_RUN="runtime-image-smoke,manifest-completeness"
_chain_status_emit runtime failed
_b3="$(cat "${CROSS_CHAIN_STATUS_FILE}")"
t_assert_contains "${_b3}" '"arch_outcomes": {"amd64": "missing", "arm64": "built-this-run"}'
t_assert_contains "${_b3}" '"gates_not_run": ["runtime-image-smoke", "manifest-completeness"]'
t_assert_ok python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${CROSS_CHAIN_STATUS_FILE}"

t_case "a green run's chain-status.json gains NO new keys"
_CHAIN_ARCH_OUTCOMES=""; _CHAIN_GATES_NOT_RUN=""
_chain_status_emit runtime ok
_b3="$(cat "${CROSS_CHAIN_STATUS_FILE}")"
t_assert_fails grep -q -e 'arch_outcomes' "${CROSS_CHAIN_STATUS_FILE}"
t_assert_ok python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "${CROSS_CHAIN_STATUS_FILE}"
unset CROSS_CHAIN_STATUS_FILE

# Wiring: every function above stays green if its call site is deleted, so assert the calls
t_case "run_runtime_stage gates on disk, then samples ACROSS the helper call"
t_assert_eq \
  "_chain_runtime_lane_disk_gate,_chain_disk_watch_start,_chain_disk_watch_stop" \
  "$(sed -n '/^run_runtime_stage() {$/,/^}$/p' "${CHAIN_SH}" \
      | grep -oE '_chain_runtime_lane_disk_gate|_chain_disk_watch_start|_chain_disk_watch_stop' \
      | paste -sd, -)" \
  "a watchdog that is never started (or never stopped) is worse than none"

t_case "the runtime failure path reports BEFORE it records and dies"
t_assert_eq \
  "_chain_runtime_failure_report,_chain_status_emit,err" \
  "$(sed -n '/^_chain_run_build_loop() {$/,/^}$/p' "${CHAIN_SH}" \
      | sed -n '/run_runtime_stage/,/err "runtime stage failed"/p' \
      | grep -oE '_chain_runtime_failure_report|_chain_status_emit|err ' \
      | sed 's/ $//' | paste -sd, -)" \
  "the report must run before _chain_status_emit, and err must stay last"
# set -e is live inside `|| { ... }`: a failing report would skip the status write and change the exit code.
t_assert_contains \
  "$(sed -n '/^_chain_run_build_loop() {$/,/^}$/p' "${CHAIN_SH}")" \
  "_chain_runtime_failure_report || true" \
  "the diagnostic must be unable to preempt _chain_status_emit/err"

t_case "the in-stage guard never reaches for a prune that wipes the compiler caches"
t_assert_eq "" \
  "$(grep -nE '(system|builder|buildkit) prune' "${CHAIN_SH}" | grep -v 'Also:' || true)" \
  "nerdctl/builder prune wipes the ccache+sccache exec cachemounts (hours to rebuild)"

t_case "main() calls the log-hygiene guards, in order, before the build loop"
t_assert_eq \
  "_chain_prepare_log_dir,_chain_archive_prev_logs,_chain_prune_archived_logs,_chain_run_build_loop" \
  "$(sed -n '/^main() {$/,/^}$/p' "${CHAIN_SH}" \
      | grep -oE '^[[:space:]]+(_chain_prepare_log_dir|_chain_archive_prev_logs|_chain_prune_archived_logs|_chain_run_build_loop)([[:space:]]|$)' \
      | sed 's/[[:space:]]//g' | paste -sd, -)" \
  "a guard whose call is missing from main() is inert, whatever its unit tests say"


# ── concurrency: a live SIBLING chain must survive this one starting ──
eval "$(sed -n '/^_chain_write_pidfile()/,/^}/p' "${CHAIN_SH}")"
eval "$(sed -n '/^_chain_archive_prev_logs()/,/^}/p' "${CHAIN_SH}")"

_sib_pf="$(mktemp)"
cross_chain_pidfile_path() { printf '%s' "${_sib_pf}"; }
sleep 300 & _sib_pid=$!
printf '%s\n' "${_sib_pid}" > "${_sib_pf}"

t_case "a live sibling keeps the pidfile, so stop-cross-chain.sh still reaches it"
_CHAIN_PIDFILE=""
_chain_write_pidfile >/dev/null 2>&1
t_assert_eq "${_sib_pid}" "$(cat "${_sib_pf}")" "clobbering it strands the running chain"
t_assert_eq "" "${_CHAIN_PIDFILE}" "this run must not think it owns a pidfile it did not write"

t_case "a live sibling's stage logs are NOT archived out from under it"
_sib_logs="$(mktemp -d)"
LOG_DIR="${_sib_logs}"
printf 'other-run\n' > "${_sib_logs}/media-arm64.log.run"
printf 'live output\n' > "${_sib_logs}/media-arm64.log"
CROSS_RUN_ID=this-run _chain_archive_prev_logs >/dev/null 2>&1
t_assert_ok test -f "${_sib_logs}/media-arm64.log"

kill "${_sib_pid}" 2>/dev/null || true
rm -rf "${_sib_pf}" "${_sib_logs}"

# B3: the between-stage guard aims at the next lane's need, not a fixed 40G floor that reclaims too late
eval "$(sed -n '/^_chain_runtime_lane_is_next() {$/,/^}$/p' "${CHAIN_SH}")"

t_case "the runtime lane is recognised as the next enabled stage"
CROSS_STAGE_ORDER=( base compiler sdk media android runtime )
stage_enabled() { return 0; }
t_assert_ok   _chain_runtime_lane_is_next android
t_assert_fails _chain_runtime_lane_is_next media   # sdk..android still to come
t_assert_fails _chain_runtime_lane_is_next runtime # nothing follows it
t_assert_fails _chain_runtime_lane_is_next ""      # no completed stage

t_case "a disabled intermediate stage does not hide the runtime lane"
stage_enabled() { [ "$1" != "android" ]; }
t_assert_ok _chain_runtime_lane_is_next media

t_case "a disabled runtime lane never raises the bar"
stage_enabled() { [ "$1" != "runtime" ]; }
t_assert_fails _chain_runtime_lane_is_next android

t_case "the guard actually consults the predicate (call site, not just the helper)"
# The file's own lesson: a helper with tests and no call site is inert coverage.
t_assert_contains "$(sed -n '/^_chain_stage_disk_guard() {$/,/^}$/p' "${CHAIN_SH}")" \
  "_chain_runtime_lane_is_next" "the guard must call the predicate"
t_assert_contains "$(sed -n '/^_chain_stage_disk_guard() {$/,/^}$/p' "${CHAIN_SH}")" \
  "_chain_runtime_lane_need_gb" "the guard must raise the threshold to the lane need"

t_summary
