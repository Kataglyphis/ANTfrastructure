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
    MATRIX_NAME=$(jq -r ".buildMatrix.${platform}[$index].name // .buildConfigurations.${platform}[$index] // empty" "$config_json")
    MATRIX_SANITIZER=$(jq -r ".buildMatrix.${platform}[$index].sanitizer // \"none\"" "$config_json")
    MATRIX_TEST_CMD=$(jq -r ".buildMatrix.${platform}[$index].testCommand // empty" "$config_json")
    MATRIX_BUILD_DIR=$(jq -r ".buildMatrix.${platform}[$index].buildDir // \"build\"" "$config_json")
    MATRIX_BUILD_TYPE=$(jq -r ".buildMatrix.${platform}[$index].buildType // empty" "$config_json")
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

# ── Main loop ───────────────────────────────────────────────────────────
# Full planner/executor loop with build matrix cycling, sanitizer-aware
# tests, and quality gates.  Reads all configuration from the JSON config
# file.  The project's Run-AgenticLoop.sh can either call this function or
# use the individual helpers (invoke_opencode, invoke_build, etc.) directly.
run_agentic_loop() {
    local config_json="$1"
    local repo_root="${2:-$(pwd)}"
    local platform="${3:-linux}"

    if ! command -v jq &>/dev/null; then log "jq required" "FATAL"; return 1; fi

    local planner_model executor_model build_every_n quality_every_n refactor_every_n
    local max_iterations max_retries loop_delay auto_commit commit_prefix
    local full_matrix_every_n test_cmd quality_cmd build_script

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
    full_matrix_every_n=$(jq -r '.intervals.fullMatrixEveryNIterations // 0' "$config_json")
    test_cmd=$(jq -r ".build.${platform}TestCommand // .build.linuxTestCommand // empty" "$config_json")
    quality_cmd=$(jq -r ".build.${platform}QualityCommand // .build.linuxQualityCommand // empty" "$config_json")
    build_script=$(jq -r ".build.${platform}Script // .build.linuxScript // empty" "$config_json")

    local matrix_count
    matrix_count=$(count_build_matrix "$config_json" "$platform")
    if [[ "$matrix_count" -eq 0 ]]; then log "No build configs in matrix" "FATAL"; return 1; fi

    section "Agentic Loop Starting ($LOOP_NAME)"
    log "Planner model: $planner_model"
    log "Executor model: $executor_model"
    log "Build matrix: $matrix_count entries"
    if [[ "$full_matrix_every_n" -gt 0 ]]; then
        log "Full matrix sweep every $full_matrix_every_n iterations"
    fi
    log "Build every N: $build_every_n  Quality every N: $quality_every_n  Refactor every N: $refactor_every_n"

    local iteration=0 tasks_completed=0 build_cycle_index=0

    # Helper: build + test for a matrix entry by index
    invoke_build_and_test_for_entry() {
        local idx="$1"
        resolve_build_matrix_entry "$config_json" "$idx" "$platform"
        local cfg="$MATRIX_NAME" build_dir="$MATRIX_BUILD_DIR" sanitizer="$MATRIX_SANITIZER"
        local entry_test_cmd="$MATRIX_TEST_CMD"
        local script_path="${repo_root}/${build_script}"
        local cmd="bash \"${script_path}\" --preset \"${cfg}\" --build-dir \"${build_dir}\""
        invoke_build "$cmd" "$cfg"
        local rc=$?
        if [[ $rc -eq 0 && "${SKIP_TESTS:-false}" != "true" ]]; then
            local effective_test_cmd="${entry_test_cmd:-$test_cmd}"
            if [[ -n "$effective_test_cmd" ]]; then
                invoke_sanitizer_tests "$effective_test_cmd" "$sanitizer"
            fi
        fi
    }

    # Helper: run the build phase (single config or full matrix sweep)
    invoke_build_phase() {
        if [[ "$full_matrix_every_n" -gt 0 && $((iteration % full_matrix_every_n)) -eq 0 && $iteration -gt 0 ]]; then
            section "FULL MATRIX SWEEP (iteration $iteration)"
            for ((i=0; i<matrix_count; i++)); do
                invoke_build_and_test_for_entry "$i"
            done
        else
            invoke_build_and_test_for_entry "$((build_cycle_index % matrix_count))"
            build_cycle_index=$((build_cycle_index + 1))
        fi
    }

    while true; do
        iteration=$((iteration + 1))
        section "ITERATION $iteration"
        if [[ "$max_iterations" -gt 0 && "$iteration" -gt "$max_iterations" ]]; then break; fi

        # Phase 1: Planner
        local do_refactor=$(( iteration % refactor_every_n == 0 ))
        local planner_msg
        if [[ "$do_refactor" -eq 1 ]]; then
            planner_msg="Analyze the codebase for refactoring opportunities. Focus on dead code, API consolidation, test coverage gaps, documentation drift, and C++23 modernization. Read BACKLOG.md first to avoid duplicates. Add at most 3 refactor tasks."
        else
            planner_msg="Analyze the codebase and add tasks to BACKLOG.md. Identify bugs, improvements, missing tests, and technical debt. Do NOT duplicate existing tasks. Add at most 5 new tasks."
        fi
        invoke_opencode "planner" "$planner_model" "$planner_msg"

        # Phase 2: Executor
        local unchecked retries=0
        unchecked=$(unchecked_task_count)
        while [[ "$unchecked" -gt 0 ]]; do
            invoke_opencode "executor" "$executor_model" "Read BACKLOG.md and find the first unchecked task (- [ ]). Implement it fully: make the code changes, add or update tests, and build with the appropriate preset. Once the task is complete and the build passes, mark it as checked (- [x]) in BACKLOG.md with a brief summary. Then commit the changes."
            local nu; nu=$(unchecked_task_count)
            if [[ "$nu" -ge "$unchecked" ]]; then
                retries=$((retries + 1))
                log "No progress detected. Retry $retries/$max_retries" "WARN"
                if [[ "$retries" -ge "$max_retries" ]]; then log "Max retries reached" "ERROR"; break; fi
            else
                retries=0; tasks_completed=$((tasks_completed + 1)); unchecked=$nu
                log "Task complete. Total: $tasks_completed | Remaining: $unchecked"
                if [[ "$auto_commit" == "true" ]]; then
                    git -C "$repo_root" add -A 2>/dev/null || true
                    git -C "$repo_root" commit -m "$commit_prefix: task #$tasks_completed" 2>/dev/null || true
                fi
                # Build phase
                if [[ "${SKIP_BUILD:-false}" != "true" && $((tasks_completed % build_every_n)) -eq 0 ]]; then
                    invoke_build_phase
                fi
                # Quality phase
                if [[ "${SKIP_QUALITY:-false}" != "true" && $((tasks_completed % quality_every_n)) -eq 0 && -n "$quality_cmd" ]]; then
                    invoke_quality "$quality_cmd"
                fi
            fi
        done

        if [[ "$loop_delay" -gt 0 && "${DRY_RUN:-false}" != "true" ]]; then
            log "Sleeping ${loop_delay}s..."
            sleep "$loop_delay"
        fi
    done
}