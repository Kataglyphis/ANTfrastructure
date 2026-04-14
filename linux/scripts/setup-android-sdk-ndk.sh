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

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Ensure both SDK env vars are set for tools that honor one or the other
export ANDROID_SDK_ROOT="${ANDROID_HOME}"

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

# Helper: try to accept all licenses in a loop until sdkmanager reports success
accept_licenses() {
  local attempt=0 max_attempts=6 sleep_sec=3 out
  mkdir -p "${ANDROID_HOME}/licenses"
  while :; do
    attempt=$((attempt + 1))
    echo "Attempt ${attempt}/${max_attempts}: accepting Android SDK licenses"
    # Feed many 'y' responses in case multiple licenses are prompted. Capture output for debugging.
    out="$(printf 'y\n%.0s' {1..200} | "${sdkmanager_bin}" --sdk_root="${ANDROID_HOME}" --licenses 2>&1 || true)"
    echo "$out"
    if echo "$out" | grep -q "All SDK package licenses accepted"; then
      echo "Licenses accepted"
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "Failed to accept all licenses after ${attempt} attempts" >&2
      return 1
    fi
    echo "License acceptance not complete; retrying in ${sleep_sec}s..."
    sleep "$sleep_sec"
  done
}

# Helper: run sdkmanager install with retries to handle transient network failures
sdkmanager_install() {
  local attempt=0 max_attempts=4 sleep_sec=5 args=("$@") out
  while :; do
    attempt=$((attempt + 1))
    echo "sdkmanager install attempt ${attempt}/${max_attempts}: ${args[*]}"
    out="$("${sdkmanager_bin}" --sdk_root="${ANDROID_HOME}" "${args[@]}" 2>&1 || true)"
    echo "$out"
    if echo "$out" | grep -q "Done\." || [ $? -eq 0 ]; then
      # If sdkmanager exits 0 or prints Done., consider it successful
      echo "sdkmanager install succeeded"
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "sdkmanager install failed after ${attempt} attempts" >&2
      return 1
    fi
    echo "sdkmanager install failed; retrying in ${sleep_sec}s..."
    sleep "$sleep_sec"
  done
}

# First try to accept any existing/required licenses before installing packages
accept_licenses || echo "Continuing despite license-accept failure; install will retry acceptance afterwards"

"${sdkmanager_bin}" \
  "cmake;${ANDROID_CMAKE_VERSION}" \
  "platform-tools" \
  "platforms;android-${ANDROID_COMPILE_SDK}" \
  "build-tools;${ANDROID_BUILD_TOOLS}" \
  "ndk;${ANDROID_NDK_VERSION}" \
  "extras;android;m2repository" \
  "extras;google;m2repository" || {
  # If the one-shot install failed, try via our retry wrapper for transient errors
  sdkmanager_install "cmake;${ANDROID_CMAKE_VERSION}" \
    "platform-tools" \
    "platforms;android-${ANDROID_COMPILE_SDK}" \
    "build-tools;${ANDROID_BUILD_TOOLS}" \
    "ndk;${ANDROID_NDK_VERSION}" \
    "extras;android;m2repository" \
    "extras;google;m2repository"
}

# Ensure licenses are accepted after installation too (some packages add new licenses)
accept_licenses || echo "Warning: license acceptance did not complete; builds may fail later"

# Convenience symlink used by some Android workflows.
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
  ln -sf "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64" "${ANDROID_NDK_HOME}/toolchain" || true
fi

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
