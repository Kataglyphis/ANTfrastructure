#!/usr/bin/env bash
set -eux

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

echo "Installing GStreamer build dependencies..."

apt-get update

# Pre-setup dependencies
install_host_packages build-essential cmake git pkg-config
install_target_packages \
    build-essential cmake git pkg-config libcairo2-dev libpango1.0-dev libgdk-pixbuf2.0-dev \
    libx11-dev libxext-dev libxrender-dev libxau-dev libxdmcp-dev libxfixes-dev \
    x11proto-core-dev libsodium-dev

(install_target_packages xorgproto) || true
install_target_packages xorg-dev || true
install_target_packages x11proto-core-dev x11proto-dev || true

# Setup-gstreamer dependencies
apt-get purge -y 'liborc*' || true
apt-get autoremove -y

install_host_packages build-essential g++ flex bison
install_target_packages \
  libc++-dev libc++abi-dev \
  libglib2.0-dev libgirepository1.0-dev gir1.2-gstreamer-1.0 \
  libcairo2-dev \
  libjson-glib-dev \
  libgsl-dev libdw-dev libnsl-dev gobject-introspection \
  libgtk-4-dev

apt-get purge -y 'libunwind-[0-9]*-dev' || true
install_target_packages libunwind-dev

install_host_packages libxml2-utils || true
install_target_packages libgtk-3-dev libgtk-4-dev glslc glslang-tools

# Audio I/O and DSP
apt-get install -y --no-install-recommends \
  libasound2-dev libpulse-dev libjack-dev libpipewire-0.3-dev \
  libsndfile1-dev libsamplerate0-dev

# Video capture / devices
apt-get install -y --no-install-recommends \
  libv4l-dev libusb-1.0-0-dev libdc1394-dev libraw1394-dev \
  libcdio-dev libcdparanoia-dev

# Graphics stacks
apt-get install -y --no-install-recommends \
  libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxrandr-dev libxv-dev \
  libwayland-dev wayland-protocols libxkbcommon-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev \
  libdrm-dev libgbm-dev libva-dev \
  libudev-dev

# Images / formats
apt-get install -y --no-install-recommends \
  libjpeg-dev libpng-dev libtiff-dev libwebp-dev

apt-get install -y --no-install-recommends libopenexr-3-dev || \
apt-get install -y --no-install-recommends libopenexr-dev || true

apt-get install -y --no-install-recommends libvvdec-dev || true

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

# Networking / crypto
apt-get install -y --no-install-recommends \
  libsoup-3.0-dev libcurl4-openssl-dev libxml2-dev \
  zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
  libsrtp2-dev libnice-dev libssl-dev libusrsctp-dev || true

# Csound conditionally
if echo "${TARGETARCH:-}" | grep -qi -E '^riscv|riscv64'; then
  echo "Skipping Csound APT install on TARGETARCH=${TARGETARCH:-unset}"
else
  install_target_packages \
    csound csound-utils csoundqt csoundqt-examples csound-doc libcsound64-dev pd-csound || true
fi

# NVIDIA
NVIDIA_GPU="${NVIDIA_CODEC_HEADERS:-auto}"
if [ "${NVIDIA_GPU}" = "auto" ]; then
  if lspci 2>/dev/null | grep -qi nvidia; then NVIDIA_GPU="yes";
  elif [ -d /dev/dri ] && ls /dev/dri/card* 2>/dev/null | head -1 | xargs -r cat 2>/dev/null | grep -q NVIDIA; then NVIDIA_GPU="yes";
  elif [ -n "${NVIDIA_DRIVER_CAPABILITIES:-}" ] || [ -n "${NVIDIA_VISIBLE_DEVICES:-}" ]; then NVIDIA_GPU="yes";
  else NVIDIA_GPU="no"; fi
fi
if [ "${NVIDIA_GPU}" = "yes" ]; then
  install_host_packages nv-codec-headers || true
fi

rm -rf /var/lib/apt/lists/*
