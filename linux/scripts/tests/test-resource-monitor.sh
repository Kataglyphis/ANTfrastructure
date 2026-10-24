#!/usr/bin/env bash
# Log discovery preserves whitespace and marker priority; summary failures cannot replace the sampled process's status.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
MONITOR="${TESTS_DIR}/../01-core/resource-monitor.sh"
eval "$(t_fn_src "${MONITOR}" _rm_active_log)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/logs with spaces"
older="${WORK}/logs with spaces/old stage.log"
newer="${WORK}/logs with spaces/new stage.log"
printf 'old\n' > "${older}"
printf 'new\n' > "${newer}"
touch -t 202601010000 "${older}"
touch -t 202601020000 "${newer}"
t_case "the explicit stage log wins over discovery"
t_assert_eq /explicit/stage.log "$(_rm_active_log /explicit/stage.log "${WORK}")"
t_case "without markers, the newest log wins even when paths contain spaces"
t_assert_eq "${newer}" "$(_rm_active_log '' "${WORK}/logs with spaces")"
touch "${older}.run"
t_case "a marked stage log wins over a newer orchestrator log"
t_assert_eq "${older}" "$(_rm_active_log '' "${WORK}/logs with spaces")"
touch "${newer}.run"
t_case "the newest marked stage log wins"
t_assert_eq "${newer}" "$(_rm_active_log '' "${WORK}/logs with spaces")"
t_case "missing log directories produce no invented path"
t_assert_eq '' "$(_rm_active_log '' "${WORK}/missing")"
exit_handler="$(t_fn_src "${MONITOR}" _rm_on_exit)"
_exit_with_summary() {
  bash -c 'eval "$1"; RM_CSV=fixture; rm_summarize() { return 99; }; trap _rm_on_exit EXIT; exit "$2"' _ "${exit_handler}" "$1"
}
t_case "an exit trap preserves failure and success even if summarizing fails"
t_assert_eq 7 "$(t_rc _exit_with_summary 7)"
t_assert_eq 0 "$(t_rc _exit_with_summary 0)"
eval "$(t_fn_src "${TESTS_DIR}/../lib-orchestrator.sh" start_resource_monitor)"
REPO_ROOT="${WORK}/repo"
mkdir -p "${REPO_ROOT}/linux/scripts/01-core"
cat > "${REPO_ROOT}/linux/scripts/01-core/resource-monitor.sh" <<'MONITOR'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${MON_CALLS}"
MONITOR
chmod +x "${REPO_ROOT}/linux/scripts/01-core/resource-monitor.sh"
warn() { :; }
log() { :; }
pgrep() { return 1; }
export MON_CALLS="${WORK}/monitor-args"
LOG_DIR=""
CROSS_RUN_ID=""

t_case "the orchestrator's resource CSV defaults under logs"
start_resource_monitor fixture
t_assert_ok t_wait_file "${MON_CALLS}" 30
wait "$!"
t_assert_ok test -d "${REPO_ROOT}/logs"
t_assert_contains "$(cat "${MON_CALLS}")" "--out-dir ${REPO_ROOT}/logs"

t_case "an explicit stage log directory still owns its resource CSV"
LOG_DIR="${WORK}/chosen-logs"
rm -f "${MON_CALLS}"
start_resource_monitor fixture
t_assert_ok t_wait_file "${MON_CALLS}" 30
wait "$!"
t_assert_ok test -d "${LOG_DIR}"
t_assert_contains "$(cat "${MON_CALLS}")" "--out-dir ${LOG_DIR}"

_probe_monitor_default() (
  eval "$(t_fn_src "${MONITOR}" main)"
  _rm_sample_loop() { printf '%s' "$1"; }
  _rm_on_exit() { :; }
  LOG_DIR="$1"
  shift
  main "$@"
  trap - EXIT
)

t_case "standalone sampling defaults to logs and keeps --out-dir explicit"
t_assert_eq logs "$(_probe_monitor_default '')"
t_assert_eq /chosen "$(_probe_monitor_default '' --out-dir /chosen)"

t_summary
