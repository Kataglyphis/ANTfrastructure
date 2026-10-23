#!/usr/bin/env bash
# Sources cross-env.sh; the fallbacks below are what runs where Dockerfile.media ships this file without it.

[ -n "${_INSTALL_DEPS_PREAMBLE_LOADED:-}" ] && return 0
_INSTALL_DEPS_PREAMBLE_LOADED=1

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
else
  # Repo layout: cross-env.sh sits next to this file, and one that fails to load is fatal.
  _preamble_repo_cross_env="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cross-env.sh"
  if [ -f "${_preamble_repo_cross_env}" ]; then
    # shellcheck disable=SC1090
    source "${_preamble_repo_cross_env}" || { echo "FATAL: cannot load ${_preamble_repo_cross_env}" >&2; exit 1; }
  fi
  unset _preamble_repo_cross_env
fi

# Fallback: define install_deps_preamble if the SDK image's cross-apt.sh doesn't have it yet
if ! command -v install_deps_preamble >/dev/null 2>&1; then
  install_deps_preamble() {
    rm -rf /var/lib/apt/lists/*
    if command -v apt_update_smart >/dev/null 2>&1; then
      apt_update_smart
    else
      apt-get update -y
    fi
    if [ "$#" -gt 0 ]; then
      if command -v install_host_packages >/dev/null 2>&1; then
        install_host_packages "$@"
      else
        apt-get install -y --no-install-recommends "$@"
      fi
    fi
  }
fi

# Native-build fallbacks for the cross helpers install-deps scripts always call.
if ! command -v is_cross >/dev/null 2>&1; then
  is_cross() { false; }
fi
if ! command -v cross_build_enabled >/dev/null 2>&1; then
  cross_build_enabled() { false; }
fi
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  cross_build_is_active() { false; }
fi
if ! command -v install_host_packages >/dev/null 2>&1; then
  install_host_packages() {
    [ "$#" -gt 0 ] || return 0
    apt-get install -y --no-install-recommends "$@"
  }
fi
if ! command -v install_target_packages >/dev/null 2>&1; then
  install_target_packages() {
    install_host_packages "$@"
  }
fi
if ! command -v install_optional_target_packages >/dev/null 2>&1; then
  install_optional_target_packages() {
    install_target_packages "$@" || true
  }
fi
if ! command -v cross_package_has_install_candidate >/dev/null 2>&1; then
  cross_package_has_install_candidate() {
    local c
    c="$(apt-cache policy "$1" 2>/dev/null | awk '/^[[:space:]]*Candidate:/ { print $2; exit }')"
    [ -n "${c}" ] && [ "${c}" != "(none)" ]
  }
fi
if ! command -v cross_resolve_target_package >/dev/null 2>&1; then
  cross_resolve_target_package() { printf '%s' "$1"; }
fi
if ! command -v host_python_major_minor >/dev/null 2>&1; then
  # Without a working python3 the pin answers: the image's PYTHON_VERSION, else versions.env beside this file.
  host_python_major_minor() {
    python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null && return 0
    local pin="${PYTHON_VERSION:-}"
    [ -n "${pin}" ] || pin="$(sed -n 's/^PYTHON_VERSION=//p' "$(dirname "${BASH_SOURCE[0]}")/versions.env" 2>/dev/null | head -n 1)"
    [[ "${pin}" =~ ^[0-9]+\.[0-9]+ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[0]}"
  }
fi

report_cross_python_development() {
  local ready_prefix="$1" missing_prefix="$2" missing_action="$3" version
  if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
    echo "${ready_prefix}Using staged target Python headers from $(cross_target_python_include_dir)"
  else
    if [ "$#" -ge 4 ]; then
      version="$4"
    else
      version="${PYTHON_MAJOR_MINOR:-$(host_python_major_minor 2>/dev/null || echo unknown)}"
    fi
    echo "${missing_prefix}Target Python ${version} development files are missing for $(cross_target_triplet 2>/dev/null || echo target); ${missing_action} for this cross build"
  fi
}
