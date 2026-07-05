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

_SETUP_GST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SETUP_GST_DIR}/../../../core/common.sh"
media_common_init "${_SETUP_GST_DIR}"

if cross_build_is_active && \
   command -v cross_target_arch >/dev/null 2>&1; then
    case "$(cross_target_arch)" in
        arm64|riscv64)
            # Meson's C++ dependency checks (for example GLib's builtin iconv probe)
            # currently fail under lld on these cross paths when g++ links libstdc++.
            # Keep the linker on the toolchain default for this build.
            export USE_LLD=false
            ;;
    esac
fi

# Meson's internal C++ standard library detection probes _LIBCPP_VERSION in a way
# that fails with the GCC 16 cross-compiler's libstdc++ headers on arm64/riscv64.
# Define _LIBCPP_VERSION in CXXFLAGS to satisfy the detection probe without
# changing the actual standard library used.
if cross_build_is_active && \
   command -v cross_target_arch >/dev/null 2>&1; then
    case "$(cross_target_arch)" in
        arm64|riscv64)
            export CXXFLAGS="${CXXFLAGS:-} -D_LIBCPP_VERSION=20220101"
            ;;
    esac
fi

for helper in \
    "/opt/scripts/core/compiler-cache.sh" \
    "${_SETUP_GST_DIR}/../../../01-core/compiler-cache.sh"; do
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
    "${_SETUP_GST_DIR}/../../../01-core/parallelism.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        break
    fi
done

for helper in \
    "/opt/scripts/core/compiler-resolution.sh" \
    "${_SETUP_GST_DIR}/../../../01-core/compiler-resolution.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        break
    fi
done

# ------------------------------------------------------------------------------
# Args (set early so we can place the venv under prefix)
# ------------------------------------------------------------------------------
# Positional arg wins; else the env value forwarded from versions.env; the
# literal is a last-resort fallback only (keep in sync with versions.env).
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
  case " ${EXTRA_MESON_ARGS} " in
    *" ${arg} "*|*" ${arg}"*)
      ;;
    *)
      EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} ${arg}"
      ;;
  esac
}

# Enforce the python-exe / gst-plugins-rs meson args. Called at two points: once
# during initial arg assembly and again after monorepo setup, so they survive an
# externally-supplied MESON_ARGS. Extracted from two verbatim-duplicated copies
# to keep them from drifting.
enforce_gst_rs_meson_args() {
  append_meson_arg "-Dpython-exe=${HOST_PYTHON}"
  if [ "${GSTREAMER_ENABLE_PYTHON_BINDINGS}" = "true" ]; then
    append_meson_arg "-Dgst-python:python-exe=${HOST_PYTHON}"
  fi
  # GST_RS_BUILD_ALL: 'auto' attempts every gst-plugins-rs plugin and cleanly
  # SKIPS (not a hard meson error) when a system dep is missing; 'enabled'
  # force-requires every plugin and aborts meson setup on the first unsatisfiable
  # dep (e.g. webrtcbin2 needs the unpackaged rice-proto>=0.4.2). 'auto' still
  # builds burn/skia/whisper/csound/dav1d and everything else whose deps we ship.
  if [ "${GST_RS_BUILD_ALL:-true}" = "true" ]; then
    append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=auto"
  else
    append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
  fi
  [ "${GST_RS_BUILD_ALL:-true}" = "true" ] || append_meson_arg "-Dgst-plugins-rs:burn=disabled"
  # whisper stays enabled unless explicitly disabled via MESON_ARGS.
  append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"
}

# NOTE: dedup-guarded env-var flag appends use append_flag_if_missing from
# 01-core/common.sh (loaded via media_common_init above); the local
# append_env_flag duplicate was removed in favor of that canonical helper.

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

  # No PATH scrub needed anymore: /opt/cross-bin carries only triplet-prefixed
  # tool names (bare names live in /opt/cross-bin/bare, which is never on
  # PATH), so host-side proc-macro / build-script jobs already resolve the
  # native cc/c++.

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
  # If the cross-resolution functions returned host paths (/usr/local/...)
  # instead of the staged cross Python, force the correct per-arch paths.
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
  # auto_plugin_features is set below via append_meson_arg (auto vs enabled
  # depends on GST_RS_BUILD_ALL), so it is intentionally not baked in here.
  EXTRA_MESON_ARGS="-Dgst-plugins-rs:sodium-source=built-in"
  # burn is left to auto_plugin_features when GST_RS_BUILD_ALL=true (default);
  # otherwise force it off (heavy ML deps).
  [ "${GST_RS_BUILD_ALL:-true}" = "true" ] || EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} -Dgst-plugins-rs:burn=disabled"
fi

# Always enforce these, even if MESON_ARGS was supplied externally.
enforce_gst_rs_meson_args

# The system Vulkan SDK headers (1.4.x) are incompatible with GCC 16's strict
# C parsing when combined with XCB headers, causing syntax errors in
# vulkan_xcb.h. Disable the vulkan WSI backends (xcb/wayland) to avoid
# compilation failures in gst-plugins-bad's vulkan library.
# Vulkan compute/processing still works without display backends in a container.
# NOTE: the option is 'vulkan-windowing' (an array of WSI backends) — the old
# 'vulkan_wsi' name does not exist in gst-plugins-bad 1.29.2 and makes meson
# setup fail with "Unknown option". Empty array = no windowing backends.
append_meson_arg "-Dgst-plugins-bad:vulkan-windowing="

BUILD_TYPE_LOWER="${BUILD_TYPE,,}"

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
  # runtime scripts live under /opt/scripts/04-runtime — reference them relative to /opt/scripts/03-media/* subfolders
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../../../04-runtime/gstreamer-env.sh"
fi

# --- Debug/logging helpers -------------------------------------------------
LOG_DIR="${TMPDIR:-/tmp}/gstreamer-build-logs-$$-$(date +%s)"

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

# ------------------------------------------------------------------------------
# Install Astral uv, use existing venv, install Meson/Ninja
# ------------------------------------------------------------------------------

if command -v sudo >/dev/null 2>&1; then sudo mkdir -p "${GSTREAMER_PREFIX}"; else mkdir -p "${GSTREAMER_PREFIX}"; fi
if command -v sudo >/dev/null 2>&1; then sudo chown -R "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}"; else chown -R "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}"; fi

echo "Using existing Python venv (expected at /opt/python/.venv)..."

# Install Meson/Ninja in the existing venv
uv pip install -U pip setuptools wheel
uv pip install -U meson ninja
# pycairo is a host Python build dependency for pygobject fallback. Install it
# only when Python bindings are enabled, since the cross-compiler CC/CXX env
# vars leak into uv and cause Meson's "Could not invoke" in cross builds.
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

# ------------------------------------------------------------------------------
# Build GStreamer from monorepo
# ------------------------------------------------------------------------------
# Honor MESON_ARGS env var if present (takes precedence over CLI args).
if [ -n "${MESON_ARGS:-}" ]; then
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
enforce_gst_rs_meson_args

# In cross mode the rustc ptp-helper link step receives empty `-C link-arg=`
# flags from meson's env passthrough, so ld.bfd fails with
# "cannot find : No such file or directory". `ptp-helper-permissions=none` does
# NOT prevent this — it only drops the helper's setuid/setcap; the binary is
# still built and linked. Since PTP clock sync needs setuid and is useless in a
# container image, disable the helper entirely on ALL cross targets (previously
# only riscv64 did this via build-gstreamer-monorepo.sh; arm64 hit the failure).
if cross_build_is_active; then
  append_meson_arg "-Dgstreamer:ptp-helper=disabled"
fi

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
if command -v sudo >/dev/null 2>&1; then sudo chown "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}" 2>/dev/null || true; else chown "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}" 2>/dev/null || true; fi
# do not write directly into tmp; its reserved for apt
BUILD_DIR="/opt/tmp/gstreamer-build-$$"
if command -v sudo >/dev/null 2>&1; then sudo mkdir -p "${BUILD_DIR}"; else mkdir -p "${BUILD_DIR}"; fi
cd "${BUILD_DIR}"
if command -v sudo >/dev/null 2>&1; then sudo chown -R "$(id -u):$(id -g)" "${BUILD_DIR}" 2>/dev/null || true; else chown -R "$(id -u):$(id -g)" "${BUILD_DIR}" 2>/dev/null || true; fi

if command -v clone_or_update_repo >/dev/null 2>&1; then
  retry 3 10 "GStreamer git clone" clone_or_update_repo "https://github.com/GStreamer/gstreamer.git" "${BUILD_DIR}/gstreamer" "${GSTREAMER_VERSION}"
  cd "${BUILD_DIR}/gstreamer"
elif [ -d "gstreamer" ]; then
  echo "Updating existing GStreamer repository..."
  cd gstreamer
  git fetch origin --tags 2>/dev/null || git fetch --unshallow origin 2>/dev/null || true
  git checkout "${GSTREAMER_VERSION}" || {
    echo "Version ${GSTREAMER_VERSION} not found in shallow clone; re-cloning..."
    cd "${BUILD_DIR}"
    rm -rf gstreamer
    git clone --depth 1 --branch "${GSTREAMER_VERSION}" https://github.com/GStreamer/gstreamer.git || {
      echo "ERROR: Failed to re-clone GStreamer repository"
      exit 1
    }
    cd gstreamer
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

if cross_build_is_active; then
  echo "Cross build detected: skipping standalone gst-plugins-rs cargo build"
  echo "(gst-plugins-rs subproject is disabled in monorepo; standalone cargo build"
  echo "has host-toolchain path wrapping issues in cross mode)"
else
  build_standalone_gst_plugins_rs
fi

echo "Done. Set PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH accordingly."

echo "Cleaning up..."
cd /
if command -v sudo >/dev/null 2>&1; then sudo rm -rf "${BUILD_DIR:?}" 2>/dev/null || true; else rm -rf "${BUILD_DIR:?}" 2>/dev/null || true; fi

echo ""
echo "=========================================="
echo "✓ GStreamer ${GSTREAMER_VERSION} built successfully!"
echo "Installed to: ${GSTREAMER_PREFIX}"
echo "=========================================="
echo ""
echo "Add these environment variables to your shell:"
echo "For setting up env:"
printf '%s\n' "Have a look into: linux/scripts/04-runtime/gstreamer-env.sh"
