#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi

build_arch() {
  if command -v build_arch_oci >/dev/null 2>&1; then
    build_arch_oci
    return 0
  fi

  if [ -n "${BUILDARCH:-}" ]; then
    printf '%s' "${BUILDARCH}"
    return 0
  fi

  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture 2>/dev/null && return 0
  fi

  uname -m || true
}

target_android_arch() {
  if command -v arch_oci >/dev/null 2>&1; then
    arch_oci
    return 0
  fi
  printf '%s' "${TARGET_ARCH:-${TARGETARCH:-arm64}}"
}

if [ "$(build_arch)" != "amd64" ]; then
  echo "Skipping GStreamer Android installation on non-amd64 build host"
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
    --target-arch="$(target_android_arch)" \
    --with-onnx-inference
else
  echo "No build script found; falling back to downloading prebuilt GStreamer Android universal"
  mkdir -p /opt/android/gstreamer
  wget -q "https://gstreamer.freedesktop.org/data/pkg/android/${GSTREAMER_VERSION}/gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz"
  tar -xf "gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz" -C /opt/android/gstreamer
  rm "gstreamer-1.0-android-universal-${GSTREAMER_VERSION}.tar.xz"
fi
