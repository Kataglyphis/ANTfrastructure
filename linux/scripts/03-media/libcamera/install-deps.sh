#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

echo "Installing libcamera build dependencies..."

apt-get update -y
install_host_packages ninja-build pkg-config cmake

install_target_packages \
    libboost-program-options-dev libdrm-dev libexif-dev libjpeg-dev libpng-dev \
    libtiff-dev libavcodec-dev libavdevice-dev libavformat-dev libswresample-dev \
    libunwind-dev libdw-dev libssl-dev \
    libyaml-dev \
    libudev-dev libevent-dev libgtest-dev
