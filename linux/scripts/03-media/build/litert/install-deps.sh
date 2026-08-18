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

# LOG5 (2026-08-17): the libatlas-base-dev probe was removed — Ubuntu resolute
# ships no atlas package at all (the probe WARNed on every build, ×3 per run)
# and the build has always proceeded on OpenBLAS/LAPACK anyway.

# NOTE: do NOT `rm -rf /var/lib/apt/lists/*` here — /var/lib/apt is a shared
# BuildKit cache mount in Dockerfile.media, so wiping it only forces the next
# stage's `apt-get update` to re-download every index (and it saves no image
# size, since a cache mount is not a layer).

echo "[INFO] Using existing Python venv (expected at /opt/python/.venv)..."
export PATH="${HOME}/.local/bin:${PATH}"

# Ensure pip/build tooling is up-to-date
# Executor pins per supply-chain audit #18 (inline defaults = versions.env).
uv pip install --upgrade pip "setuptools==${PY_SETUPTOOLS_VERSION:-83.0.0}" "wheel==${PY_WHEEL_VERSION:-0.47.0}"
uv pip install "cython==${PY_CYTHON_VERSION:-3.2.9}" "pybind11==${PY_PYBIND11_VERSION:-3.1.0}"
uv pip install numpy
