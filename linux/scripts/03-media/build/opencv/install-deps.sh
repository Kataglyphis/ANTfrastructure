#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_install_deps_init "${SCRIPT_DIR}"

: "${WITH_PYTHON:=true}"
: "${WITH_JAVA:=false}"
: "${OPENCV_PYTHON_VERSION:=$(host_python_major_minor)}"
cross_arch=""

echo "Installing OpenCV build dependencies..."

install_deps_preamble build-essential cmake git pkg-config wget unzip libtbb-dev libeigen3-dev

target_packages=(
    libavcodec-dev
    libavformat-dev
    libswscale-dev
    libv4l-dev
    libxvidcore-dev
    libx264-dev
    libjpeg-dev
    libpng-dev
    libtiff-dev
    libopenexr-dev
    libunwind-dev
    libdc1394-dev
)

if is_cross; then
    echo "Skipping libgtk-3-dev for cross builds because libpango1.0-dev is not multiarch-coinstallable."
    cross_arch="$(cross_target_arch 2>/dev/null || true)"
    if [ "${cross_arch}" = "riscv64" ]; then
        echo "Skipping GStreamer dev packages for riscv64 cross builds because Ubuntu Ports cannot satisfy their GLib helper dependency chain."
        echo "Installing riscv64 target OpenCV codec/video deps on a best-effort basis because Ubuntu Ports currently has broken dependency sets for some packages (for example FFmpeg/libpng)."
    elif [ "${cross_arch}" = "arm64" ]; then
        echo "Arm64 target OpenCV deps: adding GStreamer dev packages but using best-effort install"
        echo "(multiarch harfbuzz/libgraphite2 dependency chain is broken on this Ubuntu release)"
        target_packages+=(libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev)
    else
        target_packages+=(libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev)
    fi
else
    target_packages=(libgtk-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev "${target_packages[@]}")
fi

if { cross_build_is_active 2>/dev/null || cross_build_enabled; } && [ "$(cross_target_arch)" = "riscv64" ]; then
    install_optional_target_packages "${target_packages[@]}"
elif { cross_build_is_active 2>/dev/null || cross_build_enabled; } && [ "$(cross_target_arch)" = "arm64" ]; then
    install_optional_target_packages "${target_packages[@]}"
else
    install_target_packages "${target_packages[@]}"
fi

if [ "${WITH_PYTHON}" = "true" ]; then
    if is_cross; then
        if command -v cross_target_python_dev_ready >/dev/null 2>&1 && cross_target_python_dev_ready; then
            echo "[INFO] Using staged target Python headers from $(cross_target_python_include_dir)"
        else
            echo "[WARN] Target Python ${OPENCV_PYTHON_VERSION} development files are missing for $(cross_target_triplet 2>/dev/null || echo target); disabling OpenCV Python bindings for this cross build"
        fi
    else
        echo "[INFO] Python dependencies are satisfied via source build and uv."
    fi
fi

if [ "${WITH_JAVA}" = "true" ]; then
    apt-get install -y --no-install-recommends default-jdk ant || true
fi

# Target arch apt sources are configured in Dockerfile.media. Just install freetype/harfbuzz.
if is_cross && [ "$(cross_target_arch)" != "amd64" ]; then
    _ft_arch="$(cross_target_arch 2>/dev/null || true)"
    # Try to install freetype + harfbuzz target packages from Ubuntu Ports
    if ! dpkg -l "libfreetype-dev:${_ft_arch}" >/dev/null 2>&1; then
        install_target_packages libfreetype-dev libharfbuzz-dev || true
    fi
    # If still not installed (package not available), cross-compile freetype from source.
    _ft_triplet="$(cross_target_triplet 2>/dev/null || true)"
    _ft_ver="${FREETYPE_VERSION:-2.14.3}"
    if [ -n "${_ft_triplet}" ]; then
        cross_compile_cmake_lib_from_source freetype \
          "https://github.com/freetype/freetype/archive/refs/tags/VER-${_ft_ver//./-}.tar.gz" \
          "/usr/${_ft_triplet}" "/usr/lib/${_ft_triplet}/libfreetype.so" \
          -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
          -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
          -DBUILD_SHARED_LIBS=ON \
          -DFT_DISABLE_BZIP2=ON \
          -DFT_DISABLE_PNG=ON \
          -DFT_DISABLE_HARFBUZZ=ON \
          -DFT_DISABLE_BROTLI=ON
    fi
fi

# OpenCV 5.x's vendored libpng fails its RISC-V Vector configure probe under GCC
# 16.1.0, so the riscv64 OpenCV build links an EXTERNAL libpng instead (WITH_PNG=ON
# + BUILD_PNG=OFF in build-opencv.sh) so cv2.imencode('.png', ...) works. Build a
# PIC STATIC libpng from source so it links directly into opencv_imgcodecs.so --
# matching how the vendored libpng is bundled on the other arches, with NO extra
# runtime .so to stage into the final image (its only symbols, zlib's, resolve
# against the libz OpenCV already links). PNG_HARDWARE_OPTIMIZATIONS=OFF skips the
# RISC-V Vector intrinsics probe. Ubuntu Ports' libpng-dev:riscv64 dep set is
# frequently broken, so we build from source not apt.
if is_cross && [ "$(cross_target_arch 2>/dev/null || true)" = "riscv64" ]; then
    _png_triplet="$(cross_target_triplet 2>/dev/null || true)"
    _png_ver="${LIBPNG_VERSION:-1.6.58}"
    if [ -n "${_png_triplet}" ]; then
        # Mirrors tried in order by cross_compile_cmake_lib_from_source. curl to
        # codeload.github.com / downloads.sourceforge.net FAILS inside the buildkit
        # RUN (iree-0714a..0714e), silently dropping PNG, so the git-clone spec
        # leads — git reaches github.com where curl to codeload cannot — with the
        # two tarball mirrors kept as fallbacks for environments where curl works.
        cross_compile_cmake_lib_from_source libpng \
          "git+https://github.com/pnggroup/libpng#v${_png_ver}|https://github.com/pnggroup/libpng/archive/refs/tags/v${_png_ver}.tar.gz|https://downloads.sourceforge.net/project/libpng/libpng16/${_png_ver}/libpng-${_png_ver}.tar.gz" \
          "/usr/${_png_triplet}" "/usr/${_png_triplet}/lib/libpng16.a" \
          -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
          -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
          -DZLIB_INCLUDE_DIR=/usr/include \
          -DZLIB_LIBRARY="/usr/lib/${_png_triplet}/libz.so" \
          -DPNG_SHARED=OFF \
          -DPNG_STATIC=ON \
          -DPNG_TESTS=OFF \
          -DPNG_HARDWARE_OPTIMIZATIONS=OFF \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    fi
fi
