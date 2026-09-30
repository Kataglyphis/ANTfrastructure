#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi
# cross-apt.sh only defines functions, so it loads without cross-env.sh.
if [ -f /opt/scripts/core/cross-apt.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-apt.sh
fi
# cross_ensure_installed_foreign_arch_sources needs ubuntu-mirror.sh's helpers.
if [ -f /opt/scripts/core/ubuntu-mirror.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/ubuntu-mirror.sh
fi

# This installer runs without the module chain, so load downloads.sh directly.
if ! command -v download_file >/dev/null 2>&1; then
  for _asdk_dl in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/downloads.sh" \
    "/opt/scripts/core/downloads.sh"; do
    if [ -f "${_asdk_dl}" ]; then
      # shellcheck disable=SC1090
      source "${_asdk_dl}"
      break
    fi
  done
  unset _asdk_dl
fi

ensure_host_apt_architectures() {
  apt_sources_set_architectures "/etc/apt/sources.list.d/ubuntu.sources" "amd64 i386"
}

# Record why the payload is absent, so smoke-android.sh reads the decision instead of re-deriving it.
if ! android_require_amd64_build_host "Android SDK/NDK installation"; then
  mkdir -p /opt/android
  {
    printf 'reason=Android NDK ships as prebuilt/linux-x86_64 only\n'
    printf 'build_host=%s\n' "$(build_arch_oci)"
    printf 'skipped=sdk,ndk,gstreamer,onnxruntime,litert,opencv,iree,smoke\n'
  } > /opt/android/.android-payload-off
  exit 0
fi

: "${ANDROID_HOME:?ANDROID_HOME must be set}"
: "${ANDROID_SDK_VERSION:?ANDROID_SDK_VERSION must be set}"
: "${ANDROID_NDK_VERSION:?ANDROID_NDK_VERSION must be set}"
: "${ANDROID_COMPILE_SDK:?ANDROID_COMPILE_SDK must be set}"
: "${ANDROID_BUILD_TOOLS:?ANDROID_BUILD_TOOLS must be set}"
: "${ANDROID_EXTRA_COMPILE_SDK:?ANDROID_EXTRA_COMPILE_SDK must be set}"
: "${ANDROID_EXTRA_BUILD_TOOLS:?ANDROID_EXTRA_BUILD_TOOLS must be set}"
: "${ANDROID_CMAKE_VERSION:?ANDROID_CMAKE_VERSION must be set}"

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

# Ensure both SDK env vars are set for tools that honor one or the other
export ANDROID_SDK_ROOT="${ANDROID_HOME}"

# 32-bit libs required by parts of the Android toolchain.
if ! dpkg --print-foreign-architectures | grep -qx i386; then
  dpkg --add-architecture i386
fi
ensure_host_apt_architectures
# Every foreign arch needs its own source. docs/failure-modes.md#apt-libc6i386-install-is-unsatisfiable-after-an-archiveports-drift
cross_ensure_installed_foreign_arch_sources
apt-get update
apt-get install -y --no-install-recommends \
  libc6:i386 libncurses6:i386 libstdc++6:i386 \
  lib32z1 libbz2-1.0:i386

apt-get install -y --no-install-recommends \
  openjdk-21-jdk \
  unzip \
  xz-utils

# Cross-arch cache keyed by the pins, not TARGETARCH: this only runs on amd64, so every arch installs the same tree.
ANDROID_SDK_CACHE_DIR="${ANDROID_SDK_CACHE_DIR:-}"

# Dockerfile.android's cache id must name every pin in this list (tests/test-android-sdk-cache-key.sh).
sdk_components=(
  "cmake;${ANDROID_CMAKE_VERSION}"
  "platform-tools"
  "platforms;android-${ANDROID_COMPILE_SDK}"
  "build-tools;${ANDROID_BUILD_TOOLS}"
  # The extra API level lets consumers raise compileSdk without losing the one everything builds against.
  "platforms;android-${ANDROID_EXTRA_COMPILE_SDK}"
  "build-tools;${ANDROID_EXTRA_BUILD_TOOLS}"
  "ndk;${ANDROID_NDK_VERSION}"
  "extras;android;m2repository"
  "extras;google;m2repository"
)

# Components ANDROID_HOME lacks per package.xml, so a stale restored cache tree is caught.
sdk_missing_components() {
  local installed pkg
  installed="$(find "${ANDROID_HOME}" -maxdepth 4 -name package.xml -exec \
    sed -n 's/.*localPackage path="\([^"]*\)".*/\1/p' {} + 2>/dev/null || true)"
  for pkg in "${sdk_components[@]}"; do
    grep -qxF "${pkg}" <<<"${installed}" || printf '%s\n' "${pkg}"
  done
}

sdk_cache_tree=""
if [ -n "${ANDROID_SDK_CACHE_DIR}" ] && [ -d "${ANDROID_SDK_CACHE_DIR}" ]; then
  sdk_cache_tree="${ANDROID_SDK_CACHE_DIR}/sdk-tree"
fi

sdk_restored=0
sdk_cache_stale=0
if [ -n "${sdk_cache_tree}" ] && [ -d "${sdk_cache_tree}" ]; then
  echo "android-sdk shared cache HIT: restoring ${ANDROID_HOME} from ${sdk_cache_tree} (skipping SDK/NDK downloads)"
  mkdir -p "${ANDROID_HOME}"
  cp -a "${sdk_cache_tree}/." "${ANDROID_HOME}/"
  sdk_restored=1
  sdk_stale_components="$(sdk_missing_components)"
  if [ -n "${sdk_stale_components}" ]; then
    echo "android-sdk shared cache STALE: the restored tree lacks $(tr '\n' ' ' <<<"${sdk_stale_components}")- installing, then refreshing the cache"
    sdk_restored=0
    sdk_cache_stale=1
  fi
elif [ -n "${sdk_cache_tree}" ]; then
  echo "android-sdk shared cache MISS: downloading SDK/NDK, then populating ${sdk_cache_tree} for the other arches"
fi

if [ "${sdk_restored}" -eq 0 ]; then
  mkdir -p "${ANDROID_HOME}/cmdline-tools"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  cd "${tmpdir}"
  zip_name="commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip"
  # Verified fetch: sdkmanager bootstraps the NDK; its pin is noforward, so read it from versions.env.
  if [ -z "${ANDROID_CMDLINE_TOOLS_SHA256:-}" ] && [ -f /opt/scripts/core/versions.env ]; then
    ANDROID_CMDLINE_TOOLS_SHA256="$(sed -n 's/^ANDROID_CMDLINE_TOOLS_SHA256=//p' /opt/scripts/core/versions.env)"
  fi
  # The zip is cached by file name and re-verified, so it survives bumps of the other pins.
  cached_zip=""
  if [ -n "${ANDROID_SDK_CACHE_DIR}" ] && [ -d "${ANDROID_SDK_CACHE_DIR}" ]; then
    cached_zip="${ANDROID_SDK_CACHE_DIR}/dl/${zip_name}"
  fi
  if [ -n "${cached_zip}" ] && [ -f "${cached_zip}" ]; then
    cp "${cached_zip}" "${zip_name}"
    if [ -n "${ANDROID_CMDLINE_TOOLS_SHA256:-}" ] && \
       ! printf '%s  %s\n' "${ANDROID_CMDLINE_TOOLS_SHA256}" "${zip_name}" | sha256sum -c - >/dev/null 2>&1; then
      echo "Cached cmdline-tools zip failed checksum verification; discarding it and re-downloading" >&2
      rm -f "${zip_name}" "${cached_zip}"
    else
      echo "cmdline-tools zip: android-sdk shared cache hit (${zip_name})"
    fi
  fi
  if [ ! -f "${zip_name}" ]; then
    if [ -n "${ANDROID_CMDLINE_TOOLS_SHA256:-}" ]; then
      download_verified_file "https://dl.google.com/android/repository/${zip_name}" "${ANDROID_CMDLINE_TOOLS_SHA256}" "${zip_name}"
    else
      echo "WARNING: ANDROID_CMDLINE_TOOLS_SHA256 unset — fetching sdkmanager UNVERIFIED (pin it in versions.env alongside ANDROID_SDK_VERSION)" >&2
      download_file "https://dl.google.com/android/repository/${zip_name}" "${zip_name}"
    fi
    if [ -n "${cached_zip}" ]; then
      # Copy to a temp name, then mv, so no reader ever sees a partial zip.
      mkdir -p "${ANDROID_SDK_CACHE_DIR}/dl"
      cp "${zip_name}" "${cached_zip}.partial.$$"
      mv -f "${cached_zip}.partial.$$" "${cached_zip}"
    fi
  fi
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
    local status=0
    while :; do
      attempt=$((attempt + 1))
      echo "sdkmanager install attempt ${attempt}/${max_attempts}: ${args[*]}"
      status=0
      if out="$("${sdkmanager_bin}" --sdk_root="${ANDROID_HOME}" "${args[@]}" 2>&1)"; then
        status=0
      else
        status=$?
      fi
      echo "$out"
      # Trust the exit code only: sdkmanager prints "Done." per package even when others fail.
      if [ "${status}" -eq 0 ]; then
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

  # Fatal: an unaccepted license surfaces later as an opaque sdkmanager or gradle failure.
  accept_licenses

  sdkmanager_install "${sdk_components[@]}"

  # Again after the install: some packages bring new licenses.
  accept_licenses
fi

# Downstream builds derive this exact NDK path, so it must exist.
ndk_dir="${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}"
if [ ! -d "${ndk_dir}" ]; then
  echo "ERROR: expected NDK directory '${ndk_dir}' missing after sdkmanager install" >&2
  exit 1
fi
sdk_absent_components="$(sdk_missing_components)"
if [ -n "${sdk_absent_components}" ]; then
  echo "ERROR: ${ANDROID_HOME} lacks $(tr '\n' ' ' <<<"${sdk_absent_components}")after the install" >&2
  exit 1
fi

# Convenience symlink used by some Android workflows.
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
  ln -sf "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64" "${ANDROID_NDK_HOME}/toolchain" || true
fi

# Publish the validated tree via a staged atomic mv; failure is non-fatal, since this arch is already installed.
if [ "${sdk_restored}" -eq 0 ] && [ -n "${sdk_cache_tree}" ] && \
   { [ ! -d "${sdk_cache_tree}" ] || [ "${sdk_cache_stale}" -eq 1 ]; }; then
  rm -rf "${ANDROID_SDK_CACHE_DIR}"/sdk-tree.staging.*
  sdk_cache_staging="$(mktemp -d "${ANDROID_SDK_CACHE_DIR}/sdk-tree.staging.XXXXXX")"
  if cp -a "${ANDROID_HOME}/." "${sdk_cache_staging}/" && rm -rf "${sdk_cache_tree}" && \
     mv "${sdk_cache_staging}" "${sdk_cache_tree}"; then
    echo "android-sdk shared cache populated: ${sdk_cache_tree}"
  else
    rm -rf "${sdk_cache_staging}"
    echo "WARNING: failed to populate android-sdk shared cache (non-fatal; other arches will re-download)" >&2
  fi
fi

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
