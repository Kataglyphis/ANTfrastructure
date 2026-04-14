#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Installing LiteRT dependencies..."

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    pkg-config \
    curl \
    unzip \
    gfortran \
    libopenblas-dev \
    liblapack-dev \
    libatlas-base-dev \
    ninja-build

rm -rf /var/lib/apt/lists/*

echo "[INFO] Using existing Python venv (expected at /opt/python/.venv)..."
export PATH="${HOME}/.local/bin:${PATH}"

# Ensure pip/build tooling is up-to-date
uv pip install --upgrade pip setuptools wheel
uv pip install cython pybind11
uv pip install numpy
