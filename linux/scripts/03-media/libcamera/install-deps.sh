#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

echo "Installing libcamera build dependencies..."

install_deps_preamble ninja-build pkg-config cmake

target_packages=(
    libboost-program-options-dev libdrm-dev libexif-dev libjpeg-dev libpng-dev
    libtiff-dev libavcodec-dev libavdevice-dev libavformat-dev libswresample-dev
    libunwind-dev libdw-dev libssl-dev libglib2.0-dev libpcre2-dev
    libyaml-dev
    libudev-dev libevent-dev libgtest-dev
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev libepoxy-dev
)

if is_cross && \
   command -v cross_target_arch >/dev/null 2>&1 && \
   [ "$(cross_target_arch)" = "riscv64" ]; then
  # This stage already copies /opt/gstreamer in before libcamera builds, and
  # that prefix provides the target GLib pkg-config metadata and headers. Avoid
  # libglib2.0-dev:riscv64 here because Ubuntu pulls in target python3, whose
  # postinst cannot execute in this build stage.
  _filtered=()
  for _pkg in "${target_packages[@]}"; do
    [ "${_pkg}" = "libglib2.0-dev" ] || [ -z "${_pkg}" ] || _filtered+=("${_pkg}")
  done
  target_packages=("${_filtered[@]}")
fi

install_target_packages "${target_packages[@]}"
