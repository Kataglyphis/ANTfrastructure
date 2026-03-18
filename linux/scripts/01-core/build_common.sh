#!/usr/bin/env bash
# build_common.sh - Linux build framework with step management and logging
#
# Provides:
#   build_init <workspace> [log_dir]      - Initialize build context
#   build_log <msg...>                    - Log info message
#   build_warn <msg...>                   - Log warning message
#   build_err <msg...>                    - Log error message (does not exit)
#   build_success <msg...>                - Log success message
#   build_step <name> <script>            - Execute a build step with timing
#   build_cmd <file> [args...]            - Execute external command with logging
#   build_summary                          - Print build summary
#   build_finish [exit_code]               - Print summary and exit
#
# Usage:
#   source /path/to/01-core/build_common.sh
#   build_init "$PWD" "logs"
#   build_step "Build Release" build_cmd cargo build --release
#   build_finish 0

set -euo pipefail

if [ -z "${_BUILD_COMMON_LOADED:-}" ]; then
_BUILD_COMMON_LOADED=1

_SOURCE_MODULE="${BASH_SOURCE[0]%/*}"
source "$_SOURCE_MODULE/logging.sh" || { echo "Error: failed to source logging.sh" >&2; exit 1; }

declare -g _BUILD_WORKSPACE=""
declare -g _BUILD_LOG_DIR=""
declare -g _BUILD_LOG_FILE=""
declare -g _BUILD_SUMMARY_FILE=""
declare -g _BUILD_STARTED_AT=""
declare -ga _BUILD_SUCCEEDED=()
declare -ga _BUILD_FAILED=()
declare -gA _BUILD_ERRORS=()
declare -g _BUILD_LOG_FD=""

_build_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_build_log_raw() {
  local level="$1"; shift
  local ts
  ts=$(_build_timestamp)
  local msg="$*"

  if [ -n "${_BUILD_LOG_FILE:-}" ]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$_BUILD_LOG_FILE"
  fi
}

build_init() {
  local workspace="${1:-$PWD}"
  local log_dir="${2:-logs}"

  _BUILD_WORKSPACE="$(cd "$workspace" 2>/dev/null && pwd || echo "$workspace")"
  _BUILD_LOG_DIR="$(cd "$workspace" 2>/dev/null && mkdir -p "$log_dir" && cd "$log_dir" && pwd || echo "$log_dir")"
  _BUILD_STARTED_AT=$(_build_timestamp)

  local ts_safe
  ts_safe=$(echo "$_BUILD_STARTED_AT" | tr -d ':' | tr 'T' '_' | tr -d '-')
  _BUILD_LOG_FILE="$_BUILD_LOG_DIR/build-linux-${ts_safe}.log"
  _BUILD_SUMMARY_FILE="${_BUILD_LOG_FILE%.log}.json"

  : > "$_BUILD_LOG_FILE"

  build_log "=== Build Environment ==="
  build_log "Workspace: $_BUILD_WORKSPACE"
  build_log "Log File: $_BUILD_LOG_FILE"
  build_log "Started: $_BUILD_STARTED_AT"

  info "Build initialized: $_BUILD_WORKSPACE"
}

build_log() {
  _build_log_raw "INFO" "$@"
  info "$@"
}

build_warn() {
  _build_log_raw "WARN" "$@"
  warn "$@"
}

build_err() {
  _build_log_raw "ERROR" "$@"
  err "$*"
}

build_success() {
  _build_log_raw "SUCCESS" "$@"
  if _log_use_color; then
    printf '\033[1;32m[SUCCESS]\033[0m %s\n' "$*"
  else
    printf '[SUCCESS] %s\n' "$*"
  fi
}

build_cmd() {
  local file="$1"; shift
  local args=("$@")

  local cmd_line="$file"
  if [ ${#args[@]} -gt 0 ]; then
    cmd_line="$file ${args[*]}"
  fi

  build_log "CMD: $cmd_line"

  local exit_code=0
  if [ ${#args[@]} -eq 0 ]; then
    "$file" 2>&1 | tee -a "$_BUILD_LOG_FILE" || exit_code=$?
  else
    "$file" "${args[@]}" 2>&1 | tee -a "$_BUILD_LOG_FILE" || exit_code=$?
  fi

  if [ $exit_code -ne 0 ]; then
    return $exit_code
  fi
  return 0
}

build_step() {
  local name="$1"; shift
  local script="$*"

  build_log ""
  build_log ">>> Starting: $name"
  build_log "============================================================"

  local start end duration exit_code=0
  start=$(date +%s%N 2>/dev/null || date +%s)

  local output
  if output=$("$script" 2>&1); then
    : 
  else
    exit_code=$?
  fi

  if [ -n "$output" ]; then
    printf '%s\n' "$output" >> "$_BUILD_LOG_FILE"
    printf '%s\n' "$output"
  fi

  end=$(date +%s%N 2>/dev/null || date +%s)
  duration=$(( (end - start) /1000000 ))
  local duration_str
  if [ $duration -gt 60000 ]; then
    duration_str="$(( duration / 60000 ))m $(( (duration % 60000) / 1000 ))s"
  elif [ $duration -gt 1000 ]; then
    duration_str="$(( duration / 1000 )).$(( duration % 1000 ))s"
  else
    duration_str="${duration}ms"
  fi

  if [ $exit_code -eq 0 ]; then
    _BUILD_SUCCEEDED+=("$name")
    build_success "<<< Completed: $name (Duration: $duration_str)"
    return 0
  else
    _BUILD_FAILED+=("$name")
    _BUILD_ERRORS["$name"]="$output"
    build_err "<<< FAILED: $name (Duration: $duration_str)"
    return $exit_code
  fi
}

build_run_step() {
  local name="$1"
  shift

  build_log ""
  build_log ">>> Starting: $name"
  build_log "============================================================"

  local start end duration exit_code=0
  start=$(date +%s%N 2>/dev/null || date +%s)

  if "$@" 2>&1 | tee -a "$_BUILD_LOG_FILE"; then
    : else
    exit_code=${PIPESTATUS[0]}
  fi

  end=$(date +%s%N 2>/dev/null || date +%s)
  duration=$(( (end - start) /1000000 ))
  local duration_str
  if [ $duration -gt 60000 ]; then
    duration_str="$(( duration / 60000 ))m $(( (duration % 60000) / 1000 ))s"
  elif [ $duration -gt 1000 ]; then
    duration_str="$(( duration / 1000 )).$(( duration % 1000 ))s"
  else
    duration_str="${duration}ms"
  fi

  if [ $exit_code -eq 0 ]; then
    _BUILD_SUCCEEDED+=("$name")
    build_success "<<< Completed: $name (Duration: $duration_str)"
    return 0
  else
    _BUILD_FAILED+=("$name")
    build_err "<<< FAILED: $name (Duration: $duration_str)"
    return $exit_code
  fi
}

build_summary() {
  build_log ""
  build_log "============================================================"
  build_log "=== BUILD PIPELINE SUMMARY ==="
  build_log "============================================================"
  build_log ""

  local total=$(( ${#_BUILD_SUCCEEDED[@]} + ${#_BUILD_FAILED[@]} ))

  if [ ${#_BUILD_SUCCEEDED[@]} -gt 0 ]; then
    build_success "SUCCEEDED (${#_BUILD_SUCCEEDED[@]}):"
    for step in "${_BUILD_SUCCEEDED[@]}"; do
      build_success "  [OK] $step"
    done
  fi

  build_log ""

  if [ ${#_BUILD_FAILED[@]} -gt 0 ]; then
    build_err "FAILED (${#_BUILD_FAILED[@]}):"
    for step in "${_BUILD_FAILED[@]}"; do
      build_err "  [X] $step"
      if [ -n "${_BUILD_ERRORS[$step]:-}" ]; then
        build_err "      Error: ${_BUILD_ERRORS[$step]}"
      fi
    done
  fi

  build_log ""

  local success_rate=0
  if [ $total -gt 0 ]; then
    success_rate=$(awk "BEGIN {printf \"%.1f\", (${#_BUILD_SUCCEEDED[@]} / $total) * 100}")
  fi

  build_log "Total: $total steps, ${#_BUILD_SUCCEEDED[@]} succeeded, ${#_BUILD_FAILED[@]} failed ($success_rate% success rate)"
  build_log ""

  if [ -n "${_BUILD_LOG_FILE:-}" ]; then
    build_log "Full log available at: $_BUILD_LOG_FILE"
  fi

  local finished_at
  finished_at=$(_build_timestamp)

  local summary_json
  summary_json=$(cat <<EOF
{
  "startedAt": "$_BUILD_STARTED_AT",
  "finishedAt": "$finished_at",
  "workspace": "$_BUILD_WORKSPACE",
  "logPath": "$_BUILD_LOG_FILE",
  "summaryPath": "$_BUILD_SUMMARY_FILE",
  "totals": {
    "total": $total,
    "succeeded": ${#_BUILD_SUCCEEDED[@]},
    "failed": ${#_BUILD_FAILED[@]},
    "successRate": $success_rate
  },
  "succeededSteps": $(printf '%s\n' "${_BUILD_SUCCEEDED[@]:-}" | jq -R . | jq -s . 2>/dev/null || echo '[]'),
  "failedSteps": $(printf '%s\n' "${_BUILD_FAILED[@]:-}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
}
EOF
)

  if command -v jq >/dev/null 2>&1; then
    echo "$summary_json" > "$_BUILD_SUMMARY_FILE"
    build_log "Machine-readable summary available at:$_BUILD_SUMMARY_FILE"fi

  if [ ${#_BUILD_FAILED[@]} -gt 0 ]; then
    build_warn "Pipeline completed with errors!"
    return 1
  else
    build_success "Pipeline completed successfully!"
    return 0
  fi
}

build_finish() {
  local exit_code="${1:-0}"
  build_summary
  exit $exit_code
}

fi