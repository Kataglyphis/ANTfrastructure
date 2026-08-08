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
