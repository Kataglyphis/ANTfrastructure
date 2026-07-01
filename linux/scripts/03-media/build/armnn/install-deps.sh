#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

echo "[INFO] Installing Arm NN dependencies..."

install_deps_preamble build-essential cmake git pkg-config curl unzip ninja-build \
  scons python3 python3-pip

target_packages=(
  libboost-dev libboost-filesystem-dev libboost-program-options-dev
  libboost-system-dev libboost-test-dev
  libprotobuf-dev protobuf-compiler
  libflatbuffers-dev
)

# install_target_packages handles both native and cross builds (it resolves
# :arch suffixes and foreign-arch prep only when cross-compiling).
install_target_packages "${target_packages[@]}"

echo "[INFO] Arm NN dependencies installed"
