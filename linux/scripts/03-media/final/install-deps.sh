#!/usr/bin/env bash
set -eux

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

echo "Installing final stage dependencies..."

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

if command -v cross_apt_update >/dev/null 2>&1; then
    cross_apt_update
else
    apt-get update
fi
DEBIAN_FRONTEND=noninteractive apt-get purge -y 'gstreamer*' 'gstreamer1.0*' 'libgstreamer*' 'libunwind-*-dev' || true
# The final image only needs GTK runtime bits. Installing the foreign-arch
# GTK dev package pulls the GLib/GIR dev chain, which in turn tries to install
# target-side Python during cross builds and breaks on python3-minimal postinst.
target_packages=(
    libunwind-dev libdw-dev libv4l-0 dbus-x11
    libopenexr-dev libx264-dev libcdio-dev libspeex-dev libopenh264-dev libsrtp2-dev
    libtwolame-dev libgsm1-dev libdav1d-dev libwavpack-dev libx265-dev libdc1394-dev
    libvpx-dev libavcodec-dev libcsound64-dev libtbb12 libavfilter-dev libavformat-dev
)

if command -v cross_build_enabled >/dev/null 2>&1 && cross_build_enabled && \
   command -v cross_target_arch >/dev/null 2>&1 && \
   [ "$(cross_target_arch)" = "riscv64" ]; then
    # The riscv64 GStreamer build skips the GTK/json-glib dependent plugins
    # because Ubuntu Ports cannot currently provide a clean cross dependency
    # chain for them. Installing the runtime packages here only adds target-side
    # postinst noise without enabling extra shipped functionality.
    echo "Skipping GTK/json-glib runtime packages for riscv64 cross final image"
else
    target_packages=(libgtk-4-1 libjson-glib-1.0-0 "${target_packages[@]}")
fi

DEBIAN_FRONTEND=noninteractive install_target_packages "${target_packages[@]}" || true
apt-get autoremove --purge -y
apt-get clean
normalize_vvdec_soname_link
ldconfig
