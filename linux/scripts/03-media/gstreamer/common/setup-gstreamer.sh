#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Args (set early so we can place the venv under prefix)
# ------------------------------------------------------------------------------
GSTREAMER_VERSION="${1:-1.29.1}"
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

# Allow callers to provide MESON_ARGS (preferred) to control Meson options.
# If MESON_ARGS is set in the environment, use it verbatim; otherwise fall
# back to the caller-provided fourth positional arg (EXTRA_MESON_ARGS).
# If neither is provided, enable all gst-plugins-rs auto features and disable
# the plugins that are known to cause trouble.
if [ -n "${MESON_ARGS:-}" ]; then
  EXTRA_MESON_ARGS="${MESON_ARGS}"
elif [ -z "${EXTRA_MESON_ARGS}" ]; then
  EXTRA_MESON_ARGS="-Dgst-plugins-rs:auto_plugin_features=enabled \
    -Dgst-plugins-rs:burn=disabled \
    -Dgst-plugins-rs:sodium-source=built-in"
fi

# Always enforce these, even if MESON_ARGS was supplied externally.
append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
append_meson_arg "-Dgst-plugins-rs:burn=disabled"
# Note: whisper plugin is enabled by default unless explicitly disabled by MESON_ARGS
append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"

BUILD_TYPE_LOWER=$(echo "${BUILD_TYPE}" | tr '[:upper:]' '[:lower:]')
VENV_DIR="${GSTREAMER_PREFIX}/.venv"

# this is for uv
export PATH="${HOME}/.local/bin:${PATH}"

# set the gst paths accordingly
# Prefer the installed helper if available, otherwise source relative to this script
if [ -f /usr/local/bin/gstreamer-env.sh ]; then
  source /usr/local/bin/gstreamer-env.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # runtime scripts live under /opt/scripts/04-runtime — reference them relative to /opt/scripts/media/* subfolders
  source "${SCRIPT_DIR}/../../../04-runtime/gstreamer-env.sh"
fi

# just trust every folder
set -eux
git config --global --add safe.directory '*'

# --- Debug/logging helpers -------------------------------------------------
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
  echo "--- Resource usage ---"
  free -h || true
  df -h || true
  ulimit -a || true
  echo "--- Tool versions ---"
  which python3 || true; python3 --version 2>&1 || true
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

trap save_logs EXIT

# ensure universe/multiverse enabled and apt lists present for packages the script will install
# we need to get rid of old orc modules on the system
set -eux
sudo apt-get update
apt-get purge -y 'liborc*' || true
apt-get autoremove -y

# Helper: check whether a package is available in APT (returns 0 if present)
apt_package_exists() {
  apt-cache show "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Install broad dependency set to enable most plugins
# ------------------------------------------------------------------------------
sudo apt-get install -y \
  build-essential g++ \
  libc++-dev libc++abi-dev \
  flex bison \
  libglib2.0-dev libgirepository1.0-dev gir1.2-gstreamer-1.0 \
  libcairo2-dev \
  libjson-glib-dev python3-gi python3-gi-cairo python-gi-dev \
  libgsl-dev libdw-dev libnsl-dev gobject-introspection

# Some distributions provide a libunwind package with a numeric suffix which
# conflicts with the generic "libunwind-dev" package (for example
# "libunwind-18-dev"). Try installing the generic package and fall back to
# a known alternative if the generic package is unavailable.
if ! sudo apt-get install -y libunwind-dev 2>/dev/null; then
  INSTALLED_ALTS=$(dpkg -l 2>/dev/null | awk '{print $2}' | grep -E '^libunwind-[0-9]+-dev$' || true)
  if [ -n "${INSTALLED_ALTS}" ]; then
    echo "Detected installed libunwind package(s): ${INSTALLED_ALTS}; skipping installation."
  else
    echo "libunwind-dev not available; searching for versioned libunwind-*-dev packages..."
    mapfile -t _alts < <(apt-cache search libunwind 2>/dev/null | awk '{print $1}' | grep -E '^libunwind-[0-9]+-dev$' || true)
    if [ "${#_alts[@]}" -gt 0 ]; then
      echo "Found libunwind packages: ${_alts[*]}; installing ${_alts[0]}"
      sudo apt-get install -y "${_alts[0]}" || true
    else
      echo "No versioned libunwind-dev package found; continuing without explicit libunwind package (may be satisfied by other packages)"
    fi
  fi
fi

# Enable source repos so build-dep works
CODENAME=$(lsb_release -sc)
sudo apt-get update -y

# Ensure xmllint is available (used by meson/xml preprocessing); small package
if ! apt_package_exists libxml2-utils; then
  echo "libxml2-utils not available in APT lists; will continue without xmllint"
else
  sudo apt-get install -y --no-install-recommends libxml2-utils
fi

# For using GTK video sinks
sudo apt-get install -y --no-install-recommends libgtk-3-dev libgtk-4-dev glslc glslang-tools

# Audio I/O and DSP
sudo apt-get install -y --no-install-recommends \
  libasound2-dev libpulse-dev libjack-dev libpipewire-0.3-dev \
  libsndfile1-dev libsamplerate0-dev

# Video capture / devices
sudo apt-get install -y --no-install-recommends \
  libv4l-dev libusb-1.0-0-dev libdc1394-dev libraw1394-dev \
  libcdio-dev libcdparanoia-dev

# Graphics stacks (X11/Wayland/OpenGL/EGL/GLES/DRM/VA)
sudo apt-get install -y --no-install-recommends \
  libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxrandr-dev libxv-dev \
  libwayland-dev wayland-protocols libxkbcommon-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev \
  libdrm-dev libgbm-dev libva-dev \
  libudev-dev

# Images / formats
sudo apt-get install -y --no-install-recommends \
  libjpeg-dev libpng-dev libtiff-dev libwebp-dev

# Install OpenEXR development headers: prefer libopenexr-3-dev when present,
# otherwise fall back to libopenexr-dev if available.
if apt_package_exists libopenexr-3-dev; then
  sudo apt-get install -y --no-install-recommends libopenexr-3-dev
elif apt_package_exists libopenexr-dev; then
  sudo apt-get install -y --no-install-recommends libopenexr-dev
else
  echo "Warning: no libopenexr-* package found in APT; continuing without explicit OpenEXR dev package"
fi

# VVdeC / vvdec dependency for gst-plugins-rs vvdec plugin
# Keep the plugin enabled and install the system package instead.
if apt_package_exists libvvdec-dev; then
  sudo apt-get install -y --no-install-recommends libvvdec-dev
else
  echo "Warning: libvvdec-dev not found in APT; vvdec plugin stays enabled, but Meson may fail unless the package is available in your Ubuntu repositories."
fi

# Codecs (audio)
sudo apt-get install -y --no-install-recommends \
  libogg-dev libvorbis-dev libtheora-dev libopus-dev libflac-dev \
  libmpg123-dev libmp3lame-dev libtwolame-dev libspeex-dev libspeexdsp-dev \
  libwavpack-dev libgsm1-dev

# Codecs (video)
sudo apt-get install -y --no-install-recommends \
  libvpx-dev libaom-dev libdav1d-dev \
  libx264-dev libx265-dev libopenh264-dev \
  libsvtav1-dev || true

# FFmpeg (for gst-libav)
sudo apt-get install -y --no-install-recommends \
  libavcodec-dev libavformat-dev libavfilter-dev libavutil-dev \
  libswscale-dev libswresample-dev

# Networking / RTP / WebRTC / crypto
sudo apt-get install -y --no-install-recommends \
  libsoup-3.0-dev libcurl4-openssl-dev libxml2-dev \
  zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
  libsrtp2-dev libnice-dev libssl-dev libusrsctp-dev || true

# NVIDIA codec headers (enable nvcodec plugin)
# Only install if NVIDIA GPU present OR explicitly requested via env var
# Note: lspci won't work in Docker builds, so check /dev/dri or NVIDIA env vars
NVIDIA_GPU="${NVIDIA_CODEC_HEADERS:-auto}"
if [ "${NVIDIA_GPU}" = "auto" ]; then
  if lspci 2>/dev/null | grep -qi nvidia; then
    NVIDIA_GPU="yes"
  elif [ -d /dev/dri ] && ls /dev/dri/card* 2>/dev/null | head -1 | xargs -r cat 2>/dev/null | grep -q NVIDIA; then
    NVIDIA_GPU="yes"
  elif [ -n "${NVIDIA_DRIVER_CAPABILITIES:-}" ] || [ -n "${NVIDIA_VISIBLE_DEVICES:-}" ]; then
    NVIDIA_GPU="yes"
  else
    NVIDIA_GPU="no"
  fi
fi

if [ "${NVIDIA_GPU}" = "yes" ]; then
  # Prefer package if available, otherwise fall back to upstream repo
  if apt_package_exists nv-codec-headers; then
    sudo apt-get install -y --no-install-recommends nv-codec-headers || true
  else
    echo "nv-codec-headers not present in APT; falling back to building and installing from source"
  fi

  if ! pkg-config --exists nv-codec-headers 2>/dev/null; then
    git clone --depth 1 https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers
    make -C /tmp/nv-codec-headers install
    sudo rm -rf /tmp/nv-codec-headers
  fi
else
  echo "No NVIDIA GPU detected, skipping nv-codec-headers installation"
fi

# libcamera support; needed for raspberry pi cam
# sudo apt install -y --no-install-recommends libcamera-dev libcamera-tools

# Some projects (litert/TFLite) install headers under /usr/local/include/tflite
# while other code expects /usr/local/include/tensorflow/... header layout.
# Create a compat symlink so includes like <tensorflow/lite/interpreter.h>
# resolve correctly. Place this before libcamera/build steps so downstream
# builds (e.g. libcamera) see the expected headers.
if [ -d /usr/local/include/tflite ] && [ ! -e /usr/local/include/tensorflow ]; then
  echo "Creating compat symlink /usr/local/include/tensorflow -> /usr/local/include/tflite"
  sudo ln -s /usr/local/include/tflite /usr/local/include/tensorflow || true
fi

sudo rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Install Astral uv, create venv, install Meson/Ninja
# ------------------------------------------------------------------------------

sudo mkdir -p "${GSTREAMER_PREFIX}"
sudo chown -R "$(id -u):$(id -g)" "${GSTREAMER_PREFIX}"
uv venv "${VENV_DIR}"

# Activate venv so 'meson' and 'ninja' from the venv are used
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

# Install Meson/Ninja in the venv
uv pip install -U pip setuptools wheel
uv pip install -U meson ninja

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
  EXTRA_MESON_ARGS="${MESON_ARGS}"
fi

# Enforce the gst-plugins-rs args again here so they survive external MESON_ARGS.
append_meson_arg "-Dgst-plugins-rs:auto_plugin_features=enabled"
append_meson_arg "-Dgst-plugins-rs:burn=disabled"
# whisper left enabled — do not force-disable here
append_meson_arg "-Dgst-plugins-rs:sodium-source=built-in"

BUILD_TYPE_LOWER=$(echo "${BUILD_TYPE}" | tr '[:upper:]' '[:lower:]')

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
  echo "Updating existing GStreamer repository..."
  cd gstreamer
  git fetch origin
  git checkout "${GSTREAMER_VERSION}" || {
    echo "ERROR: Failed to checkout version ${GSTREAMER_VERSION}"
    exit 1
  }
else
  echo "Cloning GStreamer repository..."
  git clone --depth 1 --branch "${GSTREAMER_VERSION}" https://github.com/GStreamer/gstreamer.git || {
    echo "ERROR: Failed to clone GStreamer repository"
    exit 1
  }
  cd gstreamer
fi

echo ""
echo "Setting up Meson build..."

# detect host architecture (examples: x86_64, aarch64, riscv64, armv7l)
HOST_ARCH="$(uname -m)"

# Build Meson flags, conditionally enable Rust bindings (rs) except on RISC-V
MESON_FLAGS=(
  "--prefix=${GSTREAMER_PREFIX}"
  "-Dbuildtype=${BUILD_TYPE_LOWER}"
  "-Dgpl=enabled"
  "-Ddoc=disabled"
  "-Dbase=enabled"
  "-Dgood=enabled"
  "-Dgtk_doc=disabled"
  "-Dgtk=enabled"
  "-Dugly=enabled"
  "-Dges=enabled"
  # --- ML / Inference / LiteRT support ---
  "-Dbad=enabled"
  "-Dgst-plugins-bad:tflite=enabled"
  "-Dgst-plugins-bad:opencv=enabled"
  "-Dgst-plugins-bad:onnx=enabled"
  "-Dtools=enabled"
  "-Dlibav=enabled"
  "-Ddevtools=enabled"
  "-Dexamples=disabled"
  "-Dtests=disabled"
  "-Drtsp_server=enabled"
  "-Dpython=enabled"
  "-Dintrospection=enabled"
  "-Dglib:introspection=enabled"
)

case "${HOST_ARCH}" in
  riscv*|*riscv*)
    echo "Host arch '${HOST_ARCH}' detected: skipping -Drs (Rust bindings) in Meson flags"
    MESON_FLAGS+=("-Drs=disabled")
    ;;
  aarch64*|arm*)
    echo "Host arch '${HOST_ARCH}' detected: enabling -Drs (Rust bindings) but disabling csound"
    MESON_FLAGS+=("-Drs=enabled")
    append_meson_arg "-Dgst-plugins-rs:csound=disabled"
    # Disable Whisper plugin on ARM architectures — it is resource-heavy and
    # known to cause issues on some ARM toolchains/platforms.
    append_meson_arg "-Dgst-plugins-rs:whisper=disabled"
    echo "Disabling gst-plugins-rs whisper plugin for ARM host arch"
    ;;
  *)
    MESON_FLAGS+=("-Drs=enabled")
    ;;
esac

# --- begin patch: ensure meson won't use fallback subprojects by default ---
MESON_WRAP_MODE="${MESON_WRAP_MODE:-nofallback}"

case " ${EXTRA_MESON_ARGS} " in
  *" --wrap-mode="*) ;;
  *)
    EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} --wrap-mode=${MESON_WRAP_MODE}"
    ;;
esac
# --- end patch ---

# Dump debug info and save to /tmp for collection
dump_debug_info | tee /tmp/gstreamer-debug-info.log || true

# Ensure PKG_CONFIG_LIBDIR includes the system multiarch pkgconfig directory
# Some base images omit this which makes pkg-config unable to find xproto/cairo
DEB_HOST_MULTIARCH_DIR="$(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
if [ -n "${DEB_HOST_MULTIARCH_DIR}" ]; then
  SYS_PKGCONF_DIR="/usr/lib/${DEB_HOST_MULTIARCH_DIR}/pkgconfig"
else
  SYS_PKGCONF_DIR="/usr/lib/pkgconfig"
fi
# Prepend system pkgconfig dirs if not already present
PKG_CONFIG_LIBDIR="${SYS_PKGCONF_DIR}:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_LIBDIR:-}"
export PKG_CONFIG_LIBDIR

# Some distributions install .pc files under /usr/share/pkgconfig; include it
# when present so pkg-config can find xproto/cairo/etc even when PKG_CONFIG_LIBDIR
# is set (PKG_CONFIG_LIBDIR overrides pkg-config defaults).
if [ -d /usr/share/pkgconfig ]; then
  PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR}:/usr/share/pkgconfig"
  export PKG_CONFIG_LIBDIR
fi

# Extra debug: check pkg-config visibility for cairo before Meson runs
echo "--- cairo / pkg-config debug ---" | tee /tmp/gstreamer-cairo-debug.txt
echo "PKG_CONFIG PATH: PKG_CONFIG_PATH='${PKG_CONFIG_PATH:-}'" | tee -a /tmp/gstreamer-cairo-debug.txt
echo "PKG_CONFIG LIBDIR: PKG_CONFIG_LIBDIR='${PKG_CONFIG_LIBDIR:-}'" | tee -a /tmp/gstreamer-cairo-debug.txt
echo "DEB_HOST_MULTIARCH: $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)" | tee -a /tmp/gstreamer-cairo-debug.txt
which pkg-config || true | tee -a /tmp/gstreamer-cairo-debug.txt
pkg-config --version 2>&1 | tee -a /tmp/gstreamer-cairo-debug.txt || true
for p in "/usr/lib/${DEB_HOST_MULTIARCH:-}/pkgconfig" /usr/lib/pkgconfig /usr/local/lib/pkgconfig; do
  echo "listing: $p" | tee -a /tmp/gstreamer-cairo-debug.txt
  ls -la "$p" 2>/dev/null | sed -n '1,20p' | tee -a /tmp/gstreamer-cairo-debug.txt || true
  [ -f "$p/cairo.pc" ] && echo "FOUND: $p/cairo.pc" | tee -a /tmp/gstreamer-cairo-debug.txt || true
done
pkg-config --cflags --libs cairo 2>&1 | tee -a /tmp/gstreamer-cairo-debug.txt || true

# If cairo isn't visible when PKG_CONFIG_LIBDIR is set, try a fallback by
# unsetting PKG_CONFIG_LIBDIR (this lets pkg-config use its compiled-in
# defaults which often include /usr/share/pkgconfig). If that succeeds, use
# the fallback for subsequent Meson setup.
if ! pkg-config --exists cairo 2>/dev/null; then
  echo "cairo not found with PKG_CONFIG_LIBDIR='${PKG_CONFIG_LIBDIR:-}' — trying fallback by unsetting PKG_CONFIG_LIBDIR" | tee -a /tmp/gstreamer-cairo-debug.txt || true
  if env -u PKG_CONFIG_LIBDIR pkg-config --exists cairo 2>/dev/null; then
    echo "Fallback: cairo found after unsetting PKG_CONFIG_LIBDIR; proceeding using fallback search paths" | tee -a /tmp/gstreamer-cairo-debug.txt || true
    # Unset for the rest of the script so Meson will see the cairo pkg-config
    unset PKG_CONFIG_LIBDIR
    export PKG_CONFIG_LIBDIR=""
  else
    echo "Fallback also failed: cairo still not found" | tee -a /tmp/gstreamer-cairo-debug.txt || true
  fi
fi
echo "--- end cairo debug ---" | tee -a /tmp/gstreamer-cairo-debug.txt

# Run meson setup and capture full output
if ! uv run meson setup builddir "${MESON_FLAGS[@]}" ${EXTRA_MESON_ARGS} > /tmp/meson-setup.log 2>&1; then
  echo "Meson setup failed; printing verbose output..."
  uv run meson setup builddir "${MESON_FLAGS[@]}" ${EXTRA_MESON_ARGS} -Dwarning_level=2 | tee /tmp/meson-setup-fallback.log 2>&1 || true
fi

echo "Updating subprojects..."
uv run meson subprojects update > /dev/null 2>&1 || true

echo "Compiling GStreamer (this may take a while)..."

# Memory per compile job in MB
PER_JOB_MB=1500

# CPU threads
CORES=$(nproc --all)

# Verfügbaren RAM in MB holen (fallback 2048 MB)
AVAIL_MB=$(awk '/MemAvailable/ {printf("%d",$2/1024); exit}' /proc/meminfo)
[ -z "$AVAIL_MB" ] && AVAIL_MB=2048

# Max Jobs begrenzt durch RAM
MAX_BY_MEM=$(( AVAIL_MB / PER_JOB_MB ))
[ "$MAX_BY_MEM" -lt 1 ] && MAX_BY_MEM=1

# JOBS = min(CORES, MAX_BY_MEM)
if [ "$CORES" -lt "$MAX_BY_MEM" ]; then
  JOBS=$CORES
else
  JOBS=$MAX_BY_MEM
fi

# Reserve one core for system if possible
if [ "$JOBS" -gt 1 ]; then
  JOBS=$((JOBS - 1))
fi

# Ensure at least 1
[ "$JOBS" -lt 1 ] && JOBS=1

export JOBS
echo "Using JOBS=$JOBS (cores=$CORES, avail_mb=${AVAIL_MB}, per_job_mb=${PER_JOB_MB})"

echo "Compiling GStreamer..."
if ! uv run meson compile -C builddir --jobs "${JOBS}" 2>&1 | tee /tmp/meson-compile.log; then
  echo "ERROR: Meson compile failed"
  echo "==> Letzte Zeilen der Compile-Logs:"
  tail -n 20000 /tmp/meson-compile.log || true
  echo "==> Meson log:"
  tail -n +1 builddir/meson-logs/meson-log.txt || true
  dmesg | tail -n 100 | grep -i -E "out of memory|killed process" || true
  exit 1
fi

echo "Installing GStreamer..."
if ! uv run meson install -C builddir; then
  echo "ERROR: Meson install failed"
  echo "==> Meson log:"
  tail -n +1 builddir/meson-logs/meson-log.txt || true
  echo "==> Meson install log (if present):"
  tail -n +1 builddir/meson-logs/install-log.txt || true
  exit 1
fi

# --------------------------------------------------------------------
# Build gst-plugins-rs net/webrtc under /opt
# --------------------------------------------------------------------
# Ensure GStreamer is discoverable for cargo builds
if [ -d "${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu/pkgconfig" ]; then
  export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
elif [ -d "${GSTREAMER_PREFIX}/lib/aarch64-linux-gnu/pkgconfig" ]; then
  export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/aarch64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
elif [ -d "${GSTREAMER_PREFIX}/lib/riscv64-linux-gnu/pkgconfig" ]; then
  export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/riscv64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib/riscv64-linux-gnu:${LD_LIBRARY_PATH:-}"
else
  export PKG_CONFIG_PATH="${GSTREAMER_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export LD_LIBRARY_PATH="${GSTREAMER_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
fi

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

# Build gst-plugins-rs packages.
CARGO_FLAGS=()
[ "${BUILD_TYPE_LOWER}" = "release" ] && CARGO_FLAGS+=(--release)

# Limit Rust build parallelism (cargo can be very memory hungry)
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
echo "Building gst-plugins-rs workspace with CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} (cores=${RUST_CORES}, avail_mb=${RUST_AVAIL_MB}, per_job_mb=${RUST_PER_JOB_MB})"

cd "${PLUGIN_RS_DIR}"

# Always attempt to install Csound development packages when possible.
# This simplifies behaviour: rather than conditionally building csound
# plugins or producing an error, we try to install the system packages via
# APT and continue. If installation fails we'll print a warning but not
# abort the entire build.
run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo "$@"
    return $?
  fi
  return 2
}

if command -v apt-get >/dev/null 2>&1; then
  # Check if architecture shouldn't build Csound
  ARCH_FOR_APT="${HOST_ARCH} ${TARGETARCH:-} $(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || true) $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true) $(uname -m 2>/dev/null || true)"
  if echo "${ARCH_FOR_APT}" | grep -qi -E 'riscv|aarch64|arm64|arm'; then
    echo "Skipping Csound APT install on ARM/RISC-V architecture."
  else
    echo "Attempting to install Csound development packages via APT..."
    run_as_root apt-get update || true
    # Install user-facing csound packages and development headers that cargo
    # crates expect (installing several common package names to cover
    # distribution differences).
    run_as_root apt-get install -y --no-install-recommends \
      csound csound-utils libcsound64 libcsound64-dev libcsound-dev pd-csound || true

    if pkg-config --exists csound 2>/dev/null; then
      echo "libcsound detected via pkg-config after install: building all workspace members"
    else
      echo "Warning: libcsound pkg-config not available after APT install; csound-related crates may fail to build." >&2
    fi
  fi
else
  echo "APT not available: skipping automatic Csound installation. If you need csound-related plugins, please install the libcsound development package." >&2
fi

DEFAULT_EXCLUDES=(--exclude gst-plugin-burn)

# Proactively exclude csound-related crates on architectures known to cause
# csound-sys/va_list binding issues (riscv/aarch64/arm64/arm). Detect using several
# probes (HOST_ARCH, TARGETARCH, dpkg queries, and the kernel machine name) so
# we don't accidentally miss a Docker/CI context that sets one but not others.
ARCH_FOR_EXCLUDES="${HOST_ARCH} ${TARGETARCH:-} $(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || true) $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true) $(uname -m 2>/dev/null || true)"
if echo "${ARCH_FOR_EXCLUDES}" | grep -qi -E 'riscv|aarch64|arm64|arm'; then
  DEFAULT_EXCLUDES+=(--exclude gst-plugin-csound --exclude csound --exclude csound-sys)
  echo "Host arch detected in (${ARCH_FOR_EXCLUDES}): added csound-related excludes to DEFAULT_EXCLUDES"
fi
BUILD_CMD=(cargo build --workspace "${CARGO_FLAGS[@]}" --jobs "${CARGO_BUILD_JOBS}")
BUILD_CMD+=("${DEFAULT_EXCLUDES[@]}")

# If host is RISC-V or ARM64 (aarch64/arm64) or 32-bit ARM, exclude csound-related workspace
# crates from the cargo build. Csound crates (csound-sys -> va_list) currently
# fail to compile on some RISC-V and ARM toolchains (due to c_char
# signedness / platform differences), so always exclude them on these arches
# even if system csound packages are present.
#
# Use multiple detection methods (uname, TARGETARCH, dpkg) because Docker
# build contexts sometimes set TARGETARCH or use different uname values.
ARCH_PROBES="${HOST_ARCH} ${TARGETARCH:-} $(dpkg-architecture -q DEB_HOST_ARCH 2>/dev/null || true) $(dpkg-architecture -q DEB_HOST_MULTIARCH 2>/dev/null || true)"
if echo "${ARCH_PROBES}" | grep -qi -E 'riscv|aarch64|arm64|arm'; then
  echo "Host arch detected in (${ARCH_PROBES}): excluding csound-related workspace crates from cargo build"
  if cargo metadata --no-deps --format-version=1 >/tmp/cargo-metadata.json 2>/dev/null; then
    CS_PKG_NAMES=$(python3 - <<'PY'
import sys, json
try:
    j = json.load(sys.stdin)
    names = [p.get('name','') for p in j.get('packages', [])]
    print(' '.join([n for n in names if 'csound' in n]))
except Exception:
    pass
PY
)
    if [ -n "${CS_PKG_NAMES}" ]; then
      for n in ${CS_PKG_NAMES}; do
        BUILD_CMD+=(--exclude "${n}")
      done
      echo "Excluding csound packages: ${CS_PKG_NAMES}"
    else
      # Fallback to likely crate names
      BUILD_CMD+=(--exclude gst-plugin-csound)
      BUILD_CMD+=(--exclude csound)
      BUILD_CMD+=(--exclude csound-sys)
      echo "No csound package names found via cargo metadata; excluding gst-plugin-csound, csound and csound-sys"
    fi
  else
    BUILD_CMD+=(--exclude gst-plugin-csound)
    BUILD_CMD+=(--exclude csound)
    BUILD_CMD+=(--exclude csound-sys)
    echo "cargo metadata unavailable; excluding gst-plugin-csound, csound and csound-sys by default"
  fi
fi

# If Meson args disabled skia, exclude skia-related workspace crates from the
# cargo build to avoid pulling in skia-bindings (which requires GN/Chromium
# toolchain helpers like fetch-gn). This mirrors the meson configuration and
# prevents cargo from attempting to build skia when the meson plugin is off.
if echo " ${EXTRA_MESON_ARGS} ${MESON_ARGS:-} " | grep -q -E 'skia=disabled'; then
  echo "skia disabled via Meson args: excluding skia-related workspace crates from cargo build"
  if cargo metadata --no-deps --format-version=1 >/tmp/cargo-metadata.json 2>/dev/null; then
    SKIA_PKG_NAMES=$(python3 - <<'PY'
import sys, json
try:
    j=json.load(sys.stdin)
    names=[p.get('name','') for p in j.get('packages',[])]
    print(' '.join([n for n in names if 'skia' in n]))
except Exception:
    pass
PY
)
    if [ -n "${SKIA_PKG_NAMES}" ]; then
      for n in ${SKIA_PKG_NAMES}; do
        BUILD_CMD+=(--exclude "${n}")
      done
      echo "Excluding skia packages: ${SKIA_PKG_NAMES}"
    else
      # Fallback to a likely crate name used historically
      BUILD_CMD+=(--exclude gst-plugin-skia)
      BUILD_CMD+=(--exclude gst-plugin-skia-sys)
      echo "No skia package names found via cargo metadata; excluding gst-plugin-skia and gst-plugin-skia-sys"
    fi
  else
    BUILD_CMD+=(--exclude gst-plugin-skia)
    BUILD_CMD+=(--exclude gst-plugin-skia-sys)
    echo "cargo metadata unavailable; excluding gst-plugin-skia and gst-plugin-skia-sys by default"
  fi
fi

# If this is a Release build on ARM architectures, exclude the Whisper plugin
# from the cargo build. Whisper can be resource heavy and often fails on some
# ARM toolchains in release mode, so exclude it proactively for stability.
if [ "${BUILD_TYPE_LOWER}" = "release" ]; then
  if echo "${ARCH_PROBES}" | grep -qi -E 'aarch64|arm64|arm|armv7l'; then
    echo "Release build on ARM detected in (${ARCH_PROBES}): excluding whisper-related workspace crates from cargo build"
    if cargo metadata --no-deps --format-version=1 >/tmp/cargo-metadata.json 2>/dev/null; then
      WHISPER_PKG_NAMES=$(python3 - <<'PY'
import sys, json
try:
    j = json.load(sys.stdin)
    names = [p.get('name','') for p in j.get('packages', [])]
    print(' '.join([n for n in names if 'whisper' in n]))
except Exception:
    pass
PY
)
      if [ -n "${WHISPER_PKG_NAMES}" ]; then
        for n in ${WHISPER_PKG_NAMES}; do
          BUILD_CMD+=(--exclude "${n}")
        done
        echo "Excluding whisper packages: ${WHISPER_PKG_NAMES}"
      else
        # Fallback to a likely crate name
        BUILD_CMD+=(--exclude gst-plugin-whisper)
        echo "No whisper package names found via cargo metadata; excluding gst-plugin-whisper"
      fi
    else
      BUILD_CMD+=(--exclude gst-plugin-whisper)
      echo "cargo metadata unavailable; excluding gst-plugin-whisper by default"
    fi
  fi
fi

if ! "${BUILD_CMD[@]}"; then
  echo "ERROR: cargo build for gst-plugins-rs failed"
  exit 1
fi

echo "Done. Set PATH/PKG_CONFIG_PATH/LD_LIBRARY_PATH/GST_PLUGIN_PATH accordingly."

echo "Cleaning up..."
cd /
sudo rm -rf "${BUILD_DIR}"
sudo rm -rf "${VENV_DIR}" || true

echo ""
echo "=========================================="
echo "✓ GStreamer ${GSTREAMER_VERSION} built successfully!"
echo "Installed to: ${GSTREAMER_PREFIX}"
echo "=========================================="
echo ""
echo "Add these environment variables to your shell:"
echo "For setting up env:"
echo "Have a look into: ExternalLib\Kataglyphis-ContainerHub\linux\scripts\04-runtime\gstreamer-env.sh"
