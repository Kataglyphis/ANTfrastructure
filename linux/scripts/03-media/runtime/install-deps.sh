#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/scripts/core/install-deps-preamble.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/install-deps-preamble.sh
elif [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

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
    libopenexr-dev libx264-dev libcdio-dev libspeex-dev libopenh264-dev libsrtp2-dev
    libtwolame-dev libgsm1-dev libdav1d-dev libwavpack-dev libx265-dev libdc1394-dev
    libvpx-dev libavcodec-dev libcsound64-dev libtbb12 libavfilter-dev libavformat-dev
    libxml2 libbz2-1.0 liblzma5 libzstd1
    libevent-core-2.1-7t64 libevent-pthreads-2.1-7t64 libevent-2.1-7t64
    liborc-0.4-0t64 libsoup-3.0-0
    libexif12 libboost-program-options1.83.0
    libgsl28 libgslcblas0 libnuma1
)

if is_cross && \
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
