#!/usr/bin/env bash
# Characterisation of lib/agentic-loop.sh — the three subjects nothing covered:
# engine-config precedence, invoke_agent's retry ladder with the engine faked,
# and one drain of the executor queue. Written so the engine-adapter half can be
# split from the loop-driver half (backlog F2) against a fixed behaviour.
# docs/agentic-loop-build-matrix.md
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

t_summary
