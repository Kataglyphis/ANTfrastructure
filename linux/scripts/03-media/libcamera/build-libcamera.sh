#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f /opt/scripts/media/media-build-preamble.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/media/media-build-preamble.sh
  media_build_preamble_init "${SCRIPT_DIR}"
else
  for helper in \
    "/opt/scripts/core/modules.sh" \
    "${SCRIPT_DIR}/../../01-core/modules.sh"; do
    if [ -f "${helper}" ]; then
      # shellcheck disable=SC1090
      source "${helper}"
      source_modules_framework "${SCRIPT_DIR}"
      break
    fi
  done
  source_module cross-env.sh || true
  source_module logging.sh || true
  source_module common.sh || true
  source_module parallelism.sh || true
  source_module python-host.sh || true
  if ! command -v cross_build_is_active >/dev/null 2>&1; then
    cross_build_is_active() { [ "${BUILD_MODE:-native}" = "cross" ]; }
  fi
fi

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
: "${LIBCAMERA_SRC:=${TMPDIR:-/tmp}/libcamera-$$}"
: "${LIBCAMERA_BUILD_DIR:=${LIBCAMERA_SRC}/build}"
: "${LIBCAMERA_GIT:=https://git.libcamera.org/libcamera/libcamera.git}"
: "${LIBCAMERA_PREFIX:=/opt/libcamera}"
: "${BUILD_TYPE_LOWER:=release}"

echo "build-libcamera: src=${LIBCAMERA_SRC} builddir=${LIBCAMERA_BUILD_DIR} prefix=${LIBCAMERA_PREFIX} buildtype=${BUILD_TYPE_LOWER}"

# Prefer the installed helper if available, otherwise source relative to this script
if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  # shellcheck disable=SC1091
  source /usr/local/bin/gstreamer-env.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
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
setup_host_python_environment

# Install build tools into the uv venv
uv pip install --upgrade pip setuptools wheel meson ninja jinja2 pyyaml ply pybind11
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

# Ensure abseil-cpp headers are available for tflite-dependent sources
# (rpi/awb_nn.cpp includes tflite/interpreter.h -> tflite/util.h -> absl/types/span.h).
if [ ! -f /usr/local/include/absl/types/span.h ]; then
  echo "Downloading abseil-cpp headers for tflite compat..."
  local absl_ver="20240722.0"
  local absl_url="https://github.com/abseil/abseil-cpp/archive/refs/tags/${absl_ver}.tar.gz"
  local absl_tar="/tmp/abseil-${absl_ver}.tar.gz"
  mkdir -p /usr/local/include/absl
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 3 "${absl_url}" -o "${absl_tar}" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget --retry-connrefused --timeout=30 -O "${absl_tar}" "${absl_url}" 2>/dev/null
  fi
  if [ -f "${absl_tar}" ]; then
    tar -xzf "${absl_tar}" -C /usr/local/include --strip-components=1 \
      "abseil-cpp-${absl_ver}/absl" 2>/dev/null && rm -f "${absl_tar}"
  fi
  if [ ! -f /usr/local/include/absl/types/span.h ]; then
    echo "ERROR: Failed to install abseil-cpp headers for tflite compat"
    exit 1
  fi
  echo "abseil-cpp headers installed to /usr/local/include/absl/"
fi

MESON_SETUP_ARGS=(
  --prefix="${LIBCAMERA_PREFIX}"
  --buildtype="${BUILD_TYPE_LOWER}"
  -Dgstreamer=enabled
  -Dpycamera=enabled
  -Ddocumentation=disabled
)

# qcam requires native Qt6 which is not available for foreign architectures.
if command -v cross_build_is_active >/dev/null 2>&1 && cross_build_is_active; then
  MESON_SETUP_ARGS+=(-Dqcam=disabled)
fi

compiler_probe="${CXX:-}"
if [ -z "${compiler_probe}" ] && command -v resolve_build_gcc_tool >/dev/null 2>&1; then
  compiler_probe="$(resolve_build_gcc_tool g++ 2>/dev/null || resolve_build_gcc_tool c++ 2>/dev/null || true)"
fi
if [ -z "${compiler_probe}" ] && command -v c++ >/dev/null 2>&1; then
  compiler_probe="$(command -v c++)"
fi
if [ -n "${compiler_probe}" ] && [ -x "${compiler_probe}" ]; then
  compiler_details="$("${compiler_probe}" -v 2>&1 || true)"
  compiler_major="$("${compiler_probe}" -dumpfullversion -dumpversion 2>/dev/null | cut -d. -f1 || true)"
  if [ -n "${compiler_major}" ] && [ "${compiler_major}" -ge 16 ] 2>/dev/null; then
    case "${compiler_details}" in
      *"gcc version "*)
        # GCC 16 misdiagnoses libcamera's shared std::mutex teardown as array-bounds.
        append_flag_if_missing CXXFLAGS "-Wno-error=array-bounds"
        ;;
    esac
  fi
fi

if cross_build_is_active; then
  cross_triplet="$(cross_target_triplet)"

  # lc-compliance is a test application, not a runtime dependency. Cross builds
  # currently pick up an incomplete GTest link line here, so keep the shipped
  # libcamera runtime/plugin artifacts and skip that test tool.
  MESON_SETUP_ARGS+=(-Dlc-compliance=disabled)

  # Generic target headers like elfutils/tiff live in /usr/include, while some
  # arch-specific target headers such as opensslconf.h live in the multiarch
  # include dir. The cross compiler does not reliably search both roots here.
  if [ -d /usr/include ]; then
    append_flag_if_missing CPPFLAGS "-idirafter /usr/include"
    append_flag_if_missing CFLAGS "-idirafter /usr/include"
    append_flag_if_missing CXXFLAGS "-idirafter /usr/include"
  fi
  if [ -n "${cross_triplet}" ] && [ -d "/usr/include/${cross_triplet}" ]; then
    append_flag_if_missing CPPFLAGS "-idirafter /usr/include/${cross_triplet}"
    append_flag_if_missing CFLAGS "-idirafter /usr/include/${cross_triplet}"
    append_flag_if_missing CXXFLAGS "-idirafter /usr/include/${cross_triplet}"
  fi

  if command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
    # GCC 16 still reports a false positive array-bounds warning in libcamera's
    # logger path on the riscv64 cross build; don't treat that warning as fatal.
    MESON_SETUP_ARGS+=(-Dwerror=false)
    patch_libcamera_riscv64_cross_sources
  fi
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

: "${NPROC:=$(compute_jobs_with_mem_cap "" 2000)}"
ninja -C "${LIBCAMERA_BUILD_DIR}" -j"${NPROC}" -v || { echo "ninja build failed"; exit 1; }

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
  ldconfig 2>/dev/null || true
fi

echo "libcamera installed to ${LIBCAMERA_PREFIX} (or already present via pkg-config)."

if cross_build_is_active; then
  if ! command -v cross_target_python_dev_ready >/dev/null 2>&1 || ! cross_target_python_dev_ready; then
    echo "Skipping libcamera Python wheel build in cross mode (target Python not ready)"
    rm -rf "${LIBCAMERA_SRC}" || true
    exit 0
  fi
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

rm -rf "${LIBCAMERA_SRC}" || true
