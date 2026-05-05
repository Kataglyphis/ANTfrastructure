#!/usr/bin/env bash
set -eux

if [ -f /opt/scripts/core/cross-env.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/core/cross-env.sh
fi

echo "Installing final stage dependencies..."

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get purge -y 'gstreamer*' 'gstreamer1.0*' 'libgstreamer*' 'libunwind-*-dev' || true
DEBIAN_FRONTEND=noninteractive install_target_packages \
    libunwind-dev libdw-dev libgtk-4-dev libv4l-0 libjson-glib-1.0-0 dbus-x11 \
    libopenexr-dev libx264-dev libcdio-dev libspeex-dev libopenh264-dev libsrtp2-dev \
    libtwolame-dev libgsm1-dev libdav1d-dev libwavpack-dev libx265-dev libdc1394-dev \
    libvpx-dev libavcodec-dev libcsound64-dev libtbb12 libavfilter9 libavfilter-dev libavformat-dev || true
apt-get autoremove --purge -y
apt-get clean
ldconfig
