#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

# Error handler: print useful logs when a build step fails (meson/ninja/pip)
on_error() {
  local rc=${1:-1}
  echo "ERROR: build failed (exit code ${rc})"
  if [ -f "${LIBCAMERA_BUILD_DIR}/meson-logs/meson-log.txt" ]; then
    echo "----- BEGIN meson-log.txt -----"
    sed -n '1,200p' "${LIBCAMERA_BUILD_DIR}/meson-logs/meson-log.txt" || true
    echo "..."
    sed -n '201,400p' "${LIBCAMERA_BUILD_DIR}/meson-logs/meson-log.txt" || true
    echo "----- END meson-log.txt -----"
  fi
  if [ -f /tmp/uv-pip-install.log ]; then
    echo "----- BEGIN /tmp/uv-pip-install.log -----"
    sed -n '1,200p' /tmp/uv-pip-install.log || true
    echo "----- END /tmp/uv-pip-install.log -----"
  fi
  if [ -d "${LIBCAMERA_BUILD_DIR}" ]; then
    echo "Running: ninja -C \"${LIBCAMERA_BUILD_DIR}\" -v (to show the failing command)"
    ninja -C "${LIBCAMERA_BUILD_DIR}" -v || true
  fi
  exit ${rc}
}
trap 'on_error $?' ERR

append_env_flag() {
  local var_name="$1"
  local flag="$2"
  local current="${!var_name:-}"

  case " ${current} " in
    *" ${flag} "*) return 0 ;;
  esac

  export "${var_name}=${current:+${current} }${flag}"
}

patch_libcamera_riscv64_cross_sources() {
  local common_meson="${LIBCAMERA_SRC}/src/apps/common/meson.build"

  [ -f "${common_meson}" ] || return 0

  if grep -Fq "dependencies : [libcamera_public, libtiff])" "${common_meson}"; then
    return 0
  fi

  # Upstream builds dng_writer.cpp into apps_lib when libtiff is found, but the
  # static library itself only depends on libcamera_public. Native builds still
  # see /usr/include, while riscv64 cross builds need libtiff's pkg-config
  # include flags on apps_lib too.
  if grep -Fq "dependencies : [libcamera_public])" "${common_meson}"; then
    sed -i "s/dependencies : \[libcamera_public\])/dependencies : [libcamera_public, libtiff])/" "${common_meson}"
    echo "Patched libcamera apps_lib to propagate libtiff includes for riscv64 cross builds"
  fi
}

# Defaults (can be overridden via env vars)
: "${LIBCAMERA_SRC:=/tmp/libcamera}"
: "${LIBCAMERA_BUILD_DIR:=${LIBCAMERA_SRC}/build}"
: "${LIBCAMERA_GIT:=https://git.libcamera.org/libcamera/libcamera.git}"
: "${LIBCAMERA_PREFIX:=/opt/libcamera}"
: "${BUILD_TYPE_LOWER:=release}"

# libcamera-apps (contains libcamera-hello, libcamera-vid, etc.)
: "${LIBCAMERA_APPS_SRC:=/tmp/libcamera-apps}"
: "${LIBCAMERA_APPS_BUILD_DIR:=${LIBCAMERA_APPS_SRC}/build}"
: "${LIBCAMERA_APPS_GIT:=https://github.com/raspberrypi/libcamera-apps.git}"

echo "build-libcamera: src=${LIBCAMERA_SRC} builddir=${LIBCAMERA_BUILD_DIR} prefix=${LIBCAMERA_PREFIX} buildtype=${BUILD_TYPE_LOWER}"

# Prefer the installed helper if available, otherwise source relative to this script
if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  source /usr/local/bin/gstreamer-env.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${SCRIPT_DIR}/../../04-runtime/gstreamer-env.sh"
fi



# If libcamera already present via pkg-config, skip
if pkg-config --exists libcamera >/dev/null 2>&1; then
  echo "libcamera already available via pkg-config — skipping libcamera build."
  exit 0
fi

# Ensure minimal build deps (apt-based distros)
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
if ! command -v uv >/dev/null 2>&1; then
  echo "Error: 'uv' is required to build libcamera but was not found. Please install Astral 'uv' and re-run the build."
  exit 1
fi

if command -v setup_linux_cross_env >/dev/null 2>&1; then
  setup_linux_cross_env
fi

echo "Using existing Astral uv venv (expected at /opt/python/.venv)"
HOST_PYTHON="$(host_python_bin)"
export PYTHON_EXECUTABLE="${HOST_PYTHON}" \
       Python_EXECUTABLE="${HOST_PYTHON}" \
       Python3_EXECUTABLE="${HOST_PYTHON}"

# Install build tools into the uv venv; retry with --break-system-packages on PEP-668 failures
if ! uv pip install --upgrade pip setuptools wheel 2>/tmp/uv-pip-install.log; then
  echo "pip install into uv venv failed; retrying with --break-system-packages"
  uv pip install --upgrade pip setuptools wheel || { echo "pip install (with override) failed; see /tmp/uv-pip-install.log"; cat /tmp/uv-pip-install.log || true; exit 1; }
fi
if ! uv pip install --upgrade meson ninja jinja2 2>/tmp/uv-pip-install.log; then
  echo "pip install meson/ninja/jinja2 failed; retrying with --break-system-packages"
  uv pip install --upgrade meson ninja jinja2 || { echo "pip install meson/ninja/jinja2 (with override) failed; see /tmp/uv-pip-install.log"; cat /tmp/uv-pip-install.log || true; exit 1; }
fi
if ! uv pip install --upgrade pyyaml 2>/tmp/uv-pip-install.log; then
  echo "pip install pyyaml failed; retrying with --break-system-packages"
  uv pip install --upgrade pyyaml || { echo "pip install pyyaml (with override) failed; see /tmp/uv-pip-install.log"; cat /tmp/uv-pip-install.log || true; exit 1; }
fi
if ! uv pip install --upgrade ply 2>/tmp/uv-pip-install.log; then
  echo "pip install ply failed; retrying with --break-system-packages"
  uv pip install --upgrade ply || { echo "pip install ply (with override) failed; see /tmp/uv-pip-install.log"; cat /tmp/uv-pip-install.log || true; exit 1; }
fi
if ! uv pip install --upgrade pybind11 2>/tmp/uv-pip-install.log; then
  echo "pip install pybind11 failed; retrying with --break-system-packages"
  uv pip install --upgrade pybind11 || { echo "pip install pybind11 (with override) failed; see /tmp/uv-pip-install.log"; cat /tmp/uv-pip-install.log || true; exit 1; }
fi
UV_RUN_PREFIX=(uv run --)

# Ensure GoogleTest is available
if [ ! -f /usr/include/gtest/gtest.h ]; then
  if [ -d /usr/src/googletest ]; then
    mkdir -p /tmp/gtest-build
    cmake -S /usr/src/googletest -B /tmp/gtest-build -DCMAKE_BUILD_TYPE=Release
    cmake --build /tmp/gtest-build --target install -j"$(nproc)" || true
    rm -rf /tmp/gtest-build
  fi
fi

MESON_SETUP_ARGS=(
  --prefix="${LIBCAMERA_PREFIX}"
  --buildtype="${BUILD_TYPE_LOWER}"
  -Dgstreamer=enabled
  -Dpycamera=enabled
  -Ddocumentation=disabled
)

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
  # Generic target headers like elfutils/tiff live in /usr/include, while some
  # arch-specific target headers such as opensslconf.h live in the multiarch
  # include dir. This container's riscv64 cross compiler doesn't pick those up
  # reliably on its own. GCC 16 also reports a false positive array-bounds
  # warning in libcamera's logger path; don't treat that warning as fatal.
  MESON_SETUP_ARGS+=(-Dwerror=false)
  cross_triplet="$(cross_target_triplet)"
  if [ -d /usr/include ]; then
    append_env_flag CPPFLAGS "-idirafter /usr/include"
    append_env_flag CFLAGS "-idirafter /usr/include"
    append_env_flag CXXFLAGS "-idirafter /usr/include"
  fi
  if [ -n "${cross_triplet}" ] && [ -d "/usr/include/${cross_triplet}" ]; then
    append_env_flag CPPFLAGS "-idirafter /usr/include/${cross_triplet}"
    append_env_flag CFLAGS "-idirafter /usr/include/${cross_triplet}"
    append_env_flag CXXFLAGS "-idirafter /usr/include/${cross_triplet}"
  fi
  patch_libcamera_riscv64_cross_sources
fi

if command -v append_meson_cross_flags >/dev/null 2>&1; then
  append_meson_cross_flags MESON_SETUP_ARGS
fi
if command -v append_meson_native_flags >/dev/null 2>&1; then
  append_meson_native_flags MESON_SETUP_ARGS
fi

if ! "${UV_RUN_PREFIX[@]}" meson setup "${LIBCAMERA_BUILD_DIR}" "${MESON_SETUP_ARGS[@]}"; then
    echo "meson setup failed — see ${LIBCAMERA_BUILD_DIR}/meson-logs/meson-log.txt"
    exit 1
fi

ninja -C "${LIBCAMERA_BUILD_DIR}" -v || { echo "ninja build failed"; exit 1; }

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

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled; then
  echo "Skipping libcamera Python wheel build in cross mode"
  rm -rf "${LIBCAMERA_SRC}" "${LIBCAMERA_APPS_SRC}" /tmp/uv-pip-install.log || true
  exit 0
fi

echo "Attempting to create libcamera Python wheel"
PYCAMERA_DIR=$(find "${LIBCAMERA_PREFIX}" -type d -name "libcamera" | grep "site-packages" | head -n 1 || true)
if [ -n "${PYCAMERA_DIR}" ] && [ -d "${PYCAMERA_DIR}" ]; then
  echo "Found pycamera at ${PYCAMERA_DIR}. Building wheel..."
  mkdir -p "${LIBCAMERA_PREFIX}/wheels"
  WHEEL_DIR=$(mktemp -d)
  cp -r "${PYCAMERA_DIR}" "${WHEEL_DIR}/"
  
  cat << 'EOF' > "${WHEEL_DIR}/setup.py"
from setuptools import setup, Distribution
class BinaryDistribution(Distribution):
    def has_ext_modules(self): return True
setup(
    name="libcamera",
    version="0.3.0",
    packages=["libcamera"],
    package_data={"libcamera": ["*.so"]},
    include_package_data=True,
    distclass=BinaryDistribution,
)
EOF
  pushd "${WHEEL_DIR}" >/dev/null
  "${HOST_PYTHON}" -m pip wheel . -w "${LIBCAMERA_PREFIX}/wheels" || echo "Failed to build wheel"
  popd >/dev/null
  rm -rf "${WHEEL_DIR}"
else
  echo "pycamera site-packages directory not found."
fi

rm -rf "${LIBCAMERA_SRC}" "${LIBCAMERA_APPS_SRC}" /tmp/uv-pip-install.log || true
