#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

# download_and_extract (retry-capable, temp-file hygiene) lives in
# 01-core/downloads.sh; load it directly for the prebuilt-tarball fallback.
if ! command -v download_and_extract >/dev/null 2>&1; then
  for _gst_dl in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../01-core/downloads.sh" \
    "/opt/scripts/core/downloads.sh"; do
    if [ -f "${_gst_dl}" ]; then
      # shellcheck disable=SC1090
      source "${_gst_dl}"
      break
    fi
  done
  unset _gst_dl
fi

if ! android_require_amd64_build_host "GStreamer Android installation"; then
  exit 0
fi

: "${GSTREAMER_VERSION:?GSTREAMER_VERSION must be set}"
: "${GSTREAMER_ROOT_ANDROID:=/opt/android/gstreamer}"

# If the repository contains a build script to cross-compile GStreamer for Android, run it.
if [ -x /opt/scripts/03-media/gstreamer/android/build-android-from-source.sh ]; then
  echo "Found script build-android-from-source.sh -> building GStreamer for Android from source"
  /opt/scripts/03-media/gstreamer/android/build-android-from-source.sh \
    --prefix="${GSTREAMER_ROOT_ANDROID}"
else
  echo "No build script found; falling back to downloading prebuilt GStreamer Android universal"
  download_and_extract \
    "https://gstreamer.freedesktop.org/data/pkg/android/${GSTREAMER_VERSION}/gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz" \
    "${GSTREAMER_ROOT_ANDROID}"
fi
