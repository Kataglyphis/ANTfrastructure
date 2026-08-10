#!/usr/bin/env bash
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Reusable agentic-loop building blocks for Linux / Rancher Desktop.
# Source this file in your project's Run-AgenticLoop.sh.
#
# Supports two engines:
#   opencode — invokes `opencode run --agent <role> --model <model>`
#   claude   — invokes `claude -p --model <model>` (Claude Code CLI) with a
#              role system prompt appended from a prompt file
#
# Usage:
#   source "${SCRIPT_DIR}/lib/agentic-loop.sh"
#   init_agentic_loop "MyProject" "/path/to/repo"
#   load_engine_config "$config_json_path" "/path/to/repo"
#   invoke_agent "planner" "prompt message"
#   run_agentic_loop "$config_json_path"
#
# Environment overrides (all optional):
#   AGENTIC_ENGINE           opencode | claude (overrides config .engine)
#   AGENTIC_PLANNER_MODEL    overrides planner model id
#   AGENTIC_EXECUTOR_MODEL   overrides executor model id
#   DRY_RUN                  true = print actions without invoking anything
#   SKIP_BUILD / SKIP_TESTS / SKIP_QUALITY   true = skip that phase
#   PLANNER_ONLY / EXECUTOR_ONLY             true = single-phase mode
#   MAX_ITERATIONS_OVERRIDE  overrides config .intervals.maxIterations

# ── Logging ─────────────────────────────────────────────────────────────
LOG_FILE=""
LOOP_NAME=""
AGENTIC_START_TIME=0

init_agentic_loop() {
    local name="$1" repo_root="${2:-$(pwd)}"
    LOOP_NAME="$name"
    AGENTIC_START_TIME=$(date +%s)
    local log_dir="${repo_root}/logs/agentic-loop"
    mkdir -p "$log_dir"
    LOG_FILE="${log_dir}/agentic-loop_$(date '+%Y-%m-%d_%H-%M-%S').log"
    log "Agentic Loop: $LOOP_NAME"
    log "Log file: $LOG_FILE"
}

# Bash counterpart of the PS module's Complete-AgenticLoop: final summary +
# troubleshooting hints.  Call from the wrapper's EXIT trap with the exit
# code; does not exit itself (the trap owns that).
complete_agentic_loop() {
    local exit_code="${1:-0}"
    local elapsed=$(( $(date +%s) - AGENTIC_START_TIME ))
    section "Agentic Loop Finished"
    log "Exit code: $exit_code"
    log "Elapsed time: $(( elapsed / 60 ))min"
    log "Log file: $LOG_FILE"
    if [[ "$exit_code" -ne 0 ]]; then
        log "The loop exited with errors. Check sections above marked [ERROR] or [FATAL]." "WARN"
        log "Common fixes:" "WARN"
        log "  1. claude engine: run 'claude' once interactively to log in" "WARN"
        log "  2. opencode engine: run 'opencode auth login' and 'opencode models'" "WARN"
        log "  3. Verify model IDs in the loop config JSON" "WARN"
        log "  4. Run with --dry-run to test the configuration without executing" "WARN"
        log "  5. Run with --max-iterations 1 to test a single iteration" "WARN"
    fi
}

log() {
    local level="${2:-INFO}"
    local line="[$(date '+%H:%M:%S')] [$level] $1"
    echo "$line" >> "$LOG_FILE"
    echo "$line"
}

section() {
    local bar="$(printf '=%.0s' {1..60})"
    log ""; log "$bar"; log "$1"; log "$bar"
}

# ── Engine configuration ────────────────────────────────────────────────
# Shared jq prelude for the consolidated single-pass config readers below
# (load_engine_config, resolve_build_matrix_entry, _agentic_load_loop_config).
# `v` renders a scalar exactly the way an individual `$(jq -r '<path>')`
# command substitution did: null -> "null", numbers/booleans -> literal text,
# trailing newlines stripped (command substitution strips those too).
_AGENTIC_JQ_PRELUDE='def v: if . == null then "null" else tostring end | sub("\n+$"; "");'

# Reads engine selection + per-engine model/prompt settings from the config
# JSON.  Sets globals consumed by invoke_agent / invoke_claude.
# Precedence: env override > .engines.<engine>.* > legacy .models.*
load_engine_config() {
    local config_json="$1" repo_root="${2:-$(pwd)}"
    if ! command -v jq &>/dev/null; then log "jq required" "FATAL"; return 1; fi

    # One jq pass parses every engine-config field into a local map, emitted
    # as @sh-quoted shell assignments (evaluated below).  Field semantics are
    # unchanged from the previous one-jq-call-per-field version: `// empty`
    # fields become "", defaulted fields keep their defaults, env overrides
    # still win, a jq/JSON failure yields "" for every field, and the
    # globals are only assigned in the original order (so the early return
    # below still leaves CLAUDE_* / AGENT_* untouched, exactly as before).
    local -A _c=()
    local _al_cfg
    _al_cfg=$(jq -r --arg eo "${AGENTIC_ENGINE:-}" "${_AGENTIC_JQ_PRELUDE}"'
        (if $eo != "" then $eo else (.engine // "opencode" | v) end) as $e |
        @sh "_c[engine]=\($e)",
        @sh "_c[planner_model]=\(.engines[$e].plannerModel // .models.planner // "" | v)",
        @sh "_c[executor_model]=\(.engines[$e].executorModel // .models.executor // "" | v)",
        @sh "_c[planner_fallback]=\(.engines.claude.plannerFallbackModel // "" | v)",
        @sh "_c[planner_prompt]=\(.engines.claude.plannerPromptFile // "" | v)",
        @sh "_c[executor_prompt]=\(.engines.claude.executorPromptFile // "" | v)",
        @sh "_c[permission_mode]=\(.engines.claude.permissionMode // "bypassPermissions" | v)",
        @sh "_c[planner_allowed_tools]=\(.engines.claude.plannerAllowedTools // "" | v)",
        @sh "_c[extra_args]=\(.engines.claude.extraArgs // "" | v)",
        @sh "_c[stream_output]=\(.engines.claude.streamOutput // true | v)",
        @sh "_c[timeout]=\(.intervals.timeoutSeconds // 0 | v)",
        @sh "_c[planner_timeout]=\(.intervals.plannerTimeoutSeconds // 0 | v)",
        @sh "_c[executor_timeout]=\(.intervals.executorTimeoutSeconds // 0 | v)",
        @sh "_c[retries]=\(.intervals.agentRetries // 2 | v)",
        @sh "_c[retry_delay]=\(.intervals.agentRetryDelaySeconds // 20 | v)",
        @sh "_c[wait_limit_reset]=\(.intervals.waitForUsageLimitReset // true | v)"
    ' "$config_json")
    eval "$_al_cfg"

    AGENTIC_ENGINE="${_c[engine]-${AGENTIC_ENGINE:-}}"
    local e="$AGENTIC_ENGINE"

    PLANNER_MODEL="${AGENTIC_PLANNER_MODEL:-${_c[planner_model]-}}"
    EXECUTOR_MODEL="${AGENTIC_EXECUTOR_MODEL:-${_c[executor_model]-}}"
    if [[ -z "$PLANNER_MODEL" || -z "$EXECUTOR_MODEL" ]]; then
        log "No planner/executor model configured for engine '$e'" "FATAL"
        return 1
    fi

    CLAUDE_PLANNER_FALLBACK_MODEL="${_c[planner_fallback]-}"
    CLAUDE_PLANNER_PROMPT_FILE="${_c[planner_prompt]-}"
    CLAUDE_EXECUTOR_PROMPT_FILE="${_c[executor_prompt]-}"
    CLAUDE_PERMISSION_MODE="${_c[permission_mode]-}"
    CLAUDE_PLANNER_ALLOWED_TOOLS="${_c[planner_allowed_tools]-}"
    CLAUDE_EXTRA_ARGS="${_c[extra_args]-}"
    CLAUDE_STREAM_OUTPUT="${_c[stream_output]-}"

    # Prompt files are stored repo-relative in the config
    if [[ -n "$CLAUDE_PLANNER_PROMPT_FILE" && "$CLAUDE_PLANNER_PROMPT_FILE" != /* ]]; then
        CLAUDE_PLANNER_PROMPT_FILE="${repo_root}/${CLAUDE_PLANNER_PROMPT_FILE}"
    fi
    if [[ -n "$CLAUDE_EXECUTOR_PROMPT_FILE" && "$CLAUDE_EXECUTOR_PROMPT_FILE" != /* ]]; then
        CLAUDE_EXECUTOR_PROMPT_FILE="${repo_root}/${CLAUDE_EXECUTOR_PROMPT_FILE}"
    fi

    AGENT_TIMEOUT="${_c[timeout]-}"
    AGENT_PLANNER_TIMEOUT="${_c[planner_timeout]-}"
    AGENT_EXECUTOR_TIMEOUT="${_c[executor_timeout]-}"
    AGENT_RETRIES="${_c[retries]-}"
    AGENT_RETRY_DELAY="${_c[retry_delay]-}"
    WAIT_FOR_USAGE_LIMIT_RESET="${_c[wait_limit_reset]-}"

    log "Engine: $AGENTIC_ENGINE"
    log "Planner model: $PLANNER_MODEL"
    log "Executor model: $EXECUTOR_MODEL"
    if [[ "$e" == "claude" && -n "$CLAUDE_PLANNER_FALLBACK_MODEL" ]]; then
        log "Planner fallback model: $CLAUDE_PLANNER_FALLBACK_MODEL"
    fi
}

# Per-role timeout: role-specific value wins, then the generic timeout.
agent_timeout_for_role() {
    local role="$1"
    case "$role" in
        planner) [[ "${AGENT_PLANNER_TIMEOUT:-0}" -gt 0 ]] && { echo "$AGENT_PLANNER_TIMEOUT"; return; } ;;
        *)       [[ "${AGENT_EXECUTOR_TIMEOUT:-0}" -gt 0 ]] && { echo "$AGENT_EXECUTOR_TIMEOUT"; return; } ;;
    esac
    echo "${AGENT_TIMEOUT:-0}"
}

# ── Streaming helpers ───────────────────────────────────────────────────
# Echo every line to the console AND the log file as it arrives.
agent_stream_passthrough() {
    local line
    while IFS= read -r line; do
        echo "$line"
        echo "$line" >> "$LOG_FILE"
    done
}

# Render claude stream-json events into compact human-readable progress
# lines (tool calls, assistant text, tool errors, final result + cost),
# written live to console + log.  Non-JSON lines pass through unchanged.
claude_stream_render() {
    local line rendered r
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            '{'*) ;;
            *) echo "$line"; echo "$line" >> "$LOG_FILE"; continue ;;
        esac
        rendered=$(printf '%s\n' "$line" | jq -r '
            if .type == "system" and .subtype == "init" then
                "[claude] session started (model: " + (.model // "?") + ")"
            elif .type == "assistant" then
                (.message.content // [])[] |
                if .type == "tool_use" then
                    "  -> " + .name + ": " + ((.input.file_path // .input.command // .input.pattern // .input.description // .input.prompt // "") | tostring | gsub("\n"; " ") | .[0:160])
                elif .type == "text" then .text
                else empty end
            elif .type == "user" then
                (.message.content // []) |
                if type == "array" then
                    .[] | if .type == "tool_result" and (.is_error // false) then
                        "  !! tool error: " + ((.content // "") | tostring | gsub("\n"; " ") | .[0:200])
                    else empty end
                else empty end
            elif .type == "result" then
                ("[claude] result: " + ((.num_turns // 0) | tostring) + " turns, "
                    + (((.duration_ms // 0) / 1000) | tostring) + "s, $"
                    + ((.total_cost_usd // 0) | tostring)),
                (.result // empty)
            else empty end' 2>/dev/null)
        if [[ -n "$rendered" ]]; then
            while IFS= read -r r; do
                echo "$r"
                echo "$r" >> "$LOG_FILE"
            done <<< "$rendered"
        fi
    done
}

# ── OpenCode invocation ─────────────────────────────────────────────────
invoke_opencode() {
    local agent="$1" model="$2" message="$3"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY RUN] opencode run --agent $agent --model $model"
        return 0
    fi
    if ! command -v opencode &>/dev/null; then
        log "opencode not found on PATH. Install: curl -fsSL https://opencode.ai/install | bash" "FATAL"
        return 1
    fi
    local timeout_s
    timeout_s=$(agent_timeout_for_role "$agent")
    log "Invoking opencode: agent=$agent model=$model timeout=${timeout_s}s"
    local exit_code=0
    if [[ "$timeout_s" -gt 0 ]] && command -v timeout &>/dev/null; then
        printf '%s' "$message" | timeout --kill-after=30 "$timeout_s" opencode run --agent "$agent" --model "$model" 2>&1 | agent_stream_passthrough
        exit_code=${PIPESTATUS[1]}
    else
        printf '%s' "$message" | opencode run --agent "$agent" --model "$model" 2>&1 | agent_stream_passthrough
        exit_code=${PIPESTATUS[1]}
    fi
    if [[ $exit_code -eq 124 ]]; then
        log "opencode timed out after ${timeout_s}s (agent=$agent)" "ERROR"
    elif [[ $exit_code -ne 0 ]]; then
        log "opencode exited with code $exit_code (agent=$agent)" "WARN"
        if tail -n 50 "$LOG_FILE" | grep -qiE "model.*not found|invalid model|unknown model"; then
            log "Model '$model' was rejected. Run 'opencode models' to list valid IDs." "ERROR"
        fi
        if tail -n 50 "$LOG_FILE" | grep -qiE "API key|unauthorized|401|403"; then
            log "Authentication error. Run 'opencode auth login'." "ERROR"
        fi
    fi
    log "opencode finished (exit $exit_code)"
    return $exit_code
}

# ── Claude Code invocation ──────────────────────────────────────────────
# Headless Claude Code run: role prompt is appended as a system prompt from
# the configured prompt file.  The planner is sandboxed via --allowed-tools
# (read-only + BACKLOG.md edits); the executor runs with the configured
# permission mode (default: bypassPermissions, intended for trusted repos /
# sandboxes).
invoke_claude() {
    local role="$1" model="$2" message="$3"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY RUN] claude -p --model $model (role=$role)"
        return 0
    fi
    if ! command -v claude &>/dev/null; then
        log "claude not found on PATH. Install: npm install -g @anthropic-ai/claude-code" "FATAL"
        return 1
    fi

    local args=(-p --model "$model")
    if [[ "${CLAUDE_STREAM_OUTPUT:-true}" == "true" ]]; then
        # stream-json emits an event per assistant turn / tool call, so the
        # console and log show live progress instead of silence-until-done.
        args+=(--output-format stream-json --verbose)
    else
        args+=(--output-format text)
    fi

    local prompt_file=""
    case "$role" in
        planner) prompt_file="${CLAUDE_PLANNER_PROMPT_FILE:-}" ;;
        *)       prompt_file="${CLAUDE_EXECUTOR_PROMPT_FILE:-}" ;;
    esac
    if [[ -n "$prompt_file" ]]; then
        if [[ -f "$prompt_file" ]]; then
            args+=(--append-system-prompt-file "$prompt_file")
        else
            log "Prompt file not found: $prompt_file (continuing without role prompt)" "WARN"
        fi
    fi

    if [[ "$role" == "planner" && -n "${CLAUDE_PLANNER_ALLOWED_TOOLS:-}" ]]; then
        # Planner sandbox: only the listed tools are allowed; everything else
        # is denied in -p mode (no interactive prompt to approve).
        # shellcheck disable=SC2206
        args+=(--allowed-tools ${CLAUDE_PLANNER_ALLOWED_TOOLS})
    elif [[ "${CLAUDE_PERMISSION_MODE:-bypassPermissions}" == "bypassPermissions" ]]; then
        args+=(--dangerously-skip-permissions)
    else
        args+=(--permission-mode "${CLAUDE_PERMISSION_MODE}")
    fi

    if [[ "$role" == "planner" && -n "${CLAUDE_PLANNER_FALLBACK_MODEL:-}" ]]; then
        args+=(--fallback-model "$CLAUDE_PLANNER_FALLBACK_MODEL")
    fi

    if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
        # shellcheck disable=SC2206
        args+=(${CLAUDE_EXTRA_ARGS})
    fi

    local timeout_s
    timeout_s=$(agent_timeout_for_role "$role")
    log "Invoking claude: role=$role model=$model timeout=${timeout_s}s"
    local renderer="agent_stream_passthrough"
    [[ "${CLAUDE_STREAM_OUTPUT:-true}" == "true" ]] && renderer="claude_stream_render"
    local exit_code=0
    if [[ "$timeout_s" -gt 0 ]] && command -v timeout &>/dev/null; then
        printf '%s' "$message" | timeout --kill-after=30 "$timeout_s" claude "${args[@]}" 2>&1 | "$renderer"
        exit_code=${PIPESTATUS[1]}
    else
        printf '%s' "$message" | claude "${args[@]}" 2>&1 | "$renderer"
        exit_code=${PIPESTATUS[1]}
    fi
    if [[ $exit_code -eq 124 ]]; then
        log "claude timed out after ${timeout_s}s (role=$role)" "ERROR"
    elif [[ $exit_code -ne 0 ]]; then
        log "claude exited with code $exit_code (role=$role)" "WARN"
        if tail -n 50 "$LOG_FILE" | grep -qiE "not logged in|invalid api key|401|403"; then
            log "Authentication error. Run 'claude' interactively once to log in." "ERROR"
        fi
        if tail -n 50 "$LOG_FILE" | grep -qiE "model.*not found|invalid model"; then
            log "Model '$model' was rejected by claude. Check the model ID." "ERROR"
        fi
    fi
    log "claude finished (exit $exit_code)"
    return $exit_code
}

# ── Usage-limit handling ────────────────────────────────────────────────
# Detect a Claude usage/session-limit failure in the log tail and return the
# seconds to sleep until the stated reset (+ 2 min buffer) on stdout.
# Prints 0 when the recent output is not a usage-limit failure, and 1800
# when the limit is detected but the reset time can't be parsed. The reset
# time in the message ("resets 11pm (Europe/Berlin)") is taken as local time.
usage_limit_wait_seconds() {
    local tail_text
    tail_text=$(tail -n 30 "$LOG_FILE" 2>/dev/null)
    if ! echo "$tail_text" | grep -qiE "hit your (session|usage|weekly|5-hour) limit|usage limit reached"; then
        echo 0; return
    fi
    local t
    t=$(echo "$tail_text" | grep -oiE 'resets?[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' \
        | tail -n 1 | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)')
    [[ -z "$t" ]] && { echo 1800; return; }
    local target now
    target=$(date -d "today $t" +%s 2>/dev/null) || { echo 1800; return; }
    now=$(date +%s)
    (( target <= now )) && target=$(date -d "tomorrow $t" +%s)
    echo $(( target - now + 120 ))
}

# ── Engine dispatcher with retry/backoff ────────────────────────────────
# Roles: planner | executor | fixer (fixer maps to the executor model/agent).
invoke_agent() {
    local role="$1" message="$2"
    local model
    case "$role" in
        planner) model="${PLANNER_MODEL:?PLANNER_MODEL not set — call load_engine_config first}" ;;
        *)       model="${EXECUTOR_MODEL:?EXECUTOR_MODEL not set — call load_engine_config first}" ;;
    esac
    local retries="${AGENT_RETRIES:-2}" delay="${AGENT_RETRY_DELAY:-20}"
    local attempt=0 rc=0 limit_waits=0
    while true; do
        rc=0
        case "${AGENTIC_ENGINE:-opencode}" in
            claude)
                invoke_claude "$role" "$model" "$message" || rc=$? ;;
            opencode)
                local oc_agent="$role"
                [[ "$role" == "fixer" ]] && oc_agent="executor"
                invoke_opencode "$oc_agent" "$model" "$message" || rc=$? ;;
            *)
                log "Unknown engine: '${AGENTIC_ENGINE}' (expected opencode|claude)" "FATAL"
                return 1 ;;
        esac
        [[ $rc -eq 0 ]] && return 0
        # Usage/session-limit failures are not real errors: sleep until the
        # stated reset and try again without burning a retry. Capped so a
        # stuck limit can't spin forever (each pass sleeps >= 30 min anyway).
        if [[ "${WAIT_FOR_USAGE_LIMIT_RESET:-true}" == "true" && "${DRY_RUN:-false}" != "true" && "$limit_waits" -lt 10 ]]; then
            local limit_wait
            limit_wait=$(usage_limit_wait_seconds)
            if (( limit_wait > 0 )); then
                limit_waits=$((limit_waits + 1))
                log "Usage limit hit (role=$role). Waiting $(( limit_wait / 60 )) min until reset (wait $limit_waits/10) — not counted against retries." "WARN"
                sleep "$limit_wait"
                continue
            fi
        fi
        attempt=$((attempt + 1))
        if (( attempt > retries )); then
            log "Agent failed after $attempt attempt(s) (role=$role, exit=$rc)" "ERROR"
            return $rc
        fi
        local sleep_s=$((delay * attempt))
        log "Agent failed (exit=$rc). Retry $attempt/$retries in ${sleep_s}s..." "WARN"
        [[ "${DRY_RUN:-false}" != "true" ]] && sleep "$sleep_s"
    done
}

# ── BACKLOG helpers ─────────────────────────────────────────────────────
unchecked_task_count() {
    local backlog="${1:-BACKLOG.md}"
    # grep -c prints "0" AND exits non-zero on zero matches, so `|| echo 0`
    # would emit "0\n0" — capture first, then default only if empty.
    local n
    n=$(grep -c '^- \[ \]' "$backlog" 2>/dev/null) || true
    echo "${n:-0}"
}

# Count blocked (- [b]) tasks.  Blocked tasks are deliberately excluded from
# unchecked_task_count so a backlog containing only blocked entries reads as
# an empty queue and lets the planner run again.
blocked_task_count() {
    local backlog="${1:-BACKLOG.md}"
    local n
    n=$(grep -c '^- \[[bB]\]' "$backlog" 2>/dev/null) || true
    echo "${n:-0}"
}

# Remove completed (- [x]) task blocks from the backlog: the checked title
# line plus its indented / blank body lines, up to the next non-indented
# line (next task, heading, or plain text).  Completed work stays visible
# in git history instead of accumulating in the file.
remove_checked_tasks() {
    local backlog="${1:-BACKLOG.md}"
    [[ -f "$backlog" ]] || return 0
    local checked
    checked=$(grep -c '^- \[[xX]\]' "$backlog" 2>/dev/null) || true
    checked="${checked:-0}"
    [[ "$checked" -eq 0 ]] && return 0
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY RUN] would remove $checked completed task(s) from $(basename "$backlog")"
        return 0
    fi
    local tmp="${backlog}.prune.$$"
    awk '
        /^- \[[xX]\]/ { skip = 1; next }
        {
            if (skip) {
                if ($0 ~ /^[ \t]/ || $0 ~ /^[ \t]*$/) next
                skip = 0
            }
            print
        }
    ' "$backlog" > "$tmp" && mv "$tmp" "$backlog"
    log "Removed $checked completed task(s) from $(basename "$backlog")"
}

# ── Build / Test / Quality ──────────────────────────────────────────────
invoke_build() {
    local cmd="$1" config_name="$2"
    section "BUILD: $config_name"
    log "Command: $cmd"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then log "[DRY RUN] skipped build"; return 0; fi
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then log "BUILD PASSED"; return 0
    else log "BUILD FAILED" "ERROR"; return 1; fi
}

invoke_tests() {
    local cmd="$1"
    section "TESTS"
    log "Command: $cmd"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then log "[DRY RUN] skipped tests"; return 0; fi
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then log "TESTS PASSED"; return 0
    else log "TESTS FAILED" "ERROR"; return 1; fi
}

invoke_quality() {
    local cmd="$1"
    section "QUALITY"
    log "Command: $cmd"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then log "[DRY RUN] skipped quality"; return 0; fi
    eval "$cmd" >> "$LOG_FILE" 2>&1 || true
    log "Quality check complete"
}

# ── Build-failure fixer ─────────────────────────────────────────────────
# Hands the tail of the build log to the executor-tier model with a focused
# "fix the build" prompt.  Returns the agent's exit code.
invoke_build_fixer() {
    local config_name="$1" log_tail_lines="${2:-150}"
    section "BUILD FIXER: $config_name"
    local log_tail=""
    [[ -f "$LOG_FILE" ]] && log_tail=$(tail -n "$log_tail_lines" "$LOG_FILE")
    invoke_agent "fixer" "The build for preset '${config_name}' just failed in the agentic loop. Diagnose the failure from the build log below, fix the root cause in the code or build system, and rebuild with the same preset to verify the fix. Do not delete tests or disable warnings to force a green build. Commit the fix once the build passes.

--- build log (last ${log_tail_lines} lines) ---
${log_tail}
--- end build log ---"
}

# ── Sanitizer-aware test execution ──────────────────────────────────────
# Sets ASAN_OPTIONS or TSAN_OPTIONS before running tests, then restores the
# original environment.  If the sanitizer is 'none', behaves like invoke_tests.
get_sanitizer_env_vars() {
    local sanitizer="${1:-none}"
    case "$sanitizer" in
        asan) echo "ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:abort_on_error=1:allocator_may_return_null=1" ;;
        tsan) echo "TSAN_OPTIONS=halt_on_error=1:abort_on_error=1:second_deadlock_stack=1" ;;
        *)    echo "" ;;
    esac
}

invoke_sanitizer_tests() {
    local cmd="$1" sanitizer="${2:-none}"
    if [[ "$sanitizer" == "none" || -z "$sanitizer" ]]; then
        invoke_tests "$cmd"
        return $?
    fi
    local env_assignment saved_val env_var
    env_assignment=$(get_sanitizer_env_vars "$sanitizer")
    env_var="${env_assignment%%=*}"
    saved_val="${!env_var:-}"
    export "$env_assignment"
    log "Sanitizer: $sanitizer — env vars set ($env_var)"
    invoke_tests "$cmd"
    local rc=$?
    # Restore original env
    if [[ -n "$saved_val" ]]; then
        export "$env_var=$saved_val"
    else
        unset "$env_var"
    fi
    return $rc
}

# ── Build matrix helpers ────────────────────────────────────────────────
# Parse a build matrix entry from JSON.  Sets globals:
#   MATRIX_NAME, MATRIX_SANITIZER, MATRIX_TEST_CMD, MATRIX_BUILD_DIR, MATRIX_BUILD_TYPE
# Usage: resolve_build_matrix_entry "$config_json" "$index" "$platform"
resolve_build_matrix_entry() {
    local config_json="$1" index="$2" platform="${3:-linux}"
    # One jq pass for all five fields (was five calls).  Pre-initialise so a
    # jq failure yields the same empty strings the per-field calls produced.
    MATRIX_NAME="" MATRIX_SANITIZER="" MATRIX_TEST_CMD=""
    MATRIX_BUILD_DIR="" MATRIX_BUILD_TYPE=""
    local _al_cfg _al_rc=0
    _al_cfg=$(jq -r --arg p "$platform" --argjson i "$index" "${_AGENTIC_JQ_PRELUDE}"'
        .buildMatrix[$p][$i] as $m |
        @sh "MATRIX_NAME=\($m.name // .buildConfigurations[$p][$i] // "" | v)",
        @sh "MATRIX_SANITIZER=\($m.sanitizer // "none" | v)",
        @sh "MATRIX_TEST_CMD=\($m.testCommand // "" | v)",
        @sh "MATRIX_BUILD_DIR=\($m.buildDir // "build" | v)",
        @sh "MATRIX_BUILD_TYPE=\($m.buildType // "" | v)"
    ' "$config_json") || _al_rc=$?
    eval "$_al_cfg"
    # The old per-field version ended on a jq assignment, so callers saw
    # jq's exit status on unreadable/broken configs — keep that contract.
    return "$_al_rc"
}

# Count build matrix entries for a platform.
count_build_matrix() {
    local config_json="$1" platform="${2:-linux}"
    # Try buildMatrix first, fall back to buildConfigurations
    local count
    count=$(jq -r ".buildMatrix.${platform} | length" "$config_json" 2>/dev/null)
    if [[ "$count" == "null" || -z "$count" || "$count" -eq 0 ]]; then
        count=$(jq -r ".buildConfigurations.${platform} | length" "$config_json" 2>/dev/null)
    fi
    echo "${count:-0}"
}

# Get a build matrix entry name by index (backward-compatible with string arrays).
get_matrix_entry_name() {
    local config_json="$1" index="$2" platform="${3:-linux}"
    jq -r ".buildMatrix.${platform}[$index].name // .buildConfigurations.${platform}[$index] // empty" "$config_json"
}

# ── Default phase prompts ───────────────────────────────────────────────
# Single source of truth shared with WindowsAgenticLoop.Common.psm1:
# shared/agentic-loop/prompts/*.md at the repo root.
_default_prompt() {
    local lib_dir; lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local f="${lib_dir}/../../../shared/agentic-loop/prompts/$1.md"
    if [[ ! -f "$f" ]]; then
        echo "FATAL: default agentic prompt missing: $f" >&2
        return 1
    fi
    cat "$f"
}

default_planner_prompt() { _default_prompt planner; }
default_refactor_planner_prompt() { _default_prompt refactor-planner; }
default_executor_prompt() { _default_prompt executor; }

# ── Git auto-commit ─────────────────────────────────────────────────────
# Bash counterpart of the PS module's Invoke-GitAutoCommit.  No-op when
# disabled or in dry-run; never fails the loop over a commit error.
invoke_git_auto_commit() {
    local message="$1" repo_root="${2:-$(pwd)}" enabled="${3:-true}"
    [[ "$enabled" != "true" || "${DRY_RUN:-false}" == "true" ]] && return 0
    git -C "$repo_root" add -A 2>/dev/null || true
    git -C "$repo_root" commit -m "$message" 2>/dev/null || true
}

# ── Main loop ───────────────────────────────────────────────────────────
# Full planner/executor loop with engine dispatch, build matrix cycling,
# sanitizer-aware tests, build-failure fixing, and quality gates.  Reads all
# configuration from the JSON config file.  The project's Run-AgenticLoop.sh
# can either call this function or use the individual helpers directly.
#
# Honors env flags: DRY_RUN, SKIP_BUILD, SKIP_TESTS, SKIP_QUALITY,
# PLANNER_ONLY, EXECUTOR_ONLY, MAX_ITERATIONS_OVERRIDE.
# ── Loop state ────────────────────────────────────────────────────────────────
# (Complexity audit F-H: run_agentic_loop carried a 17-jq config block plus
# FOUR nested function definitions closing over its locals via dynamic scope —
# the closures were globally visible anyway once defined, so the nesting
# bought implicit coupling and nothing else. Config + mutable loop state now
# live in one associative array; the phase helpers are top-level and read it
# explicitly.)
declare -gA _AL=()

# Populate _AL from the engine config. Usage: _agentic_load_loop_config <json> <repo_root> <platform>
_agentic_load_loop_config() {
    local config_json="$1" repo_root="$2" platform="$3"
    _AL=()
    _AL[config_json]="$config_json"
    _AL[repo_root]="$repo_root"
    _AL[platform]="$platform"
    # One jq pass for all 16 config fields (was 16 calls).  No-default fields
    # keep the old `jq -r` behaviour of reading "null" when absent; a jq
    # failure leaves every field "" (pre-initialised) exactly as before.
    local _al_key
    for _al_key in build_every_n quality_every_n refactor_every_n \
        max_iterations max_retries loop_delay auto_commit commit_prefix \
        full_matrix_every_n fix_build_failures max_consecutive_build_failures \
        skip_planner_when_pending delete_completed test_cmd quality_cmd \
        build_script; do
        _AL[$_al_key]=""
    done
    local _al_cfg
    _al_cfg=$(jq -r --arg p "$platform" "${_AGENTIC_JQ_PRELUDE}"'
        @sh "_AL[build_every_n]=\(.intervals.buildEveryNTasks | v)",
        @sh "_AL[quality_every_n]=\(.intervals.qualityEveryNTasks | v)",
        @sh "_AL[refactor_every_n]=\(.intervals.refactorEveryNIterations | v)",
        @sh "_AL[max_iterations]=\(.intervals.maxIterations | v)",
        @sh "_AL[max_retries]=\(.intervals.maxExecutorRetries | v)",
        @sh "_AL[loop_delay]=\(.intervals.loopDelaySeconds | v)",
        @sh "_AL[auto_commit]=\(.git.autoCommit | v)",
        @sh "_AL[commit_prefix]=\(.git.commitPrefix | v)",
        @sh "_AL[full_matrix_every_n]=\(.intervals.fullMatrixEveryNIterations // 0 | v)",
        @sh "_AL[fix_build_failures]=\(.intervals.fixBuildFailures // true | v)",
        @sh "_AL[max_consecutive_build_failures]=\(.intervals.maxConsecutiveBuildFailures // 3 | v)",
        @sh "_AL[skip_planner_when_pending]=\(.backlog.skipPlannerWhenTasksPending // true | v)",
        @sh "_AL[delete_completed]=\(.backlog.deleteCompletedTasks // true | v)",
        @sh "_AL[test_cmd]=\(.build[$p + "TestCommand"] // .build.linuxTestCommand // "" | v)",
        @sh "_AL[quality_cmd]=\(.build[$p + "QualityCommand"] // .build.linuxQualityCommand // "" | v)",
        @sh "_AL[build_script]=\(.build[$p + "Script"] // .build.linuxScript // "" | v)"
    ' "$config_json")
    eval "$_al_cfg"
    if [[ -n "${MAX_ITERATIONS_OVERRIDE:-}" ]]; then
        _AL[max_iterations]="$MAX_ITERATIONS_OVERRIDE"
    fi
    # mutable loop state
    _AL[iteration]=0
    _AL[tasks_completed]=0
    _AL[build_cycle_index]=0
    _AL[consecutive_build_failures]=0
}

# Build + test one matrix entry by index. On build failure, optionally
# dispatches the fixer agent and retries the build once.
_agentic_build_and_test_entry() {
    local idx="$1"
    resolve_build_matrix_entry "${_AL[config_json]}" "$idx" "${_AL[platform]}"
    local cfg="$MATRIX_NAME" build_dir="$MATRIX_BUILD_DIR" sanitizer="$MATRIX_SANITIZER"
    local entry_test_cmd="$MATRIX_TEST_CMD"
    local script_path="${_AL[repo_root]}/${_AL[build_script]}"
    local cmd="bash \"${script_path}\" --preset \"${cfg}\" --build-dir \"${build_dir}\""
    local build_ok=true
    if ! invoke_build "$cmd" "$cfg"; then
        build_ok=false
        if [[ "${_AL[fix_build_failures]}" == "true" && "${DRY_RUN:-false}" != "true" ]]; then
            invoke_build_fixer "$cfg" || true
            if invoke_build "$cmd" "$cfg (after fixer)"; then
                build_ok=true
            fi
        fi
    fi
    if ! $build_ok; then
        _AL[consecutive_build_failures]=$(( _AL[consecutive_build_failures] + 1 ))
        log "Consecutive build failures: ${_AL[consecutive_build_failures]}/${_AL[max_consecutive_build_failures]}" "WARN"
        return 0
    fi
    # Guard-clause test half (was depth-5 nesting, audit F-D)
    _AL[consecutive_build_failures]=0
    [[ "${SKIP_TESTS:-false}" == "true" ]] && return 0
    local effective_test_cmd="${entry_test_cmd:-${_AL[test_cmd]}}"
    [[ -n "$effective_test_cmd" ]] || return 0
    invoke_sanitizer_tests "$effective_test_cmd" "$sanitizer"
}

# Run the build phase (single config or full matrix sweep).
_agentic_build_phase() {
    local matrix_count="$1"
    if [[ "${_AL[full_matrix_every_n]}" -gt 0 && $(( _AL[iteration] % _AL[full_matrix_every_n] )) -eq 0 && "${_AL[iteration]}" -gt 0 ]]; then
        section "FULL MATRIX SWEEP (iteration ${_AL[iteration]})"
        local i
        for ((i=0; i<matrix_count; i++)); do
            _agentic_build_and_test_entry "$i"
        done
    else
        _agentic_build_and_test_entry "$(( _AL[build_cycle_index] % matrix_count ))"
        _AL[build_cycle_index]=$(( _AL[build_cycle_index] + 1 ))
    fi
}

# After-task phases (commit, build, quality).
_agentic_after_task_phases() {
    local matrix_count="$1"
    invoke_git_auto_commit "${_AL[commit_prefix]}: task #${_AL[tasks_completed]}" "${_AL[repo_root]}" "${_AL[auto_commit]}"
    if [[ "${SKIP_BUILD:-false}" != "true" && $(( _AL[tasks_completed] % _AL[build_every_n] )) -eq 0 ]]; then
        _agentic_build_phase "$matrix_count"
    fi
    if [[ "${SKIP_QUALITY:-false}" != "true" && $(( _AL[tasks_completed] % _AL[quality_every_n] )) -eq 0 && -n "${_AL[quality_cmd]}" ]]; then
        invoke_quality "${_AL[quality_cmd]}"
    fi
}

# Drain the executor queue. Returns non-zero when stopped by persistent
# build failures; returns 0 when the queue is empty or stuck-at-max-retries.
_agentic_drain_executor_queue() {
    local matrix_count="$1"
    local backlog="${_AL[repo_root]}/BACKLOG.md"
    local unchecked retries=0
    [[ "${_AL[delete_completed]}" == "true" ]] && remove_checked_tasks "$backlog"
    unchecked=$(unchecked_task_count "$backlog")
    log "Tasks in queue: $unchecked"
    while [[ "$unchecked" -gt 0 ]]; do
        invoke_agent "executor" "$(default_executor_prompt)" || true
        local nu; nu=$(unchecked_task_count "$backlog")
        if [[ "$nu" -ge "$unchecked" ]]; then
            retries=$((retries + 1))
            log "No progress detected. Retry $retries/${_AL[max_retries]}" "WARN"
            if [[ "$retries" -ge "${_AL[max_retries]}" ]]; then log "Max retries reached" "ERROR"; break; fi
            # Dry-run never mutates BACKLOG.md — bail out instead of spinning
            [[ "${DRY_RUN:-false}" == "true" ]] && break
        else
            retries=0
            _AL[tasks_completed]=$(( _AL[tasks_completed] + 1 ))
            unchecked=$nu
            log "Task complete. Total: ${_AL[tasks_completed]} | Remaining: $unchecked"
            # Prune any leftover checked entries before the auto-commit
            [[ "${_AL[delete_completed]}" == "true" ]] && remove_checked_tasks "$backlog"
            _agentic_after_task_phases "$matrix_count"
            if [[ "${_AL[consecutive_build_failures]}" -ge "${_AL[max_consecutive_build_failures]}" ]]; then
                log "Too many consecutive build failures — stopping queue drain" "ERROR"
                return 1
            fi
        fi
    done
    return 0
}

run_agentic_loop() {
    local config_json="$1"
    local repo_root="${2:-$(pwd)}"
    local platform="${3:-linux}"

    if ! command -v jq &>/dev/null; then log "jq required" "FATAL"; return 1; fi

    load_engine_config "$config_json" "$repo_root" || return 1
    _agentic_load_loop_config "$config_json" "$repo_root" "$platform"

    local matrix_count
    matrix_count=$(count_build_matrix "$config_json" "$platform")
    if [[ "$matrix_count" -eq 0 ]]; then log "No build configs in matrix" "FATAL"; return 1; fi

    section "Agentic Loop Starting ($LOOP_NAME)"
    log "Build matrix: $matrix_count entries"
    if [[ "${_AL[full_matrix_every_n]}" -gt 0 ]]; then
        log "Full matrix sweep every ${_AL[full_matrix_every_n]} iterations"
    fi
    log "Build every N: ${_AL[build_every_n]}  Quality every N: ${_AL[quality_every_n]}  Refactor every N: ${_AL[refactor_every_n]}"
    log "Max iterations: ${_AL[max_iterations]} (0 = unlimited)"
    log "Build-failure fixing: ${_AL[fix_build_failures]} (stop after ${_AL[max_consecutive_build_failures]} consecutive failures)"

    # ── Single-phase modes ──────────────────────────────────────────────
    if [[ "${PLANNER_ONLY:-false}" == "true" ]]; then
        section "PLANNER PHASE (planner-only mode)"
        invoke_agent "planner" "$(default_planner_prompt)"
        section "Agentic Loop Complete (planner-only)"
        return 0
    fi
    if [[ "${EXECUTOR_ONLY:-false}" == "true" ]]; then
        section "EXECUTOR PHASE (executor-only mode)"
        _agentic_drain_executor_queue "$matrix_count" || true
        section "Agentic Loop Complete (executor-only, ${_AL[tasks_completed]} tasks)"
        return 0
    fi

    # ── Full loop ───────────────────────────────────────────────────────
    local force_planner=false iterations_done=0
    while true; do
        _AL[iteration]=$(( _AL[iteration] + 1 ))
        if [[ "${_AL[max_iterations]}" -gt 0 && "${_AL[iteration]}" -gt "${_AL[max_iterations]}" ]]; then break; fi
        iterations_done=${_AL[iteration]}
        section "ITERATION ${_AL[iteration]}"

        # Phase 1: Planner — skipped while the queue still has actionable
        # (- [ ]) tasks.  Blocked (- [b]) tasks do not count, and the
        # starvation guard forces a planner run after a zero-progress
        # iteration, so a backlog of blocked entries cannot stall the loop.
        local pending blocked planner_ran=false
        pending=$(unchecked_task_count "${repo_root}/BACKLOG.md")
        blocked=$(blocked_task_count "${repo_root}/BACKLOG.md")
        if [[ "${_AL[skip_planner_when_pending]}" == "true" && "$pending" -gt 0 && "$force_planner" != "true" ]]; then
            log "Skipping planner: $pending actionable task(s) pending in BACKLOG.md ($blocked blocked)"
        else
            section "PLANNER PHASE"
            if [[ "$force_planner" == "true" ]]; then
                log "Starvation guard: no progress last iteration — running planner despite $pending pending task(s) ($blocked blocked)" "WARN"
            fi
            local planner_msg
            if [[ $(( _AL[iteration] % _AL[refactor_every_n] )) -eq 0 ]]; then
                log "Refactor-focused planning cycle"
                planner_msg="$(default_refactor_planner_prompt)"
            else
                planner_msg="$(default_planner_prompt)"
            fi
            invoke_agent "planner" "$planner_msg" || true
            planner_ran=true
        fi

        # Phase 2: Executor
        local tasks_before=${_AL[tasks_completed]}
        if ! _agentic_drain_executor_queue "$matrix_count"; then
            log "Stopping loop due to persistent build failures" "ERROR"
            return 1
        fi

        if [[ "${_AL[tasks_completed]}" -eq "$tasks_before" ]]; then
            if [[ "$planner_ran" == "true" ]]; then
                log "No executor progress even after running the planner — stopping loop (no actionable tasks left)" "WARN"
                break
            fi
            log "No executor progress this iteration — planner will run next iteration" "WARN"
            force_planner=true
        else
            force_planner=false
        fi

        if [[ "${_AL[loop_delay]}" -gt 0 && "${DRY_RUN:-false}" != "true" ]]; then
            log "Sleeping ${_AL[loop_delay]}s..."
            sleep "${_AL[loop_delay]}"
        fi
    done

    section "Agentic Loop Complete (${_AL[tasks_completed]} tasks, $iterations_done iterations)"
    return 0
}
