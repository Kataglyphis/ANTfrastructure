#!/usr/bin/env bash
# Vulkan setup-env.sh resolver: strict=1 stays silent and returns 1 on a miss; strict=0 sweeps more roots and warns.
[ -n "${_VULKAN_ENV_SH_LOADED:-}" ] && return 0
_VULKAN_ENV_SH_LOADED=1

# Same default as 02-toolchain/vulkan.sh, repeated so this module never needs it loaded.
_vulkan_env_default_prefix() {
  printf '%s' "${VULKAN_PREFIX:-${VULKAN_INSTALL_ROOT:-/opt/vulkan}}"
}

_vulkan_env_log() {
  if declare -F info >/dev/null 2>&1; then
    info "$@"
  else
    printf '[INFO] %s\n' "$*"
  fi
}

_vulkan_env_warn() {
  if declare -F warn >/dev/null 2>&1; then
    warn "$@"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

# Strict callers get only their prefix: an SDK found elsewhere would defeat their return-1 gate.
_vulkan_env_collect_roots() {
  local prefix="$1"
  local include_default_roots="${2:-1}"
  local root seen=""
  local -a wanted=("${prefix}")

  [ "${include_default_roots}" = "1" ] && wanted+=(/opt/vulkan "${HOME:-}/vulkan")

  _VULKAN_ENV_ROOTS=()
  for root in "${wanted[@]}"; do
    [ -n "${root}" ] || continue
    [ "${root}" = "/vulkan" ] && continue  # HOME unset
    case ":${seen}:" in
      *":${root}:"*) continue ;;
    esac
    seen="${seen:+${seen}:}${root}"
    _VULKAN_ENV_ROOTS+=("${root}")
  done
}

vulkan_env_find_setup_script() {
  local prefix="${1:-$(_vulkan_env_default_prefix)}"
  local include_default_roots="${2:-1}"
  local root candidate

  # An explicit override (set by lib/cmake-build.sh) wins over every probe.
  if [ -n "${VULKAN_SETUP_SCRIPT:-}" ] && [ -f "${VULKAN_SETUP_SCRIPT}" ]; then
    printf '%s' "${VULKAN_SETUP_SCRIPT}"
    return 0
  fi

  _vulkan_env_collect_roots "${prefix}" "${include_default_roots}"

  if [ -n "${VULKAN_VERSION:-}" ]; then
    for root in "${_VULKAN_ENV_ROOTS[@]}"; do
      if [ -r "${root}/${VULKAN_VERSION}/setup-env.sh" ]; then
        printf '%s' "${root}/${VULKAN_VERSION}/setup-env.sh"
        return 0
      fi
    done

    # Also accept an arch subdirectory: <version>/x86_64/setup-env.sh.
    for root in "${_VULKAN_ENV_ROOTS[@]}"; do
      for candidate in "${root}/${VULKAN_VERSION}"/*/setup-env.sh; do
        [ -r "${candidate}" ] || continue
        printf '%s' "${candidate}"
        return 0
      done
    done
  fi

  if [ -n "${VULKAN_SDK:-}" ] && [ -r "${VULKAN_SDK}/setup-env.sh" ]; then
    printf '%s' "${VULKAN_SDK}/setup-env.sh"
    return 0
  fi

  # Fallback: the first setup-env.sh under any search root.
  for root in "${_VULKAN_ENV_ROOTS[@]}"; do
    for candidate in "${root}"/*/setup-env.sh; do
      [ -r "${candidate}" ] || continue
      printf '%s' "${candidate}"
      return 0
    done
  done

  return 1
}

vulkan_env_source() {
  local prefix="${1:-$(_vulkan_env_default_prefix)}"
  local sanitize_mode="${2:-keep-libs}"
  local strict="${3:-${VULKAN_ENV_STRICT:-0}}"
  local setup_path=""
  local include_default_roots=1

  # Strict callers stay scoped to their prefix; launchers sweep /opt/vulkan and ~/vulkan too.
  [ "${strict}" = "1" ] && include_default_roots=0

  setup_path="$(vulkan_env_find_setup_script "${prefix}" "${include_default_roots}")" || setup_path=""

  if [ -n "${setup_path}" ]; then
    # Strict callers capture stdout, so only launchers get the info line.
    [ "${strict}" = "1" ] || _vulkan_env_log "Sourcing Vulkan env from ${setup_path}"
    # setup-env.sh may inspect $1/$2, so clear this helper's function args first.
    set --
    # LunarG's setup-env.sh reads $1 unguarded, so source it with nounset off and restore it after.
    local _vke_had_u=0
    case $- in *u*) _vke_had_u=1; set +u ;; esac
    # shellcheck disable=SC1090,SC1091
    . "${setup_path}"
    [ "${_vke_had_u}" = "1" ] && set -u
    case "${sanitize_mode}" in
      sanitize-libs)
        # sanitize_vulkan_sdk_env lives in 02-toolchain/vulkan.sh; sanitize only when it is loaded.
        if declare -F sanitize_vulkan_sdk_env >/dev/null 2>&1; then
          sanitize_vulkan_sdk_env "${prefix}/"
        fi
        ;;
    esac
    return 0
  fi

  if [ "${strict}" = "1" ]; then
    return 1
  fi

  if command -v glslc >/dev/null 2>&1; then
    _vulkan_env_log "glslc found in PATH, skipping explicit Vulkan env sourcing"
    return 0
  fi

  _vulkan_env_warn "Vulkan setup-env.sh not found – continuing without explicit sourcing"
  return 0
}
