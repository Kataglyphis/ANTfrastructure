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

install_deps_preamble build-essential cmake git pkg-config wget unzip libeigen3-dev

target_packages=(
    libtbb-dev
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
    libavif-dev
    libhdf5-dev
)

if is_cross; then
    echo "Skipping libgtk-3-dev for cross builds because libpango1.0-dev is not multiarch-coinstallable."
    cross_arch="$(cross_target_arch 2>/dev/null || true)"
    if [ "${cross_arch}" = "riscv64" ]; then
        # The ports glib dev stack broke real builds, but its stated empty-prefix cause did not reproduce; reproduce before re-enabling.
        echo "Skipping GStreamer dev packages for riscv64: ports' glib-2.0.pc poisons cross pkg-config (RV1-GST-PC)"
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

# Cross installs are best-effort, so log which requested dev packages arrived; a Ports outage otherwise strips features silently.
if is_cross && [ -n "${cross_arch}" ] && [ "${cross_arch}" != "amd64" ]; then
    _ocv_missing=()
    for _ocv_pkg in "${target_packages[@]}"; do
        dpkg -s "${_ocv_pkg}:${cross_arch}" >/dev/null 2>&1 || _ocv_missing+=("${_ocv_pkg}")
    done
    if [ "${#_ocv_missing[@]}" -gt 0 ]; then
        echo "[WARN] opencv cross deps (${cross_arch}): $(( ${#target_packages[@]} - ${#_ocv_missing[@]} ))/${#target_packages[@]} present; MISSING: ${_ocv_missing[*]} (features built without them; runtime smoke gates the codec surface)"
    else
        echo "[INFO] opencv cross deps (${cross_arch}): all ${#target_packages[@]} requested target dev packages present"
    fi
fi

# Pass 2 links /opt/ffmpeg, so cv2 needs the apt codec libs build-ffmpeg.sh recorded; native only, as the names are unqualified.
_ocv_ff_manifest="${FFMPEG_PREFIX:-/opt/ffmpeg}/runtime-apt-packages.txt"
if ! is_cross && [ -s "${_ocv_ff_manifest}" ]; then
    _ocv_ff_pkgs=()
    _ocv_ff_skipped=()
    _ocv_ff_pkg=""   # set -u: the `|| [ -n ... ]` read guard reads it first
    while IFS= read -r _ocv_ff_pkg || [ -n "${_ocv_ff_pkg}" ]; do
        case "${_ocv_ff_pkg}" in ''|'#'*) continue ;; esac
        if cross_package_has_install_candidate "${_ocv_ff_pkg}"; then
            _ocv_ff_pkgs+=("${_ocv_ff_pkg}")
        else
            _ocv_ff_skipped+=("${_ocv_ff_pkg}")
        fi
    done < "${_ocv_ff_manifest}"
    [ "${#_ocv_ff_skipped[@]}" -eq 0 ] \
        || echo "[WARN] opencv: FFmpeg runtime codec package(s) with no apt candidate: ${_ocv_ff_skipped[*]}"
    if [ "${#_ocv_ff_pkgs[@]}" -gt 0 ]; then
        echo "[INFO] opencv: installing ${#_ocv_ff_pkgs[@]} FFmpeg runtime codec package(s) from ${_ocv_ff_manifest} (cv2 links the source-built FFmpeg)"
        install_optional_target_packages "${_ocv_ff_pkgs[@]}"
    fi
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
    # Not libharfbuzz-dev on riscv64: it depends on the banned ports libglib2.0-dev; the static build below covers both passes.
    if ! dpkg -l "libfreetype-dev:${_ft_arch}" >/dev/null 2>&1; then
        if [ "${_ft_arch}" = "riscv64" ]; then
            install_target_packages libfreetype-dev || true
        else
            install_target_packages libfreetype-dev libharfbuzz-dev || true
        fi
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

# See docs/failure-modes.md § RV1-FREETYPE: riscv64 OpenCV freetype/harfbuzz
if is_cross && [ "$(cross_target_arch 2>/dev/null || true)" = "riscv64" ]; then
    _hb_triplet="$(cross_target_triplet 2>/dev/null || true)"
    _hb_ver="${HARFBUZZ_VERSION:-12.3.2}"
    if [ -n "${_hb_triplet}" ] \
       && [ -f "/usr/lib/${_hb_triplet}/libfreetype.so" ] \
       && [ -f /usr/include/freetype2/ft2build.h ]; then
        cross_compile_cmake_lib_from_source harfbuzz \
          "git+https://github.com/harfbuzz/harfbuzz#${_hb_ver}|https://github.com/harfbuzz/harfbuzz/archive/refs/tags/${_hb_ver}.tar.gz" \
          "/usr/${_hb_triplet}" "/usr/${_hb_triplet}/lib/libharfbuzz.a" \
          -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
          -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
          -DBUILD_SHARED_LIBS=OFF \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DHB_HAVE_FREETYPE=ON \
          -DHB_BUILD_SUBSET=OFF \
          -DFREETYPE_LIBRARY="/usr/lib/${_hb_triplet}/libfreetype.so" \
          -DFREETYPE_INCLUDE_DIR_ft2build=/usr/include/freetype2 \
          -DFREETYPE_INCLUDE_DIR_freetype2=/usr/include/freetype2
        # Requires, not Requires.private: the static archive's FT_* refs need libfreetype after it on the link line.
        _hb_pc="/usr/${_hb_triplet}/lib/pkgconfig/harfbuzz.pc"
        if [ -f "${_hb_pc}" ]; then
            sed -i 's/^Requires\.private: freetype2/Requires: freetype2/' "${_hb_pc}"
        fi
    else
        echo "[WARN] harfbuzz (riscv64): ports freetype dev files missing (/usr/lib/${_hb_triplet:-<triplet>}/libfreetype.so or /usr/include/freetype2/ft2build.h); skipping harfbuzz source build"
    fi
    # Best-effort must not mean silent: log whether it was staged.
    if [ -n "${_hb_triplet}" ] \
       && [ -f "/usr/${_hb_triplet}/lib/libharfbuzz.a" ] \
       && [ -f "/usr/${_hb_triplet}/include/harfbuzz/hb-ft.h" ] \
       && [ -f "/usr/${_hb_triplet}/lib/pkgconfig/harfbuzz.pc" ]; then
        echo "[INFO] harfbuzz (riscv64): static target harfbuzz ${_hb_ver} staged at /usr/${_hb_triplet} (lib+hb-ft.h+pc)"
    else
        echo "[WARN] harfbuzz (riscv64): static target harfbuzz NOT staged; build-opencv.sh will keep BUILD_opencv_freetype=OFF"
    fi
fi

# riscv64 OpenCV's vendored libpng fails its RVV probe; a PIC static one links into imgcodecs with no extra runtime .so.
if is_cross && [ "$(cross_target_arch 2>/dev/null || true)" = "riscv64" ]; then
    _png_triplet="$(cross_target_triplet 2>/dev/null || true)"
    _png_ver="${LIBPNG_VERSION:-1.6.58}"
    if [ -n "${_png_triplet}" ]; then
        # git+ leads: curl to codeload/sourceforge fails inside the buildkit RUN where git clone works.
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
