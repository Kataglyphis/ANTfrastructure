#!/usr/bin/env bash
# version-forwarding.sh — forward versions.env vars as --build-arg to
# nerdctl build.
#
# Every KEY=value line in versions.env is forwarded, EXCEPT variables whose
# assignment is immediately preceded by a `# noforward` comment line
# (orchestrator/host-only values). Forgetting a marker is harmless: a build
# arg no Dockerfile declares is ignored by BuildKit; forgetting to forward a
# consumed variable is not (the stale Dockerfile ARG default wins silently).
#
# Provides:
#   _VERSION_BUILD_ARG_VARS        — discovered variable names
#   append_version_build_args()    — append --build-arg VAR=$VAR for all tracked versions
[ -n "${_VERSION_FORWARDING_SH_LOADED:-}" ] && return 0
_VERSION_FORWARDING_SH_LOADED=1

_VF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Normally sourced by artifact-common.sh first; this is a standalone safety guard.
# shellcheck disable=SC1090,SC1091
if [ -z "${_BUILD_HELPERS_LOADED:-}" ] && [ -f "${_VF_DIR}/build-helpers.sh" ]; then
  source "${_VF_DIR}/build-helpers.sh"
fi

if [ -z "${_VERSION_BUILD_ARG_VARS_CACHED:-}" ]; then
  _VERSION_BUILD_ARG_VARS=()
  if [ -f "${_VF_DIR}/versions.env" ]; then
    while IFS= read -r varname; do
      [ -n "${varname}" ] && _VERSION_BUILD_ARG_VARS+=("${varname}")
    done < <(awk -F= '
      /^# noforward/            { skip = 1; next }
      /^[A-Z][A-Z0-9_]*=/       { if (!skip) print $1; skip = 0; next }
                                { skip = 0 }
    ' "${_VF_DIR}/versions.env")
    if [ "${#_VERSION_BUILD_ARG_VARS[@]}" -eq 0 ]; then
      printf 'WARNING: No version variables discovered in %s\n' "${_VF_DIR}/versions.env" >&2
    fi
  fi
  _VERSION_BUILD_ARG_VARS_CACHED=1
fi

# $2 = target arch. A version differs per arch when upstream ships no artifact
# for it, and the image must ADVERTISE what it actually contains: <KEY>_<ARCH>
# in versions.env is that arch's truth and wins for it.
# docs/cross-build-verification.md#per-arch-version-truth
# A forwarded key that merely ENDS in _<ARCH> (GENAI_ALLOW_RISCV64) is a key in
# its own right, never another key's override.
_vf_is_tracked() {
  local _vfit
  for _vfit in "${_VERSION_BUILD_ARG_VARS[@]}"; do
    [ "${_vfit}" = "$1" ] && return 0
  done
  return 1
}

append_version_build_args() {
  local _avba_name="$1" _avba_arch="${2:-}"
  local var_name value override
  for var_name in "${_VERSION_BUILD_ARG_VARS[@]}"; do
    value="${!var_name:-}"
    if [ -n "${_avba_arch}" ]; then
      override="${var_name}_$(printf '%s' "${_avba_arch}" | tr '[:lower:]' '[:upper:]')"
      if [ -n "${!override:-}" ] && ! _vf_is_tracked "${override}"; then value="${!override}"; fi
    fi
    if [ -n "${value}" ]; then
      append_optional_build_arg "${_avba_name}" "${var_name}" "${value}"
    fi
  done
}
