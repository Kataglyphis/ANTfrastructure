#!/usr/bin/env bash
set -euo pipefail

# Load the shared apt/cross helpers via install-deps-preamble.sh (which
# locates and sources cross-env.sh itself in both the container and repo
# layouts), trying the in-container path first and falling back to the repo
# layout for local dev. Fail loudly if one is found but cannot load.
for _dep_env in \
    "/opt/scripts/core/install-deps-preamble.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../01-core/install-deps-preamble.sh"; do
    if [ -f "${_dep_env}" ]; then
        # shellcheck disable=SC1090
        source "${_dep_env}" || { echo "FATAL: cannot load ${_dep_env}" >&2; exit 1; }
        break
    fi
done

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
uv pip install --upgrade pip setuptools wheel
uv pip install cython pybind11
uv pip install numpy
