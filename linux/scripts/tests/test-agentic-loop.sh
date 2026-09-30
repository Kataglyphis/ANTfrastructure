#!/usr/bin/env bash
# Characterisation of lib/agentic-loop.sh and its engine half. See docs/agentic-loop-build-matrix.md#bash-agentic-loopsh
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${TESTS_DIR}/../lib/agentic-loop.sh"

t_case "jq is on PATH — agentic-loop's config readers are one jq pass"
t_assert_ok command -v jq

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
mkdir -p "${_work}/prompts"

cat > "${_work}/config.json" <<'J'
{
  "engine": "opencode",
  "engines": {
    "opencode": { "plannerModel": "oc/planner", "executorModel": "oc/executor" },
    "claude": {
      "plannerModel": "cl/planner", "executorModel": "cl/executor",
      "plannerPromptFile": "prompts/planner.md",
      "executorPromptFile": "/absolute/executor.md"
    }
  },
  "intervals": { "agentRetries": 2, "agentRetryDelaySeconds": 20 }
}
J

# Run a snippet with the library sourced and log() pointed at a scratch file.
_lib() { bash -c "set -u
LOG_FILE='${_work}/loop.log'
source '${LIB}'
LOG_FILE='${_work}/loop.log'
$1" 2>&1; }

# ── 1. engine configuration ─────────────────────────────────────────────
t_case "the config's own engine is used, and unset knobs take their defaults"
_out="$(_lib 'load_engine_config "'"${_work}"'/config.json" "'"${_work}"'" >/dev/null
        echo "${AGENTIC_ENGINE}|${PLANNER_MODEL}|${EXECUTOR_MODEL}|${AGENT_RETRIES}|${AGENT_RETRY_DELAY}|${CLAUDE_PERMISSION_MODE}"')"
t_assert_eq "opencode|oc/planner|oc/executor|2|20|bypassPermissions" "${_out}"

# Selects the claude engine for the next two cases.
_claude_cfg() { _lib "export AGENTIC_ENGINE=claude
        load_engine_config '${_work}/config.json' '${_work}' >/dev/null
        $1"; }

t_case "AGENTIC_ENGINE overrides the config and selects that engine's models"
t_assert_eq "claude|cl/planner|cl/executor" \
  "$(_claude_cfg 'echo "${AGENTIC_ENGINE}|${PLANNER_MODEL}|${EXECUTOR_MODEL}"')"

t_case "an explicit model env override beats the config file"
_out="$(_lib 'export AGENTIC_PLANNER_MODEL=env/planner
        load_engine_config "'"${_work}"'/config.json" "'"${_work}"'" >/dev/null
        echo "${PLANNER_MODEL}"')"
t_assert_eq "env/planner" "${_out}"

t_case "a repo-relative prompt file is resolved against repo_root; an absolute one is left alone"
t_assert_eq "${_work}/prompts/planner.md|/absolute/executor.md" \
  "$(_claude_cfg 'echo "${CLAUDE_PLANNER_PROMPT_FILE}|${CLAUDE_EXECUTOR_PROMPT_FILE}"')"

t_case "an engine with no models configured is FATAL, not a silent default"
printf '{ "engine": "opencode", "engines": {}, "intervals": {} }\n' > "${_work}/empty.json"
_out="$(_lib 'load_engine_config "'"${_work}"'/empty.json" "'"${_work}"'"; echo "rc=$?"')"
t_assert_contains "${_out}" "No planner/executor model configured"
t_assert_contains "${_out}" "rc=1" "returning 0 here would run the loop with an empty model id"

# ── 2. invoke_agent, with the engine faked ──────────────────────────────
_ATTEMPTS="${_work}/attempts"
# DRY_RUN=true skips invoke_agent's real back-off sleeps.
_agent() { _lib "
: > '${_ATTEMPTS}'
invoke_opencode() { echo \"\$1\" >> '${_ATTEMPTS}'; return ${1}; }
invoke_claude()   { echo \"claude:\$1\" >> '${_ATTEMPTS}'; return ${1}; }
AGENTIC_ENGINE='${2}' PLANNER_MODEL=m EXECUTOR_MODEL=m AGENT_RETRIES=2 AGENT_RETRY_DELAY=1 DRY_RUN=true \\
  invoke_agent '${3}' 'msg'; echo \"rc=\$?\""; }

t_case "a successful engine call is made once and returns 0"
_out="$(_agent 0 opencode executor)"
t_assert_contains "${_out}" "rc=0"
t_assert_eq "1" "$(wc -l < "${_ATTEMPTS}")" "success must not retry"

t_case "a failing engine is retried AGENT_RETRIES times, then the exit code is propagated"
_out="$(_agent 3 opencode executor)"
t_assert_contains "${_out}" "rc=3" "the engine's own exit code is the verdict, not a flattened 1"
t_assert_eq "3" "$(wc -l < "${_ATTEMPTS}")" "one attempt plus two retries"
t_assert_contains "${_out}" "Agent failed after 3 attempt(s)"

t_case "the fixer role runs on the executor agent, not an agent named 'fixer'"
_agent 0 opencode fixer >/dev/null
t_assert_eq "executor" "$(cat "${_ATTEMPTS}")"

t_case "every OTHER role survives that mapping under a consumer's errexit"
# An AND-OR list's failing test is errexit-exempt, but fatal as a function's last statement. See docs/agentic-loop-build-matrix.md#the-two-bash-files
_out="$(bash -c "set -eu
LOG_FILE='${_work}/loop.log'
: > '${_ATTEMPTS}'
source '${LIB}'
invoke_opencode() { echo \"\$1\" >> '${_ATTEMPTS}'; return 0; }
AGENTIC_ENGINE=opencode PLANNER_MODEL=m EXECUTOR_MODEL=m DRY_RUN=true invoke_agent executor msg
echo reached-the-end" 2>&1)"
t_assert_contains "${_out}" "reached-the-end" "errexit must not end the run on the role that is NOT the fixer"
t_assert_eq "executor" "$(cat "${_ATTEMPTS}")" "the adapter must still have been called once"

t_case "an unknown engine is FATAL and never falls through to a default"
_out="$(_agent 0 podracer executor)"
t_assert_contains "${_out}" "Unknown engine"
t_assert_contains "${_out}" "rc=1"
t_assert_eq "0" "$(wc -c < "${_ATTEMPTS}")" "no adapter may be invoked for an engine that does not exist"

# ── 3. one executor-queue drain; the faked agent ticks one task, i.e. progress ──
_drain() { _lib "
_AL[repo_root]='${_work}'; _AL[delete_completed]=false; _AL[max_retries]=2
_AL[tasks_completed]=0; _AL[consecutive_build_failures]=0
_AL[max_consecutive_build_failures]=3
_agentic_after_task_phases() { :; }
invoke_agent() { ${1}; }
_agentic_drain_executor_queue 1; echo \"rc=\$?\"
echo \"completed=\${_AL[tasks_completed]}\""; }

t_case "the drain runs until the queue is empty and counts every completed task"
printf -- '- [ ] one\n- [ ] two\n' > "${_work}/BACKLOG.md"
_out="$(_drain "sed -i '0,/^- \[ \]/s//- [x]/' '${_work}/BACKLOG.md'")"
t_assert_contains "${_out}" "Tasks in queue: 2"
t_assert_contains "${_out}" "completed=2"
t_assert_contains "${_out}" "rc=0"

t_case "an executor that makes NO progress stops at max_retries instead of spinning"
printf -- '- [ ] one\n' > "${_work}/BACKLOG.md"
_out="$(_drain ":")"
t_assert_contains "${_out}" "Retry 1/2"
t_assert_contains "${_out}" "Max retries reached"
t_assert_contains "${_out}" "completed=0"
t_assert_contains "${_out}" "rc=0" "a stalled queue ends the drain; it is not a loop failure"

t_case "a backlog holding only BLOCKED tasks reads as an empty queue"
printf -- '- [b] blocked on the SDK\n' > "${_work}/BACKLOG.md"
_out="$(_drain ":")"
t_assert_contains "${_out}" "Tasks in queue: 0"
t_assert_contains "${_out}" "completed=0" "blocked work must let the planner run again, not stall the executor"

# ── 3b. opencode v2 only; the strings are real --version output. See docs/windows-agentic-loop.md#opencode-v2
t_case "opencode_major_version reads both CLIs' --version; unreadable is 0"
t_assert_eq "1" "$(_lib 'opencode_major_version "1.18.33"')"
t_assert_eq "2" "$(_lib 'opencode_major_version "opencode v2.0.18"')"
t_assert_eq "0" "$(_lib 'opencode_major_version ""')" "an unreadable version must not pass for v2"

t_case "both roles run --standalone, only the executor gets --auto"
_out="$(_lib 'opencode_run_args executor m | tr "\n" " "')"
t_assert_eq "run --agent executor --model m --standalone --auto " "${_out}" \
  "a headless v2 run auto-rejects every ask permission without --auto"
_out="$(_lib 'opencode_run_args planner m | tr "\n" " "')"
t_assert_eq "run --agent planner --model m --standalone " "${_out}" \
  "the planner stays restricted, as it is under the claude engine"

t_case "a dry run shows the v2 command line"
_out="$(_lib 'DRY_RUN=true invoke_opencode executor m msg')"
t_assert_contains "${_out}" "[DRY RUN] opencode run --agent executor --model m --standalone --auto"

t_case "a v1 opencode on PATH is FATAL and never gets a run"
_out="$(_lib 'opencode() { if [[ "$1" == --version ]]; then echo 1.18.33; else echo RAN-RUN; fi; }
invoke_opencode executor m msg; echo "rc=$?"')"
t_assert_contains "${_out}" "opencode v2 is required; PATH has '1.18.33'"
t_assert_contains "${_out}" "rc=1"
t_assert_eq "0" "$(grep -c RAN-RUN <<< "${_out}")" "v1 must not be handed v2's flags"

# ── 4. the F2 seam: the entry point loads the engine half, and no function lives in both ──
ENGINES="${TESTS_DIR}/../lib/agentic-engines.sh"

t_case "sourcing the entry point alone defines both halves"
_out="$(bash -c "source '${LIB}' >/dev/null 2>&1
  for f in log unchecked_task_count load_engine_config invoke_agent invoke_claude \\
           invoke_opencode claude_stream_render usage_limit_wait_seconds; do
    declare -F \"\${f}\" >/dev/null || echo \"MISSING \${f}\"
  done; echo DONE")"
t_assert_eq "DONE" "${_out}" "a consumer sources agentic-loop.sh and nothing else"

t_case "the entry point resolves its sibling by BASH_SOURCE, not by cwd"
_out="$(cd / && bash -c "source '${LIB}' >/dev/null 2>&1; declare -F invoke_agent >/dev/null && echo YES")"
t_assert_eq "YES" "${_out}" "external repos source this by absolute path from their own tree"

t_case "the engine half owns the adapters and none of the loop driver"
_out="$(bash -c "source '${ENGINES}' >/dev/null 2>&1
  declare -F invoke_agent >/dev/null || echo NO_ADAPTER
  declare -F run_agentic_loop >/dev/null && echo DRIVER_LEAKED
  declare -F unchecked_task_count >/dev/null && echo BACKLOG_LEAKED
  echo DONE")"
t_assert_eq "DONE" "${_out}" "the split is by subject; a leaked driver function means a half moved back"

t_case "neither file defines the same function twice"
_dupes="$(cat "${LIB}" "${ENGINES}" | sed -n 's/^\([a-z_][a-z0-9_]*\)() {$/\1/p' | sort | uniq -d)"
t_assert_eq "" "${_dupes}" "one owner per function — a re-inlined copy would drift like the pre-split preamble did"

t_case "the jq prelude crosses the seam: a driver-side reader still parses a matrix entry"
# Without the engine half's prelude every MATRIX_* field would be silently empty.
cat > "${_work}/matrix.json" <<'J'
{ "buildMatrix": { "linux": [ { "name": "rel", "sanitizer": "asan", "testCommand": "ctest" } ] } }
J
_out="$(_lib 'resolve_build_matrix_entry "'"${_work}"'/matrix.json" 0 linux
        echo "${MATRIX_NAME}|${MATRIX_SANITIZER}|${MATRIX_TEST_CMD}|${MATRIX_BUILD_DIR}"')"
t_assert_eq "rel|asan|ctest|build" "${_out}"

t_case "the jq precondition survives in load_engine_config, which run_agentic_loop delegates to"
# An emptied PATH misses jq like a jq-less host; the one owner must say so, exactly once.
_out="$(bash -c "set -u
LOG_FILE='${_work}/loop.log'
source '${LIB}'
PATH=/nonexistent
run_agentic_loop '${_work}/config.json' '${_work}' linux
echo \"rc=\$?\"" 2>&1)"
t_assert_contains "${_out}" "jq required"
t_assert_contains "${_out}" "rc=1" "no jq must stop the loop before it plans anything"
t_assert_eq "1" "$(printf '%s\n' "${_out}" | grep -c 'jq required')" "the owner must state the reason exactly once"

# ── 5. the F1 seam: _planner <iteration> <skip_when_pending> <force>; the phase reports via nameref if it ran ──
_planner() { _lib "
_AL[repo_root]='${_work}'; _AL[iteration]=$1; _AL[skip_planner_when_pending]=$2
_AL[refactor_every_n]=10
invoke_agent() { echo \"agent:\$1:\$2\"; }
_agentic_planner_phase '${_work}' '$3' ran; echo \"ran=\$ran\""; }

t_case "planner phase: pending tasks SKIP the planner and report ran=false"
printf -- '- [ ] one\n' > "${_work}/BACKLOG.md"
_out="$(_planner 1 true false)"
t_assert_contains "${_out}" "Skipping planner: 1 actionable task(s) pending"
t_assert_contains "${_out}" "ran=false"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c 'agent:planner' || true)" \
  "a skip that still invokes the agent is the bug the guard exists to prevent"

t_case "planner phase: the starvation guard runs it despite pending tasks"
_out="$(_planner 1 true true)"
t_assert_contains "${_out}" "Starvation guard"
t_assert_contains "${_out}" "ran=true"
t_assert_contains "${_out}" "agent:planner"

t_case "planner phase: a blocked-only backlog is an empty queue, so the planner runs"
printf -- '- [b] blocked on the SDK\n' > "${_work}/BACKLOG.md"
_out="$(_planner 1 true false)"
t_assert_contains "${_out}" "agent:planner"
t_assert_contains "${_out}" "ran=true"

t_case "planner phase: the refactor cycle picks the refactor prompt"
printf -- '- [ ] one\n' > "${_work}/BACKLOG.md"
_out="$(_planner 10 false false)"
t_assert_contains "${_out}" "Refactor-focused planning cycle"
t_assert_contains "${_out}" "ran=true"

t_case "run_agentic_loop delegates its planner phase to the seam"
t_assert_contains "$(t_fn_src "${LIB}" run_agentic_loop)" \
  '_agentic_planner_phase "$repo_root" "$force_planner" planner_ran' \
  "an inlined copy would drift from the phase the suite exercises"

t_summary
