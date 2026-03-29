#!/bin/bash
set -eux

# 1. Parse Arguments
GST_VERSION="1.29.1"
ANDROID_SDK="/opt/android-sdk"
ANDROID_NDK="/opt/android-sdk/ndk/29.0.14206865"
INSTALL_PATH="/opt/android/gstreamer"
ANDROID_API_LEVEL=34  # Android 14
TARGET_ARCH="arm64"

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

# ------------------------------------------------------------------------------
# Concurrency limiting (similar to the desktop GStreamer build)
# ------------------------------------------------------------------------------
# You can override by exporting JOBS (or set ANDROID_GSTREAMER_PER_JOB_MB)
PER_JOB_MB="${ANDROID_GSTREAMER_PER_JOB_MB:-1500}"

if [ -z "${JOBS:-}" ]; then
    CORES="$(nproc --all)"

    # Available RAM in MB (fallback 2048 MB)
    AVAIL_MB="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo)"
    [ -z "${AVAIL_MB}" ] && AVAIL_MB=2048

    MAX_BY_MEM=$(( AVAIL_MB / PER_JOB_MB ))
    [ "${MAX_BY_MEM}" -lt 1 ] && MAX_BY_MEM=1

    # JOBS = min(CORES, MAX_BY_MEM)
    if [ "${CORES}" -lt "${MAX_BY_MEM}" ]; then
        JOBS="${CORES}"
    else
        JOBS="${MAX_BY_MEM}"
    fi

    # Reserve one core for system if possible
    if [ "${JOBS}" -gt 1 ]; then
        JOBS=$((JOBS - 1))
    fi

    [ "${JOBS}" -lt 1 ] && JOBS=1
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
    python3-dev gettext build-essential libxext-dev libxi-dev \
    x11proto-record-dev libxrender-dev libgl1-mesa-dev \
    libxfixes-dev libxdamage-dev libxcomposite-dev libasound2-dev \
    gperf wget libxtst-dev libxrandr-dev libglu1-mesa-dev \
    libegl1-mesa-dev git xutils-dev ccache python3-setuptools \
    libssl-dev

# 4. Setup Cerbero with fallback mechanism
cd /opt
if [ ! -d "cerbero" ]; then
    # First, clone without depth to allow fallback branch checkout
    git clone https://gitlab.freedesktop.org/gstreamer/cerbero.git
    cd cerbero
    
    # Try to checkout the specific tag
    echo "==> Attempting to checkout tag: $GST_VERSION"
    if git checkout "$GST_VERSION" 2>/dev/null; then
        echo "==> Successfully checked out tag: $GST_VERSION"
    else
        echo "==> Tag $GST_VERSION not found, attempting fallback..."
        
        # Extract major.minor version (e.g., "1.26" from "1.26.10")
        MAJOR_MINOR=$(echo "$GST_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
        
        if [ -z "$MAJOR_MINOR" ]; then
            echo "Error: Could not extract major.minor version from $GST_VERSION"
            exit 1
        fi
        
        echo "==> Extracted version prefix: $MAJOR_MINOR"
        
        # Fetch all branches to ensure we have remote branches available
        git fetch --all
        
        # Try to find a matching branch (e.g., "1.26" or "origin/1.26")
        BRANCH_FOUND=false
        
        # Check local branches first
        if git show-ref --verify --quiet "refs/heads/$MAJOR_MINOR"; then
            echo "==> Found local branch: $MAJOR_MINOR"
            git checkout "$MAJOR_MINOR"
            BRANCH_FOUND=true
        # Check remote branches
        elif git show-ref --verify --quiet "refs/remotes/origin/$MAJOR_MINOR"; then
            echo "==> Found remote branch: origin/$MAJOR_MINOR"
            git checkout -b "$MAJOR_MINOR" "origin/$MAJOR_MINOR"
            BRANCH_FOUND=true
        else
            # Try to find any tag matching the major.minor version
            echo "==> Searching for tags matching $MAJOR_MINOR..."
            MATCHING_TAG=$(git tag -l "${MAJOR_MINOR}*" | sort -V | tail -n 1)
            
            if [ -n "$MATCHING_TAG" ]; then
                echo "==> Found matching tag: $MATCHING_TAG"
                git checkout "$MATCHING_TAG"
                BRANCH_FOUND=true
            fi
        fi
        
        if [ "$BRANCH_FOUND" = false ]; then
            echo "Error: Could not find tag $GST_VERSION or branch/tag matching $MAJOR_MINOR"
            echo "Available tags:"
            git tag -l | head -20
            echo "Available branches:"
            git branch -r | head -20
            exit 1
        fi
    fi
else
    cd cerbero
fi

# 5. Setup Python Virtual Environment
export UV_PYTHON=python3.12
uv venv .venv
source .venv/bin/activate
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
    x86_64|x64)
        CERBERO_TARGET_ARCH="X86_64"
        CONFIG_NAME="android_x86_64"
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
# Note: GStreamer 1.26.9 has limited Android version support
# Use the highest available version for newer Android APIs
if [ "$ANDROID_API_LEVEL" -ge 26 ]; then
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
variants = []
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
    export SETUPTOOLS_USE_DISTUTILS=local
    
    # Set Android environment variables
    export ANDROID_SDK_ROOT="${ANDROID_SDK}"
    export ANDROID_NDK_HOME="${ANDROID_NDK}"
    
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
