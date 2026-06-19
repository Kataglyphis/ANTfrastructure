#!/usr/bin/env bash
# media-build-preamble.sh
# Shared preamble for all media library build scripts.
# Sources core modules through the dual-path fallback (container vs repo layout).
#
# Provides:
#   media_build_preamble_init <script_dir>
#
# Usage: source this file at the top of a media build script, then call:
#   media_build_preamble_init "${SCRIPT_DIR}"

media_build_preamble_init() {
  local script_dir="${1:-$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)}"

  for helper in \
    "/opt/scripts/core/modules.sh" \
    "${script_dir}/../../01-core/modules.sh"; do
    if [ -f "${helper}" ]; then
      # shellcheck disable=SC1090
      source "${helper}"
      source_modules_framework "${script_dir}"
      break
    fi
  done

  source_module common.sh || true
  source_module cross-env.sh || true
  source_module logging.sh || true
  source_module parallelism.sh || true
  source_module downloads.sh || true
  source_module compiler-cache.sh && { setup_ccache; setup_lld_linker; } || true
  source_module compiler-resolution.sh || true
  source_module python-host.sh || true
  source_module cmake-cache-linker.sh || true

  # Fallback for cross_build_is_active in case cross-env.sh guard prevents reload.
  # Prefer cross_build_enabled (checks both BUILD_MODE and cross-target != build-arch),
  # falling back to BUILD_MODE check if cross_build_enabled isn't available.
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    if command -v cross_build_enabled >/dev/null 2>&1; then
      cross_build_is_active() { cross_build_enabled; }
    else
      cross_build_is_active() { [ "${BUILD_MODE:-native}" = "cross" ]; }
    fi
  fi
}
