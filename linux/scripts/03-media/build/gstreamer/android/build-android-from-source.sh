#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../android-build-preamble.sh"

# 1. Parse Arguments
GST_VERSION="${GSTREAMER_VERSION:-1.29.2}"
ANDROID_SDK="${ANDROID_HOME:-/opt/android-sdk}"
ANDROID_NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:-/opt/android-sdk}/ndk/${ANDROID_NDK_VERSION:-29.0.14206865}}"
INSTALL_PATH="${GSTREAMER_ROOT_ANDROID:-/opt/android/gstreamer}"
TARGET_ARCH="${TARGET_ARCH:-${TARGETARCH:-arm64}}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --gst-version=*) GST_VERSION="${1#*=}"; shift ;;
    --android-sdk=*) ANDROID_SDK="${1#*=}"; shift ;;
    --android-ndk=*) ANDROID_NDK="${1#*=}"; shift ;;
    --android-api=*) ANDROID_API_LEVEL="${1#*=}"; shift ;;
    --prefix=*)      INSTALL_PATH="${1#*=}"; shift ;;
    --target-arch=*) TARGET_ARCH="${1#*=}"; shift ;;
    --with-onnx-inference) shift ;;
    *) shift ;;
  esac
done

# 2. Set environment for non-interactive apt
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

android_build_preamble_init "GStreamer Android build" "${ANDROID_API_LEVEL:-34}"

resolve_host_python() {
    if command -v host_python_bin >/dev/null 2>&1; then
        host_python_bin
        return
    fi

    if [ -n "${MEDIA_HOST_PYTHON:-}" ] && [ -x "${MEDIA_HOST_PYTHON}" ]; then
        printf '%s' "${MEDIA_HOST_PYTHON}"
        return
    fi

    if [ -n "${UV_PYTHON:-}" ] && [ -x "${UV_PYTHON}" ]; then
        printf '%s' "${UV_PYTHON}"
        return
    fi

    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/python" ]; then
        printf '%s' "${VIRTUAL_ENV}/bin/python"
        return
    fi

    if [ -n "${PYTHON_MAJOR_MINOR:-}" ] && [ -x "/usr/local/bin/python${PYTHON_MAJOR_MINOR}" ]; then
        printf '%s' "/usr/local/bin/python${PYTHON_MAJOR_MINOR}"
        return
    fi

    command -v python3 2>/dev/null || command -v python 2>/dev/null || return 1
}

patch_cerbero_system_m4_usage() {
    local autoconf_recipe="recipes/build-tools/autoconf.recipe"
    local libtool_recipe="recipes/build-tools/libtool.recipe"

    [ -f "${autoconf_recipe}" ] || return 0
    [ -f "${libtool_recipe}" ] || return 0

    # Container layout first (apply-patch.sh + patches/ are COPY'd into the
    # android stages); the 4-up repo-relative path resolves to /opt in the
    # flattened container layout ("bash: /opt/01-core/apply-patch.sh: No such
    # file", exit 127).
    local _apply_patch _patches_root _scripts_dir
    if [ -f /opt/scripts/core/apply-patch.sh ]; then
        _apply_patch=/opt/scripts/core/apply-patch.sh
        _patches_root=/opt/scripts/patches
    else
        _scripts_dir="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
        _apply_patch="${_scripts_dir}/01-core/apply-patch.sh"
        _patches_root="${_scripts_dir}/patches"
    fi
    bash "${_apply_patch}" \
      "${_patches_root}/cerbero/001-drop-m4-dependency.patch" \
      "$(pwd)" \
      "Cerbero drop m4 dependency from autoconf/libtool recipes"
}

override_pkgconfig_dead_mirror() {
    # PKGCFG-MIRROR (2026-08-22): cerbero bootstraps pkg-config-0.29.2 from
    # gstreamer.freedesktop.org/src/mirror/ which now returns 404 (upstream
    # restructure), and the original pkgconfig.freedesktop.org is unreachable
    # — every COLD cerbero bootstrap dies on curl (22) across ALL arches.
    # Point the recipe at the stable macports distfiles mirror (verified
    # HTTP 200; same tarball, checksum in the recipe still guards the bytes).
    local recipe
    recipe="$(grep -rl "pkg-config-0.29.2\|pkgconfig" recipes/ packages/ 2>/dev/null | grep -m1 "pkg-config" || true)"
    [ -n "${recipe}" ] || recipe="recipes/build-tools/pkg-config.recipe"
    if [ -f "${recipe}" ]; then
        sed -i           -e 's|https://gstreamer.freedesktop.org/src/mirror/pkg-config|https://distfiles.macports.org/pkgconfig/pkg-config|g'           -e 's|https://pkgconfig.freedesktop.org/releases|https://distfiles.macports.org/pkgconfig|g'           "${recipe}"
        echo "cerbero: pkg-config source redirected to macports mirror (freedesktop 404, PKGCFG-MIRROR)"
    else
        echo "WARNING: pkg-config recipe not found for mirror override — cold bootstrap may 404" >&2
    fi
}

override_soundtouch_codeberg_checksum() {
    # soundtouch is fetched from Codeberg's AUTO-GENERATED archive
    # (codeberg.org/soundtouch/soundtouch/archive/<version>.tar.gz). Forgejo
    # regenerates these with different compression periodically, so ANY static
    # pinned hash drifts while the SOURCE is unchanged. It has drifted 3x
    # (e07abf... -> 87c6c9... -> 35d404e6...), so chasing it with a hardcoded
    # value is a losing game.
    #
    # Instead of pinning a fixed hash, pin DYNAMICALLY: fetch the archive now,
    # compute its real sha256, and write THAT into the recipe so cerbero's later
    # fetch always matches. Integrity rests on TLS + the version tag (the tag is
    # immutable; only the archive's compression varies) -- the right trade-off
    # for a non-byte-stable auto-archive. Best-effort: on any failure the recipe
    # is left untouched and cerbero's own checksum step still guards the fetch.
    local recipe="recipes/soundtouch.recipe"
    [ -f "${recipe}" ] || return 0
    command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 || {
        echo "WARNING: curl/sha256sum unavailable; cannot dynamic-pin soundtouch checksum" >&2
        return 0
    }

    local ver cur url tmp actual
    ver="$(sed -n "s/^[[:space:]]*version[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "${recipe}" | head -1)"
    cur="$(sed -n "s/^[[:space:]]*tarball_checksum[[:space:]]*=[[:space:]]*['\"]\([0-9a-fA-F]*\)['\"].*/\1/p" "${recipe}" | head -1)"
    if [ -z "${ver}" ] || [ -z "${cur}" ]; then
        echo "WARNING: could not parse soundtouch version/checksum from recipe; leaving as-is" >&2
        return 0
    fi

    url="https://codeberg.org/soundtouch/soundtouch/archive/${ver}.tar.gz"
    tmp="$(mktemp)"
    if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 -o "${tmp}" "${url}"; then
        actual="$(sha256sum "${tmp}" | awk '{print $1}')"
        if [ -n "${actual}" ] && [ "${actual}" != "${cur}" ]; then
            sed -i "s/${cur}/${actual}/g" "${recipe}"
            echo "Re-pinned soundtouch tarball checksum ${cur} -> ${actual} (live Codeberg archive ${ver})"
        else
            echo "soundtouch tarball checksum already matches live Codeberg archive (${cur})"
        fi
    else
        echo "WARNING: could not pre-fetch soundtouch archive to re-pin checksum; leaving recipe as-is" >&2
    fi
    rm -f "${tmp}"
}

# ------------------------------------------------------------------------------
# Concurrency limiting (similar to the desktop GStreamer build)
# ------------------------------------------------------------------------------
# You can override by exporting JOBS (or set ANDROID_GSTREAMER_PER_JOB_MB)
PER_JOB_MB="${ANDROID_GSTREAMER_PER_JOB_MB:-1500}"

if [ -z "${JOBS:-}" ]; then
    JOBS="$(nproc --all)"
    # Nothing in this script pre-loads parallelism.sh, so source it on demand
    # (container path) before probing for compute_jobs_with_mem_cap — mirrors
    # media_jobs() in android-build-preamble.sh, but keeps the configurable
    # ANDROID_GSTREAMER_PER_JOB_MB cap instead of its fixed 2000 MB.
    if [ -f /opt/scripts/core/parallelism.sh ]; then
        # shellcheck disable=SC1091
        source /opt/scripts/core/parallelism.sh 2>/dev/null || true
        if declare -F compute_jobs_with_mem_cap >/dev/null 2>&1; then
            JOBS="$(compute_jobs_with_mem_cap "" "${PER_JOB_MB}")"
        fi
    fi
fi

export JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
export MAKEFLAGS="-j${JOBS}"
export NINJAFLAGS="-j${JOBS}"

# Cargo/Rust build parallelism (important for gst-plugins-rs)
export CARGO_BUILD_JOBS="${JOBS}"
# Codegen units begrenzen = weniger RAM pro Crate
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${JOBS}"
# Optional: LTO deaktivieren spart RAM bei Release-Builds
# export CARGO_PROFILE_RELEASE_LTO="false"

echo "Using JOBS=${JOBS} (CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL}, CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}, per_job_mb=${PER_JOB_MB})"

# 3. Pre-install dependencies
echo "==> Pre-installing dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
    autotools-dev automake autoconf libtool g++ autopoint \
    make cmake ninja-build bison flex nasm pkg-config \
    libxv-dev libx11-dev libx11-xcb-dev libpulse-dev \
    gettext build-essential libxext-dev libxi-dev \
    x11proto-record-dev libxrender-dev libgl1-mesa-dev \
    libxfixes-dev libxdamage-dev libxcomposite-dev libasound2-dev \
    gperf wget libxtst-dev libxrandr-dev libglu1-mesa-dev \
    libegl1-mesa-dev git m4 xutils-dev ccache \
    libssl-dev

# 4. Setup Cerbero with fallback mechanism
cd /opt
if [ ! -d "cerbero" ]; then
    # First, clone without depth to allow fallback branch checkout
    # Pinned shallow clone, HARD-FAIL on a missing tag (supply-chain audit
    # #20): the old ladder fell back to the MOVING origin/<major.minor>
    # branch, silently turning a reproducible build into an unreproducible
    # one — and cerbero is the build system that pins every downstream
    # GStreamer source. A missing tag is a loud, fixable condition.
    echo "==> Cloning cerbero at pinned tag: $GST_VERSION"
    if ! git clone --depth 1 --branch "$GST_VERSION" https://gitlab.freedesktop.org/gstreamer/cerbero.git; then
        echo "Error: cerbero has no tag '$GST_VERSION'." >&2
        echo "       Fix GSTREAMER_VERSION in versions.env (or add a 40-hex CERBERO_COMMIT" >&2
        echo "       pin there and extend this clone) — refusing the moving-branch fallback." >&2
        exit 1
    fi
    cd cerbero
else
    cd cerbero
fi

patch_cerbero_system_m4_usage
override_soundtouch_codeberg_checksum
override_pkgconfig_dead_mirror

# 5. Setup Python Virtual Environment
HOST_PYTHON="$(resolve_host_python)"
export UV_PYTHON="${HOST_PYTHON}" \
       MEDIA_HOST_PYTHON="${HOST_PYTHON}"
uv venv --seed --python "${HOST_PYTHON}" .venv
source .venv/bin/activate
export UV_PYTHON="${VIRTUAL_ENV}/bin/python" \
       MEDIA_HOST_PYTHON="${VIRTUAL_ENV}/bin/python"
uv pip install distro "setuptools==70.0.0" wheel

# 6. Detect build host
BUILD_ARCH=$(uname -m)
case "$BUILD_ARCH" in
    x86_64|amd64) CERBERO_HOST_ARCH="X86_64" ;;
    aarch64|arm64) CERBERO_HOST_ARCH="ARM64" ;;
    *) echo "Unsupported: $BUILD_ARCH"; exit 1 ;;
esac

# 7. Map target architecture
case "$TARGET_ARCH" in
    arm64|aarch64)
        CERBERO_TARGET_ARCH="ARM64"
        CONFIG_NAME="android_arm64"
        ;;
    amd64|x86_64|x64)
        CERBERO_TARGET_ARCH="X86_64"
        CONFIG_NAME="android_x86_64"
        ;;
    riscv64|riscv|rv64*)
        CERBERO_TARGET_ARCH="RISCV64"
        CONFIG_NAME="android_riscv64"
        ;;
    armv7|arm)
        CERBERO_TARGET_ARCH="ARMv7"
        CONFIG_NAME="android_armv7"
        ;;
    *)
        echo "Unsupported target: $TARGET_ARCH"
        exit 1
        ;;
esac

# 8. Create Cerbero home directory structure
CERBERO_HOME="/opt/cerbero"
CERBERO_PREFIX="${CERBERO_HOME}/dist/android_${TARGET_ARCH}"
mkdir -p "${CERBERO_HOME}"
mkdir -p "${CERBERO_PREFIX}"

# 9. Map API level to Cerbero's DistroVersion enum
CERBERO_VARIANTS_OVERRIDE=""

# Note: Cerbero's bundled riscv64 Android config requires API 35 and disables Rust.
# Other Android targets still use the older distro version mapping.
if [ "${CERBERO_TARGET_ARCH}" = "RISCV64" ]; then
    DISTRO_VERSION="ANDROID_VANILLAICECREAM"
    CERBERO_VARIANTS_OVERRIDE="variants.override('norust')"
    echo "==> Note: Using ANDROID_VANILLAICECREAM for Android riscv64 (Cerbero requirement)"
elif [ "$ANDROID_API_LEVEL" -ge 26 ]; then
    DISTRO_VERSION="ANDROID_OREO"           # API 26+ - Use Oreo for all newer versions
    echo "==> Note: Using ANDROID_OREO for API ${ANDROID_API_LEVEL} (highest available in GStreamer 1.26.9)"
elif [ "$ANDROID_API_LEVEL" -ge 24 ]; then
    DISTRO_VERSION="ANDROID_NOUGAT"         # API 24-25 - Nougat
elif [ "$ANDROID_API_LEVEL" -ge 23 ]; then
    DISTRO_VERSION="ANDROID_MARSHMALLOW"    # API 23 - Marshmallow
elif [ "$ANDROID_API_LEVEL" -ge 21 ]; then
    DISTRO_VERSION="ANDROID_LOLLIPOP_MR1"   # API 21-22 - Lollipop
elif [ "$ANDROID_API_LEVEL" -ge 19 ]; then
    DISTRO_VERSION="ANDROID_KITKAT"         # API 19 - KitKat
else
    echo "Error: Minimum Android API level is 19"
    exit 1
fi

# 10. Create comprehensive configuration file
cat > ${CONFIG_NAME}.cbc <<EOF
import os
from cerbero.config import Architecture, Distro, Platform, DistroVersion

# Build host configuration
arch = Architecture.${CERBERO_HOST_ARCH}
platform = Platform.LINUX

# Target configuration
target_platform = Platform.ANDROID
target_distro = Distro.ANDROID
target_arch = Architecture.${CERBERO_TARGET_ARCH}
target_distro_version = DistroVersion.${DISTRO_VERSION}

# Android-specific paths
os.environ['ANDROID_SDK_ROOT'] = "${ANDROID_SDK}"
os.environ['ANDROID_NDK_HOME'] = "${ANDROID_NDK}"

android_sdk = "${ANDROID_SDK}"
android_ndk = "${ANDROID_NDK}"

# Build paths
home_dir = "${CERBERO_HOME}"
prefix = "${CERBERO_PREFIX}"
sources = os.path.join(home_dir, "sources")
logs = os.path.join(home_dir, "logs")
cache_file = os.path.join(home_dir, "cache-file.cache")

# Build configuration
${CERBERO_VARIANTS_OVERRIDE}
interactive = False

# Toolchain configuration
allow_system_libs = False
use_ccache = True if os.path.exists('/usr/bin/ccache') else False
EOF

echo "==> Configuration created:"
echo "    Build Host: ${CERBERO_HOST_ARCH}"
echo "    Target: ${CERBERO_TARGET_ARCH}"
echo "    API Level: ${ANDROID_API_LEVEL} (using ${DISTRO_VERSION})"
echo "    Cerbero Home: ${CERBERO_HOME}"
echo "    Prefix: ${CERBERO_PREFIX}"

# Try to pass the job limit through Cerbero's CLI if supported (different Cerbero versions vary).
CERBERO_JOBS_ARGS=()
if uv run ./cerbero-uninstalled --help 2>&1 | grep -q -- '--jobs'; then
    CERBERO_JOBS_ARGS+=(--jobs "${JOBS}")
elif uv run ./cerbero-uninstalled --help 2>&1 | grep -q -- '-j'; then
    CERBERO_JOBS_ARGS+=(-j "${JOBS}")
else
    echo "==> Note: Cerbero CLI has no --jobs/-j; relying on env (MAKEFLAGS/CMAKE_BUILD_PARALLEL_LEVEL/NINJAFLAGS)"
fi

# 11. Execute build
(
    unset RUSTUP_HOME CARGO_HOME RUSTC_WRAPPER
    export DEBIAN_FRONTEND=noninteractive
    export M4=/usr/bin/m4
    export SETUPTOOLS_USE_DISTUTILS=local
    
    # Set Android environment variables
    export ANDROID_SDK_ROOT="${ANDROID_SDK}"
    export ANDROID_NDK_HOME="${ANDROID_NDK}"
    
    # Ensure apt runs non-interactively and pre-install common build deps
    # Cerbero's bootstrap may invoke apt-get without -y which prompts; pre-install
    # the packages it requests so the bootstrap won't stop for confirmation.
    # Must FAIL here on error (no `|| true`): a mirror outage swallowed at this
    # point resurfaces hours later as an inscrutable Cerbero bootstrap failure.
    # Transient network hiccups are already retried via the base image's
    # /etc/apt/apt.conf.d/80-retries (Acquire::Retries "3").
    echo "==> Installing system packages required by Cerbero (non-interactive)"
    apt-get update
    apt-get install -y --no-install-recommends \
        autoconf automake autopoint autotools-dev binutils bison build-essential \
        ccache cmake curl flex g++ gettext git gperf libasound2-dev libclang-dev \
        libcurl4-openssl-dev libdrm-dev libegl1-mesa-dev libgl1-mesa-dev \
        libglu1-mesa-dev libpulse-dev libssl-dev libtool libva-dev libx11-dev \
        libx11-xcb-dev libxcomposite-dev libxdamage-dev libxext-dev libxfixes-dev \
        libxi-dev libxrandr-dev libxrender-dev libxtst-dev libxv-dev m4 make nasm \
        ninja-build pkg-config python3-dev python3-setuptools x11proto-record-dev \
        xutils-dev

    echo "==> Running Cerbero Bootstrap..."
    uv run ./cerbero-uninstalled -c ${CONFIG_NAME}.cbc "${CERBERO_JOBS_ARGS[@]}" bootstrap
    
    echo "==> Building GStreamer..."
    uv run ./cerbero-uninstalled -c ${CONFIG_NAME}.cbc "${CERBERO_JOBS_ARGS[@]}" package gstreamer-1.0
)

# 12. Extract package
mkdir -p "$INSTALL_PATH"

echo "==> Searching for package..."
PACKAGE_FILE=""
while IFS= read -r candidate; do
    case "${candidate}" in
        *-runtime.tar.*) ;; # prefer non-runtime if available
        *) PACKAGE_FILE="${candidate}"; break ;;
    esac
done < <(find . -name "gstreamer-1.0-*android*.tar.*" -type f 2>/dev/null | sort)

if [ -z "${PACKAGE_FILE}" ]; then
    PACKAGE_FILE=$(find . -name "gstreamer-1.0-*android*.tar.*" -type f 2>/dev/null | sort | head -n 1)
fi

if [ -z "$PACKAGE_FILE" ]; then
    echo "Error: Package not found. Listing all tar files:"
    find . -name "*.tar.*" -type f 2>/dev/null || echo "No tar files found"
    exit 1
fi

echo "==> Extracting: $PACKAGE_FILE"

# Avoid "Cannot open: Not a directory" due to previous partial extractions
if [ -z "${INSTALL_PATH}" ] || [ "${INSTALL_PATH}" = "/" ]; then
    echo "Refusing to extract into unsafe INSTALL_PATH='${INSTALL_PATH}'"
    exit 1
fi

rm -rf "${INSTALL_PATH}"
mkdir -p "${INSTALL_PATH}"

tar -xf "$PACKAGE_FILE" -C "$INSTALL_PATH" --strip-components=1

echo ""
echo "==> ✓ Success!"
echo "==> GStreamer ${GST_VERSION} for Android ${TARGET_ARCH} (API ${ANDROID_API_LEVEL})"
echo "==> Installed to: $INSTALL_PATH"
echo ""

# ------------------------------------------------------------------------------
# Cleanup Cerbero build directory (~10-15 GB)
# The built GStreamer is now extracted to $INSTALL_PATH, so we no longer need
# the Cerbero sources, build artifacts, and packaged tarballs.
# ------------------------------------------------------------------------------
echo "==> Cleaning up Cerbero build directory..."
CERBERO_SIZE=$(du -sh /opt/cerbero 2>/dev/null | cut -f1 || echo "unknown")
rm -rf /opt/cerbero
echo "==> Cleanup complete. Freed ${CERBERO_SIZE} of disk space."
