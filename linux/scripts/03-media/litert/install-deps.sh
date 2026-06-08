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
)

if is_cross; then
    if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
        echo "[INFO] Using staged target Python headers from $(cross_target_python_include_dir)"
    else
        echo "[WARN] Target Python ${PYTHON_MAJOR_MINOR:-$(host_python_major_minor 2>/dev/null || echo unknown)} development files are missing for $(cross_target_triplet 2>/dev/null || echo target); skipping LiteRT Python wheel support for this cross build"
    fi
fi

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
    curl \
    unzip \
    gfortran \
    ninja-build

install_target_packages "${target_packages[@]}"

atlas_pkg="libatlas-base-dev"
if is_cross; then
    atlas_pkg_resolved="$(cross_resolve_target_package "${atlas_pkg}")"
else
    atlas_pkg_resolved="${atlas_pkg}"
fi

if cross_package_has_install_candidate "${atlas_pkg_resolved}"; then
    install_target_packages "${atlas_pkg}"
else
    echo "[WARN] ${atlas_pkg_resolved} has no apt install candidate; continuing with OpenBLAS/LAPACK"
fi

rm -rf /var/lib/apt/lists/*

echo "[INFO] Using existing Python venv (expected at /opt/python/.venv)..."
export PATH="${HOME}/.local/bin:${PATH}"

# Ensure pip/build tooling is up-to-date
uv pip install --upgrade pip setuptools wheel
uv pip install cython pybind11
uv pip install numpy
