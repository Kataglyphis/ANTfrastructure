# Source-only helper -- do not execute directly.
# package-groups.sh - shared package group catalog.
# Sources that need cross-aware install functions should source cross-apt.sh first.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

# Base build toolchain packages
PKG_BASE_BUILD=(
  build-essential cmake git pkg-config wget
  autoconf automake libtool texinfo
  ninja-build
)

# Python build dependencies
PKG_PYTHON_BUILD=(
  libssl-dev libbz2-dev liblzma-dev libzstd-dev libffi-dev
  libreadline-dev libncurses-dev libgdbm-dev libsqlite3-dev
  zlib1g-dev
)

# Image/media format dev packages
PKG_IMAGE_FORMATS=(
  libjpeg-turbo8-dev libpng-dev libtiff-dev libwebp-dev
)

# Video codec dev packages (common set)
PKG_CODECS_VIDEO=(
  libx264-dev libx265-dev libvpx-dev libdav1d-dev libaom-dev
  libtheora-dev
)

# Audio codec dev packages
PKG_CODECS_AUDIO=(
  libogg-dev libvorbis-dev libopus-dev libflac-dev
  libmp3lame-dev libtwolame-dev libspeex-dev libspeexdsp-dev
  libwavpack-dev libgsm1-dev
)

# Graphics/GPU dev packages
PKG_GRAPHICS_DEV=(
  libdrm-dev libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev libgbm-dev
  libepoxy-dev
)

# FFmpeg dev packages
PKG_FFMPEG_DEV=(
  libavcodec-dev libavformat-dev libavfilter-dev libavutil-dev
  libswscale-dev libswresample-dev
)

# Vulkan SDK build dependencies
PKG_VULKAN_BUILD=(
  libx11-dev libxext-dev libxcb1-dev libxcb-shm0-dev libxcb-xfixes0-dev
  libxrandr-dev libxfixes-dev libxrender-dev libxau-dev libxdmcp-dev
  libwayland-dev wayland-protocols
  pkg-config python3 libzstd-dev libxml2-dev ninja-build libx264-dev
  libpng-dev glslc glslang-tools
)

# Networking / crypto dev packages
PKG_NETWORK_CRYPTO=(
  libcurl4-openssl-dev libxml2-dev
  zlib1g-dev libbz2-dev liblzma-dev libzstd-dev
  libssl-dev
)

# GStreamer-specific additional packages
PKG_GSTREAMER_EXTRA=(
  libgsl-dev libdw-dev libnsl-dev libexpat1-dev
  libfontconfig-dev libfribidi-dev libfreetype-dev libpixman-1-dev
  libffi-dev libpcre2-dev
)


