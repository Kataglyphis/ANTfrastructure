#!/usr/bin/env bash
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Reusable agentic-loop building blocks for Linux / Rancher Desktop.
# Source this file in your project's Run-AgenticLoop.sh.
#
# Usage:
#   source "${SCRIPT_DIR}/lib/agentic-loop.sh"
#   init_agentic_loop "MyProject" "/path/to/repo"
#   invoke_opencode "planner" "model-id" "prompt message"
#   run_agentic_loop "$config_json_path"

# ── Logging ─────────────────────────────────────────────────────────────
LOG_FILE=""
LOOP_NAME=""

init_agentic_loop() {
    local name="$1" repo_root="${2:-$(pwd)}"
    LOOP_NAME="$name"
    local log_dir="${repo_root}/logs/agentic-loop"
    mkdir -p "$log_dir"
    LOG_FILE="${log_dir}/agentic-loop_$(date '+%Y-%m-%d_%H-%M-%S').log"
    log "Agentic Loop: $LOOP_NAME"
    log "Log file: $LOG_FILE"
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

# ── OpenCode invocation ─────────────────────────────────────────────────
invoke_opencode() {
    local agent="$1" model="$2" message="$3"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "[DRY RUN] opencode run --agent $agent --model $model"
        return 0
    fi
    if ! command -v opencode &>/dev/null; then
        log "opencode not found on PATH" "FATAL"
        return 1
    fi
    log "Invoking opencode: agent=$agent model=$model"
    local exit_code=0 output
    output=$(echo "$message" | opencode run --agent "$agent" --model "$model" 2>&1) || exit_code=$?
    {
        echo "--- opencode output start ---"
        echo "$output"
        echo "--- opencode output end ---"
    } >> "$LOG_FILE"
    if [[ $exit_code -ne 0 ]]; then
        log "opencode exited with code $exit_code (agent=$agent)" "WARN"
    fi
    log "opencode finished (exit $exit_code)"
    return $exit_code
}

# ── BACKLOG helpers ─────────────────────────────────────────────────────
unchecked_task_count() {
    local backlog="${1:-BACKLOG.md}"
    grep -c '^- \[ \]' "$backlog" 2>/dev/null || echo 0
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

# ── Main loop ───────────────────────────────────────────────────────────
run_agentic_loop() {
    local config_json="$1"
    local planner_model executor_model build_every_n quality_every_n refactor_every_n
    local max_iterations max_retries loop_delay auto_commit commit_prefix
    local build_cfg_script test_cmd quality_cmd repo_root build_configs

    # Parse config
    if ! command -v jq &>/dev/null; then log "jq required" "FATAL"; return 1; fi
    planner_model=$(jq -r '.models.planner' "$config_json")
    executor_model=$(jq -r '.models.executor' "$config_json")
    build_every_n=$(jq -r '.intervals.buildEveryNTasks' "$config_json")
    quality_every_n=$(jq -r '.intervals.qualityEveryNTasks' "$config_json")
    refactor_every_n=$(jq -r '.intervals.refactorEveryNIterations' "$config_json")
    max_iterations=$(jq -r '.intervals.maxIterations' "$config_json")
    max_retries=$(jq -r '.intervals.maxExecutorRetries' "$config_json")
    loop_delay=$(jq -r '.intervals.loopDelaySeconds' "$config_json")
    auto_commit=$(jq -r '.git.autoCommit' "$config_json")
    commit_prefix=$(jq -r '.git.commitPrefix' "$config_json")
    repo_root=$(jq -r '.repoRoot' "$config_json")

    section "Agentic Loop Starting ($LOOP_NAME)"
    log "Planner model: $planner_model"
    log "Executor model: $executor_model"
    log "Build every N: $build_every_n  Quality every N: $quality_every_n  Refactor every N: $refactor_every_n"

    local iteration=0 tasks_completed=0 build_cycle_index=0

    while true; do
        iteration=$((iteration + 1))
        section "ITERATION $iteration"
        if [[ "$max_iterations" -gt 0 && "$iteration" -gt "$max_iterations" ]]; then break; fi

        # Phase 1: Planner
        invoke_opencode "planner" "$planner_model" "Analyze the codebase and add tasks to BACKLOG.md."

        # Phase 2: Executor
        local unchecked retries=0
        unchecked=$(unchecked_task_count)
        while [[ "$unchecked" -gt 0 ]]; do
            invoke_opencode "executor" "$executor_model" "Execute the next unchecked task from BACKLOG.md."
            local nu; nu=$(unchecked_task_count)
            if [[ "$nu" -ge "$unchecked" ]]; then
                retries=$((retries + 1))
                if [[ "$retries" -ge "$max_retries" ]]; then log "Max retries reached" "ERROR"; break; fi
            else
                retries=0; tasks_completed=$((tasks_completed + 1)); unchecked=$nu
                log "Task complete. Total: $tasks_completed | Remaining: $unchecked"
                if [[ "$auto_commit" == "true" ]]; then
                    git -C "$repo_root" add -A 2>/dev/null || true
                    git -C "$repo_root" commit -m "$commit_prefix: task #$tasks_completed" 2>/dev/null || true
                fi
            fi
        done

        if [[ "$loop_delay" -gt 0 ]]; then sleep "$loop_delay"; fi
    done
}