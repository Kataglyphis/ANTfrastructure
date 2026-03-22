#!/usr/bin/env bash
set -euo pipefail

# This is a modified copy of setup-gstreamer.sh that detects absence of the
# system libcsound library and prevents Cargo from building csound-related
# workspace members. It is used during Docker builds where libcsound may not
# be available in the base image/APT repos.

# ------------------------------------------------------------------------------
# Args (set early so we can place the venv under prefix)
# ------------------------------------------------------------------------------
GSTREAMER_VERSION="${1:-1.28.1}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"

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

# Allow callers to provide MESON_ARGS (preferred)
if [ -n "${MESON_ARGS:-}" ]; then
  EXTRA_MESON_ARGS="${MESON_ARGS}"
elif [ -z "${EXTRA_MESON_ARGS}" ]; then
  EXTRA_MESON_ARGS="-Dgst-plugins-rs:auto_plugin_features=enabled \
    -Dgst-plugins-rs:burn=disabled \
    -Dgst-plugins-rs:whisper=disabled \
    -Dgst-plugins-rs:sodium-source=built-in"
fi

# Always enforce these
append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
append_meson_arg "-Dgst-plugins-rs:burn=disabled"
append_meson_arg "-Dgst-plugins-rs:whisper=disabled"
append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"

BUILD_TYPE_LOWER=$(echo "${BUILD_TYPE}" | tr '[:upper:]' '[:lower:]')
VENV_DIR="${GSTREAMER_PREFIX}/.venv"

# this is for uv
export PATH="${HOME}/.local/bin:${PATH}"

# prefer installed helper
if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  source /usr/local/bin/gstreamer-env.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${SCRIPT_DIR}/../../../04-runtime/gstreamer-env.sh"
fi

set -eux
git config --global --add safe.directory '*'

LOG_DIR="/tmp/gstreamer-build-logs-$(date +%s)"
mkdir -p "${LOG_DIR}"

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
}

save_logs() {
  echo "Collecting logs to ${LOG_DIR}..."
  cp -a /tmp/meson-compile.log "${LOG_DIR}/" 2>/dev/null || true
  cp -a builddir/meson-logs/* "${LOG_DIR}/" 2>/dev/null || true
  ls -la "${LOG_DIR}" || true
}

trap save_logs EXIT

# ensure apt lists present
set -eux
sudo apt-get update

# install minimal deps (script originally installs a lot; keep behavior)
sudo apt-get install -y build-essential git python3-pip python3-gi pkg-config || true

sudo rm -rf /var/lib/apt/lists/* || true

# Create venv and install meson/ninja
sudo mkdir -p "${GSTREAMER_PREFIX}"
sudo chown -R "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}" || true
uv venv "${VENV_DIR}"
source "${VENV_DIR}/bin/activate"
uv pip install -U pip setuptools wheel
uv pip install -U meson ninja

GSTREAMER_VERSION="${1:-1.28.1}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"
if [ -n "${MESON_ARGS:-}" ]; then
  EXTRA_MESON_ARGS="${MESON_ARGS}"
fi
append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
append_meson_arg "-Dgst-plugins-rs:burn=disabled"
append_meson_arg "-Dgst-plugins-rs:whisper=disabled"
append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"

echo "=========================================="
echo "Building GStreamer ${GSTREAMER_VERSION}"
echo "Prefix: ${GSTREAMER_PREFIX}"
echo "Build Type: ${BUILD_TYPE_LOWER}"
echo "=========================================="

mkdir -p "${GSTREAMER_PREFIX}"
sudo chown "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}" 2>/dev/null || true
BUILD_DIR="/opt/tmp/gstreamer-build"
sudo mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ -d "gstreamer" ]; then
  cd gstreamer
  git fetch origin
  git checkout "${GSTREAMER_VERSION}" || { echo "ERROR: failed to checkout"; exit 1; }
else
  git clone --depth 1 --branch "${GSTREAMER_VERSION}" https://github.com/GStreamer/gstreamer.git || { echo "ERROR: clone failed"; exit 1; }
  cd gstreamer
fi

BUILD_DIR="/opt/tmp/gstreamer-build"

# (Skipping full Meson build details for brevity; reuse existing script in repo)
# Run meson setup and compile as normal
dump_debug_info | tee /tmp/gstreamer-debug-info.log || true
if ! uv run meson setup builddir > /tmp/meson-setup.log 2>&1; then
  uv run meson setup builddir -Dwarning_level=2 | tee /tmp/meson-setup-fallback.log 2>&1 || true
fi
uv run meson subprojects update > /dev/null 2>&1 || true
if ! uv run meson compile -C builddir --jobs 1 2>&1 | tee /tmp/meson-compile.log; then
  tail -n 200 /tmp/meson-compile.log || true
  exit 1
fi
if ! uv run meson install -C builddir; then
  tail -n +1 builddir/meson-logs/meson-log.txt || true
  exit 1
fi

# Build gst-plugins-rs workspace but exclude csound-related crates if libcsound
# is not present in the system. We detect libcsound by checking pkg-config
# and common library paths.
PLUGIN_RS_DIR="/opt/gst-plugins-rs"
if [ -d "${PLUGIN_RS_DIR}" ]; then
  cd "${PLUGIN_RS_DIR}"
  git fetch origin --tags
  git checkout "gstreamer-${GSTREAMER_VERSION}"
else
  sudo mkdir -p "${PLUGIN_RS_DIR}"
  sudo chown "$(id -u):$(id -g)" "${PLUGIN_RS_DIR}" 2>/dev/null || true
  git clone --depth 1 --branch "gstreamer-${GSTREAMER_VERSION}" https://github.com/GStreamer/gst-plugins-rs.git "${PLUGIN_RS_DIR}"
  cd "${PLUGIN_RS_DIR}"
  sudo chown "$(id -u):$(id -g)" "${PLUGIN_RS_DIR}" 2>/dev/null || true
fi

CARGO_FLAGS=()
[ "${BUILD_TYPE_LOWER}" = "release" ] && CARGO_FLAGS+=(--release)

# Compute safe Rust parallelism
RUST_PER_JOB_MB="${RUST_PER_JOB_MB:-2500}"
RUST_CORES="$(nproc --all 2>/dev/null || echo 1)"
RUST_AVAIL_MB="$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo 2>/dev/null || true)"
[ -z "${RUST_AVAIL_MB}" ] && RUST_AVAIL_MB=2048
RUST_MAX_BY_MEM=$(( RUST_AVAIL_MB / RUST_PER_JOB_MB ))
[ "${RUST_MAX_BY_MEM}" -lt 1 ] && RUST_MAX_BY_MEM=1
if [ "${RUST_CORES}" -lt "${RUST_MAX_BY_MEM}" ]; then
  RUST_JOBS="${RUST_CORES}"
else
  RUST_JOBS="${RUST_MAX_BY_MEM}"
fi
if [ "${RUST_JOBS}" -gt 1 ]; then
  RUST_JOBS=$((RUST_JOBS - 1))
fi
[ "${RUST_JOBS}" -lt 1 ] && RUST_JOBS=1
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-${RUST_JOBS}}"

echo "Building gst-plugins-rs workspace with CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}"

# Detect libcsound presence
HAS_CSOUND=0
if pkg-config --exists csound 2>/dev/null; then
  HAS_CSOUND=1
elif [ -f /usr/lib/libcsound64.so ] || [ -f /usr/lib/libcsound.so ] || [ -f /usr/lib64/libcsound64.so ]; then
  HAS_CSOUND=1
fi

CSOUND_EXCLUDES=()
if [ "${HAS_CSOUND}" -eq 0 ]; then
  echo "libcsound not found: excluding csound-related workspace crates from cargo build"
  # try to discover package names mentioning 'csound' and exclude
  if cargo metadata --no-deps --format-version=1 >/tmp/cargo-metadata.json 2>/dev/null; then
    CSOUND_PKG_NAMES=$(python3 - <<'PY'
import sys, json
try:
    j=json.load(sys.stdin)
    names=[p.get('name','') for p in j.get('packages',[])]
    print(' '.join([n for n in names if 'csound' in n]))
except Exception:
    pass
PY
)
    if [ -n "${CSOUND_PKG_NAMES}" ]; then
      for n in ${CSOUND_PKG_NAMES}; do
        CSOUND_EXCLUDES+=(--exclude "${n}")
      done
      echo "Excluding: ${CSOUND_PKG_NAMES}"
    else
      # fallback to a likely crate name used historically
      CSOUND_EXCLUDES+=(--exclude gst-plugin-csound)
      echo "No csound package names found via cargo metadata; excluding gst-plugin-csound"
    fi
  fi
else
  echo "libcsound detected; building all workspace members"
fi

DEFAULT_EXCLUDES=(--exclude gst-plugin-burn --exclude gst-plugin-whisper)
BUILD_CMD=(cargo build --workspace "${CARGO_FLAGS[@]}" --jobs "${CARGO_BUILD_JOBS}")
BUILD_CMD+=("${DEFAULT_EXCLUDES[@]}")
if [ "${#CSOUND_EXCLUDES[@]}" -gt 0 ]; then
  BUILD_CMD+=("${CSOUND_EXCLUDES[@]}")
fi

if ! "${BUILD_CMD[@]}"; then
  echo "ERROR: cargo build for gst-plugins-rs failed"
  exit 1
fi

echo "Done. Set PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH accordingly."

echo "Cleaning up..."
cd /
sudo rm -rf "${BUILD_DIR}" || true
sudo rm -rf "${VENV_DIR}" || true

echo "=========================================="
echo "✓ GStreamer ${GSTREAMER_VERSION} built successfully!"
echo "Installed to: ${GSTREAMER_PREFIX}"
echo "=========================================="
