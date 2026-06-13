#!/usr/bin/env bash
set -euo pipefail

for _cv_env in \
    "/opt/scripts/core/cross-env.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../01-core/cross-env.sh"; do
    if [ -f "${_cv_env}" ]; then
        source "${_cv_env}" || { echo "FATAL: cannot load ${_cv_env}" >&2; exit 1; }
        break
    fi
done

: "${WITH_PYTHON:=true}"
: "${WITH_JAVA:=false}"
: "${OPENCV_PYTHON_VERSION:=$(host_python_major_minor)}"

echo "Installing OpenCV build dependencies..."

if command -v apt_update_smart >/dev/null 2>&1; then
    apt_update_smart
else
    apt-get update -y
fi
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

if is_cross; then
    echo "Skipping libgtk-3-dev for cross builds because libpango1.0-dev is not multiarch-coinstallable."
    if [ "$(cross_target_arch)" = "riscv64" ]; then
        echo "Skipping GStreamer dev packages for riscv64 cross builds because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
        echo "Installing riscv64 target OpenCV codec/video deps on a best-effort basis because Ubuntu Ports currently has broken dependency sets for some packages (for example FFmpeg/libpng)."
    else
        target_packages+=(libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev)
    fi
else
    target_packages=(libgtk-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev "${target_packages[@]}")
fi

if cross_build_is_active && [ "$(cross_target_arch)" = "riscv64" ]; then
    install_optional_target_packages "${target_packages[@]}"
else
    install_target_packages "${target_packages[@]}"
fi

if [ "${WITH_PYTHON}" = "true" ]; then
    if is_cross; then
        if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
            echo "[INFO] Using staged target Python headers from $(cross_target_python_include_dir)"
        else
            echo "[WARN] Target Python ${OPENCV_PYTHON_VERSION} development files are missing for $(cross_target_triplet 2>/dev/null || echo target); disabling OpenCV Python bindings for this cross build"
        fi
    else
        echo "[INFO] Python dependencies are satisfied via source build and uv."
    fi
fi

if [ "${WITH_JAVA}" = "true" ]; then
    apt-get install -y --no-install-recommends default-jdk ant || true
fi
