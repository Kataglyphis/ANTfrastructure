#!/usr/bin/env bash
set -euo pipefail

echo "Installing libcamera build dependencies..."

apt-get update -y
apt-get install -y --no-install-recommends \
    libboost-program-options-dev libdrm-dev libexif-dev libjpeg-dev libpng-dev \
    libtiff-dev libavcodec-dev libavdevice-dev libavformat-dev libswresample-dev \
    libunwind-dev libdw-dev \
    libyaml-dev \
    ninja-build pkg-config libudev-dev libevent-dev libgtest-dev cmake
