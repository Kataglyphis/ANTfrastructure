#!/usr/bin/env bash
# Tests for 01-core/chain-lifecycle.sh — the orchestrator-lifecycle primitives
# shared by build-cross-chain.sh and stop-cross-chain.sh (Batch 5 / O1+O2):
# canonical CROSS_RUN_ID generation, the well-known pidfile path, and the
# child-subtree termination walk.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${TESTS_DIR}/../01-core"
source "${TESTS_DIR}/test-harness.sh"
source "${CORE_DIR}/chain-lifecycle.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# ---------------------------------------------------------------------------
# O2: run-id generation.
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

# ---------------------------------------------------------------------------
# O2: pidfile path.
t_case "cross_chain_pidfile_path honors CROSS_CHAIN_PIDFILE"
t_assert_eq "/run/mychain.pid" \
  "$(CROSS_CHAIN_PIDFILE=/run/mychain.pid cross_chain_pidfile_path)"

t_case "cross_chain_pidfile_path defaults under TMPDIR"
t_assert_eq "/custom/tmp/kata-cross-chain.pid" \
  "$(TMPDIR=/custom/tmp CROSS_CHAIN_PIDFILE= cross_chain_pidfile_path)"

# ---------------------------------------------------------------------------
# O1: child-subtree termination. Launch a root process that itself backgrounds a
# leaf sleep, then TERM the subtree of the root and confirm the leaf dies while
# the walk never targets the root's PARENT (this test process).
t_case "chain_terminate_descendants TERMs the descendant subtree"
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

# ---------------------------------------------------------------------------
# STALE-LOG (2026-08-23): the two log-hygiene guards are only as good as their
# LOG_DIR default. Both live in build-cross-chain.sh, which runs `main "$@"` at
# the bottom and therefore cannot be sourced — so the assertions below evaluate
# the SHIPPED text of the pieces under test (never a copy that could drift).
CHAIN_SH="${TESTS_DIR}/../build-cross-chain.sh"

t_case "LOG_DIR defaults to out/build-logs so both guards are armed without --log-dir"
# Regression: an empty default made the truncate marker AND the archiver inert
# for every run launched without --log-dir — wave5j's failed android-*.log was
# still in out/build-logs when wave5k ran, and a watcher read it as new errors.
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

# Pull the archiver in with its logging stubbed out (logging.sh is not sourced
# here — the suite deliberately loads chain-lifecycle.sh only).
log()  { :; }
warn() { :; }
eval "$(sed -n '/^_chain_live_sibling_pid()/,/^}/p' "${CHAIN_SH}")"
# Isolate from the HOST's real pidfile: a chain actually running on this
# machine would otherwise make the archiver correctly refuse, failing these.
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
# LOG_DIR now defaults to out/build-logs, which is also where the nohup/tee
# transcript of the RUNNING chain lives; mv'ing a file an open tee holds would
# silently redirect the operator's terminal log into archive/.
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

# ---------------------------------------------------------------------------
# The default only helps if the directory exists before the first writer runs:
# _chain_status_emit skips a missing dir outright (no chain-status.json on a
# fresh clone with no out/), and an uncreatable dir must DISABLE logging rather
# than kill a multi-hour chain from inside a `set -e` command substitution.
eval "$(sed -n '/^_chain_prepare_log_dir() {$/,/^}$/p' "${CHAIN_SH}")"
REPO_ROOT="${TESTS_DIR}/../../.."

t_case "preparing the log dir creates it (fresh clone has no out/)"
LOG_DIR="${workdir}/fresh/out/build-logs"
_chain_prepare_log_dir
t_assert_ok test -d "${LOG_DIR}"
t_assert_eq "${workdir}/fresh/out/build-logs" "${LOG_DIR}" "a writable dir must be kept"

t_case "an uncreatable log dir disables logging instead of failing the run"
mkdir -p "${workdir}/ro"
if [ "$(id -u)" != "0" ] && chmod 500 "${workdir}/ro" 2>/dev/null; then
  LOG_DIR="${workdir}/ro/logs"
  _chain_prepare_log_dir
  t_assert_eq "" "${LOG_DIR}" "an unwritable dir must fall back to no per-stage logs"
  chmod 700 "${workdir}/ro" 2>/dev/null || true
else
  t_assert_eq "1" "1"   # root (or a permissionless fs) cannot exercise this
fi

# ---------------------------------------------------------------------------
# The second guard: cross_stage_log_redirect truncates once per run id, so a
# stage log only ever holds the CURRENT run (this is what the 575k-line media
# log that spanned several rebuilds cost us).
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

# ---------------------------------------------------------------------------
# Bounded archive retention. _chain_archive_prev_logs only ever ADDS, and it now
# runs on EVERY chain start: when the default landed, out/build-logs was already
# 13G — 12G of it archive/, 40 run dirs, the largest 6.3G — on a filesystem at
# 92% used, i.e. the box whose builds die of ENOSPC. The assertions below pin
# down BOTH halves: that retention prunes, and that it cannot prune anything it
# does not own.
log()  { :; }    # re-stub: sourcing cross-stage-build.sh may pull in the real ones
warn() { :; }
is_dry_run() { [ "${DRY_RUN:-0}" = "1" ]; }   # stands in for build-helpers.sh's
eval "$(sed -n '/^_chain_prune_archived_logs() {$/,/^}$/p' "${CHAIN_SH}")"
t_case "the retention function was extracted from the shipped script"
t_assert_eq "function" "$(type -t _chain_prune_archived_logs || true)"

# Build an archive/ tree: one dir per run id given, each with a file inside so a
# removal has to be recursive to succeed. Retention orders by mtime (the two run
# id shapes do not interleave lexically), so stamp the dirs oldest-first in
# argument order — after writing their contents, which would bump the mtime.
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
# A dir nobody's run id could produce, and a loose file: neither may be a
# candidate, and neither may count against the keep budget either (so the run
# dirs are still pruned down to exactly ${keep}).
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
# archive/365161 — 6.3G, the single biggest dir in the 13G tree — is named by
# cross-stage-build.sh's stage-marker helper `rid="${CROSS_RUN_ID:-$$}"`, i.e. by the orchestrator
# PID. Two consequences this case pins down: such a dir IS a run dir (excluding
# it from the pattern would leave the worst offender unreclaimable), and age
# must come from mtime — sorted by NAME, a leading '3' files 365161 after every
# 2026* id, so the biggest, oldest dir on the box would rank as the NEWEST and
# survive forever while the small ones got pruned.
LOG_DIR="${workdir}/ret-h"
_mk_archive "${LOG_DIR}" 365161 20260101-000000-h1 1847483 20260102-000000-h2
CROSS_LOG_ARCHIVE_KEEP=2
_chain_prune_archived_logs
t_assert_fails test -e "${LOG_DIR}/archive/365161"
t_assert_fails test -e "${LOG_DIR}/archive/20260101-000000-h1"
t_assert_ok    test -d "${LOG_DIR}/archive/1847483"
t_assert_ok    test -d "${LOG_DIR}/archive/20260102-000000-h2"

t_case "retention skips a symlinked run dir instead of following it"
# The link is named so it sorts OLDEST: a follow-the-symlink bug would eat it
# (and its target's contents) first.
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
# The path is built as ${LOG_DIR}/archive. An empty (or unset) LOG_DIR must
# return before that is ever formed — never fall through to a relative
# 'archive/*' resolved against the process's working directory.
decoy="${workdir}/decoy"
_mk_archive "${decoy}" 20260101-000000-d1 20260102-000000-d2 20260103-000000-d3
CROSS_LOG_ARCHIVE_KEEP=1
( cd "${decoy}" && LOG_DIR="" && _chain_prune_archived_logs )
t_assert_ok test -f "${decoy}/archive/20260101-000000-d1/media-amd64.log"
( cd "${decoy}" && unset LOG_DIR && _chain_prune_archived_logs )
t_assert_ok test -f "${decoy}/archive/20260101-000000-d1/media-amd64.log"

t_case "the removal is ATTEMPTED only for a validated run dir, never an empty path"
# Stronger than "the decoy survived": shadow rm with a recorder, so the exact
# argv of every removal the function would make is captured. An empty LOG_DIR
# or an empty victim would show up here as `rm -rf -- /` or `rm -rf -- /archive`
# long before it needed a directory to exist to do damage.
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

# ---------------------------------------------------------------------------
# chain-status.json must NOT follow LOG_DIR. The repo-root copy is git-TRACKED;
# when LOG_DIR gained a default, a ${LOG_DIR}-relative path would have frozen
# that tracked file at the last run's "ok" — a brand-new stale-GREEN artifact,
# the exact class this item exists to kill.
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

# ---------------------------------------------------------------------------
# WIRING, not just the functions. Every assertion above exercises a function
# lifted out of the shipped file — all of them stay green if the CALLS are
# deleted from main(), which is how a guard ends up inert while its tests look
# like coverage (the exporter flag that never tagged, the strip gate that never
# ran). So assert the call sites themselves, in order, inside main().
# ---------------------------------------------------------------------------
# B2: the lane-entry disk gate. `_chain_stage_disk_guard` only runs BETWEEN
# stages, and the runtime lane is one stage of three ~120G wrapper builds: the
# 2026-09-01 run entered it with 88G free and died 28 min later. This gate is
# the one that can REFUSE, so it must actually be able to go red.
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

# The runtime lane builds arches SERIALLY and rmi's each wrapper before the next,
# so peak is ONE wrapper -- --parallel-archs must not scale it. The first cut of
# this gate multiplied by PARALLEL_ARCHS and would have demanded 360G for a run
# that never needs more than 120G at once.
t_case "lane need is ONE wrapper, whatever --parallel-archs says"
PARALLEL_ARCHS=0; t_assert_eq "120" "$(_chain_runtime_lane_need_gb)"
PARALLEL_ARCHS=1; t_assert_eq "120" "$(_chain_runtime_lane_need_gb)"
PARALLEL_ARCHS=0

t_case "the lane gate PASSES with ample headroom"
_lane_free=500
( _chain_runtime_lane_disk_gate ) > "${workdir}/lane.txt" 2>&1
t_assert_contains "$(cat "${workdir}/lane.txt")" "runtime lane: 500G free"

t_case "the lane gate REFUSES when the lane cannot possibly fit"
# MUTATION ANCHOR: this is the assertion that goes red if the gate is removed,
# stubbed to `return 0`, or its threshold is silently defaulted to 0.
_lane_free=88
( _chain_runtime_lane_disk_gate ) > "${workdir}/lane.txt" 2>&1 && _lane_rc=0 || _lane_rc=$?
t_assert_eq "1" "${_lane_rc}" "88G free against a ~120G lane MUST refuse"
t_assert_contains "$(cat "${workdir}/lane.txt")" "runtime lane refused: 88G free"
t_assert_contains "$(cat "${workdir}/lane.txt")" "FORCE_LOW_DISK=1"

# $@ = VAR=VAL knobs for ONE gate run; the subshell keeps them from leaking into
# the next case. Sets _lane_rc, logs to lane.txt.
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

# ---------------------------------------------------------------------------
# B3: a runtime failure skips EVERY gate downstream of the per-arch wrapper loop
# in build-runtime-manifest.sh. The 2026-09-01 run ended with a bare
# "[ERROR] runtime stage failed" and `grep -c` returning 0 for all of them.
eval "$(sed -n '/^_chain_runtime_arch_state() {$/,/^}$/p' "${CHAIN_SH}")"
eval "$(sed -n '/^_chain_runtime_failure_report() {$/,/^}$/p' "${CHAIN_SH}")"
_CHAIN_RUNTIME_GATES="$(sed -n 's/^_CHAIN_RUNTIME_GATES="\(.*\)"$/\1/p' "${CHAIN_SH}")"
arch_list_to_words() { printf '%s' "${1//,/ }"; }
warn() { printf '[WARN] %s\n' "$*"; }
FINAL_IMAGE="repo/img:latest-cross"
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
# The lane can also fail AFTER the loop (a manifest push). Claiming a skip there
# would be a lie, and a lie in the failure summary is worse than the silence.
ancestry_recorded_run_id() { printf '%s' "${CROSS_RUN_ID}"; }
_CHAIN_ARCH_OUTCOMES=""; _CHAIN_GATES_NOT_RUN="stale-value"
_chain_runtime_failure_report > "${workdir}/b3-report.txt"
out="$(cat "${workdir}/b3-report.txt")"
t_assert_eq "amd64=built-this-run,arm64=built-this-run,riscv64=built-this-run" "${_CHAIN_ARCH_OUTCOMES}"
t_assert_eq "" "${_CHAIN_GATES_NOT_RUN}"
t_assert_contains "${out}" "AT or AFTER"

# ---------------------------------------------------------------------------
# The outcomes must survive into chain-status.json, so a later --manifest-only
# repair cannot assemble an index believing everything was checked.
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

# ---------------------------------------------------------------------------
# B2 wiring. The in-stage guard and the lane gate are inert unless run_runtime_stage
# actually calls them, and the failure report is inert unless the build loop does.
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
# set -e IS live inside a `|| { ... }` group: a report that returned non-zero
# would skip the status write AND change the chain's exit code from 1 to its own.
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

# ---------------------------------------------------------------------------
# B3: the between-stage guard must aim at the NEXT lane, not at a fixed floor.
# Reclaiming at 40G before a lane whose entry gate refuses below ~120G arrives
# too late: the 2026-09-02 run needed six manual prunes to get there.
# ---------------------------------------------------------------------------
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
