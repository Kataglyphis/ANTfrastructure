#!/usr/bin/env bash
set -euo pipefail

# Builds GStreamer and all its plugins from source; USE_CCACHE, USE_SCCACHE and USE_LLD default to true.

_SETUP_GST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SETUP_GST_DIR}/../../../core/common.sh"
media_common_init "${_SETUP_GST_DIR}"

if cross_build_is_active && \
   command -v cross_target_arch >/dev/null 2>&1; then
    case "$(cross_target_arch)" in
        arm64|riscv64)
            # Meson's C++ dependency probes (GLib's builtin iconv) fail under lld here when g++ links libstdc++.
            export USE_LLD=false
            ;;
    esac
fi

# Meson's C++ stdlib probe fails on GCC 16's cross libstdc++ headers; defining _LIBCPP_VERSION satisfies it without changing the library.
if cross_build_is_active && \
   command -v cross_target_arch >/dev/null 2>&1; then
    case "$(cross_target_arch)" in
        arm64|riscv64)
            export CXXFLAGS="${CXXFLAGS:-} -D_LIBCPP_VERSION=20220101"
            ;;
    esac
fi

# media_common_init ran setup_lld_linker before the cross USE_LLD=false above, so run it again.
setup_sccache
setup_lld_linker

# Positional arg, then the value forwarded from versions.env; the literal is a last resort that must match versions.env.
GSTREAMER_VERSION="${1:-${GSTREAMER_VERSION:-1.29.2}}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"
setup_host_python_environment
: "${GSTREAMER_ENABLE_PYTHON_BINDINGS:=true}"

if cross_build_is_active && \
   command -v cross_target_python_dev_ready >/dev/null 2>&1 && \
   ! cross_target_python_dev_ready; then
  GSTREAMER_ENABLE_PYTHON_BINDINGS=false
  echo "Target Python development files are not staged for $(cross_target_triplet 2>/dev/null || echo target); disabling gst-python in cross mode"
fi

export GSTREAMER_ENABLE_PYTHON_BINDINGS

append_meson_arg() {
  local arg="$1"
  # Space-padded on both sides, so this matches whole tokens only, never a prefix.
  case " ${EXTRA_MESON_ARGS} " in
    *" ${arg} "*)
      ;;
    *)
      EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} ${arg}"
      ;;
  esac
}

# Called again after the monorepo setup so these args survive an externally supplied MESON_ARGS.
enforce_gst_rs_meson_args() {
  append_meson_arg "-Dpython-exe=${HOST_PYTHON}"
  if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS}" = "true" ]; then
    append_meson_arg "-Dgst-python:python-exe=${HOST_PYTHON}"
  fi
  # auto skips a plugin whose system dep is missing; enabled aborts meson on the first one (webrtcbin2 needs unpackaged rice-proto).
  if [ "${GST_RS_BUILD_ALL:-true}" = "true" ]; then
    append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=auto"
  else
    append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
  fi
  [ "${GST_RS_BUILD_ALL:-true}" = "true" ] || append_meson_arg "-Dgst-plugins-rs:burn=disabled"
  # whisper stays enabled unless explicitly disabled via MESON_ARGS.
  append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"
}

resolve_host_gcc_for_cargo() {
  resolve_host_compiler_for_lang c
}

prepare_cargo_host_linker_wrapper() {
  local compiler="$1"
  prepare_host_compiler_wrapper "${compiler}" host-gcc "${GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR:-/tmp/gstreamer-cargo-host-toolchain}"
}

resolve_host_gxx_for_cargo() {
  resolve_host_compiler_for_lang cxx
}

prepare_cargo_host_cxx_wrapper() {
  local compiler="$1"
  prepare_host_compiler_wrapper "${compiler}" host-g++ "${GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR:-/tmp/gstreamer-cargo-host-toolchain}"
}

prepare_host_cargo_toolchain_env() {
  local build_rust_env="X86_64_UNKNOWN_LINUX_GNU"
  local build_rust_lower="x86_64_unknown_linux_gnu"
  local cargo_host_cc=""
  local cargo_host_linker=""
  local cargo_host_cxx=""
  local cargo_host_cxx_wrapper=""

  if ! cross_build_is_active; then
    return 0
  fi

  if command -v cross_build_upper_rust >/dev/null 2>&1; then
    build_rust_env="$(cross_build_upper_rust 2>/dev/null || true)"
  fi
  if command -v cross_build_lower_rust >/dev/null 2>&1; then
    build_rust_lower="$(cross_build_lower_rust 2>/dev/null || true)"
  fi
  [ -n "${build_rust_env}" ] || build_rust_env="X86_64_UNKNOWN_LINUX_GNU"
  [ -n "${build_rust_lower}" ] || build_rust_lower="x86_64_unknown_linux_gnu"

  # No PATH scrub: /opt/cross-bin holds only triplet-prefixed names, so host build scripts already find the native cc.

  cargo_host_cc="$(resolve_host_gcc_for_cargo)"
  if [ -n "${cargo_host_cc}" ]; then
    cargo_host_linker="$(prepare_cargo_host_linker_wrapper "${cargo_host_cc}")"
    export "CARGO_TARGET_${build_rust_env}_LINKER=${cargo_host_linker}"
    export "CC_${build_rust_lower}=${cargo_host_linker}"
    export HOST_CC="${cargo_host_linker}"
  fi

  cargo_host_cxx="$(resolve_host_gxx_for_cargo)"
  if [ -n "${cargo_host_cxx}" ]; then
    cargo_host_cxx_wrapper="$(prepare_cargo_host_cxx_wrapper "${cargo_host_cxx}")"
    export "CXX_${build_rust_lower}=${cargo_host_cxx_wrapper}"
    export HOST_CXX="${cargo_host_cxx_wrapper}"
  fi

  # Without a target-triple linker cargo links the cross cdylibs with the host cc and fails "incompatible with elf64-x86-64".
  local target_rust_env="" target_rust_lower="" target_cc="" target_cxx=""
  if command -v cross_target_upper_rust >/dev/null 2>&1; then
    target_rust_env="$(cross_target_upper_rust 2>/dev/null || true)"
  fi
  if command -v cross_target_lower_rust >/dev/null 2>&1; then
    target_rust_lower="$(cross_target_lower_rust 2>/dev/null || true)"
  fi
  if [ -n "${target_rust_env}" ] && command -v resolve_cross_cc_cxx_for_arch >/dev/null 2>&1; then
    local _tgt_arch
    _tgt_arch="$(cross_target_arch 2>/dev/null || true)"
    target_cc="$( resolve_cross_cc_cxx_for_arch "${_tgt_arch}" >/dev/null 2>&1 && printf '%s' "${CC:-}" )"
    target_cxx="$( resolve_cross_cc_cxx_for_arch "${_tgt_arch}" >/dev/null 2>&1 && printf '%s' "${CXX:-}" )"
    if export_cargo_target_linker "${target_rust_env}" "${target_rust_lower}" "${target_cc}" "${target_cxx}"; then
      echo "Cross cargo: target linker ${target_cc} (CARGO_TARGET_${target_rust_env}_LINKER)"
    else
      echo "WARN: could not resolve cross gcc for target; Rust target crates may fail to link" >&2
    fi
  fi
}

_gst_xpy_check_meson() {
  local meson_version=""
  meson_version="$(uv run meson --version 2>/dev/null || meson --version 2>/dev/null || true)"
  if ! "${HOST_PYTHON}" - "${meson_version}" <<'PY'
import re
import sys

version = sys.argv[1].strip()
match = re.match(r'^(\d+)\.(\d+)\.(\d+)', version)
if not match:
    raise SystemExit(1)

current = tuple(int(part) for part in match.groups())
raise SystemExit(0 if current >= (1, 10, 0) else 1)
PY
  then
    echo "Meson ${meson_version:-unknown} does not support python.build_config; continuing without cross Python ABI metadata"
    return 1
  fi
  return 0
}

_gst_xpy_resolve_target_paths() {
  if command -v cross_target_triplet >/dev/null 2>&1; then
    target_triplet="$(cross_target_triplet)"
  else
    target_triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi
  if [ -z "${target_triplet}" ]; then
    echo "Could not determine cross target triplet for Meson python.build_config"
    return 1
  fi

  if command -v cross_target_python_include_dir >/dev/null 2>&1; then
    target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
  fi
  if command -v cross_target_python_library >/dev/null 2>&1; then
    target_python_library="$(cross_target_python_library 2>/dev/null || true)"
  fi
  if command -v cross_target_python_pkgconfig_dir >/dev/null 2>&1; then
    target_python_pkgconfig_dir="$(cross_target_python_pkgconfig_dir 2>/dev/null || true)"
  fi
  # The resolvers can return the host's /usr/local Python; use the staged cross Python instead.
  if [ "${target_python_include}" = "/usr/local/include/python3.14" ] && \
     [ -n "${target_triplet}" ]; then
    local _cross_arch="${target_triplet%%-*}"
    local _cross_stage="/opt/python-cross/${_cross_arch}/usr/local"
    if [ -d "${_cross_stage}" ]; then
      target_python_include="${_cross_stage}/include/python3.14"
      target_python_library="${_cross_stage}/lib/libpython3.14.so"
      target_python_pkgconfig_dir="${_cross_stage}/lib/pkgconfig"
    fi
  fi
  if [ -z "${target_python_include}" ] || [ -z "${target_python_library}" ] || [ -z "${target_python_pkgconfig_dir}" ]; then
    echo "Target Python development files are not ready for ${target_triplet}; skipping Meson python.build_config generation"
    return 1
  fi
  return 0
}

_gst_xpy_write_config() {
  local python_build_config=""
  python_build_config="/tmp/meson-python-build-config-${target_triplet}.json"
  if "${HOST_PYTHON}" - "${python_build_config}" "${target_triplet}" "${target_python_include}" "${target_python_library}" "${target_python_pkgconfig_dir}" <<'PY'
import json
import pathlib
import re
import sys
import sysconfig

output_path = pathlib.Path(sys.argv[1])
target_triplet = sys.argv[2]
include_dir = pathlib.Path(sys.argv[3])
dynamic_libpython = pathlib.Path(sys.argv[4])
pkgconfig_path = sys.argv[5]
target_arch = target_triplet.split('-', 1)[0]

language_version = f"{sys.version_info.major}.{sys.version_info.minor}"
if not include_dir.is_dir():
    raise SystemExit(f"Could not determine Python include directory for {language_version}")

cache_tag = getattr(sys.implementation, 'cache_tag', '') or f"cpython-{sys.version_info.major}{sys.version_info.minor}"
flag_match = re.match(r'^cpython-\d+([a-z]*)$', cache_tag)
abi_flags = list(flag_match.group(1)) if flag_match else []

platform = sysconfig.get_platform() or f"linux-{target_arch}"
host_multiarch = sysconfig.get_config_var('MULTIARCH') or ''
host_arch = host_multiarch.split('-', 1)[0] if host_multiarch else ''
if host_arch and platform.endswith(host_arch):
    platform = f"{platform[:-len(host_arch)]}{target_arch}"
elif not platform.startswith('linux-'):
    platform = f"linux-{target_arch}"

libpython = {
    'link_extensions': False,
}
if dynamic_libpython.exists():
    libpython['dynamic'] = str(dynamic_libpython)

impl_version = getattr(sys.implementation, 'version', sys.version_info)
# Compute base_prefix from the include dir: include/pythonX.Y -> prefix
cross_prefix = str(include_dir.parent.parent)
data = {
    'schema_version': '1.0',
    'base_prefix': cross_prefix,
    'platform': platform,
    'language': {
        'version': language_version,
    },
    'implementation': {
        'name': sys.implementation.name,
        'version': {
            'major': impl_version.major,
            'minor': impl_version.minor,
            'micro': impl_version.micro,
            'releaselevel': impl_version.releaselevel,
            'serial': impl_version.serial,
        },
        'cache_tag': cache_tag,
        '_multiarch': target_triplet,
    },
    'abi': {
        'flags': abi_flags,
        'extension_suffix': f'.{cache_tag}-{target_triplet}.so',
        'stable_abi_suffix': '.abi3.so',
    },
    'libpython': libpython,
    'c_api': {
        'headers': str(include_dir),
        'pkgconfig_path': pkgconfig_path,
    },
}

output_path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
PY
  then
    CROSS_PYTHON_BUILD_CONFIG="${python_build_config}"
    export CROSS_PYTHON_BUILD_CONFIG
    echo "Generated Meson python.build_config for ${target_triplet}: ${CROSS_PYTHON_BUILD_CONFIG}"
  else
    rm -f "${python_build_config}" 2>/dev/null || true
    echo "WARNING: Failed to generate Meson python.build_config for ${target_triplet}; continuing without it"
  fi
}

prepare_cross_python_build_config() {
  local target_triplet=""
  local target_python_include=""
  local target_python_library=""
  local target_python_pkgconfig_dir=""

  CROSS_PYTHON_BUILD_CONFIG=""
  export CROSS_PYTHON_BUILD_CONFIG

  if ! cross_build_is_active; then
    return 0
  fi

  if ! _gst_xpy_check_meson; then
    return 0
  fi

  if ! _gst_xpy_resolve_target_paths; then
    return 0
  fi

  _gst_xpy_write_config
}

# MESON_ARGS wins verbatim over the fourth positional arg.
if [ -n "${MESON_ARGS:-}" ]; then
  :
  EXTRA_MESON_ARGS="${MESON_ARGS}"
elif [ -z "${EXTRA_MESON_ARGS}" ]; then
  :
  # No auto_plugin_features here: enforce_gst_rs_meson_args picks auto or enabled from GST_RS_BUILD_ALL.
  EXTRA_MESON_ARGS="-Dgst-plugins-rs:sodium-source=built-in"
  # burn pulls heavy ML deps, so it is off unless GST_RS_BUILD_ALL leaves it to auto_plugin_features.
  [ "${GST_RS_BUILD_ALL:-true}" = "true" ] || EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} -Dgst-plugins-rs:burn=disabled"
fi

# Always enforce these, even if MESON_ARGS was supplied externally.
enforce_gst_rs_meson_args

# GCC 16 rejects vulkan_xcb.h with the XCB headers; an empty vulkan-windowing drops the WSI backends a container does not need.
append_meson_arg "-Dgst-plugins-bad:vulkan-windowing="

BUILD_TYPE_LOWER="${BUILD_TYPE,,}"

# /usr/local/bin first, so tools that shell out by name get the cross g-ir-scanner and ldd shims.
export PATH="/usr/local/sbin:/usr/local/bin:${HOME}/.local/bin:${PATH}"

# The installed gstreamer-env.sh first, else the repo copy.
if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  :
  # shellcheck disable=SC1091
  source /usr/local/bin/gstreamer-env.sh
else
  :
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../../../../04-runtime/gstreamer-env.sh"
fi

# Debug and logging helpers
LOG_DIR="${TMPDIR:-/tmp}/gstreamer-build-logs-$$-$(date +%s)"

dump_debug_info() {
  echo "=== GStreamer build debug info ==="
  echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Host: $(uname -a)"
  echo "GStreamer version: ${GSTREAMER_VERSION:-1.29.2}"
  echo "GStreamer prefix: ${GSTREAMER_PREFIX:-/opt/gstreamer}"
  echo "Build type: ${BUILD_TYPE:-unset}"
  echo "MESON_WRAP_MODE: ${MESON_WRAP_MODE:-unset}"
  echo "Environment snapshot:"
  env | sort
  echo "--- Resource usage ---"
  free -h || true
  df -h || true
  ulimit -a || true
  echo "--- Tool versions ---"
  printf 'host python: %s\n' "${HOST_PYTHON:-unresolved}" || true
  if [ -n "${HOST_PYTHON:-}" ]; then "${HOST_PYTHON}" --version 2>&1 || true; fi
  which pip  || true; pip --version 2>&1 || true
  which meson || true; meson --version 2>&1 || true
  which ninja || true; ninja --version 2>&1 || true
  which rustc || true; rustc --version 2>&1 || true
  which cargo || true; cargo --version 2>&1 || true
  which clang || true; clang --version 2>&1 || true
  which cc || true; cc --version 2>&1 || true
  which pkg-config || true; pkg-config --version 2>&1 || true
  echo "=== end debug info ==="
}

save_logs() {
  echo "Collecting logs to ${LOG_DIR}..."
  cp -a /tmp/meson-compile.log "${LOG_DIR}/" 2>/dev/null || true
  cp -a builddir/meson-logs/* "${LOG_DIR}/" 2>/dev/null || true
  cp -a /tmp/meson-setup.log "${LOG_DIR}/" 2>/dev/null || true
  cp -a /tmp/meson-setup-fallback.log "${LOG_DIR}/" 2>/dev/null || true
  cp -a /tmp/gstreamer-debug-info.log "${LOG_DIR}/" 2>/dev/null || true
  ls -la "${LOG_DIR}" || true
  echo "Logs preserved in ${LOG_DIR}"
}

if [ "${GSTREAMER_DEBUG_LOGS:-false}" = "true" ]; then
  mkdir -p "${LOG_DIR}"
  trap save_logs EXIT
fi

# Meson and Ninja in the existing venv

ensure_sudo_or_die
${SUDO_WRAP} mkdir -p "${GSTREAMER_PREFIX}"
${SUDO_WRAP} chown -R "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}"

echo "Using existing Python venv (expected at /opt/python/.venv)..."

# The inline defaults must match versions.env.
uv pip install -U pip "setuptools==${PY_SETUPTOOLS_VERSION:-83.0.0}" "wheel==${PY_WHEEL_VERSION:-0.47.0}"
uv pip install -U "meson==${PY_MESON_VERSION:-1.11.2}" "ninja==${PY_NINJA_VERSION:-1.13.0}"
# meson 1.12 cannot find g-i's glib subproject in the riscv64 cross introspection build; re-bump once meson or g-i fix it (MESON-GI).
if command -v cross_target_arch >/dev/null 2>&1 \
   && [ "$(cross_target_arch 2>/dev/null || true)" = "riscv64" ]; then
  echo "riscv64 cross: pinning meson 1.11.2 for the g-i glib-subproject resolution (MESON-GI)"
  uv pip install "meson==1.11.2"
fi
# pycairo (for the pygobject fallback) only with Python bindings: the cross CC/CXX leak into uv and break Meson in cross builds.
if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS}" = "true" ]; then
  HOST_MULTIARCH="$(dpkg-architecture -q DEB_BUILD_MULTIARCH 2>/dev/null || dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  HOST_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
  if [ -n "${HOST_MULTIARCH}" ]; then
    HOST_PKG_CONFIG_LIBDIR="/usr/lib/${HOST_MULTIARCH}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
  else
    HOST_PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
  fi
  if python3 -c 'import cairo' 2>/dev/null; then
    echo "pycairo already installed (system package), skipping pip upgrade"
  else
    env \
      PKG_CONFIG_ALLOW_CROSS= \
      PKG_CONFIG_SYSROOT_DIR= \
      PKG_CONFIG_LIBDIR="${HOST_PKG_CONFIG_LIBDIR}" \
      PKG_CONFIG_PATH="${HOST_PKG_CONFIG_PATH}" \
      SCCACHE_DISABLE=1 \
      uv pip install -U pycairo
  fi
else
  echo "Python bindings disabled, skipping pycairo installation"
fi

# Optional: verify
meson --version
ninja --version

# Build GStreamer from the monorepo
if [ -n "${MESON_ARGS:-}" ]; then
  EXTRA_MESON_ARGS="${MESON_ARGS}"
  # The reset drops the vulkan-windowing arg appended earlier, so re-apply it.
  append_meson_arg "-Dgst-plugins-bad:vulkan-windowing="
fi

if [ -f "${_SETUP_GST_DIR}/patch-gstreamer-sources.sh" ]; then
  # shellcheck disable=SC1090
  source "${_SETUP_GST_DIR}/patch-gstreamer-sources.sh"
fi

if [ -f "${_SETUP_GST_DIR}/build-gst-plugins-rs.sh" ]; then
  # shellcheck disable=SC1090
  source "${_SETUP_GST_DIR}/build-gst-plugins-rs.sh"
else
  echo "ERROR: Missing helper: ${_SETUP_GST_DIR}/build-gst-plugins-rs.sh" >&2
  exit 1
fi

if [ -f "${_SETUP_GST_DIR}/build-gstreamer-monorepo.sh" ]; then
  # shellcheck disable=SC1090
  source "${_SETUP_GST_DIR}/build-gstreamer-monorepo.sh"
else
  echo "ERROR: Missing helper: ${_SETUP_GST_DIR}/build-gstreamer-monorepo.sh" >&2
  exit 1
fi

# Enforce the gst-plugins-rs args again here so they survive external MESON_ARGS.
enforce_gst_rs_meson_args

# On every arch: gst-ptp-helper is a setuid-root binary useless in a container, and its cross link fails on empty -C link-arg=.
append_meson_arg "-Dgstreamer:ptp-helper=disabled"

echo "=========================================="
echo "Building GStreamer ${GSTREAMER_VERSION}"
echo "Prefix: ${GSTREAMER_PREFIX}"
echo "Build Type: ${BUILD_TYPE_LOWER}"
echo "=========================================="

if [ -x "${GSTREAMER_PREFIX}/bin/gst-launch-1.0" ] && [ "${FORCE_REBUILD:-0}" != "1" ]; then
  installed_ver="$("${GSTREAMER_PREFIX}/bin/gst-launch-1.0" --version 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || true)"
  if [ "${installed_ver}" = "${GSTREAMER_VERSION}" ]; then
    echo "GStreamer ${GSTREAMER_VERSION} already installed at ${GSTREAMER_PREFIX}, skipping build"
    echo "Set FORCE_REBUILD=1 to force rebuild"
    exit 0
  fi
fi

mkdir -p "${GSTREAMER_PREFIX}"
${SUDO_WRAP} chown "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}" 2>/dev/null || true
# do not write directly into tmp; its reserved for apt
BUILD_DIR="/opt/tmp/gstreamer-build-$$"
${SUDO_WRAP} mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
${SUDO_WRAP} chown -R "$(id -u):$(id -g)" "${BUILD_DIR}" 2>/dev/null || true

# GitHub first, the canonical gitlab.freedesktop.org as fallback.
GST_GIT_URL="https://github.com/GStreamer/gstreamer.git"
GST_GIT_FALLBACK="https://gitlab.freedesktop.org/gstreamer/gstreamer.git"
if command -v clone_or_update_repo >/dev/null 2>&1; then
  retry 3 10 "GStreamer git clone" clone_or_update_repo "${GST_GIT_URL}" "${BUILD_DIR}/gstreamer" "${GSTREAMER_VERSION}" \
    || { rm -rf "${BUILD_DIR}/gstreamer"
         retry 2 10 "GStreamer git clone (fallback)" clone_or_update_repo "${GST_GIT_FALLBACK}" "${BUILD_DIR}/gstreamer" "${GSTREAMER_VERSION}"; }
  cd "${BUILD_DIR}/gstreamer"
elif [ -d "gstreamer" ]; then
  echo "Updating existing GStreamer repository..."
  cd gstreamer
  git fetch origin --tags 2>/dev/null || git fetch --unshallow origin 2>/dev/null || true
  git checkout "${GSTREAMER_VERSION}" || {
    echo "Version ${GSTREAMER_VERSION} not found in shallow clone; re-cloning..."
    cd "${BUILD_DIR}"
    rm -rf gstreamer
    git clone --depth 1 --branch "${GSTREAMER_VERSION}" "${GST_GIT_URL}" \
      || git clone --depth 1 --branch "${GSTREAMER_VERSION}" "${GST_GIT_FALLBACK}" || {
      echo "ERROR: Failed to re-clone GStreamer repository (github + gitlab)"
      exit 1
    }
    cd gstreamer
  }
else
  :
  echo "Cloning GStreamer repository..."
  git clone --depth 1 --branch "${GSTREAMER_VERSION}" "${GST_GIT_URL}" \
    || git clone --depth 1 --branch "${GSTREAMER_VERSION}" "${GST_GIT_FALLBACK}" || {
    echo "ERROR: Failed to clone GStreamer repository (github + gitlab)"
    exit 1
  }
  cd gstreamer
fi

if command -v patch_gstreamer_sources >/dev/null 2>&1; then
  patch_gstreamer_sources "$(pwd)"
fi

build_gstreamer_monorepo

if cross_build_is_active; then
  echo "Cross build: gst-plugins-rs is built + installed by the monorepo (-Drs=enabled"
  echo "with the target Rust linker wired via prepare_host_cargo_toolchain_env), so the"
  echo "separate standalone cargo build is redundant and skipped here."
else
  build_standalone_gst_plugins_rs
fi

echo "Done. Set PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH accordingly."

echo "Cleaning up..."
cd /
${SUDO_WRAP} rm -rf "${BUILD_DIR:?}" 2>/dev/null || true

echo ""
echo "=========================================="
echo "✓ GStreamer ${GSTREAMER_VERSION} built successfully!"
echo "Installed to: ${GSTREAMER_PREFIX}"
echo "=========================================="
echo ""
echo "Add these environment variables to your shell:"
echo "For setting up env:"
printf '%s\n' "Have a look into: linux/scripts/04-runtime/gstreamer-env.sh"
