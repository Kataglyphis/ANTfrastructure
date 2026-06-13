#!/usr/bin/env bash
# media-build-preamble.sh
# Shared preamble for media library build scripts.
# Sources core modules through the dual-path fallback (container vs repo layout).
# Usage: source this file at the top of a media build script.

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
}
