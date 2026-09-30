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
  local _patch_file="/opt/scripts/patches/libcamera/001-apps-add-libtiff-dependency.patch"
  bash "${_apply_patch}" "${_patch_file}" "${LIBCAMERA_SRC}" \
    "libcamera riscv64 cross: add libtiff to apps_lib dependencies"
}

# Upstream compiles libyuv's RVV rows only under clang; see docs/riscv64-rva23-baseline.md#libyuv-rvv
patch_libyuv_rvv_sources() {
  local _libyuv_src="${LIBCAMERA_SRC}/subprojects/libyuv"

  [ -d "${_libyuv_src}" ] || return 0

  bash "/opt/scripts/core/apply-patch.sh" \
    "/opt/scripts/patches/libyuv/001-rvv-build-with-gcc.patch" "${_libyuv_src}" \
    "libyuv: compile the RVV rows with GCC"
}

# Proves the RVV patch reached the shipped library; see docs/riscv64-rva23-baseline.md#libyuv-rvv
verify_libyuv_rvv_rows() {
  local _lib _rows

  command -v cross_target_arch >/dev/null 2>&1 || return 0
  [ "$(cross_target_arch)" = "riscv64" ] || return 0

  _lib="$(find "${LIBCAMERA_PREFIX}" -name libyuv.a -print -quit 2>/dev/null)"
  [ -n "${_lib}" ] || { echo "ERROR: libyuv.a not found under ${LIBCAMERA_PREFIX}" >&2; exit 1; }

  _rows="$(nm -g --defined-only "${_lib}" 2>/dev/null | grep -c -e '_RVV$' || true)"
  [ "${_rows:-0}" -gt 0 ] || { echo "ERROR: libyuv built without RVV rows: ${_lib}" >&2; exit 1; }

  echo "libyuv: ${_rows} RVV rows"
}

: "${LIBCAMERA_SRC:=${TMPDIR:-/tmp}/libcamera-$$}"
: "${LIBCAMERA_BUILD_DIR:=${LIBCAMERA_SRC}/build}"
: "${LIBCAMERA_GIT:=https://git.libcamera.org/libcamera/libcamera.git}"
# Official GitHub mirror, used as a fallback when the upstream edge is down.
: "${LIBCAMERA_GIT_MIRROR:=https://github.com/libcamera-org/libcamera.git}"
: "${LIBCAMERA_PREFIX:=/opt/libcamera}"
: "${BUILD_TYPE_LOWER:=release}"

echo "build-libcamera: src=${LIBCAMERA_SRC} builddir=${LIBCAMERA_BUILD_DIR} prefix=${LIBCAMERA_PREFIX} buildtype=${BUILD_TYPE_LOWER}"

if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  # shellcheck disable=SC1091
  source /usr/local/bin/gstreamer-env.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../../../04-runtime/gstreamer-env.sh"
fi



if pkg-config --exists libcamera >/dev/null 2>&1; then
  echo "libcamera already available via pkg-config — skipping libcamera build."
  exit 0
fi

# git.libcamera.org intermittently serves a default TLS cert, hence the GitHub mirror fallback.
if ! retry 3 10 "libcamera git clone" clone_or_update_repo "${LIBCAMERA_GIT}" "${LIBCAMERA_SRC}" "${LIBCAMERA_VERSION:-}"; then
  echo "[WARN] libcamera primary remote ${LIBCAMERA_GIT} failed; falling back to mirror ${LIBCAMERA_GIT_MIRROR}"
  rm -rf "${LIBCAMERA_SRC}"
  retry 3 10 "libcamera git clone (mirror)" clone_or_update_repo "${LIBCAMERA_GIT_MIRROR}" "${LIBCAMERA_SRC}" "${LIBCAMERA_VERSION:-}"
fi
cd "${LIBCAMERA_SRC}"

mkdir -p "${LIBCAMERA_BUILD_DIR}"

if ! command -v uv >/dev/null 2>&1; then
  echo "Error: 'uv' is required to build libcamera but was not found. Please install Astral 'uv' and re-run the build."
  exit 1
fi

if command -v setup_linux_cross_env >/dev/null 2>&1; then
  setup_linux_cross_env
fi

echo "Using existing Astral uv venv (expected at /opt/python/.venv)"
setup_host_python_environment

# Build tools are pinned for the supply chain; inline defaults mirror versions.env.
uv pip install --upgrade pip \
  "setuptools==${PY_SETUPTOOLS_VERSION:-83.0.0}" \
  "wheel==${PY_WHEEL_VERSION:-0.47.0}" \
  "meson==${PY_MESON_VERSION:-1.11.2}" \
  "ninja==${PY_NINJA_VERSION:-1.13.0}" \
  jinja2 pyyaml ply \
  "pybind11==${PY_PYBIND11_VERSION:-3.1.0}"
UV_RUN_PREFIX=(uv run --)

if [ ! -f /usr/include/gtest/gtest.h ]; then
  if [ -d /usr/src/googletest ]; then
    mkdir -p /tmp/gtest-build
    cmake -S /usr/src/googletest -B /tmp/gtest-build -DCMAKE_BUILD_TYPE=Release
    cmake --build /tmp/gtest-build --target install -j"$(nproc)" || true
    rm -rf /tmp/gtest-build
  fi
fi

# rpi/awb_nn.cpp reaches absl/types/span.h through the tflite headers; same prefix LiteRT uses.
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

  # riscv64 pkg-config drops glib's libdir include, so link glibconfig.h beside the glib headers it does find.
  if [ -d /opt/gstreamer/include/glib-2.0 ] \
     && [ ! -e /opt/gstreamer/include/glib-2.0/glibconfig.h ]; then
    _glibconf="$(find /opt/gstreamer -name glibconfig.h 2>/dev/null | head -1)"
    if [ -n "${_glibconf}" ]; then
      ${SUDO_WRAP:-} ln -sf "${_glibconf}" /opt/gstreamer/include/glib-2.0/glibconfig.h
      echo "Linked glibconfig.h into /opt/gstreamer/include/glib-2.0/ (libdir-include .pc loss workaround)"
    fi
  fi

  # lc-compliance is only a test tool, and cross builds get an incomplete GTest link line for it.
  MESON_SETUP_ARGS+=(-Dlc-compliance=disabled)

  # In a meson cross build env CXXFLAGS reach only the build machine, so GCC 16's false -Warray-bounds needs this.
  MESON_SETUP_ARGS+=(-Dwerror=false)

  # The cross compiler does not reliably search both /usr/include and the multiarch include dir.
  if [ -d /usr/include ]; then
    append_flag_if_missing CPPFLAGS "-idirafter /usr/include"
    append_flag_if_missing CFLAGS "-idirafter /usr/include"
    append_flag_if_missing CXXFLAGS "-idirafter /usr/include"
  fi
  if [ -n "${cross_triplet}" ] && [ -d "/usr/include/${cross_triplet}" ]; then
    append_cross_idirafter "${cross_triplet}"
  fi

  if command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
    # Upstream's apps_lib uses libtiff without depending on it; see docs/upstreamable-patches.md § 4.
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

# meson setup downloads the libyuv subproject; patch it before ninja compiles.
patch_libyuv_rvv_sources

: "${NPROC:=$(media_jobs)}"
ninja -C "${LIBCAMERA_BUILD_DIR}" -j"${NPROC}" -v || { echo "ninja build failed"; exit 1; }

ensure_sudo_or_die
${SUDO_WRAP} ninja -C "${LIBCAMERA_BUILD_DIR}" -j"${NPROC}" install

verify_libyuv_rvv_rows

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
  
  # A branch or bare SHA is not a valid version, so it becomes the local part of 0.0.0+<ref>.
  _lc_wheel_version="${LIBCAMERA_VERSION:-}"
  _lc_wheel_version="${_lc_wheel_version#v}"
  case "${_lc_wheel_version}" in
    [0-9]*.[0-9]*) : ;;                                  # looks like a version
    *) _lc_wheel_version="0.0.0+${_lc_wheel_version:-unpinned}" ;;
  esac
  cat << EOF > "${WHEEL_DIR}/setup.py"
from setuptools import setup, Distribution
class BinaryDistribution(Distribution):
    def has_ext_modules(self): return True
setup(
    name="libcamera",
    version="${_lc_wheel_version}",
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

# --strip-all keeps .dynsym, so dynamic linking is unaffected; MEDIA_STRIP=0 disables it.
declare -F strip_media_prefixes >/dev/null 2>&1 && strip_media_prefixes "${LIBCAMERA_PREFIX}" || true
