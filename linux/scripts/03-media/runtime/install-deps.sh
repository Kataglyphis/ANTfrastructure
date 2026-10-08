#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/install-deps-preamble.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/install-deps-preamble.sh
elif [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

# media_load_arch_flags (the per-arch MEDIA_SKIP_* flags) lives in 03-media/core/common.sh.
for _media_common in \
    "/opt/scripts/03-media/core/common.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../core/common.sh"; do
    if [ -f "${_media_common}" ]; then
        # shellcheck disable=SC1090
        source "${_media_common}" || { echo "FATAL: cannot load ${_media_common}" >&2; exit 1; }
        break
    fi
done
media_load_arch_flags

echo "Installing final stage dependencies..."

install_deps_preamble

normalize_vvdec_soname_link() {
    local soname_lib="/usr/local/lib/libvvdec.so.3"
    local real_lib="${soname_lib}.0.0"

    [ -e "${soname_lib}" ] || return 0
    [ -L "${soname_lib}" ] && return 0

    if [ ! -e "${real_lib}" ]; then
        mv "${soname_lib}" "${real_lib}"
    else
        rm -f "${soname_lib}"
    fi

    ln -snf "$(basename "${real_lib}")" "${soname_lib}"
    ln -snf "$(basename "${soname_lib}")" "/usr/local/lib/libvvdec.so"
}

DEBIAN_FRONTEND=noninteractive apt-get purge -y $(dpkg -l 'gstreamer*' 'gstreamer1.0*' 'libgstreamer*' 'libunwind-*-dev' 2>/dev/null | grep '^ii' | awk '{print $2}') 2>/dev/null || true
# GTK runtime only: the dev package pulls target-side Python, whose postinst breaks cross builds.
target_packages=(
    libunwind-dev libdw-dev libv4l-0 dbus-x11
    # riscv64 builds Pillow from source, which hard-fails without jpeglib.h.
    libjpeg-dev
    libopenexr-dev libx264-dev libcdio-dev libspeex-dev libopenh264-dev libsrtp2-dev
    libtwolame-dev libgsm1-dev libdav1d-dev libwavpack-dev libx265-dev libdc1394-dev
    libvpx-dev libavcodec-dev libcsound64-dev libtbb12 libavfilter-dev libavformat-dev
    libxml2-16 libbz2-1.0 liblzma5 libzstd1
    # Without libgudev ~9 GStreamer plugins fail to load (v4l2, va, gtk4, ...).
    libgudev-1.0-0 libcdparanoia0
    libevent-core-2.1-7t64 libevent-pthreads-2.1-7t64 libevent-2.1-7t64
    liborc-0.4-0t64 libsoup-3.0-0
    libexif12 libboost-program-options1.83.0
    libgsl28 libgslcblas0 libnuma1
)

# With MEDIA_SKIP_GLIB_STACK the plugins these packages serve were never built.
if [ "${MEDIA_SKIP_GLIB_STACK:-0}" = "1" ]; then
    echo "Skipping GTK/json-glib runtime packages for riscv64 cross final image"
else
    target_packages=(libgtk-4-1 libjson-glib-1.0-0 "${target_packages[@]}")
fi

# FFmpeg's own codec libs (libopencore-amrwb0, ...), which the cp314t store's proof loads PyAV against; cross proves nothing here.
ffmpeg_manifest="${FFMPEG_PREFIX:-/opt/ffmpeg}/runtime-apt-packages.txt"
if ! cross_build_is_active && [ -s "${ffmpeg_manifest}" ]; then
    mapfile -t ffmpeg_runtime_packages < <(sed '/^[[:space:]]*$/d' "${ffmpeg_manifest}")
    target_packages+=("${ffmpeg_runtime_packages[@]}")
fi
# Host packages on purpose: the image is a host-runnable cross-dev container, and :<target> installs conflict.
DEBIAN_FRONTEND=noninteractive install_host_packages "${target_packages[@]}" || true
apt-get autoremove --purge -y
apt-get clean
normalize_vvdec_soname_link
ldconfig
