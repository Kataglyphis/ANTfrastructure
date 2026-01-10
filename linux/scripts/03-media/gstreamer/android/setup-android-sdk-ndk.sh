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
  echo "Skipping Android SDK/NDK installation on non-x86_64 architecture"
  exit 0
fi

: "${ANDROID_HOME:?ANDROID_HOME must be set}"
: "${ANDROID_SDK_VERSION:?ANDROID_SDK_VERSION must be set}"
: "${ANDROID_NDK_VERSION:?ANDROID_NDK_VERSION must be set}"
: "${ANDROID_COMPILE_SDK:?ANDROID_COMPILE_SDK must be set}"
: "${ANDROID_BUILD_TOOLS:?ANDROID_BUILD_TOOLS must be set}"
: "${ANDROID_CMAKE_VERSION:?ANDROID_CMAKE_VERSION must be set}"
: "${GSTREAMER_VERSION:?GSTREAMER_VERSION must be set}"

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# 32-bit libs required by parts of the Android toolchain.
dpkg --add-architecture i386
apt-get update
apt-get install -y --no-install-recommends \
  libc6:i386 libncurses6:i386 libstdc++6:i386 \
  lib32z1 libbz2-1.0:i386

apt-get install -y --no-install-recommends \
  openjdk-21-jdk \
  unzip \
  xz-utils

mkdir -p "${ANDROID_HOME}/cmdline-tools"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cd "${tmpdir}"
zip_name="commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip"
wget -q "https://dl.google.com/android/repository/${zip_name}"
unzip -q "${zip_name}"

# Ensure a clean install of 'latest' cmdline-tools.
rm -rf "${ANDROID_HOME}/cmdline-tools/latest"
mkdir -p "${ANDROID_HOME}/cmdline-tools"

# The zip contains a top-level 'cmdline-tools' directory.
mv cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest"

sdkmanager_bin="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"

# Accept licenses non-interactively; ignore failures to keep builds resilient.
yes | "${sdkmanager_bin}" --licenses || true

"${sdkmanager_bin}" \
  "cmake;${ANDROID_CMAKE_VERSION}" \
  "platform-tools" \
  "platforms;android-${ANDROID_COMPILE_SDK}" \
  "build-tools;${ANDROID_BUILD_TOOLS}" \
  "ndk;${ANDROID_NDK_VERSION}" \
  "extras;android;m2repository" \
  "extras;google;m2repository"

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

# Convenience symlink used by some Android workflows.
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
  ln -sf "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64" "${ANDROID_NDK_HOME}/toolchain" || true
fi

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
