#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

echo "[INFO] Installing LiteRT dependencies..."

target_packages=(
    libopenblas-dev
    liblapack-dev
    libatlas-base-dev
)

# Cross-wheel builds need target Python headers, but the generic libpython3-dev
# package tracks the distro-default target libpython headers without binding the
# install logic to whichever host python happens to be first on PATH.
if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
    target_packages=(libpython3-dev "${target_packages[@]}")
    echo "[INFO] Using target Python headers from libpython3-dev"
fi

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

install_target_packages "${target_packages[@]}"

rm -rf /var/lib/apt/lists/*

echo "[INFO] Using existing Python venv (expected at /opt/python/.venv)..."
export PATH="${HOME}/.local/bin:${PATH}"

# Ensure pip/build tooling is up-to-date
uv pip install --upgrade pip setuptools wheel
uv pip install cython pybind11
uv pip install numpy
