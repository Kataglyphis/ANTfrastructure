#!/usr/bin/env bash
set -Eeuo pipefail
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

# Source shared modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for helper in \
    "/opt/scripts/core/modules.sh" \
    "${SCRIPT_DIR}/../../01-core/modules.sh"; do
    if [ -f "${helper}" ]; then
        # shellcheck disable=SC1090
        source "${helper}"
        source_modules_framework "${SCRIPT_DIR}"
        break
    fi
done

source_module cross-env.sh || true
source_module logging.sh || true
source_module parallelism.sh || true
source_module compiler-cache.sh && { setup_ccache; setup_lld_linker; } || true
install_warn_trap

# Defaults (can be overridden via env vars or arguments)
: "${OPENCV_VERSION:=5.x}"
: "${OPENCV_SRC:=/tmp/opencv}"
: "${OPENCV_PREFIX:=/opt/opencv5}"
: "${OPENCV_REPO:=https://github.com/opencv/opencv.git}"
: "${OPENCV_CONTRIB_REPO:=https://github.com/opencv/opencv_contrib.git}"
: "${BUILD_TYPE:=Release}"
: "${NPROC:=$(compute_jobs_with_mem_cap "" 2000)}"
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
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "build-opencv: version=${OPENCV_VERSION} prefix=${OPENCV_PREFIX} buildtype=${BUILD_TYPE}"

# ------------------------------------------------------------------------------
# Fetch OpenCV source
# ------------------------------------------------------------------------------
fetch_opencv() {
    info "Fetching OpenCV ${OPENCV_VERSION} source..."
    
    # Main repository
    if [ -d "${OPENCV_SRC}/.git" ]; then
        echo "Updating existing OpenCV checkout..."
        cd "${OPENCV_SRC}"
        git fetch --tags || true
    else
        rm -rf "${OPENCV_SRC}"
        git clone "${OPENCV_REPO}" "${OPENCV_SRC}" || { echo "Failed cloning OpenCV"; exit 1; }
        cd "${OPENCV_SRC}"
    fi
    
    git checkout "${OPENCV_VERSION}" || { echo "Failed to checkout version ${OPENCV_VERSION}"; exit 1; }
    echo "OpenCV version: $(git describe --tags 2>/dev/null || echo 'unknown')"
    
    # Contrib modules (optional)
    if [ "${WITH_CONTRIB}" = "true" ]; then
        echo "Fetching OpenCV contrib modules..."
        # Use the conventional opencv_contrib directory name so CMake's
        # OPENCV_EXTRA_MODULES_PATH is the expected path
        local contrib_dir="${OPENCV_SRC}/opencv_contrib"

        if [ -d "${contrib_dir}/.git" ]; then
            cd "${contrib_dir}"
            git fetch --tags || true
        else
            rm -rf "${contrib_dir}"
            git clone "${OPENCV_CONTRIB_REPO}" "${contrib_dir}" || { echo "Failed cloning OpenCV contrib"; exit 1; }
            cd "${contrib_dir}"
        fi

        git checkout "${OPENCV_VERSION}" || { echo "Failed to checkout contrib version ${OPENCV_VERSION}"; exit 1; }
        echo "OpenCV contrib version: $(git describe --tags 2>/dev/null || echo 'unknown')"
    fi

    # OpenCV 5.x vendored MLAS: MlasHGemmSupported is declared in inc/mlas.h
    # but never defined, yet compute.cpp calls it from the FP16 template
    # MlasGQASupported<MLAS_FP16> regardless of MLAS_GEMM_ONLY. On riscv64
    # this produces an undefined-symbol link error. Provide a stub that
    # returns false when MLAS_GEMM_ONLY is set (SGEMM-only build).
    local mlas_compute="${OPENCV_SRC}/3rdparty/mlas/lib/compute.cpp"
    if [ -f "${mlas_compute}" ] && ! grep -Fq 'MLAS_GEMM_ONLY stub' "${mlas_compute}"; then
        echo "Patching vendored MLAS: adding MlasHGemmSupported stub for MLAS_GEMM_ONLY"
        cat >> "${mlas_compute}" <<'MLAS_STUB_EOF'

#ifdef MLAS_GEMM_ONLY
// MLAS_GEMM_ONLY stub: MlasHGemmSupported is declared but never defined
// in SGEMM-only builds; provide a fallback that always returns false.
MLASCALL
bool
MlasHGemmSupported(
    CBLAS_TRANSPOSE TransA,
    CBLAS_TRANSPOSE TransB
    )
{
    (void)TransA;
    (void)TransB;
    return false;
}
#endif
MLAS_STUB_EOF
        echo "OpenCV MLAS stub patch applied"
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

resolve_cross_archive_tool() {
    local tool="$1"
    local preferred="${CROSS_TARGET_TRIPLET}-gcc-${tool}"
    local fallback="${CROSS_TARGET_TRIPLET}-${tool}"
    local resolved

    resolved="$(command -v "${preferred}" 2>/dev/null || true)"
    if [ -n "${resolved}" ]; then
        printf '%s' "${resolved}"
        return 0
    fi

    resolved="$(command -v "${fallback}" 2>/dev/null || true)"
    if [ -n "${resolved}" ]; then
        printf '%s' "${resolved}"
        return 0
    fi

    printf '%s' "${fallback}"
}

shell_quote_args() {
    local quoted=""
    local arg

    for arg in "$@"; do
        quoted+="${quoted:+ }$(printf '%q' "${arg}")"
    done

    printf '%s' "${quoted}"
}

opencv_cross_wheel_platform_tag() {
    if ! command -v cross_target_arch >/dev/null 2>&1 || ! command -v arch_linux_platform_tag_for >/dev/null 2>&1; then
        return 1
    fi

    arch_linux_platform_tag_for "$(cross_target_arch)"
}

# ------------------------------------------------------------------------------
# Configure OpenCV build
# ------------------------------------------------------------------------------
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
        with_gtk="OFF"
        with_opengl="OFF"
        # Debian/Ubuntu multiarch keeps zlib.h in the shared include directory.
        target_zlib_include="/usr/include"
        target_zlib_library="/usr/lib/$(cross_target_triplet)/libz.so"
        target_shared_include_fallback="-idirafter /usr/include"
        if [ "$(cross_target_arch)" = "riscv64" ]; then
            # Ubuntu Ports cannot currently satisfy the target GStreamer/GLib dev chain for riscv64 cross builds.
            with_gstreamer="OFF"
        fi
        if [ "${WITH_PYTHON}" = "true" ] && command -v cross_target_python_dev_ready >/dev/null 2>&1 && ! cross_target_python_dev_ready; then
            echo "Target Python development files are not staged for $(cross_target_triplet 2>/dev/null || echo target); disabling OpenCV Python bindings in cross mode"
            WITH_PYTHON="false"
        fi
    fi

    if [ "${WITH_PYTHON}" = "true" ]; then
        echo "Using existing Python venv (expected at /opt/python/.venv)..."
        HOST_PYTHON="$(host_python_bin)"
        export PYTHON_EXECUTABLE="${HOST_PYTHON}" \
               Python_EXECUTABLE="${HOST_PYTHON}" \
               Python3_EXECUTABLE="${HOST_PYTHON}"
        uv pip install numpy wheel
    fi

    # Build cmake options array
    local cmake_opts=(
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
    )

    if command -v append_cmake_cross_args >/dev/null 2>&1; then
        append_cmake_cross_args cmake_opts
    fi

    if cross_build_is_active; then
        # OpenCV's mixed vendored/system dependency graph needs access to the
        # target sysroot headers and libraries under /usr while still finding
        # generated build artifacts in the normal build tree.
        cmake_opts+=("-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH")
        cmake_opts+=("-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH")
        cmake_opts+=("-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH")
        cmake_opts+=("-DCMAKE_AR=$(resolve_cross_archive_tool ar)")
        cmake_opts+=("-DCMAKE_RANLIB=$(resolve_cross_archive_tool ranlib)")
        cmake_opts+=("-DCMAKE_C_COMPILER_AR=$(resolve_cross_archive_tool ar)")
        cmake_opts+=("-DCMAKE_CXX_COMPILER_AR=$(resolve_cross_archive_tool ar)")
        cmake_opts+=("-DCMAKE_C_COMPILER_RANLIB=$(resolve_cross_archive_tool ranlib)")
        cmake_opts+=("-DCMAKE_CXX_COMPILER_RANLIB=$(resolve_cross_archive_tool ranlib)")
        cmake_opts+=("-DZLIB_INCLUDE_DIR=${target_zlib_include}")
        cmake_opts+=("-DZLIB_LIBRARY=${target_zlib_library}")
        cmake_opts+=("-DCMAKE_C_FLAGS=${target_shared_include_fallback}")
        cmake_opts+=("-DCMAKE_CXX_FLAGS=${target_shared_include_fallback}")
    fi

    # Fallback LLD flags (canonical path via setup_lld_linker exports env vars)
    if [ -z "${CMAKE_EXE_LINKER_FLAGS:-}" ] && command -v ld.lld >/dev/null 2>&1 && [ "${USE_LLD:-true}" != "false" ]; then
        cmake_opts+=("-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld")
        cmake_opts+=("-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld")
        cmake_opts+=("-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld")
    fi

    # Fallback ccache flags (canonical path via setup_ccache exports env vars)
    if [ -z "${CMAKE_C_COMPILER_LAUNCHER:-}" ] && command -v ccache >/dev/null 2>&1 && [ "${USE_CCACHE:-true}" != "false" ]; then
        cmake_opts+=("-DCMAKE_C_COMPILER_LAUNCHER=ccache")
        cmake_opts+=("-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
        cmake_opts+=("-DCMAKE_ASM_COMPILER_LAUNCHER=")
    fi

    # Ensure tracking contrib module is explicitly enabled (some builds/platforms
    # may not build it by default even when contrib modules are available).
    cmake_opts+=("-DBUILD_opencv_tracking=ON")

    # Help CMake find the Vulkan SDK if it's installed in the default location
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
    
    # Contrib modules
    if [ "${WITH_CONTRIB}" = "true" ]; then
        cmake_opts+=("-DOPENCV_EXTRA_MODULES_PATH=${OPENCV_SRC}/opencv_contrib/modules")
        cmake_opts+=("-DBUILD_opencv_python3=${WITH_PYTHON}")
    fi
    
    # Python bindings
    if [ "${WITH_PYTHON}" = "true" ]; then
        PY_EXEC="${HOST_PYTHON:-$(host_python_bin)}"
        cmake_opts+=("-DPYTHON3_EXECUTABLE=${PY_EXEC}")
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
                cmake_opts+=("-DPYTHON3_LIBRARY=${target_python_library}")
                cmake_opts+=("-DPYTHON3_INCLUDE_DIR=${target_python_include}")
            fi

            # Numpy headers are architecture-independent; use the host venv numpy.
            # OpenCV's cmake needs them to generate Python3 wrappers (cv2.so).
            # In cross mode, FindPython3 cannot probe numpy at the target, so we
            # supply the include path explicitly.
            local numpy_include
            numpy_include="$(${HOST_PYTHON:-$(host_python_bin)} -c 'import numpy; print(numpy.get_include())' 2>/dev/null || true)"
            if [ -n "${numpy_include}" ] && [ -d "${numpy_include}" ]; then
                cmake_opts+=("-DPYTHON3_NUMPY_INCLUDE_DIRS=${numpy_include}")
                echo "Set PYTHON3_NUMPY_INCLUDE_DIRS=${numpy_include} for cross-compile"
            else
                echo "[WARN] Numpy not available in host venv; Python3 wrappers will not be generated"
            fi
        elif [ -f "/usr/local/lib/libpython${OPENCV_PYTHON_VERSION}.so" ]; then
            cmake_opts+=("-DPYTHON3_LIBRARY=/usr/local/lib/libpython${OPENCV_PYTHON_VERSION}.so")
            cmake_opts+=("-DPYTHON3_INCLUDE_DIR=/usr/local/include/python${OPENCV_PYTHON_VERSION}")
        fi
    fi
    
    # Java bindings
    if [ "${WITH_JAVA}" = "true" ]; then
        cmake_opts+=("-DBUILD_JAVA=ON")
        cmake_opts+=("-DBUILD_opencv_java=ON")
    else
        cmake_opts+=("-DBUILD_JAVA=OFF")
        cmake_opts+=("-DBUILD_opencv_java=OFF")
    fi
    
    # Hardware acceleration options
    if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
        echo "Enabling NVIDIA CUDA and cuDNN support in OpenCV..."
        # CUDA path should be available from base image (typically /usr/local/cuda)
        cmake_opts+=("-DWITH_CUDA=ON")
        cmake_opts+=("-DCUDA_FAST_MATH=ON")
        cmake_opts+=("-DWITH_CUDNN=ON")
        cmake_opts+=("-DOPENCV_DNN_CUDA=ON")
        cmake_opts+=("-DWITH_CUBLAS=ON")
        cmake_opts+=("-DWITH_NVCUVID=ON")
        cmake_opts+=("-DWITH_TENSORRT=ON")
        
        # Explicitly provide the CUDA library stub so we can build without a GPU present
        if [ -f "/usr/local/cuda/lib64/stubs/libcuda.so" ]; then
            cmake_opts+=("-DCUDA_CUDA_LIBRARY=/usr/local/cuda/lib64/stubs/libcuda.so")
        elif [ -f "/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so" ]; then
            cmake_opts+=("-DCUDA_CUDA_LIBRARY=/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so")
        else
            # fallback if stub isn't found
            cmake_opts+=("-DBUILD_opencv_cudacodec=OFF")
        fi
    fi

    echo "CMake options: ${cmake_opts[*]}"
    cmake "${OPENCV_SRC}" "${cmake_opts[@]}" || { echo "OpenCV configure failed"; exit 1; }
}

# ------------------------------------------------------------------------------
# Build OpenCV
# ------------------------------------------------------------------------------
build_opencv() {
    echo "Building OpenCV with ${NPROC} parallel jobs..."
    
    local build_dir="${OPENCV_SRC}/build"
    cd "${build_dir}"
    
    if make -j"${NPROC}"; then
        return 0
    fi

    echo "OpenCV parallel build failed; rerunning serial verbose build for diagnostics..."
    make -j1 VERBOSE=1 || true
    echo "OpenCV build failed"
    exit 1
}

# ------------------------------------------------------------------------------
# NOTE: build_opencv_python_wheel() below is preserved for reference but is
# NOT called by main(). The source-built 5.x bindings are installed directly
# via cmake (BUILD_opencv_python3=true) and are preferred over the wheel path.
# ------------------------------------------------------------------------------
build_opencv_python_wheel() {
    echo "====================================================================="
    echo "Building opencv-python wheel from official repository..."
    echo "====================================================================="
    
    local py_repo_src="/tmp/opencv-python-repo"
    rm -rf "${py_repo_src}"
    
    # Clone the official repo (it manages OpenCV submodules automatically)
    git clone --recursive https://github.com/opencv/opencv-python.git "${py_repo_src}"
    pushd "${py_repo_src}" >/dev/null
    
    # Max features: include contrib modules, disable headless (keep GUI)
    export ENABLE_CONTRIB=1
    export ENABLE_HEADLESS=0
    
    local py_cmake_args=(
        "-DWITH_TBB=ON"
        "-DWITH_EIGEN=ON"
        "-DWITH_GTK=ON"
        "-DWITH_V4L=ON"
        "-DWITH_FFMPEG=ON"
        "-DWITH_GSTREAMER=ON"
        "-DWITH_OPENEXR=ON"
        "-DWITH_JPEG=ON"
        "-DWITH_PNG=ON"
        "-DWITH_TIFF=ON"
        "-DWITH_WEBP=ON"
        "-DWITH_DC1394=ON"
        "-DWITH_1394=ON"
        "-DWITH_OPENCL=ON"
        "-DWITH_OPENGL=ON"
        "-DWITH_VULKAN=ON"
        "-DWITH_PROTOBUF=ON"
        "-DWITH_LIBV4L=ON"
        "-DWITH_ITT=ON"
        "-DBUILD_opencv_tracking=ON"
    )
    local wheel_platform_name=""
    
    if [ "$(target_machine)" != "amd64" ] && [ "$(target_machine)" != "x86_64" ]; then
        py_cmake_args+=("-DWITH_IPP=OFF")
    fi

    if cross_build_is_active; then
        local -a wheel_cross_args=()
        local cross_ar=""
        local cross_ranlib=""
        local target_python_library=""
        local target_python_include=""
        local target_python_arch_include=""
        local target_triplet=""

        wheel_platform_name="$(opencv_cross_wheel_platform_tag || true)"
        if [ -z "${wheel_platform_name}" ]; then
            echo "[WARN] Could not determine a platform tag for the OpenCV cross wheel; skipping wheel retagging"
        fi

        target_triplet="$(cross_target_triplet 2>/dev/null || true)"
        if command -v append_cmake_cross_args >/dev/null 2>&1; then
            append_cmake_cross_args wheel_cross_args
            py_cmake_args+=("${wheel_cross_args[@]}")
        fi
        cross_ar="$(resolve_cross_archive_tool ar)"
        cross_ranlib="$(resolve_cross_archive_tool ranlib)"

        py_cmake_args+=("-DWITH_GTK=OFF" "-DWITH_OPENGL=OFF")
        if [ "$(cross_target_arch)" = "riscv64" ]; then
            py_cmake_args+=("-DWITH_GSTREAMER=OFF")
        fi
        py_cmake_args+=(
            "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH"
            "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH"
            "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH"
            "-DCMAKE_AR=${cross_ar}"
            "-DCMAKE_RANLIB=${cross_ranlib}"
            "-DCMAKE_C_COMPILER_AR=${cross_ar}"
            "-DCMAKE_CXX_COMPILER_AR=${cross_ar}"
            "-DCMAKE_C_COMPILER_RANLIB=${cross_ranlib}"
            "-DCMAKE_CXX_COMPILER_RANLIB=${cross_ranlib}"
            "-DZLIB_INCLUDE_DIR=/usr/include"
            "-DCMAKE_C_FLAGS=-idirafter /usr/include"
            "-DCMAKE_CXX_FLAGS=-idirafter /usr/include"
        )
        if [ -n "${target_triplet}" ] && [ -f "/usr/lib/${target_triplet}/libz.so" ]; then
            py_cmake_args+=("-DZLIB_LIBRARY=/usr/lib/${target_triplet}/libz.so")
        fi

        if command -v cross_target_python_library >/dev/null 2>&1; then
            target_python_library="$(cross_target_python_library 2>/dev/null || true)"
        fi
        if command -v cross_target_python_include_dir >/dev/null 2>&1; then
            target_python_include="$(cross_target_python_include_dir 2>/dev/null || true)"
            target_python_arch_include="$(cross_target_python_arch_include_dir 2>/dev/null || true)"
        fi
        if [ -n "${target_python_library}" ] && [ -d "${target_python_include}" ]; then
            py_cmake_args+=("-DPYTHON3_LIBRARY=${target_python_library}" "-DPYTHON3_INCLUDE_DIR=${target_python_include}")
            if [ -d "${target_python_arch_include}" ]; then
                py_cmake_args+=("-DPython3_INCLUDE_DIRS=${target_python_include};${target_python_arch_include}")
            fi
        fi
    fi
    
    if [ "${ENABLE_NVIDIA:-false}" = "true" ]; then
        echo "Enabling NVIDIA CUDA support for opencv-python wheel..."
        py_cmake_args+=("-DWITH_CUDA=ON")
        py_cmake_args+=("-DCUDA_FAST_MATH=ON")
        py_cmake_args+=("-DWITH_CUDNN=ON")
        py_cmake_args+=("-DOPENCV_DNN_CUDA=ON")
        py_cmake_args+=("-DWITH_CUBLAS=ON")
        
        # Add stub library path if no GPU during build
        if [ -f "/usr/local/cuda/lib64/stubs/libcuda.so" ]; then
            py_cmake_args+=("-DCUDA_CUDA_LIBRARY=/usr/local/cuda/lib64/stubs/libcuda.so")
        elif [ -f "/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so" ]; then
            py_cmake_args+=("-DCUDA_CUDA_LIBRARY=/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so")
        else
            py_cmake_args+=("-DBUILD_opencv_cudacodec=OFF")
        fi
    fi
    
    export CMAKE_ARGS="$(shell_quote_args "${py_cmake_args[@]}")"
    echo "CMAKE_ARGS for python wheel: ${CMAKE_ARGS}"
    
    PYEXEC="${HOST_PYTHON:-$(host_python_bin)}"
    # Ensure build dependencies are installed
    "${PYEXEC}" -m pip install wheel scikit-build cmake ninja numpy packaging || \
        uv pip install --python "${PYEXEC}" wheel scikit-build cmake ninja numpy packaging

    local cmake_bin_dir=""
    local cmake_bin=""
    cmake_bin_dir="$("${PYEXEC}" -c 'import cmake; print(cmake.CMAKE_BIN_DIR)' 2>/dev/null || true)"
    if [ -n "${cmake_bin_dir}" ] && [ -x "${cmake_bin_dir}/cmake" ]; then
        cmake_bin="${cmake_bin_dir}/cmake"
        export PATH="${cmake_bin_dir}:${PATH}"
        export CMAKE_EXECUTABLE="${cmake_bin}"
        export SKBUILD_CMAKE="${cmake_bin}"
        echo "Using CMake binary from ${cmake_bin}"
    fi
    
    mkdir -p "${OPENCV_PREFIX}/wheels"
    
    echo "Building wheel via scikit-build... (this will take a while as it compiles OpenCV again)"
    "${PYEXEC}" -m pip wheel . -w "${OPENCV_PREFIX}/wheels" --verbose || echo "Failed to build opencv-python wheel"

    if [ -n "${wheel_platform_name}" ]; then
        shopt -s nullglob
        local -a built_cross_wheels=("${OPENCV_PREFIX}/wheels"/*.whl)
        shopt -u nullglob
        if [ "${#built_cross_wheels[@]}" -gt 0 ]; then
            local cross_wheel
            for cross_wheel in "${built_cross_wheels[@]}"; do
                "${PYEXEC}" -m wheel tags --remove --platform-tag="${wheel_platform_name}" "${cross_wheel}" || \
                    echo "Failed to retag OpenCV cross wheel $(basename "${cross_wheel}")"
            done
        fi
    fi
    
    popd >/dev/null
}

# ------------------------------------------------------------------------------
# Install OpenCV
# ------------------------------------------------------------------------------
install_opencv() {
    echo "Installing OpenCV to ${OPENCV_PREFIX}..."
    
    local build_dir="${OPENCV_SRC}/build"
    cd "${build_dir}"
    
    SUDO_CMD=""
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO_CMD="sudo"
        else
            echo "Not root and sudo missing - cannot install; exiting"
            exit 1
        fi
    fi

    ${SUDO_CMD} make install
    ${SUDO_CMD} ldconfig || true

    # Ensure unversioned symlinks exist for contrib libraries (search lib and lib64)
    for libdir in "${OPENCV_PREFIX}/lib" "${OPENCV_PREFIX}/lib64"; do
        if [ -d "${libdir}" ]; then
            local candidate
            candidate=$(find "${libdir}" -maxdepth 1 -name "libopencv_tracking.so*" | head -n 1)
            if [ -n "${candidate}" ] && [ ! -e "${libdir}/libopencv_tracking.so" ]; then
                echo "Creating symlink ${libdir}/libopencv_tracking.so -> ${candidate}"
                ${SUDO_CMD} ln -sf "$(basename "${candidate}")" "${libdir}/libopencv_tracking.so" || true
            fi
        fi
    done

    # Sanity-check: fail early if tracking library is still missing
    if ! (ls "${OPENCV_PREFIX}/lib/libopencv_tracking.so" >/dev/null 2>&1 || ls "${OPENCV_PREFIX}/lib64/libopencv_tracking.so" >/dev/null 2>&1); then
        echo "ERROR: libopencv_tracking was not found after install. Listing installed libs for debugging:"
        ${SUDO_CMD} ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null || true
        ${SUDO_CMD} ls -la "${OPENCV_PREFIX}/lib64" 2>/dev/null || true
        die "Failing build so the image build doesn't continue with a broken OpenCV install."
    fi

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
            ${SUDO_CMD} cp "${pcdir}/opencv5.pc" "${pcdir}/opencv4.pc"
        fi
    done

    local sharedir="${OPENCV_PREFIX}/share"
    if [ ! -e "${sharedir}/opencv4" ] && \
       [ ! -e "${sharedir}/opencv" ] && \
       [ ! -e "${sharedir}/OpenCV" ]; then
        ${SUDO_CMD} mkdir -p "${sharedir}"
        if [ -d "${sharedir}/opencv5" ]; then
            echo "Creating data-dir compatibility alias ${sharedir}/opencv4 -> opencv5"
            ${SUDO_CMD} ln -s opencv5 "${sharedir}/opencv4"
        else
            # No OpenCV data directory was installed (e.g. cascade data removed
            # in OpenCV 5 core). Create an empty data dir so consumers that only
            # probe for its existence at configure time still succeed.
            echo "Creating empty data-dir compatibility alias ${sharedir}/opencv4"
            ${SUDO_CMD} mkdir -p "${sharedir}/opencv4"
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
    echo "Libraries:"
    ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null | head -20 || echo "Could not list libraries"
    
    if [ "${WITH_PYTHON}" = "true" ] && { ! cross_build_is_active; }; then
        echo ""
        echo "Python bindings:"
        "${HOST_PYTHON:-$(host_python_bin)}" -c "import cv2; print('OpenCV version:', cv2.__version__)" 2>/dev/null || echo "Could not import cv2"
    elif [ "${WITH_PYTHON}" = "true" ]; then
        echo "Skipping Python import validation in cross mode"
    fi
}

main "$@"
