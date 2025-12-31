#!/bin/bash
set -eux

# 1. Parse Arguments
GST_VERSION="1.26.9"
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

# 4. Setup Cerbero
cd /opt
if [ ! -d "cerbero" ]; then
    git clone --depth 1 --branch "$GST_VERSION" \
        https://gitlab.freedesktop.org/gstreamer/cerbero.git
fi
cd cerbero

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

# 11. Execute build
(
    unset RUSTUP_HOME CARGO_HOME RUSTC_WRAPPER
    export DEBIAN_FRONTEND=noninteractive
    export SETUPTOOLS_USE_DISTUTILS=local
    
    # Set Android environment variables
    export ANDROID_SDK_ROOT="${ANDROID_SDK}"
    export ANDROID_NDK_HOME="${ANDROID_NDK}"
    
    echo "==> Running Cerbero Bootstrap..."
    uv run ./cerbero-uninstalled -c ${CONFIG_NAME}.cbc bootstrap
    
    echo "==> Building GStreamer..."
    uv run ./cerbero-uninstalled -c ${CONFIG_NAME}.cbc package gstreamer-1.0
)

# 12. Extract package
mkdir -p "$INSTALL_PATH"

echo "==> Searching for package..."
PACKAGE_FILE=$(find . -name "gstreamer-1.0-*android*.tar.*" -type f 2>/dev/null | head -n 1)

if [ -z "$PACKAGE_FILE" ]; then
    echo "Error: Package not found. Listing all tar files:"
    find . -name "*.tar.*" -type f 2>/dev/null || echo "No tar files found"
    exit 1
fi

echo "==> Extracting: $PACKAGE_FILE"
tar -xf "$PACKAGE_FILE" -C "$INSTALL_PATH" --strip-components=1

echo ""
echo "==> ✓ Success!"
echo "==> GStreamer ${GST_VERSION} for Android ${TARGET_ARCH} (API ${ANDROID_API_LEVEL})"
echo "==> Installed to: $INSTALL_PATH"
echo ""
