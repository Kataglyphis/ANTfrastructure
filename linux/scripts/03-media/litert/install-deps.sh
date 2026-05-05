#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

echo "[INFO] Installing LiteRT dependencies..."

apt-get update
install_host_packages \
    build-essential \
    cmake \
    git \
    pkg-config \
    curl \
    unzip \
    gfortran \
    ninja-build

install_target_packages \
    libopenblas-dev \
    liblapack-dev \
    libatlas-base-dev

rm -rf /var/lib/apt/lists/*

echo "[INFO] Using existing Python venv (expected at /opt/python/.venv)..."
export PATH="${HOME}/.local/bin:${PATH}"

# Ensure pip/build tooling is up-to-date
uv pip install --upgrade pip setuptools wheel
uv pip install cython pybind11
uv pip install numpy
