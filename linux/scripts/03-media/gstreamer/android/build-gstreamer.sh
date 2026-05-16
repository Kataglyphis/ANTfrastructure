#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

if ! android_require_amd64_build_host "GStreamer Android installation"; then
  exit 0
fi

: "${GSTREAMER_VERSION:?GSTREAMER_VERSION must be set}"
: "${GSTREAMER_ROOT_ANDROID:=/opt/android/gstreamer}"

# If the repository contains a build script to cross-compile GStreamer for Android, run it.
if [ -x /opt/scripts/media/gstreamer/android/build-android-from-source.sh ]; then
  echo "Found script build-android-from-source.sh -> building GStreamer for Android from source"
  /opt/scripts/media/gstreamer/android/build-android-from-source.sh \
    --prefix="${GSTREAMER_ROOT_ANDROID}"
else
  echo "No build script found; falling back to downloading prebuilt GStreamer Android universal"
  mkdir -p "${GSTREAMER_ROOT_ANDROID}"
  wget -q "https://gstreamer.freedesktop.org/data/pkg/android/${GSTREAMER_VERSION}/gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz"
  tar -xf "gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz" -C "${GSTREAMER_ROOT_ANDROID}"
  rm "gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz"
fi
