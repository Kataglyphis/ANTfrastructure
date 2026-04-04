#!/usr/bin/env bash
set -euo pipefail

echo "Installing FFmpeg build dependencies..."

apt-get update -y
apt-get install -y --no-install-recommends \
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
    nasm \
    libass-dev \
    libfreetype6-dev \
    libgnutls28-dev \
    libmp3lame-dev \
    libsdl2-dev \
    libva-dev \
    libvdpau-dev \
    libvorbis-dev \
    libxcb1-dev \
    libxcb-shm0-dev \
    libxcb-xfixes0-dev \
    zlib1g-dev \
    libx264-dev \
    libx265-dev \
    libnuma-dev \
    libvpx-dev \
    libfdk-aac-dev \
    libopus-dev \
    libaom-dev \
    libdav1d-dev \
    libsvtav1-dev \
    libsvtav1enc-dev
