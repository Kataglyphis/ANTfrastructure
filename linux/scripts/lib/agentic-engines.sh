#!/usr/bin/env bash
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Engine adapters; not standalone, agentic-loop.sh owns log()/section(). docs/agentic-loop-build-matrix.md#the-two-bash-files
[ -n "${_AGENTIC_ENGINES_SH_LOADED:-}" ] && return 0
_AGENTIC_ENGINES_SH_LOADED=1

# Engine configuration: `v` renders a scalar exactly as a `$(jq -r '<path>')` substitution would.
_AGENTIC_JQ_PRELUDE='def v: if . == null then "null" else tostring end | sub("\n+$"; "");'

# Role-prompt composition, twin of New-AgenticComposedPrompt. docs/agentic-loop-build-matrix.md#role-prompt-composition

# <hub>/linux/scripts/lib -> <hub>
_agentic_hub_root() {
    (cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
}

# The engine-agnostic role prompt, not prompts/<role>.md (the short task message).
agentic_system_prompt_path() {
    echo "$(_agentic_hub_root)/shared/agentic-loop/system-prompts/${1}.md"
}

# PowerShell's String.TrimEnd() over a file: drop trailing blank lines.
_agentic_trim_trailing_blanks() {
    awk '{ lines[NR] = $0 }
         END { last = NR
               while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
               for (i = 1; i <= last; i++) print lines[i] }' "$1"
}

# PowerShell's String.Trim(): drop leading AND trailing blank lines.
_agentic_trim_blanks() {
    _agentic_trim_trailing_blanks "$1" |
        awk 'NF || started { started = 1; print }'
}

# Runs under DRY_RUN too: the file is derived, and a dry run exists to check this wiring.
write_opencode_agent_file() {
    local role="$1" repo_root="$2" body_file="$3" source_label="$4"
    local out="${repo_root}/.opencode/agents/${role}.md"
    mkdir -p "$(dirname "$out")"
    local tmp="${out}.tmp.$$"
    {
        cat <<EOF
<!--
GENERATED FILE - DO NOT EDIT.

Written on every agentic-loop start by write_opencode_agent_file
(ANTfrastructure linux/scripts/lib/agentic-engines.sh).
opencode takes no system-prompt file on its command line, so this is the
only way \`opencode run --agent <role>\` can be given the shared role prompt.

Composed from: shared/agentic-loop/system-prompts/${role}.md + ${source_label}
Change the shared prompt or the project overlay - edits here are lost on
the next run, and a committed copy is how the prompts forked before.
-->

EOF
        _agentic_trim_trailing_blanks "$body_file"
    } > "$tmp"

    if [[ -f "$out" ]] && cmp -s "$tmp" "$out"; then
        rm -f "$tmp"
        log "opencode agent prompt up to date: $out"
        return 0
    fi
    mv "$tmp" "$out"
    log "Generated opencode agent prompt: $out ($source_label)"
    if [[ -f "${repo_root}/.gitignore" ]] \
       && ! grep -qE '^[[:space:]]*\.opencode/agents/' "${repo_root}/.gitignore"; then
        log "$out is generated but .gitignore does not exclude '.opencode/agents/' — add it, or the copy will be committed and fork again." "WARN"
    fi
}

# Returns via a global (log() writes stdout); always writes the opencode agent file so both engines agree.
_AGENTIC_RESOLVED_PROMPT_FILE=""
resolve_role_prompt_file() {
    local role="$1" override="$2" overlay="$3" repo_root="$4"
    _AGENTIC_RESOLVED_PROMPT_FILE=""

    if [[ -n "$overlay" && ! -f "$overlay" ]]; then
        log "Prompt overlay not found: $overlay (using the shared role prompt alone)" "WARN"
        overlay=""
    fi

    local shared
    shared="$(agentic_system_prompt_path "$role")"

    if [[ -n "$overlay" ]]; then
        if [[ -n "$override" ]]; then
            log "Both ${role}PromptFile and ${role}PromptOverlayFile set; the overlay wins." "WARN"
        fi
        if [[ ! -f "$shared" ]]; then
            log "Shared system prompt missing: $shared" "FATAL"
            return 1
        fi
        local composed="${TMPDIR:-/tmp}/agentic-prompt-${role}-composed.md"
        {
            _agentic_trim_trailing_blanks "$shared"
            printf '\n---\n\n<!-- project overlay: %s -->\n\n' "$overlay"
            _agentic_trim_blanks "$overlay"
        } > "$composed"
        log "Composed $role prompt: shared default + $(basename "$overlay")"
        write_opencode_agent_file "$role" "$repo_root" "$composed" "$(basename "$overlay")"
        _AGENTIC_RESOLVED_PROMPT_FILE="$composed"
        return 0
    fi

    if [[ -n "$override" ]]; then
        if [[ -f "$override" ]]; then
            write_opencode_agent_file "$role" "$repo_root" "$override" \
                "full override $(basename "$override") (migrate it to an overlay)"
        else
            log "Prompt file not found: $override (no opencode agent prompt generated for $role)" "WARN"
        fi
        _AGENTIC_RESOLVED_PROMPT_FILE="$override"
        return 0
    fi

    # No prompt config at all: without this branch opencode would get nothing.
    if [[ -f "$shared" ]]; then
        write_opencode_agent_file "$role" "$repo_root" "$shared" "no project overlay configured"
    else
        log "No prompt configured for $role and the shared role prompt is unavailable ($shared); opencode will run without a role prompt." "WARN"
    fi
    return 0
}

# Config paths are repo-relative; empty and absolute values pass through.
_agentic_repo_path() {
    local path="$1" repo_root="$2"
    if [[ -n "$path" && "$path" != /* ]]; then
        printf '%s/%s\n' "$repo_root" "$path"
    else
        printf '%s\n' "$path"
    fi
}

# Kept out of the config reader because it writes files.
_agentic_compose_role_prompts() {
    local repo_root="$1"
    resolve_role_prompt_file planner "$CLAUDE_PLANNER_PROMPT_FILE" \
        "$AGENTIC_PLANNER_OVERLAY_FILE" "$repo_root" || return 1
    CLAUDE_PLANNER_PROMPT_FILE="$_AGENTIC_RESOLVED_PROMPT_FILE"
    resolve_role_prompt_file executor "$CLAUDE_EXECUTOR_PROMPT_FILE" \
        "$AGENTIC_EXECUTOR_OVERLAY_FILE" "$repo_root" || return 1
    CLAUDE_EXECUTOR_PROMPT_FILE="$_AGENTIC_RESOLVED_PROMPT_FILE"
}

# Precedence: env override > .engines.<engine>.* > legacy .models.*
load_engine_config() {
    local config_json="$1" repo_root="${2:-$(pwd)}"
    if ! command -v jq &>/dev/null; then log "jq required" "FATAL"; return 1; fi

    # A jq failure yields "" for every field; assignment order keeps the early return from touching CLAUDE_*/AGENT_*.
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
        @sh "_c[planner_overlay]=\(.promptOverlays.plannerPromptOverlayFile // .engines[$e].plannerPromptOverlayFile // ([.engines[]? | .plannerPromptOverlayFile? | select(. != null)] | first) // "" | v)",
        @sh "_c[executor_overlay]=\(.promptOverlays.executorPromptOverlayFile // .engines[$e].executorPromptOverlayFile // ([.engines[]? | .executorPromptOverlayFile? | select(. != null)] | first) // "" | v)",
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
    CLAUDE_PLANNER_PROMPT_FILE="$(_agentic_repo_path "${_c[planner_prompt]-}" "$repo_root")"
    CLAUDE_EXECUTOR_PROMPT_FILE="$(_agentic_repo_path "${_c[executor_prompt]-}" "$repo_root")"
    CLAUDE_PERMISSION_MODE="${_c[permission_mode]-}"
    CLAUDE_PLANNER_ALLOWED_TOOLS="${_c[planner_allowed_tools]-}"
    CLAUDE_EXTRA_ARGS="${_c[extra_args]-}"
    CLAUDE_STREAM_OUTPUT="${_c[stream_output]-}"

    AGENTIC_PLANNER_OVERLAY_FILE="$(_agentic_repo_path "${_c[planner_overlay]-}" "$repo_root")"
    AGENTIC_EXECUTOR_OVERLAY_FILE="$(_agentic_repo_path "${_c[executor_overlay]-}" "$repo_root")"

    # Every engine: .opencode/agents/<role>.md is opencode's only channel for a role prompt.
    _agentic_compose_role_prompts "$repo_root" || return 1

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

# Streaming helpers
agent_stream_passthrough() {
    local line
    while IFS= read -r line; do
        echo "$line"
        echo "$line" >> "$LOG_FILE"
    done
}

# Non-JSON lines pass through unchanged.
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

# OpenCode invocation. Twin of Get-AgenticOpenCodeMajorVersion; unparseable --version text is 0.
opencode_major_version() {
    if [[ "${1:-}" =~ ([0-9]+)\.[0-9]+\.[0-9]+ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo 0
    fi
}

# --standalone: else v2 attaches to a service that outlives the timeout; --auto: headless v2 rejects every ask. docs/windows-agentic-loop.md#opencode-v2
opencode_run_args() {
    local agent="$1" model="$2"
    printf '%s\n' run --agent "$agent" --model "$model" --standalone
    if [[ "$agent" == "executor" ]]; then echo --auto; fi
}

invoke_opencode() {
    local agent="$1" model="$2" message="$3"
    local -a run_args
    mapfile -t run_args < <(opencode_run_args "$agent" "$model")
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY RUN] opencode ${run_args[*]}"
        return 0
    fi
    if ! command -v opencode &>/dev/null; then
        log "opencode not found on PATH. Install v2: curl -fsSL https://opencode.ai/v2/install | bash" "FATAL"
        return 1
    fi
    # v1 takes neither flag above; `run --standalone` there is not a run.
    local version_text
    version_text="$(opencode --version 2>/dev/null || true)"
    if [[ "$(opencode_major_version "$version_text")" -lt 2 ]]; then
        log "opencode v2 is required; PATH has '${version_text}'. Install: curl -fsSL https://opencode.ai/v2/install | bash" "FATAL"
        return 1
    fi
    local timeout_s
    timeout_s=$(agent_timeout_for_role "$agent")
    log "Invoking opencode: agent=$agent model=$model timeout=${timeout_s}s"
    local exit_code=0
    if [[ "$timeout_s" -gt 0 ]] && command -v timeout &>/dev/null; then
        printf '%s' "$message" | timeout --kill-after=30 "$timeout_s" opencode "${run_args[@]}" 2>&1 | agent_stream_passthrough
        exit_code=${PIPESTATUS[1]}
    else
        printf '%s' "$message" | opencode "${run_args[@]}" 2>&1 | agent_stream_passthrough
        exit_code=${PIPESTATUS[1]}
    fi
    if [[ $exit_code -eq 124 ]]; then
        log "opencode timed out after ${timeout_s}s (agent=$agent)" "ERROR"
    elif [[ $exit_code -ne 0 ]]; then
        log "opencode exited with code $exit_code (agent=$agent)" "WARN"
        if tail -n 50 "$LOG_FILE" | grep -qiE "model.*not found|invalid model|unknown model|model unavailable"; then
            log "Model '$model' was rejected. Run 'opencode models' to list valid IDs." "ERROR"
        fi
        if tail -n 50 "$LOG_FILE" | grep -qiE "API key|unauthorized|401|403"; then
            log "Authentication error. Run 'opencode auth login'." "ERROR"
        fi
    fi
    log "opencode finished (exit $exit_code)"
    return $exit_code
}

# Claude Code invocation: planner sandboxed by --allowed-tools; executor defaults to bypassPermissions (trusted repos only).
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
        # stream-json shows live progress instead of silence until done.
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
        # -p mode has no approval prompt, so unlisted tools are denied.
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

# Usage limits: prints seconds to the stated reset (+2 min), 0 if none hit, 1800 if the reset is unparseable.
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

# Engine dispatcher; the fixer role maps to the executor model/agent.
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
        # A usage limit is not an error: wait for the reset without burning a retry, capped against a stuck limit.
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
