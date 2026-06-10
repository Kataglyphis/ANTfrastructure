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
#   runtime_dispatch_shared_args     — runtime dispatch wrapper
#   runtime_post_parse_setup         — post-parse normalization + context prep
#
# After dispatch_parsed_args returns 0:
#   _DP_SHIFT=0  flag not recognized, caller should handle it
#   _DP_SHIFT=1  single-arg flag consumed (caller: shift 1, continue)
#   _DP_SHIFT=2  two-arg flag consumed   (caller: shift 2, continue)
# Returns 255 for --help (caller should print usage and exit).
# Returns non-zero on parse error.

# ==============================================================================
# parse_shared_orchestrator_args
#
# Shared CLI argument parsing for cross-chain orchestrator scripts.
# Call this from the argument loop in build-cross-chain.sh,
# build-cross-compiler.sh, and build-sdk-artifacts.sh.
#
# Receives namerefs for the shared variables, then $1 $2 from the caller's loop.
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

  case "${arg}" in
    --target-arches|--architectures)
      _psoa_target_arches="${val}"; return 2 ;;
    --image-repo)
      _psoa_image_repo="${val}"; return 2 ;;
    --vulkan-version)
      _psoa_vulkan_version="${val}"; return 2 ;;
    --fast-ubuntu-mirror)
      _psoa_use_fast_mirror=true; return 1 ;;
    --fast-ubuntu-mirror-url)
      _psoa_use_fast_mirror=true; _psoa_fast_mirror_url="${val}"; return 2 ;;
    --fast-ubuntu-ports-mirror-url)
      _psoa_use_fast_mirror=true; _psoa_fast_ports_url="${val}"; return 2 ;;
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
    2) _DP_SHIFT=2; return 0 ;;
    *) return "$_dp_rc" ;;
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
    --fast-ubuntu-mirror)
      _use_fast_mirror=true; return 1 ;;
    --fast-ubuntu-mirror-url)
      _use_fast_mirror=true; _fast_mirror_url="${val}"; return 2 ;;
    --fast-ubuntu-ports-mirror-url)
      _use_fast_mirror=true; _fast_ports_url="${val}"; return 2 ;;
    -h|--help)
      return 255 ;;
    *)
      return 0 ;;
  esac
}

# ==============================================================================
# runtime_dispatch_shared_args
#
# Shared dispatch wrapper for runtime build scripts.
# Both build-runtime-artifacts.sh and build-runtime-manifest.sh call this.
# Pass the same namerefs + "$1" "$2" as parse_shared_runtime_args.
# Sets _DP_SHIFT for the caller (see dispatch_parsed_args).
# ==============================================================================
runtime_dispatch_shared_args() {
  dispatch_parsed_args parse_shared_runtime_args "$@"
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
