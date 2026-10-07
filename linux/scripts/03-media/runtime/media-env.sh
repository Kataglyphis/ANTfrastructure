#!/usr/bin/env bash
set -euo pipefail
# Media paths shared by Dockerfile.media and Dockerfile.package; 04-runtime/verify-runtime-paths.sh checks them.

set -a

: "${GSTREAMER_PREFIX:=/opt/gstreamer}"
: "${OPENCV_PREFIX:=/opt/opencv5}"
: "${FFMPEG_PREFIX:=/opt/ffmpeg}"
: "${LIBCAMERA_PREFIX:=/opt/libcamera}"

# The one wheelhouse the runtime wheel scripts share.
: "${WHEELS_DIR:=/opt/wheels}"
# Its cp314t twins, a store of their own: docs/consumer-image-contract.md#the-free-threaded-wheels
: "${FT_WHEELS_DIR:=/opt/wheels-cp314t}"

PATH="${GSTREAMER_PREFIX}/bin:${OPENCV_PREFIX}/bin:${LIBCAMERA_PREFIX}/bin:${FFMPEG_PREFIX}/bin:/usr/local/bin:${PATH}"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${GSTREAMER_PREFIX}/lib/multiarch/pkgconfig:${OPENCV_PREFIX}/lib/pkgconfig:${LIBCAMERA_PREFIX}/lib/pkgconfig:${LIBCAMERA_PREFIX}/lib64/pkgconfig:${FFMPEG_PREFIX}/lib/pkgconfig"
LD_LIBRARY_PATH="/opt/gcc-${GCC_VERSION:-16.2.0}/lib64:/opt/gcc-${GCC_VERSION:-16.2.0}/lib:/usr/local/lib:${GSTREAMER_PREFIX}/lib/multiarch:${GSTREAMER_PREFIX}/lib:${OPENCV_PREFIX}/lib:${OPENCV_PREFIX}/lib64:${LIBCAMERA_PREFIX}/lib:${LIBCAMERA_PREFIX}/lib64:${FFMPEG_PREFIX}/lib:${FFMPEG_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
GDK_BACKEND="x11"
GST_PLUGIN_PATH="${GSTREAMER_PREFIX}/lib/multiarch/gstreamer-1.0:${LIBCAMERA_PREFIX}/lib/gstreamer-1.0"
GI_TYPELIB_PATH="${GSTREAMER_PREFIX}/lib/multiarch/girepository-1.0"

set +a
