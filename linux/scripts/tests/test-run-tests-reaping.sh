#!/usr/bin/env bash
# run-tests.sh kills each suite's whole process group: after it, on its timeout and when the run itself is interrupted.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_skip_unless "setsid (process groups)" command -v setsid

_WORK="$(mktemp -d)"
trap '_kill_recorded; rm -rf "${_WORK}"' EXIT
mkdir -p "${_WORK}/tests"
cp "${TESTS_DIR}/test-harness.sh" "${TESTS_DIR}/run-tests.sh" "${_WORK}/tests/"
cp "${1:-${TESTS_DIR}/../lib-ordered-jobs.sh}" "${_WORK}/lib-ordered-jobs.sh"

# _suite <name> <body>: a passing suite whose body may leave a child behind, recording its pid in <name>.pid.
_suite() {
  local directory="${3:-${_WORK}/tests}"
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/test-harness.sh"\nt_case one\n%s\nt_assert_ok true\nt_summary\n' "$2" \
    > "${directory}/$1"
}
_alive() {
  if [ ! -s "${_WORK}/$1.pid" ]; then printf 'dead\n'; return 0; fi
  t_pid_state "$(cat "${_WORK}/$1.pid")"
}
_kill_recorded() {
  local f
  for f in "${_WORK}"/*.group; do [ ! -s "${f}" ] || kill -KILL -- "-$(cat "${f}")" 2>/dev/null; done
  for f in "${_WORK}"/*.pid; do [ ! -s "${f}" ] || kill -KILL "$(cat "${f}")" 2>/dev/null; done
}
_clear() { _kill_recorded; rm -f "${_WORK}"/tests/test-[a-z]*-*.sh "${_WORK}"/*.pid "${_WORK}"/*.group; }

_launch_runner() {
  local output="$1"; shift
  setsid env "$@" bash "${_WORK}/tests/run-tests.sh" </dev/null >"$output" 2>&1 &
  runner=$!
  printf '%s\n' "$runner" > "${_WORK}/runner.group"
}
_wait_runner() {
  local label="$1" output="$2" limit="${3:-20}" state deadline
  deadline=$((SECONDS + limit))
  RUNNER_STATUS=0
  printf 'reaping wait: %s\n' "$label" >&2
  while :; do
    state="$(ps -o stat= -p "$runner" 2>/dev/null)"
    state="${state//[[:space:]]/}"
    case "$state" in
      ''|Z*|X*) wait "$runner" 2>/dev/null || RUNNER_STATUS=$?; return 0 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.1
  done
  printf 'FAIL: runner still active after %ss in %s\n' "$limit" "$label" >&2
  [ ! -f "$output" ] || tail -n 20 "$output" >&2
  kill -TERM -- "-$runner" 2>/dev/null || true
  sleep 1
  kill -KILL -- "-$runner" 2>/dev/null || true
  wait "$runner" 2>/dev/null || true
  return 1
}
_require_join() {
  _wait_runner "$@" && return 0
  t_assert_eq joined timed-out "runner $1 failed to stop after cancellation"
  t_summary
  exit 1
}
_require_file() {
  t_assert_ok t_wait_file "$1"
  [ -s "$1" ] || { t_summary; exit 1; }
}

t_case "a stuck runner has a bounded join and its process group is killed"
printf 'reaping case: %s\n' "$_T_CASE" >&2
setsid sleep 300 </dev/null >"${_WORK}/join.out" 2>&1 &
runner=$!
printf '%s\n' "$runner" > "${_WORK}/runner.group"
join_rc=0
_wait_runner forced-timeout "${_WORK}/join.out" 0 2>"${_WORK}/join.diagnostic" || join_rc=$?
t_assert_eq 1 "$join_rc" "a stuck runner was reported as joined"
t_assert_contains "$(cat "${_WORK}/join.diagnostic")" "runner still active after 0s in forced-timeout"
t_assert_eq dead "$(t_pid_state "$runner")" "a stuck runner survived its bounded join"
_clear

t_case "a child the suite leaves running is killed when the suite ends"
printf 'reaping case: %s\n' "$_T_CASE" >&2
_suite test-a-leak.sh "sleep 300 & echo \$! > '${_WORK}/leak.pid'"
out="$(timeout --kill-after=2s 20s bash "${_WORK}/tests/run-tests.sh" </dev/null 2>&1)"; rc=$?
t_assert_eq 0 "$rc" "the runner did not finish after its suite ended"
t_assert_contains "${out}" "All linux script test suites passed"
t_assert_eq "dead" "$(_alive leak)" "the leaked sleep outlived its suite"
_clear

t_case "a suite past RUN_TESTS_SUITE_TIMEOUT is killed with its children and fails the run"
printf 'reaping case: %s\n' "$_T_CASE" >&2
_suite test-b-hang.sh "sleep 300 & echo \$! > '${_WORK}/hang.pid'; wait"
out="$(RUN_TESTS_SUITE_TIMEOUT=2 timeout --kill-after=2s 12s bash "${_WORK}/tests/run-tests.sh" </dev/null 2>&1)"; rc=$?
t_assert_eq "1" "${rc}"
[ "${rc}" -eq 1 ] || { t_summary; exit 1; }
t_assert_contains "${out}" "TIMEOUT: killed after 2s"
t_assert_eq "dead" "$(_alive hang)" "the hung suite's child survived its timeout"
_clear

t_case "a run killed mid-suite takes the running suite's group with it"
printf 'reaping case: %s\n' "$_T_CASE" >&2
_suite test-c-slow.sh "sleep 300 & echo \$! > '${_WORK}/slow.pid'; wait"
_launch_runner "${_WORK}/slow.out"
_require_file "${_WORK}/slow.pid"
kill -TERM "${runner}"
_require_join mid-suite "${_WORK}/slow.out"
t_assert_eq "dead" "$(_alive slow)" "an interrupted run left its suite's child running"

_clear
t_case "interruption during PGID publication cannot leave a supervising worker or late suite alive"
printf 'reaping case: %s\n' "$_T_CASE" >&2
mkfifo "${_WORK}/release"
exec {release_fd}<>"${_WORK}/release"
cat > "${_WORK}/barrier.sh" <<'BASH'
if [ -z "${REAP_FIXTURE_OWNER:-}" ]; then REAP_FIXTURE_OWNER=$BASHPID; export REAP_FIXTURE_OWNER; fi
printf() {
  local caller_pid=$BASHPID target
  target="$(readlink "/proc/$caller_pid/fd/1" 2>/dev/null || true)"
  case "$target" in
    *.pgid)
      builtin printf '%s\n' "$BASHPID" > "$REAP_FIXTURE_ROOT/publication.pid"
      builtin printf '%s\n' "${@: -1}" > "$REAP_FIXTURE_ROOT/command.group"
      builtin printf ready > "$REAP_FIXTURE_ROOT/publication.ready"
      read -r _ < "$REAP_FIXTURE_ROOT/release"
      ;;
  esac
  builtin printf "$@"
}
kill() {
  if [ "$BASHPID" = "$REAP_FIXTURE_OWNER" ]; then builtin printf reaping > "$REAP_FIXTURE_ROOT/reaping"; fi
  builtin kill "$@"
}
BASH
_suite test-d-race.sh "sleep 300 & echo \$! > '${_WORK}/race.pid'; wait"
REAP_FIXTURE_OWNER=""
export REAP_FIXTURE_OWNER
_launch_runner "${_WORK}/race.out" REAP_FIXTURE_ROOT="${_WORK}" BASH_ENV="${_WORK}/barrier.sh"
_require_file "${_WORK}/publication.ready"
kill -TERM "$runner"
_require_file "${_WORK}/reaping"
printf 'release\n' >&"$release_fd"
_require_join publication "${_WORK}/race.out"
t_assert_eq dead "$(_alive publication)" "the runner exited before joining its blocked supervising worker"
t_assert_eq dead "$(_alive race)" "a suite started or survived after cancellation during publication"
exec {release_fd}>&-

for mode in interrupt timeout; do
  _clear
  t_case "a nested runner is reaped through its own EXIT cleanup on $mode"
  printf 'reaping case: %s\n' "$_T_CASE" >&2
  mkdir -p "${_WORK}/nested/tests"
  cp "${_WORK}/tests/run-tests.sh" "${_WORK}/tests/test-harness.sh" "${_WORK}/nested/tests/"
  cp "${_WORK}/lib-ordered-jobs.sh" "${_WORK}/nested/"
  _suite test-child-hang.sh "sleep 300 & echo \$! > '${_WORK}/nested-child.pid'; ps -o pgid= -p \$BASHPID | tr -d ' ' > '${_WORK}/nested.group'; wait" "${_WORK}/nested/tests"
  _suite test-e-nested.sh "RUN_TESTS_SUITE_TIMEOUT=900 bash '${_WORK}/nested/tests/run-tests.sh' & echo \$! > '${_WORK}/nested-owner.pid'; wait"
  duration=900; [ "$mode" != timeout ] || duration=2
  _launch_runner "${_WORK}/nested.out" RUN_TESTS_SUITE_TIMEOUT="$duration"
  _require_file "${_WORK}/nested-child.pid"
  if [ "$mode" = interrupt ]; then kill -TERM "$runner"; fi
  _require_join "nested $mode" "${_WORK}/nested.out"
  status="$RUNNER_STATUS"
  expected=143; [ "$mode" != timeout ] || expected=1
  t_assert_eq "$expected" "$status"
  t_assert_eq dead "$(_alive nested-owner)" "a nested runner outlived cancellation"
  t_assert_eq dead "$(_alive nested-child)" "a nested runner's separate child group survived cancellation"
done

t_summary
