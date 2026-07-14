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
    # If still not installed (package not available), cross-compile freetype from source
    _ft_triplet="$(cross_target_triplet 2>/dev/null || true)"
    if [ -n "${_ft_triplet}" ] && [ ! -f "/usr/lib/${_ft_triplet}/libfreetype.so" ]; then
        echo "[INFO] Target libfreetype-dev:${_ft_arch} not in repos. Cross-compiling from source..."
        _ft_src="/tmp/freetype-src-$$"
        _ft_ver="${FREETYPE_VERSION:-2.14.2}"
        rm -rf "${_ft_src}"
        mkdir -p "${_ft_src}"
        curl -sL "https://github.com/freetype/freetype/archive/refs/tags/VER-${_ft_ver//./-}.tar.gz" \
          | tar -xzf - -C "${_ft_src}" --strip-components=1 || true
        if [ ! -f "${_ft_src}/CMakeLists.txt" ]; then
            echo "[WARN] Failed to download freetype source"
        else
        mkdir -p "${_ft_src}/build"
        cd "${_ft_src}/build"
        cmake .. \
          -DCMAKE_SYSTEM_NAME=Linux \
          -DCMAKE_SYSTEM_PROCESSOR="${_ft_arch}" \
          -DCMAKE_C_COMPILER="${_ft_triplet}-gcc" \
          -DCMAKE_CXX_COMPILER="${_ft_triplet}-g++" \
          -DCMAKE_FIND_ROOT_PATH="/usr/${_ft_triplet};/usr/lib/${_ft_triplet}" \
          -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
          -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
          -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
          -DCMAKE_INSTALL_PREFIX="/usr/${_ft_triplet}" \
          -DBUILD_SHARED_LIBS=ON \
          -DFT_DISABLE_BZIP2=ON \
          -DFT_DISABLE_PNG=ON \
          -DFT_DISABLE_HARFBUZZ=ON \
          -DFT_DISABLE_BROTLI=ON \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        cmake --build . --target install -j"$(nproc)" 2>/dev/null || {
            echo "[WARN] Failed to build freetype from source"
        }
        rm -rf "${_ft_src}"
        fi
    fi
fi

# OpenCV 5.x's vendored libpng fails its RISC-V Vector configure probe under GCC
# 16.1.0, so the riscv64 OpenCV build links an EXTERNAL libpng instead (WITH_PNG=ON
# + BUILD_PNG=OFF in build-opencv.sh) so cv2.imencode('.png', ...) works. Build a
# PIC STATIC libpng from source so it links directly into opencv_imgcodecs.so --
# matching how the vendored libpng is bundled on the other arches, with NO extra
# runtime .so to stage into the final image (its only symbols, zlib's, resolve
# against the libz OpenCV already links). Ubuntu Ports' libpng-dev:riscv64 dep set
# is frequently broken, so we don't rely on apt. Same source pattern as freetype.
if is_cross && [ "$(cross_target_arch 2>/dev/null || true)" = "riscv64" ]; then
    _png_triplet="$(cross_target_triplet 2>/dev/null || true)"
    if [ -n "${_png_triplet}" ] \
       && [ ! -f "/usr/${_png_triplet}/lib/libpng16.a" ] \
       && [ ! -f "/usr/${_png_triplet}/lib/libpng16_static.a" ]; then
        echo "[INFO] Cross-compiling static libpng for riscv64 OpenCV PNG support..."
        _png_src="/tmp/libpng-src-$$"
        _png_ver="${LIBPNG_VERSION:-1.6.44}"
        rm -rf "${_png_src}"
        mkdir -p "${_png_src}"
        curl -sL "https://github.com/pnggroup/libpng/archive/refs/tags/v${_png_ver}.tar.gz" \
          | tar -xzf - -C "${_png_src}" --strip-components=1 || true
        if [ ! -f "${_png_src}/CMakeLists.txt" ]; then
            echo "[WARN] Failed to download libpng source; riscv64 OpenCV will build without PNG"
        else
            mkdir -p "${_png_src}/build"
            cd "${_png_src}/build"
            # PNG_HARDWARE_OPTIMIZATIONS=OFF skips the RISC-V Vector intrinsics probe
            # that breaks OpenCV's vendored copy; scalar libpng is correct, just slower.
            # Static + PIC so it links straight into the opencv_imgcodecs shared lib.
            cmake .. \
              -DCMAKE_SYSTEM_NAME=Linux \
              -DCMAKE_SYSTEM_PROCESSOR=riscv64 \
              -DCMAKE_C_COMPILER="${_png_triplet}-gcc" \
              -DCMAKE_FIND_ROOT_PATH="/usr/${_png_triplet};/usr/lib/${_png_triplet}" \
              -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
              -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
              -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
              -DCMAKE_INSTALL_PREFIX="/usr/${_png_triplet}" \
              -DZLIB_INCLUDE_DIR=/usr/include \
              -DZLIB_LIBRARY="/usr/lib/${_png_triplet}/libz.so" \
              -DPNG_SHARED=OFF \
              -DPNG_STATIC=ON \
              -DPNG_TESTS=OFF \
              -DPNG_HARDWARE_OPTIMIZATIONS=OFF \
              -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
              -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_POLICY_VERSION_MINIMUM=3.5
            cmake --build . --target install -j"$(nproc)" || {
                echo "[WARN] Failed to build libpng from source; riscv64 OpenCV will build without PNG"
            }
            rm -rf "${_png_src}"
        fi
    fi
fi
