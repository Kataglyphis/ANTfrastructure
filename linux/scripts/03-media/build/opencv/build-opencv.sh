#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# build-opencv.sh - Build and install OpenCV from source
# ==============================================================================
# This script fetches a specific version of OpenCV and builds it with
# commonly used modules and features enabled.
#
# Usage:
#   ./build-opencv.sh [--opencv-version VERSION]
#
# Defaults can be overridden via environment variables or arguments.
#
# Build Acceleration:
#   USE_CCACHE=true     Enable ccache for faster rebuilds (default: true)
#   USE_LLD=true        Use lld linker for faster linking (default: true)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"
install_warn_trap

# Defaults (can be overridden via env vars or arguments)
: "${OPENCV_VERSION:=5.x}"
: "${OPENCV_SRC:=${TMPDIR:-/tmp}/opencv-$$}"
: "${OPENCV_PREFIX:=/opt/opencv5}"
: "${OPENCV_REPO:=https://github.com/opencv/opencv.git}"
: "${OPENCV_CONTRIB_REPO:=https://github.com/opencv/opencv_contrib.git}"
: "${BUILD_TYPE:=Release}"
: "${NPROC:=$(media_jobs)}"
: "${WITH_CONTRIB:=true}"
: "${WITH_PYTHON:=true}"
: "${OPENCV_PYTHON_VERSION:=$(host_python_major_minor)}"
: "${WITH_JAVA:=false}"
: "${SKIP_DEP_INSTALL:=false}"
: "${WITH_IPP:=ON}"

HOST_PYTHON=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --opencv-version|-v)
            OPENCV_VERSION="$2"
            shift 2
            ;;
        --prefix|-p)
            OPENCV_PREFIX="$2"
            shift 2
            ;;
        --build-type|-b)
            BUILD_TYPE="$2"
            shift 2
            ;;
        --with-contrib)
            WITH_CONTRIB="$2"
            shift 2
            ;;
        --with-python)
            WITH_PYTHON="$2"
            shift 2
            ;;
        --with-java)
            WITH_JAVA="$2"
            shift 2
            ;;
        --skip-dep-install)
            SKIP_DEP_INSTALL="true"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --opencv-version VERSION  OpenCV version to build (default: 5.x)"
            echo "  --prefix PATH             Installation prefix (default: /opt/opencv5)"
            echo "  --build-type TYPE         Build type: Release/Debug (default: Release)"
            echo "  --with-contrib BOOL       Build with contrib modules (default: true)"
            echo "  --with-python BOOL        Build with Python bindings (default: true)"
            echo "  --with-java BOOL          Build with Java bindings (default: false)"
            echo "  --skip-dep-install        Skip dependency installation (for Docker)"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "build-opencv: version=${OPENCV_VERSION} prefix=${OPENCV_PREFIX} buildtype=${BUILD_TYPE}"

# ------------------------------------------------------------------------------
# Build environment configuration
#
# OpenCV's vendored dependency graph produces duplicate symbol definitions
# when linking the monolithic libopencv_core.so. --allow-multiple-definition
# works around this without needing to patch OpenCV's CMakeLists.
#
# lld is disabled for OpenCV because its strict duplicate-symbol handling
# rejects symbols that GNU ld accepts with --allow-multiple-definition.
#
# CC/CXX are pinned to GCC explicitly because CMake may otherwise pick clang
# from PATH (the SDK image has both). The ${GCC_VERSION} env is set by the
# toolchain stage; fall back to scanning /opt/gcc-* if unset.
# ------------------------------------------------------------------------------
configure_opencv_build_env() {
    rm -rf "${OPENCV_PREFIX}"

    # Resolve GCC version if not already set in the environment
    if [ -z "${GCC_VERSION:-}" ]; then
        local _gcc_dir
        _gcc_dir="$(ls -d /opt/gcc-*/bin 2>/dev/null | sort -V | tail -1 || true)"
        if [ -n "${_gcc_dir}" ]; then
            GCC_VERSION="${_gcc_dir#/opt/gcc-}"
            GCC_VERSION="${GCC_VERSION%/bin}"
        fi
    fi

    unset LDFLAGS
    export USE_LLD=false
    if [ -n "${GCC_VERSION:-}" ]; then
        export CMAKE_C_COMPILER="/opt/gcc-${GCC_VERSION}/bin/gcc"
        export CMAKE_CXX_COMPILER="/opt/gcc-${GCC_VERSION}/bin/g++"
    fi
    export LDFLAGS="-Wl,--allow-multiple-definition"
    # OCV-FF1 ROOT CAUSE (2026-08-21): opencv's detect_ffmpeg try_compile
    # ("Can't build ffmpeg test code") got only the four -l names from
    # pkg-config but NO link dir for our custom prefix — the test link died
    # resolving avcodec's transitive libswresample and HAVE_FFMPEG went
    # FALSE despite four YES probes. cmake folds env LDFLAGS into
    # CMAKE_EXE_LINKER_FLAGS, which try_compile inherits: hand it the
    # ffmpeg libdir (+rpath-link for the transitive closure).
    if [ -d "${FFMPEG_PREFIX:-/opt/ffmpeg}/lib" ]; then
        export LDFLAGS="${LDFLAGS} -L${FFMPEG_PREFIX:-/opt/ffmpeg}/lib -Wl,-rpath-link,${FFMPEG_PREFIX:-/opt/ffmpeg}/lib"
    fi
    # Same class for GSTREAMER (2026-08-21, riscv64 pass-2): videoio links
    # our /opt/gstreamer fine, but APP binaries (opencv_visualisation) then
    # need the gst libdir on the rpath-link for transitive NEEDED
    # resolution ("libgstapp-1.0.so.0 ... not found (try using
    # -rpath-link)"). Resolve the real libdir (per-arch layouts differ).
    #
    # 2026-08-28: the plain `find ... -name 'libgstreamer-1.0.so*' | head -1`
    # this used to do picked meson's gdb pretty-printer FIRST (readdir order is
    # not sorted), so ALL THREE arches of run 20260827-200128 got
    # -L/opt/gstreamer/share/gdb/auto-load/opt/gstreamer/lib/... — a directory
    # that holds no .so at all, i.e. the repair above has been inert and the
    # riscv64 pass-2 failure it was written for is unprotected. Ask pkg-config
    # first (Dockerfile.media's opencv-gst step already prepends the gstreamer
    # pkgconfig dir to PKG_CONFIG_PATH), then the two known layouts; the
    # triplet dir EXISTS-but-is-EMPTY on cross (build-gstreamer-stage.sh
    # mkdir -p's it for the lib/multiarch symlink while meson installs into
    # plain lib/), so a candidate only counts once it actually holds a
    # libgstreamer-1.0.so*.
    local _gst_prefix="${GSTREAMER_PREFIX:-/opt/gstreamer}"
    local _gst_triplet _gst_cand _gst_lib=""
    _gst_triplet="$(arch_deb_multiarch_triplet_for "${TARGET_ARCH:-${TARGETARCH:-amd64}}" 2>/dev/null || true)"
    for _gst_cand in \
        "$(pkg-config --variable=libdir gstreamer-1.0 2>/dev/null || true)" \
        "${_gst_prefix}/lib/${_gst_triplet}" \
        "${_gst_prefix}/lib"; do
        [ -n "${_gst_cand}" ] || continue
        if compgen -G "${_gst_cand}/libgstreamer-1.0.so*" >/dev/null 2>&1; then
            _gst_lib="${_gst_cand}"
            break
        fi
    done
    if [ -z "${_gst_lib}" ]; then
        # Last resort for an unexpected layout — prune share/gdb so the
        # pretty-printer mirror can never win the race again.
        _gst_lib="$(dirname "$(find "${_gst_prefix}" -path '*/share/gdb' -prune -o -name 'libgstreamer-1.0.so*' -not -type d -print 2>/dev/null | head -1)" 2>/dev/null || true)"
        [ "${_gst_lib}" = "." ] && _gst_lib=""
    fi
    if [ -n "${_gst_lib}" ]; then
        echo "OpenCV: gstreamer libdir resolved to ${_gst_lib} (-L + -rpath-link)"
        export LDFLAGS="${LDFLAGS} -L${_gst_lib} -Wl,-rpath-link,${_gst_lib}"
    elif [ ! -d "${_gst_prefix}" ]; then
        # Pass 1 of the cross lanes runs before the gstreamer prefix exists at all.
        # Warning there is a false alarm on every arm64/riscv64 run.
        :
    else
        echo "[WARN] OpenCV: no gstreamer libdir found under ${_gst_prefix}; app links may fail on transitive libgst* (\"try using -rpath-link\")"
    fi
}

configure_opencv_build_env

# ------------------------------------------------------------------------------
# Fetch OpenCV source
# ------------------------------------------------------------------------------
fetch_opencv() {
    info "Fetching OpenCV ${OPENCV_VERSION} source..."

    # Main repository — cloned FIRST (not in parallel with contrib). contrib
    # nests under OPENCV_SRC (${OPENCV_SRC}/opencv_contrib), so cloning both at
    # once raced on creating OPENCV_SRC itself ("could not create work tree dir
    # '<OPENCV_SRC>': File exists"), leaving contrib un-cloned. Sequential clone
    # guarantees the parent exists before contrib is fetched into it.
    # OPENCV_COMMIT (opt-in 40-hex SHA) pins reproducibly; default empty keeps
    # tracking the OPENCV_VERSION branch (bleeding edge). core and contrib pin
    # independently since they are separate repos with distinct HEADs.
    retry 3 10 "opencv git clone" clone_or_update_repo "${OPENCV_REPO}" "${OPENCV_SRC}" "${OPENCV_COMMIT:-${OPENCV_VERSION}}" \
        || { echo "Failed to clone opencv"; exit 1; }

    # Contrib modules (optional) — fetched into the conventional opencv_contrib
    # directory name so CMake's OPENCV_EXTRA_MODULES_PATH is the expected path.
    local contrib_dir=""
    if [ "${WITH_CONTRIB}" = "true" ]; then
        echo "Fetching OpenCV contrib modules..."
        contrib_dir="${OPENCV_SRC}/opencv_contrib"
        retry 3 10 "opencv_contrib git clone" clone_or_update_repo "${OPENCV_CONTRIB_REPO}" "${contrib_dir}" "${OPENCV_CONTRIB_COMMIT:-${OPENCV_VERSION}}" \
            || { echo "Failed to clone opencv_contrib"; exit 1; }
    fi

    cd "${OPENCV_SRC}"
    # When a commit pin is set, clone_or_update_repo already checked out the SHA
    # via FETCH_HEAD and no ${OPENCV_VERSION} branch ref exists locally — a
    # branch checkout here would fail and abort the build. Only re-checkout the
    # branch in the unpinned (branch-tracking) case.
    if [ -z "${OPENCV_COMMIT:-}" ]; then
        git checkout "${OPENCV_VERSION}" || { echo "Failed to checkout version ${OPENCV_VERSION}"; exit 1; }
    fi
    echo "OpenCV version: $(git describe --tags 2>/dev/null || echo 'unknown')"

    if [ "${WITH_CONTRIB}" = "true" ]; then
        cd "${contrib_dir}"
        if [ -z "${OPENCV_CONTRIB_COMMIT:-}" ]; then
            git checkout "${OPENCV_VERSION}" || { echo "Failed to checkout contrib version ${OPENCV_VERSION}"; exit 1; }
        fi
        echo "OpenCV contrib version: $(git describe --tags 2>/dev/null || echo 'unknown')"
        cd "${OPENCV_SRC}"
    fi

    # OpenCV 5.x vendored MLAS declares MlasHGemmSupported (inc/mlas.h) but never
    # defines it, yet compute.cpp calls it from MlasGQASupported<MLAS_FP16>,
    # producing an undefined-symbol link error. Apply a weak-stub patch.
    if [ -f "${OPENCV_SRC}/3rdparty/mlas/lib/compute.cpp" ]; then
        bash /opt/scripts/core/apply-patch.sh \
            /opt/scripts/patches/opencv/001-mlas-hgemm-supported-stub.patch \
            "${OPENCV_SRC}" \
            "OpenCV MLAS MlasHGemmSupported stub for MLAS_GEMM_ONLY"
    fi

    # OCV-FF1 phase 2 (2026-08-21): with the try_compile link gap fixed,
    # HAVE_FFMPEG went TRUE for the first time — and exposed that opencv
    # 5.0.0 still uses the AVCodec fields FFmpeg 8 removed (pix_fmts,
    # supported_framerates; 4.x master already migrated, the 5.x branch has
    # not). Backport shim: avcodec_get_supported_config() behind
    # LIBAVCODEC_VERSION_MAJOR >= 62 guards — 2 sites, drops cleanly when a
    # 5.x release lands the migration.
    if [ -f "${OPENCV_SRC}/modules/videoio/src/cap_ffmpeg_impl.hpp" ]; then
        bash /opt/scripts/core/apply-patch.sh \
            /opt/scripts/patches/opencv/002-ffmpeg8-avcodec-config-api.patch \
            "${OPENCV_SRC}" \
            "OpenCV 5.0.0 FFmpeg-8 AVCodec config-API compat (OCV-FF1)"
    fi
}

target_machine() {
    if command -v cross_target_arch >/dev/null 2>&1; then
        cross_target_arch
        return 0
    fi
    if [ -n "${TARGET_ARCH:-${TARGETARCH:-}}" ]; then
        printf '%s' "${TARGET_ARCH:-${TARGETARCH}}"
        return 0
    fi
    uname -m
}

# ------------------------------------------------------------------------------
# Configure OpenCV build
# ------------------------------------------------------------------------------

# Adjust build flags for non-x86 targets and cross-mode gating of GTK/GStreamer/
# Python. Mutates the surrounding with_* and target_* locals.
# CMake hands OpenCV `-isystem /usr/include`, which shadows libstdc++'s own
# <complex.h> wrapper. docs/failure-modes.md#opencv-stdcomplex-breaks-on-a-shadowed-complexh
_opencv_write_cxx_compat_shim() {
  local dir="${1:?shim dir is required}"

  mkdir -p "${dir}"
  cat > "${dir}/complex.h" <<'SHIM'
#pragma once
/* Restores what libstdc++'s <complex.h> does: include the C header, then drop
   its `complex` macro so std::complex still parses. Transparent in C. */
#ifdef __cplusplus
#include <complex>
#include_next <complex.h>
#undef complex
#else
#include_next <complex.h>
#endif
SHIM
}

_opencv_target_adjustments() {
    local -n _ota_cmake_opts="$1"
    local -n _ota_with_gtk="$2"
    local -n _ota_with_gstreamer="$3"
    local -n _ota_with_opengl="$4"
    local -n _ota_zlib_inc="$5"
    local -n _ota_zlib_lib="$6"
    local -n _ota_shared_inc="$7"

    # Disable IPP automatically on non-x86 hosts because OpenCV bundles
    # prebuilt ippicv libraries for x86 which will fail when linking on
    # architectures like aarch64 or riscv. Allow explicit override via
    # the WITH_IPP env var (set to "ON" or "OFF").
    if [ "$(target_machine)" != "amd64" ] && [ "$(target_machine)" != "x86_64" ] && [ "${WITH_IPP}" = "ON" ]; then
        echo "Non-x86 target detected ($(target_machine)) - disabling Intel IPP to avoid x86 prebuilt libs"
        WITH_IPP="OFF"
    fi

    if cross_build_is_active; then
        # GTK pulls target-side Pango GIR files that are not coinstallable with the host arch.
        _ota_with_gtk="OFF"
        _ota_with_opengl="OFF"
        # Debian/Ubuntu multiarch keeps zlib.h in the shared include directory.
        _ota_zlib_inc="/usr/include"
        _ota_zlib_lib="/usr/lib/$(cross_target_triplet)/libz.so"
        _ota_shared_inc="-idirafter /usr/include"
        # -I beats -isystem, so the shim wins whatever CMake appends.
        _opencv_write_cxx_compat_shim "${OPENCV_SRC%/}-cxx-compat"
        _ota_shared_inc="-I${OPENCV_SRC%/}-cxx-compat ${_ota_shared_inc}"
        # OCV-FF2 (2026-08-31): pass 2 inherits the gstreamer stage, which
        # installs the DISTRO libav*-dev (FFmpeg 8.0.1) while we build our own
        # n9.0 into ${FFMPEG_PREFIX}. Both land on the include path, and
        # codec_par.h's `#include "libavutil/pixfmt.h"` resolved to the 8.0.1
        # copy -- which has no AVAlphaMode, added in 9.0. Killed the riscv64
        # opencv_videoio build. -I is searched before -isystem, so pinning our
        # prefix here makes our headers win regardless of what CMake appends.
        # docs/failure-modes.md
        if [ -d "${FFMPEG_PREFIX:-/opt/ffmpeg}/include/libavutil" ]; then
            _ota_shared_inc="-I${FFMPEG_PREFIX:-/opt/ffmpeg}/include ${_ota_shared_inc}"
        fi
        if [ "$(cross_target_arch)" = "riscv64" ]; then
            # RV1 RE-LIFT (2026-08-21, closure window 2): the 2026-08-20
            # "OFF both passes" verdict was taken while the POISONED ports
            # glib-2.0.pc sat in the sysroot; that package is gone (root-cause
            # revert) and riscv64 gstreamer builds with introspection again →
            # /opt/gstreamer exports working glib .pcs like wave-3. Pass-1
            # (OPENCV_GSTREAMER_PASS unset) stays OFF (no system gstreamer to
            # probe — deliberate); pass-2 (Dockerfile.media exports
            # OPENCV_GSTREAMER_PASS=2) probes OUR /opt/gstreamer. Target:
            # cv2 GStreamer:YES on ALL THREE arches. Dedicated discriminator
            # (2026-08-21): this used to key on FORCE_REBUILD, so forcing a
            # PASS-1 rebuild silently flipped gstreamer ON with nothing to
            # probe — FORCE_REBUILD keeps its one meaning (skip-override).
            if [ "${OPENCV_GSTREAMER_PASS:-1}" != "2" ]; then
                _ota_with_gstreamer="OFF"
            fi
            # RV1-FREETYPE: riscv64 stages a PIC-static target harfbuzz because the
            # ports dev package is glib-poisoned. docs/failure-modes.md
            local _hb_triplet _hb_a _hb_inc _hb_pc _ft_so
            _hb_triplet="$(cross_target_triplet 2>/dev/null || echo riscv64-linux-gnu)"
            _hb_a="/usr/${_hb_triplet}/lib/libharfbuzz.a"
            _hb_inc="/usr/${_hb_triplet}/include/harfbuzz/hb-ft.h"
            _hb_pc="/usr/${_hb_triplet}/lib/pkgconfig/harfbuzz.pc"
            _ft_so="/usr/lib/${_hb_triplet}/libfreetype.so"
            if [ -f "${_hb_a}" ] && [ -f "${_hb_inc}" ] && [ -f "${_hb_pc}" ] && [ -f "${_ft_so}" ]; then
                echo "riscv64 OpenCV: freetype module ENABLED against static target harfbuzz (${_hb_a}) + ${_ft_so}"
                export PKG_CONFIG_PATH="/usr/${_hb_triplet}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
                _ota_cmake_opts+=("-Dpkgcfg_lib_HARFBUZZ_harfbuzz:FILEPATH=${_hb_a}")
                _ota_cmake_opts+=("-Dpkgcfg_lib_HARFBUZZ_freetype:FILEPATH=${_ft_so}")
                _ota_cmake_opts+=("-Dpkgcfg_lib_FREETYPE_freetype:FILEPATH=${_ft_so}")
            else
                echo "[WARN] riscv64 OpenCV: static target harfbuzz not staged (libharfbuzz.a=$([ -f "${_hb_a}" ] && echo ok || echo MISSING) hb-ft.h=$([ -f "${_hb_inc}" ] && echo ok || echo MISSING) harfbuzz.pc=$([ -f "${_hb_pc}" ] && echo ok || echo MISSING) libfreetype.so=$([ -f "${_ft_so}" ] && echo ok || echo MISSING)); keeping BUILD_opencv_freetype=OFF"
                _ota_cmake_opts+=("-DBUILD_opencv_freetype=OFF")
            fi
            # OpenCV 5.x's vendored libpng fails its RISC-V Vector configure probe under
            # GCC 16.1.0 (the CMake test uses incompatible intrinsics). Rather than drop
            # PNG entirely (which breaks cv2.imencode('.png', ...)), link the EXTERNAL
            # libpng that install-deps.sh provides (Ubuntu Ports package or, as a
            # fallback, cross-compiled from source via git+ mirror): WITH_PNG=ON +
            # BUILD_PNG=OFF bypasses the vendored copy and its RVV probe. External libpng
            # is a HARD REQUIREMENT on riscv64 — if it is absent we FAIL EARLY here rather
            # than silently shipping a PNG-less OpenCV that only surfaces as a red
            # runtime smoke a stage later (that fail-late footgun cost us iree-0714a..e).
            # Deliberate opt-out: OPENCV_ALLOW_NO_PNG=1 downgrades it to WITH_PNG=OFF.
            local _png_triplet _png_lib="" _png_inc="" _png_cand
            _png_triplet="$(cross_target_triplet 2>/dev/null || echo riscv64-linux-gnu)"
            for _png_cand in \
                "/usr/${_png_triplet}/lib/libpng16.a" \
                "/usr/${_png_triplet}/lib/libpng16_static.a" \
                "/usr/lib/${_png_triplet}/libpng16.a"; do
                [ -f "${_png_cand}" ] && { _png_lib="${_png_cand}"; break; }
            done
            for _png_cand in "/usr/${_png_triplet}/include/libpng16" "/usr/${_png_triplet}/include"; do
                [ -f "${_png_cand}/png.h" ] && { _png_inc="${_png_cand}"; break; }
            done
            if [ -n "${_png_lib}" ] && [ -n "${_png_inc}" ]; then
                echo "riscv64 OpenCV: linking external static libpng (${_png_lib}, headers ${_png_inc})"
                _ota_cmake_opts+=("-DWITH_PNG=ON" "-DBUILD_PNG=OFF" "-DPNG_PNG_INCLUDE_DIR=${_png_inc}" "-DPNG_LIBRARY=${_png_lib}")
            elif [ "${OPENCV_ALLOW_NO_PNG:-0}" = "1" ]; then
                echo "[WARN] riscv64 OpenCV: no external libpng found and OPENCV_ALLOW_NO_PNG=1 set; disabling PNG (cv2 PNG encode unavailable)"
                _ota_cmake_opts+=("-DWITH_PNG=OFF")
            else
                echo "[ERROR] riscv64 OpenCV: external static libpng NOT found (searched /usr/${_png_triplet}/lib and /usr/lib/${_png_triplet})." >&2
                echo "[ERROR] PNG is required on riscv64; install-deps.sh must build libpng (git+ mirror). Failing early instead of shipping a PNG-less OpenCV." >&2
                echo "[ERROR] Set OPENCV_ALLOW_NO_PNG=1 only if a PNG-less riscv64 OpenCV is genuinely acceptable." >&2
                exit 1
            fi
        fi
        if [ "${WITH_PYTHON}" = "true" ] && command -v cross_target_python_dev_ready >/dev/null 2>&1 && ! cross_target_python_dev_ready; then
            echo "Target Python development files are not staged for $(cross_target_triplet 2>/dev/null || echo target); disabling OpenCV Python bindings in cross mode"
            WITH_PYTHON="false"
        fi
    fi
}

# Append core CMake options (build type, install path, modules, codecs).
_opencv_cmake_core_opts() {
    local -n _occmo_out="$1"
    local with_gtk="$2" with_gstreamer="$3" with_opengl="$4"
    _occmo_out=(
        "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}"
        "-DCMAKE_INSTALL_PREFIX=${OPENCV_PREFIX}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DBUILD_SHARED_LIBS=ON"
        "-DENABLE_BUILD_HARDENING=ON"
        "-DOPENCV_GENERATE_PKGCONFIG=ON"
        "-DBUILD_TESTS=OFF"
        "-DBUILD_PERF_TESTS=OFF"
        "-DBUILD_EXAMPLES=OFF"
        "-DBUILD_DOCS=OFF"
        "-DBUILD_JAVA_TESTS=OFF"
        "-DINSTALL_TESTS=OFF"
        "-DINSTALL_C_EXAMPLES=OFF"
        "-DINSTALL_PYTHON_EXAMPLES=OFF"
        "-DWITH_TBB=ON"
        "-DWITH_EIGEN=ON"
        "-DWITH_GTK=${with_gtk}"
        "-DWITH_V4L=ON"
        "-DWITH_FFMPEG=ON"
        "-DWITH_GSTREAMER=${with_gstreamer}"
        "-DWITH_OPENEXR=ON"
        "-DWITH_JPEG=ON"
        "-DWITH_PNG=ON"
        "-DWITH_TIFF=ON"
        "-DWITH_WEBP=ON"
        "-DWITH_DC1394=ON"
        "-DWITH_1394=ON"
        "-DWITH_OPENCL=ON"
        "-DWITH_OPENGL=${with_opengl}"
        "-DWITH_VULKAN=ON"
        "-DWITH_PROTOBUF=ON"
        "-DWITH_LIBV4L=ON"
        "-DWITH_ITT=ON"
        "-DWITH_IPP=${WITH_IPP}"
        # ONNX Runtime DNN backend. OpenCV 5.0's dnn/CMakeLists.txt ALWAYS
        # auto-downloads a prebuilt ORT when WITH_ONNXRUNTIME=ON: it checks
        # NOT HAVE_ONNXRUNTIME before that cache var is ever set, then FORCEs
        # ONNXRT_ROOT_DIR to the extracted prebuilt dir. DOWNLOAD_ONNXRUNTIME=OFF
        # only blocks the FORCED case. We pre-set HAVE_ONNXRUNTIME=1 below (in
        # the compat-tree section) to skip the download, and build a symlink
        # tree so FindONNX.cmake's find_library/find_path find our source-built
        # ORT. Without the pre-set, the download overwrites our find with a
        # prebuilt 1.25.1 that carries DML headers (breaks Linux, no riscv64).
        "-DWITH_ONNXRUNTIME=ON"
        "-DONNXRT_ROOT_DIR=/usr/local/lib/onnxruntime-cpu"
        "-DDOWNLOAD_ONNXRUNTIME=OFF"
        # LOG26: enable AVIF, HDF5 and the non-free algorithms.
        "-DWITH_AVIF=ON"
        "-DWITH_HDF5=ON"
        "-DOPENCV_ENABLE_NONFREE=ON"
    )

    # RVV is gated on these cache vars, not on -march. docs/riscv64-rva23-baseline.md
    if [ "$(cross_target_arch)" = "riscv64" ]; then
        _occmo_out+=("-DCPU_BASELINE=RVV" "-DWITH_HAL_RVV=ON")
    fi
}

# Append cross-compilation CMake flags (find-root modes, archiver tools,
# zlib, idirafter include fallback).
_opencv_cmake_cross_opts() {
    local -n _ocmco_out="$1"
    local target_zlib_include="$2" target_zlib_library="$3" target_shared_include_fallback="$4"

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args _ocmco_out
    fi

    if cross_build_is_active; then
        # OpenCV's mixed vendored/system dependency graph needs access to the
        # target sysroot headers and libraries under /usr while still finding
        # generated build artifacts in the normal build tree.
        _ocmco_out+=("-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH")
        _ocmco_out+=("-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH")
        _ocmco_out+=("-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH")
        _ocmco_out+=("-DCMAKE_AR=$(resolve_cross_archive_tool ar)")
        _ocmco_out+=("-DCMAKE_RANLIB=$(resolve_cross_archive_tool ranlib)")
        _ocmco_out+=("-DCMAKE_C_COMPILER_AR=$(resolve_cross_archive_tool ar)")
        _ocmco_out+=("-DCMAKE_CXX_COMPILER_AR=$(resolve_cross_archive_tool ar)")
        _ocmco_out+=("-DCMAKE_C_COMPILER_RANLIB=$(resolve_cross_archive_tool ranlib)")
        _ocmco_out+=("-DCMAKE_CXX_COMPILER_RANLIB=$(resolve_cross_archive_tool ranlib)")
        _ocmco_out+=("-DZLIB_INCLUDE_DIR=${target_zlib_include}")
        _ocmco_out+=("-DZLIB_LIBRARY=${target_zlib_library}")
        _ocmco_out+=("-DCMAKE_C_FLAGS=${target_shared_include_fallback}")
        _ocmco_out+=("-DCMAKE_CXX_FLAGS=${target_shared_include_fallback}")
    fi
}

# Help CMake find the Vulkan SDK if installed in the default /opt/vulkan location.
_opencv_vulkan_setup() {
    if [ -d "/opt/vulkan" ]; then
        local vulkan_ver
        vulkan_ver=$(ls /opt/vulkan | sort -V | tail -n 1)
        if [ -n "$vulkan_ver" ]; then
            # LunarG SDK tarball consistently uses "x86_64" in the path regardless of actual host architecture
            local vulkan_sdk="/opt/vulkan/${vulkan_ver}/x86_64"
            if [ -d "$vulkan_sdk" ]; then
                export VULKAN_SDK="$vulkan_sdk"
                export PATH="$vulkan_sdk/bin:$PATH"
                export LD_LIBRARY_PATH="$vulkan_sdk/lib:${LD_LIBRARY_PATH:-}"
                export VK_LAYER_PATH="$vulkan_sdk/etc/vulkan/explicit_layer.d"
            fi
        fi
    fi
}

# Append contrib modules path when WITH_CONTRIB=true.
_opencv_cmake_contrib_opts() {
    local -n _ocmco_out="$1"
    if [ "${WITH_CONTRIB}" = "true" ]; then
        _ocmco_out+=("-DOPENCV_EXTRA_MODULES_PATH=${OPENCV_SRC}/opencv_contrib/modules")
        _ocmco_out+=("-DBUILD_opencv_python3=${WITH_PYTHON}")
    fi
}

# Append Python bindings CMake opts (executable, library, include, numpy).
_opencv_cmake_python_opts() {
    local -n _ocmpo_out="$1"

    if [ "${WITH_PYTHON}" = "true" ]; then
        echo "Using existing Python venv (expected at /opt/python/.venv)..."
        setup_host_python_environment
        uv pip install numpy wheel

        local PY_EXEC="${HOST_PYTHON:-$(host_python_bin)}"
        _ocmpo_out+=("-DPYTHON3_EXECUTABLE=${PY_EXEC}")
        # Explicitly set library and include paths since FindPython3 might not find free-threaded (t) libraries
        if cross_build_is_active; then
            local target_python_library=""
            local target_python_include=""

            if command -v cross_target_python_library >/dev/null 2>&1; then
                target_python_library="$(cross_target_python_library 2>/dev/null || true)"
            fi
            if command -v cross_target_python_include_dir >/dev/null 2>&1; then
                target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
            fi

            if [ -n "${target_python_library}" ] && [ -d "${target_python_include}" ]; then
                _ocmpo_out+=("-DPYTHON3_LIBRARY=${target_python_library}")
                _ocmpo_out+=("-DPYTHON3_INCLUDE_DIR=${target_python_include}")
            fi

            # Numpy headers are architecture-independent; use the host venv numpy.
            # OpenCV's cmake needs them to generate Python3 wrappers (cv2.so).
            # In cross mode, FindPython3 cannot probe numpy at the target, so we
            # supply the include path explicitly.
            local numpy_include
            numpy_include="$(python_module_include "${HOST_PYTHON:-$(host_python_bin)}" numpy)"
            if [ -n "${numpy_include}" ] && [ -d "${numpy_include}" ]; then
                _ocmpo_out+=("-DPYTHON3_NUMPY_INCLUDE_DIRS=${numpy_include}")
                echo "Set PYTHON3_NUMPY_INCLUDE_DIRS=${numpy_include} for cross-compile"
            else
                echo "[WARN] Numpy not available in host venv; Python3 wrappers will not be generated"
            fi
        elif [ -f "/usr/local/lib/libpython${OPENCV_PYTHON_VERSION}.so" ]; then
            _ocmpo_out+=("-DPYTHON3_LIBRARY=/usr/local/lib/libpython${OPENCV_PYTHON_VERSION}.so")
            _ocmpo_out+=("-DPYTHON3_INCLUDE_DIR=/usr/local/include/python${OPENCV_PYTHON_VERSION}")
        fi
    fi
}

# Append Java bindings CMake opts.
_opencv_cmake_java_opts() {
    local -n _ocmjo_out="$1"
    if [ "${WITH_JAVA}" = "true" ]; then
        _ocmjo_out+=("-DBUILD_JAVA=ON")
        _ocmjo_out+=("-DBUILD_opencv_java=ON")
    else
        _ocmjo_out+=("-DBUILD_JAVA=OFF")
        _ocmjo_out+=("-DBUILD_opencv_java=OFF")
    fi
}

# Append NVIDIA CUDA / cuDNN / TensorRT CMake opts when ENABLE_NVIDIA=true.
_opencv_cmake_cuda_opts() {
    local -n _ocmcd_out="$1"
    if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
        echo "Enabling NVIDIA CUDA and cuDNN support in OpenCV..."
        _ocmcd_out+=("-DWITH_CUDA=ON")
        _ocmcd_out+=("-DCUDA_FAST_MATH=ON")
        _ocmcd_out+=("-DWITH_CUDNN=ON")
        _ocmcd_out+=("-DOPENCV_DNN_CUDA=ON")
        _ocmcd_out+=("-DWITH_CUBLAS=ON")
        _ocmcd_out+=("-DWITH_NVCUVID=ON")
        _ocmcd_out+=("-DWITH_TENSORRT=ON")
        # Target GPU arch list from versions.env (CUDA_ARCHITECTURES).
        _ocmcd_out+=("-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES:-80;86;89;90}")
        # CUDA compile caching — sccache wraps nvcc first-class (ccache cannot).
        # Resolve through compiler_cache_launcher() for the guarded launcher;
        # only accept sccache-class launchers (ccache can't wrap nvcc).
        if [ "${ENABLE_SCCACHE_CUDA:-0}" = "1" ]; then
            _cuda_launcher="$(compiler_cache_launcher 2>/dev/null || true)"
            case "${_cuda_launcher}" in
                *sccache*)
                    echo "sccache: wrapping nvcc via CMAKE_CUDA_COMPILER_LAUNCHER (${_cuda_launcher})"
                    _ocmcd_out+=("-DCMAKE_CUDA_COMPILER_LAUNCHER=${_cuda_launcher}")
                    ;;
                *)
                    echo "WARN: sccache unavailable for CUDA caching — building uncached"
                    ;;
            esac
        fi

        # Explicitly provide the CUDA library stub so we can build without a GPU present
        if [ -f "/usr/local/cuda/lib64/stubs/libcuda.so" ]; then
            _ocmcd_out+=("-DCUDA_CUDA_LIBRARY=/usr/local/cuda/lib64/stubs/libcuda.so")
        elif [ -f "/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so" ]; then
            _ocmcd_out+=("-DCUDA_CUDA_LIBRARY=/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so")
        else
            _ocmcd_out+=("-DBUILD_opencv_cudacodec=OFF")
        fi
    fi
}

# For cross-builds, ensure freetype/harfbuzz can be found (host headers, target libs).
_opencv_cmake_freetype_opts() {
    local -n _ocmfo_out="$1"
    if cross_build_is_active && [ "$(cross_target_arch)" != "amd64" ]; then
        local _cv_triplet
        _cv_triplet="$(cross_target_triplet 2>/dev/null || true)"
        if [ -n "${_cv_triplet}" ]; then
            local _cv_target_lib="/usr/lib/${_cv_triplet}"
            if [ -d /usr/include/freetype2 ]; then
                _ocmfo_out+=("-DFREETYPE_INCLUDE_DIRS=/usr/include/freetype2")
            fi
            if [ -d /usr/include/harfbuzz ]; then
                _ocmfo_out+=("-DHARFBUZZ_INCLUDE_DIRS=/usr/include/harfbuzz")
            fi
            if [ -f "${_cv_target_lib}/libfreetype.so" ]; then
                _ocmfo_out+=("-DFREETYPE_LIBRARY=${_cv_target_lib}/libfreetype.so")
            fi
            if [ -f "${_cv_target_lib}/libharfbuzz.so" ]; then
                _ocmfo_out+=("-DHARFBUZZ_LIBRARY=${_cv_target_lib}/libharfbuzz.so")
            fi
        fi
    fi
}

configure_opencv() {
    echo "Configuring OpenCV build..."

    local build_dir="${OPENCV_SRC}/build"
    local with_gtk="ON"
    local with_gstreamer="ON"
    local with_opengl="ON"
    local target_zlib_include=""
    local target_zlib_library=""
    local target_shared_include_fallback=""
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    # Target adjustments must be computed FIRST (they set with_gtk/with_gstreamer/
    # target_zlib_* consumed by the core opts) but their CMake overrides (e.g.
    # riscv64 -DWITH_PNG=OFF) must land AFTER the core opts in the final command:
    # _opencv_cmake_core_opts does a full array reassignment (and cmake is
    # last-wins), so collect them separately and append after the core opts.
    local target_cmake_opts=()
    _opencv_target_adjustments target_cmake_opts with_gtk with_gstreamer with_opengl \
        target_zlib_include target_zlib_library target_shared_include_fallback

    _opencv_cmake_core_opts cmake_opts "${with_gtk}" "${with_gstreamer}" "${with_opengl}"
    cmake_opts+=("${target_cmake_opts[@]}")
    _opencv_cmake_cross_opts cmake_opts \
        "${target_zlib_include}" "${target_zlib_library}" "${target_shared_include_fallback}"

    append_cmake_cache_linker_args cmake_opts

    # Ensure tracking module is explicitly enabled (some builds/platforms
    # may not build it by default even when contrib modules are available).
    cmake_opts+=("-DBUILD_opencv_tracking=ON")

    _opencv_vulkan_setup
    _opencv_cmake_contrib_opts cmake_opts
    _opencv_cmake_python_opts cmake_opts
    _opencv_cmake_java_opts cmake_opts
    _opencv_cmake_cuda_opts cmake_opts
    _opencv_cmake_freetype_opts cmake_opts

    # DETERMINISTIC exe-linker flags (2026-08-21): the cross/cache helpers
    # can place their own -DCMAKE_EXE_LINKER_FLAGS in cmake_opts, and an
    # explicit -D beats env LDFLAGS — which silently dropped the
    # ffmpeg/gstreamer -L/-rpath-link repairs from the APP links (riscv64
    # pass-2 died on libgst* "not found (try using -rpath-link)" despite the
    # env fix). cmake is last-wins on repeated -D: append ours LAST, merging
    # whatever the helpers put into the env with our LDFLAGS bundle.
    cmake_opts+=("-DCMAKE_EXE_LINKER_FLAGS=${CMAKE_EXE_LINKER_FLAGS:-} ${LDFLAGS:-}")

    echo "CMake options: ${cmake_opts[*]}"

    # Build a CMake-compatible ORT layout so FindONNX.cmake's find_library and
    # find_path succeed against ONNXRT_ROOT_DIR. The real libs are at
    # <root>/lib/ (NOT <root>/runtime/lib, which holds only pkgconfig). The
    # mount is readonly, so create the tree in the tmpfs build dir.
    # Pre-set HAVE_ONNXRUNTIME=1 to skip OpenCV's unconditional prebuilt
    # download (see comment in _opencv_cmake_core_opts).
    #
    # Copy the include tree (not symlink) so we can strip the DML provider
    # headers. Our source-built ORT copies ALL provider headers from the
    # source tree, including DML (Windows-only). FindONNX.cmake probes
    # for dml_provider_factory.h and sets HAVE_ONNX_DML, which makes gapi
    # compile dml_ep.cpp — a file whose relative include
    # ../providers/dml/dml_provider_factory.h cannot resolve on Linux.
    _ort_real="/usr/local/lib/onnxruntime-cpu"
    _ort_compat="${build_dir}/ort-compat"
    if [ -d "${_ort_real}" ] && [ -d "${_ort_real}/include" ] && [ -d "${_ort_real}/lib" ]; then
        mkdir -p "${_ort_compat}"
        cp -aL "${_ort_real}/include" "${_ort_compat}/include"
        rm -rf "${_ort_compat}/include/onnxruntime/core/providers/dml"
        ln -sf "${_ort_real}/lib" "${_ort_compat}/lib"
        cmake_opts+=("-DONNXRT_ROOT_DIR=${_ort_compat}")
        cmake_opts+=("-DHAVE_ONNXRUNTIME=1")
    else
        # ORT not present (build failed or skipped) — disable to avoid
        # OpenCV's SEND_ERROR when WITH_ONNXRUNTIME=ON finds nothing.
        cmake_opts+=("-DWITH_ONNXRUNTIME=OFF")
    fi

    cmake -G Ninja "${OPENCV_SRC}" "${cmake_opts[@]}" || die "OpenCV configure failed"
}

# ------------------------------------------------------------------------------
# Build OpenCV
# ------------------------------------------------------------------------------
build_opencv() {
    echo "Building OpenCV with ${NPROC} parallel jobs..."

    local build_dir="${OPENCV_SRC}/build"
    cd "${build_dir}"

    if ninja -j"${NPROC}" install; then
        return 0
    fi

    echo "OpenCV parallel build failed; rerunning serial verbose build for diagnostics..."
    ninja -j1 -v install || true
    echo "OpenCV build failed"
    exit 1
}

# ------------------------------------------------------------------------------
# Install OpenCV
# ------------------------------------------------------------------------------
install_opencv() {
    echo "Installing OpenCV to ${OPENCV_PREFIX}..."
    
    local build_dir="${OPENCV_SRC}/build"
    cd "${build_dir}"
    
    ensure_sudo_or_die

    # Use cmake --install which works with any generator (Ninja, Make, etc.)
    # Keep stderr of each attempt quiet on the happy path, but capture it so the
    # actual reason (ENOSPC, permissions, ...) reaches the log if BOTH fail.
    local _cmake_install_err _make_install_err
    _cmake_install_err="$(mktemp)"
    _make_install_err="$(mktemp)"
    ${SUDO_WRAP} cmake --install . --prefix "${OPENCV_PREFIX}" 2>"${_cmake_install_err}" || \
    ${SUDO_WRAP} make install 2>"${_make_install_err}" || {
      echo "ERROR: Both cmake --install and make install failed for OpenCV"
      echo "--- cmake --install stderr ---"
      cat "${_cmake_install_err}"
      echo "--- make install stderr ---"
      cat "${_make_install_err}"
      exit 1
    }
    rm -f "${_cmake_install_err}" "${_make_install_err}"
    ${SUDO_WRAP} ldconfig || true

    # Ensure unversioned symlinks exist for contrib libraries (search lib and lib64)
    for libdir in "${OPENCV_PREFIX}/lib" "${OPENCV_PREFIX}/lib64"; do
        if [ -d "${libdir}" ]; then
            local candidate
            candidate=$(find "${libdir}" -maxdepth 1 -name "libopencv_tracking.so*" | head -n 1)
            if [ -n "${candidate}" ] && [ ! -e "${libdir}/libopencv_tracking.so" ]; then
                echo "Creating symlink ${libdir}/libopencv_tracking.so -> ${candidate}"
                ${SUDO_WRAP} ln -sf "$(basename "${candidate}")" "${libdir}/libopencv_tracking.so" || true
            fi
        fi
    done

    # Sanity-check: fail early if core or tracking library is still missing
    for _ocv_lib in libopencv_core libopencv_tracking; do
        if ! (ls "${OPENCV_PREFIX}/lib/${_ocv_lib}.so" >/dev/null 2>&1 || ls "${OPENCV_PREFIX}/lib64/${_ocv_lib}.so" >/dev/null 2>&1); then
            echo "ERROR: ${_ocv_lib} was not found after install. Listing installed libs for debugging:"
            ${SUDO_WRAP} ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null || true
            ${SUDO_WRAP} ls -la "${OPENCV_PREFIX}/lib64" 2>/dev/null || true
            die "Failing build so the image build doesn't continue with a broken OpenCV install."
        fi
    done

    install_opencv4_compat_aliases
}

# ------------------------------------------------------------------------------
# OpenCV 4 compatibility aliases
#
# OpenCV 5.x installs its pkg-config file as `opencv5.pc` and its data files
# under `share/opencv5`. Downstream consumers (notably GStreamer's
# gst-plugins-bad opencv plugin) still look up OpenCV via the historical
# `opencv4` pkg-config name and a `share/{opencv,OpenCV,opencv4}` data
# directory. GStreamer only requires `opencv4 >= 4.0.0` (no upper bound), so the
# OpenCV 5.x version satisfies that check once the package is discoverable under
# the `opencv4` name. Provide stable `opencv4` compatibility aliases so those
# consumers resolve against this OpenCV 5 install instead of failing.
# ------------------------------------------------------------------------------
install_opencv4_compat_aliases() {
    local pcdir
    for pcdir in "${OPENCV_PREFIX}/lib/pkgconfig" "${OPENCV_PREFIX}/lib64/pkgconfig"; do
        if [ -f "${pcdir}/opencv5.pc" ] && [ ! -e "${pcdir}/opencv4.pc" ]; then
            echo "Creating pkg-config compatibility alias ${pcdir}/opencv4.pc -> opencv5.pc"
            ${SUDO_WRAP} cp "${pcdir}/opencv5.pc" "${pcdir}/opencv4.pc"
        fi
    done

    local sharedir="${OPENCV_PREFIX}/share"
    if [ ! -e "${sharedir}/opencv4" ] && \
       [ ! -e "${sharedir}/opencv" ] && \
       [ ! -e "${sharedir}/OpenCV" ]; then
        ${SUDO_WRAP} mkdir -p "${sharedir}"
        if [ -d "${sharedir}/opencv5" ]; then
            echo "Creating data-dir compatibility alias ${sharedir}/opencv4 -> opencv5"
            ${SUDO_WRAP} ln -s opencv5 "${sharedir}/opencv4"
        else
            # No OpenCV data directory was installed (e.g. cascade data removed
            # in OpenCV 5 core). Create an empty data dir so consumers that only
            # probe for its existence at configure time still succeed.
            echo "Creating empty data-dir compatibility alias ${sharedir}/opencv4"
            ${SUDO_WRAP} mkdir -p "${sharedir}/opencv4"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
    echo "Cleaning up build directory..."
    rm -rf "${OPENCV_SRC}" || true
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    if [ "${FORCE_REBUILD:-0}" != "1" ] && pkg-config --exists opencv5 2>/dev/null; then
        echo "OpenCV already installed ($(pkg-config --modversion opencv5 2>/dev/null)); skipping build"
        echo "Set FORCE_REBUILD=1 to rebuild"
        return 0
    fi

    fetch_opencv
    configure_opencv
    build_opencv
    install_opencv
    
    if [ "${WITH_PYTHON}" = "true" ]; then
        # The library cmake (with BUILD_opencv_python3=true and numpy headers)
        # already installs cv2 to /opt/opencv5/lib/python3.*/site-packages/.
        # The opencv-python wheel rebuild produces the OLD tagged version from
        # the official repo (4.x, not 5.x) and would overwrite the source-built
        # 5.x bindings. Skip it unconditionally.
        echo "Skipping opencv-python wheel rebuild; source-built 5.x bindings are already installed to ${OPENCV_PREFIX}"
    fi
    
    cleanup
    
    # Validation step
    pkg-config --exists opencv5 && echo "OpenCV found via pkg-config: $(pkg-config --modversion opencv5)" || {
        echo "ERROR: OpenCV not found via pkg-config (opencv5)"
        echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}"
        die "OpenCV validation failed"
    }
    
    echo "OpenCV ${OPENCV_VERSION} installed successfully to ${OPENCV_PREFIX}"

    # AP4: strip symbol tables from the installed OpenCV prefix. Unlike
    # ffmpeg/gstreamer/libcamera, this script does not call setup_linux_cross_env,
    # so ${STRIP} is unset — strip_media_prefixes self-derives the cross
    # <triplet>-strip (via _resolve_media_strip_bin) when a cross build is active,
    # else host strip. --strip-all keeps .dynsym (dynamic linking unaffected).
    # Best-effort; MEDIA_STRIP=0 disables. /opt/opencv5 is a dedicated prefix, so
    # this touches only OpenCV libs (litert/onnxruntime live in the shared
    # /usr/local and are handled elsewhere).
    # DUPN1: MEDIA_STRIP gate lives inside the helper now.
    declare -F strip_media_prefixes >/dev/null 2>&1 && strip_media_prefixes "${OPENCV_PREFIX}" || true

    echo "Libraries:"
    ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null | head -20 || echo "Could not list libraries"
    
    if [ "${WITH_PYTHON}" = "true" ] && { ! cross_build_is_active; }; then
        echo ""
        echo "Python bindings:"
        # cv2 installs under the OpenCV prefix, not system site-packages, so a
        # bare import can never succeed here -- this check warned on every build
        # while the real one (final stage) passed. Point it at the prefix, the
        # same way Dockerfile.media's final stage does, so it actually gates.
        local _cv2_pp
        _cv2_pp="$(echo "${OPENCV_PREFIX}"/lib/python*/site-packages 2>/dev/null | tr ' ' ':')"
        PYTHONPATH="${_cv2_pp}${PYTHONPATH:+:${PYTHONPATH}}" \
            verify_python_import "cv2" "cv2.__version__" \
            || echo "[WARN] cv2 import FAILED on a native build (traceback above) — real defect, not a sandbox artifact; non-fatal here, gated by smoke-media.sh and the runtime torch-venv smoke"
    elif [ "${WITH_PYTHON}" = "true" ]; then
        echo "Skipping Python import validation in cross mode"
    fi
}

main "$@"
