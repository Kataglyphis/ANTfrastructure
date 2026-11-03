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

# Phases and gates against real markers; not covered: which phase a real lane's peak lands in, which needs a chain.
BRM="${TESTS_DIR}/../build-runtime-manifest.sh"
eval "$(t_fn_src "${TESTS_DIR}/../lib-orchestrator.sh" runtime_step_mark)"
eval "$(t_fn_src "${TESTS_DIR}/../lib-orchestrator.sh" runtime_step_phase)"
_steps="${WORK}/phase-steps"
_marks() { ls "${_steps}" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

t_case "a lane phase holds index.<step> while it runs and returns its status"
(
  export RESOURCE_MONITOR_STEP_DIR="${_steps}"
  _probe() { _marks > "${WORK}/seen"; return "$1"; }
  rc=0; runtime_step_phase manifest _probe 0 || rc=$?
  t_assert_eq "0" "${rc}"
  t_assert_eq "index.manifest" "$(cat "${WORK}/seen")"
  t_assert_eq "" "$(_marks)" "a finished phase drops its marker"
  rc=0; runtime_step_phase acceptance _probe 7 || rc=$?
  t_assert_eq "7" "${rc}" "the status reaches the caller"
  t_assert_eq "" "$(_marks)" "a failed phase drops its marker too"
  exit "${_T_FAILED}"
)
t_assert_eq "0" "$?" "the phase assertions above"

t_case "a phase's body keeps the caller's errexit, as a wrapped runtime_step_run would not"
_out="$(bash -c 'source <(sed -n "/^runtime_step_mark() {\$/,/^}\$/p;/^runtime_step_phase() {\$/,/^}\$/p" "$1")
  set -e
  body() { false; echo body-went-on; }
  runtime_step_phase manifest body
  echo lane-went-on' _ "${TESTS_DIR}/../lib-orchestrator.sh" 2>&1)"; _rc=$?
t_assert_eq "1" "${_rc}" "${_out}"
t_assert_eq "" "${_out}" "neither the body nor the lane continues past a failed command"

t_case "a gate names its arch and script while it runs, and keeps its status"
(
  export RESOURCE_MONITOR_STEP_DIR="${_steps}"
  eval "$(t_fn_src "${BRM}" _manifest_gate_arch)"
  runtime_wrapper_tag() { printf 'img:%s' "$1"; }
  _manifest_pull_if_missing() { _marks > "${WORK}/pull-seen"; }
  log() { :; }
  run() { _marks > "${WORK}/gate-seen"; return "${GATE_RC:-0}"; }
  rc=0; GATE_RC=3 _manifest_gate_arch "Wrapper content gate" /x/verify-shipped-wrapper.sh arm64 || rc=$?
  t_assert_eq "3" "${rc}" "a failed gate fails its caller"
  t_assert_eq "arm64.verify-shipped-wrapper" "$(cat "${WORK}/gate-seen")"
  t_assert_eq "arm64.verify-shipped-wrapper" "$(cat "${WORK}/pull-seen")" "the pull is part of the gate's cost"
  t_assert_eq "" "$(_marks)"
  exit "${_T_FAILED}"
)
t_assert_eq "0" "$?" "the gate assertions above"

t_case "every phase after the arch loop is named"
_main="$(t_fn_src "${BRM}" main)"
_build="$(t_fn_src "${BRM}" _manifest_build_and_smoke)"
for _phase in 'reuse-plan _manifest_plan_reuse' 'manifest create_manifest' 'freshness _manifest_check_freshness' 'drop-pushed _manifest_drop_pushed_images'; do
  t_assert_contains "${_main}" "runtime_step_phase ${_phase}"
done
for _phase in 'binfmt ensure_foreign_binfmt' 'input-preflight runtime_input_preflight' 'reuse-pull runtime_reuse_pull' 'push-wait runtime_push_queue_finish'; do
  t_assert_contains "${_build}" "runtime_step_phase ${_phase}"
done
t_assert_contains "$(t_fn_src "${BRM}" create_manifest)" "runtime_step_phase acceptance _manifest_accept_and_promote"

t_summary
