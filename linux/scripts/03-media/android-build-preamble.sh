#!/usr/bin/env bash
# Usage: source, then android_build_preamble_init <label> [api_level_default]
set -euo pipefail

android_build_preamble_init() {
  local label="${1:-Android library build}"
  local api_default="${2:-34}"

  if [ -f /opt/scripts/core/platform.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/platform.sh
  fi

  if ! android_require_amd64_build_host "${label}"; then
    exit 0
  fi

  TARGET_ARCH="$(android_target_arch)"
  ANDROID_ABI="$(android_target_abi)"
  : "${ANDROID_ABI:?Unsupported Android target ABI}"

  ANDROID_API_LEVEL="$(android_raise_api_level_if_needed "${TARGET_ARCH}" "${api_default}" "${label}")"

  # Wired here so every android stage gets sccache while the Dockerfile RUN blocks stay identical.
  if [ -f /opt/scripts/core/compiler-cache.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/compiler-cache.sh
    setup_ccache 2>/dev/null || true
    setup_lld_linker 2>/dev/null || true
  fi

  export DEBIAN_FRONTEND=noninteractive
}

# Host compiler resolution: the canonical helper when shipped, else an inline copy.

if [ -f /opt/scripts/core/compiler-resolution.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/compiler-resolution.sh
  resolve_host_compiler() { resolve_host_compiler_for_lang "$1"; }
else
  # Explicit /usr/bin first: PATH leads with /opt/gcc-<ver>/bin, whose gcc is the cross compiler.
  resolve_host_compiler() {
    local candidate
    case "$1" in
      c)
        for candidate in /usr/bin/gcc /usr/bin/cc /usr/bin/clang; do
          [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
        done
        command -v gcc 2>/dev/null || command -v cc 2>/dev/null || command -v clang 2>/dev/null || true ;;
      cxx)
        for candidate in /usr/bin/g++ /usr/bin/c++ /usr/bin/clang++; do
          [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
        done
        command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || command -v clang++ 2>/dev/null || true ;;
    esac
  }
fi

# media_jobs [cap_mb], as in core/common.sh; Android scripts skip media_common_init, so source on demand.

media_jobs() {
  local jobs
  jobs="$(nproc)"
  if [ -f /opt/scripts/core/parallelism.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/parallelism.sh 2>/dev/null || true
    if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
      jobs="$(compute_jobs_with_mem_cap "" "${1:-2000}")"
    fi
  fi
  printf '%s\n' "${jobs}"
}

# Usage: <url> <ref> <dir>; leaves the shell inside the fresh clone.
android_clone_shallow() {
  local url="$1" ref="$2" dir="$3"
  cd /opt
  rm -rf "${dir}"
  git clone --depth 1 -b "${ref}" "${url}" "${dir}"
  cd "${dir}"
}

# Usage: <patch-rel-path> <target-dir> <desc>; outside a container the repo root comes from the caller's path.
android_apply_patch() {
  local patch_rel="$1" target_dir="$2" desc="$3"
  local _apply_patch _patches_root

  if [ -f /opt/scripts/core/apply-patch.sh ]; then
    _apply_patch=/opt/scripts/core/apply-patch.sh
    _patches_root=/opt/scripts/patches
  else
    local _scripts_dir
    _scripts_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")/../../../.." && pwd)"
    _apply_patch="${_scripts_dir}/01-core/apply-patch.sh"
    _patches_root="${_scripts_dir}/patches"
  fi

  bash "${_apply_patch}" "${_patches_root}/${patch_rel}" "${target_dir}" "${desc}"
}
