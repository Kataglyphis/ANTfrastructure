#!/bin/bash -i
set -euo pipefail

# ------------------------------------------------------------------------------
# Args (set early so we can place the venv under prefix)
# ------------------------------------------------------------------------------
GSTREAMER_VERSION="${1:-1.26.8}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"
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
set -eux; \
git config --global --add safe.directory '*'

# ensure universe/multiverse enabled and apt lists present for packages the script will install
# we need to get rid of old orc modules on the system
set -eux; \
sudo apt-get update; \
apt-get purge -y 'liborc*' || true && \
apt-get autoremove -y

# ------------------------------------------------------------------------------
# Install broad dependency set to enable most plugins
# ------------------------------------------------------------------------------
sudo apt-get install -y \
  flex bison \
  libglib2.0-dev libgirepository1.0-dev gir1.2-gstreamer-1.0 \
  libjson-glib-dev python3-gi python3-gi-cairo python-gi-dev \
  libgsl-dev libunwind-dev libdw-dev libnsl-dev gobject-introspection

# Enable source repos so build-dep works
CODENAME=$(lsb_release -sc)
sudo apt-get update -y

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
  libjpeg-dev libpng-dev libtiff-dev libwebp-dev \
  libopenexr-3-dev || sudo apt-get install -y --no-install-recommends libopenexr-dev

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
# Only install NVIDIA codec headers if an NVIDIA GPU is present
if lspci | grep -i nvidia > /dev/null 2>&1; then
  sudo apt-get install -y --no-install-recommends nv-codec-headers
  if ! pkg-config --exists nv-codec-headers; then
    git clone https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers
    make -C /tmp/nv-codec-headers install
    sudo rm -rf /tmp/nv-codec-headers
  fi
else
  echo "No NVIDIA GPU detected, skipping nv-codec-headers installation"
fi

# libcamera support; needed for raspberry pi cam
# sudo apt install -y --no-install-recommends libcamera-dev libcamera-tools

sudo rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Install Astral uv, create venv, install Meson/Ninja
# ------------------------------------------------------------------------------

sudo mkdir -p "${GSTREAMER_PREFIX}"
sudo chown -R $USER:$USER "${GSTREAMER_PREFIX}"
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
GSTREAMER_VERSION="${1:-1.26.7}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"

BUILD_TYPE_LOWER=$(echo "${BUILD_TYPE}" | tr '[:upper:]' '[:lower:]')

echo "=========================================="
echo "Building GStreamer ${GSTREAMER_VERSION}"
echo "Prefix: ${GSTREAMER_PREFIX}"
echo "Build Type: ${BUILD_TYPE_LOWER}"
echo "=========================================="

mkdir -p "${GSTREAMER_PREFIX}"
sudo chown $USER:$USER "${GSTREAMER_PREFIX}"
# do not write directlly into tmp; its reserved for apt
BUILD_DIR="/opt/tmp/gstreamer-build"
sudo mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
sudo chown -R $USER:$USER "${BUILD_DIR}"

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

# detect host architecture (examples: x86_64, aarch64, riscv64)
HOST_ARCH="$(uname -m)"

# treat riscv* as RISC-V; also handle dpkg architecture strings if you prefer:
# DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || true)" 

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
  "-Dbad=enabled"
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
# dont use auto features
# "-Dauto_features=disabled"
# Only enable Rust bindings on non-RISC-V hosts
# for now libsodium needs to updated to work 
# with RISCV
case "${HOST_ARCH}" in
  riscv*|*riscv*)
    echo "Host arch '${HOST_ARCH}' detected: skipping -Drs (Rust bindings) in Meson flags"
    MESON_FLAGS+=("-Drs=disabled")
    ;;
  *)
    MESON_FLAGS+=("-Drs=enabled")
    ;;
esac

# --- begin patch: ensure meson won't use fallback subprojects by default ---
# Allow overriding by setting MESON_WRAP_MODE in the environment
MESON_WRAP_MODE="${MESON_WRAP_MODE:-nofallback}"

# Append wrap-mode to EXTRA_MESON_ARGS if not already present
case " ${EXTRA_MESON_ARGS} " in
  *" --wrap-mode="*) ;;
  *)
    EXTRA_MESON_ARGS="${EXTRA_MESON_ARGS} --wrap-mode=${MESON_WRAP_MODE}"
    ;;
esac
# --- end patch ---


uv run meson setup builddir "${MESON_FLAGS[@]}" ${EXTRA_MESON_ARGS} || {
  echo "Meson setup failed; printing verbose output..."
  uv run meson setup builddir "${MESON_FLAGS[@]}" ${EXTRA_MESON_ARGS} -Dwarning_level=2
}

echo "Updating subprojects..."
uv run meson subprojects update > /dev/null 2>&1 || true

echo "Compiling GStreamer (this may take a while)..."

# Memory per compile job in MB — anpassen bei Bedarf (1500..3000)
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
# NOTE: Avoid `-v` here: Docker build output is capped and verbose logs hide the *real* error.
# We still capture the full output (stdout+stderr) to /tmp/meson-compile.log for debugging.
if ! uv run meson compile -C builddir --jobs "${JOBS}" 2>&1 | tee /tmp/meson-compile.log; then
  echo "ERROR: Meson compile failed"
  echo "==> Letzte Zeilen der Compile-Logs:"
  tail -n 20000 /tmp/meson-compile.log || true
  echo "==> Meson log:"
  tail -n +1 builddir/meson-logs/meson-log.txt || true
  # Prüfe OOM
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
  sudo mkdir "${PLUGIN_RS_DIR}"
  sudo chown $USER:$USER "${PLUGIN_RS_DIR}"
  git clone --depth 1 --branch "gstreamer-${GSTREAMER_VERSION}" https://github.com/GStreamer/gst-plugins-rs.git "${PLUGIN_RS_DIR}"
  cd "${PLUGIN_RS_DIR}"
  sudo chown $USER:$USER "${PLUGIN_RS_DIR}"
fi

cd net/webrtc
CARGO_FLAGS=()
[ "${BUILD_TYPE_LOWER}" = "release" ] && CARGO_FLAGS+=(--release)

# Limit Rust build parallelism (cargo can be very memory hungry)
# Allow override via env: CARGO_BUILD_JOBS or RUST_PER_JOB_MB
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
echo "Building gst-plugins-rs with CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS} (cores=${RUST_CORES}, avail_mb=${RUST_AVAIL_MB}, per_job_mb=${RUST_PER_JOB_MB})"

cargo build "${CARGO_FLAGS[@]}" --jobs "${CARGO_BUILD_JOBS}"
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
echo "  export PATH=\"${GSTREAMER_PREFIX}/bin:\${PATH}\""
echo "  export PKG_CONFIG_PATH=\"${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu/pkgconfig:\${PKG_CONFIG_PATH}\""
echo "  export LD_LIBRARY_PATH=\"${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH}\""
echo "  export GST_PLUGIN_PATH=\"${GSTREAMER_PREFIX}/lib/gstreamer-1.0:\${GST_PLUGIN_PATH}\""
