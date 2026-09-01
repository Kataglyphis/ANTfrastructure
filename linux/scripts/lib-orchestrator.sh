# shellcheck shell=bash
# lib-orchestrator.sh
# Shared preamble + argument-loop helpers for the top-level build-*.sh
# orchestrator scripts.  Source this AFTER computing REPO_ROOT and at TOP LEVEL
# (never inside a function):
#
#   REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#   source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
#   orchestrator_preamble   # (cross scripts)  OR  runtime_flow_preamble (runtime)
#
# WHY TOP-LEVEL: artifact-common.sh transitively sources modules (stage-defs.sh,
# digest-pinning.sh, …) that `declare -A`/`declare -a` global arrays.  A
# `declare` inside a function without -g is function-local, so sourcing
# artifact-common from within a helper function would make those arrays vanish
# when the function returns.  We therefore source artifact-common at this file's
# top level, which — because this file is itself sourced at the caller's top
# level — lands the arrays in the caller's global scope.
#
# Provides:
#   orchestrator_preamble       — IMAGE_REPO default + init_mirror_defaults
#   run_orchestrator_arg_loop   — the consume_shared_arg/consume_dp_shift/case
#                                 loop around parse_shared_orchestrator_args
#   runtime_flow_preamble       — runtime-flow-common defaults + TARGET_ARCHES
#   run_runtime_arg_loop        — the same loop around parse_shared_runtime_args
#
# Argument-loop case-handler contract
# -----------------------------------
# Each caller passes a "case handler" function that handles its script-specific
# flags.  The handler is invoked as `<handler> "$@"` with the caller's remaining
# args ($1 is the flag).  It must:
#   * set _OARG_SHIFT to the number of args it consumed (1 or 2), and return 0
#     when it recognized $1; or
#   * return non-zero when $1 is unknown (the loop then prints usage + exits 1).
[ -n "${_LIB_ORCHESTRATOR_SH_LOADED:-}" ] && return 0
_LIB_ORCHESTRATOR_SH_LOADED=1

_LIB_ORCHESTRATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the shared artifact/CLI helpers at top level (see WHY TOP-LEVEL above).
# artifact-common.sh has its own load guard, so repeated sourcing is a no-op.
# shellcheck source=linux/scripts/01-core/artifact-common.sh
source "${_LIB_ORCHESTRATOR_DIR}/01-core/artifact-common.sh"

# ── cross-lane preamble ────────────────────────────────────────────────────────
# Shared invariant scalar defaults for the cross orchestrators
# (build-cross-chain.sh, build-cross-compiler.sh, build-cross-stage.sh,
# build-sdk-artifacts.sh).  Script-specific defaults (CROSS_TARGETS /
# TARGET_ARCH(ES) / OUTPUT_ROOT / …) stay in each script because they differ.
orchestrator_preamble() {
  IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
  init_mirror_defaults
}

# ── shared usage: fast-ubuntu-mirror option lines ───────────────────────────────
# Single source of truth for the three --fast-ubuntu-mirror* option lines shared
# by every cross orchestrator usage() text (build-cross-chain / build-cross-stage
# / build-cross-compiler / build-sdk-artifacts).  The descriptions had drifted
# across the four copies; emit them here so they stay in sync.  Call between two
# cat <<'EOF' blocks inside each usage().
orchestrator_usage_mirror_options() {
  cat <<'EOF'
  --fast-ubuntu-mirror                Replace Ubuntu archive/security/ports mirrors during builds
  --fast-ubuntu-mirror-url URL        Archive mirror URL
  --fast-ubuntu-ports-mirror-url URL  Optional ubuntu-ports mirror URL
EOF
}

# ── cross-lane argument loop ────────────────────────────────────────────────────
# Usage:
#   run_orchestrator_arg_loop <usage_fn> <case_handler_fn> \
#     <arches_var> <use_mirror_var> <mirror_url_var> <ports_url_var> \
#     <image_repo_var> <vulkan_var> <push_var> "$@"
#
# The seven variable NAMES are forwarded verbatim to
# parse_shared_orchestrator_args so each script keeps its exact positional
# nameref contract (e.g. arches bound to CROSS_TARGETS vs TARGET_ARCHES,
# push bound to PUSH_IMAGES vs a throwaway sink).
run_orchestrator_arg_loop() {
  local _usage_fn="$1" _case_fn="$2"
  local _n1="$3" _n2="$4" _n3="$5" _n4="$6" _n5="$7" _n6="$8" _n7="$9"
  shift 9

  while [ $# -gt 0 ]; do
    local _flag="$1"
    consume_shared_arg "${_usage_fn}" \
      parse_shared_orchestrator_args \
      "${_n1}" "${_n2}" "${_n3}" "${_n4}" "${_n5}" "${_n6}" "${_n7}" \
      "$1" "${2:-}" || break
    # O5: a shared flag was recognized — warn if this script lists it inert.
    if consume_dp_shift; then
      orchestrator_warn_if_unsupported "${_flag}" "$(basename "${0:-orchestrator}")" || true
      shift "${_DP_SHIFT}"
      continue
    fi
    _OARG_SHIFT=0
    if "${_case_fn}" "$@"; then
      shift "${_OARG_SHIFT}"
      continue
    fi
    warn "Unknown option: $1"; "${_usage_fn}" >&2; exit 1
  done
}

# ── runtime-flow preamble ───────────────────────────────────────────────────────
# Shared preamble for build-runtime-artifacts.sh and build-runtime-manifest.sh.
# runtime-flow-common.sh declares only functions/scalars (no arrays), so it is
# safe to source here; artifact-common (with its global arrays) is already
# loaded at this file's top level.  Sets the shared TARGET_ARCHES default;
# script-specific vars (OUTPUT_ROOT/IMAGE_PREFIX/IMAGE_NAME/…) stay in each
# script.
runtime_flow_preamble() {
  # shellcheck source=linux/scripts/01-core/runtime-flow-common.sh
  source "${_ARTIFACT_COMMON_DIR}/runtime-flow-common.sh"
  init_runtime_flow_defaults
  TARGET_ARCHES="$(resolve_arch_list)"
}

# ── runtime-flow argument loop ──────────────────────────────────────────────────
# Usage: run_runtime_arg_loop <usage_fn> <case_handler_fn> "$@"
#
# build-runtime-artifacts.sh and build-runtime-manifest.sh pass an identical
# 11-nameref list to parse_shared_runtime_args, so it is hardcoded here.  Each
# script supplies only its distinct extra flags via the case handler.
run_runtime_arg_loop() {
  local _usage_fn="$1" _case_fn="$2"
  shift 2

  while [ $# -gt 0 ]; do
    consume_shared_arg "${_usage_fn}" \
      parse_shared_runtime_args \
      TARGET_ARCHES ARTIFACT_IMAGE_PREFIX ARTIFACT_BUILD_MODE \
      BASE_DOCKERFILE_PATH PACKAGE_DOCKERFILE_PATH WRAPPER_DOCKERFILE_PATH \
      TORCH_APP_MODE \
      USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL FAST_UBUNTU_PORTS_MIRROR_URL \
      PUSH_INTERMEDIATE_IMAGES \
      "$1" "${2:-}" || break
    consume_dp_shift && { shift "${_DP_SHIFT}"; continue; }
    _OARG_SHIFT=0
    if "${_case_fn}" "$@"; then
      shift "${_OARG_SHIFT}"
      continue
    fi
    warn "Unknown option: $1"; "${_usage_fn}" >&2; exit 1
  done
}

# Start the run's resource monitor. $1 is the run-id used when CROSS_RUN_ID is
# unset. Idempotent; self-terminates via --watch-pid. RESOURCE_MONITOR=0
# disables. See docs/build-resource-monitoring.md.
start_resource_monitor() {
  [ "${RESOURCE_MONITOR:-1}" = "1" ] || return 0
  local mon="${REPO_ROOT}/linux/scripts/01-core/resource-monitor.sh"
  [ -x "${mon}" ] || return 0
  local out="${LOG_DIR:-${REPO_ROOT}}" rid="${CROSS_RUN_ID:-$1}"
  pgrep -f "resource-monitor.sh.*${rid}" >/dev/null 2>&1 && return 0
  bash "${mon}" --out-dir "${out}" --run-id "${rid}" --stage-log-dir "${out}" \
    --disk-path "${BUILDKIT_CACHE_DIR:-/}" --watch-pid "$$" </dev/null >/dev/null 2>&1 &
  log "resource-monitor: sampling -> ${out}/resources-${rid}.csv (RESOURCE_MONITOR=0 to disable)"
}
