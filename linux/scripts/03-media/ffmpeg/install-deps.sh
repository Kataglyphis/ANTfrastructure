#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

echo "Installing FFmpeg build dependencies..."

apt-get update -y
install_host_packages \
    autoconf \
    automake \
    build-essential \
    cmake \
    git \
    libtool \
    pkg-config \
    texinfo \
    wget \
    yasm \
    nasm

target_packages=(
    libfreetype6-dev
    libmp3lame-dev
    libva-dev
    libvdpau-dev
    libvorbis-dev
    libxcb1-dev
    libxcb-shm0-dev
    libxcb-xfixes0-dev
    zlib1g-dev
    libx264-dev
    libx265-dev
    libnuma-dev
    libvpx-dev
    libfdk-aac-dev
    libopus-dev
    libaom-dev
    libdav1d-dev
    libsvtav1-dev
    libsvtav1enc-dev
)

if command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
    echo "Skipping libass-dev for riscv64 because Ubuntu Ports cannot satisfy its HarfBuzz/GLib helper dependency chain."
    echo "Skipping libgnutls28-dev for riscv64 because FFmpeg's cross probe does not currently pass in this environment."
    echo "Skipping libsdl2-dev for riscv64 because Ubuntu Ports cannot satisfy its GLib helper dependency chain."
else
    target_packages+=(libgnutls28-dev)
    target_packages+=(libass-dev)
    target_packages+=(libsdl2-dev)
fi

install_target_packages "${target_packages[@]}"

if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
    echo "Installing nv-codec-headers for FFmpeg NVIDIA acceleration..."
    git clone https://git.videolan.org/git/ffmpeg/nv-codec-headers.git /tmp/nv-codec-headers
    cd /tmp/nv-codec-headers
    make install
    cd -
    rm -rf /tmp/nv-codec-headers
fi
