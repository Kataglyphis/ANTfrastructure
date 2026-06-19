#!/usr/bin/env bash
set -euo pipefail

for _cv_env in \
    "/opt/scripts/core/install-deps-preamble.sh" \
    "/opt/scripts/core/cross-env.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../01-core/cross-env.sh"; do
    if [ -f "${_cv_env}" ]; then
        source "${_cv_env}" || { echo "FATAL: cannot load ${_cv_env}" >&2; exit 1; }
        break
    fi
done

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
        _ft_ver="2.14.2"
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
