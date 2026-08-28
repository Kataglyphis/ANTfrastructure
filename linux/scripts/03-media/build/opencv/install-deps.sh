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
)

if is_cross; then
    echo "Skipping libgtk-3-dev for cross builds because libpango1.0-dev is not multiarch-coinstallable."
    cross_arch="$(cross_target_arch 2>/dev/null || true)"
    if [ "${cross_arch}" = "riscv64" ]; then
        # RV1 REVERTED FOR GSTREAMER-DEV (2026-08-20, after 5 live failures):
        # ports DOES ship the packages now, but its riscv64 glib-2.0.pc
        # expands prefix/libdir EMPTY in cross pkg-config contexts — and once
        # installed it POISONS every glib lookup in the stage (opencv imported
        # targets, libcamera's gst element compile AND link all died on it;
        # wave-3 behavior without the package was clean). Availability !=
        # cross-coinstallable. Do NOT install gstreamer/glib dev here until
        # RV1-GST-PC fixes the expansion; the two-pass opencv-gst pass-2
        # still links OUR /opt/gstreamer.
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

# The cross arches route EVERYTHING through the optional installer above
# (documented broken dep chains on this rolling Ubuntu; riscv64 additionally
# has the static-libpng fallback, so even codec dev packages may not be hard
# requirements). That tolerance must not mean SILENCE: a Ports outage used to
# strip features with no trace until the runtime smoke. Emit one greppable
# presence verdict per install so the build log shows exactly which requested
# dev packages the target arch actually got. (Functional codec coverage is
# gated downstream by the runtime opencv smoke — this line is for diagnosis.)
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
    # Try to install freetype + harfbuzz target packages from Ubuntu Ports.
    # riscv64 requests ONLY libfreetype-dev: libharfbuzz-dev:riscv64 Depends on
    # libglib2.0-dev — the exact ports package RV1-GST-PC banned (its riscv64
    # glib-2.0.pc expands prefix EMPTY in cross pkg-config contexts and poisons
    # every glib lookup). The 2026-08-22 riscv64 media log proves the old
    # unconditional request really dragged libglib2.0-dev:riscv64 into the
    # PASS-1 opencv sysroot, while PASS-2 (FROM gstreamer, libfreetype-dev
    # pre-satisfied by gstreamer's dep chain) skipped this block entirely and
    # got NO harfbuzz dev at all — the pass asymmetry behind RV1-FREETYPE.
    # riscv64 harfbuzz comes from the static source build below instead,
    # identically in both passes.
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

# RV1-FREETYPE (2026-08-24): riscv64 needs a TARGET harfbuzz for OpenCV's
# contrib freetype module (it uses the hb-ft API: hb_ft_font_create), but the
# ports dev package is off-limits (libharfbuzz-dev:riscv64 → Depends:
# libglib2.0-dev = the RV1-GST-PC poison, see above) and /opt/gstreamer's
# meson-subproject harfbuzz does not exist yet in pass-1. Build a PIC STATIC
# harfbuzz from source — the libpng discipline below: it links directly into
# libopencv_freetype.so, so NO extra runtime .so has to be staged (the only
# new runtime NEEDED is libfreetype.so.6, which so-package-map.txt already
# resolves to libfreetype6). HB_HAVE_FREETYPE=ON compiles the hb-ft glue the
# module requires; the explicit FREETYPE_* cache pins keep harfbuzz's
# FindFreetype off the HOST libs entirely (no find_* fall-through, and
# MODE=ONLY hard-walls anything else). Gated on the ports freetype dev files
# this build links against — if they are missing, skip loudly and
# build-opencv.sh keeps the module OFF (graceful, matches today's shipped
# behavior). git+ mirror leads for the same reason as libpng's below: curl to
# codeload.github.com fails inside the buildkit RUN while git clone works.
# 12.3.2 = today's ports harfbuzz (arm64 dev + riscv64 runtime 12.3.2-2);
# HARFBUZZ_VERSION env overrides (not yet a versions.env pin — local default,
# same pattern as FREETYPE_VERSION's fallback).
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
        # The generated harfbuzz.pc declares freetype under Requires.private,
        # which a plain `pkg-config --libs harfbuzz` omits. OpenCV's contrib
        # module links `<objects> ${FREETYPE_LIBRARIES} ${HARFBUZZ_LIBRARIES}`
        # under -Wl,--no-undefined, and with a STATIC libharfbuzz.a the
        # archive's FT_* refs are NOT resolved by a libfreetype DSO that
        # appeared EARLIER on the link line (proven by a local link experiment
        # 2026-08-24: objects+ft.so+hb.a fails with undefined FT_*;
        # objects+ft.so+hb.a+ft.so links clean). Promote the dep to Requires
        # so ocv_check_modules appends the TARGET libfreetype.so AFTER the
        # archive inside HARFBUZZ_LIBRARIES. Our .pc bakes an absolute
        # prefix=/usr/${_hb_triplet} (cmake-generated), so this cannot
        # reintroduce the RV1-GST-PC empty-prefix poison shape.
        _hb_pc="/usr/${_hb_triplet}/lib/pkgconfig/harfbuzz.pc"
        if [ -f "${_hb_pc}" ]; then
            sed -i 's/^Requires\.private: freetype2/Requires: freetype2/' "${_hb_pc}"
        fi
    else
        echo "[WARN] harfbuzz (riscv64): ports freetype dev files missing (/usr/lib/${_hb_triplet:-<triplet>}/libfreetype.so or /usr/include/freetype2/ft2build.h); skipping harfbuzz source build"
    fi
    # Greppable presence verdict (same rationale as the dev-package verdict
    # above: best-effort tolerance must not mean silence).
    if [ -n "${_hb_triplet}" ] \
       && [ -f "/usr/${_hb_triplet}/lib/libharfbuzz.a" ] \
       && [ -f "/usr/${_hb_triplet}/include/harfbuzz/hb-ft.h" ] \
       && [ -f "/usr/${_hb_triplet}/lib/pkgconfig/harfbuzz.pc" ]; then
        echo "[INFO] harfbuzz (riscv64): static target harfbuzz ${_hb_ver} staged at /usr/${_hb_triplet} (lib+hb-ft.h+pc)"
    else
        echo "[WARN] harfbuzz (riscv64): static target harfbuzz NOT staged; build-opencv.sh will keep BUILD_opencv_freetype=OFF"
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
