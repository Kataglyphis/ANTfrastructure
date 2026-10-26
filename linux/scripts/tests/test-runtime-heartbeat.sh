#!/usr/bin/env bash
# Timer fixtures cover heartbeat lifecycle and dry runs; they do not build or smoke-test images.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
FNS="$(t_fn_src "${TESTS_DIR}/../01-core/runtime-build-fns.sh" _runtime_heartbeat)" || exit 1
FNT="$(t_fn_src "${TESTS_DIR}/../01-core/runtime-build-fns.sh" _runtime_timed)" || exit 1
_LOG="$(mktemp)"
trap 'rm -f "${_LOG}"' EXIT
# Short fixture timers bound failures in startup and cleanup paths.
export RUNTIME_HEARTBEAT_FIRST_SECS=5
log() { echo "$*" >> "${_LOG}"; }
is_dry_run() { if [ "${DRY_RUN:-0}" = 1 ]; then return 0; fi; return 1; }
eval "${FNS}"
eval "$(t_fn_src "${TESTS_DIR}/../01-core/parallel-loop.sh" parallel_require_child_stop)" || exit 1
eval "$(t_fn_src "${TESTS_DIR}/../01-core/parallel-loop.sh" parallel_stop_child_advisory)" || exit 1
eval "${FNT}"
eval "$(t_fn_src "${TESTS_DIR}/../lib-orchestrator.sh" runtime_step_mark)" || exit 1
eval "$(t_fn_src "${TESTS_DIR}/../lib-orchestrator.sh" runtime_step_run)" || exit 1

t_case "a step under the first threshold prints no heartbeat"
: > "${_LOG}"
RUNTIME_HEARTBEAT_FIRST_SECS=5 RUNTIME_HEARTBEAT_EVERY_SECS=1 _runtime_timed quick amd64 sleep 0.2
t_assert_eq "0" "$(grep -c heartbeat "${_LOG}")"

t_case "a long step prints heartbeats, then the timing line, and the heartbeat stops"
: > "${_LOG}"
RUNTIME_HEARTBEAT_FIRST_SECS=1 RUNTIME_HEARTBEAT_EVERY_SECS=1 _runtime_timed long riscv64 sleep 3.5
t_assert_eq "1" "$([ "$(grep -c '\[heartbeat riscv64 long\]' "${_LOG}")" -ge 2 ] && echo 1 || echo 0)"
t_assert_contains "$(tail -n 1 "${_LOG}")" "[runtime-timing] arch=riscv64 step=long"
before="$(wc -l < "${_LOG}")"
sleep 2.5
t_assert_eq "${before}" "$(wc -l < "${_LOG}")"

t_case "dry runs keep command status and timing without starting a heartbeat"
dry_run_probe() (
  _runtime_heartbeat() { printf 'unexpected heartbeat\n' >> "${_LOG}"; }
  kill() { printf 'unexpected heartbeat cleanup\n' >> "${_LOG}"; builtin kill "$@"; }
  DRY_RUN=1 _runtime_timed dry arm64 bash -c 'exit 23'
)
: > "${_LOG}"
t_assert_eq 23 "$(t_rc dry_run_probe)"
t_assert_contains "$(cat "${_LOG}")" 'step=dry secs='
t_assert_eq 0 "$(grep -c 'unexpected heartbeat' "${_LOG}")"
t_case "a timed step holds its monitor marker while it runs and drops it after, on failure too"
export RESOURCE_MONITOR_STEP_DIR="${_LOG}.steps"
_marker_probe() { ls "${RESOURCE_MONITOR_STEP_DIR}" > "${_LOG}.seen"; return 9; }
t_assert_eq 9 "$(t_rc _runtime_timed package arm64 _marker_probe)"
t_assert_eq "arm64.package" "$(cat "${_LOG}.seen")"
t_assert_eq "" "$(ls "${RESOURCE_MONITOR_STEP_DIR}")"
t_case "without a monitor the lane writes no marker"
RESOURCE_MONITOR_STEP_DIR="" _runtime_timed quick amd64 true
t_assert_eq "" "$(ls "${RESOURCE_MONITOR_STEP_DIR}")"
t_case "a marked command keeps its caller's bindings and argument boundaries"
_bound_probe() { local _caller_var=step; printf '%s|' "${!_caller_var}" "$@" > "${_LOG}.seen"; }
_runtime_timed bound amd64 _bound_probe 'a b' ''
t_assert_eq "bound|a b||" "$(cat "${_LOG}.seen")"
t_assert_eq "" "$(ls "${RESOURCE_MONITOR_STEP_DIR}")" "a passed step drops its marker"
rm -rf "${RESOURCE_MONITOR_STEP_DIR}" "${_LOG}.seen"
unset RESOURCE_MONITOR_STEP_DIR

t_case "termination during heartbeat child startup closes inherited output pipes"
env HEARTBEAT_FNS="${FNS}" python3 - <<'PYTHON'
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

with tempfile.TemporaryDirectory() as work:
    script = r'''
set -uT
log() { :; }
# An ignored TERM models the timer child missing TERM at exec while its parent exits.
sleep() { trap '' TERM; : > "$HEARTBEAT_READY"; exec /bin/sleep 20; }
trap 'if [[ "${FUNCNAME[0]:-}" == _runtime_heartbeat && "$BASH_COMMAND" == *"=\$!" ]]; then kill -TERM "$BASHPID"; fi' DEBUG
''' + os.environ["HEARTBEAT_FNS"] + r'''
_runtime_heartbeat probe amd64 0 &
printf '%s' "$!" > "$HEARTBEAT_PID"
wait "$!"
'''
    ready = Path(work, "ready")
    pidfile = Path(work, "pid")
    env = dict(os.environ, HEARTBEAT_READY=str(ready), HEARTBEAT_PID=str(pidfile))
    proc = subprocess.Popen(["bash", "-c", script], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    try:
        deadline = time.monotonic() + 5
        while not (ready.exists() and pidfile.exists()) and time.monotonic() < deadline:
            time.sleep(0.01)
        assert ready.exists() and pidfile.exists(), "heartbeat child did not start"
        if proc.poll() is None:
            os.kill(int(pidfile.read_text()), signal.SIGTERM)
        try:
            stdout, stderr = proc.communicate(timeout=2)
        except subprocess.TimeoutExpired as exc:
            raise AssertionError("heartbeat timer child survived parent TERM") from exc
        assert proc.returncode == 0, stderr.decode()
    finally:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
PYTHON
t_assert_eq 0 "$?" "heartbeat timer is reaped after TERM"

t_summary
