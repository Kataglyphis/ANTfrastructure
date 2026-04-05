#!/usr/bin/env bash
set -euo pipefail

: "${WITH_PYTHON:=true}"
: "${WITH_JAVA:=false}"
: "${OPENCV_PYTHON_VERSION:=3.14t}"

echo "Installing OpenCV build dependencies..."

apt-get update -y
apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    pkg-config \
    wget \
    unzip \
    libtbb-dev \
    libeigen3-dev \
    libgtk-3-dev \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    libv4l-dev \
    libxvidcore-dev \
    libx264-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libopenexr-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libunwind-dev \
    libdc1394-dev

if [ "${WITH_PYTHON}" = "true" ]; then
    PYVER_MAJOR_MINOR="${OPENCV_PYTHON_VERSION%.*}"
    apt-get install -y --no-install-recommends "python${OPENCV_PYTHON_VERSION}-dev" || true
    apt-get install -y --no-install-recommends python3-dev python3-numpy python3-pip || true
fi

if [ "${WITH_JAVA}" = "true" ]; then
    apt-get install -y --no-install-recommends default-jdk ant || true
fi
