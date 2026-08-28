#!/usr/bin/env bash
# vulkan-env.sh - locate and source a Vulkan SDK's setup-env.sh.
#
# One home for a resolver that had two copies with OPPOSITE miss contracts, so
# the contract is now per call, not per copy:
#   strict=1  search only the caller's prefix, return 1 on a miss, stay SILENT
#             (some callers capture stdout).
#   strict=0  also sweep /opt/vulkan and ~/vulkan, fall back to glslc on PATH,
#             then warn and return 0. The default.
#
# Strictness is POSITIONAL (default ${VULKAN_ENV_STRICT:-0}), not env-only: the
# image-side callers must keep `return 1` regardless of a stray export.
#
# Dependency-free on purpose -- no set -e/-u at file scope, no downloads.sh -- so
# a dev launcher can source it for one function without the SDK installer's
# shell options.
#
# vulkan_env_find_setup_script [prefix] [include_default_roots]  -> path, or 1
# vulkan_env_source [prefix] [sanitize_mode] [strict]            -> resolve+source
[ -n "${_VULKAN_ENV_SH_LOADED:-}" ] && return 0
_VULKAN_ENV_SH_LOADED=1

# Default install location - same default 02-toolchain/vulkan.sh uses, repeated
# here so this module never depends on that file being loaded first.
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

# Fills the _VULKAN_ENV_ROOTS array with the SDK search roots in priority order:
# the caller's prefix first, then - only when $2 is 1 - the two extra roots the
# launcher copy hardcoded. The extra roots are OFF for strict callers on
# purpose: for them an explicit prefix is an instruction ("is there an SDK
# *here*?"), and silently answering with an SDK from somewhere else would break
# the `return 1` gate they rely on. A global array (rather than a $(...)
# capture) keeps paths with spaces intact and avoids a subshell in a helper that
# runs on every build script's startup.
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

  # An explicit override wins over every probe (set by lib/cmake-build.sh and
  # run-ctest.sh --vulkan-setup, directly or via
  # CMAKE_BUILD_DEFAULT_VULKAN_SETUP_SCRIPT).
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

    # Also accept SDKs installed into a subdirectory (arch folder), e.g.
    # /opt/vulkan/<version>/x86_64/setup-env.sh
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

  # Fallback: the first setup-env.sh found under any search root
  # (e.g. /opt/vulkan/*/setup-env.sh or ~/vulkan/*/setup-env.sh).
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

  # Strict callers stay scoped to the prefix they passed (see
  # _vulkan_env_collect_roots); launchers sweep /opt/vulkan and ~/vulkan too.
  [ "${strict}" = "1" ] && include_default_roots=0

  setup_path="$(vulkan_env_find_setup_script "${prefix}" "${include_default_roots}")" || setup_path=""

  if [ -n "${setup_path}" ]; then
    # Strict callers redirect stdout/stderr away (or capture stdout); keep the
    # informational line for the launcher contract only.
    [ "${strict}" = "1" ] || _vulkan_env_log "Sourcing Vulkan env from ${setup_path}"
    # setup-env.sh may inspect $1/$2, so clear this helper's function args first.
    set --
    # VENDOR SCRIPT under nounset: LunarG's setup-env.sh reads $1 UNGUARDED
    # (line 14 in 1.4.357.0). With the args just cleared and a strict-mode
    # caller (tvm.sh runs set -euo pipefail), that is a guaranteed
    # "$1: unbound variable" abort — it killed the sdk stage's TVM step.
    # Source vendor code with nounset suspended, restore afterwards (same
    # pattern as sourcing profile.d or a venv activate).
    local _vke_had_u=0
    case $- in *u*) _vke_had_u=1; set +u ;; esac
    # shellcheck disable=SC1090,SC1091
    . "${setup_path}"
    [ "${_vke_had_u}" = "1" ] && set -u
    case "${sanitize_mode}" in
      sanitize-libs)
        # sanitize_vulkan_sdk_env lives in 02-toolchain/vulkan.sh. This module
        # stays free of that dependency and only sanitizes when the installer
        # module is loaded too (which is the case for every strict caller).
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
