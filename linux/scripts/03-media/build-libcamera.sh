#!/usr/bin/env bash
set -euo pipefail

# Defaults (can be overridden via env vars)
: "${LIBCAMERA_SRC:=/tmp/libcamera}"
: "${LIBCAMERA_BUILD_DIR:=${LIBCAMERA_SRC}/build}"
: "${LIBCAMERA_GIT:=https://git.libcamera.org/libcamera/libcamera.git}"
: "${LIBCAMERA_PREFIX:=/opt/libcamera}"
: "${BUILD_TYPE_LOWER:=release}"

# libcamera-apps (contains libcamera-hello, libcamera-vid, etc.)
# https://www.raspberrypi.com/documentation/computers/camera_software.html#building-libcamera-and-rpicam-apps
: "${LIBCAMERA_APPS_SRC:=/tmp/libcamera-apps}"
: "${LIBCAMERA_APPS_BUILD_DIR:=${LIBCAMERA_APPS_SRC}/build}"
: "${LIBCAMERA_APPS_GIT:=https://github.com/raspberrypi/libcamera-apps.git}"

echo "build-libcamera: src=${LIBCAMERA_SRC} builddir=${LIBCAMERA_BUILD_DIR} prefix=${LIBCAMERA_PREFIX} buildtype=${BUILD_TYPE_LOWER}"

# Prefer the installed helper if available, otherwise source relative to this script
if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  source /usr/local/bin/gstreamer-env.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${SCRIPT_DIR}/../04-runtime/gstreamer-env.sh"
fi

sudo apt update
sudo apt install -y pybind11-dev python3-pybind11 python3-dev \
  libboost-program-options-dev libdrm-dev libexif-dev libjpeg-dev libpng-dev \
  libtiff-dev libavcodec-dev libavdevice-dev libavformat-dev libswresample-dev

# If libcamera already present via pkg-config, skip
if pkg-config --exists libcamera >/dev/null 2>&1; then
  echo "libcamera already available via pkg-config — skipping libcamera build."
  exit 0
fi

# Ensure minimal build deps (apt-based distros)
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    libyaml-dev python3-yaml python3-ply python3-jinja2 \
    ninja-build pkg-config libudev-dev libevent-dev || true
else
  echo "apt-get not found — ensure libcamera build deps are installed manually."
fi

# clone or update
if [ -d "${LIBCAMERA_SRC}/.git" ]; then
  echo "Updating existing libcamera checkout..."
  cd "${LIBCAMERA_SRC}"
  git fetch --depth 1 origin || true
  git checkout origin/HEAD || true
else
  rm -rf "${LIBCAMERA_SRC}"
  git clone --depth 1 "${LIBCAMERA_GIT}" "${LIBCAMERA_SRC}" || { echo "Failed cloning libcamera"; exit 1; }
  cd "${LIBCAMERA_SRC}"
fi

mkdir -p "${LIBCAMERA_BUILD_DIR}"

# configure & build
# NOTE: pycamera (Python bindings) is disabled to avoid conflicts with GStreamer's
# plugin scanner. The libcamerasrc GStreamer element does NOT require Python bindings.
# The Python error "TypeError: PyModule_AddObjectRef() first argument must be a module"
# occurs when gst-plugin-scanner tries to load the pycamera module.
# Ensure the Python that Meson will use has the 'jinja2' module available. Some builds
# install an alternate python interpreter under /root/.local/bin which doesn't see
# system packages provided by 'python3-jinja2'. If missing, install into the interpreter's
# user site via pip so Meson can proceed.
PYTHON_BIN="$(command -v python3 || true)"
if [ -n "${PYTHON_BIN}" ]; then
  if ! "${PYTHON_BIN}" -c 'import jinja2' >/dev/null 2>&1; then
    echo "jinja2 not found for ${PYTHON_BIN}; attempting to install via pip (user site)"
    if "${PYTHON_BIN}" -m pip --version >/dev/null 2>&1; then
      "${PYTHON_BIN}" -m pip install --user jinja2 || true
    else
      echo "pip not available for ${PYTHON_BIN}; installing python3-pip and retrying"
      if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -y || true
        sudo apt-get install -y python3-pip || true
      else
        apt-get update -y || true
        apt-get install -y python3-pip || true
      fi
      "${PYTHON_BIN}" -m pip install --user jinja2 || true
    fi
  fi
fi

meson setup "${LIBCAMERA_BUILD_DIR}" --prefix="${LIBCAMERA_PREFIX}" --buildtype="${BUILD_TYPE_LOWER}" \
  -Dgstreamer=enabled -Dpycamera=enabled -Ddocumentation=disabled || {
    echo "meson setup failed — see ${LIBCAMERA_BUILD_DIR}/meson-logs/meson-log.txt"
    exit 1
  }

ninja -C "${LIBCAMERA_BUILD_DIR}" || { echo "ninja build failed"; exit 1; }

# install (use sudo if not root)
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo ninja -C "${LIBCAMERA_BUILD_DIR}" install
  else
    echo "Not root and sudo missing — cannot install; exiting"
    exit 1
  fi
else
  ninja -C "${LIBCAMERA_BUILD_DIR}" install
fi

# update ld cache if possible
if command -v sudo >/dev/null 2>&1; then
  sudo ldconfig || true
else
  ldconfig || true 2>/dev/null || true
fi

echo "libcamera installed to ${LIBCAMERA_PREFIX} (or already present via pkg-config)."
