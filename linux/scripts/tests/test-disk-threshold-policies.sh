#!/usr/bin/env bash
# Extracted chain functions use fake disk measurements and reclaim calls, not real stores, samplers or builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${1:-${TESTS_DIR}/../01-core}"
CHAIN="${2:-${TESTS_DIR}/../build-cross-chain.sh}"
RECEIPT="${3:-}"
[ -z "${RECEIPT}" ] || : > "${RECEIPT}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cat > "${WORK}/worker.sh" <<'WORKER'
set -uo pipefail
source "$1"
source "$2/disk-guard.sh"
t_source_functions "$2/cross-stage-build.sh" _cross_salvage_disk_ok
t_source_functions "$3" _chain_runtime_lane_disk_gate _chain_disk_watch_start
kind="$4" threshold="$5" measured="$6" policy="$7" fixture="$8"
_disk_guard_free_gb() { printf 'probe\n' >> "$fixture/probes"; printf '%s' "$measured"; }
log() { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
err() { printf 'ERR %s\n' "$*"; return 8; }
is_dry_run() { [ "$policy" = dry ]; }
_chain_runtime_lane_need_gb() { printf '%s' "$CROSS_RUNTIME_LANE_GB"; }
_disk_guard_protected_slugs() { printf protected; }
_disk_guard_stage_tags() { printf tags; }
_disk_guard_watch_loop() { printf 'WATCH %s\n' "$*" > "$fixture/watch"; }
_disk_guard_reclaim_begin() { printf 'BEGIN\n'; }
_disk_guard_trim_cache_export() { printf 'TRIM %s\n' "$*"; }
_disk_guard_buildkit_fallback() { printf 'BUILDKIT %s\n' "$*"; }
_disk_guard_image_store_fallback() { printf 'IMAGES %s\n' "$*"; }
_disk_guard_reclaim_record() { printf 'RECORD %s\n' "$*"; }
BUILDKIT_CACHE_DIR=cache SALVAGE_MIN_FREE_GB="$threshold" CROSS_RUNTIME_LANE_GB="$threshold" CROSS_DISK_GUARD_GB="$threshold"
DISK_PREFLIGHT=1 CROSS_DISK_WATCH=1 CROSS_DISK_WATCH_SECS=120 CROSS_TRIM_KEEP_SLUGS=3 FORCE_LOW_DISK=0
[ "$policy" != force ] || FORCE_LOW_DISK=1
rc=0
case "$kind" in
  salvage) _cross_salvage_disk_ok cache || rc=$? ;;
  runtime) _chain_runtime_lane_disk_gate || rc=$? ;;
  watch) _chain_disk_watch_start fixture || rc=$?; [ -z "${_CHAIN_DISK_WATCH_PID:-}" ] || wait "$_CHAIN_DISK_WATCH_PID" ;;
esac
printf 'STATUS=%s\n' "$rc"
WORKER
for kind in salvage runtime watch; do
  for threshold in invalid 0 10; do
    for measured in '' 5 20; do
      for policy in normal dry force; do
        t_case "${kind} threshold '${threshold}' measurement '${measured}' ${policy}"
        rm -f "${WORK}/probes" "${WORK}/watch"
        out="$(t_run_fixture_worker "${WORK}/worker.sh" "${CORE}" "${CHAIN}" "$kind" "$threshold" "$measured" "$policy" "$WORK" 2>&1)"
        t_record_fixture_receipt "${RECEIPT}" "${kind}/${threshold}/${measured}/${policy}" "${out}"
        expected_status=0
        if [ "$threshold" = 10 ] && [ "$measured" = 5 ]; then
          case "$kind/$policy" in salvage/*) expected_status=1 ;; runtime/normal) expected_status=8 ;; esac
        fi
        t_assert_eq "$expected_status" "${out##*STATUS=}"
        expected_probes=''
        if [ "$threshold" = 10 ] && [ "$kind" != watch ]; then
          expected_probes=probe
          if [ "$kind/$measured/$policy" = runtime/5/normal ]; then expected_probes+=$'\nprobe'; fi
        fi
        actual_probes=''; [ ! -f "${WORK}/probes" ] || actual_probes="$(cat "${WORK}/probes")"
        t_assert_eq "$expected_probes" "$actual_probes"
        expected_watch=''
        if [ "$kind" = watch ] && [ "$threshold" = 10 ] && [ "$policy" != dry ]; then expected_watch="WATCH cache 10 120 protected 3 "; fi
        actual_watch=''; [ ! -f "${WORK}/watch" ] || actual_watch="$(cat "${WORK}/watch")"
        if [ -n "$expected_watch" ]; then t_assert_contains "$actual_watch" "$expected_watch"; else t_assert_eq '' "$actual_watch"; fi
      done
    done
  done
done
t_summary
