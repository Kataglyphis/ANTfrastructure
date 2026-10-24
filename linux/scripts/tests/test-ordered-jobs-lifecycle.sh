#!/usr/bin/env bash
# Owned-worker fixtures cover signals, reporting and trap preservation, not detached sessions or kernel signal-delivery failures.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
library="${1:-${TESTS_DIR}/../lib-ordered-jobs.sh}"
work="$(mktemp -d)"
_ordered_cleanup_session() {
  local session="$1" group
  for group in $(ps -eo sid=,pgid= | awk -v owner="$session" '$1 == owner {print $2}' | sort -u); do
    kill -TERM -- "-$group" 2>/dev/null || true
    kill -KILL -- "-$group" 2>/dev/null || true
  done
  wait "$session" 2>/dev/null || true
}
_ordered_cleanup() {
  local file
  for file in "$work"/*.session; do [ ! -s "$file" ] || _ordered_cleanup_session "$(cat "$file")"; done
  rm -rf "$work"
}
trap _ordered_cleanup EXIT

for mode in empty allocation-failure; do
  t_case "$mode leaves returning and ignored caller traps unchanged"
  result="$(bash -u -s -- "$library" "$mode" <<'BASH'
source "$1"
trap 'printf custom >/dev/null' TERM
trap '' INT
before="$(trap -p TERM INT)"
report() { printf 'unexpected report\n'; }
if [ "$2" = allocation-failure ]; then oj_add true; mktemp() { return 7; }; fi
status=0; oj_run 1 report || status=$?
printf '%s\n' "$status" "$before" "$(trap -p TERM INT)"
BASH
)"
  expected=0; [ "$mode" != allocation-failure ] || expected=1
  t_assert_eq "$expected" "$(printf '%s\n' "$result" | head -1)"
  t_assert_eq "$(printf '%s\n' "$result" | sed -n '2,3p')" "$(printf '%s\n' "$result" | sed -n '4,5p')"
done

for scenario in TERM:returning TERM:ignored INT:returning INT:ignored; do
  signal=${scenario%%:*}; policy=${scenario#*:}
  t_case "$policy $signal remains active while scheduled work and unrelated caller jobs are running"
  dir="$work/$signal-$policy"; mkdir -p "$dir"; mkfifo "$dir/release"
  exec {release_fd}<>"$dir/release"
  cat > "$dir/runner.sh" <<'BASH'
set -uo pipefail
source "$1"
dir=$2; policy=$3; signal=$4; calls=0
trap 'oj_reap; kill "$unrelated" 2>/dev/null; wait "$unrelated" 2>/dev/null' EXIT
sleep 300 & unrelated=$!
if [ "$policy" = ignored ]; then trap '' "$signal"
else trap 'calls=$((calls + 1)); printf handled > "$dir/handled"' "$signal"; fi
before="$(trap -p "$signal")"
task() { printf ready > "$dir/ready"; read -r _ < "$dir/release"; }
report() { printf 'report=%s\n' "$2"; }
oj_add task
oj_run 1 report
printf 'calls=%s\n' "$calls"
[ "$(trap -p "$signal")" = "$before" ] && printf 'trap=preserved\n'
kill -0 "$unrelated" && printf 'unrelated=alive\n'
BASH
  setsid python3 -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp("bash", ["bash", *sys.argv[1:]])' "$dir/runner.sh" "$library" "$dir" "$policy" "$signal" > "$dir/out" 2> "$dir/err" &
  runner=$!
  printf '%s\n' "$runner" > "$work/$signal-$policy.session"
  t_assert_ok t_wait_file "$dir/ready"
  if [ ! -s "$dir/ready" ]; then _ordered_cleanup_session "$runner"; exec {release_fd}>&-; continue; fi
  if [ "$signal" = INT ]; then kill -INT -- "-$runner"; else kill -TERM "$runner"; fi
  if [ "$policy" = returning ]; then t_assert_ok t_wait_file "$dir/handled"; fi
  t_assert_ok kill -0 "$runner"
  printf 'release\n' >&"$release_fd"
  status=0; wait "$runner" || status=$?
  exec {release_fd}>&-
  rm -f "$work/$signal-$policy.session"
  t_assert_eq 0 "$status"
  t_assert_contains "$(cat "$dir/out")" 'report=0'
  t_assert_contains "$(cat "$dir/out")" 'trap=preserved'
  t_assert_contains "$(cat "$dir/out")" 'unrelated=alive'
  expected=0; [ "$policy" != returning ] || expected=1
  t_assert_contains "$(cat "$dir/out")" "calls=$expected"
done

t_case 'the groupless fallback does not add a timeout supervisor'
result="$(bash -u -s -- "$library" <<'BASH'
source "$1"
OJ_GROUPS=0; OJ_TIMEOUT=1
_oj_start_watchdog() { printf 'unexpected watchdog\n'; exit 9; }
report() { printf 'report=%s\n' "$2"; }
oj_add true
oj_run 1 report
BASH
)"
t_assert_eq report=0 "$result"

for failure in cleanup supervisor-0 supervisor-7 supervisor-143; do
  t_case "$failure failure reaches the actual run-tests failing summary instead of hanging or going green"
  dir="$work/$failure"; mkdir -p "$dir/tests"
  cp "$TESTS_DIR/run-tests.sh" "$TESTS_DIR/test-harness.sh" "$dir/tests/"
  cp "$library" "$dir/lib-ordered-jobs.sh"
  if [ "$failure" = cleanup ]; then
    cat >> "$dir/lib-ordered-jobs.sh" <<'BASH'
eval "$(declare -f _oj_worker_reap | sed '1s/_oj_worker_reap/_oj_real_worker_reap/')"
_oj_worker_reap() { _oj_real_worker_reap; return 1; }
BASH
  else
    printf '\n_oj_start() { exit %s; }\n' "${failure#supervisor-}" >> "$dir/lib-ordered-jobs.sh"
  fi
  printf 'source "$(dirname "$0")/test-harness.sh"\nt_assert_ok true\nt_summary\n' > "$dir/tests/test-fixture.sh"
  status=0
  timeout 12 bash "$dir/tests/run-tests.sh" > "$dir/out" 2>&1 || status=$?
  t_assert_eq 1 "$status"
  t_assert_contains "$(cat "$dir/out")" '1 suite(s) failed: test-fixture.sh'
done
t_summary
