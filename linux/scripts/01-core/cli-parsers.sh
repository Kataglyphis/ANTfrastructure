# shellcheck shell=bash
# Shared CLI argument parsing for orchestrator and runtime build scripts.
# Sourced by artifact-common.sh — never source this directly.
[ -n "${_CLI_PARSERS_SH_LOADED:-}" ] && return 0
_CLI_PARSERS_SH_LOADED=1

# Every parser below returns the number of args it consumed — 1 or 2 — or 0 when
# it did not recognize the flag; 255 means --help.
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

# Flags that set globals directly, so they need no nameref from either parser.
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

# For build-cross-chain.sh, build-cross-compiler.sh, build-cross-stage.sh and
# verify-cross-chain.sh: namerefs for the shared vars, then $1 $2 from their loop.
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

  local _rc=0
  _parse_global_flags "${arg}" "${val}" || _rc=$?
  if [ "${_rc}" -ne 0 ]; then return "${_rc}"; fi

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

# Shared flags parse in every entry point but are inert in some (--push in
# build-cross-chain, --parallel-archs in build-cross-stage). Each script lists its
# own in ORCHESTRATOR_UNSUPPORTED_FLAGS; warn, never reject (Batch 5 / O5).
orchestrator_warn_if_unsupported() {
  local flag="$1" script="${2:-this script}" u
  # shellcheck disable=SC2086  # intentional word-split of the space-separated list
  for u in ${ORCHESTRATOR_UNSUPPORTED_FLAGS:-}; do
    if [ "${flag}" = "${u}" ]; then
      warn "${flag} is accepted for CLI compatibility but has no effect in ${script} — ignoring it."
      return 0
    fi
  done
  return 1
}

# Runs a parser and turns its return code into _DP_SHIFT (0/1/2 args to shift);
# 255 for --help still propagates to the caller.
dispatch_parsed_args() {
  local _dp_rc=0
  _DP_SHIFT=0
  "$@" || _dp_rc=$?
  case $_dp_rc in
    1) _DP_SHIFT=1; return 0 ;;
    2)
      # Reject an empty or flag-like value centrally: a trailing --target-arches
      # used to assign "", which falls through to CROSS_DEFAULT_ARCHES and builds
      # all three arches instead of erroring.
      local _dp_val="${*: -1}" _dp_flag="${*: -2:1}"
      if [ -z "${_dp_val}" ] || [ "${_dp_val#--}" != "${_dp_val}" ]; then
        echo "ERROR: ${_dp_flag} requires a value (got '${_dp_val}')" >&2
        return 1
      fi
      _DP_SHIFT=2; return 0 ;;
    *) return "$_dp_rc" ;;
  esac
}

# dispatch_parsed_args plus the 255 → usage+exit case, so callers only look at
# _DP_SHIFT. Usage: consume_shared_arg usage_fn parse_fn NAMEREFS... "$1" "${2:-}"
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

# Returns 0 when _DP_SHIFT is 1 or 2 (caller: shift "${_DP_SHIFT}"; continue),
# 1 when it is 0 (caller handles the arg itself).
consume_dp_shift() {
  case "${_DP_SHIFT}" in
    1) return 0 ;;
    2) return 0 ;;
    0) return 1 ;;
  esac
}

# For build-runtime-artifacts.sh and build-runtime-manifest.sh, whose flag sets
# are nearly identical: namerefs, then $1 $2 from their loop.
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

  local _rc=0
  _parse_global_flags "${arg}" "${val}" || _rc=$?
  if [ "${_rc}" -ne 0 ]; then return "${_rc}"; fi

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
