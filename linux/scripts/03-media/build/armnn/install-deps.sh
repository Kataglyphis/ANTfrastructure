#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_install_deps_init "${SCRIPT_DIR}"

echo "[INFO] Installing Arm NN dependencies..."

install_deps_preamble build-essential cmake git pkg-config curl unzip ninja-build \
  scons python3 python3-pip

target_packages=(
  libboost-dev libboost-filesystem-dev libboost-program-options-dev
  libboost-system-dev libboost-test-dev
  libprotobuf-dev protobuf-compiler
  libflatbuffers-dev
)

install_target_packages "${target_packages[@]}"

# Arm NN links -lgomp, but libgomp1:<arch> ships only libgomp.so.1 and the cross toolchain has no target libgomp.
if is_cross 2>/dev/null; then
  _tri="$(cross_target_triplet 2>/dev/null || true)"
  _libdir="/usr/lib/${_tri}"
  if [ -n "${_tri}" ] && [ -d "${_libdir}" ] && [ ! -e "${_libdir}/libgomp.so" ] && [ -e "${_libdir}/libgomp.so.1" ]; then
    echo "Creating ${_libdir}/libgomp.so -> libgomp.so.1 (libgomp1 ships no dev symlink)"
    ln -sf libgomp.so.1 "${_libdir}/libgomp.so"
  fi
fi

echo "[INFO] Arm NN dependencies installed"
