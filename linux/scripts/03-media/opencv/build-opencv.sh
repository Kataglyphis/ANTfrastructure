#!/usr/bin/env bash
set -euo pipefail

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
# ==============================================================================

# Defaults (can be overridden via env vars or arguments)
: "${OPENCV_VERSION:=4.x}"
: "${OPENCV_SRC:=/tmp/opencv}"
: "${OPENCV_PREFIX:=/opt/opencv}"
: "${OPENCV_REPO:=https://github.com/opencv/opencv.git}"
: "${OPENCV_CONTRIB_REPO:=https://github.com/opencv/opencv_contrib.git}"
: "${BUILD_TYPE:=Release}"
: "${NPROC:=$(nproc)}"
: "${WITH_CONTRIB:=true}"
: "${WITH_PYTHON:=true}"
: "${OPENCV_PYTHON_VERSION:=3.14}"
: "${WITH_JAVA:=false}"
: "${SKIP_DEP_INSTALL:=false}"
: "${WITH_IPP:=ON}"

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
            echo "  --opencv-version VERSION  OpenCV version to build (default: 4.x)"
            echo "  --prefix PATH             Installation prefix (default: /opt/opencv)"
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
    echo "Fetching OpenCV ${OPENCV_VERSION} source..."
    
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
}

# ------------------------------------------------------------------------------
# Configure OpenCV build
# ------------------------------------------------------------------------------
configure_opencv() {
    echo "Configuring OpenCV build..."
    
    local build_dir="${OPENCV_SRC}/build"
    mkdir -p "${build_dir}"
    cd "${build_dir}"
    
    # Disable IPP automatically on non-x86 hosts because OpenCV bundles
    # prebuilt ippicv libraries for x86 which will fail when linking on
    # architectures like aarch64 or riscv. Allow explicit override via
    # the WITH_IPP env var (set to "ON" or "OFF").
    if [ "$(uname -m)" != "x86_64" ] && [ "${WITH_IPP}" = "ON" ]; then
        echo "Non-x86 host detected ($(uname -m)) - disabling Intel IPP to avoid x86 prebuilt libs"
        WITH_IPP="OFF"
    fi

    if [ "${WITH_PYTHON}" = "true" ]; then
        echo "Using existing Python venv (expected at /opt/python/.venv)..."
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
        "-DWITH_IPP=${WITH_IPP}"
    )

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
        PY_EXEC="$(which python3)"
        cmake_opts+=("-DPYTHON3_EXECUTABLE=${PY_EXEC}")
        # Explicitly set library and include paths since FindPython3 might not find free-threaded (t) libraries
        if [ -f "/usr/local/lib/libpython${OPENCV_PYTHON_VERSION}.so" ]; then
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
    
    make -j"${NPROC}" || { echo "OpenCV build failed"; exit 1; }
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
        echo "Failing build so the image build doesn't continue with a broken OpenCV install."
        exit 1
    fi

    # Attempt to build/capture Python wheel for OpenCV
    mkdir -p "${OPENCV_PREFIX}/wheels"
    if [ "${WITH_PYTHON}" = "true" ]; then
        echo "Attempting to create OpenCV wheel using the selected Python"
        PYEXEC="$(which python3)"
        if [ -n "${PYEXEC}" ]; then
            if [ -f "${OPENCV_SRC}/modules/python/package/setup.py" ]; then
                echo "Building python wheel from modules/python/package..."
                export OPENCV_VERSION="$(pkg-config --modversion opencv4 2>/dev/null || echo 4.10.0)"
                
                CV2_DIR=$(find "${OPENCV_PREFIX}" -type d -name "cv2" -path "*/python*/cv2" | head -n 1)
                if [ -n "${CV2_DIR}" ]; then
                    echo "Found cv2 python bindings at: ${CV2_DIR}"
                    # Copy the cv2 module into the package directory
                    cp -r "${CV2_DIR}" "${OPENCV_SRC}/modules/python/package/" || true
                    
                    # In addition, we need to ensure the compiled .so is properly placed
                    # inside the cv2 package folder before building the wheel
                    echo "Hunting for compiled cv2*.so to bundle inside the wheel..."
                    SO_FILE=$(find "${OPENCV_PREFIX}" "${OPENCV_SRC}/build" /usr /opt -type f -name "cv2*.so" 2>/dev/null | head -n 1 || true)
                    if [ -n "${SO_FILE}" ]; then
                        echo "Found compiled extension: ${SO_FILE}"
                        # Try to copy it directly into the cv2 directory we just copied
                        cp "${SO_FILE}" "${OPENCV_SRC}/modules/python/package/cv2/" || true
                        
                        # Python 3.14 might expect it inside a python-3.14 subdirectory
                        mkdir -p "${OPENCV_SRC}/modules/python/package/cv2/python-3.14"
                        cp "${SO_FILE}" "${OPENCV_SRC}/modules/python/package/cv2/python-3.14/" || true
                    else
                        echo "WARNING: Could not find any cv2*.so extension! The wheel will be incomplete."
                    fi
                else
                    echo "Could not find cv2 python directory to bundle into wheel. The wheel might be empty!"
                fi
                
                pushd "${OPENCV_SRC}/modules/python/package" >/dev/null
                sed -i -e "s/package_name = 'opencv'/package_name = 'opencv-python'/g" -e 's/package_name="opencv"/package_name="opencv-python"/g' setup.py || true
                
                ${PYEXEC} -m pip wheel . -w "${OPENCV_PREFIX}/wheels" || echo "Could not wheel OpenCV via pip"
                popd >/dev/null

                # Fix the wheel tags to match the current Python interpreter
                local wheel_file
                wheel_file=$(ls "${OPENCV_PREFIX}/wheels/"*opencv*"-py3-none-any.whl" 2>/dev/null | head -n 1 || true)
                if [ -n "${wheel_file}" ]; then
                    echo "Retagging wheel ${wheel_file} to match platform/ABI..."
                    local tags
                    tags=$(${PYEXEC} -c "import packaging.tags; t=next(packaging.tags.sys_tags()); print(f'--python-tag {t.interpreter} --abi-tag {t.abi} --platform-tag {t.platform}')")
                    ${PYEXEC} -m wheel tags "${wheel_file}" ${tags} --remove || true
                fi
            else
                ${PYEXEC} -m pip wheel -w "${OPENCV_PREFIX}/wheels" "${OPENCV_SRC}" || echo "Could not wheel OpenCV via pip; wheel may not be available"
            fi
        else
            echo "No suitable python executable found to build OpenCV wheel"
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
    cleanup
    
    # Validation step
    pkg-config --exists opencv4 && echo "OpenCV found via pkg-config: $(pkg-config --modversion opencv4)" || {
        echo "ERROR: OpenCV not found via pkg-config"
        echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}"
        exit 1
    }
    
    echo "OpenCV ${OPENCV_VERSION} installed successfully to ${OPENCV_PREFIX}"
    echo "Libraries:"
    ls -la "${OPENCV_PREFIX}/lib" 2>/dev/null | head -20 || echo "Could not list libraries"
    
    if [ "${WITH_PYTHON}" = "true" ]; then
        echo ""
        echo "Python bindings:"
        python3 -c "import cv2; print('OpenCV version:', cv2.__version__)" 2>/dev/null || echo "Could not import cv2"
    fi
}

main "$@"
