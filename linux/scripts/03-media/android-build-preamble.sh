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

  export DEBIAN_FRONTEND=noninteractive
}
