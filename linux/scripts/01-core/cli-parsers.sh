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
      # shellcheck disable=SC2034 # shared flag parser; read by the orchestrators that source it
      DRY_RUN=1; return 1 ;;
    --parallel-archs)
      # shellcheck disable=SC2034 # shared flag parser; read by parallel-loop.sh
      PARALLEL_ARCHS=1; return 1 ;;
    --max-parallel-archs)
      # shellcheck disable=SC2034 # shared flag parser; read by runtime-flow-common.sh
      MAX_PARALLEL_ARCHS="${val}"; return 2 ;;
    *)
      return 0 ;;
  esac
}

_parse_common_build_flags() {
  local -n _pcbf_arches="$1"
  local _pcbf_rc=0
  _parse_global_flags "$5" "$6" || _pcbf_rc=$?
  if [ "${_pcbf_rc}" -ne 0 ]; then return "${_pcbf_rc}"; fi
  _parse_mirror_flags "$2" "$3" "$4" "$5" "$6" || _pcbf_rc=$?
  if [ "${_pcbf_rc}" -ne 0 ]; then return "${_pcbf_rc}"; fi
  case "$5" in
    --target-arches|--architectures) _pcbf_arches="$6"; return 2 ;;
    -h|--help) return 255 ;;
    *) return 0 ;;
  esac
}

_parse_named_build_flags() {
  local _pnbf_rc=0
  _parse_common_build_flags "$1" "$2" "$3" "$4" "$5" "$6" || _pnbf_rc=$?
  if [ "${_pnbf_rc}" -ne 0 ]; then return "${_pnbf_rc}"; fi
  [ -n "$5" ] || return 0
  local -n _pnbf_options="$7"
  local _pnbf_destination="${_pnbf_options[$5]:-}"
  if [ -n "${_pnbf_destination}" ]; then
    local -n _pnbf_value="${_pnbf_destination}"
    _pnbf_value="$6"
    return 2
  fi
  return 0
}

# The cross orchestrators' shared flags: seven namerefs, then the loop's $1 $2.
parse_shared_orchestrator_args() {
  local -n _psoa_push=$7
  local -A _psoa_options=([--image-repo]="$5" [--vulkan-version]="$6")
  local arg="$8" val="$9"
  case "${arg}" in
    --push) _psoa_push=1; return 1 ;;
  esac
  _parse_named_build_flags "$1" "$2" "$3" "$4" "${arg}" "${val}" _psoa_options
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
  local -A _psra_options=(
    [--artifact-image-prefix]="$2" [--artifact-build-mode]="$3"
    [--base-dockerfile]="$4" [--package-dockerfile]="$5"
    [--wrapper-dockerfile]="$6" [--torch-dockerfile]="$6" [--torch-app-mode]="$7"
  )
  local -n _push_intermediate=${11}
  _parse_named_build_flags "$1" "$8" "$9" "${10}" "${12}" "${13}" _psra_options
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
