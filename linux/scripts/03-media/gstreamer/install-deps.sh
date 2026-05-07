#!/usr/bin/env bash
set -eux

if [ -f /opt/scripts/core/cross-env.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/core/cross-env.sh
fi

echo "Installing GStreamer build dependencies..."

apt-get update

is_riscv64_cross=false
if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   command -v cross_target_arch >/dev/null 2>&1 && [ "$(cross_target_arch)" = "riscv64" ]; then
  is_riscv64_cross=true
fi

prefer_toolchain_vulkan=false
if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   [ -d "${VULKAN_PREFIX:-/opt/vulkan}" ]; then
  prefer_toolchain_vulkan=true
fi

# Pre-setup dependencies
install_host_packages build-essential cmake git pkg-config g++ flex bison

pre_setup_target_packages=(
  libx11-dev
  libxext-dev
  libxrender-dev
  libxau-dev
  libxdmcp-dev
  libxfixes-dev
  libsodium-dev
)

if [ "${is_riscv64_cross}" = "true" ]; then
  echo "Skipping libcairo2-dev, libpango1.0-dev and libgdk-pixbuf2.0-dev for riscv64 cross builds because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
else
  pre_setup_target_packages=(libcairo2-dev libpango1.0-dev libgdk-pixbuf2.0-dev "${pre_setup_target_packages[@]}")
fi

install_target_packages "${pre_setup_target_packages[@]}"

# X11 proto headers are shipped as Architecture: all packages here, so do not
# route them through install_target_packages or apt may insist on a nonexistent
# :riscv64 variant.
apt-get install -y --no-install-recommends x11proto-dev

install_target_packages xorg-dev || true
install_target_packages x11proto-core-dev x11proto-dev || true

# Setup-gstreamer dependencies
apt-get purge -y 'liborc*' || true
apt-get autoremove -y

gst_target_packages=(
  libc++-dev
  libc++abi-dev
  libgsl-dev
  libdw-dev
  libnsl-dev
  libexpat1-dev
  libfontconfig-dev
  libfribidi-dev
  libfreetype-dev
  libpixman-1-dev
  # GLib fallback still needs target libffi.pc when libglib2.0-dev is skipped on riscv64.
  libffi-dev
  libpcre2-dev
)

if [ "${is_riscv64_cross}" = "true" ]; then
  echo "Skipping target GLib/GTK/introspection/cairo packages for riscv64 cross builds because Ubuntu Ports cannot satisfy their helper dependency chain."
else
  gst_target_packages+=(
    libcairo2-dev
    libglib2.0-dev
    libgirepository1.0-dev
    gir1.2-gstreamer-1.0
    libjson-glib-dev
    libgtk-4-dev
  )
fi

install_target_packages "${gst_target_packages[@]}"

apt-get purge -y 'libunwind-[0-9]*-dev' || true
install_target_packages libunwind-dev

install_host_packages libxml2-utils glslc glslang-tools gobject-introspection || true
if [ "${is_riscv64_cross}" = "true" ]; then
  echo "Skipping target GTK dev packages for riscv64 cross builds because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
else
  install_target_packages libgtk-3-dev libgtk-4-dev
fi

# Audio I/O and DSP
apt-get install -y --no-install-recommends \
  libasound2-dev libpulse-dev libjack-dev libpipewire-0.3-dev \
  libsndfile1-dev libsamplerate0-dev

# Video capture / devices
apt-get install -y --no-install-recommends \
  libv4l-dev libusb-1.0-0-dev libdc1394-dev libraw1394-dev \
  libcdio-dev libcdparanoia-dev

# Graphics stacks
# GTK and several video sinks probe these through the target-only pkg-config
# view during cross builds, so install the graphics development packages on the
# target side as well. Prefer the toolchain Vulkan SDK headers for cross builds
# and only install the target runtime loader to avoid distro header conflicts.
graphics_target_packages=(
  libx11-dev libxext-dev libxfixes-dev libxdamage-dev libxrandr-dev libxv-dev \
  libxi-dev libxcursor-dev libxinerama-dev \
  libwayland-dev wayland-protocols libxkbcommon-dev libxkbcommon-x11-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libglu1-mesa-dev \
  libdrm-dev libgbm-dev libva-dev libepoxy-dev \
  libudev-dev
)

if [ "${prefer_toolchain_vulkan}" = "true" ]; then
  echo "Using toolchain Vulkan SDK from ${VULKAN_PREFIX:-/opt/vulkan}; installing target libvulkan1 instead of libvulkan-dev."
  graphics_target_packages+=(libvulkan1)
else
  graphics_target_packages+=(libvulkan-dev)
fi

install_target_packages "${graphics_target_packages[@]}"

if [ "${is_riscv64_cross}" = "true" ]; then
  echo "Skipping libgudev-1.0-dev for riscv64 cross builds because Ubuntu Ports cannot satisfy its libglib2.0-dev helper dependency chain."
else
  install_target_packages libgudev-1.0-dev
fi

# Images / formats
# GTK/gdk-pixbuf probe these through the target-only pkg-config view during
# cross builds, so install the image development packages on the target side.
install_target_packages \
  libjpeg-turbo8-dev libpng-dev libtiff-dev libwebp-dev

install_target_packages libopenexr-3-dev || \
install_target_packages libopenexr-dev || true

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
if [ -f /opt/ffmpeg/lib/pkgconfig/libavcodec.pc ]; then
  echo "Using staged FFmpeg build from /opt/ffmpeg for gst-libav; skipping distro FFmpeg dev packages."
else
  apt-get install -y --no-install-recommends \
    libavcodec-dev libavformat-dev libavfilter-dev libavutil-dev \
    libswscale-dev libswresample-dev
fi

# Networking / crypto
apt-get install -y --no-install-recommends libsoup-3.0-dev libnice-dev || true
install_target_packages \
  libcurl4-openssl-dev libxml2-dev \
  zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
  libsrtp2-dev libssl-dev libusrsctp-dev || true

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
