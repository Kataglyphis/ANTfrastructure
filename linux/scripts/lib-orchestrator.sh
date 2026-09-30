# shellcheck shell=bash
# Source at top level after REPO_ROOT: artifact-common.sh's `declare -A` arrays go function-local in a function.
[ -n "${_LIB_ORCHESTRATOR_SH_LOADED:-}" ] && return 0
_LIB_ORCHESTRATOR_SH_LOADED=1

_LIB_ORCHESTRATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Top level keeps its arrays global; its own load guard makes re-sourcing a no-op.
# shellcheck source=linux/scripts/01-core/artifact-common.sh
source "${_LIB_ORCHESTRATOR_DIR}/01-core/artifact-common.sh"
# RUNTIME_WHEELS_SOURCE. Beside, not inside, 01-core: that tree is in the compiler image's closure.
# shellcheck source=linux/scripts/lib-runtime-wheels.sh
source "${_LIB_ORCHESTRATOR_DIR}/lib-runtime-wheels.sh"
# HAILO_NESTED_CACHE / HAILO_PYHAILORT_IPO: the orchestrators check them before the first stage.
# shellcheck source=linux/scripts/03-media/build/hailo/hailo-build-lib.sh
source "${_LIB_ORCHESTRATOR_DIR}/03-media/build/hailo/hailo-build-lib.sh"

# Forwarded like versions.env keys but kept out of it, which would re-key the chain. docs/linux-cross-builds.md#operational-env-knobs-not-versionsenv
_VERSION_BUILD_ARG_VARS+=(WEB_LANE_TOOLS_SOURCE WEB_LANE_TOOLS_CACHE WEB_LANE_TOOLS_CROSS_ARCHES)
_VERSION_BUILD_ARG_VARS+=(HAILO_NESTED_CACHE HAILO_PYHAILORT_IPO)

# Cross-lane preamble: shared defaults only; the ones that differ stay in each script.
orchestrator_preamble() {
  IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
  init_mirror_defaults
}

# One copy of the --fast-ubuntu-mirror* usage lines so the four orchestrators cannot drift.
orchestrator_usage_mirror_options() {
  cat <<'EOF'
  --fast-ubuntu-mirror                Replace Ubuntu archive/security/ports mirrors during builds
  --fast-ubuntu-mirror-url URL        Archive mirror URL
  --fast-ubuntu-ports-mirror-url URL  Optional ubuntu-ports mirror URL
EOF
}

# <usage_fn> <case_fn> <7 nameref names> "$@"; case_fn sets _OARG_SHIFT and returns 0, else non-zero.
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

# Runtime-flow preamble: runtime-flow-common.sh declares no arrays, so sourcing it here is safe.
runtime_flow_preamble() {
  # shellcheck source=linux/scripts/01-core/runtime-flow-common.sh
  source "${_ARTIFACT_COMMON_DIR}/runtime-flow-common.sh"
  init_runtime_flow_defaults
  TARGET_ARCHES="$(resolve_arch_list)"
}

# <usage_fn> <case_fn> "$@"; both runtime scripts share the 11-nameref list, so it is fixed here.
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

# $1 is the run id when CROSS_RUN_ID is unset; RESOURCE_MONITOR=0 disables. See docs/build-resource-monitoring.md
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
