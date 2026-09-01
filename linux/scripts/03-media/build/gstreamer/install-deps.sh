#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_install_deps_init "${SCRIPT_DIR}"

if [ -f /opt/scripts/toolchain/vulkan.sh ]; then
  # shellcheck disable=SC1091
  source /opt/scripts/toolchain/vulkan.sh
fi

vulkan_prefix="${VULKAN_PREFIX:-${VULKAN_INSTALL_ROOT:-/opt/vulkan}}"

echo "Installing GStreamer build dependencies..."

install_deps_preamble build-essential cmake git pkg-config g++ flex bison

prefer_toolchain_vulkan=false
if is_cross; then
  if declare -F source_vulkan_sdk_env >/dev/null 2>&1 && \
     source_vulkan_sdk_env "${vulkan_prefix}" sanitize-libs >/dev/null 2>&1; then
    prefer_toolchain_vulkan=true
  elif [ -d "${vulkan_prefix}" ]; then
    prefer_toolchain_vulkan=true
  fi
fi

# Ubuntu 26.04 "resolute" (rolling dev release) mirror skew: libvulkan-dev is
# Multi-Arch: same, so its arch-independent headers under /usr/include/vk_video/
# must be byte-identical across the host :amd64 instance (already installed) and
# the target :<arch> instance being installed. When the amd64 archive and the
# arm64/riscv64 ports archive drift to different libvulkan-dev versions, those
# shared headers differ and dpkg REFUSES to unpack the target instance ("trying
# to overwrite shared '/usr/include/vk_video/vulkan_video_codec_av1std.h', which
# is different from other instances of package libvulkan-dev"). libgtk-4-dev
# pulls libvulkan-dev in transitively, so this aborts the whole GTK/graphics
# install and broke the base->latest-cross chain (observed 2026-08-10, arm64
# media). The conflicting files are arch-independent vulkan-video codec headers —
# letting the target instance's copy win is benign. Allow dpkg to overwrite so
# the cross install completes. Cross-only (native builds have no second instance).
if is_cross; then
  install -d /etc/apt/apt.conf.d
  printf 'Dpkg::Options { "--force-overwrite"; };\n' \
    > /etc/apt/apt.conf.d/99-cross-vulkan-force-overwrite
fi

if is_cross; then
  if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
    echo "Using staged target Python headers from $(cross_target_python_include_dir)"
  else
    echo "Target Python ${PYTHON_MAJOR_MINOR:-$(host_python_major_minor 2>/dev/null || echo unknown)} development files are missing for $(cross_target_triplet 2>/dev/null || echo target); disabling gst-python for this cross build"
  fi
fi

# Pre-setup dependencies
pre_setup_target_packages=(
  libx11-dev
  libxext-dev
  libxrender-dev
  libxau-dev
  libxdmcp-dev
  libxfixes-dev
  libsodium-dev
)

if [ "${MEDIA_SKIP_CAIRO_PANGO_PIXBUF:-0}" = "1" ]; then
  echo "Skipping libcairo2-dev, libpango1.0-dev and libgdk-pixbuf-2.0-dev for riscv64 cross builds because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
else
  pre_setup_target_packages=(libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev "${pre_setup_target_packages[@]}")
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

if [ "${MEDIA_SKIP_LIBCXX_DEV:-0}" = "1" ]; then
  echo "Skipping target libc++-dev and libc++abi-dev for riscv64 cross builds because Ubuntu Ports has broken dependencies for libc++-21-dev."
else
  gst_target_packages+=(
    libc++-dev
    libc++abi-dev
  )
fi

if [ "${MEDIA_SKIP_GLIB_STACK:-0}" = "1" ]; then
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

install_target_packages "${gst_target_packages[@]}" || true

apt-get purge -y 'libunwind-[0-9]*-dev' || true
install_target_packages libunwind-dev || true

# Install libdw-dev as host package too — its headers (elfutils/libdwfl.h) are
# arch-independent and required by GStreamer gstinfo.c for backtrace support.
install_host_packages libdw-dev libxml2-utils glslc glslang-tools gobject-introspection || true
if [ "${MEDIA_SKIP_GTK_DEV:-0}" = "1" ]; then
  echo "Skipping target GTK dev packages for riscv64 cross builds because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
else
  install_target_packages libgtk-3-dev libgtk-4-dev
fi

# Audio I/O and DSP — target-side dev packages (linked into cross plugins).
install_target_packages \
  libasound2-dev libpulse-dev libjack-dev libpipewire-0.3-dev \
  libsndfile1-dev libsamplerate0-dev || true

# Video capture / devices — target-side dev packages.
install_target_packages \
  libv4l-dev libusb-1.0-0-dev libdc1394-dev libraw1394-dev \
  libcdio-dev libcdparanoia-dev || true

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
  echo "Using toolchain Vulkan SDK from ${vulkan_prefix}; installing target libvulkan1 instead of libvulkan-dev."
  graphics_target_packages+=(libvulkan1)
else
  graphics_target_packages+=(libvulkan-dev)
fi

install_target_packages "${graphics_target_packages[@]}" || true

if [ "${MEDIA_SKIP_GUDEV:-0}" = "1" ]; then
  echo "Skipping libgudev-1.0-dev for riscv64 cross builds because Ubuntu Ports cannot satisfy its libglib2.0-dev helper dependency chain."
else
  install_target_packages libgudev-1.0-dev || true
fi

# Images / formats
# GTK/gdk-pixbuf probe these through the target-only pkg-config view during
# cross builds, so install the image development packages on the target side.
install_target_packages \
  libjpeg-turbo8-dev libpng-dev libtiff-dev libwebp-dev || true

# colormanagement needs lcms2. arm64 only got it transitively via
# libgdk-pixbuf-2.0-dev; riscv64 loses that path. No GLib dep, so no skip
# flag applies. docs/refactoring-backlog.md
install_target_packages liblcms2-dev || true

# libopenexr-3-dev is GONE on Ubuntu 26.04 (renamed libopenexr-dev); the dead
# first attempt only cost a failed apt round-trip every run. libvvdec-dev does
# not exist on ports at all, so the guard stays and vvdec builds from source.
install_target_packages libopenexr-dev || true

install_target_packages libvvdec-dev || true

# Codecs (audio)
# These are linked into target-side plugins such as gst-plugins-good/ext/lame,
# so cross builds need the target multiarch dev packages rather than host ones.
install_target_packages \
  libogg-dev libvorbis-dev libtheora-dev libopus-dev libflac-dev \
  libmpg123-dev libmp3lame-dev libtwolame-dev libspeex-dev libspeexdsp-dev \
  libwavpack-dev libgsm1-dev || true

# Codecs (video)
install_target_packages \
  libvpx-dev libaom-dev libdav1d-dev \
  libx264-dev libx265-dev libopenh264-dev || true
install_target_packages libsvtav1enc-dev || install_target_packages libsvtav1-dev || true

# FFmpeg (for gst-libav)
if [ -f /opt/ffmpeg/lib/pkgconfig/libavcodec.pc ]; then
  echo "Using staged FFmpeg build from /opt/ffmpeg for gst-libav; skipping distro FFmpeg dev packages."
else
  install_target_packages \
    libavcodec-dev libavformat-dev libavfilter-dev libavutil-dev \
    libswscale-dev libswresample-dev || true
fi

# Networking / crypto
# (libsoup-3.0-dev / libnice-dev are installed via install_target_packages below.)
# HLS crypto backends FIRST and on their OWN apt-get calls: install_target_packages
# runs one all-or-nothing `apt-get install` and silently swallows failure on cross,
# so bundling libssl-dev with a sibling that can't be co-installed on a flaky ports
# arch (e.g. libusrsctp-dev on riscv64) would leave gst-plugins-good's HLS with no
# crypto and hard-abort meson ("Could not get define 'OPENSSL_VERSION_*'"). nettle
# is HLS's preferred backend; libssl is the fallback — install both independently.
install_target_packages nettle-dev || true
install_target_packages libssl-dev || true
install_target_packages \
  libcurl4-openssl-dev libxml2-dev \
  zlib1g-dev libbz2-dev liblzma-dev libzstd-dev \
  libsrtp2-dev libusrsctp-dev || true
install_target_packages libsoup-3.0-dev libnice-dev || true

# Csound conditionally
if [ "${MEDIA_SKIP_CSOUND:-0}" = "1" ]; then
  echo "Skipping target Csound packages for $(cross_target_arch 2>/dev/null || echo target) cross builds because the Csound plugin is disabled on this target."
else
  # gst-plugin-csound only needs libcsound64 (lib + headers). Install it on its OWN
  # call so a heavy/absent sibling (csoundqt pulls Qt, pd-csound pulls puredata)
  # can't take the essential package down — install_target_packages is
  # all-or-nothing per call. The rest are best-effort extras.
  install_target_packages libcsound64-dev || true
  install_optional_target_packages csound csound-utils csoundqt csoundqt-examples csound-doc pd-csound || true
fi

# NVIDIA
NVIDIA_GPU="${NVIDIA_CODEC_HEADERS:-auto}"
if [ "${NVIDIA_GPU}" = "auto" ]; then
  if lspci 2>/dev/null | grep -qi nvidia; then NVIDIA_GPU="yes";
  elif [ -d /sys/class/drm ] && grep -q '^0x10de$' /sys/class/drm/card*/device/vendor 2>/dev/null; then NVIDIA_GPU="yes";
  elif [ -n "${NVIDIA_DRIVER_CAPABILITIES:-}" ] || [ -n "${NVIDIA_VISIBLE_DEVICES:-}" ]; then NVIDIA_GPU="yes";
  else NVIDIA_GPU="no"; fi
fi
if [ "${NVIDIA_GPU}" = "yes" ]; then
  # nv-codec-headers is NOT an apt package (it is the ffnvcodec git repo). The
  # ffmpeg stage git-clones + installs it to /usr/local (install-deps.sh, the nv-codec-headers clone),
  # so it is already available to gstreamer's nvcodec plugin. The old
  # `install_host_packages nv-codec-headers` here was a no-op that only logged a
  # spurious "skipped unavailable host package" from the resilient-apt fallback.
  :
fi

# NOTE: do NOT `rm -rf /var/lib/apt/lists/*` here — /var/lib/apt is a shared
# BuildKit cache mount in Dockerfile.media, so wiping it only forces the next
# stage's `apt-get update` to re-download every index (and it saves no image
# size, since a cache mount is not a layer).
