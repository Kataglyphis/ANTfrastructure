#!/usr/bin/env bash
# Characterisation of lib/agentic-loop.sh — the three subjects nothing covered:
# engine-config precedence, invoke_agent's retry ladder with the engine faked,
# and one drain of the executor queue. Written so the engine-adapter half can be
# split from the loop-driver half (backlog F2) against a fixed behaviour.
# docs/agentic-loop-build-matrix.md#bash-agentic-loopsh
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${TESTS_DIR}/../lib/agentic-loop.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — agentic-loop's config readers are one jq pass" >&2
  exit 0
fi

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

# The claude engine is selected the same way in the next two cases; one helper
# so the second is a call, not a copy.
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
# DRY_RUN=true skips invoke_agent's back-off sleeps; without it this case sleeps
# AGENT_RETRY_DELAY * attempt seconds for real.
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
# The mapping was written `[[ "$role" == fixer ]] && oc_agent=executor`, and it was
# reported as fatal for every other role under a consumer's `set -e`. MEASURED, it
# is not: bash exempts every command of an AND-OR list except the one after the
# final && or ||, so the failing test neither exits the shell nor fires an ERR trap
# under `set -eE`. It WOULD be fatal one edit later -- as the last statement of the
# function the list becomes its return status -- so the shape is gone and the
# behaviour is pinned here. docs/agentic-loop-build-matrix.md#the-two-bash-files
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

# ── 3. one drain of the executor queue ──────────────────────────────────
# invoke_agent is faked to tick exactly one task, which is what "the executor
# made progress" means to the drain loop.
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

# ── 4. the F2 seam: two files, one entry point ──────────────────────────
# The engine half is loaded BY agentic-loop.sh from its own directory, so a
# consumer that sources only the entry point still gets every adapter, and
# neither file may carry a second copy of the other's functions.
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
# _AGENTIC_JQ_PRELUDE is defined in the engine half and used by
# resolve_build_matrix_entry in the driver half; an unsourced sibling makes the
# jq program a bare filter and every MATRIX_* field silently empty.
cat > "${_work}/matrix.json" <<'J'
{ "buildMatrix": { "linux": [ { "name": "rel", "sanitizer": "asan", "testCommand": "ctest" } ] } }
J
_out="$(_lib 'resolve_build_matrix_entry "'"${_work}"'/matrix.json" 0 linux
        echo "${MATRIX_NAME}|${MATRIX_SANITIZER}|${MATRIX_TEST_CMD}|${MATRIX_BUILD_DIR}"')"
t_assert_eq "rel|asan|ctest|build" "${_out}"

t_case "the jq precondition survives in load_engine_config, which run_agentic_loop delegates to"
# PATH is emptied after sourcing, so `command -v jq` misses exactly the way a
# host without jq does. run_agentic_loop carried a second copy of this guard;
# deleting the copy must not lose the verdict, and deleting the OWNER must
# turn this red rather than let a jq-less host reach the planner.
_out="$(bash -c "set -u
LOG_FILE='${_work}/loop.log'
source '${LIB}'
PATH=/nonexistent
run_agentic_loop '${_work}/config.json' '${_work}' linux
echo \"rc=\$?\"" 2>&1)"
t_assert_contains "${_out}" "jq required"
t_assert_contains "${_out}" "rc=1" "no jq must stop the loop before it plans anything"
t_assert_eq "1" "$(printf '%s\n' "${_out}" | grep -c 'jq required')" "the owner must state the reason exactly once"

t_summary
