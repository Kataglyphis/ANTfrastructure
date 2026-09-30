#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Build and install OpenCV from source; see --help for the options.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../core/common.sh"
media_common_init "${SCRIPT_DIR}"
install_warn_trap
# shellcheck source=opencv-ort.sh
source "${SCRIPT_DIR}/opencv-ort.sh"
# shellcheck source=../../ort-provenance.sh
source "${SCRIPT_DIR}/../../ort-provenance.sh"

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
: "${OPENCV_GSTREAMER_PASS:=1}"

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

# GNU ld, not lld, accepts OpenCV's vendored duplicate symbols with --allow-multiple-definition; GCC is pinned over clang on PATH.
configure_opencv_build_env() {
    rm -rf "${OPENCV_PREFIX}"

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
    # detect_ffmpeg's try_compile inherits env LDFLAGS and needs our libdir for avcodec's transitive libs, or HAVE_FFMPEG goes FALSE.
    if [ -d "${FFMPEG_PREFIX:-/opt/ffmpeg}/lib" ]; then
        export LDFLAGS="${LDFLAGS} -L${FFMPEG_PREFIX:-/opt/ffmpeg}/lib -Wl,-rpath-link,${FFMPEG_PREFIX:-/opt/ffmpeg}/lib"
    fi
    # App links need the gst libdir on -rpath-link; a candidate counts only if it holds the .so, as the cross triplet dir can be empty.
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
        # Prune share/gdb: meson's gdb pretty-printer mirror holds no .so but sorts first in readdir order.
        _gst_lib="$(dirname "$(find "${_gst_prefix}" -path '*/share/gdb' -prune -o -name 'libgstreamer-1.0.so*' -not -type d -print 2>/dev/null | head -1)" 2>/dev/null || true)"
        [ "${_gst_lib}" = "." ] && _gst_lib=""
    fi
    if [ -n "${_gst_lib}" ]; then
        echo "OpenCV: gstreamer libdir resolved to ${_gst_lib} (-L + -rpath-link)"
        export LDFLAGS="${LDFLAGS} -L${_gst_lib} -Wl,-rpath-link,${_gst_lib}"
    elif [ ! -d "${_gst_prefix}" ]; then
        # Cross pass 1 runs before the gstreamer prefix exists, so a warning would be a false alarm.
        :
    else
        echo "[WARN] OpenCV: no gstreamer libdir found under ${_gst_prefix}; app links may fail on transitive libgst* (\"try using -rpath-link\")"
    fi
}

configure_opencv_build_env

# Fetch OpenCV source
fetch_opencv() {
    info "Fetching OpenCV ${OPENCV_VERSION} source..."

    # Not in parallel with contrib: it nests under OPENCV_SRC, and both clones race to create that dir.
    retry 3 10 "opencv git clone" clone_or_update_repo "${OPENCV_REPO}" "${OPENCV_SRC}" "${OPENCV_COMMIT:-${OPENCV_VERSION}}" \
        || { echo "Failed to clone opencv"; exit 1; }

    local contrib_dir=""
    if [ "${WITH_CONTRIB}" = "true" ]; then
        echo "Fetching OpenCV contrib modules..."
        contrib_dir="${OPENCV_SRC}/opencv_contrib"
        retry 3 10 "opencv_contrib git clone" clone_or_update_repo "${OPENCV_CONTRIB_REPO}" "${contrib_dir}" "${OPENCV_CONTRIB_COMMIT:-${OPENCV_VERSION}}" \
            || { echo "Failed to clone opencv_contrib"; exit 1; }
    fi

    cd "${OPENCV_SRC}"
    # A pinned clone sits on FETCH_HEAD with no local branch ref, so only an unpinned one re-checks out the branch.
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

    # OpenCV 5.x's vendored MLAS calls MlasHGemmSupported but never defines it: weak-stub it.
    if [ -f "${OPENCV_SRC}/3rdparty/mlas/lib/compute.cpp" ]; then
        bash /opt/scripts/core/apply-patch.sh \
            /opt/scripts/patches/opencv/001-mlas-hgemm-supported-stub.patch \
            "${OPENCV_SRC}" \
            "OpenCV MLAS MlasHGemmSupported stub for MLAS_GEMM_ONLY"
    fi

    # opencv 5.0.0 still uses the AVCodec fields FFmpeg 8 removed; drop these once a 5.x release carries the fix.
    if [ -f "${OPENCV_SRC}/modules/videoio/src/cap_ffmpeg_impl.hpp" ]; then
        # Upstream's own 4.x commits, not a reimplementation: docs/upstreamable-patches.md entry 2
        bash /opt/scripts/core/apply-patch.sh \
            /opt/scripts/patches/opencv/002a-upstream-ffmpeg-pix_fmts-removal.patch \
            "${OPENCV_SRC}" \
            "OpenCV upstream 700cd32ffd: support FFmpeg after AVCodec::pix_fmts removal"
        bash /opt/scripts/core/apply-patch.sh \
            /opt/scripts/patches/opencv/002b-upstream-ffmpeg-supported-config-framerates.patch \
            "${OPENCV_SRC}" \
            "OpenCV upstream 83ed22ca28: avcodec_get_supported_config for framerates"
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

# Configure OpenCV build

# CMake's -isystem /usr/include shadows libstdc++'s <complex.h>: docs/failure-modes.md#opencv-stdcomplex-breaks-on-a-shadowed-complexh
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

# See docs/failure-modes.md § RV1-FREETYPE: riscv64 OpenCV freetype/harfbuzz
_ota_riscv64_freetype() {
    local -n _otarf_opts="$1"
    local _hb_triplet _hb_a _hb_inc _hb_pc _ft_so
    _hb_triplet="$(cross_target_triplet 2>/dev/null || echo riscv64-linux-gnu)"
    _hb_a="/usr/${_hb_triplet}/lib/libharfbuzz.a"
    _hb_inc="/usr/${_hb_triplet}/include/harfbuzz/hb-ft.h"
    _hb_pc="/usr/${_hb_triplet}/lib/pkgconfig/harfbuzz.pc"
    _ft_so="/usr/lib/${_hb_triplet}/libfreetype.so"
    if [ -f "${_hb_a}" ] && [ -f "${_hb_inc}" ] && [ -f "${_hb_pc}" ] && [ -f "${_ft_so}" ]; then
        echo "riscv64 OpenCV: freetype module ENABLED against static target harfbuzz (${_hb_a}) + ${_ft_so}"
        export PKG_CONFIG_PATH="/usr/${_hb_triplet}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
        _otarf_opts+=("-Dpkgcfg_lib_HARFBUZZ_harfbuzz:FILEPATH=${_hb_a}")
        _otarf_opts+=("-Dpkgcfg_lib_HARFBUZZ_freetype:FILEPATH=${_ft_so}")
        _otarf_opts+=("-Dpkgcfg_lib_FREETYPE_freetype:FILEPATH=${_ft_so}")
    else
        echo "[WARN] riscv64 OpenCV: static target harfbuzz not staged (libharfbuzz.a=$([ -f "${_hb_a}" ] && echo ok || echo MISSING) hb-ft.h=$([ -f "${_hb_inc}" ] && echo ok || echo MISSING) harfbuzz.pc=$([ -f "${_hb_pc}" ] && echo ok || echo MISSING) libfreetype.so=$([ -f "${_ft_so}" ] && echo ok || echo MISSING)); keeping BUILD_opencv_freetype=OFF"
        _otarf_opts+=("-DBUILD_opencv_freetype=OFF")
    fi
}

# The vendored libpng fails its RVV probe under GCC 16, so riscv64 needs install-deps.sh's; absent, fail now, not at a later smoke.
_ota_riscv64_png() {
    local -n _otarp_opts="$1"
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
        _otarp_opts+=("-DWITH_PNG=ON" "-DBUILD_PNG=OFF" "-DPNG_PNG_INCLUDE_DIR=${_png_inc}" "-DPNG_LIBRARY=${_png_lib}")
    elif [ "${OPENCV_ALLOW_NO_PNG:-0}" = "1" ]; then
        echo "[WARN] riscv64 OpenCV: no external libpng found and OPENCV_ALLOW_NO_PNG=1 set; disabling PNG (cv2 PNG encode unavailable)"
        _otarp_opts+=("-DWITH_PNG=OFF")
    else
        echo "[ERROR] riscv64 OpenCV: external static libpng NOT found (searched /usr/${_png_triplet}/lib and /usr/lib/${_png_triplet})." >&2
        echo "[ERROR] PNG is required on riscv64; install-deps.sh must build libpng (git+ mirror). Failing early instead of shipping a PNG-less OpenCV." >&2
        echo "[ERROR] Set OPENCV_ALLOW_NO_PNG=1 only if a PNG-less riscv64 OpenCV is genuinely acceptable." >&2
        exit 1
    fi
}

_opencv_target_adjustments() {
    local -n _ota_cmake_opts="$1"
    local -n _ota_with_gtk="$2"
    local -n _ota_with_gstreamer="$3"
    local -n _ota_with_opengl="$4"
    local -n _ota_zlib_inc="$5"
    local -n _ota_zlib_lib="$6"
    local -n _ota_shared_inc="$7"

    # OpenCV's bundled ippicv is x86-only prebuilt and fails to link elsewhere.
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
        # Pass 2 also sees the distro's older libav*-dev headers; -I puts our FFmpeg's ahead of them.
        if [ -d "${FFMPEG_PREFIX:-/opt/ffmpeg}/include/libavutil" ]; then
            _ota_shared_inc="-I${FFMPEG_PREFIX:-/opt/ffmpeg}/include ${_ota_shared_inc}"
        fi
        if [ "$(cross_target_arch)" = "riscv64" ]; then
            # Only pass 2 (OPENCV_GSTREAMER_PASS=2) has our /opt/gstreamer to probe; pass 1 has no gstreamer at all.
            if [ "${OPENCV_GSTREAMER_PASS}" != "2" ]; then
                _ota_with_gstreamer="OFF"
            fi
            _ota_riscv64_freetype _ota_cmake_opts
            _ota_riscv64_png _ota_cmake_opts
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
        # ONNX Runtime args come from opencv_ort_cmake_args (configure_opencv).
        "-DWITH_AVIF=ON"
        "-DWITH_HDF5=ON"
        "-DOPENCV_ENABLE_NONFREE=ON"
    )

    # RVV is gated on these cache vars, not on -march. docs/riscv64-rva23-baseline.md
    if [ "$(cross_target_arch)" = "riscv64" ]; then
        _occmo_out+=("-DCPU_BASELINE=RVV" "-DWITH_HAL_RVV=ON")
    fi
}

_opencv_cmake_cross_opts() {
    local -n _ocmco_out="$1"
    local target_zlib_include="$2" target_zlib_library="$3" target_shared_include_fallback="$4"

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args _ocmco_out
    fi

    if cross_build_is_active; then
        # BOTH: the target sysroot lives under /usr, while generated artifacts stay in the build tree.
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

            # FindPython3 cannot probe the target's numpy; its headers are arch-independent, so the host's serve.
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
        # TensorRT is optional: the Jetson lane is CUDA+cuDNN without it.
        if [ "${ENABLE_TENSORRT:-true}" = "false" ]; then
            echo "ENABLE_TENSORRT=false — OpenCV built without the TensorRT backend"
        else
            _ocmcd_out+=("-DWITH_TENSORRT=ON")
        fi
        _ocmcd_out+=("-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES:-86;87;89;120}")
        # OpenCV's own CUDA detection reads CUDA_ARCH_BIN, in dotted form (87 -> 8.7), not the list above.
        _ocv_arch_bin="$(printf '%s' "${CUDA_ARCHITECTURES:-86;87;89;120}" \
            | tr ';' '\n' | sed -E 's/^([0-9]+)([0-9])$/\1.\2/' | paste -sd';' -)"
        _ocmcd_out+=("-DCUDA_ARCH_BIN=${_ocv_arch_bin}")
        echo "OpenCV CUDA arches: CUDA_ARCH_BIN=${_ocv_arch_bin}"
        # Only an sccache-class launcher can wrap nvcc; ccache cannot.
        if [ "${ENABLE_SCCACHE_CUDA:-0}" = "1" ]; then
            compiler_cache_launcher_env 2>/dev/null || true
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

    # Computed first for the locals, appended after the core opts: those reassign the array and cmake is last-wins.
    local target_cmake_opts=()
    _opencv_target_adjustments target_cmake_opts with_gtk with_gstreamer with_opengl \
        target_zlib_include target_zlib_library target_shared_include_fallback

    _opencv_cmake_core_opts cmake_opts "${with_gtk}" "${with_gstreamer}" "${with_opengl}"
    cmake_opts+=("${target_cmake_opts[@]}")
    _opencv_cmake_cross_opts cmake_opts \
        "${target_zlib_include}" "${target_zlib_library}" "${target_shared_include_fallback}"

    append_cmake_cache_linker_args cmake_opts

    # Some platforms skip the tracking module by default even with contrib present.
    cmake_opts+=("-DBUILD_opencv_tracking=ON")

    _opencv_vulkan_setup
    _opencv_cmake_contrib_opts cmake_opts
    _opencv_cmake_python_opts cmake_opts
    _opencv_cmake_java_opts cmake_opts
    _opencv_cmake_cuda_opts cmake_opts
    _opencv_cmake_freetype_opts cmake_opts

    # Last, because a helper's -DCMAKE_EXE_LINKER_FLAGS would beat env LDFLAGS and drop the -L/-rpath-link repairs.
    cmake_opts+=("-DCMAKE_EXE_LINKER_FLAGS=${CMAKE_EXE_LINKER_FLAGS:-} ${LDFLAGS:-}")

    # The chain ONNX Runtime or no OpenCV at all: opencv-ort.sh.
    local ort_compat="${build_dir}/ort-compat" ort_ver
    opencv_ort_compat_tree "${OPENCV_ORT_CHAIN_ROOT}" "${ort_compat}" \
        || die "OpenCV must build against the chain ONNX Runtime at ${OPENCV_ORT_CHAIN_ROOT}"
    ort_ver="$(opencv_ort_version "${OPENCV_ORT_CHAIN_ROOT}/lib")" || die "no chain ONNX Runtime version"
    opencv_ort_cmake_args cmake_opts "${ort_compat}" "${ort_ver}"

    echo "CMake options: ${cmake_opts[*]}"
    cmake -G Ninja "${OPENCV_SRC}" "${cmake_opts[@]}" 2>&1 | tee "${build_dir}/opencv-configure.log" \
        || die "OpenCV configure failed"
    opencv_ort_assert_configure "${build_dir}" "${ort_compat}" "${ort_ver}" \
        || die "OpenCV configure resolved an ONNX Runtime other than the chain"
}

# Build OpenCV
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

# Install OpenCV
install_opencv() {
    echo "Installing OpenCV to ${OPENCV_PREFIX}..."
    
    local build_dir="${OPENCV_SRC}/build"
    cd "${build_dir}"
    
    ensure_sudo_or_die

    # Stderr is captured, not dropped, so the real reason (ENOSPC, permissions) reaches the log if both fail.
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
    opencv_ort_assert_installed "${OPENCV_PREFIX}" \
        || die "OpenCV's install left a second ONNX Runtime in ${OPENCV_PREFIX}"
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

# gst-plugins-bad still looks OpenCV up as opencv4 (>= 4.0.0, no upper bound), so alias the 5.x install to that name.
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
            # OpenCV 5 core installs no data dir; consumers only probe that one exists.
            echo "Creating empty data-dir compatibility alias ${sharedir}/opencv4"
            ${SUDO_WRAP} mkdir -p "${sharedir}/opencv4"
        fi
    fi
}

# Cleanup
cleanup() {
    echo "Cleaning up build directory..."
    rm -rf "${OPENCV_SRC}" || true
}

# Main
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
    # G2: the tree, both records and the configure log hold the chain ORT only; a pass stamps the prefix for G1.
    ort_assert_chain_only opencv --stamp "${OPENCV_PREFIX}/ort-provenance/opencv.json" --chain "${OPENCV_ORT_CHAIN_ROOT}" \
        --tree "${OPENCV_SRC}" --shim "${OPENCV_SRC}/build/ort-compat" --record "${OPENCV_SRC}/build/CMakeCache.txt" \
        --record "${OPENCV_SRC}/build/build.ninja" --log "${OPENCV_SRC}/build/opencv-configure.log" \
        || die "OpenCV's build inputs reach an ONNX Runtime other than the chain's"

    if [ "${WITH_PYTHON}" = "true" ]; then
        # The opencv-python wheel would build 4.x over the 5.x cv2 the library install already placed.
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

    # Best-effort strip (MEDIA_STRIP=0 disables); the helper derives the cross strip itself, as STRIP is unset here.
    declare -F strip_media_prefixes >/dev/null 2>&1 && strip_media_prefixes "${OPENCV_PREFIX}" || true

    echo "Libraries:"
    ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null | head -20 || echo "Could not list libraries"
    
    if [ "${WITH_PYTHON}" = "true" ] && { ! cross_build_is_active; }; then
        echo ""
        echo "Python bindings:"
        # cv2 lives under the OpenCV prefix, not system site-packages, so a bare import would always fail.
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
