#!/usr/bin/env bash
# android-build-preamble.sh
# Shared preamble for Android library build scripts (onnxruntime, litert, opencv, gstreamer).
# Usage: source this file, then call android_build_preamble_init <label> [api_level_default]
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

  # LOG13: wire the compiler cache launcher so android-iree (and any other
  # project that respects CMAKE_*_COMPILER_LAUNCHER / RUSTC_WRAPPER) gets
  # sccache instead of falling back to inherited ccache or nothing. The five
  # RUN blocks stay byte-identical — only the preamble changes.
  if [ -f /opt/scripts/core/compiler-cache.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/compiler-cache.sh
    setup_ccache 2>/dev/null || true
    setup_lld_linker 2>/dev/null || true
  fi

  export DEBIAN_FRONTEND=noninteractive
}

# Parallel job-count helper for the Android build scripts.
# Mirrors media_jobs() in 03-media/core/common.sh, but the Android scripts do
# NOT call media_common_init, so parallelism.sh is not pre-loaded — source it
# on demand (container path) before using compute_jobs_with_mem_cap, and fall
# back to plain nproc when it is unavailable. Keeps the exact 2000-MB per-job
# memory-cap behavior of the blocks it replaces.
media_jobs() {
  local jobs
  jobs="$(nproc)"
  if [ -f /opt/scripts/core/parallelism.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/parallelism.sh 2>/dev/null || true
    if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
      jobs="$(compute_jobs_with_mem_cap "" 2000)"
    fi
  fi
  printf '%s\n' "${jobs}"
}

# Shallow-clone helper for the Android build scripts.
# Replaces the repeated `cd /opt; rm -rf <dir>; git clone --depth 1 -b <ref>
# <url> <dir>; cd <dir>` idiom. Leaves the shell inside the freshly cloned dir.
android_clone_shallow() {
  local url="$1" ref="$2" dir="$3"
  cd /opt
  rm -rf "${dir}"
  git clone --depth 1 -b "${ref}" "${url}" "${dir}"
  cd "${dir}"
}

# Patch-application helper for the Android build scripts.
# Replaces the repeated container-vs-repo apply-patch.sh + patches/ resolver.
# Container layout (apply-patch.sh + patches/ COPY'd into the android stages)
# is tried first; otherwise the repo layout is derived from the CALLER's path
# (BASH_SOURCE[1], the build-android.sh under 03-media/build/<lib>/android/).
# Args: <patch-relative-path> <target-dir> <description>.
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
