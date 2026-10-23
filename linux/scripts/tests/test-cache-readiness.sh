#!/usr/bin/env bash
# Stubbed cache functions cover startup policy, health verdicts and launcher bytes, not real daemons, compilers or networks.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${1:-${TESTS_DIR}/../01-core}"
PROBE="${2:-${TESTS_DIR}/../02-toolchain/probe-sccache.sh}"
RECEIPT="${3:-}"
[ -z "$RECEIPT" ] || : > "$RECEIPT"
_cache_receipt_contract() {
  local receipt="$2/receipt with spaces"
  t_case 'optional receipts preserve field order and shell quoting'
  t_assert_ok t_record_fixture_receipt '' ignored
  t_assert_eq '' "$(t_record_fixture_receipt '' ignored)"
  t_record_fixture_receipt "$receipt" 'first value' '' 'second*'
  t_assert_eq "first\\ value '' second\\* " "$(cat "$receipt")"
}
_t_probe_file _cache_receipt_contract

_cache_readiness_worker() {
  local WORK="$1"
  mkdir -p "$WORK/01-core" "$WORK/toolchain" "$WORK/installed"
  cp "$CORE/compiler-cache-utils.sh" "$WORK/01-core/"
  awk '/^cat > .*probe.c/ {exit} {print}' "$PROBE" > "$WORK/toolchain/probe-sccache.sh"
cat > "$WORK/worker.sh" <<'WORKER'
set -uo pipefail
source "$1"
core="$2"; fixture="$3"; caller="$4"; hook_status="$5"; health_status="$6"
source "$core/compiler-cache-utils.sh"
# Installed-path lookup is redirected into a disposable fixture without touching /opt.
if declare -F compiler_cache_guarded_launcher >/dev/null; then
  eval "$(declare -f compiler_cache_guarded_launcher | sed "s|/opt/scripts/core|$fixture/installed|g")"
fi
t_source_functions "$core/common.sh" ensure_sccache_env compiler_cache_launcher
t_source_functions "$core/compiler-cache.sh" _resolve_compiler_cache_launcher sccache_export_server_address
eval "$(declare -f compiler_cache_launcher | sed "s|/opt/scripts/core|$fixture/installed|g")"
_COMMON_SH_DIR="$fixture/01-core"; _CC_SH_DIR="$_COMMON_SH_DIR"
sccache_configure_server_address() { printf 'address\n' >> "$fixture/trace"; }
sccache_start_server() { printf 'hook\n' >> "$fixture/trace"; return "$hook_status"; }
sccache() {
  printf '%s\n' "$*" >> "$fixture/trace"
  case "$1" in --version) printf 'sccache 0.14.0\n' ;; --start-server) return 7 ;; --show-stats) printf "stats stdout\n"; printf "stats stderr\n" >&2; return "$health_status" ;; *) return 99 ;; esac
}
ccache() { return 0; }
ensure_ccache_env() { return 0; }
info() { :; }
warn() { printf 'WARN %s\n' "$*" >&2; }
SCCACHE_DIR="$fixture/cache" USE_SCCACHE=1
case "$caller" in
  common) compiler_cache_launcher ;;
  standalone) unset -f compiler_cache_launcher; _resolve_compiler_cache_launcher ;;
  probe) source "$fixture/toolchain/probe-sccache.sh" ;;
esac
WORKER
}

_cache_readiness_case() {
  local caller="$1" hook="$2" health="$3" launcher="$4" WORK="$6"
  local rc out expected_rc expected_trace expected expected_error
  _cache_readiness_worker "$WORK"
  t_case "${caller} hook=${hook} health=${health} launcher=${launcher}"
  rm -f "$WORK/01-core/sccache-launcher.sh" "$WORK/trace"
  if [ "$launcher" = yes ]; then printf '#!/bin/sh\nexit 0\n' > "$WORK/01-core/sccache-launcher.sh"; chmod +x "$WORK/01-core/sccache-launcher.sh"; fi
  rc=0
  out="$(t_run_fixture_worker "$WORK/worker.sh" "$CORE" "$WORK" "$caller" "$hook" "$health" 2> "$WORK/err")" || rc=$?
  expected_rc=0; expected_trace=$'address\nhook'
  if [ "$hook" = 1 ]; then expected_trace+=$'\n--start-server'; fi
  expected_trace+=$'\n--show-stats'
  if [ "$caller" = probe ]; then
    expected_trace=$'--version\n--start-server\n--show-stats'
    [ "$health" = 0 ] || expected_rc=1
  fi
  t_assert_eq "$expected_rc" "$rc"
  t_assert_eq "$expected_trace" "$(cat "$WORK/trace")"
  expected_error=''
  if [ "$caller/$health" = common/1 ]; then expected_error=$'WARN sccache server did not answer — caller should fall back to ccache\nWARN falling back to ccache for this stage'; fi
  t_assert_eq "$expected_error" "$(cat "$WORK/err")"
  if [ "$caller" != probe ]; then
    expected=ccache
    if [ "$health" = 0 ]; then expected=sccache; [ "$launcher" != yes ] || expected="$WORK/01-core/sccache-launcher.sh"; fi
    t_assert_eq "$expected" "$out"
  else
    t_assert_contains "$out" '[probe-sccache] sccache: sccache 0.14.0'
  fi
  t_record_fixture_receipt "$RECEIPT" "$caller/$hook/$health/$launcher" "$rc" "${out//${WORK}/FIXTURE}" "$(cat "$WORK/err")"
  return 0
}

for caller in common standalone probe; do
  for hook in 0 1; do
    for health in 0 1; do
      for launcher in yes no; do
        _t_probe_file _cache_readiness_case "$caller" "$hook" "$health" "$launcher"
      done
    done
  done
done
t_summary
