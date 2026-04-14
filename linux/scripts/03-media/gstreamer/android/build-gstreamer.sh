#!/usr/bin/env bash
set -euo pipefail

is_x86_64() {
  local arch
  arch="${TARGETARCH:-}"
  case "${arch}" in
    amd64|x86_64) return 0 ;;
  esac

  arch="$(uname -m || true)"
  case "${arch}" in
    x86_64|amd64) return 0 ;;
  esac

  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "${arch}" in
    amd64) return 0 ;;
  esac

  return 1
}

if ! is_x86_64; then
  echo "Skipping GStreamer Android installation on non-x86_64 architecture"
  exit 0
fi

: "${GSTREAMER_VERSION:?GSTREAMER_VERSION must be set}"

# If the repository contains a build script to cross-compile GStreamer for Android, run it and enable ONNX plugin.
if [ -x /opt/scripts/media/gstreamer/android/build-android-from-source.sh ]; then
  echo "Found script build-android-from-source.sh -> building GStreamer for Android from source (with ONNX inference plugin)"
  /opt/scripts/media/gstreamer/android/build-android-from-source.sh \
    --gst-version="${GSTREAMER_VERSION}" \
    --android-sdk="${ANDROID_HOME}" \
    --android-ndk="${ANDROID_NDK_HOME:-${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}}" \
    --prefix="/opt/android/gstreamer" \
    --with-onnx-inference
else
  echo "No build script found; falling back to downloading prebuilt GStreamer Android universal"
  mkdir -p /opt/android/gstreamer
  wget -q "https://gstreamer.freedesktop.org/data/pkg/android/${GSTREAMER_VERSION}/gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz"
  tar -xf "gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz" -C /opt/android/gstreamer
  rm "gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz"
fi
