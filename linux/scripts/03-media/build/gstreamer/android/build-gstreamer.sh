#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

# The prebuilt-tarball fallback needs download_and_extract from 01-core/downloads.sh.
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
    download_verified_file "${_gst_univ_url}" "${GSTREAMER_ANDROID_UNIVERSAL_SHA256}" "${_gst_univ_tmp}"
    mkdir -p "${GSTREAMER_ROOT_ANDROID}"
    tar -xJf "${_gst_univ_tmp}" -C "${GSTREAMER_ROOT_ANDROID}"
    rm -f "${_gst_univ_tmp}"
  else
    echo "WARNING: GSTREAMER_ANDROID_UNIVERSAL_SHA256 unset — fetching prebuilt GStreamer UNVERIFIED" >&2
    download_and_extract "${_gst_univ_url}" "${GSTREAMER_ROOT_ANDROID}"
  fi
fi
