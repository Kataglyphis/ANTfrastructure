#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/install-deps-preamble.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/install-deps-preamble.sh
elif [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

# Load the data-driven per-arch MEDIA_SKIP_* flags (arch-flags-<arch>.env).
# media_load_arch_flags lives in 03-media/core/common.sh: in the container it
# is COPY'd to /opt/scripts/03-media/core (base stage), in the repo it sits at
# linux/scripts/03-media/core. The preamble above already provided the
# cross_build_is_active / cross_target_arch helpers it needs.
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
# The final image only needs GTK runtime bits. Installing the foreign-arch
# GTK dev package pulls the GLib/GIR dev chain, which in turn tries to install
# target-side Python during cross builds and breaks on python3-minimal postinst.
target_packages=(
    libunwind-dev libdw-dev libv4l-0 dbus-x11
    # libjpeg-dev (jpeglib.h + native libjpeg): required for the torch venv's
    # Pillow build. On riscv64, PyPI ships no wheel so pip compiles Pillow from
    # source under QEMU; Pillow enables JPEG by default and hard-fails without
    # these headers. zlib/freetype are already present in the base image.
    libjpeg-dev
    libopenexr-dev libx264-dev libcdio-dev libspeex-dev libopenh264-dev libsrtp2-dev
    libtwolame-dev libgsm1-dev libdav1d-dev libwavpack-dev libx265-dev libdc1394-dev
    libvpx-dev libavcodec-dev libcsound64-dev libtbb12 libavfilter-dev libavformat-dev
    libxml2 libbz2-1.0 liblzma5 libzstd1
    libevent-core-2.1-7t64 libevent-pthreads-2.1-7t64 libevent-2.1-7t64
    liborc-0.4-0t64 libsoup-3.0-0
    libexif12 libboost-program-options1.83.0
    libgsl28 libgslcblas0 libnuma1
)

# MEDIA_SKIP_GLIB_STACK (arch-flags-riscv64.env): when the GStreamer build
# skipped the GTK/json-glib dependent plugins, installing the runtime packages
# here only adds target-side postinst noise without enabling extra shipped
# functionality.
if [ "${MEDIA_SKIP_GLIB_STACK:-0}" = "1" ]; then
    echo "Skipping GTK/json-glib runtime packages for riscv64 cross final image"
else
    target_packages=(libgtk-4-1 libjson-glib-1.0-0 "${target_packages[@]}")
fi

# HOST packages, deliberately: this final image is a host-runnable cross-dev
# container (PLATFORM linux/amd64 even for arm64/riscv64 targets), and these
# are runtime/dev deps for the HOST-side tools baked into it. Historically this
# ran through the install-deps-preamble FALLBACK (no 01-core mounted), whose
# install_target_packages degraded to host installs — so host semantics is
# what every shipped image has always had. Now that the final stage mounts
# 01-core (real cross-env), keep that behavior EXPLICIT: with real
# install_target_packages the whole group resolves as :<target-arch> and fails
# wholesale on cross (co-installation conflicts), leaving the image with none
# of these packages.
DEBIAN_FRONTEND=noninteractive install_host_packages "${target_packages[@]}" || true
apt-get autoremove --purge -y
apt-get clean
normalize_vvdec_soname_link
ldconfig
