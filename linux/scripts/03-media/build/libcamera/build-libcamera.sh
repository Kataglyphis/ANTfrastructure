#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"

case "${1:-}" in
  -h|--help)
    echo "Usage: $0"
    echo ""
    echo "Build and install libcamera from source (Meson + GStreamer integration)."
    echo ""
    echo "Environment:"
    echo "  LIBCAMERA_PREFIX  Install prefix (default: /opt/libcamera)"
    echo "  BUILD_MODE=cross   Enable cross-compile flags"
    echo "  TARGET_ARCH        Target architecture (amd64/arm64/riscv64)"
    echo "  USE_CCACHE         Enable ccache (default: true)"
    echo "  USE_LLD            Use lld linker (default: true)"
    exit 0
    ;;
esac

patch_libcamera_riscv64_cross_sources() {
  local common_meson="${LIBCAMERA_SRC}/src/apps/common/meson.build"

  [ -f "${common_meson}" ] || return 0

  local _apply_patch="/opt/scripts/core/apply-patch.sh"
  local _patch_file="/opt/scripts/patches/libcamera/001-riscv64-add-libtiff-dep.patch"
  bash "${_apply_patch}" "${_patch_file}" "${LIBCAMERA_SRC}" \
    "libcamera riscv64 cross: add libtiff to apps_lib dependencies"
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

# Clone (or refresh) the source via the shared 01-core helper — same fetch/
# shallow-clone logic used by the litert/opencv build scripts.
retry 3 10 "libcamera git clone" clone_or_update_repo "${LIBCAMERA_GIT}" "${LIBCAMERA_SRC}"
cd "${LIBCAMERA_SRC}"

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
# Canonical implementation: 01-core/abseil-headers.sh (Critical Fix #2).
# libcamera ships in the same image as LiteRT which installs abseil under
# /usr/local/include/absl, so this install pinpoints the same location.
if ! install_abseil_headers "/usr/local/include"; then
  err "Failed to install abseil-cpp headers for tflite compat"
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

  # GCC 16 emits a FALSE-POSITIVE -Warray-bounds on libcamera's shared std::mutex
  # teardown / logger path. The -Wno-error=array-bounds added to CXXFLAGS above
  # does NOT reach the target compiler in a meson cross build (env C*FLAGS apply
  # only to the build machine), so disable -Werror for ALL cross targets — not
  # just riscv64. Without this a fresh arm64 libcamera compile hard-fails
  # (arm64 previously only "passed" on a cached layer).
  MESON_SETUP_ARGS+=(-Dwerror=false)

  # Generic target headers like elfutils/tiff live in /usr/include, while some
  # arch-specific target headers such as opensslconf.h live in the multiarch
  # include dir. The cross compiler does not reliably search both roots here.
  if [ -d /usr/include ]; then
    append_flag_if_missing CPPFLAGS "-idirafter /usr/include"
    append_flag_if_missing CFLAGS "-idirafter /usr/include"
    append_flag_if_missing CXXFLAGS "-idirafter /usr/include"
  fi
  if [ -n "${cross_triplet}" ] && [ -d "/usr/include/${cross_triplet}" ]; then
    append_cross_idirafter "${cross_triplet}"
  fi

  if command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
    # (-Dwerror=false is now applied for all cross targets above.)
    # Upstream apps_lib compiles dng_writer.cpp (which uses libtiff) when libtiff
    # is found, but omits libtiff from its dependency list, so consumers fail to
    # link. Add the missing dependency.
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

: "${NPROC:=$(media_jobs)}"
ninja -C "${LIBCAMERA_BUILD_DIR}" -j"${NPROC}" -v || { echo "ninja build failed"; exit 1; }

# install (use sudo if not root)
ensure_sudo_or_die
${SUDO_WRAP} ninja -C "${LIBCAMERA_BUILD_DIR}" -j"${NPROC}" install

# update ld cache if possible
${SUDO_WRAP} ldconfig || true

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
