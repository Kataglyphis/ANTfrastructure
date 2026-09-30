# shellcheck shell=bash
# Shared CLI parsing for the orchestrator and runtime scripts; sourced only through artifact-common.sh.
[ -n "${_CLI_PARSERS_SH_LOADED:-}" ] && return 0
_CLI_PARSERS_SH_LOADED=1

# Every parser returns the args it consumed (1 or 2), 0 for an unknown flag, 255 for --help.
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

# The cross orchestrators' shared flags: seven namerefs, then the loop's $1 $2.
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

# Flags inert in one entry point (its ORCHESTRATOR_UNSUPPORTED_FLAGS) warn, never reject.
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

# Turns a parser's return code into _DP_SHIFT; 255 (--help) still propagates.
dispatch_parsed_args() {
  local _dp_rc=0
  _DP_SHIFT=0
  "$@" || _dp_rc=$?
  case $_dp_rc in
    1) _DP_SHIFT=1; return 0 ;;
    2)
      # An empty value would fall through to the default and build every arch.
      local _dp_val="${*: -1}" _dp_flag="${*: -2:1}"
      if [ -z "${_dp_val}" ] || [ "${_dp_val#--}" != "${_dp_val}" ]; then
        echo "ERROR: ${_dp_flag} requires a value (got '${_dp_val}')" >&2
        return 1
      fi
      _DP_SHIFT=2; return 0 ;;
    *) return "$_dp_rc" ;;
  esac
}

# consume_shared_arg <usage_fn> <parse_fn> <namerefs...> "$1" "${2:-}": handles --help, so callers read only _DP_SHIFT.
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

# 0: the caller shifts _DP_SHIFT and continues; 1: the caller handles the arg itself.
consume_dp_shift() {
  case "${_DP_SHIFT}" in
    1) return 0 ;;
    2) return 0 ;;
    0) return 1 ;;
  esac
}

# The runtime scripts' shared flags: eleven namerefs, then the loop's $1 $2.
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

# runtime_post_parse_setup [arches_var] [image_prefix]: needs IMAGE_PREFIX or IMAGE_NAME set.
runtime_post_parse_setup() {
  local arches_var_name="${1:-TARGET_ARCHES}"
  local image_prefix="${2:-${IMAGE_PREFIX:-${IMAGE_NAME:-}}}"

  cd "${REPO_ROOT}" || exit 1

  local raw_arches="${!arches_var_name}"
  raw_arches="$(normalize_target_arches "${raw_arches}")"
  printf -v "${arches_var_name}" '%s' "${raw_arches}"

  # A variant must write variant tags too, or its wrappers overwrite the default :latest-<arch>.
  local _variant; _variant="$(cross_variant)" || exit 1
  if [ -n "${_variant}" ]; then
    case "-${image_prefix##*:}-" in
      *"-${_variant}-"*) ;;
      *) err "the ${_variant} variant is active (CROSS_VARIANT / ENABLE_NVIDIA / ENABLE_AMD) but the runtime image prefix ${image_prefix} carries no -${_variant}: it would write the default chain's tags. Use $(cross_final_image_tag)." ;;
    esac
  fi

  export RUNTIME_IMAGE_PREFIX="${image_prefix}"
  runtime_prepare_local_context_chain
  runtime_install_local_context_cleanup_trap
}
