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
eval "$(t_fn_src "${MONITOR}" _rm_steps)"
eval "$(t_fn_src "${MONITOR}" _rm_stage)"
steps="${WORK}/steps"
mkdir -p "${steps}"
printf '#5 [stage-x 1/2] RUN\n' > "${WORK}/stage.log"
t_case "without step markers the stage comes from the active log, else the label"
t_assert_eq stage-x "$(_rm_stage "${WORK}/stage.log" lbl "${steps}")"
t_assert_eq lbl "$(_rm_stage '' lbl "${steps}")"
t_case "the runtime lane's markers name every active arch and step, joined without a comma"
: > "${steps}/amd64.push"
: > "${steps}/arm64.package"
t_assert_eq "amd64/push+arm64/package" "$(_rm_stage "${WORK}/stage.log" lbl "${steps}")"
t_case "a marker directory without markers falls back"
rm -f "${steps}"/*
t_assert_eq stage-x "$(_rm_stage "${WORK}/stage.log" lbl "${steps}")"

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
printf '%s step-dir=%s\n' "$*" "${RESOURCE_MONITOR_STEP_DIR:-}" > "${MON_CALLS}"
MONITOR
chmod +x "${REPO_ROOT}/linux/scripts/01-core/resource-monitor.sh"
warn() { :; }
log() { :; }
pgrep() { return 1; }
export MON_CALLS="${WORK}/monitor-args"
LOG_DIR=""

_assert_monitor_dir() {
  local expected="$1"
  rm -f "${MON_CALLS}"
  CROSS_RUN_ID='' start_resource_monitor fixture
  t_assert_ok t_wait_file "${MON_CALLS}" 30
  wait "$!"
  t_assert_ok test -d "${expected}"
  t_assert_contains "$(cat "${MON_CALLS}")" "--out-dir ${expected}"
  t_assert_contains "$(cat "${MON_CALLS}")" "step-dir=${expected}/.steps-fixture"
  t_assert_eq "${expected}/.steps-fixture" "${RESOURCE_MONITOR_STEP_DIR}"
  unset RESOURCE_MONITOR_STEP_DIR
}

t_case "the orchestrator's resource CSV defaults under logs"
_assert_monitor_dir "${REPO_ROOT}/logs"

t_case "an explicit stage log directory still owns its resource CSV"
LOG_DIR="${WORK}/chosen-logs"
_assert_monitor_dir "${LOG_DIR}"

t_case "the summary counts low-disk samples against the disk-watch floor (CON141)"
t_assert_contains "$(cat "${MON_CALLS}")" "--low-disk-gb 40"
CROSS_DISK_GUARD_GB=55 _assert_monitor_dir "${LOG_DIR}"
t_assert_contains "$(cat "${MON_CALLS}")" "--low-disk-gb 55"
RM_LOW_DISK_GB=12 CROSS_DISK_GUARD_GB=55 _assert_monitor_dir "${LOG_DIR}"
t_assert_contains "$(cat "${MON_CALLS}")" "--low-disk-gb 12" "an explicit RM_LOW_DISK_GB still wins"

_probe_monitor_default() (
  eval "$(t_fn_src "${MONITOR}" main)"
  _rm_sample_loop() { printf '%s' "$1"; }
  _rm_on_exit() { :; }
  LOG_DIR="$1"
  shift
  main "$@"
  trap - EXIT
)

t_case "a child lane keeps the step directory its parent exported, so one monitor reads both"
mkdir -p "${WORK}/parent-steps"
: > "${WORK}/parent-steps/amd64.push"
export RESOURCE_MONITOR_STEP_DIR="${WORK}/parent-steps"
rm -f "${MON_CALLS}"
CROSS_RUN_ID='' start_resource_monitor fixture
t_assert_ok t_wait_file "${MON_CALLS}" 30
wait "$!"
t_assert_contains "$(cat "${MON_CALLS}")" "step-dir=${WORK}/parent-steps"
t_assert_ok test -f "${WORK}/parent-steps/amd64.push"
unset RESOURCE_MONITOR_STEP_DIR

t_case "standalone sampling defaults to logs and keeps --out-dir explicit"
t_assert_eq logs "$(_probe_monitor_default '')"
t_assert_eq /chosen "$(_probe_monitor_default '' --out-dir /chosen)"

t_summary
