# shellcheck shell=bash
# cli-parsers.sh
# Shared CLI argument parsing helpers for orchestrator and runtime build scripts.
# Sourced by artifact-common.sh — do not source this directly.
[ -n "${_CLI_PARSERS_SH_LOADED:-}" ] && return 0
_CLI_PARSERS_SH_LOADED=1
#
# Provides:
#   parse_shared_orchestrator_args   — cross-chain orchestrator arg parser
#   dispatch_parsed_args             — dispatches parser, sets _DP_SHIFT
#   parse_shared_runtime_args        — runtime build script arg parser
#   runtime_post_parse_setup         — post-parse normalization + context prep
#
# Flags that set global variables directly (no nameref needed):
#   --dry-run                     → DRY_RUN=1
#   --parallel-archs              → PARALLEL_ARCHS=1
#   --max-parallel-archs N        → MAX_PARALLEL_ARCHS=N
#   --fast-ubuntu-mirror          → USE_FAST_UBUNTU_MIRROR=true (via _parse_mirror_flags)
#
# After dispatch_parsed_args returns 0:
#   _DP_SHIFT=0  flag not recognized, caller should handle it
#   _DP_SHIFT=1  single-arg flag consumed (caller: shift 1, continue)
#   _DP_SHIFT=2  two-arg flag consumed   (caller: shift 2, continue)
# Returns 255 for --help (caller should print usage and exit).
# Returns non-zero on parse error.

# ==============================================================================
# _parse_mirror_flags
#
# Internal: handle the three mirror-related flags.  Used by both
# parse_shared_orchestrator_args and parse_shared_runtime_args to
# eliminate duplicated case-branch logic.
#
# Usage: _parse_mirror_flags <use_fast_mirror_nameref> <fast_mirror_url_nameref> <fast_ports_url_nameref> <arg> <val>
# Returns 1 (single-arg consumed), 2 (two-arg consumed), or 0 (not a mirror flag).
# ==============================================================================
_parse_mirror_flags() {
  local -n _pmf_use=$1
  local -n _pmf_url=$2
  local -n _pmf_ports=$3
  local arg="$4" val="$5"

  case "${arg}" in
    --fast-ubuntu-mirror)
      _pmf_use=true; return 1 ;;
    --fast-ubuntu-mirror-url)
      _pmf_use=true; _pmf_url="${val}"; return 2 ;;
    --fast-ubuntu-ports-mirror-url)
      _pmf_use=true; _pmf_ports="${val}"; return 2 ;;
    *)
      return 0 ;;
  esac
}

# ==============================================================================
# _parse_global_flags
#
# Internal: handle flags that set global variables (--dry-run,
# --parallel-archs, --max-parallel-archs).  These are shared across
# orchestrator and runtime parsers.
#
# Usage: _parse_global_flags <arg> <val>
# Returns 1, 2, or 0 (not a global flag).
# ==============================================================================
_parse_global_flags() {
  local arg="$1" val="$2"

  case "${arg}" in
    --dry-run)
      DRY_RUN=1; return 1 ;;
    --parallel-archs)
      PARALLEL_ARCHS=1; return 1 ;;
    --max-parallel-archs)
      MAX_PARALLEL_ARCHS="${val}"; return 2 ;;
    *)
      return 0 ;;
  esac
}

# ==============================================================================
# parse_shared_orchestrator_args
#
# Shared CLI argument parsing for cross-chain orchestrator scripts.
# Call this from the argument loop in build-cross-chain.sh,
# build-cross-compiler.sh, build-cross-stage.sh, and verify-cross-chain.sh.
#
# Receives namerefs for the shared variables, then $1 $2 from the caller's loop.
# Also handles global flags (--dry-run, --parallel-archs, mirror flags).
#
# Return values:
#   1  — consumed a single-arg flag (caller should shift 1)
#   2  — consumed a two-arg flag (caller should shift 2)
#   0  — flag not recognized (caller should handle it)
#   255 — --help requested (caller should print usage and exit)
# ==============================================================================
parse_shared_orchestrator_args() {
  local -n _psoa_target_arches=$1
  local -n _psoa_use_fast_mirror=$2
  local -n _psoa_fast_mirror_url=$3
  local -n _psoa_fast_ports_url=$4
  local -n _psoa_image_repo=$5
  local -n _psoa_vulkan_version=$6
  local -n _psoa_push=$7
  shift 7 || true
  local arg="$1" val="$2"

  # Global flags (--dry-run, --parallel-archs, etc.)
  local _rc=0
  _parse_global_flags "${arg}" "${val}" || _rc=$?
  if [ "${_rc}" -ne 0 ]; then return "${_rc}"; fi

  # Mirror flags (shared across both parsers)
  _parse_mirror_flags _psoa_use_fast_mirror _psoa_fast_mirror_url _psoa_fast_ports_url "${arg}" "${val}" || _rc=$?
  if [ "${_rc}" -ne 0 ]; then return "${_rc}"; fi

  case "${arg}" in
    --target-arches|--architectures)
      _psoa_target_arches="${val}"; return 2 ;;
    --image-repo)
      _psoa_image_repo="${val}"; return 2 ;;
    --vulkan-version)
      _psoa_vulkan_version="${val}"; return 2 ;;
    --push)
      _psoa_push=1; return 1 ;;
    -h|--help)
      return 255 ;;
    *)
      return 0 ;;
  esac
}

# ==============================================================================
# dispatch_parsed_args
#
# Calls a shared CLI argument parser and translates its return codes into
# the _DP_SHIFT variable for the caller to consume.
#
# After this returns 0:
#   _DP_SHIFT = 0  flag not recognized (caller handles it)
#   _DP_SHIFT = 1  consumed a single-arg flag
#   _DP_SHIFT = 2  consumed a two-arg flag
# Returns 255 for --help, non-zero on unexpected error.
# ==============================================================================
dispatch_parsed_args() {
  local _dp_rc=0
  _DP_SHIFT=0
  "$@" || _dp_rc=$?
  case $_dp_rc in
    1) _DP_SHIFT=1; return 0 ;;
    2)
      # Two-arg flag consumed. By contract the parser was invoked as
      # `parse_fn NAMEREFS... <flag> <value>` — reject an empty or flag-like
      # value here, centrally: a trailing `--target-arches` (or a typo that
      # made it swallow the NEXT flag as its value) used to assign "" /
      # "--push" silently, and an empty arch list falls through to
      # CROSS_DEFAULT_ARCHES — building all three arches instead of erroring.
      local _dp_val="${*: -1}" _dp_flag="${*: -2:1}"
      if [ -z "${_dp_val}" ] || [ "${_dp_val#--}" != "${_dp_val}" ]; then
        echo "ERROR: ${_dp_flag} requires a value (got '${_dp_val}')" >&2
        return 1
      fi
      _DP_SHIFT=2; return 0 ;;
    *) return "$_dp_rc" ;;
  esac
}

# ==============================================================================
# consume_shared_arg
#
# Wrapper around dispatch_parsed_args that handles the 255→usage+exit case
# so the caller only needs to check _DP_SHIFT for shift/continue.
#
# Usage:  consume_shared_arg usage_fn \
#           parse_shared_orchestrator_args NAMEREFS... \
#           "$1" "${2:-}" || exit 1
#         case "${_DP_SHIFT}" in 1) shift; continue;; 2) shift 2; continue;; esac
# ==============================================================================
consume_shared_arg() {
  local usage_fn="$1"
  shift
  local _csa_rc=0
  _DP_SHIFT=0
  dispatch_parsed_args "$@" || _csa_rc=$?
  case $_csa_rc in
    255) "${usage_fn}"; exit 0 ;;
    0) return 0 ;;
    *) return "$_csa_rc" ;;
  esac
}

# ==============================================================================
# consume_dp_shift
#
# Shortcut to handle _DP_SHIFT after consume_shared_arg returns 0.
# Instead of:
#   case "${_DP_SHIFT}" in 1) shift; continue ;; 2) shift 2; continue ;; esac
# Write:
#   consume_dp_shift; shift "${_DP_SHIFT}"; continue
#
# Returns 0 when _DP_SHIFT is 1 or 2 (caller should shift + continue).
# Returns 1 when _DP_SHIFT is 0 (caller should handle the arg locally).
# ==============================================================================
consume_dp_shift() {
  case "${_DP_SHIFT}" in
    1) return 0 ;;
    2) return 0 ;;
    0) return 1 ;;
  esac
}

# ==============================================================================
# parse_shared_runtime_args
#
# Shared CLI argument parsing for runtime build scripts.
# Call this from the argument loop in build-runtime-artifacts.sh and
# build-runtime-manifest.sh to handle their nearly identical flag sets.
#
# Receives: name-refs for all shared variables, then $1 $2 from the caller's loop.
# Also handles global flags (--dry-run, --parallel-archs, mirror flags).
#
# Return values:
#   1  — consumed a single-arg flag (caller should shift 1)
#   2  — consumed a two-arg flag (caller should shift 2)
#   0  — flag not recognized (caller should handle it)
#   255 — --help requested (caller should print usage and exit)
# ==============================================================================
parse_shared_runtime_args() {
  local -n _target_arches=$1
  local -n _artifact_image_prefix=$2
  local -n _artifact_build_mode=$3
  local -n _base_dockerfile=$4
  local -n _package_dockerfile=$5
  local -n _wrapper_dockerfile=$6
  local -n _torch_app_mode=$7
  local -n _use_fast_mirror=$8
  local -n _fast_mirror_url=$9
  local -n _fast_ports_url=${10}
  local -n _push_intermediate=${11}
  shift 11 || true
  local arg="$1" val="$2"

  # Global flags (--dry-run, --parallel-archs, etc.)
  local _rc=0
  _parse_global_flags "${arg}" "${val}" || _rc=$?
  if [ "${_rc}" -ne 0 ]; then return "${_rc}"; fi

  # Mirror flags (shared across both parsers)
  _parse_mirror_flags _use_fast_mirror _fast_mirror_url _fast_ports_url "${arg}" "${val}" || _rc=$?
  if [ "${_rc}" -ne 0 ]; then return "${_rc}"; fi

  case "${arg}" in
    --architectures|--target-arches)
      _target_arches="${val}"; return 2 ;;
    --artifact-image-prefix)
      _artifact_image_prefix="${val}"; return 2 ;;
    --artifact-build-mode)
      _artifact_build_mode="${val}"; return 2 ;;
    --base-dockerfile)
      _base_dockerfile="${val}"; return 2 ;;
    --package-dockerfile)
      _package_dockerfile="${val}"; return 2 ;;
    --wrapper-dockerfile|--torch-dockerfile)
      _wrapper_dockerfile="${val}"; return 2 ;;
    --torch-app-mode)
      _torch_app_mode="${val}"; return 2 ;;
    -h|--help)
      return 255 ;;
    *)
      return 0 ;;
  esac
}

# ==============================================================================
# runtime_post_parse_setup
#
# Shared post-parse setup for runtime build scripts.
# Call after argument parsing to normalize arches, set RUNTIME_IMAGE_PREFIX,
# and prepare local context chain.  Requires IMAGE_PREFIX or IMAGE_NAME to be
# set before calling.
# ==============================================================================
runtime_post_parse_setup() {
  local arches_var_name="${1:-TARGET_ARCHES}"
  local image_prefix="${2:-${IMAGE_PREFIX:-${IMAGE_NAME:-}}}"

  cd "${REPO_ROOT}" || exit 1

  # Resolve the arches variable dynamically
  local raw_arches="${!arches_var_name}"
  raw_arches="$(normalize_target_arches "${raw_arches}")"
  printf -v "${arches_var_name}" '%s' "${raw_arches}"

  export RUNTIME_IMAGE_PREFIX="${image_prefix}"
  runtime_prepare_local_context_chain
  runtime_install_local_context_cleanup_trap
}
