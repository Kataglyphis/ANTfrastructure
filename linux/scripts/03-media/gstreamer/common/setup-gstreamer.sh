#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# setup-gstreamer.sh - Build GStreamer from source with all plugins
# ==============================================================================
#
# Build Acceleration:
#   USE_CCACHE=true              Enable ccache for C/C++ (default: true)
#   USE_SCCACHE=true             Enable sccache for Rust (default: true)
#   USE_LLD=true                 Use lld linker (default: true)
#   AGGRESSIVE_PARALLELISM=true  Use lower memory caps (default: false)
# ==============================================================================

# Source build acceleration and parallelism helpers if available
_SETUP_GST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for helper in \
    "/opt/scripts/core/cross-env.sh" \
    "${_SETUP_GST_DIR}/../../../../01-core/cross-env.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        break
    fi
done

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
    # Meson's C++ dependency checks (for example GLib's builtin iconv probe)
    # currently fail under lld on the riscv64 cross path when g++ links
    # libstdc++. Keep the linker on the toolchain default for this build.
    export USE_LLD=false
fi

for helper in \
    "/opt/scripts/core/compiler-cache.sh" \
    "${_SETUP_GST_DIR}/../../../../01-core/compiler-cache.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        setup_ccache
        setup_sccache
        setup_lld_linker
        break
    fi
done

# Source parallelism helpers
for helper in \
    "/opt/scripts/core/parallelism.sh" \
    "${_SETUP_GST_DIR}/../../../../01-core/parallelism.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        break
    fi
done

# ------------------------------------------------------------------------------
# Args (set early so we can place the venv under prefix)
# ------------------------------------------------------------------------------
GSTREAMER_VERSION="${1:-1.29.1}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"
HOST_PYTHON="$(host_python_bin)"
export PYTHON_EXECUTABLE="${HOST_PYTHON}" \
  Python_EXECUTABLE="${HOST_PYTHON}" \
  Python3_EXECUTABLE="${HOST_PYTHON}"

append_meson_arg() {
  local arg="$1"
  case " ${EXTRA_MESON_ARGS} " in
    *" ${arg} "*|*" ${arg}"*)
      ;;
    *)
      EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} ${arg}"
      ;;
  esac
}

append_env_flag() {
  local var_name="$1"
  local flag="$2"
  local current="${!var_name:-}"

  case " ${current} " in
    *" ${flag} "*)
      return 0
      ;;
  esac

  if [ -n "${current}" ]; then
    printf -v "${var_name}" '%s %s' "${current}" "${flag}"
  else
    printf -v "${var_name}" '%s' "${flag}"
  fi

  export "${var_name}=${!var_name}"
}

resolve_host_gcc_for_cargo() {
  local build_triplet=""
  local candidate
  local resolved=""

  if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
    resolved="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
    [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool cc 2>/dev/null || true)"
    [ -n "${resolved}" ] && { printf '%s' "${resolved}"; return 0; }
  fi

  if command -v build_deb_multiarch_triplet >/dev/null 2>&1; then
    build_triplet="$(build_deb_multiarch_triplet)"
  fi

  for candidate in \
    "/usr/bin/${build_triplet}-gcc" \
    /usr/bin/gcc \
    /usr/bin/cc; do
    [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
  done

  command -v gcc 2>/dev/null || command -v cc 2>/dev/null || true
}

prepare_cargo_host_linker_wrapper() {
  local compiler="$1"
  local wrapper_dir="${GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR:-/tmp/gstreamer-cargo-host-toolchain}"

  if command -v make_named_host_compiler_wrapper >/dev/null 2>&1; then
    make_named_host_compiler_wrapper "${wrapper_dir}" host-gcc "${compiler}"
    return 0
  fi

  mkdir -p "${wrapper_dir}"
  cat > "${wrapper_dir}/host-gcc" <<EOF
#!/usr/bin/env bash
exec env PATH="/usr/bin:/bin" "${compiler}" -B/usr/bin/ "\$@"
EOF
  chmod +x "${wrapper_dir}/host-gcc"
  printf '%s' "${wrapper_dir}/host-gcc"
}

resolve_host_gxx_for_cargo() {
  local build_triplet=""
  local candidate
  local resolved=""

  if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
    resolved="$(resolve_build_gcc_tool g++ 2>/dev/null || true)"
    [ -n "${resolved}" ] || resolved="$(resolve_build_gcc_tool c++ 2>/dev/null || true)"
    [ -n "${resolved}" ] && { printf '%s' "${resolved}"; return 0; }
  fi

  if command -v build_deb_multiarch_triplet >/dev/null 2>&1; then
    build_triplet="$(build_deb_multiarch_triplet)"
  fi

  for candidate in \
    "/usr/bin/${build_triplet}-g++" \
    /usr/bin/g++ \
    /usr/bin/c++; do
    [ -x "${candidate}" ] && { printf '%s' "${candidate}"; return 0; }
  done

  command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || true
}

prepare_cargo_host_cxx_wrapper() {
  local compiler="$1"
  local wrapper_dir="${GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR:-/tmp/gstreamer-cargo-host-toolchain}"

  if command -v make_named_host_compiler_wrapper >/dev/null 2>&1; then
    make_named_host_compiler_wrapper "${wrapper_dir}" host-g++ "${compiler}"
    return 0
  fi

  mkdir -p "${wrapper_dir}"
  cat > "${wrapper_dir}/host-g++" <<EOF
#!/usr/bin/env bash
exec env PATH="/usr/bin:/bin" "${compiler}" -B/usr/bin/ "\$@"
EOF
  chmod +x "${wrapper_dir}/host-g++"
  printf '%s' "${wrapper_dir}/host-g++"
}

prepare_cross_python_build_config() {
  local meson_version=""
  local target_triplet=""
  local python_build_config=""
  local target_python_include=""
  local target_python_library=""
  local target_python_pkgconfig_dir=""

  CROSS_PYTHON_BUILD_CONFIG=""
  export CROSS_PYTHON_BUILD_CONFIG

  if ! command -v cross_build_enabled >/dev/null 2>&1 || ! cross_build_enabled; then
    return 0
  fi

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
    return 0
  fi

  if command -v cross_target_triplet >/dev/null 2>&1; then
    target_triplet="$(cross_target_triplet)"
  else
    target_triplet="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
  fi
  if [ -z "${target_triplet}" ]; then
    echo "Could not determine cross target triplet for Meson python.build_config"
    return 0
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
  if [ -z "${target_python_include}" ] || [ -z "${target_python_library}" ] || [ -z "${target_python_pkgconfig_dir}" ]; then
    echo "Target Python development files are not ready for ${target_triplet}; skipping Meson python.build_config generation"
    return 0
  fi

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
data = {
    'schema_version': '1.0',
    'base_prefix': '/usr',
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

# Allow callers to provide MESON_ARGS (preferred) to control Meson options.
# If MESON_ARGS is set in the environment, use it verbatim; otherwise fall
# back to the caller-provided fourth positional arg (EXTRA_MESON_ARGS).
# If neither is provided, enable all gst-plugins-rs auto features and disable
# the plugins that are known to cause trouble.
if [ -n "${MESON_ARGS:-}" ]; then
  :
  EXTRA_MESON_ARGS="${MESON_ARGS}"
elif [ -z "${EXTRA_MESON_ARGS}" ]; then
  :
  EXTRA_MESON_ARGS="-Dgst-plugins-rs:auto_plugin_features=enabled \
    -Dgst-plugins-rs:burn=disabled \
    -Dgst-plugins-rs:sodium-source=built-in"
fi

# Always enforce these, even if MESON_ARGS was supplied externally.
append_meson_arg "-Dpython-exe=${HOST_PYTHON}"
append_meson_arg "-Dgst-python:python-exe=${HOST_PYTHON}"
append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
append_meson_arg "-Dgst-plugins-rs:burn=disabled"
# Note: whisper plugin is enabled by default unless explicitly disabled by MESON_ARGS
append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"

BUILD_TYPE_LOWER=$(echo "${BUILD_TYPE}" | tr '[:upper:]' '[:lower:]')

# Keep /usr/local/bin ahead of /bin so cross-introspection shims like
# g-ir-scanner and ldd are used when upstream tools shell out by program name.
export PATH="/usr/local/sbin:/usr/local/bin:${HOME}/.local/bin:${PATH}"

# set the gst paths accordingly
# Prefer the installed helper if available, otherwise source relative to this script
if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  :
  # shellcheck disable=SC1091
  source /usr/local/bin/gstreamer-env.sh
else
  :
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # runtime scripts live under /opt/scripts/04-runtime — reference them relative to /opt/scripts/media/* subfolders
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../../../04-runtime/gstreamer-env.sh"
fi

# just trust every folder
set -eux

# --- Debug/logging helpers -------------------------------------------------
LOG_DIR="/tmp/gstreamer-build-logs-$(date +%s)"

dump_debug_info() {
  echo "=== GStreamer build debug info ==="
  echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Host: $(uname -a)"
  echo "GStreamer version: ${GSTREAMER_VERSION:-unset}"
  echo "GStreamer prefix: ${GSTREAMER_PREFIX:-unset}"
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

# ensure universe/multiverse enabled and apt lists present for packages the script will install
# we need to get rid of old orc modules on the system
set -eux




# Helper: check whether a package is available in APT (returns 0 if present)
apt_package_exists() {
  apt-cache show "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Install broad dependency set to enable most plugins
# ------------------------------------------------------------------------------



# Force removal of any versioned libunwind to avoid conflicts, then install generic



# Ensure xmllint is available (used by meson/xml preprocessing); small package
if ! apt_package_exists libxml2-utils; then
  :
  echo "libxml2-utils not available in APT lists; will continue without xmllint"
else
  :
  
fi

# For using GTK video sinks


# Audio I/O and DSP



# Video capture / devices



# Graphics stacks (X11/Wayland/OpenGL/EGL/GLES/DRM/VA)



# Images / formats



# Install OpenEXR development headers: prefer libopenexr-3-dev when present,
# otherwise fall back to libopenexr-dev if available.
if apt_package_exists libopenexr-3-dev; then
  :
  
elif apt_package_exists libopenexr-dev; then
  :
  
else
  :
  echo "Warning: no libopenexr-* package found in APT; continuing without explicit OpenEXR dev package"
fi

# VVdeC / vvdec dependency for gst-plugins-rs vvdec plugin
# Keep the plugin enabled and install the system package instead.
if apt_package_exists libvvdec-dev; then
  :
  
else
  :
  echo "Warning: libvvdec-dev not found in APT; continuing with the source-build fallback from install-vvdec.sh so the vvdec plugin stays enabled."
fi

# Codecs (audio)



# Codecs (video)



# FFmpeg (for gst-libav)



# Networking / RTP / WebRTC / crypto



# NVIDIA codec headers (enable nvcodec plugin)
# Only install if NVIDIA GPU present OR explicitly requested via env var
# Note: lspci won't work in Docker builds, so check /dev/dri or NVIDIA env vars
NVIDIA_GPU="${NVIDIA_CODEC_HEADERS:-auto}"
if [ "${NVIDIA_GPU}" = "auto" ]; then
  :
  if lspci 2>/dev/null | grep -qi nvidia; then
  :
    NVIDIA_GPU="yes"
  elif [ -d /sys/class/drm ] && grep -q '^0x10de$' /sys/class/drm/card*/device/vendor 2>/dev/null; then
  :
    NVIDIA_GPU="yes"
  elif [ -n "${NVIDIA_DRIVER_CAPABILITIES:-}" ] || [ -n "${NVIDIA_VISIBLE_DEVICES:-}" ]; then
  :
    NVIDIA_GPU="yes"
  else
  :
    NVIDIA_GPU="no"
  fi
fi

if [ "${NVIDIA_GPU}" = "yes" ]; then
  :
  # Prefer package if available, otherwise fall back to upstream repo
  if apt_package_exists nv-codec-headers; then
  :
    
  else
  :
    echo "nv-codec-headers not present in APT; falling back to building and installing from source"
  fi

  if ! pkg-config --exists nv-codec-headers 2>/dev/null; then
  :
    git clone --depth 1 https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers
    make -C /tmp/nv-codec-headers install
    sudo rm -rf /tmp/nv-codec-headers
  fi
else
  :
  echo "No NVIDIA GPU detected, skipping nv-codec-headers installation"
fi

# libcamera support; needed for raspberry pi cam
# sudo apt install -y --no-install-recommends libcamera-dev libcamera-tools

sudo rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Install Astral uv, use existing venv, install Meson/Ninja
# ------------------------------------------------------------------------------

sudo mkdir -p "${GSTREAMER_PREFIX}"
sudo chown -R "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}"

echo "Using existing Python venv (expected at /opt/python/.venv)..."

# Install Meson/Ninja in the existing venv
uv pip install -U pip setuptools wheel
uv pip install -U meson ninja
# pycairo is a host Python build dependency for pygobject fallback. Install it
# with host pkg-config paths so cross-target overrides do not hide xorgproto
# metadata required by cairo's x11 dependency chain.
HOST_MULTIARCH="$(dpkg-architecture -q DEB_BUILD_MULTIARCH 2>/dev/null || dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
HOST_PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
if [ -n "${HOST_MULTIARCH}" ]; then
  HOST_PKG_CONFIG_LIBDIR="/usr/lib/${HOST_MULTIARCH}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
else
  HOST_PKG_CONFIG_LIBDIR="/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
fi
env \
  PKG_CONFIG_ALLOW_CROSS= \
  PKG_CONFIG_SYSROOT_DIR= \
  PKG_CONFIG_LIBDIR="${HOST_PKG_CONFIG_LIBDIR}" \
  PKG_CONFIG_PATH="${HOST_PKG_CONFIG_PATH}" \
  uv pip install -U pycairo

# Optional: verify
meson --version
ninja --version

# ------------------------------------------------------------------------------
# Build GStreamer from monorepo
# ------------------------------------------------------------------------------
GSTREAMER_VERSION="${1:-1.29.1}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"

# Honor MESON_ARGS env var (if present) at this later re-evaluation point as
# well. This allows callers to export MESON_ARGS or pass a fourth positional
# argument; MESON_ARGS takes precedence.
if [ -n "${MESON_ARGS:-}" ]; then
  :
  EXTRA_MESON_ARGS="${MESON_ARGS}"
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
append_meson_arg "-Dpython-exe=${HOST_PYTHON}"
append_meson_arg "-Dgst-python:python-exe=${HOST_PYTHON}"
append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
append_meson_arg "-Dgst-plugins-rs:burn=disabled"
# whisper left enabled — do not force-disable here
append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"

echo "=========================================="
echo "Building GStreamer ${GSTREAMER_VERSION}"
echo "Prefix: ${GSTREAMER_PREFIX}"
echo "Build Type: ${BUILD_TYPE_LOWER}"
echo "=========================================="

mkdir -p "${GSTREAMER_PREFIX}"
sudo chown "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}" 2>/dev/null || true
# do not write directly into tmp; its reserved for apt
BUILD_DIR="/opt/tmp/gstreamer-build"
sudo mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
sudo chown -R "$(id -u):$(id -g)" "${BUILD_DIR}" 2>/dev/null || true

if [ -d "gstreamer" ]; then
  :
  echo "Updating existing GStreamer repository..."
  cd gstreamer
  git fetch origin
  git checkout "${GSTREAMER_VERSION}" || {
    echo "ERROR: Failed to checkout version ${GSTREAMER_VERSION}"
    exit 1
  }
else
  :
  echo "Cloning GStreamer repository..."
  git clone --depth 1 --branch "${GSTREAMER_VERSION}" https://github.com/GStreamer/gstreamer.git || {
    echo "ERROR: Failed to clone GStreamer repository"
    exit 1
  }
  cd gstreamer
fi

if command -v patch_gstreamer_sources >/dev/null 2>&1; then
  patch_gstreamer_sources "$(pwd)" "${EXTRA_MESON_ARGS}"
fi

build_gstreamer_monorepo

build_standalone_gst_plugins_rs

echo "Done. Set PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH accordingly."

echo "Cleaning up..."
cd /
sudo rm -rf "${BUILD_DIR}"

echo ""
echo "=========================================="
echo "✓ GStreamer ${GSTREAMER_VERSION} built successfully!"
echo "Installed to: ${GSTREAMER_PREFIX}"
echo "=========================================="
echo ""
echo "Add these environment variables to your shell:"
echo "For setting up env:"
printf '%s\n' "Have a look into: linux/scripts/04-runtime/gstreamer-env.sh"
