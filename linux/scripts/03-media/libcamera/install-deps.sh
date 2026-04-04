#!/usr/bin/env bash
set -euo pipefail

echo "Installing libcamera build dependencies..."

apt-get update -y
apt-get install -y --no-install-recommends \
    pybind11-dev python3-pybind11 python3-dev \
    libboost-program-options-dev libdrm-dev libexif-dev libjpeg-dev libpng-dev \
    libtiff-dev libavcodec-dev libavdevice-dev libavformat-dev libswresample-dev \
    libunwind-dev libdw-dev \
    libyaml-dev python3-yaml python3-ply python3-jinja2 \
    ninja-build pkg-config libudev-dev libevent-dev libgtest-dev cmake
