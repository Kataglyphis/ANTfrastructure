#!/usr/bin/env bash
set -euo pipefail

# setup-torch-venv.sh
# Consolidated torch venv creation and application assembly for Dockerfile.torch.
# Replaces the three separate RUN blocks that duplicate the cross-mode skip guard.

TORCH_APP_MODE="${TORCH_APP_MODE:-all}"
VENV="${VENV:-/opt/venv}"
BUILD_MODE="${BUILD_MODE:-native}"

cross_skip() {
  if [ "${BUILD_MODE}" = "cross" ]; then
    echo "Skipping ${1:-torch step} in pure cross artifact mode"
    return 0
  fi
  return 1
}

setup_torch_venv() {
  cross_skip "torch venv creation" && return 0

  if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
  fi

  local python_bin
  python_bin="$(command -v python3.14 || command -v python3 || true)"
  if [ -z "${python_bin}" ]; then
    python_bin="$(find /usr/local/bin -name 'python3.*' -type f 2>/dev/null | head -1 || true)"
  fi

  test -x "${python_bin}" || {
    echo "Python interpreter not found in the base image" >&2
    ls -1 /usr/local/bin/python* 2>/dev/null || true
    exit 1
  }

  uv venv --seed --python="${python_bin}" "${VENV}"
}

setup_torch_deps() {
  cross_skip "torch environment assembly" && return 0

  apt-get update
  apt-get install -y --no-install-recommends \
    libgirepository-2.0-dev libcairo2-dev libgirepository1.0-dev \
    python3-gi \
    gir1.2-glib-2.0 gir1.2-gtk-3.0 \
    git libopenblas-dev liblapack-dev \
    libgtk-3-dev \
    libglib2.0-dev \
    libjpeg-dev \
    libtiff-dev \
    libpng-dev \
    libsdl2-dev \
    libnotify-dev \
    libsm-dev \
    libxtst-dev \
    freeglut3-dev \
    libxxf86vm-dev \
    libegl1-mesa-dev \
    libglu1-mesa-dev \
    pkg-config \
    libfreetype6-dev \
    libqhull-dev \
    libharfbuzz-dev \
    libfribidi-dev
  rm -rf /var/lib/apt/lists/*
}

setup_torch_app() {
  cross_skip "torch application install" && return 0

  export SKIP_TORCH_TEST_EXTRAS=true
  /opt/scripts/media/final/assemble-torch-app.sh "${TORCH_APP_MODE}"
}

main() {
  setup_torch_venv
  setup_torch_deps
  setup_torch_app
}

main "$@"
