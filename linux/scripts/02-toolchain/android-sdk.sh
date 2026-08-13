#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/platform.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/platform.sh
fi
# apt_sources_set_architectures lives in cross-apt.sh (self-contained; sourcing
# it only defines functions, no cross-env.sh dependency needed here).
if [ -f /opt/scripts/core/cross-apt.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-apt.sh
fi

# download_file (retry-capable) lives in 01-core/downloads.sh; load it directly
# since this installer runs without the full module chain.
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

if ! android_require_amd64_build_host "Android SDK/NDK installation"; then
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
if ! dpkg --print-foreign-architectures | grep -qx i386; then
  dpkg --add-architecture i386
fi
ensure_host_apt_architectures
apt-get update
apt-get install -y --no-install-recommends \
  libc6:i386 libncurses6:i386 libstdc++6:i386 \
  lib32z1 libbz2-1.0:i386

apt-get install -y --no-install-recommends \
  openjdk-21-jdk \
  unzip \
  xz-utils

# ---------------------------------------------------------------------------
# Shared cross-arch download cache (wired via Dockerfile.android:
# --mount=type=cache,target=${ANDROID_SDK_CACHE_DIR},sharing=locked with an id
# keyed by the SDK/NDK version tuple, deliberately NOT by TARGETARCH). This
# script only ever runs on amd64 build hosts (see the
# android_require_amd64_build_host gate above), so the installed tree —
# linux-x86_64 host tooling plus sdkmanager packages keyed by name+version —
# is identical for every target arch. The first arch populates
# <cache>/sdk-tree; the 2nd/3rd arch restore from it instead of re-downloading
# the multi-GB SDK/NDK from Google. sharing=locked already serializes
# concurrent --parallel-archs builds on the mount; the populate at the bottom
# is additionally staged + atomic-mv so an interrupted build can never publish
# a partial tree. NOTE the cache mount is invisible at image runtime:
# everything is still installed into ${ANDROID_HOME} in the image layer.
# Unset/absent cache dir (script run outside the Dockerfile) => plain install.
ANDROID_SDK_CACHE_DIR="${ANDROID_SDK_CACHE_DIR:-}"
sdk_cache_tree=""
if [ -n "${ANDROID_SDK_CACHE_DIR}" ] && [ -d "${ANDROID_SDK_CACHE_DIR}" ]; then
  sdk_cache_tree="${ANDROID_SDK_CACHE_DIR}/sdk-tree"
fi

sdk_restored=0
if [ -n "${sdk_cache_tree}" ] && [ -d "${sdk_cache_tree}" ]; then
  echo "android-sdk shared cache HIT: restoring ${ANDROID_HOME} from ${sdk_cache_tree} (skipping SDK/NDK downloads)"
  mkdir -p "${ANDROID_HOME}"
  cp -a "${sdk_cache_tree}/." "${ANDROID_HOME}/"
  sdk_restored=1
elif [ -n "${sdk_cache_tree}" ]; then
  echo "android-sdk shared cache MISS: downloading SDK/NDK, then populating ${sdk_cache_tree} for the other arches"
fi

if [ "${sdk_restored}" -eq 0 ]; then
  mkdir -p "${ANDROID_HOME}/cmdline-tools"

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT

  cd "${tmpdir}"
  zip_name="commandlinetools-linux-${ANDROID_SDK_VERSION}_latest.zip"
  # VERIFIED fetch (supply-chain audit #8): the unzipped sdkmanager bootstraps
  # the NDK — the cross compiler for every Android artifact — and auto-accepts
  # all licenses; every downstream hash check rests on this binary's integrity.
  # The pin is noforward (not a build-arg): read it from the mounted versions.env
  # when the env doesn't carry it (same pattern as install-rust.sh).
  if [ -z "${ANDROID_CMDLINE_TOOLS_SHA256:-}" ] && [ -f /opt/scripts/core/versions.env ]; then
    ANDROID_CMDLINE_TOOLS_SHA256="$(sed -n 's/^ANDROID_CMDLINE_TOOLS_SHA256=//p' /opt/scripts/core/versions.env)"
  fi
  # Shared-cache lookup for the cmdline-tools zip (keyed by the version in the
  # file name, re-verified against the sha pin when one is set). This covers
  # partial invalidations: a bump of any other pin changes the sdk-tree cache
  # key, but the unchanged cmdline-tools zip need not be re-downloaded.
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
      # Publish to the shared cache via copy-to-temp + atomic mv so a reader
      # can never observe a partially written zip (belt-and-braces on top of
      # the mount's sharing=locked serialization).
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
      # Trust the exit code only: sdkmanager prints "Done." per package, so a
      # partially failed multi-package install still emits it — grepping for it
      # here used to turn half-failed installs into false successes.
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

  # Accept any existing/required licenses before installing packages. FATAL on
  # failure: an unaccepted license guarantees an opaque sdkmanager/gradle failure
  # later, so fail loudly here where the cause is still visible.
  accept_licenses

  sdk_packages=(
    "cmake;${ANDROID_CMAKE_VERSION}"
    "platform-tools"
    "platforms;android-${ANDROID_COMPILE_SDK}"
    "build-tools;${ANDROID_BUILD_TOOLS}"
    "ndk;${ANDROID_NDK_VERSION}"
    "extras;android;m2repository"
    "extras;google;m2repository"
  )

  # sdkmanager_install already retries transient failures; call it directly
  # instead of the old one-shot-then-retry duplication of the package list.
  sdkmanager_install "${sdk_packages[@]}"

  # Ensure licenses are accepted after installation too (some packages add new
  # licenses). FATAL for the same reason as the pre-install acceptance above.
  accept_licenses
fi

# Postcondition: the NDK directory the whole Android lane cross-compiles with
# must exist at the version-pinned path (same derivation the downstream builds
# use: ${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}).
ndk_dir="${ANDROID_HOME}/ndk/${ANDROID_NDK_VERSION}"
if [ ! -d "${ndk_dir}" ]; then
  echo "ERROR: expected NDK directory '${ndk_dir}' missing after sdkmanager install" >&2
  exit 1
fi

# Convenience symlink used by some Android workflows.
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
  ln -sf "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64" "${ANDROID_NDK_HOME}/toolchain" || true
fi

# Populate the shared cross-arch cache (first arch through the mount only;
# runs AFTER the NDK postcondition + toolchain symlink so the cached tree is
# the fully validated install). Stage into a temp dir on the same cache
# filesystem, then atomically mv into place: rename is atomic, so a build
# killed mid-copy can never publish a partial tree — the next build simply
# misses and re-populates. Failure to populate is non-fatal by design: THIS
# arch's install is already complete in the image layer.
if [ "${sdk_restored}" -eq 0 ] && [ -n "${sdk_cache_tree}" ] && [ ! -d "${sdk_cache_tree}" ]; then
  rm -rf "${ANDROID_SDK_CACHE_DIR}"/sdk-tree.staging.*
  sdk_cache_staging="$(mktemp -d "${ANDROID_SDK_CACHE_DIR}/sdk-tree.staging.XXXXXX")"
  if cp -a "${ANDROID_HOME}/." "${sdk_cache_staging}/" && mv "${sdk_cache_staging}" "${sdk_cache_tree}"; then
    echo "android-sdk shared cache populated: ${sdk_cache_tree}"
  else
    rm -rf "${sdk_cache_staging}"
    echo "WARNING: failed to populate android-sdk shared cache (non-fatal; other arches will re-download)" >&2
  fi
fi

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/*
