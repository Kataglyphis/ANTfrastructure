#!/usr/bin/env bash
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The engine-adapter half of the agentic loop: config load, the opencode and
# claude adapters, stream rendering, usage-limit back-off and invoke_agent's
# retry ladder. Sourced by agentic-loop.sh, which owns log()/section() and the
# loop driver -- this half is not a standalone library.
# docs/agentic-loop-build-matrix.md#the-two-bash-files
[ -n "${_AGENTIC_ENGINES_SH_LOADED:-}" ] && return 0
_AGENTIC_ENGINES_SH_LOADED=1

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
                if [[ "$role" == "fixer" ]]; then oc_agent="executor"; fi
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
        if [[ "${DRY_RUN:-false}" != "true" ]]; then sleep "$sleep_s"; fi
    done
}
