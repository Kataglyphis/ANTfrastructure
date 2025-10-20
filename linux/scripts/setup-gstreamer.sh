#!/bin/bash
set -euo pipefail

# -------------------------------------------------------
# Args (set early so we can place the venv under prefix)
# -------------------------------------------------------
GSTREAMER_VERSION="${1:-1.26.7}"
GSTREAMER_PREFIX="${2:-/opt/gstreamer}"
BUILD_TYPE="${3:-Release}"
EXTRA_MESON_ARGS="${4:-}"
BUILD_TYPE_LOWER=$(echo "${BUILD_TYPE}" | tr '[:upper:]' '[:lower:]')
VENV_DIR="${GSTREAMER_PREFIX}/.venv"

# -------------------------------------------------------
# Install broad dependency set to enable most plugins
# -------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.local/bin:$PATH"  # ensure 'uv' is on PATH

uv --version

apt-get install -y \
  build-essential git cmake meson ninja-build pkg-config \
  python3 python3-venv python3-dev \
  flex bison \
  libglib2.0-dev libgirepository1.0-dev gir1.2-gstreamer-1.0 \
  libgsl-dev libunwind-dev libdw-dev libnsl-dev

# apt-get install -y pkg-config build-essential \
#   libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
#   libsoup2.4-dev libnice-dev libssl-dev

# apt-get install -y libgstreamer1.0-dev \
#                 libgstreamer-plugins-base1.0-dev \
#                 libgstreamer-plugins-bad1.0-dev \
#                 gstreamer1.0-plugins-base \
#                 gstreamer1.0-plugins-good \
#                 gstreamer1.0-plugins-bad \
#                 gstreamer1.0-plugins-ugly \
#                 gstreamer1.0-libav \
#                 gstreamer1.0-tools

apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates gnupg lsb-release software-properties-common \
  build-essential meson ninja-build pkg-config \
  python3 python3-pip git curl

# Enable source repos so build-dep works
CODENAME=$(lsb_release -sc)
add-apt-repository -y "deb-src http://archive.ubuntu.com/ubuntu ${CODENAME} main restricted universe multiverse"
add-apt-repository -y "deb-src http://archive.ubuntu.com/ubuntu ${CODENAME}-updates main restricted universe multiverse"
apt-get update -y

# Install build-deps for the distro GStreamer packages
apt-get build-dep -y gstreamer1.0 gst-plugins-base1.0 gst-plugins-good1.0 \
  gst-plugins-bad1.0 gst-plugins-ugly1.0 gst-libav1.0 gst-rtsp-server1.0 || true

# Core + introspection
apt-get install -y --no-install-recommends \
  libglib2.0-dev liborc-0.4-dev \
  gobject-introspection libgirepository1.0-dev

# Audio I/O and DSP
apt-get install -y --no-install-recommends \
  libasound2-dev libpulse-dev libjack-dev libpipewire-0.3-dev \
  libsndfile1-dev libsamplerate0-dev

# Video capture / devices
apt-get install -y --no-install-recommends \
  libv4l-dev libusb-1.0-0-dev libdc1394-dev libraw1394-dev \
  libcdio-dev libcdparanoia-dev

# Graphics stacks (X11/Wayland/OpenGL/EGL/GLES/DRM/VA)
apt-get install -y --no-install-recommends \
  libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxrandr-dev libxv-dev \
  libwayland-dev wayland-protocols libxkbcommon-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev \
  libdrm-dev libva-dev

# Images / formats
apt-get install -y --no-install-recommends \
  libjpeg-dev libpng-dev libtiff-dev libwebp-dev \
  libopenexr-3-dev || apt-get install -y --no-install-recommends libopenexr-dev

# Codecs (audio)
apt-get install -y --no-install-recommends \
  libogg-dev libvorbis-dev libtheora-dev libopus-dev libflac-dev \
  libmpg123-dev libmp3lame-dev libtwolame-dev libspeex-dev libspeexdsp-dev \
  libwavpack-dev libgsm1-dev

# Codecs (video)
apt-get install -y --no-install-recommends \
  libvpx-dev libaom-dev libdav1d-dev \
  libx264-dev libx265-dev libopenh264-dev \
  libsvtav1-dev || true

# FFmpeg (for gst-libav)
apt-get install -y --no-install-recommends \
  libavcodec-dev libavformat-dev libavfilter-dev libavutil-dev \
  libswscale-dev libswresample-dev

# Networking / RTP / WebRTC / crypto
apt-get install -y --no-install-recommends \
  libsoup-3.0-dev libcurl4-openssl-dev libxml2-dev \
  zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
  libsrtp2-dev libnice-dev libssl-dev libusrsctp-dev || true

# NVIDIA codec headers (enable nvcodec plugin)
apt-get install -y --no-install-recommends nv-codec-headers || true
if ! pkg-config --exists nv-codec-headers; then
  git clone https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers
  make -C /tmp/nv-codec-headers install
  rm -rf /tmp/nv-codec-headers
fi

rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------
# Install Astral uv, create venv, install Meson/Ninja
# -------------------------------------------------------

mkdir -p "${GSTREAMER_PREFIX}"
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

rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------
# Build GStreamer from monorepo
# -------------------------------------------------------
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
BUILD_DIR="/tmp/gstreamer-build"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

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

uv run meson setup builddir \
  --prefix="${GSTREAMER_PREFIX}" \
  -Dbuildtype="${BUILD_TYPE_LOWER}" \
  -Dgpl=enabled \
  ${EXTRA_MESON_ARGS} \
  > /dev/null 2>&1 || {
  echo "ERROR: Meson setup failed (retrying with verbose output)"
  uv run  meson setup builddir --prefix="${GSTREAMER_PREFIX}" -Dbuildtype="${BUILD_TYPE_LOWER}" -Dgpl=enabled ${EXTRA_MESON_ARGS}
  exit 1
}

echo "Updating subprojects..."
uv run meson subprojects update > /dev/null 2>&1 || true

echo "Compiling GStreamer (this may take a while)..."
uv run meson compile -C builddir > /dev/null 2>&1 || {
  echo "ERROR: Meson compile failed"
  exit 1
}

echo "Installing GStreamer..."
uv run meson install -C builddir > /dev/null 2>&1 || {
  echo "ERROR: Meson install failed"
  exit 1
}

echo "Cleaning up..."
cd /
rm -rf "${BUILD_DIR}"

echo ""
echo "=========================================="
echo "✓ GStreamer ${GSTREAMER_VERSION} built successfully!"
echo "Installed to: ${GSTREAMER_PREFIX}"
echo "=========================================="
echo ""
echo "Add these environment variables to your shell:"
echo "  export PATH=\"${GSTREAMER_PREFIX}/bin:\${PATH}\""
echo "  export PKG_CONFIG_PATH=\"${GSTREAMER_PREFIX}/lib/pkgconfig:\${PKG_CONFIG_PATH}\""
echo "  export LD_LIBRARY_PATH=\"${GSTREAMER_PREFIX}/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH}\""
echo "  export GST_PLUGIN_PATH=\"${GSTREAMER_PREFIX}/lib/gstreamer-1.0:\${GST_PLUGIN_PATH}\""