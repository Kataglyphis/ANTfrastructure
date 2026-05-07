#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

: "${WITH_PYTHON:=true}"
: "${WITH_JAVA:=false}"
: "${OPENCV_PYTHON_VERSION:=3.14t}"

echo "Installing OpenCV build dependencies..."

apt-get update -y
install_host_packages \
    build-essential \
    cmake \
    git \
    pkg-config \
    wget \
    unzip \
    libtbb-dev \
    libeigen3-dev

target_packages=(
    libavcodec-dev
    libavformat-dev
    libswscale-dev
    libv4l-dev
    libxvidcore-dev
    libx264-dev
    libjpeg-dev
    libpng-dev
    libtiff-dev
    libopenexr-dev
    libunwind-dev
    libdc1394-dev
)

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
    echo "Skipping libgtk-3-dev for cross builds because libpango1.0-dev is not multiarch-coinstallable."
    if [ "$(cross_target_arch)" = "riscv64" ]; then
        echo "Skipping GStreamer dev packages for riscv64 cross builds because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
    else
        target_packages+=(libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev)
    fi
else
    target_packages=(libgtk-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev "${target_packages[@]}")
fi

install_target_packages "${target_packages[@]}"

if [ "${WITH_PYTHON}" = "true" ]; then
    echo "[INFO] Python dependencies are satisfied via source build and uv."
fi

if [ "${WITH_JAVA}" = "true" ]; then
    apt-get install -y --no-install-recommends default-jdk ant || true
fi
