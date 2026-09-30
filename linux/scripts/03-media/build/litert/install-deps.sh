#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_install_deps_init "${SCRIPT_DIR}"

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

install_deps_preamble build-essential cmake git pkg-config curl unzip cpio gfortran ninja-build

install_target_packages "${target_packages[@]}"

# Do not wipe /var/lib/apt/lists: it is a BuildKit cache mount, so that saves no size and forces re-downloads.

echo "[INFO] Using existing Python venv (expected at /opt/python/.venv)..."
export PATH="${HOME}/.local/bin:${PATH}"

# Build tools are pinned for the supply chain; inline defaults mirror versions.env.
uv pip install --upgrade pip "setuptools==${PY_SETUPTOOLS_VERSION:-83.0.0}" "wheel==${PY_WHEEL_VERSION:-0.47.0}"
uv pip install "cython==${PY_CYTHON_VERSION:-3.2.9}" "pybind11==${PY_PYBIND11_VERSION:-3.1.0}"
uv pip install numpy
