#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

# One helper owns the repo and image lookup while preserving a caller's downloader.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"
if [ -f "${SCRIPTS_ROOT}/01-core/modules.sh" ]; then
  # shellcheck source=../../../../01-core/modules.sh
  source "${SCRIPTS_ROOT}/01-core/modules.sh"
else
  source "${SCRIPTS_ROOT}/core/modules.sh"
fi
source_module download-loader.sh
download_module_load

if ! android_require_amd64_build_host "GStreamer Android installation"; then
  exit 0
fi

: "${GSTREAMER_VERSION:?GSTREAMER_VERSION must be set}"
: "${GSTREAMER_ROOT_ANDROID:=/opt/android/gstreamer}"

if [ -x /opt/scripts/03-media/gstreamer/android/build-android-from-source.sh ]; then
  echo "Found script build-android-from-source.sh -> building GStreamer for Android from source"
  /opt/scripts/03-media/gstreamer/android/build-android-from-source.sh \
    --prefix="${GSTREAMER_ROOT_ANDROID}"
else
  echo "No build script found; falling back to downloading prebuilt GStreamer Android universal"
  _gst_univ_url="https://gstreamer.freedesktop.org/data/pkg/android/${GSTREAMER_VERSION}/gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz"
  # These prebuilt .so's ship in the Android artifacts, so verify whenever a pin exists; it bumps with GSTREAMER_VERSION.
  if [ -n "${GSTREAMER_ANDROID_UNIVERSAL_SHA256:-}" ]; then
    _gst_univ_tmp="$(mktemp /tmp/gst-android-universal-XXXXXX.tar.xz)"
    download_verified_extract_xz "${_gst_univ_url}" "${GSTREAMER_ANDROID_UNIVERSAL_SHA256}" \
      "${_gst_univ_tmp}" "${GSTREAMER_ROOT_ANDROID}"
  else
    echo "WARNING: GSTREAMER_ANDROID_UNIVERSAL_SHA256 unset — fetching prebuilt GStreamer UNVERIFIED" >&2
    download_and_extract "${_gst_univ_url}" "${GSTREAMER_ROOT_ANDROID}"
  fi
fi
